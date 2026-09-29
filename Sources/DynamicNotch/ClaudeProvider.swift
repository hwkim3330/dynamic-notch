import AppKit
import NotchKit

/// Claude Code 훅 → 노치.
/// 훅이 `DynamicNotch --claude-hook` 을 실행하면 (ClaudeHook.run) 분산 알림으로 이벤트가 넘어온다.
enum ClaudeHook {
    static let notification = Notification.Name("com.hwkim3330.dynamicnotch.claude")

    /// 훅 모드: stdin 의 훅 JSON 을 읽어 실행 중인 앱에 넘기고 바로 끝낸다
    static func run() -> Never {
        let data = FileHandle.standardInput.readDataToEndOfFile()
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        func str(_ k: String) -> String { (json[k] as? String) ?? "" }
        let env = ProcessInfo.processInfo.environment
        let info: [String: String] = [
            "event": str("hook_event_name"),
            "session": str("session_id"),
            "cwd": str("cwd"),
            "message": str("message"),
            "notificationType": str("notification_type"),
            "tool": str("tool_name"),
            "prompt": String(str("prompt").prefix(120)),
            "terminal": env["__CFBundleIdentifier"] ?? "",
        ]
        DistributedNotificationCenter.default().postNotificationName(
            notification, object: nil, userInfo: info, deliverImmediately: true)
        exit(0)
    }
}

@MainActor
final class ClaudeProvider {
    private let model: NotchModel
    private var lastEvent: [String: Date] = [:]
    private var timer: Timer?

    init(model: NotchModel) {
        self.model = model
        DistributedNotificationCenter.default().addObserver(
            forName: ClaudeHook.notification, object: nil, queue: .main
        ) { [weak self] note in
            let info = note.userInfo as? [String: String] ?? [:]
            MainActor.assumeIsolated { self?.handle(info) }
        }
        model.onOpenSession = { s in
            guard let id = s.terminalBundleID, !id.isEmpty,
                  let app = NSRunningApplication.runningApplications(withBundleIdentifier: id).first else { return }
            app.activate()
        }
        timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.prune() }
        }
    }

    private static let toolNames: [String: String] = [
        "Bash": "명령 실행", "Edit": "파일 수정", "Write": "파일 작성", "Read": "파일 읽기",
        "Grep": "검색", "Glob": "파일 찾기", "WebFetch": "웹 읽기", "WebSearch": "웹 검색",
        "Agent": "에이전트", "Task": "에이전트", "TodoWrite": "할 일 정리",
    ]

    private func handle(_ i: [String: String]) {
        let id = i["session"] ?? ""
        guard !id.isEmpty else { return }
        let project = URL(fileURLWithPath: i["cwd"] ?? "").lastPathComponent
        let existing = model.sessions.first { $0.id == id }
        var s = existing ?? ClaudeSession(id: id, project: project.isEmpty ? "Claude" : project, state: .done)
        if let t = i["terminal"], !t.isEmpty { s.terminalBundleID = t }
        lastEvent[id] = Date()

        switch i["event"] {
        case "UserPromptSubmit":
            s.state = .working
            s.since = Date()
            s.detail = (i["prompt"] ?? "").replacingOccurrences(of: "\n", with: " ")
        case "PreToolUse":
            if s.state != .working { s.state = .working; if existing?.state != .attention { s.since = Date() } }
            let tool = i["tool"] ?? ""
            s.detail = Self.toolNames[tool] ?? tool
        case "Notification":
            let type = i["notificationType"] ?? ""
            let msg = i["message"] ?? ""
            // "입력 기다리는 중" 알림은 작업이 끝난 뒤 반복해서 오므로 무시
            if type == "idle_prompt" || msg.localizedCaseInsensitiveContains("waiting for your input") { return }
            s.state = .attention
            s.detail = msg
            model.show(.claude(title: "확인 필요", project: s.project, detail: msg, mood: .attention), for: 3.5)
        case "Stop":
            let took = Date().timeIntervalSince(s.since)
            let wasBusy = existing?.state == .working || existing?.state == .attention
            s.state = .done
            s.since = Date()
            // 터미널을 보고 있을 땐 짧은 답마다 띄우지 않는다
            let front = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
            if wasBusy, took > 45 || front != s.terminalBundleID {
                let m = Int(took) / 60, sec = Int(took) % 60
                model.show(.claude(title: "작업 완료", project: s.project,
                                   detail: m > 0 ? "\(m)분 \(sec)초 걸림" : "\(sec)초 걸림", mood: .done), for: 3)
            }
            s.detail = ""
        case "SessionEnd":
            model.removeSession(id)
            lastEvent[id] = nil
            return
        default:
            return
        }
        model.upsert(s)
    }

    /// 이벤트가 오래 없는 세션 정리 (터미널을 그냥 닫은 경우 등)
    private func prune() {
        let now = Date()
        for s in model.sessions {
            let idle = now.timeIntervalSince(lastEvent[s.id] ?? s.since)
            if (s.state == .done && idle > 30 * 60) || idle > 3 * 3600 {
                model.removeSession(s.id)
                lastEvent[s.id] = nil
            }
        }
    }
}

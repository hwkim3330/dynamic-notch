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
            "tty": controllingTTY() ?? "",
        ]
        if env["DYNAMICNOTCH_DEBUG"] != nil { FileHandle.standardError.write("\(info)\n".data(using: .utf8)!) }
        DistributedNotificationCenter.default().postNotificationName(
            notification, object: nil, userInfo: info, deliverImmediately: true)
        exit(0)
    }

    /// 상태 줄 모드: Claude Code 가 주는 상태 JSON 에서 구독 한도를 앱으로 넘기고, 짧은 상태 줄을 출력한다
    static func statusLine() -> Never {
        let data = FileHandle.standardInput.readDataToEndOfFile()
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        let rl = json["rate_limits"] as? [String: Any] ?? [:]
        func win(_ k: String) -> (Double, Double)? {
            guard let w = rl[k] as? [String: Any], let p = (w["used_percentage"] as? NSNumber)?.doubleValue else { return nil }
            return (p, (w["resets_at"] as? NSNumber)?.doubleValue ?? 0)
        }
        var info: [String: String] = ["event": "Limits"]
        var parts: [String] = []
        if let m = json["model"] as? [String: Any], let name = m["display_name"] as? String { parts.append(name) }
        if let (p, r) = win("five_hour") {
            info["five"] = String(p); info["fiveReset"] = String(r)
            let left = max(0, r - Date().timeIntervalSince1970)
            parts.append("5h \(Int(p.rounded()))%" + (r > 0 ? " (\(Int(left) / 3600)h\(Int(left) % 3600 / 60)m)" : ""))
        }
        if let (p, r) = win("seven_day") {
            info["week"] = String(p); info["weekReset"] = String(r)
            parts.append("주간 \(Int(p.rounded()))%")
        }
        if info.count > 1 {
            DistributedNotificationCenter.default().postNotificationName(
                notification, object: nil, userInfo: info, deliverImmediately: true)
        }
        print(parts.joined(separator: " · "))
        exit(0)
    }

    /// 훅 프로세스는 stdin 이 파이프라 tty 가 없다. 부모(셸 → claude)를 거슬러 올라가 첫 tty 를 찾는다.
    static func controllingTTY() -> String? {
        var pid = getppid()
        for _ in 0..<6 {
            var info = kinfo_proc()
            var size = MemoryLayout<kinfo_proc>.stride
            var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
            guard sysctl(&mib, 4, &info, &size, nil, 0) == 0, size > 0 else { return nil }
            let dev = info.kp_eproc.e_tdev
            if dev != -1, let name = devname(dev, S_IFCHR) { return "/dev/" + String(cString: name) }
            pid = info.kp_eproc.e_ppid
            if pid <= 1 { return nil }
        }
        return nil
    }
}

/// 세션이 도는 바로 그 터미널 탭으로 이동한다 (창이 여러 개여도)
enum TerminalJump {
    static func go(bundleID: String?, tty: String?) {
        let id = bundleID ?? ""
        if let tty, !tty.isEmpty {
            let script: String? = switch id {
            case "com.apple.Terminal":
                """
                tell application "Terminal"
                  repeat with w in windows
                    repeat with t in tabs of w
                      if tty of t is "\(tty)" then
                        set selected of t to true
                        set index of w to 1
                        activate
                        return
                      end if
                    end repeat
                  end repeat
                end tell
                """
            case "com.googlecode.iterm2":
                """
                tell application "iTerm2"
                  repeat with w in windows
                    repeat with t in tabs of w
                      repeat with s in sessions of t
                        if tty of s is "\(tty)" then
                          select w
                          select t
                          select s
                          activate
                          return
                        end if
                      end repeat
                    end repeat
                  end repeat
                end tell
                """
            default: nil
            }
            if let script {
                DispatchQueue.global().async {
                    var err: NSDictionary?
                    NSAppleScript(source: script)?.executeAndReturnError(&err)
                    if let err { NSLog("DynamicNotch jump: \(err)") }
                }
                return
            }
        }
        // 그 밖의 터미널(Ghostty, VS Code, Codex 앱 등)은 앱만 앞으로
        if let app = NSRunningApplication.runningApplications(withBundleIdentifier: id).first {
            app.activate()
        } else if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) {
            NSWorkspace.shared.openApplication(at: url, configuration: .init())
        }
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
        model.onOpenSession = { s in TerminalJump.go(bundleID: s.terminalBundleID, tty: s.tty) }
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
        if i["event"] == "Limits" { updateLimits(i); return }
        let id = i["session"] ?? ""
        guard !id.isEmpty else { return }
        let project = URL(fileURLWithPath: i["cwd"] ?? "").lastPathComponent
        let existing = model.sessions.first { $0.id == id }
        var s = existing ?? ClaudeSession(id: id, project: project.isEmpty ? "Claude" : project, state: .done)
        if let t = i["terminal"], !t.isEmpty { s.terminalBundleID = t }
        if let t = i["tty"], !t.isEmpty { s.tty = t }
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

    /// 5시간 한도 % 기록 (예측용)
    private var fiveHistory: [(t: Date, pct: Double)] = []

    private func updateLimits(_ i: [String: String]) {
        func d(_ k: String) -> Double? { i[k].flatMap(Double.init) }
        func date(_ k: String) -> Date? { d(k).flatMap { $0 > 0 ? Date(timeIntervalSince1970: $0) : nil } }
        let old = model.limits?.fiveHour ?? 0
        var l = PlanLimits(fiveHour: d("five"), fiveHourResets: date("fiveReset"), week: d("week"), weekResets: date("weekReset"))
        if let p = l.fiveHour {
            // 초기화되면(값이 떨어지면) 기록을 새로 시작
            if let last = fiveHistory.last, p < last.pct - 5 { fiveHistory.removeAll() }
            fiveHistory.append((Date(), p))
            fiveHistory.removeAll { Date().timeIntervalSince($0.t) > 45 * 60 }
            // 최근 45분 기울기로 100% 도달 시각 추정
            if let first = fiveHistory.first, let last = fiveHistory.last,
               last.t.timeIntervalSince(first.t) > 5 * 60, last.pct > first.pct {
                let rate = (last.pct - first.pct) / last.t.timeIntervalSince(first.t)   // %/초
                let hit = Date().addingTimeInterval((100 - last.pct) / rate)
                if let reset = l.fiveHourResets, hit < reset { l.fiveHourHitsAt = hit }
            }
        }
        model.limits = l
        // 80%, 95% 를 처음 넘을 때 한 번 알린다
        if let now = l.fiveHour, let t = [95.0, 80.0].first(where: { now >= $0 && old < $0 }) {
            var detail = ""
            if let r = l.fiveHourResets {
                let m = max(0, Int(r.timeIntervalSinceNow / 60))
                detail = "\(m / 60)시간 \(m % 60)분 후 초기화"
            }
            model.show(.claude(title: "5시간 사용량 \(Int(t))%", project: "", detail: detail, mood: .attention), for: 4)
        }
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

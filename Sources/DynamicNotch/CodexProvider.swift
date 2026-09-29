import AppKit
import NotchKit

/// OpenAI Codex (데스크톱 앱 + CLI) → 노치.
/// Codex 설정(notify)은 이미 다른 도구가 쓰고 있을 수 있어서 건드리지 않고,
/// ~/.codex/sessions/**/rollout-*.jsonl 에 새로 붙는 줄만 읽는다.
@MainActor
final class CodexProvider {
    private let model: NotchModel
    private let root = ProcessInfo.processInfo.environment["DYNAMICNOTCH_CODEX_DIR"].map { URL(fileURLWithPath: $0) }
        ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex/sessions")
    private var offsets: [String: UInt64] = [:]
    private var cwd: [String: String] = [:]
    private var timer: Timer?
    private let started = Date()

    init(model: NotchModel) {
        self.model = model
        scan(initial: true)
        timer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.scan(initial: false) }
        }
    }

    /// 최근 이틀 폴더만 훑는다 (전체 기록은 수 GB가 될 수 있음)
    private func recentFiles() -> [URL] {
        let fm = FileManager.default
        var out: [URL] = []
        let cal = Calendar.current
        for back in 0...1 {
            guard let day = cal.date(byAdding: .day, value: -back, to: Date()) else { continue }
            let c = cal.dateComponents([.year, .month, .day], from: day)
            let dir = root.appendingPathComponent(String(format: "%04d/%02d/%02d", c.year!, c.month!, c.day!))
            let items = (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
            out += items.filter { $0.pathExtension == "jsonl" }
        }
        return out
    }

    private func scan(initial: Bool) {
        for url in recentFiles() {
            let path = url.path
            guard let attrs = try? FileManager.default.attributesOfItem(atPath: path),
                  let size = (attrs[.size] as? NSNumber)?.uint64Value else { continue }
            if offsets[path] == nil {
                // 처음 보는 파일: 이미 있던 내용은 건너뛰되, 앞부분에서 cwd 만 읽는다
                readMeta(path)
                offsets[path] = initial ? size : 0
                if initial { continue }
            }
            let from = offsets[path]!
            guard size > from, let fh = FileHandle(forReadingAtPath: path) else { continue }
            try? fh.seek(toOffset: from)
            let data = fh.readData(ofLength: Int(min(size - from, 4 << 20)))
            try? fh.close()
            // 마지막 줄이 덜 써졌으면 다음 번에 다시 읽는다
            guard let lastNL = data.lastIndex(of: UInt8(ascii: "\n")) else { continue }
            offsets[path] = from + UInt64(lastNL + 1)
            for line in data[..<lastNL].split(separator: UInt8(ascii: "\n")) {
                handle(line: Data(line), path: path)
            }
        }
    }

    private func readMeta(_ path: String) {
        guard let fh = FileHandle(forReadingAtPath: path) else { return }
        let head = fh.readData(ofLength: 64 << 10)
        try? fh.close()
        guard let nl = head.firstIndex(of: UInt8(ascii: "\n")),
              let j = try? JSONSerialization.jsonObject(with: head[..<nl]) as? [String: Any],
              let p = j["payload"] as? [String: Any], let c = p["cwd"] as? String else { return }
        cwd[path] = c
    }

    private func handle(line: Data, path: String) {
        guard let j = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
              let p = j["payload"] as? [String: Any], let type = p["type"] as? String else { return }
        let id = "codex:" + URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent
        let project = URL(fileURLWithPath: cwd[path] ?? "").lastPathComponent
        var s = model.sessions.first { $0.id == id }
            ?? ClaudeSession(id: id, project: project.isEmpty ? "Codex" : project, state: .done,
                             agent: .codex, terminalBundleID: "com.openai.codex")
        switch (j["type"] as? String, type) {
        case ("session_meta", _), ("turn_context", _):
            if let c = p["cwd"] as? String { cwd[path] = c; s.project = URL(fileURLWithPath: c).lastPathComponent }
            return
        case ("event_msg", "task_started"):
            s.state = .working
            s.since = Date()
            s.detail = "작업 중"
        case ("event_msg", let t) where t.hasSuffix("approval_request"):
            s.state = .attention
            s.detail = t.hasPrefix("exec") ? "명령 실행 승인 필요" : "변경 승인 필요"
            model.show(.claude(title: "확인 필요", project: s.project, detail: s.detail, mood: .attention, agent: .codex), for: 3.5)
        case ("event_msg", "task_complete"):
            let took = Date().timeIntervalSince(s.since)
            let msg = (p["last_agent_message"] as? String ?? "")
                .split(separator: "\n").first.map { String($0).replacingOccurrences(of: "*", with: "") } ?? ""
            if s.state != .done {
                model.show(.claude(title: "작업 완료", project: s.project,
                                   detail: msg.isEmpty ? "\(Int(took))초 걸림" : msg, mood: .done, agent: .codex), for: 3.2)
            }
            s.state = .done
            s.since = Date()
            s.detail = msg
        case ("response_item", "function_call"), ("response_item", "custom_tool_call"):
            if s.state != .working { s.state = .working; s.since = Date() }
            s.detail = (p["name"] as? String).map { $0 == "shell" || $0 == "exec_command" ? "명령 실행" : $0 } ?? s.detail
        default:
            return
        }
        model.upsert(s)
    }
}

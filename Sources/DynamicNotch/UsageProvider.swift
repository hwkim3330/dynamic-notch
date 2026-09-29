import Foundation
import NotchKit

/// Claude Code / Codex 토큰 사용량 집계.
/// Claude: ~/.claude/projects/**/*.jsonl 의 assistant 메시지 usage (API 가격으로 환산한 추정치)
/// Codex: ~/.codex/sessions 의 token_count 이벤트
/// 파일이 수백 MB 라서 최근 8일치만, 읽은 위치를 기억해 새로 붙은 줄만 읽는다. 전부 백그라운드 큐.
final class UsageProvider: @unchecked Sendable {
    private weak var model: NotchModel?
    private let queue = DispatchQueue(label: "dynamicnotch.usage", qos: .utility)
    private var timer: DispatchSourceTimer?
    private var offsets: [String: UInt64] = [:]
    /// message.id → 기록 (스트리밍 중 같은 id 가 여러 줄 찍히므로 마지막 것만)
    private var claude: [String: Rec] = [:]
    private var codex: [Rec] = []

    struct Rec { var t: Date; var model: String; var input, output, cacheW5, cacheW1h, cacheR: Double }

    /// $/1M 토큰 (입력, 출력, 캐시 읽기). 캐시 쓰기는 입력의 1.25배(5분) / 2배(1시간).
    static let prices: [(prefix: String, i: Double, o: Double, r: Double)] = [
        ("claude-opus-5-5", 4, 20, 0.20), ("claude-opus-5", 5, 25, 0.5), ("claude-opus-4", 5, 25, 0.5),
        ("claude-fable-5-1", 10, 50, 0.25), ("claude-fable-5", 10, 50, 1.0), ("claude-mythos", 10, 50, 0.25),
        ("claude-sonnet-5", 2, 10, 0.2), ("claude-sonnet-4", 3, 15, 0.3), ("claude-haiku-4", 1, 5, 0.1),
    ]

    static func cost(_ r: Rec) -> Double {
        let p = prices.first { r.model.hasPrefix($0.prefix) } ?? ("", 5, 25, 0.5)
        return (r.input * p.i + r.output * p.o + r.cacheW5 * p.i * 1.25 + r.cacheW1h * p.i * 2 + r.cacheR * p.r) / 1_000_000
    }

    @MainActor init(model: NotchModel) {
        self.model = model
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + 2, repeating: 20)
        t.setEventHandler { [weak self] in self?.refresh() }
        t.resume()
        timer = t
    }

    private let home = FileManager.default.homeDirectoryForCurrentUser
    private let horizon: TimeInterval = 8 * 86400

    private func files(under root: URL) -> [URL] {
        guard let e = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.contentModificationDateKey],
                                                     options: [.skipsHiddenFiles]) else { return [] }
        let cutoff = Date().addingTimeInterval(-horizon)
        var out: [URL] = []
        for case let u as URL in e where u.pathExtension == "jsonl" {
            let m = (try? u.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
            if m > cutoff { out.append(u) }
        }
        return out
    }

    private func readNew(_ url: URL, _ each: (Data) -> Void) {
        let path = url.path
        guard let size = (try? FileManager.default.attributesOfItem(atPath: path)[.size] as? NSNumber)?.uint64Value,
              let fh = FileHandle(forReadingAtPath: path) else { return }
        let from = offsets[path] ?? 0
        guard size > from else { return }
        try? fh.seek(toOffset: from)
        let data = fh.readData(ofLength: Int(size - from))
        try? fh.close()
        guard let last = data.lastIndex(of: 0x0A) else { return }
        offsets[path] = from + UInt64(last + 1)
        for line in data[..<last].split(separator: 0x0A) { each(Data(line)) }
    }

    private static let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]; return f
    }()

    private func refresh() {
        let usageKey = Data("\"usage\"".utf8), tokenKey = Data("token_count".utf8)
        for u in files(under: home.appendingPathComponent(".claude/projects")) {
            readNew(u) { line in
                guard line.range(of: usageKey) != nil,
                      let j = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                      let m = j["message"] as? [String: Any], let us = m["usage"] as? [String: Any],
                      let ts = (j["timestamp"] as? String).flatMap(Self.iso.date) else { return }
                func n(_ k: String) -> Double { (us[k] as? NSNumber)?.doubleValue ?? 0 }
                let cc = us["cache_creation"] as? [String: Any]
                let w1h = (cc?["ephemeral_1h_input_tokens"] as? NSNumber)?.doubleValue ?? 0
                let w5 = (cc?["ephemeral_5m_input_tokens"] as? NSNumber)?.doubleValue ?? (n("cache_creation_input_tokens") - w1h)
                let id = (m["id"] as? String) ?? (j["uuid"] as? String) ?? UUID().uuidString
                claude[id] = Rec(t: ts, model: m["model"] as? String ?? "", input: n("input_tokens"),
                                 output: n("output_tokens"), cacheW5: max(0, w5), cacheW1h: w1h, cacheR: n("cache_read_input_tokens"))
            }
        }
        for u in files(under: home.appendingPathComponent(".codex/sessions")) {
            readNew(u) { line in
                guard line.range(of: tokenKey) != nil,
                      let j = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                      let p = j["payload"] as? [String: Any], p["type"] as? String == "token_count",
                      let info = p["info"] as? [String: Any], let last = info["last_token_usage"] as? [String: Any],
                      let ts = (j["timestamp"] as? String).flatMap(Self.iso.date) else { return }
                func n(_ k: String) -> Double { (last[k] as? NSNumber)?.doubleValue ?? 0 }
                codex.append(Rec(t: ts, model: "codex", input: n("input_tokens") - n("cached_input_tokens"),
                                 output: n("output_tokens"), cacheW5: 0, cacheW1h: 0, cacheR: n("cached_input_tokens")))
            }
        }
        let cutoff = Date().addingTimeInterval(-horizon)
        claude = claude.filter { $0.value.t > cutoff }
        codex.removeAll { $0.t < cutoff }
        publish()
    }

    private func publish() {
        let now = Date()
        let dayStart = Calendar.current.startOfDay(for: now)
        let c = Array(claude.values)
        func sum(_ rs: [Rec]) -> (tokens: Double, cost: Double) {
            (rs.reduce(0) { $0 + $1.input + $1.output + $1.cacheW5 + $1.cacheW1h + $1.cacheR }, rs.reduce(0) { $0 + Self.cost($1) })
        }
        let today = sum(c.filter { $0.t >= dayStart })
        let five = sum(c.filter { now.timeIntervalSince($0.t) < 5 * 3600 })
        let week = sum(c.filter { now.timeIntervalSince($0.t) < 7 * 86400 })
        // 최근 24시간, 1시간 단위 비용 (막대그래프)
        var hourly = [Double](repeating: 0, count: 24)
        for r in c where now.timeIntervalSince(r.t) < 24 * 3600 {
            let h = 23 - Int(now.timeIntervalSince(r.t) / 3600)
            if h >= 0 && h < 24 { hourly[h] += Self.cost(r) }
        }
        var byModel: [String: Double] = [:]
        for r in c where r.t >= dayStart { byModel[Self.short(r.model), default: 0] += Self.cost(r) }
        let codexToday = codex.filter { $0.t >= dayStart }.reduce(0) { $0 + $1.input + $1.output + $1.cacheR }
        let snap = UsageSnapshot(todayCost: today.cost, todayTokens: today.tokens, fiveHourCost: five.cost,
                                 weekCost: week.cost, hourly: hourly,
                                 byModel: byModel.sorted { $0.value > $1.value }.map { ($0.key, $0.value) },
                                 codexTodayTokens: codexToday, updated: now)
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated {
                self?.model?.usage = snap
            }
        }
    }

    static func short(_ raw: String) -> String {
        // 날짜 꼬리(-20251001) 제거
        let id = raw.replacingOccurrences(of: #"-\d{8}$"#, with: "", options: .regularExpression)
        return id.replacingOccurrences(of: "claude-", with: "").replacingOccurrences(of: "-", with: " ").capitalized
            .replacingOccurrences(of: " 5 5", with: " 5.5").replacingOccurrences(of: " 5 1", with: " 5.1")
            .replacingOccurrences(of: " 4 5", with: " 4.5")
    }
}

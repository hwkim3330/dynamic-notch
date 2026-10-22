import AppKit
import CryptoKit
import NotchKit

/// OBS 녹화 상태 — OBS 에 들어 있는 obs-websocket(v5)으로 붙는다.
///
/// OBS 가 켜져 있을 때만 연결하고, 녹화가 시작·정지·일시정지되는 이벤트를 받아
/// 노치에 빨간 점과 녹화 시간을 띄운다. 메뉴에서 녹화를 켜고 끌 수도 있다.
/// 비밀번호와 포트는 OBS 설정 파일에서 읽는다(따로 입력할 필요 없음).
@MainActor
final class OBSProvider: NSObject {
    static let bundleID = "com.obsproject.obs-studio"
    static let configURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/obs-studio/plugin_config/obs-websocket/config.json")

    private let model: NotchModel
    private var timer: Timer?
    private var task: URLSessionWebSocketTask?
    private var identified = false
    private var nextID = 0
    private var pending: [String: ([String: Any]) -> Void] = [:]

    /// 메뉴에 보여줄 상태
    private(set) var connected = false
    var recording: Bool { model.recording != nil }

    init(model: NotchModel) {
        self.model = model
        super.init()
        timer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.poll() }
        }
        timer?.tolerance = 1
        poll()
    }

    struct Config { var enabled: Bool; var port: Int; var password: String?; }

    static func readConfig() -> Config? {
        guard let d = try? Data(contentsOf: configURL),
              let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { return nil }
        let auth = j["auth_required"] as? Bool ?? false
        return Config(enabled: j["server_enabled"] as? Bool ?? false, port: j["server_port"] as? Int ?? 4455,
                      password: auth ? j["server_password"] as? String : nil)
    }

    /// OBS 원격 제어 서버를 켠다. OBS 를 다시 켜야 적용된다.
    static func enableServer() -> Bool {
        guard let d = try? Data(contentsOf: configURL),
              var j = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { return false }
        j["server_enabled"] = true
        guard let out = try? JSONSerialization.data(withJSONObject: j, options: [.prettyPrinted, .sortedKeys]) else { return false }
        return (try? out.write(to: configURL, options: .atomic)) != nil
    }

    var obsRunning: Bool { !NSRunningApplication.runningApplications(withBundleIdentifier: Self.bundleID).isEmpty }

    private func poll() {
        guard obsRunning else {
            if task != nil { disconnect() }
            return
        }
        if task == nil, let c = Self.readConfig(), c.enabled { connect(c) }
    }

    private func connect(_ c: Config) {
        guard let url = URL(string: "ws://127.0.0.1:\(c.port)") else { return }
        let t = URLSession.shared.webSocketTask(with: url, protocols: ["obswebsocket.json"])
        task = t
        identified = false
        t.resume()
        receive(t, password: c.password)
    }

    private func disconnect() {
        task?.cancel(with: .goingAway, reason: nil)
        task = nil; identified = false; connected = false; pending = [:]
        model.recording = nil
    }

    private func receive(_ t: URLSessionWebSocketTask, password: String?) {
        t.receive { [weak self] result in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self, self.task === t else { return }
                    switch result {
                    case .failure:
                        // OBS 가 꺼졌거나 서버가 닫혔다 — 다음 확인 때 다시 붙는다
                        self.disconnect()
                    case .success(let msg):
                        if case .string(let s) = msg, let d = s.data(using: .utf8),
                           let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any] {
                            self.handle(j, password: password)
                        }
                        self.receive(t, password: password)
                    }
                }
            }
        }
    }

    private func send(_ op: Int, _ d: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: ["op": op, "d": d]),
              let s = String(data: data, encoding: .utf8) else { return }
        task?.send(.string(s)) { _ in }
    }

    private func request(_ type: String, _ done: (([String: Any]) -> Void)? = nil) {
        nextID += 1
        let id = "dn\(nextID)"
        if let done { pending[id] = done }
        send(6, ["requestType": type, "requestId": id])
    }

    private func handle(_ j: [String: Any], password: String?) {
        let op = j["op"] as? Int ?? -1
        let d = j["d"] as? [String: Any] ?? [:]
        switch op {
        case 0:   // Hello → Identify (녹화·스트림 이벤트만 구독: Outputs = 1 << 6)
            var ident: [String: Any] = ["rpcVersion": 1, "eventSubscriptions": 1 << 6]
            if let a = d["authentication"] as? [String: Any], let pw = password,
               let ch = a["challenge"] as? String, let salt = a["salt"] as? String {
                let secret = Data(SHA256.hash(data: Data((pw + salt).utf8))).base64EncodedString()
                ident["authentication"] = Data(SHA256.hash(data: Data((secret + ch).utf8))).base64EncodedString()
            }
            send(1, ident)
        case 2:   // Identified
            identified = true; connected = true
            refresh()
        case 5:   // Event
            if d["eventType"] as? String == "RecordStateChanged" { refresh() }
        case 7:   // RequestResponse
            if let id = d["requestId"] as? String, let cb = pending.removeValue(forKey: id) {
                cb(d["responseData"] as? [String: Any] ?? [:])
            }
        default: break
        }
    }

    /// 현재 녹화 상태를 물어 노치에 반영한다. 녹화 시간은 OBS 가 세는 값(일시정지 제외)을 쓴다.
    private func refresh() {
        request("GetRecordStatus") { [weak self] r in
            guard let self else { return }
            guard r["outputActive"] as? Bool == true else { self.model.recording = nil; return }
            let paused = r["outputPaused"] as? Bool ?? false
            let dur = (r["outputDuration"] as? Double ?? 0) / 1000
            self.model.recording = Recording(since: Date().addingTimeInterval(-dur), paused: paused, frozen: dur)
        }
    }

    func toggleRecord() { if identified { request("ToggleRecord") } }
    func togglePause() { if identified { request("ToggleRecordPause") } }
}

import SwiftUI

public struct NowPlaying: Equatable {
    public var title: String
    public var artist: String
    public var album: String
    public var source: String
    public var isPlaying: Bool
    public var duration: TimeInterval
    public var elapsed: TimeInterval
    public var elapsedAt: Date
    public var artwork: CGImage?
    public var artworkKey: String
    public var tint: Color

    public init(title: String, artist: String, album: String = "", source: String,
                isPlaying: Bool, duration: TimeInterval = 0, elapsed: TimeInterval = 0,
                elapsedAt: Date = Date(), artwork: CGImage? = nil, artworkKey: String = "",
                tint: Color = .white) {
        self.title = title; self.artist = artist; self.album = album; self.source = source
        self.isPlaying = isPlaying; self.duration = duration; self.elapsed = elapsed
        self.elapsedAt = elapsedAt; self.artwork = artwork; self.artworkKey = artworkKey
        self.tint = tint
    }

    public var trackKey: String { "\(source)|\(title)|\(artist)|\(album)" }

    public func position(at date: Date) -> TimeInterval {
        guard isPlaying else { return elapsed }
        let p = elapsed + date.timeIntervalSince(elapsedAt)
        return duration > 0 ? min(duration, p) : p
    }

    public static func == (a: NowPlaying, b: NowPlaying) -> Bool {
        a.trackKey == b.trackKey && a.isPlaying == b.isPlaying && a.duration == b.duration
            && a.elapsed == b.elapsed && a.elapsedAt == b.elapsedAt
            && a.artworkKey == b.artworkKey && a.tint == b.tint
    }
}

public enum AgentKind: String, Equatable {
    case claude, codex
    public var name: String { self == .claude ? "Claude Code" : "Codex" }
}

/// 코딩 에이전트 세션 하나 (Claude Code 훅 / Codex 세션 로그로 갱신)
public struct ClaudeSession: Equatable, Identifiable {
    public enum State: Equatable { case working, attention, done }
    public var id: String
    public var project: String
    public var state: State
    public var since: Date
    public var detail: String
    public var agent: AgentKind
    public var terminalBundleID: String?
    /// 세션이 도는 터미널 탭의 tty (/dev/ttys003) — 여러 창 중 정확한 탭으로 이동할 때 씀
    public var tty: String?

    public init(id: String, project: String, state: State, since: Date = Date(),
                detail: String = "", agent: AgentKind = .claude,
                terminalBundleID: String? = nil, tty: String? = nil) {
        self.id = id; self.project = project; self.state = state; self.since = since
        self.detail = detail; self.agent = agent; self.terminalBundleID = terminalBundleID; self.tty = tty
    }

    public var mood: ClawdMood {
        switch state {
        case .working: .working
        case .attention: .attention
        case .done: .idle
        }
    }
}

public enum Transient: Equatable {
    case battery(level: Int, pluggedIn: Bool)
    case unlock(success: Bool)
    case faceID(success: Bool)
    case claude(title: String, project: String, detail: String, mood: ClawdMood, agent: AgentKind = .claude)
    case sensor(camera: Bool, on: Bool)
    case download(name: String, path: String)
    case remote(on: Bool)

    var kind: String {
        switch self {
        case .battery: "battery"
        case .unlock: "unlock"
        case .faceID: "faceid"
        case .claude: "claude"
        case .sensor: "sensor"
        case .download: "download"
        case .remote: "remote"
        }
    }
}

/// 구독 한도 (Claude Code 상태 줄 입력에서 받음). 퍼센트는 0...100
public struct PlanLimits: Equatable {
    public var fiveHour: Double?
    public var fiveHourResets: Date?
    public var week: Double?
    public var weekResets: Date?
    /// 지금 속도로 5시간 한도 100%에 닿는 예상 시각 (초기화 전에 닿을 때만)
    public var fiveHourHitsAt: Date?
    public var updated: Date
    public init(fiveHour: Double?, fiveHourResets: Date?, week: Double?, weekResets: Date?, updated: Date = Date()) {
        self.fiveHour = fiveHour; self.fiveHourResets = fiveHourResets
        self.week = week; self.weekResets = weekResets; self.updated = updated
    }
}

/// 사용량 요약 (API 가격으로 환산한 추정치)
public struct UsageSnapshot: Equatable {
    public var todayCost: Double
    public var todayTokens: Double
    public var fiveHourCost: Double
    public var weekCost: Double
    public var hourly: [Double]
    public var byModel: [(String, Double)]
    public var codexTodayTokens: Double
    public var updated: Date
    public var limits: PlanLimits?

    public init(todayCost: Double, todayTokens: Double, fiveHourCost: Double, weekCost: Double, hourly: [Double],
                byModel: [(String, Double)], codexTodayTokens: Double, updated: Date, limits: PlanLimits? = nil) {
        self.todayCost = todayCost; self.todayTokens = todayTokens; self.fiveHourCost = fiveHourCost
        self.weekCost = weekCost; self.hourly = hourly; self.byModel = byModel
        self.codexTodayTokens = codexTodayTokens; self.updated = updated; self.limits = limits
    }

    public static func == (a: UsageSnapshot, b: UsageSnapshot) -> Bool {
        a.updated == b.updated && a.limits == b.limits && a.todayCost == b.todayCost
    }
}

public enum CallState: Equatable {
    case ringing(name: String, subtitle: String)
    case active(name: String, since: Date)
}

public enum NotchTab: String, CaseIterable {
    case claude, usage, camera, music
    var symbol: String {
        switch self {
        case .claude: "sparkle"
        case .usage: "chart.bar.fill"
        case .camera: "camera.fill"
        case .music: "music.note"
        }
    }
    var title: String {
        switch self {
        case .claude: "에이전트"
        case .usage: "사용량"
        case .camera: "미러"
        case .music: "음악"
        }
    }
}

/// 노치가 지금 무엇을 보여주는지. 우선순위는 `NotchModel.content` 참고.
public enum NotchContent: Equatable {
    case idle
    case peek
    case musicCompact
    case claudeCompact
    case callCompact
    case callRinging
    case transient(Transient)
    case expanded(NotchTab)

    /// 뷰 전환(블러 페이드)의 기준. 값만 바뀌면 같은 뷰를 유지한다.
    var kind: String {
        switch self {
        case .transient(let t): "t." + t.kind
        case .expanded: "expanded"
        default: "\(self)"
        }
    }
}

@MainActor
public protocol NotchControls: AnyObject {
    func playPause()
    func nextTrack()
    func previousTrack()
}

@MainActor
public final class NotchModel: ObservableObject {
    /// 물리 노치 크기(pt). 노치 없는 화면이면 가상의 노치.
    @Published public var notchSize = CGSize(width: 185, height: 32)
    /// 실제 노치가 있는 화면인지. 없으면 평소엔 숨어 있다가 알림이 올 때만 위에서 내려온다.
    @Published public var hasPhysicalNotch = true
    @Published public var nowPlaying: NowPlaying?
    @Published public var demoNowPlaying: NowPlaying?
    @Published public var call: CallState?
    @Published public var sessions: [ClaudeSession] = []
    @Published public var tab: NotchTab = .claude
    @Published public var usage: UsageSnapshot?
    @Published public var limits: PlanLimits?
    @Published public private(set) var transient: Transient?
    @Published public private(set) var expanded = false
    @Published public private(set) var peeking = false
    /// 전체 화면 앱(영상 등)을 볼 땐 계속 떠 있는 컴팩트 표시를 숨긴다. 잠깐 뜨는 알림은 그대로.
    @Published public var quietForFullscreen = false
    public var onRevealFile: ((String) -> Void)?

    public weak var controls: NotchControls?
    /// 펼쳐질 때 (햅틱, 재생 위치 새로고침 등)
    public var onExpand: (() -> Void)?
    /// 세션 행을 누르면 그 세션의 터미널로 이동
    public var onOpenSession: ((ClaudeSession) -> Void)?
    /// 카메라 미러 뷰 (플랫폼별로 주입; macOS는 AVCaptureVideoPreviewLayer)
    public var cameraView: (() -> AnyView)?

    private var transientTask: Task<Void, Never>?
    private var hoverTask: Task<Void, Never>?
    private var hovering = false

    public init() {}

    public var media: NowPlaying? { demoNowPlaying ?? nowPlaying }

    /// 노치에 요약해서 보여줄 세션: 확인 필요 > 작업 중
    public var headlineSession: ClaudeSession? {
        sessions.first { $0.state == .attention } ?? sessions.first { $0.state == .working }
    }

    public var clawdMood: ClawdMood {
        if let s = headlineSession { return s.mood }
        return sessions.isEmpty ? .sleeping : .idle
    }

    public var availableTabs: [NotchTab] {
        media != nil ? [.claude, .usage, .music, .camera] : [.claude, .usage, .camera]
    }

    public var content: NotchContent {
        if case .ringing = call { return .callRinging }
        if let t = transient { return .transient(t) }
        if expanded { return .expanded(availableTabs.contains(tab) ? tab : .claude) }
        if quietForFullscreen { return peeking ? .peek : .idle }
        if case .active = call { return .callCompact }
        if headlineSession != nil { return .claudeCompact }
        if media?.isPlaying == true { return .musicCompact }
        if peeking { return .peek }
        return .idle
    }

    public struct Layout: Equatable {
        public var size: CGSize
        public var topRadius: CGFloat
        public var bottomRadius: CGFloat
        /// 위쪽 귀까지 포함한 전체 모양 크기
        public var outerSize: CGSize { CGSize(width: size.width + 2 * topRadius, height: size.height) }
    }

    public func layout(for c: NotchContent) -> Layout {
        let n = notchSize
        let wide = max(n.width + 250, 470)
        switch c {
        case .idle:
            return Layout(size: n, topRadius: 6, bottomRadius: 11)
        case .peek:
            return Layout(size: CGSize(width: n.width + 2 * 44, height: n.height), topRadius: 8, bottomRadius: 14)
        case .musicCompact:
            return Layout(size: CGSize(width: n.width + 2 * (n.height + 14), height: n.height), topRadius: 8, bottomRadius: 14)
        case .claudeCompact, .callCompact:
            return Layout(size: CGSize(width: n.width + 2 * 74, height: n.height), topRadius: 8, bottomRadius: 14)
        case .transient(let t):
            switch t {
            case .battery, .sensor, .remote:
                return Layout(size: CGSize(width: n.width + 2 * 86, height: n.height), topRadius: 8, bottomRadius: 14)
            case .unlock, .faceID:
                return Layout(size: CGSize(width: n.width + 24, height: n.height + 56), topRadius: 8, bottomRadius: 26)
            case .claude, .download:
                return Layout(size: CGSize(width: max(n.width + 200, 390), height: n.height + 60), topRadius: 10, bottomRadius: 28)

            }
        case .callRinging:
            return Layout(size: CGSize(width: max(n.width + 220, 420), height: n.height + 62), topRadius: 10, bottomRadius: 30)
        case .expanded(let tab):
            switch tab {
            case .claude:
                let rows = CGFloat(min(3, max(1, sessions.count)))
                return Layout(size: CGSize(width: wide, height: n.height + 36 + rows * 34), topRadius: 12, bottomRadius: 30)
            case .camera:
                return Layout(size: CGSize(width: wide, height: n.height + 206), topRadius: 12, bottomRadius: 32)
            case .usage:
                return Layout(size: CGSize(width: wide, height: n.height + 132), topRadius: 12, bottomRadius: 30)
            case .music:
                return Layout(size: CGSize(width: wide, height: n.height + 142), topRadius: 12, bottomRadius: 32)
            }
        }
    }

    public var currentLayout: Layout { layout(for: content) }

    // MARK: - 이벤트

    public func show(_ t: Transient, for seconds: Double = 2.0) {
        transient = t
        transientTask?.cancel()
        transientTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            guard !Task.isCancelled else { return }
            self?.transient = nil
        }
    }

    public func dismissTransient() {
        transientTask?.cancel()
        transient = nil
    }

    /// 잠금 → 열림 (맥 잠금 해제)
    public func playUnlock() {
        show(.unlock(success: false), for: 2.2)
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 450_000_000)
            if case .unlock = self?.transient { self?.transient = .unlock(success: true) }
        }
    }

    /// Face ID 스캔 → 성공 (영상 속 그 장면)
    public func playFaceID() {
        show(.faceID(success: false), for: 2.4)
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 900_000_000)
            if case .faceID = self?.transient { self?.transient = .faceID(success: true) }
        }
    }

    public func acceptCall() {
        if case .ringing(let name, _) = call { call = .active(name: name, since: Date()) }
    }

    public func endCall() { call = nil }

    /// 호버: 활동 중이면 펼치고, 아무것도 없으면 살짝 삐져나오기만 한다 (클릭해야 펼침).
    /// 화면 위쪽 가운데로 마우스를 옮길 때마다 큰 판이 튀어나와 가리지 않게 하기 위함.
    public func setHover(_ h: Bool) {
        guard h != hovering else { return }
        hovering = h
        hoverTask?.cancel()
        hoverTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: h ? 150_000_000 : 380_000_000)
            guard let self, !Task.isCancelled else { return }
            if h {
                switch self.content {
                case .musicCompact, .claudeCompact, .callCompact: self.open(nil)
                case .idle: self.peeking = true
                default: break
                }
            } else {
                self.peeking = false
                self.expanded = false
            }
        }
    }

    public func open(_ tab: NotchTab?) {
        hoverTask?.cancel()
        peeking = false
        if let tab { self.tab = tab }
        else if headlineSession != nil { self.tab = .claude }
        else if media?.isPlaying == true { self.tab = .music }
        else if self.tab == .camera || !availableTabs.contains(self.tab) { self.tab = .claude }
        guard !expanded else { return }
        expanded = true
        onExpand?()
    }

    public func collapse() {
        hoverTask?.cancel()
        expanded = false
        peeking = false
    }

    // MARK: - Claude Code

    public func upsert(_ s: ClaudeSession) {
        if let i = sessions.firstIndex(where: { $0.id == s.id }) { sessions[i] = s } else { sessions.append(s) }
    }

    public func removeSession(_ id: String) { sessions.removeAll { $0.id == id } }
}

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

public enum Transient: Equatable {
    case volume(level: Double, muted: Bool)
    case battery(level: Int, charging: Bool, pluggedIn: Bool)
    case unlock(success: Bool)
    case faceID(success: Bool)
    case device(name: String, symbol: String, connected: Bool)

    var kind: String {
        switch self {
        case .volume: "volume"
        case .battery: "battery"
        case .unlock: "unlock"
        case .faceID: "faceid"
        case .device: "device"
        }
    }
}

public enum CallState: Equatable {
    case ringing(name: String, subtitle: String)
    case active(name: String, since: Date)
}

public struct BatteryInfo: Equatable {
    public var level: Int
    public var charging: Bool
    public var pluggedIn: Bool
    public init(level: Int, charging: Bool, pluggedIn: Bool) {
        self.level = level; self.charging = charging; self.pluggedIn = pluggedIn
    }
}

/// 노치가 지금 무엇을 보여주는지. 우선순위는 `NotchModel.content` 참고.
public enum NotchContent: Equatable {
    case idle
    case musicCompact
    case callCompact
    case callRinging
    case transient(Transient)
    case expandedMusic
    case expandedHome

    /// 뷰 전환(블러 페이드)의 기준. 값만 바뀌면 같은 뷰를 유지한다.
    var kind: String {
        switch self {
        case .transient(let t): "t." + t.kind
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
    @Published public var nowPlaying: NowPlaying?
    @Published public var demoNowPlaying: NowPlaying?
    @Published public var call: CallState?
    @Published public var battery: BatteryInfo?
    @Published public var volume: Double = 0.5
    @Published public private(set) var transient: Transient?
    @Published public private(set) var expanded = false

    public weak var controls: NotchControls?
    /// 호버로 펼쳐질 때 (햅틱, 재생 위치 새로고침 등)
    public var onExpand: (() -> Void)?

    private var transientTask: Task<Void, Never>?
    private var hoverTask: Task<Void, Never>?
    private var hovering = false

    public init() {}

    public var media: NowPlaying? { demoNowPlaying ?? nowPlaying }

    public var content: NotchContent {
        if case .ringing = call { return .callRinging }
        if let t = transient { return .transient(t) }
        if expanded { return media != nil ? .expandedMusic : .expandedHome }
        if case .active = call { return .callCompact }
        if media?.isPlaying == true { return .musicCompact }
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
        let side = n.height + 14
        let wide = max(n.width + 250, 470)
        switch c {
        case .idle:
            return Layout(size: n, topRadius: 6, bottomRadius: 11)
        case .musicCompact:
            return Layout(size: CGSize(width: n.width + 2 * side, height: n.height), topRadius: 8, bottomRadius: 14)
        case .callCompact:
            return Layout(size: CGSize(width: n.width + 2 * 74, height: n.height), topRadius: 8, bottomRadius: 14)
        case .transient(let t):
            switch t {
            case .volume, .battery:
                return Layout(size: CGSize(width: n.width + 2 * 86, height: n.height), topRadius: 8, bottomRadius: 14)
            case .unlock, .faceID:
                return Layout(size: CGSize(width: n.width + 24, height: n.height + 56), topRadius: 8, bottomRadius: 26)
            case .device:
                return Layout(size: CGSize(width: max(n.width + 150, 330), height: n.height + 54), topRadius: 10, bottomRadius: 26)
            }
        case .callRinging:
            return Layout(size: CGSize(width: max(n.width + 220, 420), height: n.height + 62), topRadius: 10, bottomRadius: 30)
        case .expandedMusic:
            return Layout(size: CGSize(width: wide, height: n.height + 142), topRadius: 12, bottomRadius: 32)
        case .expandedHome:
            return Layout(size: CGSize(width: wide, height: n.height + 84), topRadius: 12, bottomRadius: 30)
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

    public func setHover(_ h: Bool) {
        guard h != hovering else { return }
        hovering = h
        hoverTask?.cancel()
        hoverTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: h ? 110_000_000 : 380_000_000)
            guard let self, !Task.isCancelled, self.expanded != h else { return }
            self.expanded = h
            if h { self.onExpand?() }
        }
    }

    public func setExpanded(_ e: Bool) {
        hoverTask?.cancel()
        guard expanded != e else { return }
        expanded = e
        if e { onExpand?() }
    }
}

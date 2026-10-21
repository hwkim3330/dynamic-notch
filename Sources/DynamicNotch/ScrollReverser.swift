import AppKit
import ApplicationServices

/// 스크롤 방향 뒤집기 — Scroll Reverser 를 따로 띄우지 않아도 되게.
///
/// 스크롤 이벤트를 세션 이벤트 탭에서 가로채, 트랙패드(연속 스크롤)인지
/// 마우스 휠(끊어지는 스크롤)인지 보고 축별로 부호만 바꾼다.
/// 손쉬운 사용(접근성) 권한이 있어야 이벤트 탭을 만들 수 있다.
///
/// 기본값은 기존 Scroll Reverser 설정을 그대로 옮긴 것이다:
/// 트랙패드 세로만 뒤집고, 마우스와 가로 방향은 그대로 둔다.
@MainActor
final class ScrollReverser {
    static let shared = ScrollReverser()

    enum Key: String, CaseIterable {
        case enabled = "scroll.enabled"
        case trackpadVertical = "scroll.trackpad.vertical"
        case trackpadHorizontal = "scroll.trackpad.horizontal"
        case mouseVertical = "scroll.mouse.vertical"
        case mouseHorizontal = "scroll.mouse.horizontal"

        var title: String {
            switch self {
            case .enabled: "스크롤 뒤집기 켜기"
            case .trackpadVertical: "트랙패드 · 세로"
            case .trackpadHorizontal: "트랙패드 · 가로"
            case .mouseVertical: "마우스 · 세로"
            case .mouseHorizontal: "마우스 · 가로"
            }
        }
    }

    private let defaults = UserDefaults.standard
    private var tap: CFMachPort?
    private var prompted = false
    private var source: CFRunLoopSource?

    private init() {
        defaults.register(defaults: [
            Key.enabled.rawValue: true,
            Key.trackpadVertical.rawValue: true,
            Key.trackpadHorizontal.rawValue: false,
            Key.mouseVertical.rawValue: false,
            Key.mouseHorizontal.rawValue: false,
        ])
    }

    func isOn(_ k: Key) -> Bool { defaults.bool(forKey: k.rawValue) }

    func toggle(_ k: Key) {
        defaults.set(!isOn(k), forKey: k.rawValue)
        Flags.store(self)
        // 탭은 마우스 기능도 같이 쓰므로 끄지 않는다. 뒤집기 여부는 깃발로만 바꾼다.
    }

    /// 권한이 있으면 탭을 건다. 없으면 시스템 권한 창을 띄우고, 허용될 때까지 몇 초마다 다시 본다.
    func start() {
        Flags.store(self)
        guard tap == nil else { return }
        // 권한 요청 창은 처음 한 번만. 그 뒤엔 허용될 때까지 조용히 확인만 한다.
        // (매번 창을 띄우면 허용한 뒤에도 몇 초마다 다시 떴다.)
        let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: !prompted] as CFDictionary
        prompted = true
        let trusted = AXIsProcessTrustedWithOptions(opts)
        ScrollDebug.note("trusted=\(trusted) bundle=\(Bundle.main.bundlePath)")
        guard trusted else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in self?.start() }
            return
        }
        let mask = CGEventMask(1 << CGEventType.scrollWheel.rawValue)
            | CGEventMask(1 << CGEventType.otherMouseDown.rawValue)
            | CGEventMask(1 << CGEventType.otherMouseUp.rawValue)
        guard let t = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap,
                                        options: .defaultTap, eventsOfInterest: mask,
                                        callback: scrollCallback, userInfo: nil) else {
            NSLog("DynamicNotch: 스크롤 이벤트 탭 생성 실패")
            ScrollDebug.note("tapCreate 실패")
            return
        }
        ScrollDebug.note("tap 생성됨")
        tap = t
        Flags.tap = t
        source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, t, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: t, enable: true)
    }

    func stop() {
        if let t = tap { CGEvent.tapEnable(tap: t, enable: false) }
        if let s = source { CFRunLoopRemoveSource(CFRunLoopGetMain(), s, .commonModes) }
        tap = nil; source = nil; Flags.tap = nil
    }
}

/// 이벤트 탭 콜백은 C 함수라 액터 밖에서 불린다. 읽기 전용 깃발만 여기 둔다.
enum Flags {
    nonisolated(unsafe) static var tpV = true, tpH = false, msV = false, msH = false
    nonisolated(unsafe) static var tap: CFMachPort?

    @MainActor static func store(_ r: ScrollReverser) {
        let on = r.isOn(.enabled)
        tpV = on && r.isOn(.trackpadVertical); tpH = on && r.isOn(.trackpadHorizontal)
        msV = on && r.isOn(.mouseVertical); msH = on && r.isOn(.mouseHorizontal)
        MouseFlags.reverseV = msV; MouseFlags.reverseH = msH   // 부드러운 휠은 보낼 때 뒤집는다
    }
}

private func scrollCallback(proxy: CGEventTapProxy, type: CGEventType, event: CGEvent,
                            userInfo: UnsafeMutableRawPointer?) -> Unmanaged<CGEvent>? {
    // 시스템이 탭을 꺼버리는 경우(응답이 늦었거나 사용자 입력)가 있다. 바로 다시 켠다.
    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
        if let t = Flags.tap { CGEvent.tapEnable(tap: t, enable: true) }
        return Unmanaged.passUnretained(event)
    }
    // 우리가 만들어 보낸 이벤트(부드러운 휠, 단축키)는 이미 처리된 것이다
    if event.getIntegerValueField(.eventSourceUserData) == MouseFlags.marker {
        return Unmanaged.passUnretained(event)
    }
    // 다른 프로그램이 만든 이벤트(화면 공유, Universal Control, Deskflow, RustDesk …)는 그대로 통과.
    // 실제 장치 이벤트는 보낸 프로세스가 0 이다 — 진단 기록으로 확인함(트랙패드 30개 전부 pid=0).
    // 원격 쪽 이벤트까지 뒤집으면 상대 기기의 설정 위에 한 번 더 뒤집혀 방향이 꼬인다.
    if event.getIntegerValueField(.eventSourceUnixProcessID) != 0 {
        return Unmanaged.passUnretained(event)
    }
    if type == .otherMouseDown || type == .otherMouseUp { return handleMouse(type: type, event: event) }
    guard type == .scrollWheel else { return Unmanaged.passUnretained(event) }

    // 트랙패드·매직마우스는 연속 스크롤, 일반 마우스 휠은 끊어지는 스크롤이다
    let continuous = event.getIntegerValueField(.scrollWheelEventIsContinuous) != 0
    if !continuous && MouseFlags.smooth {
        return handleMouse(type: type, event: event)       // 부드러운 휠이 뒤집기까지 맡는다
    }
    let flipV = continuous ? Flags.tpV : Flags.msV
    let flipH = continuous ? Flags.tpH : Flags.msH
    if flipV { flip(event, .scrollWheelEventDeltaAxis1, .scrollWheelEventPointDeltaAxis1, .scrollWheelEventFixedPtDeltaAxis1) }
    if flipH { flip(event, .scrollWheelEventDeltaAxis2, .scrollWheelEventPointDeltaAxis2, .scrollWheelEventFixedPtDeltaAxis2) }
    return continuous ? Unmanaged.passUnretained(event) : handleMouse(type: type, event: event)
}

/// 같은 움직임이 세 가지 단위로 들어 있다. 하나만 바꾸면 앱마다 다르게 반응하니 셋 다 뒤집는다.
///
/// 순서가 중요하다(Scroll Reverser 의 MouseTap.m 에서 확인): 줄 단위(DeltaAxis)를 쓰면
/// macOS 가 픽셀(8배)·고정소수점(1배) 값을 그 자리에서 다시 계산한다. 그래서
///   1) 세 값을 먼저 다 읽고  2) 줄 → 고정소수점 → 픽셀 순서로 쓴다.
/// 처음엔 줄 값을 바꾼 뒤에 픽셀 값을 읽어 뒤집었는데, 그건 이미 다시 계산된 값이라
/// 두 번 뒤집혀 원래 방향으로 돌아갔다.
private func flip(_ e: CGEvent, _ line: CGEventField, _ point: CGEventField, _ fixed: CGEventField) {
    let l = e.getIntegerValueField(line), p = e.getIntegerValueField(point), f = e.getDoubleValueField(fixed)
    e.setIntegerValueField(line, value: -l)
    e.setDoubleValueField(fixed, value: -f)
    e.setIntegerValueField(point, value: -p)
}


/// 진단용 — 처음 30개 스크롤 이벤트의 필드를 파일에 남긴다(~/Library/Logs/DynamicNotch-scroll.log).
enum ScrollDebug {
    nonisolated(unsafe) static var n = 0
    nonisolated(unsafe) static var lastNote = ""
    static func note(_ s: String) {
        guard s != lastNote else { return }          // 같은 상태는 한 번만
        lastNote = s
        write("[\(Date())] \(s)\n")
    }
    static func write(_ line: String) {
        let url = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/DynamicNotch-scroll.log")
        if let h = try? FileHandle(forWritingTo: url) { h.seekToEndOfFile(); h.write(line.data(using: .utf8)!); try? h.close() }
        else { try? line.write(to: url, atomically: true, encoding: .utf8) }
    }
    static func log(_ type: CGEventType, _ e: CGEvent) {
        guard type == .scrollWheel, n < 30 else { return }
        n += 1
        let line = "pid=\(e.getIntegerValueField(.eventSourceUnixProcessID)) "
            + "state=\(e.getIntegerValueField(.eventSourceStateID)) "
            + "cont=\(e.getIntegerValueField(.scrollWheelEventIsContinuous)) "
            + "user=\(e.getIntegerValueField(.eventSourceUserData)) "
            + "dy=\(e.getIntegerValueField(.scrollWheelEventPointDeltaAxis1)) "
            + "phase=\(e.getIntegerValueField(.scrollWheelEventScrollPhase))/\(e.getIntegerValueField(.scrollWheelEventMomentumPhase))\n"
        write(line)
    }
}

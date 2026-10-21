import AppKit
import CoreGraphics

/// 마우스 기능 — Logi Options+ 대신.
///
/// 로지텍 Lift 기준(엄지 버튼 둘 + 휠 + 휠 아래 버튼)이지만 어느 마우스든 같다.
///   · 엄지 버튼(3·4번)  → 뒤로 / 앞으로 (⌘[ / ⌘]) — 앱마다 다르게 먹던 걸 통일
///   · 휠 속도          → 기본 0.5배 (Logi Options+ 에서 쓰던 '느리게'에 맞춤)
///   · 부드러운 휠      → 한 칸을 짧게 나눠 픽셀 단위로 흘려보낸다 (트랙패드 느낌)
///   · Shift + 휠       → 가로 스크롤 (Logi 의 '가상 엄지 휠' 대신)
///
/// 트랙패드(연속 스크롤)는 건드리지 않는다. 우리가 만들어 보낸 이벤트에는 표식을 달아
/// 이벤트 탭이 자기 이벤트를 다시 처리하지 않게 한다.
@MainActor
final class MouseTools {
    static let shared = MouseTools()

    enum Key: String, CaseIterable {
        case buttons = "mouse.buttons"
        case smooth = "mouse.smooth"
        case shiftHorizontal = "mouse.shiftHorizontal"
        var title: String {
            switch self {
            case .buttons: "엄지 버튼 → 뒤로/앞으로"
            case .smooth: "부드러운 휠 스크롤"
            case .shiftHorizontal: "Shift + 휠 = 가로 스크롤"
            }
        }
    }
    static let speeds: [(String, Double)] = [("느리게", 0.5), ("보통", 1.0), ("빠르게", 2.0)]

    private let d = UserDefaults.standard
    private var timer: Timer?

    private init() {
        d.register(defaults: [Key.buttons.rawValue: true, Key.smooth.rawValue: true,
                              Key.shiftHorizontal.rawValue: true, "mouse.speed": 0.5])
        sync()
    }

    func isOn(_ k: Key) -> Bool { d.bool(forKey: k.rawValue) }
    func toggle(_ k: Key) { d.set(!isOn(k), forKey: k.rawValue); sync() }
    var speed: Double { d.double(forKey: "mouse.speed") }
    func setSpeed(_ v: Double) { d.set(v, forKey: "mouse.speed"); sync() }

    private func sync() {
        MouseFlags.buttons = isOn(.buttons); MouseFlags.smooth = isOn(.smooth)
        MouseFlags.shiftH = isOn(.shiftHorizontal); MouseFlags.speed = speed
    }

    /// 부드러운 스크롤 — 남은 거리를 매 프레임 일정 비율씩 흘려보낸다.
    func kick() {
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 1 / 120, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.step() }
        }
    }

    private func step() {
        var (dy, dx) = MouseFlags.takeStep()
        if dy == 0 && dx == 0 { timer?.invalidate(); timer = nil; return }
        if MouseFlags.reverseV { dy = -dy }
        if MouseFlags.reverseH { dx = -dx }
        guard let e = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2,
                              wheel1: Int32(dy), wheel2: Int32(dx), wheel3: 0) else { return }
        e.setIntegerValueField(.eventSourceUserData, value: MouseFlags.marker)
        e.post(tap: .cgSessionEventTap)
    }
}

/// 이벤트 탭(C 콜백)에서 읽는 값들. 메인 스레드에서만 쓰고 읽는다(탭은 메인 런루프에 붙어 있다).
enum MouseFlags {
    nonisolated(unsafe) static var buttons = true, smooth = true, shiftH = true, speed = 0.5
    nonisolated(unsafe) static var reverseV = false, reverseH = false   // 마우스 뒤집기 설정 (부드러운 스크롤용)
    static let marker: Int64 = 0x4E6F_7463_68     // "Notch" — 우리가 보낸 이벤트 표식
    nonisolated(unsafe) static var pendY = 0.0, pendX = 0.0

    /// 남은 거리의 22%씩 — 짧고 매끄럽게 멈춘다
    static func takeStep() -> (Double, Double) {
        func part(_ v: inout Double) -> Double {
            if abs(v) < 0.5 { let r = v.rounded(); v = 0; return r }
            let s = (v * 0.22).rounded(v > 0 ? .up : .down); v -= s; return s
        }
        return (part(&pendY), part(&pendX))
    }
}

/// 마우스 쪽 처리. 처리했으면 nil 을 돌려 원래 이벤트를 버리고, 아니면 이벤트를 그대로 넘긴다.
func handleMouse(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
    // 엄지 버튼: 3번=뒤로, 4번=앞으로 (0=왼쪽, 1=오른쪽, 2=가운데)
    if type == .otherMouseDown || type == .otherMouseUp {
        let b = event.getIntegerValueField(.mouseEventButtonNumber)
        guard MouseFlags.buttons, b == 3 || b == 4 else { return Unmanaged.passUnretained(event) }
        if type == .otherMouseDown { sendKey(b == 3 ? 33 : 30, cmd: true) }   // 33='[', 30=']'
        return nil
    }
    guard type == .scrollWheel,
          event.getIntegerValueField(.eventSourceUserData) != MouseFlags.marker,
          event.getIntegerValueField(.scrollWheelEventIsContinuous) == 0     // 마우스 휠만
    else { return Unmanaged.passUnretained(event) }

    var dy = Double(event.getIntegerValueField(.scrollWheelEventDeltaAxis1))
    var dx = Double(event.getIntegerValueField(.scrollWheelEventDeltaAxis2))
    if MouseFlags.shiftH && event.flags.contains(.maskShift) && dx == 0 { dx = dy; dy = 0 }
    if !MouseFlags.smooth {
        // 속도만 바꿔서 보낸다
        if MouseFlags.speed == 1 && !(MouseFlags.shiftH && event.flags.contains(.maskShift)) {
            return Unmanaged.passUnretained(event)
        }
        event.setIntegerValueField(.scrollWheelEventDeltaAxis1, value: Int64((dy * MouseFlags.speed).rounded()))
        event.setIntegerValueField(.scrollWheelEventDeltaAxis2, value: Int64((dx * MouseFlags.speed).rounded()))
        return Unmanaged.passUnretained(event)
    }
    // 부드럽게: 한 칸 ≈ 40px 에 속도를 곱해 쌓아두고 타이머가 흘려보낸다
    MouseFlags.pendY += dy * 40 * MouseFlags.speed
    MouseFlags.pendX += dx * 40 * MouseFlags.speed
    MainActor.assumeIsolated { MouseTools.shared.kick() }
    return nil
}

private func sendKey(_ code: CGKeyCode, cmd: Bool) {
    for down in [true, false] {
        guard let e = CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: down) else { continue }
        if cmd { e.flags = .maskCommand }
        e.setIntegerValueField(.eventSourceUserData, value: MouseFlags.marker)
        e.post(tap: .cgSessionEventTap)
    }
}

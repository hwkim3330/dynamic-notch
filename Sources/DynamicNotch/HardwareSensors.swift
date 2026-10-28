import AppKit
import Combine
import IOKit.hid
import NotchKit

/// 센서 탭 — 화면 각도와 트랙패드 저울. 탭을 열어 둔 동안만 켠다(배터리).
///
/// 화면 각도: 힌지 각도 센서(Apple HID 0x05AC:0x8104, 센서 페이지 0x20 / 방향 0x8A).
///            기능 리포트 1번의 둘째·셋째 바이트가 각도(도). (LidAngleSensor 와 같은 방식)
/// 트랙패드:  비공개 MultitouchSupport 의 손가락 프레임. 구조체 13번째 칸(float)이 누르는 힘이고,
///            값이 대략 그램과 같다(TrackWeight 와 같은 방식). 직접 눌러 보며 칸 위치를 확인했다.
@MainActor
final class HardwareSensors {
    private let model: NotchModel
    private var subs: Set<AnyCancellable> = []
    private var timer: Timer?
    private var lid: IOHIDDevice?
    private var hid: IOHIDManager?        // 장치 연결은 이 관리자가 살아 있는 동안만 유지된다
    private var mt: UnsafeMutableRawPointer?
    private var tare = 0.0

    init(model: NotchModel) {
        self.model = model
        model.onTare = { [weak self] in
            MainActor.assumeIsolated { self?.tare = Touch.raw }
        }
        Publishers.CombineLatest(model.$expanded, model.$tab)
            .map { $0 && $1 == .sensors }
            .removeDuplicates()
            .sink { [weak self] on in MainActor.assumeIsolated { on ? self?.start() : self?.stop() } }
            .store(in: &subs)
    }

    private func start() {
        if lid == nil { openLid() }
        startTouch()
        timer = Timer.scheduledTimer(withTimeInterval: 1 / 15, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
    }

    private func stop() {
        timer?.invalidate(); timer = nil
        stopTouch()
    }

    private func tick() {
        if let d = lid {
            var buf = [UInt8](repeating: 0, count: 8); var len = buf.count
            let r = IOHIDDeviceGetReport(d, kIOHIDReportTypeFeature, 1, &buf, &len)
            if r != kIOReturnSuccess { DNLog.note("화면 각도 읽기 실패 \(r)") }
            if r == kIOReturnSuccess, len >= 3 {
                let a = Int(buf[1]) | Int(buf[2]) << 8
                if model.lidAngle != a { model.lidAngle = a }
            }
        }
        let touching = Date().timeIntervalSince(Touch.lastSeen) < 0.15
        if model.trackpadTouching != touching { model.trackpadTouching = touching }
        if !touching && Touch.raw != 0 { Touch.raw = 0 }
        let g = touching ? max(0, Touch.raw - tare) : nil
        if model.trackpadGrams != g { model.trackpadGrams = g }
    }

    private func openLid() {
        let m = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        let match: NSDictionary = ["VendorID": 0x05AC, "ProductID": 0x8104, "PrimaryUsagePage": 0x0020, "PrimaryUsage": 0x008A]
        IOHIDManagerSetDeviceMatching(m, match as CFDictionary)
        let r = IOHIDManagerOpen(m, IOOptionBits(kIOHIDOptionsTypeNone))
        hid = m
        guard let set = IOHIDManagerCopyDevices(m) as? Set<IOHIDDevice>, let d = set.first else {
            DNLog.note("화면 각도 센서 못 찾음 (manager open \(r))"); return
        }
        let o = IOHIDDeviceOpen(d, IOOptionBits(kIOHIDOptionsTypeNone))
        DNLog.note("화면 각도 센서 open \(o)")
        lid = d
    }

    // MARK: - MultitouchSupport (비공개 프레임워크라 dlopen 으로 부른다)

    private typealias CreateDefault = @convention(c) () -> UnsafeMutableRawPointer?
    private typealias Callback = @convention(c) (UnsafeMutableRawPointer?, UnsafeMutableRawPointer?, Int32, Double, Int32) -> Int32
    private typealias Register = @convention(c) (UnsafeMutableRawPointer?, Callback) -> Void
    private typealias Start = @convention(c) (UnsafeMutableRawPointer?, Int32) -> Int32
    private typealias Stop = @convention(c) (UnsafeMutableRawPointer?) -> Void
    private static let lib = dlopen("/System/Library/PrivateFrameworks/MultitouchSupport.framework/MultitouchSupport", RTLD_LAZY)
    private static func fn<T>(_ name: String, _: T.Type) -> T? {
        guard let lib, let s = dlsym(lib, name) else { return nil }
        return unsafeBitCast(s, to: T.self)
    }

    private func startTouch() {
        guard mt == nil, let create = Self.fn("MTDeviceCreateDefault", CreateDefault.self),
              let reg = Self.fn("MTRegisterContactFrameCallback", Register.self),
              let start = Self.fn("MTDeviceStart", Start.self), let d = create() else { return }
        reg(d, touchCallback)
        _ = start(d, 0)
        mt = d
    }

    private func stopTouch() {
        guard let d = mt, let stop = Self.fn("MTDeviceStop", Stop.self) else { return }
        stop(d); mt = nil
    }
}

/// 콜백은 멀티터치 스레드에서 불린다. 마지막 값만 적어 두고 타이머가 읽는다.
enum Touch {
    nonisolated(unsafe) static var raw = 0.0
    nonisolated(unsafe) static var lastSeen = Date.distantPast
}

private let touchCallback: @convention(c) (UnsafeMutableRawPointer?, UnsafeMutableRawPointer?, Int32, Double, Int32) -> Int32 = { _, touches, count, _, _ in
    guard count >= 1, let t = touches else { return 0 }
    // 첫 손가락의 13번째 4바이트 칸 = 누르는 힘
    let p = Double(t.load(fromByteOffset: 13 * 4, as: Float.self))
    if p.isFinite { Touch.raw = p; Touch.lastSeen = Date() }
    return 0
}

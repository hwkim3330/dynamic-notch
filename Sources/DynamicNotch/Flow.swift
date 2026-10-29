import AppKit
import CoreGraphics
import NotchKit

/// Flow — 한 마우스·키보드와 한 클립보드로 맥과 리눅스를 오간다 (Deskflow·Logi Flow 대신).
///
/// · 맥 화면 오른쪽(설정으로 왼쪽) 끝을 넘어가면 포인터가 리눅스 화면으로 넘어가고, 키보드도 따라간다.
///   리눅스 화면 반대쪽 끝으로 돌아오면 맥으로 돌아온다. 급할 땐 ⌃⌥⌘L.
/// · 클립보드는 연결돼 있는 동안 양쪽이 늘 같다 (글자, PNG 그림).
/// · 연결은 SSH: 맥이 `ssh <호스트>` 로 리눅스의 작은 에이전트(linux/notchflow-agent.c)를 띄우고
///   그 표준 입출력으로 이벤트를 주고받는다. 열어 둘 포트가 없고, 연구원망에서도 암호화되며, 호스트는 mDNS
///   이름(예: kim-System-Product-Name.local 또는 ~/.ssh/config 의 별칭)이라 IP 가 바뀌어도 된다.
///   에이전트 소스는 앱에 들어 있고, 리눅스에서 바뀌었을 때만 다시 컴파일한다.
/// · 키 배치: ⌘(왼쪽) → Ctrl (⌘C/⌘V 가 리눅스에서도 복사·붙여넣기), ⌃ → 오른쪽 Ctrl, ⌥ → Alt,
///   오른쪽 ⌘ → Super, 오른쪽 ⌥ 과 Caps Lock → 한/영 (Hangul).
@MainActor
final class Flow {
    static let shared = Flow()

    enum Side: String, CaseIterable { case right, left
        var title: String { self == .right ? "맥 오른쪽에 리눅스" : "맥 왼쪽에 리눅스" }
    }
    enum Status: Equatable { case off, connecting, connected(w: Int, h: Int), failed(String) }

    private let d = UserDefaults.standard
    var model: NotchModel?
    private(set) var status: Status = .off
    var enabled: Bool { d.bool(forKey: "flow.enabled") }
    var host: String { d.string(forKey: "flow.host") ?? "linux" }
    var side: Side { Side(rawValue: d.string(forKey: "flow.side") ?? "") ?? .right }

    private var link: FlowLink?
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private var retry: Timer?
    private var clipTimer: Timer?
    private var lastChange = NSPasteboard.general.changeCount

    private init() {}

    func setEnabled(_ on: Bool) { d.set(on, forKey: "flow.enabled"); on ? start() : stop() }
    func setHost(_ h: String) { d.set(h, forKey: "flow.host"); if enabled { stop(); start() } }
    func setSide(_ s: Side) { d.set(s.rawValue, forKey: "flow.side") }

    func start() {
        guard enabled, link == nil else { return }
        installTap()
        status = .connecting
        let l = FlowLink(host: host)
        link = l
        l.onFrame = { [weak self] t, p in self?.frame(t, p) }
        l.onClose = { [weak self] why in self?.closed(why) }
        l.open()
        lastChange = NSPasteboard.general.changeCount
        clipTimer = Timer.scheduledTimer(withTimeInterval: 0.4, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.pollClipboard() }
        }
    }

    func stop() {
        leave()
        retry?.invalidate(); retry = nil
        clipTimer?.invalidate(); clipTimer = nil
        link?.close(); link = nil
        status = .off
        FlowState.remoteW = 0
    }

    private func closed(_ why: String) {
        leave()
        link = nil
        clipTimer?.invalidate(); clipTimer = nil
        FlowState.remoteW = 0
        status = .failed(why)
        DNLog.note("flow: 끊김 \(why)")
        guard enabled else { status = .off; return }
        retry?.invalidate()
        retry = Timer.scheduledTimer(withTimeInterval: 5, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.retry = nil; self?.start() }
        }
    }

    private func frame(_ t: UInt8, _ p: Data) {
        switch t {
        case UInt8(ascii: "I"):
            guard p.count >= 8 else { return }
            let w = Int(p.int32(0)), h = Int(p.int32(4))
            FlowState.remoteW = Double(w); FlowState.remoteH = Double(h)
            status = .connected(w: w, h: h)
            DNLog.note("flow: 연결됨 \(host) \(w)x\(h)")
        case UInt8(ascii: "C"):
            guard let s = String(data: p, encoding: .utf8) else { return }
            let pb = NSPasteboard.general
            pb.clearContents(); pb.setString(s, forType: .string)
            lastChange = pb.changeCount
        case UInt8(ascii: "P"):
            let pb = NSPasteboard.general
            pb.clearContents(); pb.setData(p, forType: .png)
            lastChange = pb.changeCount
        case UInt8(ascii: "D"):
            DNLog.note("flow agent: \(String(decoding: p, as: UTF8.self))")
        default: break
        }
    }

    /// 맥에서 복사한 것 → 리눅스 클립보드
    private func pollClipboard() {
        let pb = NSPasteboard.general
        guard pb.changeCount != lastChange, let link else { return }
        lastChange = pb.changeCount
        if let s = pb.string(forType: .string), s.utf8.count < 32 << 20 {
            link.send("C", Data(s.utf8))
        } else if let png = pb.data(forType: .png) ?? pb.data(forType: .tiff).flatMap(pngFromTIFF), png.count < 32 << 20 {
            link.send("P", png)
        }
    }

    private func pngFromTIFF(_ tiff: Data) -> Data? {
        NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:])
    }

    // MARK: - 넘어가기 / 돌아오기

    /// 포인터가 리눅스로 넘어간다
    func enter(at y: Double, display: CGRect) {
        guard let link, FlowState.remoteW > 0, !FlowState.active else { return }
        let k = FlowState.remoteH / display.height
        FlowState.scale = k
        FlowState.display = display
        FlowState.rx = side == .right ? 1 : FlowState.remoteW - 2
        FlowState.ry = min(FlowState.remoteH - 1, max(0, (y - display.minY) * k))
        FlowState.active = true
        // 맥 포인터는 경계 조금 안쪽에 세워 두고 숨긴다 (움직임 값은 계속 들어온다)
        let park = CGPoint(x: side == .right ? display.maxX - 40 : display.minX + 40, y: y)
        CGWarpMouseCursorPosition(park)
        CGAssociateMouseAndMouseCursorPosition(0)
        CursorHider.hide()
        link.send("M", Data(int32s: [Int32(FlowState.rx), Int32(FlowState.ry)]))
        model?.show(.flow(on: true, name: shortHost), for: 1.6)
    }

    /// 포인터가 맥으로 돌아온다
    func leave() {
        guard FlowState.active else { return }
        FlowState.active = false
        link?.send("R", Data())
        let disp = FlowState.display
        let y = min(disp.maxY - 1, max(disp.minY, disp.minY + FlowState.ry / max(FlowState.scale, 0.01)))
        CGWarpMouseCursorPosition(CGPoint(x: side == .right ? disp.maxX - 3 : disp.minX + 3, y: y))
        CGAssociateMouseAndMouseCursorPosition(1)
        CursorHider.show()
        model?.show(.flow(on: false, name: shortHost), for: 1.2)
    }

    private var shortHost: String {
        let h = host.replacingOccurrences(of: ".local", with: "")
        return h.count > 18 ? String(h.prefix(18)) : h
    }

    func send(_ t: Character, _ p: Data) { link?.send(t, p) }

    // MARK: - 이벤트 탭

    private func installTap() {
        guard tap == nil, AXIsProcessTrusted() else { return }
        let types: [CGEventType] = [.mouseMoved, .leftMouseDown, .leftMouseUp, .rightMouseDown, .rightMouseUp,
                                    .otherMouseDown, .otherMouseUp, .leftMouseDragged, .rightMouseDragged,
                                    .otherMouseDragged, .scrollWheel, .keyDown, .keyUp, .flagsChanged]
        let mask = types.reduce(CGEventMask(0)) { $0 | CGEventMask(1 << $1.rawValue) }
        guard let t = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
                                        eventsOfInterest: mask, callback: flowCallback, userInfo: nil) else {
            DNLog.note("flow: 이벤트 탭 생성 실패"); return
        }
        tap = t; FlowState.tap = t
        source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, t, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: t, enable: true)
    }

    var statusText: String {
        switch status {
        case .off: "꺼짐"
        case .connecting: "연결 중… (\(host))"
        case .connected(let w, let h): "연결됨 · \(shortHost) · \(w)×\(h)"
        case .failed(let why): "끊김: \(why) — 5초 뒤 다시"
        }
    }
}

/// 탭 콜백(C 함수)이 읽고 쓰는 상태. 탭은 메인 런루프에서 돈다.
enum FlowState {
    nonisolated(unsafe) static var active = false
    nonisolated(unsafe) static var tap: CFMachPort?
    nonisolated(unsafe) static var remoteW = 0.0, remoteH = 0.0
    nonisolated(unsafe) static var rx = 0.0, ry = 0.0, scale = 1.0
    nonisolated(unsafe) static var display = CGRect.zero
    nonisolated(unsafe) static var scrollAccY = 0.0, scrollAccX = 0.0
    nonisolated(unsafe) static var lastMove = 0.0
}

private func flowCallback(proxy: CGEventTapProxy, type: CGEventType, event: CGEvent,
                          userInfo: UnsafeMutableRawPointer?) -> Unmanaged<CGEvent>? {
    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
        if let t = FlowState.tap { CGEvent.tapEnable(tap: t, enable: true) }
        return Unmanaged.passUnretained(event)
    }
    let pass = Unmanaged.passUnretained(event)
    if event.getIntegerValueField(.eventSourceUserData) == MouseFlags.marker { return FlowState.active ? nil : pass }
    return MainActor.assumeIsolated { () -> Unmanaged<CGEvent>? in
        FlowState.active ? remote(type, event) : (local(type, event) ? nil : pass)
    }
}

/// 맥에 있을 때: 화면 끝을 넘으려는지만 본다. 넘어갔으면 true (이 이벤트는 버린다)
@MainActor private func local(_ type: CGEventType, _ e: CGEvent) -> Bool {
    guard type == .mouseMoved, FlowState.remoteW > 0 else { return false }   // 버튼을 누른 채로는 넘어가지 않는다
    let dx = e.getDoubleValueField(.mouseEventDeltaX)
    let loc = e.location
    let right = Flow.shared.side == .right
    guard right ? dx > 0 : dx < 0 else { return false }
    let displays = activeDisplays()
    guard let disp = displays.first(where: { $0.insetBy(dx: -1, dy: 0).contains(loc) }) else { return false }
    let edgeX = right ? displays.map(\.maxX).max()! : displays.map(\.minX).min()!
    // 가장 바깥 화면의 그 쪽 끝에 닿았을 때만
    guard right ? (disp.maxX >= edgeX && loc.x >= edgeX - 1) : (disp.minX <= edgeX && loc.x <= edgeX) else { return false }
    Flow.shared.enter(at: loc.y, display: disp)
    return true
}

@MainActor private func activeDisplays() -> [CGRect] {
    var ids = [CGDirectDisplayID](repeating: 0, count: 16); var n: UInt32 = 0
    CGGetActiveDisplayList(16, &ids, &n)
    return ids.prefix(Int(n)).map { CGDisplayBounds($0) }
}

/// 리눅스에 있을 때: 모든 입력을 리눅스로 보내고 맥에는 버린다
@MainActor private func remote(_ type: CGEventType, _ e: CGEvent) -> Unmanaged<CGEvent>? {
    let f = Flow.shared
    switch type {
    case .mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged:
        let k = FlowState.scale
        FlowState.rx += e.getDoubleValueField(.mouseEventDeltaX) * k
        FlowState.ry = min(FlowState.remoteH - 1, max(0, FlowState.ry + e.getDoubleValueField(.mouseEventDeltaY) * k))
        let back = f.side == .right ? FlowState.rx < 0 : FlowState.rx > FlowState.remoteW - 1
        if back && type == .mouseMoved { f.leave(); return nil }
        FlowState.rx = min(FlowState.remoteW - 1, max(0, FlowState.rx))
        f.send("M", Data(int32s: [Int32(FlowState.rx), Int32(FlowState.ry)]))
    case .leftMouseDown, .leftMouseUp, .rightMouseDown, .rightMouseUp, .otherMouseDown, .otherMouseUp:
        let down = type == .leftMouseDown || type == .rightMouseDown || type == .otherMouseDown
        var b: UInt8
        switch type {
        case .leftMouseDown, .leftMouseUp: b = 1
        case .rightMouseDown, .rightMouseUp: b = 3
        default:
            switch e.getIntegerValueField(.mouseEventButtonNumber) {
            case 2: b = 2
            case 3: b = 8          // 엄지 뒤 → 뒤로
            case 4: b = 9          // 엄지 앞 → 앞으로
            default: return nil
            }
        }
        f.send("B", Data([b, down ? 1 : 0]))
    case .scrollWheel:
        let continuous = e.getIntegerValueField(.scrollWheelEventIsContinuous) != 0
        // 맥에서 쓰는 방향 설정(스크롤 뒤집기)을 그대로 따른다
        let fv: Double = (continuous ? Flags.tpV : Flags.msV) ? -1 : 1
        let fh: Double = (continuous ? Flags.tpH : Flags.msH) ? -1 : 1
        var cy = 0, cx = 0
        if continuous {
            FlowState.scrollAccY += Double(e.getIntegerValueField(.scrollWheelEventPointDeltaAxis1)) * fv
            FlowState.scrollAccX += Double(e.getIntegerValueField(.scrollWheelEventPointDeltaAxis2)) * fh
            let step = 24.0
            cy = Int(FlowState.scrollAccY / step); FlowState.scrollAccY -= Double(cy) * step
            cx = Int(FlowState.scrollAccX / step); FlowState.scrollAccX -= Double(cx) * step
        } else {
            cy = Int(Double(e.getIntegerValueField(.scrollWheelEventDeltaAxis1)) * fv)
            cx = Int(Double(e.getIntegerValueField(.scrollWheelEventDeltaAxis2)) * fh)
            if MouseFlags.shiftH && e.flags.contains(.maskShift) && cx == 0 { cx = cy; cy = 0 }
        }
        if cy != 0 || cx != 0 {
            f.send("W", Data([UInt8(bitPattern: Int8(clamping: cy)), UInt8(bitPattern: Int8(clamping: -cx))]))
        }
    case .keyDown, .keyUp:
        let code = Int(e.getIntegerValueField(.keyboardEventKeycode))
        // 비상 탈출: ⌃⌥⌘L
        if type == .keyDown, code == 37, e.flags.isSuperset(of: [.maskControl, .maskAlternate, .maskCommand]) {
            f.leave(); return nil
        }
        if e.getIntegerValueField(.keyboardEventAutorepeat) != 0 { return nil }   // 반복은 리눅스가 알아서 한다
        guard let ks = FlowKeys.keysym[code] else { return nil }
        f.send("K", Data(int32s: [Int32(bitPattern: ks)]) + Data([type == .keyDown ? 1 : 0]))
    case .flagsChanged:
        let code = Int(e.getIntegerValueField(.keyboardEventKeycode))
        if code == 57 {                         // Caps Lock → 한/영
            for down: UInt8 in [1, 0] { f.send("K", Data(int32s: [Int32(bitPattern: 0xff31)]) + Data([down])) }
            return nil
        }
        guard let (bit, ks) = FlowKeys.modifier[code] else { return nil }
        let down: UInt8 = (e.flags.rawValue & bit) != 0 ? 1 : 0
        f.send("K", Data(int32s: [Int32(bitPattern: ks)]) + Data([down]))
    default:
        return Unmanaged.passUnretained(e)
    }
    return nil
}

/// 맥 키 코드(물리 위치) → X keysym (US 배열의 그 자리 글자). Shift 는 따로 보내니 소문자·기본 기호만.
enum FlowKeys {
    static let keysym: [Int: UInt32] = {
        var m: [Int: UInt32] = [:]
        let chars: [(Int, Character)] = [
            (0, "a"), (1, "s"), (2, "d"), (3, "f"), (4, "h"), (5, "g"), (6, "z"), (7, "x"), (8, "c"), (9, "v"),
            (11, "b"), (12, "q"), (13, "w"), (14, "e"), (15, "r"), (16, "y"), (17, "t"), (18, "1"), (19, "2"),
            (20, "3"), (21, "4"), (22, "6"), (23, "5"), (24, "="), (25, "9"), (26, "7"), (27, "-"), (28, "8"),
            (29, "0"), (30, "]"), (31, "o"), (32, "u"), (33, "["), (34, "i"), (35, "p"), (37, "l"), (38, "j"),
            (39, "'"), (40, "k"), (41, ";"), (42, "\\"), (43, ","), (44, "/"), (45, "n"), (46, "m"), (47, "."),
            (50, "`"), (49, " "),
        ]
        for (k, c) in chars { m[k] = UInt32(c.unicodeScalars.first!.value) }
        let named: [(Int, UInt32)] = [
            (36, 0xff0d), (48, 0xff09), (51, 0xff08), (53, 0xff1b), (117, 0xffff), (76, 0xff8d),  // Return Tab BackSpace Escape Delete KP_Enter
            (123, 0xff51), (124, 0xff53), (125, 0xff54), (126, 0xff52),                          // ← → ↓ ↑
            (115, 0xff50), (119, 0xff57), (116, 0xff55), (121, 0xff56), (114, 0xff63),           // Home End PgUp PgDn Insert(Help)
            (122, 0xffbe), (120, 0xffbf), (99, 0xffc0), (118, 0xffc1), (96, 0xffc2), (97, 0xffc3), // F1-F6
            (98, 0xffc4), (100, 0xffc5), (101, 0xffc6), (109, 0xffc7), (103, 0xffc8), (111, 0xffc9), // F7-F12
            (105, 0xffca), (107, 0xffcb), (113, 0xffcc),                                          // F13-F15
            (65, 0xffae), (67, 0xffaa), (69, 0xffab), (75, 0xffaf), (78, 0xffad), (81, 0xffbd), (71, 0xff7f),
            (82, 0xffb0), (83, 0xffb1), (84, 0xffb2), (85, 0xffb3), (86, 0xffb4), (87, 0xffb5), (88, 0xffb6),
            (89, 0xffb7), (91, 0xffb8), (92, 0xffb9),                                             // 숫자 패드
            (102, 0xff31), (104, 0xff34),                                                         // 영문/かな 키 → 한/영, 한자
        ]
        for (k, s) in named { m[k] = s }
        return m
    }()

    /// 수식 키: 맥 키 코드 → (그 키의 장치 깃발 비트, X keysym)
    static let modifier: [Int: (UInt64, UInt32)] = [
        56: (0x02, 0xffe1),     // 왼쪽 Shift
        60: (0x04, 0xffe2),     // 오른쪽 Shift
        55: (0x08, 0xffe3),     // 왼쪽 ⌘ → Control_L
        54: (0x10, 0xffeb),     // 오른쪽 ⌘ → Super_L
        59: (0x01, 0xffe4),     // 왼쪽 ⌃ → Control_R
        62: (0x2000, 0xffe4),   // 오른쪽 ⌃ → Control_R
        58: (0x20, 0xffe9),     // 왼쪽 ⌥ → Alt_L
        61: (0x40, 0xff31),     // 오른쪽 ⌥ → Hangul (한/영)
    ]
}

/// 백그라운드 앱이 포인터를 숨기려면 이 연결 속성이 필요하다 (Deskflow 와 같은 방법)
enum CursorHider {
    private typealias CID = Int32
    @_silgen_name("_CGSDefaultConnection") private static func defaultConnection() -> CID
    @_silgen_name("CGSSetConnectionProperty")
    private static func setProperty(_ cid: CID, _ target: CID, _ key: CFString, _ value: CFTypeRef) -> CGError
    nonisolated(unsafe) private static var hidden = false

    static func hide() {
        guard !hidden else { return }
        let c = defaultConnection()
        _ = setProperty(c, c, "SetsCursorInBackground" as CFString, kCFBooleanTrue)
        CGDisplayHideCursor(CGMainDisplayID()); hidden = true
    }
    static func show() {
        guard hidden else { return }
        CGDisplayShowCursor(CGMainDisplayID()); hidden = false
    }
}

/// SSH 로 띄운 리눅스 에이전트와의 연결 (프레임: 종류 1바이트 + 길이 4바이트 LE + 내용)
final class FlowLink: @unchecked Sendable {
    let host: String
    var onFrame: (@MainActor (UInt8, Data) -> Void)?
    var onClose: (@MainActor (String) -> Void)?
    private var proc: Process?
    private var stdin: FileHandle?
    private let writes = DispatchQueue(label: "flow.write")
    private var buf = Data()
    private var errText = ""

    init(host: String) { self.host = host }

    private static let ssh = ["-o", "BatchMode=yes", "-o", "ConnectTimeout=6", "-o", "ServerAliveInterval=5",
                              "-o", "ServerAliveCountMax=2", "-o", "StrictHostKeyChecking=accept-new", "-o", "AddressFamily=inet"]

    func open() {
        DispatchQueue.global().async { [self] in
            // 1) 에이전트 소스를 보내고, 바뀌었거나 없으면 리눅스에서 컴파일
            guard let src = Bundle.main.url(forResource: "notchflow-agent", withExtension: "c"),
                  let srcData = try? Data(contentsOf: src) else { return fail("앱에 에이전트 소스가 없음") }
            let install = """
            set -e; d=$HOME/.local/share/notchflow; mkdir -p "$d" "$HOME/.local/bin"; cat > "$d/new.c"
            if ! cmp -s "$d/new.c" "$d/notchflow-agent.c" || [ ! -x "$HOME/.local/bin/notchflow-agent" ]; then
              mv "$d/new.c" "$d/notchflow-agent.c"
              gcc -O2 -o "$HOME/.local/bin/notchflow-agent" "$d/notchflow-agent.c" -lX11 -lXtst -lXfixes
            fi
            """
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
            p.arguments = Self.ssh + [host, install]
            let inp = Pipe(), err = Pipe()
            p.standardInput = inp; p.standardError = err; p.standardOutput = FileHandle.nullDevice
            do { try p.run() } catch { return fail("ssh 실행 실패") }
            inp.fileHandleForWriting.write(srcData); try? inp.fileHandleForWriting.close()
            p.waitUntilExit()
            if p.terminationStatus != 0 {
                let e = String(decoding: err.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                return fail(e.split(separator: "\n").last.map(String.init) ?? "설치 실패 (\(p.terminationStatus))")
            }
            // 2) 에이전트 실행
            let a = Process()
            a.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
            a.arguments = Self.ssh + ["-T", host, "exec $HOME/.local/bin/notchflow-agent"]
            let i2 = Pipe(), o2 = Pipe(), e2 = Pipe()
            a.standardInput = i2; a.standardOutput = o2; a.standardError = e2
            o2.fileHandleForReading.readabilityHandler = { [weak self] h in
                let chunk = h.availableData
                if chunk.isEmpty { h.readabilityHandler = nil; return }
                self?.received(chunk)
            }
            e2.fileHandleForReading.readabilityHandler = { [weak self] h in
                let chunk = h.availableData
                if chunk.isEmpty { h.readabilityHandler = nil; return }
                self?.errText += String(decoding: chunk, as: UTF8.self)
            }
            a.terminationHandler = { [weak self] pr in
                guard let self else { return }
                let why = self.errText.split(separator: "\n").last.map(String.init) ?? "연결 종료 (\(pr.terminationStatus))"
                DispatchQueue.main.async { MainActor.assumeIsolated { self.onClose?(why) } }
            }
            do { try a.run() } catch { return fail("ssh 실행 실패") }
            proc = a; stdin = i2.fileHandleForWriting
            send("H", Data())
        }
    }

    private func fail(_ why: String) {
        DispatchQueue.main.async { MainActor.assumeIsolated { self.onClose?(why) } }
    }

    func close() {
        proc?.terminationHandler = nil
        proc?.terminate(); proc = nil
        try? stdin?.close(); stdin = nil
    }

    func send(_ t: Character, _ p: Data) {
        var f = Data([t.asciiValue ?? 0])
        f.append(Data(int32s: [Int32(p.count)])); f.append(p)
        writes.async { [weak self] in try? self?.stdin?.write(contentsOf: f) }
    }

    private func received(_ chunk: Data) {
        buf.append(chunk)
        while buf.count >= 5 {
            let n = Int(UInt32(bitPattern: buf.int32(1)))
            guard buf.count >= 5 + n else { break }
            let t = buf[buf.startIndex]
            let payload = buf.subdata(in: buf.startIndex + 5 ..< buf.startIndex + 5 + n)
            buf.removeSubrange(buf.startIndex ..< buf.startIndex + 5 + n)
            DispatchQueue.main.async { [weak self] in MainActor.assumeIsolated { self?.onFrame?(t, payload) } }
        }
    }
}

extension Data {
    init(int32s: [Int32]) {
        var d = Data()
        for v in int32s { Swift.withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
        self = d
    }
    func int32(_ off: Int) -> Int32 {
        let s = startIndex + off
        return Int32(bitPattern: UInt32(self[s]) | UInt32(self[s + 1]) << 8 | UInt32(self[s + 2]) << 16 | UInt32(self[s + 3]) << 24)
    }
}

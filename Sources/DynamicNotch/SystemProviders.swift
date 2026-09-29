import AppKit
import CoreAudio
import CoreMediaIO
import IOKit.ps
import NotchKit

// MARK: - 전원 어댑터 연결/분리, 배터리 부족

@MainActor
final class BatteryProvider {
    private let model: NotchModel
    private var source: CFRunLoopSource?
    private var last: (level: Int, plugged: Bool)?

    init(model: NotchModel) {
        self.model = model
        let ctx = Unmanaged.passUnretained(self).toOpaque()
        source = IOPSNotificationCreateRunLoopSource({ ctx in
            guard let ctx else { return }
            let me = Unmanaged<BatteryProvider>.fromOpaque(ctx).takeUnretainedValue()
            MainActor.assumeIsolated { me.update() }
        }, ctx)?.takeRetainedValue()
        if let source { CFRunLoopAddSource(CFRunLoopGetMain(), source, .defaultMode) }
        update()
    }

    private func read() -> (level: Int, plugged: Bool)? {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let list = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef] else { return nil }
        for ps in list {
            guard let d = IOPSGetPowerSourceDescription(info, ps)?.takeUnretainedValue() as? [String: Any],
                  (d[kIOPSTypeKey] as? String) == kIOPSInternalBatteryType else { continue }
            let cap = d[kIOPSCurrentCapacityKey] as? Int ?? 0
            let mx = max(1, d[kIOPSMaxCapacityKey] as? Int ?? 100)
            return (Int((Double(cap) / Double(mx) * 100).rounded()),
                    (d[kIOPSPowerSourceStateKey] as? String) == kIOPSACPowerValue)
        }
        return nil
    }

    func update() {
        guard let b = read() else { return }
        if let last, last.plugged != b.plugged {
            model.show(.battery(level: b.level, pluggedIn: b.plugged), for: 2.4)
        } else if let last, last.level > 20, b.level <= 20, !b.plugged {
            model.show(.battery(level: b.level, pluggedIn: false), for: 3)
        }
        last = b
    }
}

// MARK: - 잠금 해제

@MainActor
final class ScreenLockProvider {
    init(model: NotchModel) {
        DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("com.apple.screenIsUnlocked"), object: nil, queue: .main
        ) { [weak model] _ in
            MainActor.assumeIsolated {
                // 잠금 화면이 사라지는 애니메이션이 끝난 뒤 보여준다
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { model?.playUnlock() }
            }
        }
    }
}

// MARK: - 카메라 / 마이크 사용 감지

/// 다른 앱이 카메라나 마이크를 켜고 끌 때 노치에 표시한다 (노치 = 카메라 자리).
/// 권한이 필요 없는 CoreMediaIO / CoreAudio 의 "IsRunningSomewhere" 속성을 1초마다 읽는다.
@MainActor
final class SensorProvider {
    private let model: NotchModel
    private var timer: Timer?
    private var camera: Bool?
    private var mic: Bool?

    init(model: NotchModel) {
        self.model = model
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.poll() }
        }
        poll()
    }

    private func poll() {
        let cam = Self.cameraRunning()
        let m = Self.micRunning()
        // 우리 미러가 켠 카메라는 알리지 않는다
        if let camera, cam != camera, !CameraMirror.isActive {
            model.show(.sensor(camera: true, on: cam), for: 2.2)
        } else if let mic, m != mic {
            model.show(.sensor(camera: false, on: m), for: 2.2)
        }
        camera = cam
        mic = m
    }

    static func cameraRunning() -> Bool {
        var addr = CMIOObjectPropertyAddress(
            mSelector: CMIOObjectPropertySelector(kCMIOHardwarePropertyDevices),
            mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal),
            mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain))
        var size: UInt32 = 0
        guard CMIOObjectGetPropertyDataSize(CMIOObjectID(kCMIOObjectSystemObject), &addr, 0, nil, &size) == 0,
              size > 0 else { return false }
        var ids = [CMIOObjectID](repeating: 0, count: Int(size) / MemoryLayout<CMIOObjectID>.size)
        var used: UInt32 = 0
        CMIOObjectGetPropertyData(CMIOObjectID(kCMIOObjectSystemObject), &addr, 0, nil, size, &used, &ids)
        for id in ids {
            var a = CMIOObjectPropertyAddress(
                mSelector: CMIOObjectPropertySelector(kCMIODevicePropertyDeviceIsRunningSomewhere),
                mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeWildcard),
                mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementWildcard))
            var running: UInt32 = 0
            var got: UInt32 = 0
            if CMIOObjectGetPropertyData(id, &a, 0, nil, UInt32(MemoryLayout<UInt32>.size), &got, &running) == 0,
               running != 0 { return true }
        }
        return false
    }

    static func micRunning() -> Bool {
        var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices,
                                              mScope: kAudioObjectPropertyScopeGlobal,
                                              mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size) == noErr
        else { return false }
        var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &ids)
        for id in ids {
            // 입력 스트림이 있는 장치만
            var sAddr = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreams,
                                                   mScope: kAudioDevicePropertyScopeInput,
                                                   mElement: kAudioObjectPropertyElementMain)
            var sSize: UInt32 = 0
            guard AudioObjectGetPropertyDataSize(id, &sAddr, 0, nil, &sSize) == noErr, sSize > 0 else { continue }
            var rAddr = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyDeviceIsRunningSomewhere,
                                                   mScope: kAudioObjectPropertyScopeGlobal,
                                                   mElement: kAudioObjectPropertyElementMain)
            var running: UInt32 = 0
            var rSize = UInt32(MemoryLayout<UInt32>.size)
            if AudioObjectGetPropertyData(id, &rAddr, 0, nil, &rSize, &running) == noErr, running != 0 { return true }
        }
        return false
    }
}

// MARK: - 다운로드 완료

/// ~/Downloads 에 새 파일이 다 받아지면 알린다 (Chrome, Safari 등 브라우저 무관)
@MainActor
final class DownloadsProvider {
    private let model: NotchModel
    private let dir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Downloads")
    private var known: Set<String> = []
    private var source: DispatchSourceFileSystemObject?
    private var pending: [String: (size: UInt64, seen: Int)] = [:]
    private var timer: Timer?

    static let partial = ["crdownload", "download", "part", "partial", "tmp"]

    init(model: NotchModel) {
        self.model = model
        known = Set(list())
        model.onRevealFile = { path in
            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
        }
        let fd = open(dir.path, O_EVTONLY)
        guard fd >= 0 else { return }
        let src = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: .write, queue: .main)
        src.setEventHandler { [weak self] in MainActor.assumeIsolated { self?.changed() } }
        src.setCancelHandler { close(fd) }
        src.resume()
        source = src
        // 크기가 두 번 연속 같으면 다 받은 것으로 본다
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.settle() }
        }
    }

    private func list() -> [String] {
        (try? FileManager.default.contentsOfDirectory(atPath: dir.path))?.filter { !$0.hasPrefix(".") } ?? []
    }

    private func changed() {
        let now = Set(list())
        for name in now.subtracting(known) where !Self.partial.contains((name as NSString).pathExtension.lowercased()) {
            pending[name] = (0, 0)
        }
        known = now
    }

    private func settle() {
        for (name, st) in pending {
            let path = dir.appendingPathComponent(name).path
            guard let size = (try? FileManager.default.attributesOfItem(atPath: path)[.size] as? NSNumber)?.uint64Value else {
                pending[name] = nil; continue
            }
            if size == st.size, size > 0 {
                if st.seen >= 1 {
                    pending[name] = nil
                    model.show(.download(name: name, path: path), for: 3.2)
                } else { pending[name] = (size, st.seen + 1) }
            } else { pending[name] = (size, 0) }
        }
    }
}

// MARK: - RustDesk 원격 접속

/// 누군가 이 맥에 RustDesk 로 접속하면 연결 관리자(`--cm`) 창이 뜬다. 그걸 보고 알린다.
@MainActor
final class RemoteProvider {
    private let model: NotchModel
    private var timer: Timer?
    private var last: Bool?

    init(model: NotchModel) {
        self.model = model
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.poll() }
        }
        poll()
    }

    private func poll() {
        let pids = NSWorkspace.shared.runningApplications
            .filter { ($0.bundleIdentifier ?? "").lowercased().contains("rustdesk") }
            .map(\.processIdentifier)
        let on = pids.contains { Self.args(of: $0).contains("--cm") }
        if let last, last != on { model.show(.remote(on: on), for: on ? 3 : 2) }
        last = on
    }

    /// RustDesk 프로세스의 실행 인자 (sysctl KERN_PROCARGS2, 같은 사용자 프로세스만 읽힘)
    static func args(of pid: pid_t) -> [String] {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > 4 else { return [] }
        var buf = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, 3, &buf, &size, nil, 0) == 0 else { return [] }
        let argc = buf.withUnsafeBytes { $0.load(as: Int32.self) }
        var parts = buf[4..<size].split(separator: 0, omittingEmptySubsequences: true).map { String(decoding: $0, as: UTF8.self) }
        if !parts.isEmpty { parts.removeFirst() }   // 실행 파일 경로
        return Array(parts.prefix(Int(argc)))
    }
}

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

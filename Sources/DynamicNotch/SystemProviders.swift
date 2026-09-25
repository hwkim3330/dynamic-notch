import AppKit
import CoreAudio
import AudioToolbox
import IOKit.ps
import IOBluetooth
import CoreBluetooth
import NotchKit

// MARK: - 배터리 / 전원 어댑터

@MainActor
final class BatteryProvider {
    private let model: NotchModel
    private var source: CFRunLoopSource?
    private var last: BatteryInfo?

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

    private func read() -> BatteryInfo? {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let list = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef] else { return nil }
        for ps in list {
            guard let d = IOPSGetPowerSourceDescription(info, ps)?.takeUnretainedValue() as? [String: Any],
                  (d[kIOPSTypeKey] as? String) == kIOPSInternalBatteryType else { continue }
            let cap = d[kIOPSCurrentCapacityKey] as? Int ?? 0
            let mx = max(1, d[kIOPSMaxCapacityKey] as? Int ?? 100)
            return BatteryInfo(level: Int((Double(cap) / Double(mx) * 100).rounded()),
                               charging: d[kIOPSIsChargingKey] as? Bool ?? false,
                               pluggedIn: (d[kIOPSPowerSourceStateKey] as? String) == kIOPSACPowerValue)
        }
        return nil
    }

    func update() {
        guard let b = read() else { return }
        model.battery = b
        if let last, last.pluggedIn != b.pluggedIn {
            model.show(.battery(level: b.level, charging: b.charging || b.pluggedIn, pluggedIn: b.pluggedIn), for: 2.4)
        } else if let last, last.level > 20, b.level <= 20, !b.pluggedIn {
            model.show(.battery(level: b.level, charging: false, pluggedIn: false), for: 3)
        }
        last = b
    }
}

// MARK: - 볼륨

@MainActor
final class VolumeProvider {
    private let model: NotchModel
    private var device = AudioObjectID(kAudioObjectUnknown)
    private var lastVolume: Float32 = -1
    private var lastMute = false
    private let started = Date()
    private let listener: AudioObjectPropertyListenerBlock

    private static var volumeAddr = AudioObjectPropertyAddress(
        mSelector: kAudioHardwareServiceDeviceProperty_VirtualMainVolume,
        mScope: kAudioDevicePropertyScopeOutput, mElement: kAudioObjectPropertyElementMain)
    private static var muteAddr = AudioObjectPropertyAddress(
        mSelector: kAudioDevicePropertyMute,
        mScope: kAudioDevicePropertyScopeOutput, mElement: kAudioObjectPropertyElementMain)
    private static var defaultAddr = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDefaultOutputDevice,
        mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)

    init(model: NotchModel) {
        self.model = model
        var weakSelf: VolumeProvider?
        listener = { _, _ in MainActor.assumeIsolated { weakSelf?.read(show: true) } }
        weakSelf = self
        AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &Self.defaultAddr, .main) { [weak self] _, _ in
            MainActor.assumeIsolated { self?.attach() }
        }
        attach()
    }

    private func attach() {
        if device != kAudioObjectUnknown {
            AudioObjectRemovePropertyListenerBlock(device, &Self.volumeAddr, .main, listener)
            AudioObjectRemovePropertyListenerBlock(device, &Self.muteAddr, .main, listener)
        }
        var id = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &Self.defaultAddr, 0, nil, &size, &id)
        device = id
        AudioObjectAddPropertyListenerBlock(device, &Self.volumeAddr, .main, listener)
        AudioObjectAddPropertyListenerBlock(device, &Self.muteAddr, .main, listener)
        read(show: false)
    }

    private func read(show: Bool) {
        var v: Float32 = 0
        var size = UInt32(MemoryLayout<Float32>.size)
        AudioObjectGetPropertyData(device, &Self.volumeAddr, 0, nil, &size, &v)
        var m: UInt32 = 0
        size = UInt32(MemoryLayout<UInt32>.size)
        let hasMute = AudioObjectGetPropertyData(device, &Self.muteAddr, 0, nil, &size, &m) == noErr
        let muted = hasMute && m != 0
        defer { lastVolume = v; lastMute = muted }
        model.volume = Double(v)
        guard show, Date().timeIntervalSince(started) > 1.5,
              abs(v - lastVolume) > 0.001 || muted != lastMute else { return }
        model.show(.volume(level: Double(v), muted: muted), for: 1.6)
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

// MARK: - 블루투스 기기 (AirPods 등)

/// IOBluetooth 는 권한이 정해지지 않았으면 메인 스레드를 막고 기다리므로,
/// CoreBluetooth 로 권한을 비동기로 받은 뒤에만 등록한다.
@MainActor
final class BluetoothProvider: NSObject, CBCentralManagerDelegate {
    private let model: NotchModel
    private var started = Date()
    private var connectNote: IOBluetoothUserNotification?
    private var central: CBCentralManager?

    init(model: NotchModel) {
        self.model = model
        super.init()
        switch CBManager.authorization {
        case .allowedAlways: register()
        case .notDetermined: central = CBCentralManager(delegate: self, queue: .main)
        default: break
        }
    }

    nonisolated func centralManagerDidUpdateState(_ central: CBCentralManager) {
        MainActor.assumeIsolated {
            if CBManager.authorization == .allowedAlways, connectNote == nil { register() }
        }
    }

    private func register() {
        started = Date()
        connectNote = IOBluetoothDevice.register(forConnectNotifications: self, selector: #selector(connected(_:device:)))
    }

    private func symbol(for d: IOBluetoothDevice) -> String {
        let name = (d.name ?? "").lowercased()
        if name.contains("airpods max") { return "airpodsmax" }
        if name.contains("airpods pro") { return "airpodspro" }
        if name.contains("airpods") { return "airpods" }
        if name.contains("beats") { return "beats.headphones" }
        switch d.deviceClassMajor {
        case UInt32(kBluetoothDeviceClassMajorAudio): return "headphones"
        case UInt32(kBluetoothDeviceClassMajorPeripheral):
            if name.contains("mouse") { return "magicmouse" }
            if name.contains("trackpad") { return "rectangle.and.hand.point.up.left" }
            return "keyboard"
        case UInt32(kBluetoothDeviceClassMajorPhone): return "iphone"
        default: return "dot.radiowaves.left.and.right"
        }
    }

    @objc private func connected(_ note: IOBluetoothUserNotification, device: IOBluetoothDevice) {
        device.register(forDisconnectNotification: self, selector: #selector(disconnected(_:device:)))
        // 시작 직후엔 이미 연결된 기기들이 한꺼번에 들어오므로 무시
        guard Date().timeIntervalSince(started) > 3 else { return }
        model.show(.device(name: device.name ?? "블루투스 기기", symbol: symbol(for: device), connected: true), for: 2.6)
    }

    @objc private func disconnected(_ note: IOBluetoothUserNotification, device: IOBluetoothDevice) {
        note.unregister()
        model.show(.device(name: device.name ?? "블루투스 기기", symbol: symbol(for: device), connected: false), for: 2.2)
    }
}

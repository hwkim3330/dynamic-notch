import AppKit
import SwiftUI
import ServiceManagement
import NotchKit

@main
struct Main {
    static func main() {
        // Claude Code 훅에서 불릴 때: 이벤트만 넘기고 바로 종료 (UI 없음)
        if CommandLine.arguments.contains("--claude-hook") { ClaudeHook.run() }
        if CommandLine.arguments.contains("--statusline") { ClaudeHook.statusLine() }

        // 이미 떠 있으면 두 번째 실행은 조용히 끝낸다 (노치가 두 겹으로 그려지지 않게)
        let me = ProcessInfo.processInfo.processIdentifier
        let myPath = Bundle.main.executablePath
        let others = NSWorkspace.shared.runningApplications.filter {
            $0.processIdentifier != me && ($0.bundleIdentifier == "com.hwkim3330.dynamicnotch"
                || ($0.executableURL?.path == myPath && myPath != nil))
        }
        if !others.isEmpty { exit(0) }

        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        // delegate 는 weak 이라 릴리스 빌드에서 일찍 해제되지 않도록 붙잡아 둔다
        withExtendedLifetime(delegate) { app.run() }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    let model = NotchModel()
    var obs: OBSProvider!
    private var obsMenu: NSMenu!
    var panel: NotchPanel!
    var statusItem: NSStatusItem!
    var providers: [AnyObject] = []

    func applicationDidFinishLaunching(_ note: Notification) {
        panel = NotchPanel(model: model)
        panel.reposition()
        panel.orderFrontRegardless()

        let nowPlaying = NowPlayingProvider(model: model)
        model.controls = nowPlaying
        model.cameraView = { AnyView(CameraMirror()) }
        model.onExpand = { [weak nowPlaying] in
            NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
            nowPlaying?.refreshPosition()
        }
        obs = OBSProvider(model: model)
        providers = [nowPlaying, obs, HardwareSensors(model: model), ClaudeProvider(model: model), CodexProvider(model: model),
                     BatteryProvider(model: model), ScreenLockProvider(model: model),
                     SensorProvider(model: model), DownloadsProvider(model: model), RemoteProvider(model: model),
                     UsageProvider(model: model)]

        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                                               object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.panel.reposition() }
        }
        setupStatusItem()
        watchSleep()
        ScrollReverser.shared.start()

        if let i = CommandLine.arguments.firstIndex(of: "--open"), i + 1 < CommandLine.arguments.count,
           let tab = NotchTab(rawValue: CommandLine.arguments[i + 1]) {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [model] in model.open(tab) }
        }
        if CommandLine.arguments.contains("--demo") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [model] in NotchDemo.run(model) }
        }
    }

    /// 화면이 꺼지거나 잠기면 애니메이션과 마우스 추적을 멈춘다
    private func watchSleep() {
        let ws = NSWorkspace.shared.notificationCenter
        let dn = DistributedNotificationCenter.default()
        let pause: (Bool) -> Void = { [weak self] p in
            MainActor.assumeIsolated {
                AnimationGate.paused = p
                self?.panel.setTracking(!p)
                self?.model.objectWillChange.send()
            }
        }
        for n in [NSWorkspace.screensDidSleepNotification, NSWorkspace.willSleepNotification] {
            ws.addObserver(forName: n, object: nil, queue: .main) { _ in pause(true) }
        }
        for n in [NSWorkspace.screensDidWakeNotification, NSWorkspace.didWakeNotification] {
            ws.addObserver(forName: n, object: nil, queue: .main) { [weak self] _ in
                pause(false)
                MainActor.assumeIsolated {
                    self?.panel.reposition()
                    // 잠자기 뒤에 이벤트 탭이 조용히 죽는 경우가 있다 — 새로 건다
                    ScrollReverser.shared.stop(); ScrollReverser.shared.start()
                }
            }
        }
        dn.addObserver(forName: Notification.Name("com.apple.screenIsLocked"), object: nil, queue: .main) { _ in pause(true) }
        dn.addObserver(forName: Notification.Name("com.apple.screenIsUnlocked"), object: nil, queue: .main) { _ in pause(false) }
    }

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let img = NSImage(systemSymbolName: "macbook", accessibilityDescription: "Dynamic Notch") {
            statusItem.button?.image = img
        } else {
            statusItem.button?.title = "◗"
        }
        let menu = NSMenu()
        menu.addItem(item("데모 재생", #selector(runDemo), "d"))
        menu.addItem(item("사용량 보기", #selector(openUsage), "u"))
        menu.addItem(item("미러 열기", #selector(openMirror), ""))
        menu.addItem(item("센서 보기 (화면 각도 · 트랙패드 저울)", #selector(openSensors), ""))
        menu.addItem(.separator())
        // 스크롤 뒤집기 — Scroll Reverser 대신
        let scroll = NSMenuItem(title: "스크롤 뒤집기", action: nil, keyEquivalent: "")
        let sub = NSMenu()
        for (n, k) in ScrollReverser.Key.allCases.enumerated() {
            let it = item(k.title, #selector(toggleScroll), "")
            it.tag = n
            it.state = ScrollReverser.shared.isOn(k) ? .on : .off
            sub.addItem(it)
            if k == .enabled { sub.addItem(.separator()) }
        }
        scroll.submenu = sub
        menu.addItem(scroll)
        // 마우스 — Logi Options+ 대신
        let mouse = NSMenuItem(title: "마우스", action: nil, keyEquivalent: "")
        let msub = NSMenu()
        for (n, k) in MouseTools.Key.allCases.enumerated() {
            let it = item(k.title, #selector(toggleMouse), ""); it.tag = n
            it.state = MouseTools.shared.isOn(k) ? .on : .off; msub.addItem(it)
        }
        msub.addItem(.separator())
        for (n, (name, v)) in MouseTools.speeds.enumerated() {
            let it = item("휠 속도: \(name)", #selector(setMouseSpeed), ""); it.tag = n
            it.state = MouseTools.shared.speed == v ? .on : .off; msub.addItem(it)
        }
        mouse.submenu = msub
        menu.addItem(mouse)
        // OBS — 녹화 상태는 노치에, 시작·정지는 여기서
        let obsItem = NSMenuItem(title: "OBS", action: nil, keyEquivalent: "")
        obsMenu = NSMenu()
        obsMenu.delegate = self
        obsItem.submenu = obsMenu
        menu.addItem(obsItem)
        menu.addItem(.separator())
        let login = item("로그인 시 자동 실행", #selector(toggleLogin), "")
        login.state = SMAppService.mainApp.status == .enabled ? .on : .off
        menu.addItem(login)
        menu.addItem(.separator())
        menu.addItem(item("Dynamic Notch 종료", #selector(quit), "q"))
        statusItem.menu = menu
    }

    private func item(_ title: String, _ sel: Selector, _ key: String) -> NSMenuItem {
        let i = NSMenuItem(title: title, action: sel, keyEquivalent: key)
        i.target = self
        return i
    }

    /// OBS 메뉴는 열 때마다 상태에 맞게 새로 만든다
    func menuNeedsUpdate(_ menu: NSMenu) {
        guard menu === obsMenu else { return }
        menu.removeAllItems()
        let cfg = OBSProvider.readConfig()
        if cfg == nil || cfg?.enabled == false {
            menu.addItem(item("OBS 원격 제어 켜기", #selector(enableOBS), ""))
            return
        }
        if !obs.obsRunning {
            menu.addItem(item("OBS 열기", #selector(launchOBS), ""))
            return
        }
        guard obs.connected else {
            let it = NSMenuItem(title: "OBS 연결 중… (켜기 전에 열린 OBS 는 다시 켜야 함)", action: nil, keyEquivalent: "")
            it.isEnabled = false; menu.addItem(it)
            return
        }
        menu.addItem(item(obs.recording ? "녹화 정지" : "녹화 시작", #selector(toggleRecord), ""))
        if obs.recording {
            menu.addItem(item(model.recording?.paused == true ? "녹화 재개" : "녹화 일시정지", #selector(pauseRecord), ""))
        }
    }

    @objc func toggleRecord() { obs.toggleRecord() }
    @objc func pauseRecord() { obs.togglePause() }
    @objc func launchOBS() {
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: OBSProvider.bundleID) {
            NSWorkspace.shared.openApplication(at: url, configuration: .init())
        }
    }
    @objc func enableOBS() {
        let ok = OBSProvider.enableServer()
        let a = NSAlert()
        a.messageText = ok ? "OBS 원격 제어를 켰습니다" : "OBS 설정 파일을 찾지 못했습니다"
        a.informativeText = ok ? (obs.obsRunning ? "OBS 를 한 번 껐다 켜면 노치에 녹화 상태가 뜹니다." : "OBS 를 켜면 노치에 녹화 상태가 뜹니다.")
            : "OBS 를 한 번 실행한 뒤 다시 시도하세요."
        NSApp.activate(ignoringOtherApps: true)
        a.runModal()
    }

    @objc func runDemo() { NotchDemo.run(model) }
    @objc func openMirror() { model.open(.camera) }
    @objc func openUsage() { model.open(.usage) }
    @objc func openSensors() { model.open(.sensors) }
    @objc func quit() { NSApp.terminate(nil) }

    @objc func toggleMouse(_ sender: NSMenuItem) {
        let k = MouseTools.Key.allCases[sender.tag]
        MouseTools.shared.toggle(k)
        sender.state = MouseTools.shared.isOn(k) ? .on : .off
    }

    @objc func setMouseSpeed(_ sender: NSMenuItem) {
        MouseTools.shared.setSpeed(MouseTools.speeds[sender.tag].1)
        sender.menu?.items.filter { $0.action == #selector(setMouseSpeed) }.forEach { $0.state = .off }
        sender.state = .on
    }

    @objc func toggleScroll(_ sender: NSMenuItem) {
        let k = ScrollReverser.Key.allCases[sender.tag]
        ScrollReverser.shared.toggle(k)
        sender.state = ScrollReverser.shared.isOn(k) ? .on : .off
    }

    @objc func toggleLogin(_ sender: NSMenuItem) {
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
        } catch {
            NSLog("DynamicNotch: login item 오류 \(error)")
        }
        sender.state = SMAppService.mainApp.status == .enabled ? .on : .off
    }
}

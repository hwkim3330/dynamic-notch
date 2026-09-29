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
final class AppDelegate: NSObject, NSApplicationDelegate {
    let model = NotchModel()
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
        providers = [nowPlaying, ClaudeProvider(model: model), CodexProvider(model: model),
                     BatteryProvider(model: model), ScreenLockProvider(model: model),
                     SensorProvider(model: model), DownloadsProvider(model: model), RemoteProvider(model: model),
                     UsageProvider(model: model)]

        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                                               object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.panel.reposition() }
        }
        setupStatusItem()
        watchSleep()

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
                MainActor.assumeIsolated { self?.panel.reposition() }
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

    @objc func runDemo() { NotchDemo.run(model) }
    @objc func openMirror() { model.open(.camera) }
    @objc func openUsage() { model.open(.usage) }
    @objc func quit() { NSApp.terminate(nil) }

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

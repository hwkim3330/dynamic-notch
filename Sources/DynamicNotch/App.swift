import AppKit
import SwiftUI
import ServiceManagement
import NotchKit

@main
struct Main {
    static func main() {
        // Claude Code 훅에서 불릴 때: 이벤트만 넘기고 바로 종료 (UI 없음)
        if CommandLine.arguments.contains("--claude-hook") { ClaudeHook.run() }

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
        providers = [nowPlaying, ClaudeProvider(model: model), BatteryProvider(model: model),
                     ScreenLockProvider(model: model), SensorProvider(model: model)]

        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                                               object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.panel.reposition() }
        }
        setupStatusItem()

        if CommandLine.arguments.contains("--demo") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [model] in NotchDemo.run(model) }
        }
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

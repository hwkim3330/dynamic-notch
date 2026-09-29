import AppKit
import SwiftUI
import Combine
import NotchKit

/// 첫 클릭부터 버튼이 눌리도록
final class FirstMouseHostingView<V: View>: NSHostingView<V> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// 화면 맨 위, 물리 노치 바로 위에 떠 있는 투명 패널.
/// 노치 모양 밖은 클릭이 통과하도록 마우스 위치를 추적해 ignoresMouseEvents 를 토글한다.
@MainActor
final class NotchPanel: NSPanel {
    static let canvas = CGSize(width: 780, height: 300)
    let model: NotchModel
    private var timer: Timer?
    private var screenRef: NSScreen?

    init(model: NotchModel) {
        self.model = model
        super.init(contentRect: CGRect(origin: .zero, size: Self.canvas),
                   styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: false)
        isFloatingPanel = true
        level = NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue + 3)
        collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        backgroundColor = .clear
        isOpaque = false
        hasShadow = false
        ignoresMouseEvents = true
        isMovable = false
        hidesOnDeactivate = false

        let host = FirstMouseHostingView(rootView: NotchView(model: model)
            .frame(width: Self.canvas.width, height: Self.canvas.height))
        host.frame = CGRect(origin: .zero, size: Self.canvas)
        contentView = host

        setTracking(true)
        // 다른 곳을 클릭하면 접는다 (메뉴에서 연 미러 등)
        NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            MainActor.assumeIsolated { self?.model.collapse() }
        }
    }

    /// 마우스 위치 추적 (20Hz). 화면이 꺼져 있으면 끈다.
    func setTracking(_ on: Bool) {
        timer?.invalidate()
        timer = nil
        guard on else { return }
        let t = Timer(timeInterval: 1 / 20, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.trackMouse() }
        }
        t.tolerance = 0.01
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    /// 노치가 있는 내장 화면을 우선, 없으면 메인 화면에 가상 노치
    func reposition() {
        let screen = NSScreen.screens.first { $0.safeAreaInsets.top > 0 } ?? NSScreen.main ?? NSScreen.screens[0]
        screenRef = screen
        let f = screen.frame
        var size = CGSize(width: 190, height: 32)
        var centerX = f.midX
        if screen.safeAreaInsets.top > 0,
           let l = screen.auxiliaryTopLeftArea, let r = screen.auxiliaryTopRightArea {
            size = CGSize(width: r.minX - l.maxX, height: screen.safeAreaInsets.top)
            centerX = (l.maxX + r.minX) / 2
        } else {
            size.height = max(24, f.maxY - screen.visibleFrame.maxY)
        }
        model.notchSize = size
        setFrame(CGRect(x: centerX - Self.canvas.width / 2, y: f.maxY - Self.canvas.height,
                        width: Self.canvas.width, height: Self.canvas.height), display: true)
    }

    static var menuBarAutoHides: Bool {
        UserDefaults(suiteName: UserDefaults.globalDomain)?.bool(forKey: "_HIHideMenuBar") ?? false
    }

    private func trackMouse() {
        guard let screen = screenRef else { return }
        // 메뉴 막대가 없는 상태 = 전체 화면 앱 (메뉴 막대 자동 숨김을 켠 사람은 제외)
        let fullscreen = !Self.menuBarAutoHides && screen.visibleFrame.maxY >= screen.frame.maxY - 1
        if model.quietForFullscreen != fullscreen { model.quietForFullscreen = fullscreen }
        let l = model.currentLayout.outerSize
        let top = screen.frame.maxY
        let cx = frame.midX
        var rect = CGRect(x: cx - l.width / 2, y: top - l.height, width: l.width, height: l.height)
        // 접힌 노치는 살짝 넓게 잡아 쉽게 호버되도록
        if model.content == .idle { rect = rect.insetBy(dx: -4, dy: -2) }
        let inside = rect.contains(NSEvent.mouseLocation)
        if ignoresMouseEvents == inside { ignoresMouseEvents = !inside }
        model.setHover(inside)
    }
}

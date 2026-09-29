import SwiftUI

/// 노치 전체. 부모 프레임의 위쪽 가운데에 붙어서 모양/내용을 스프링으로 모핑한다.
public struct NotchView: View {
    @ObservedObject var model: NotchModel

    public init(model: NotchModel) { self.model = model }

    static let spring = Animation.spring(response: 0.44, dampingFraction: 0.76)

    public var body: some View {
        let content = model.content
        let l = model.layout(for: content)
        let shape = NotchShape(topRadius: l.topRadius, bottomRadius: l.bottomRadius)

        ZStack(alignment: .top) {
            shape.fill(Color.black)
            ContentSwitch(model: model, content: content)
                .id(content.kind)
                .transition(.blurFade)
                .padding(.horizontal, l.topRadius)
        }
        .frame(width: l.outerSize.width, height: l.outerSize.height, alignment: .top)
        .mask(shape)
        // 노치 없는 화면: 쉬는 동안엔 안 보이게 (위로 말려 올라감)
        .opacity(!model.hasPhysicalNotch && content == .idle ? 0 : 1)
        .offset(y: !model.hasPhysicalNotch && content == .idle ? -l.outerSize.height : 0)
        .background(alignment: .top) { Glow(color: glowColor(content), shape: shape) }
        .contentShape(shape)
        .onTapGesture { tapped(content) }
        .animation(Self.spring, value: content)
        .animation(Self.spring, value: model.notchSize)
        .animation(Self.spring, value: model.sessions.count)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .environment(\.notchSize, model.notchSize)
    }

    private func tapped(_ c: NotchContent) {
        switch c {
        case .idle, .peek, .musicCompact, .claudeCompact, .callCompact: model.open(nil)
        case .transient(.claude): model.dismissTransient(); model.open(.claude)
        case .transient(.download(_, let path)): model.dismissTransient(); model.onRevealFile?(path)
        default: break
        }
    }

    /// 영상처럼 활동이 뜰 때 아래로 은은하게 번지는 색
    private func glowColor(_ c: NotchContent) -> Color {
        switch c {
        case .musicCompact: model.media?.tint ?? .clear
        case .expanded(.music): model.media?.tint ?? .clear
        case .claudeCompact:
            model.headlineSession?.state == .attention ? ClawdView.ochre
                : (model.headlineSession?.agent == .codex ? .white : ClawdView.clay)
        case .transient(.claude(_, _, _, _, let agent)): agent == .claude ? ClawdView.clay : .white
        case .callRinging, .callCompact: .green
        case .transient(.battery(_, let plugged)): plugged ? .green : .clear
        case .transient(.faceID(let ok)), .transient(.unlock(let ok)): ok ? .green : .white
        case .transient(.sensor(let camera, let on)): on ? (camera ? .green : .orange) : .clear
        case .transient(.remote(let on)): on ? .red : .clear
        default: .clear
        }
    }
}

private struct Glow: View {
    let color: Color
    let shape: NotchShape
    var body: some View {
        shape.fill(color.opacity(0.55))
            .blur(radius: 18)
            .offset(y: 6)
            .opacity(color == .clear ? 0 : 0.7)
    }
}

private struct ContentSwitch: View {
    @ObservedObject var model: NotchModel
    let content: NotchContent

    var body: some View {
        switch content {
        case .idle:
            Color.clear
        case .peek:
            PeekView(mood: model.clawdMood, open: { model.open($0) })
        case .musicCompact:
            if let m = model.media { CompactMusicView(media: m) }
        case .claudeCompact:
            if let s = model.headlineSession {
                CompactClaudeView(session: s, others: model.sessions.filter { $0.state != .done }.count - 1)
            }
        case .callCompact:
            if case .active(_, let since) = model.call { CompactCallView(since: since) }
        case .callRinging:
            if case .ringing(let name, let sub) = model.call {
                RingingCallView(name: name, subtitle: sub,
                                accept: { model.acceptCall() }, decline: { model.endCall() })
            }
        case .transient(let t):
            TransientView(transient: t)
        case .expanded(let tab):
            ExpandedView(model: model, tab: tab)
        }
    }
}

/// 펼친 판: 위 날개에 탭, 아래에 탭 내용
private struct ExpandedView: View {
    @Environment(\.notchSize) var n
    @ObservedObject var model: NotchModel
    let tab: NotchTab

    var body: some View {
        ZStack(alignment: .top) {
            Wings(inset: 14) {
                HStack(spacing: 4) {
                    ForEach(model.availableTabs, id: \.self) { t in
                        TabButton(tab: t, selected: t == tab) {
                            withAnimation(NotchView.spring) { model.tab = t }
                        }
                    }
                }
            } right: {
                Text(tab.title)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.5))
            }
            Group {
                switch tab {
                case .claude:
                    ClaudePanel(sessions: model.sessions, mood: model.clawdMood, open: { model.onOpenSession?($0) })
                case .music:
                    if let m = model.media { ExpandedMusicView(media: m, controls: model.controls) }
                case .camera:
                    CameraPanel(make: model.cameraView)
                case .usage:
                    UsagePanel(usage: model.usage, limits: model.limits)
                }
            }
            .id(tab)
            .transition(.blurFade)
        }
    }
}

private struct TabButton: View {
    let tab: NotchTab
    let selected: Bool
    let action: () -> Void
    @State private var hover = false
    var body: some View {
        Button(action: action) {
            Group {
                if tab == .claude {
                    ClawdGlyph().frame(width: 15, height: 11)
                } else {
                    Image(systemName: tab.symbol).font(.system(size: 11, weight: .semibold))
                }
            }
            .foregroundStyle(.white.opacity(selected ? 1 : 0.5))
            .frame(width: 26, height: 22)
            .background(Capsule().fill(.white.opacity(selected ? 0.16 : hover ? 0.08 : 0)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
    }
}

// MARK: - 환경값 / 전환

private struct NotchSizeKey: EnvironmentKey { static let defaultValue = CGSize(width: 185, height: 32) }
extension EnvironmentValues {
    var notchSize: CGSize {
        get { self[NotchSizeKey.self] }
        set { self[NotchSizeKey.self] = newValue }
    }
}

private struct BlurFade: ViewModifier {
    let radius: CGFloat
    let opacity: Double
    let scale: CGFloat
    func body(content: Content) -> some View {
        content.blur(radius: radius).opacity(opacity).scaleEffect(scale, anchor: .top)
    }
}

extension AnyTransition {
    static var blurFade: AnyTransition {
        .asymmetric(
            insertion: .modifier(active: BlurFade(radius: 10, opacity: 0, scale: 0.86),
                                 identity: BlurFade(radius: 0, opacity: 1, scale: 1))
                .animation(.easeOut(duration: 0.32).delay(0.06)),
            removal: .modifier(active: BlurFade(radius: 8, opacity: 0, scale: 0.9),
                               identity: BlurFade(radius: 0, opacity: 1, scale: 1))
                .animation(.easeIn(duration: 0.14))
        )
    }
}

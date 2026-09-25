import SwiftUI

/// 노치 전체. 부모 프레임의 위쪽 가운데에 붙어서 모양/내용을 스프링으로 모핑한다.
public struct NotchView: View {
    @ObservedObject var model: NotchModel

    public init(model: NotchModel) { self.model = model }

    static let spring = Animation.spring(response: 0.44, dampingFraction: 0.74)

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
        .background(alignment: .top) { Glow(model: model, content: content, shape: shape) }
        .contentShape(shape)
        .onTapGesture {
            if content == .musicCompact || content == .idle || content == .callCompact {
                model.setExpanded(true)
            }
        }
        .animation(Self.spring, value: content)
        .animation(Self.spring, value: model.notchSize)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .environment(\.notchSize, model.notchSize)
    }
}

/// 영상처럼 활동이 뜰 때 아래로 은은하게 번지는 색 번짐
private struct Glow: View {
    @ObservedObject var model: NotchModel
    let content: NotchContent
    let shape: NotchShape

    var color: Color {
        switch content {
        case .idle: .clear
        case .musicCompact, .expandedMusic: model.media?.tint ?? .clear
        case .callRinging, .callCompact: .green
        case .transient(let t):
            switch t {
            case .battery(_, let charging, let plugged): (charging || plugged) ? .green : .clear
            case .faceID(let ok), .unlock(let ok): ok ? .green : .white
            default: .clear
            }
        case .expandedHome: .clear
        }
    }

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
        case .musicCompact:
            if let m = model.media { CompactMusicView(media: m) }
        case .callCompact:
            if case .active(_, let since) = model.call { CompactCallView(since: since) }
        case .callRinging:
            if case .ringing(let name, let sub) = model.call {
                RingingCallView(name: name, subtitle: sub,
                                accept: { model.acceptCall() }, decline: { model.endCall() })
            }
        case .transient(let t):
            TransientView(transient: t)
        case .expandedMusic:
            if let m = model.media { ExpandedMusicView(media: m, controls: model.controls) }
        case .expandedHome:
            ExpandedHomeView(battery: model.battery, volume: model.volume, call: model.call,
                             endCall: { model.endCall() })
        }
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

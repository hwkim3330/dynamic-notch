import SwiftUI
import QuartzCore

/// 노치에 몇 시간씩 떠 있는 작은 애니메이션은 SwiftUI 로 매 프레임 다시 그리면 CPU 를 계속 쓴다.
/// 대신 한 번 프레임들을 구워 두고 Core Animation 키프레임으로 돌린다 → 재생은 WindowServer 가 하고 앱은 쉰다.
@MainActor
enum SpriteCache {
    static let fps = 12.0
    static let loop = 10.0   // 초. 이 길이로 반복 (파형/걸음/두리번 주기가 대략 맞아떨어지는 길이)
    private static var store: [String: [CGImage]] = [:]

    static func frames<V: View>(key: String, scale: CGFloat, make: (Double) -> V) -> [CGImage] {
        let k = "\(key)@\(scale)"
        if let f = store[k] { return f }
        var out: [CGImage] = []
        let n = Int(loop * fps)
        for i in 0..<n {
            let r = ImageRenderer(content: make(Double(i) / fps))
            r.scale = scale
            if let img = r.cgImage { out.append(img) }
        }
        store[k] = out
        return out
    }
}

#if os(macOS)
struct SpritePlayer: NSViewRepresentable {
    let frames: [CGImage]
    func makeNSView(context: Context) -> NSView {
        let v = NSView()
        v.wantsLayer = true
        apply(v.layer!)
        return v
    }
    func updateNSView(_ v: NSView, context: Context) {
        if (v.layer?.animation(forKey: "sprite") as? CAKeyframeAnimation)?.values?.count != frames.count { apply(v.layer!) }
    }
    private func apply(_ layer: CALayer) {
        layer.contentsGravity = .resizeAspect
        layer.contents = frames.first
        guard frames.count > 1 else { return }
        let a = CAKeyframeAnimation(keyPath: "contents")
        a.values = frames
        a.calculationMode = .discrete
        a.duration = Double(frames.count) / SpriteCache.fps
        a.repeatCount = .infinity
        a.isRemovedOnCompletion = false
        layer.add(a, forKey: "sprite")
    }
}
#else
struct SpritePlayer: UIViewRepresentable {
    let frames: [CGImage]
    func makeUIView(context: Context) -> UIView {
        let v = UIView()
        v.layer.contentsGravity = .resizeAspect
        v.layer.contents = frames.first
        if frames.count > 1 {
            let a = CAKeyframeAnimation(keyPath: "contents")
            a.values = frames
            a.calculationMode = .discrete
            a.duration = Double(frames.count) / SpriteCache.fps
            a.repeatCount = .infinity
            a.isRemovedOnCompletion = false
            v.layer.add(a, forKey: "sprite")
        }
        return v
    }
    func updateUIView(_ v: UIView, context: Context) {}
}
#endif

/// 컴팩트용 에이전트 얼굴 (스프라이트)
struct AgentSprite: View {
    @Environment(\.displayScale) var scale
    let agent: AgentKind
    let mood: ClawdMood
    let unit: CGFloat

    var body: some View {
        let key = "\(agent.rawValue).\(mood).\(unit)"
        let frames = SpriteCache.frames(key: key, scale: scale) { t in
            Group {
                if agent == .claude { ClawdView.Still(view: ClawdView(mood: mood, unit: unit), t: t) }
                else { CodexBot.Still(mood: mood, unit: unit, t: t) }
            }
        }
        SpritePlayer(frames: frames)
            .frame(width: unit * 15, height: unit * 13.5)
    }
}

/// 컴팩트용 파형 (스프라이트)
struct WaveSprite: View {
    @Environment(\.displayScale) var scale
    let color: Color
    let height: CGFloat
    var body: some View {
        let key = "wave.\(color.description).\(height)"
        let frames = SpriteCache.frames(key: key, scale: scale) { t in
            Waveform.Still(color: color, height: height, t: t)
        }
        SpritePlayer(frames: frames).frame(width: 5 * 3 + 4 * 2.2, height: height)
    }
}

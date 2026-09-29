import SwiftUI

/// Clawd의 기분. Claude Code 세션 상태와 1:1로 대응한다.
public enum ClawdMood: Equatable {
    case idle        // 대기: 천천히 숨쉬며 깜빡임
    case working     // 작업 중: 제자리 걸음, 두리번
    case done        // 완료: 깡총 뛰며 ^^ 눈 + 반짝
    case attention   // 확인 필요: 팔 흔들기 + 느낌표
    case sleeping    // 오래 쉼: 눈 감고 zzz
}

/// Clawd — ClaudeAnimationBase(clawd.js)의 블록 실루엣을 SwiftUI Canvas로 옮긴 것.
/// 좌표는 clawd.js와 같다. u = 몸 단위, 몸은 x -5u…5u, y -8u…-2u, 다리는 y 0까지, (0,0)은 발 사이 바닥.
public struct ClawdView: View {
    public var mood: ClawdMood
    public var unit: CGFloat
    public var seed: Double

    public init(mood: ClawdMood, unit: CGFloat = 3, seed: Double = 0) {
        self.mood = mood; self.unit = unit; self.seed = seed
    }

    static let clay = Color(red: 0.851, green: 0.467, blue: 0.341)   // #D97757
    static let clayDk = Color(red: 0.659, green: 0.302, blue: 0.2)   // #A84D33
    static let clayLt = Color(red: 0.949, green: 0.635, blue: 0.514) // #F2A283
    static let ink = Color(red: 0.169, green: 0.133, blue: 0.2)      // #2B2233
    static let ochre = Color(red: 0.91, green: 0.667, blue: 0.22)    // #E8AA38
    static let cream = Color(red: 1, green: 0.961, blue: 0.886)      // #FFF5E2

    public var body: some View {
        // 노치 날개에 들어가는 작은 크기는 12fps 로도 충분하다 (몇 시간씩 떠 있으니 전력 절약)
        TimelineView(.animation(minimumInterval: unit < 3 ? 1 / 10 : 1 / 24, paused: AnimationGate.paused)) { tl in
            let t = tl.date.timeIntervalSinceReferenceDate + seed * 3.7
            Canvas { ctx, size in
                draw(&ctx, size: size, t: t)
            }
        }
        .frame(width: unit * 15, height: unit * 13.5)
    }

    // MARK: 포즈 (clawd.js move()/feel() 축약)

    struct Pose {
        var dy = 0.0, sq = 0.0, rot = 0.0, dx = 0.0
        var aL = 0.2, aR = 0.2
        var walk: Double? = nil
        var eyes = "normal"
        var lookX = 0.0
        var emote: String? = nil
    }

    func pose(_ t: Double) -> Pose {
        var p = Pose()
        switch mood {
        case .idle:
            let bp = t * 0.9, s = abs(sin(bp * .pi))
            p.dy = -s * 0.35; p.sq = max(0, 1 - (bp - floor(bp)) * 3.5) * 0.04
        case .working:
            let bp = t * 2.4, s1 = sin(bp * .pi)
            p.walk = bp / 2; p.dy = -abs(s1) * 0.6
            p.aL = 0.3 * s1 + 0.2; p.aR = -0.3 * s1 + 0.2
            p.eyes = "look"; p.lookX = sin(t * 1.3) * 0.8
        case .done:
            let bp = t * 1.7, ab = abs(sin(bp * .pi)), hit = max(0, 1 - (bp - floor(bp)) * 3.5)
            p.dy = -ab * 3.2; p.sq = hit * 0.18; p.aL = 0.3 + ab * 1.1; p.aR = p.aL
            p.eyes = "happy"; p.emote = "spark"
        case .attention:
            let bp = t * 1.6, ab = abs(sin(bp * .pi))
            p.dy = -ab * 0.8; p.aL = 1.1 + 0.5 * sin(bp * .pi * 4); p.aR = -0.2
            p.eyes = "wide"; p.emote = "!"
        case .sleeping:
            p.sq = 0.03 * sin(t * 1.6); p.eyes = "closed"; p.emote = "zzz"; p.aL = -0.3; p.aR = -0.3
        }
        return p
    }

    // MARK: 그리기

    func draw(_ ctx: inout GraphicsContext, size: CGSize, t: Double) {
        let u = unit
        let p = pose(t)
        let ground = CGPoint(x: size.width / 2 + p.dx * u, y: size.height - u * 0.6)

        // 그림자
        let shadowK = 1 - min(0.5, abs(p.dy) * 0.08)
        ctx.fill(Path(ellipseIn: CGRect(x: ground.x - 5.4 * u * shadowK, y: ground.y - 0.5 * u * shadowK,
                                        width: 10.8 * u * shadowK, height: 1.0 * u * shadowK)),
                 with: .color(.white.opacity(0.08)))

        var c = ctx
        c.translateBy(x: ground.x, y: ground.y + p.dy * u)
        c.rotate(by: .radians(p.rot))
        c.scaleBy(x: 1 + p.sq * 0.6, y: 1 - p.sq)

        func rect(_ x: Double, _ y: Double, _ w: Double, _ h: Double) -> Path {
            Path(roundedRect: CGRect(x: x * u, y: y * u, width: w * u, height: h * u),
                 cornerRadius: u * 0.12)
        }

        // 팔 (몸 뒤)
        for (px, dir, a) in [(-4.9, -1.0, p.aL), (4.9, 1.0, p.aR)] {
            var a2 = c
            let slide = dir * 0.55 * max(0, min(1, (abs(a) - 0.7) / 0.9))
            a2.translateBy(x: (px + slide) * u, y: -4.5 * u)
            a2.rotate(by: .radians(dir < 0 ? a : -a))
            a2.fill(rect(dir < 0 ? -2.2 : 0, -0.5, 2.2, 1), with: .color(Self.clay))
            a2.fill(rect(dir < 0 ? -2.2 : 0, 0.1, 2.2, 0.4), with: .color(Self.clayDk.opacity(0.45)))
        }

        // 다리
        for (i, lx) in [-4.0, -2.0, 1.0, 3.0].enumerated() {
            var h = 2.2
            if let w = p.walk {
                let ph = sin((w + (i % 2 == 1 ? 0.5 : 0)) * 2 * .pi)
                if ph > 0 { h = 2.2 - ph * 0.9 }
            }
            c.fill(rect(lx, -2.4, 1, h), with: .color(Self.clayDk))
        }

        // 몸통 + 하이라이트 + 아래 그늘
        c.fill(rect(-5, -8, 10, 6), with: .color(Self.clay))
        c.fill(Path(ellipseIn: CGRect(x: -4.2 * u, y: -7.6 * u, width: 5.2 * u, height: 2.2 * u)),
               with: .color(Self.clayLt.opacity(0.45)))
        c.fill(rect(-4.8, -3.8, 9.6, 1.6), with: .color(Self.clayDk.opacity(0.4)))

        // 눈
        let blink = ["normal", "look", "wide"].contains(p.eyes)
            && (t * 0.9 + seed * 1.7).truncatingRemainder(dividingBy: 3.3) < 0.12
        for s in [-1.0, 1.0] {
            let cx = s * 2.5 + p.lookX * 0.5, cy = -6.0
            if blink {
                c.fill(rect(cx - 0.7, cy + 0.35, 1.4, 0.3), with: .color(Self.ink))
                continue
            }
            switch p.eyes {
            case "wide":
                c.fill(rect(cx - 0.62, cy - 1.35, 1.25, 2.7), with: .color(Self.ink))
                c.fill(Path(ellipseIn: CGRect(x: (cx - 0.45) * u, y: (cy - 1.0) * u, width: 0.4 * u, height: 0.55 * u)),
                       with: .color(Self.cream))
            case "happy":
                var l = Path()
                l.move(to: CGPoint(x: (cx - 0.9) * u, y: (cy + 0.7) * u))
                l.addLine(to: CGPoint(x: cx * u, y: (cy - 0.5) * u))
                l.addLine(to: CGPoint(x: (cx + 0.9) * u, y: (cy + 0.7) * u))
                c.stroke(l, with: .color(Self.ink), style: StrokeStyle(lineWidth: max(1, u * 0.35), lineCap: .round, lineJoin: .round))
            case "closed":
                var l = Path()
                l.move(to: CGPoint(x: (cx - 0.9) * u, y: (cy + 0.2) * u))
                l.addQuadCurve(to: CGPoint(x: (cx + 0.9) * u, y: (cy + 0.2) * u),
                               control: CGPoint(x: cx * u, y: (cy + 1.0) * u))
                c.stroke(l, with: .color(Self.ink), style: StrokeStyle(lineWidth: max(1, u * 0.3), lineCap: .round))
            default:
                c.fill(rect(cx - 0.5, cy - 1, 1, 2), with: .color(Self.ink))
            }
        }

        // 감정 표시
        switch p.emote {
        case "!":
            let wob = sin(t * 10) * 0.08
            var e = c
            e.translateBy(x: 0, y: -10.2 * u)
            e.rotate(by: .radians(0.1 + wob))
            var bang = Path()
            bang.move(to: CGPoint(x: -0.62 * u, y: -2.3 * u)); bang.addLine(to: CGPoint(x: 0.62 * u, y: -2.3 * u))
            bang.addLine(to: CGPoint(x: 0.22 * u, y: 0.45 * u)); bang.addLine(to: CGPoint(x: -0.22 * u, y: 0.45 * u))
            bang.closeSubpath()
            e.fill(bang, with: .color(Self.ochre))
            e.fill(Path(ellipseIn: CGRect(x: -0.42 * u, y: 0.85 * u, width: 0.84 * u, height: 0.84 * u)), with: .color(Self.ochre))
        case "spark":
            let tw = 1 + 0.2 * sin(t * 12)
            star(&c, at: CGPoint(x: 6.2 * u, y: -9 * u), r: 1.3 * u * tw, color: Self.cream)
            star(&c, at: CGPoint(x: 8 * u, y: -7.2 * u), r: 0.7 * u / tw, color: Self.ochre)
        case "zzz":
            for i in 0..<3 {
                let ph = (t * 0.4 + Double(i) / 3).truncatingRemainder(dividingBy: 1)
                let a = sin(ph * .pi)
                guard a > 0.12 else { continue }
                let zs = (0.8 + ph * 0.7) * min(1, a * 1.6)
                var z = c
                z.opacity = a
                z.draw(Text("z").font(.system(size: 2.4 * u * zs, weight: .heavy, design: .rounded))
                    .foregroundStyle(Self.cream),
                       at: CGPoint(x: (5.2 + ph * 2.6) * u, y: (-8.6 - ph * 4.2) * u))
            }
        default: break
        }
    }

    private func star(_ c: inout GraphicsContext, at o: CGPoint, r: CGFloat, color: Color) {
        var s = Path()
        for k in 0..<8 {
            let ang = Double(k) * .pi / 4 - .pi / 2
            let rr = k % 2 == 0 ? r : r * 0.32
            let pt = CGPoint(x: o.x + cos(ang) * rr, y: o.y + sin(ang) * rr)
            k == 0 ? s.move(to: pt) : s.addLine(to: pt)
        }
        s.closeSubpath()
        c.fill(s, with: .color(color))
    }
}

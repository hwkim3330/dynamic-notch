import SwiftUI
import CoreImage

public enum ArtworkTint {
    /// 앨범아트 평균색을 노치 위에서 잘 보이게 채도/밝기를 끌어올린 색
    public static func color(of image: CGImage) -> Color {
        let ci = CIImage(cgImage: image)
        guard let f = CIFilter(name: "CIAreaAverage",
                               parameters: [kCIInputImageKey: ci,
                                            kCIInputExtentKey: CIVector(cgRect: ci.extent)]),
              let out = f.outputImage else { return .white }
        var px = [UInt8](repeating: 0, count: 4)
        CIContext(options: [.workingColorSpace: NSNull()])
            .render(out, toBitmap: &px, rowBytes: 4, bounds: CGRect(x: 0, y: 0, width: 1, height: 1),
                    format: .RGBA8, colorSpace: nil)
        var (h, s, b) = hsb(Double(px[0]) / 255, Double(px[1]) / 255, Double(px[2]) / 255)
        if s < 0.12 { return Color(white: 0.92) }
        s = min(1, max(0.55, s * 1.4))
        b = max(0.85, b)
        _ = h
        return Color(hue: h, saturation: s, brightness: b)
    }

    static func hsb(_ r: Double, _ g: Double, _ b: Double) -> (Double, Double, Double) {
        let mx = max(r, g, b), mn = min(r, g, b), d = mx - mn
        var h = 0.0
        if d > 0 {
            if mx == r { h = ((g - b) / d).truncatingRemainder(dividingBy: 6) }
            else if mx == g { h = (b - r) / d + 2 }
            else { h = (r - g) / d + 4 }
            h /= 6; if h < 0 { h += 1 }
        }
        return (h, mx == 0 ? 0 : d / mx, mx)
    }
}

/// 영상 속 장면을 순서대로 재현하는 데모. 실제 이벤트가 없어도 모든 활동을 볼 수 있다.
@MainActor
public enum NotchDemo {
    public static func artwork() -> CGImage? {
        let w = 240
        guard let ctx = CGContext(data: nil, width: w, height: w, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        let cs = CGColorSpaceCreateDeviceRGB()
        let colors = [CGColor(red: 0.95, green: 0.2, blue: 0.35, alpha: 1),
                      CGColor(red: 0.55, green: 0.25, blue: 0.95, alpha: 1),
                      CGColor(red: 0.1, green: 0.05, blue: 0.2, alpha: 1)] as CFArray
        if let g = CGGradient(colorsSpace: cs, colors: colors, locations: [0, 0.55, 1]) {
            ctx.drawLinearGradient(g, start: .zero, end: CGPoint(x: w, y: w), options: [])
        }
        ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 0.18))
        ctx.fillEllipse(in: CGRect(x: 60, y: 60, width: 120, height: 120))
        ctx.setFillColor(CGColor(red: 0.1, green: 0.05, blue: 0.2, alpha: 1))
        ctx.fillEllipse(in: CGRect(x: 108, y: 108, width: 24, height: 24))
        return ctx.makeImage()
    }

    private static var task: Task<Void, Never>?

    public static func run(_ m: NotchModel) {
        task?.cancel()
        task = Task { @MainActor in
            func wait(_ s: Double) async -> Bool {
                try? await Task.sleep(nanoseconds: UInt64(s * 1_000_000_000))
                return !Task.isCancelled
            }
            m.setExpanded(false)
            m.dismissTransient()
            // 1. 전화 수신 → 수락 → 통화 중 컴팩트
            m.call = .ringing(name: "Michael", subtitle: "휴대전화")
            guard await wait(2.6) else { return }
            m.acceptCall()
            guard await wait(3.0) else { return }
            m.endCall()
            guard await wait(0.6) else { return }
            // 2. 음악 재생 컴팩트 → 펼침
            let art = artwork()
            m.demoNowPlaying = NowPlaying(title: "Dolgoch Tape", artist: "Dynamic Notch",
                                          source: "Demo", isPlaying: true, duration: 214, elapsed: 61,
                                          elapsedAt: Date(), artwork: art, artworkKey: "demo",
                                          tint: art.map(ArtworkTint.color(of:)) ?? .pink)
            guard await wait(2.8) else { return }
            m.setExpanded(true)
            guard await wait(3.2) else { return }
            m.setExpanded(false)
            guard await wait(1.6) else { return }
            // 3. Face ID
            m.playFaceID()
            guard await wait(2.8) else { return }
            // 4. 볼륨, 충전
            for v in stride(from: 0.3, through: 0.8, by: 0.1) {
                m.show(.volume(level: v, muted: false), for: 1.4)
                guard await wait(0.12) else { return }
            }
            guard await wait(1.6) else { return }
            m.show(.battery(level: m.battery?.level ?? 82, charging: true, pluggedIn: true), for: 2.2)
            guard await wait(2.6) else { return }
            m.show(.device(name: "AirPods Pro", symbol: "airpodspro", connected: true), for: 2.2)
            guard await wait(2.6) else { return }
            m.demoNowPlaying = nil
        }
    }
}

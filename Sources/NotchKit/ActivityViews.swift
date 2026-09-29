import SwiftUI

// MARK: - 공용 조각

struct ArtworkView: View {
    let image: CGImage?
    let tint: Color
    let side: CGFloat
    let radius: CGFloat

    var body: some View {
        ZStack {
            if let image {
                Image(decorative: image, scale: 1).resizable().aspectRatio(contentMode: .fill)
            } else {
                LinearGradient(colors: [tint.opacity(0.9), tint.opacity(0.35)],
                               startPoint: .topLeading, endPoint: .bottomTrailing)
                Image(systemName: "music.note").font(.system(size: side * 0.45, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.85))
            }
        }
        .frame(width: side, height: side)
        .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
    }
}

/// 재생 중 파형 (오디오를 직접 탭하지 않고 부드러운 노이즈로 움직임)
struct Waveform: View {
    var color: Color
    var active: Bool
    var bars = 5
    var height: CGFloat = 16

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 30, paused: !active)) { tl in
            let t = tl.date.timeIntervalSinceReferenceDate
            HStack(alignment: .center, spacing: 2.2) {
                ForEach(0..<bars, id: \.self) { i in
                    Capsule().fill(color)
                        .frame(width: 3, height: barHeight(i, t))
                }
            }
            .frame(height: height)
        }
    }

    private func barHeight(_ i: Int, _ t: Double) -> CGFloat {
        guard active else { return 3 }
        let d = Double(i)
        let a = sin(t * (6.1 + d * 1.73) + d * 1.3)
        let b = sin(t * (2.9 + d * 0.87) + d * 2.4)
        let c = sin(t * 11.3 + d * 0.7) * 0.25
        let v = min(1, abs(a * 0.7 + b * 0.5 + c))
        return 3 + (height - 3) * CGFloat(v)
    }
}

func formatTime(_ t: TimeInterval) -> String {
    let s = max(0, Int(t.rounded(.down)))
    return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, s / 60 % 60, s % 60)
                     : String(format: "%d:%02d", s / 60, s % 60)
}

/// 노치 좌우 날개에 내용을 배치하는 컨테이너 (가운데는 카메라가 있는 물리 노치)
struct Wings<L: View, R: View>: View {
    @Environment(\.notchSize) var n
    var inset: CGFloat = 10
    @ViewBuilder var left: L
    @ViewBuilder var right: R

    var body: some View {
        HStack(spacing: 0) {
            left.frame(maxWidth: .infinity, alignment: .leading)
            Color.clear.frame(width: n.width - inset)
            right.frame(maxWidth: .infinity, alignment: .trailing)
        }
        .padding(.horizontal, inset)
        .frame(height: n.height)
    }
}

// MARK: - 컴팩트

struct CompactMusicView: View {
    @Environment(\.notchSize) var n
    let media: NowPlaying

    var body: some View {
        Wings {
            ArtworkView(image: media.artwork, tint: media.tint, side: n.height - 12, radius: 6)
        } right: {
            Waveform(color: media.tint, active: media.isPlaying, height: n.height * 0.45)
        }
    }
}

struct CompactCallView: View {
    let since: Date
    var body: some View {
        Wings {
            TimelineView(.periodic(from: since, by: 1)) { tl in
                HStack(spacing: 5) {
                    Image(systemName: "phone.fill").font(.system(size: 11, weight: .bold))
                    Text(formatTime(tl.date.timeIntervalSince(since)))
                        .font(.system(size: 13, weight: .semibold).monospacedDigit())
                }
                .foregroundStyle(.green)
                .fixedSize()
            }
        } right: {
            Waveform(color: .green, active: true, bars: 6, height: 14)
        }
    }
}

// MARK: - 통화 수신

struct RingingCallView: View {
    @Environment(\.notchSize) var n
    let name: String
    let subtitle: String
    let accept: () -> Void
    let decline: () -> Void
    @State private var pulse = false

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                Circle().fill(LinearGradient(colors: [.gray.opacity(0.9), .gray.opacity(0.5)],
                                             startPoint: .top, endPoint: .bottom))
                Text(String(name.prefix(1))).font(.system(size: 20, weight: .semibold)).foregroundStyle(.white)
            }
            .frame(width: 44, height: 44)
            VStack(alignment: .leading, spacing: 2) {
                Text(subtitle).font(.system(size: 12)).foregroundStyle(.white.opacity(0.55))
                Text(name).font(.system(size: 17, weight: .semibold)).foregroundStyle(.white)
            }
            Spacer(minLength: 8)
            CircleButton(symbol: "phone.down.fill", color: .red, action: decline)
            CircleButton(symbol: "phone.fill", color: .green, action: accept)
                .scaleEffect(pulse ? 1.07 : 1)
                .animation(.easeInOut(duration: 0.7).repeatForever(autoreverses: true), value: pulse)
        }
        .padding(.horizontal, 16)
        .padding(.top, n.height + 2)
        .onAppear { pulse = true }
    }
}

struct CircleButton: View {
    let symbol: String
    let color: Color
    var size: CGFloat = 40
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: size * 0.42, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: size, height: size)
                .background(Circle().fill(color))
        }
        .buttonStyle(.plain)
    }
}

// MARK: - 일시 알림

struct TransientView: View {
    @Environment(\.notchSize) var n
    let transient: Transient

    var body: some View {
        switch transient {
        case .battery(let level, let plugged):
            Wings {
                Text(plugged ? "충전 중" : "배터리 사용")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(plugged ? .green : (level <= 20 ? .red : .white))
                    .lineLimit(1).fixedSize()
            } right: {
                HStack(spacing: 5) {
                    Text("\(level)%").font(.system(size: 13, weight: .semibold).monospacedDigit())
                    Image(systemName: batterySymbol(level, plugged))
                        .font(.system(size: 17))
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(level <= 20 && !plugged ? .red : .green, .white.opacity(0.5))
                }
                .foregroundStyle(plugged ? .green : .white)
                .fixedSize()
            }
        case .sensor(let camera, let on):
            let color: Color = camera ? .green : .orange
            Wings {
                Image(systemName: camera ? (on ? "video.fill" : "video.slash.fill") : (on ? "mic.fill" : "mic.slash.fill"))
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(on ? color : .white.opacity(0.6))
                    .contentTransition(.symbolEffect(.replace))
            } right: {
                HStack(spacing: 6) {
                    Text(camera ? "카메라" : "마이크").font(.system(size: 13, weight: .semibold))
                    Circle().fill(on ? color : .white.opacity(0.3)).frame(width: 7, height: 7)
                }
                .foregroundStyle(on ? color : .white.opacity(0.6))
                .fixedSize()
            }
        case .unlock(let ok):
            VStack {
                Image(systemName: ok ? "lock.open.fill" : "lock.fill")
                    .font(.system(size: 26, weight: .semibold))
                    .foregroundStyle(ok ? .green : .white)
                    .contentTransition(.symbolEffect(.replace))
                    .symbolEffect(.bounce, value: ok)
            }
            .frame(maxWidth: .infinity)
            .padding(.top, n.height + 6)
        case .faceID(let ok):
            VStack {
                Image(systemName: ok ? "face.smiling" : "faceid")
                    .font(.system(size: 34, weight: .regular))
                    .foregroundStyle(ok ? .green : .white)
                    .contentTransition(.symbolEffect(.replace))
                    .symbolEffect(.pulse, isActive: !ok)
                    .symbolEffect(.bounce, value: ok)
            }
            .frame(maxWidth: .infinity)
            .padding(.top, n.height + 2)
        case .claude(let title, let project, let detail, let mood, let agent):
            ClaudeBanner(title: title, project: project, detail: detail, mood: mood, agent: agent)
        case .download(let name, _):
            HStack(spacing: 12) {
                Image(systemName: "arrow.down.circle.fill")
                    .font(.system(size: 30))
                    .foregroundStyle(.white, Color.accentColor)
                    .symbolEffect(.bounce, value: name)
                VStack(alignment: .leading, spacing: 2) {
                    Text("다운로드 완료").font(.system(size: 14, weight: .semibold)).foregroundStyle(.white)
                    Text(name).font(.system(size: 12)).foregroundStyle(.white.opacity(0.55))
                        .lineLimit(1).truncationMode(.middle)
                }
                Spacer(minLength: 0)
                Text("Finder에서 보기").font(.system(size: 11, weight: .medium)).foregroundStyle(.white.opacity(0.4))
            }
            .padding(.horizontal, 18)
            .padding(.top, n.height + 4)
        case .remote(let on):
            Wings {
                Image(systemName: on ? "display.and.arrow.down" : "display")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(on ? .red : .white.opacity(0.6))
            } right: {
                HStack(spacing: 6) {
                    Text(on ? "원격 접속" : "원격 종료").font(.system(size: 13, weight: .semibold))
                    Circle().fill(on ? Color.red : .white.opacity(0.3)).frame(width: 7, height: 7)
                }
                .foregroundStyle(on ? .red : .white.opacity(0.6))
                .fixedSize()
            }

        }
    }
}

func batterySymbol(_ level: Int, _ charging: Bool) -> String {
    if charging { return "battery.100percent.bolt" }
    switch level {
    case ..<13: return "battery.0percent"
    case ..<38: return "battery.25percent"
    case ..<63: return "battery.50percent"
    case ..<88: return "battery.75percent"
    default: return "battery.100percent"
    }
}

struct Bar: View {
    var value: Double
    var color: Color
    var body: some View {
        GeometryReader { g in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.18))
                Capsule().fill(color).frame(width: max(0, min(1, value)) * g.size.width)
            }
        }
        .frame(height: 5)
    }
}

// MARK: - 펼침

struct ExpandedMusicView: View {
    @Environment(\.notchSize) var n
    let media: NowPlaying
    weak var controls: NotchControls?

    var body: some View {
        VStack(spacing: 12) {
            HStack(spacing: 12) {
                ArtworkView(image: media.artwork, tint: media.tint, side: 58, radius: 12)
                    .shadow(color: media.tint.opacity(0.4), radius: 8)
                VStack(alignment: .leading, spacing: 3) {
                    Text(media.title).font(.system(size: 15, weight: .semibold)).foregroundStyle(.white)
                    Text(media.artist).font(.system(size: 13)).foregroundStyle(.white.opacity(0.6))
                }
                .lineLimit(1)
                Spacer(minLength: 8)
                Waveform(color: media.tint, active: media.isPlaying, bars: 6, height: 22)
            }
            TimelineView(.periodic(from: .now, by: 0.5)) { tl in
                let pos = media.position(at: tl.date)
                HStack(spacing: 8) {
                    Text(formatTime(pos))
                    Bar(value: media.duration > 0 ? pos / media.duration : 0, color: .white.opacity(0.9))
                    Text(media.duration > 0 ? "-" + formatTime(media.duration - pos) : "--:--")
                }
                .font(.system(size: 11, weight: .medium).monospacedDigit())
                .foregroundStyle(.white.opacity(0.55))
            }
            HStack(spacing: 44) {
                ControlButton(symbol: "backward.fill", size: 18) { controls?.previousTrack() }
                ControlButton(symbol: media.isPlaying ? "pause.fill" : "play.fill", size: 24) { controls?.playPause() }
                ControlButton(symbol: "forward.fill", size: 18) { controls?.nextTrack() }
            }
        }
        .padding(.horizontal, 22)
        .padding(.top, n.height + 4)
    }
}

struct ControlButton: View {
    let symbol: String
    let size: CGFloat
    let action: () -> Void
    @State private var hover = false
    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: size, weight: .semibold))
                .foregroundStyle(.white)
                .contentTransition(.symbolEffect(.replace))
                .frame(width: 40, height: 30)
                .background(Circle().fill(.white.opacity(hover ? 0.14 : 0)).frame(width: 38, height: 38))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
    }
}

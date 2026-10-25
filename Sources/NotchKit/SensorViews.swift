import SwiftUI

/// 센서 탭: 화면 각도 + 트랙패드 저울
struct SensorPanel: View {
    @Environment(\.notchSize) var n
    @ObservedObject var model: NotchModel

    var body: some View {
        HStack(alignment: .center, spacing: 26) {
            LidGauge(angle: model.lidAngle)
            Divider().frame(height: 70).overlay(.white.opacity(0.12))
            VStack(alignment: .leading, spacing: 4) {
                Text("트랙패드 저울").font(.system(size: 10, weight: .medium)).foregroundStyle(.white.opacity(0.45))
                HStack(alignment: .firstTextBaseline, spacing: 3) {
                    Text(model.trackpadTouching ? String(format: "%.0f", max(0, model.trackpadGrams ?? 0)) : "—")
                        .font(.system(size: 34, weight: .semibold).monospacedDigit())
                        .contentTransition(.numericText())
                    Text("g").font(.system(size: 15, weight: .semibold)).foregroundStyle(.white.opacity(0.5))
                }
                .foregroundStyle(.white)
                .animation(.easeOut(duration: 0.15), value: model.trackpadGrams)
                Text(model.trackpadTouching ? "손가락을 댄 채로 물건을 올리세요" : "손가락 하나를 트랙패드에 대 보세요")
                    .font(.system(size: 10)).foregroundStyle(.white.opacity(0.4))
            }
            Spacer(minLength: 0)
            Button { model.onTare?() } label: {
                Text("영점").font(.system(size: 11, weight: .semibold))
                    .padding(.horizontal, 12).padding(.vertical, 6)
                    .background(Capsule().fill(.white.opacity(0.12)))
            }
            .buttonStyle(.plain).foregroundStyle(.white)
        }
        .padding(.horizontal, 26)
        .padding(.top, n.height + 10)
    }
}

/// 뚜껑 각도 — 바닥선 위로 화면이 열린 모양을 그린다
private struct LidGauge: View {
    let angle: Int?
    var body: some View {
        HStack(spacing: 12) {
            ZStack(alignment: .bottomLeading) {
                Rectangle().fill(.white.opacity(0.35)).frame(width: 54, height: 3)
                Rectangle().fill(.white)
                    .frame(width: 48, height: 3)
                    .rotationEffect(.degrees(-Double(angle ?? 0)), anchor: .leading)
                    .animation(.spring(response: 0.35, dampingFraction: 0.8), value: angle)
            }
            .frame(width: 58, height: 58, alignment: .bottomLeading)
            VStack(alignment: .leading, spacing: 2) {
                Text("화면 각도").font(.system(size: 10, weight: .medium)).foregroundStyle(.white.opacity(0.45))
                Text(angle.map { "\($0)°" } ?? "—")
                    .font(.system(size: 30, weight: .semibold).monospacedDigit())
                    .foregroundStyle(.white)
                    .contentTransition(.numericText())
                    .animation(.easeOut(duration: 0.15), value: angle)
            }
        }
    }
}

import SwiftUI

/// 탭 아이콘용 정지 Clawd 실루엣
struct ClawdGlyph: View {
    var body: some View {
        Canvas { ctx, size in
            let u = min(size.width / 12, size.height / 8.5)
            ctx.translateBy(x: size.width / 2, y: size.height)
            func r(_ x: Double, _ y: Double, _ w: Double, _ h: Double) -> Path {
                Path(CGRect(x: x * u, y: y * u, width: w * u, height: h * u))
            }
            let c = GraphicsContext.Shading.color(ClawdView.clay)
            ctx.fill(r(-5, -8, 10, 6), with: c)
            ctx.fill(r(-6.2, -5, 1.4, 1), with: c)
            ctx.fill(r(4.8, -5, 1.4, 1), with: c)
            for lx in [-4.0, -2.0, 1.0, 3.0] { ctx.fill(r(lx, -2.2, 1, 2.2), with: c) }
            for ex in [-2.5, 2.5] { ctx.fill(r(ex - 0.5, -7, 1, 2), with: .color(.black)) }
        }
    }
}

func elapsedLabel(since: Date, now: Date) -> String { formatTime(now.timeIntervalSince(since)) }

/// 아무 활동이 없을 때 호버: Clawd가 왼쪽에서 빼꼼, 오른쪽엔 미러 버튼
struct PeekView: View {
    let mood: ClawdMood
    let open: (NotchTab?) -> Void

    var body: some View {
        Wings(inset: 8) {
            Button { open(.claude) } label: {
                ClawdView(mood: mood == .sleeping ? .idle : mood, unit: 2.1)
            }
            .buttonStyle(.plain)
        } right: {
            Button { open(.camera) } label: {
                Image(systemName: "camera.fill")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.75))
                    .frame(width: 26, height: 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
    }
}

/// Claude 작업 중 / 확인 필요 — 노치 좌우 날개
struct CompactClaudeView: View {
    let session: ClaudeSession
    let others: Int

    var body: some View {
        Wings(inset: 8) {
            ClawdView(mood: session.mood, unit: 2.2)
        } right: {
            HStack(spacing: 5) {
                if session.state == .attention {
                    Text("확인").font(.system(size: 13, weight: .bold))
                        .foregroundStyle(ClawdView.ochre)
                } else {
                    TimelineView(.periodic(from: session.since, by: 1)) { tl in
                        Text(elapsedLabel(since: session.since, now: tl.date))
                            .font(.system(size: 13, weight: .semibold).monospacedDigit())
                            .foregroundStyle(ClawdView.clay)
                    }
                }
                if others > 0 {
                    Text("+\(others)")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(.black)
                        .padding(.horizontal, 4).padding(.vertical, 1)
                        .background(Capsule().fill(ClawdView.clayLt))
                }
            }
            .fixedSize()
        }
    }
}

/// 작업 완료 / 확인 필요 알림 (잠깐 아래로 늘어남)
struct ClaudeBanner: View {
    @Environment(\.notchSize) var n
    let title: String
    let project: String
    let detail: String
    let mood: ClawdMood

    var body: some View {
        HStack(spacing: 12) {
            ClawdView(mood: mood, unit: 3.4)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(title).font(.system(size: 14, weight: .semibold)).foregroundStyle(.white)
                    Text(project).font(.system(size: 12, weight: .medium)).foregroundStyle(ClawdView.clay)
                }
                if !detail.isEmpty {
                    Text(detail).font(.system(size: 12)).foregroundStyle(.white.opacity(0.55))
                }
            }
            .lineLimit(1)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
        .padding(.top, n.height + 2)
    }
}

/// 펼친 판의 Claude 탭: 세션 목록
struct ClaudePanel: View {
    @Environment(\.notchSize) var n
    let sessions: [ClaudeSession]
    let mood: ClawdMood
    let open: (ClaudeSession) -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            ClawdView(mood: mood, unit: 3.6)
                .padding(.top, 2)
            VStack(spacing: 4) {
                if sessions.isEmpty {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("실행 중인 Claude Code 없음").font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(.white.opacity(0.8))
                            Text("세션이 시작되면 여기서 상태를 보여줘요")
                                .font(.system(size: 11)).foregroundStyle(.white.opacity(0.45))
                        }
                        Spacer()
                    }
                    .frame(height: 30)
                } else {
                    ForEach(sessions.prefix(3)) { s in SessionRow(session: s) { open(s) } }
                }
            }
        }
        .padding(.horizontal, 18)
        .padding(.top, n.height + 4)
    }
}

private struct SessionRow: View {
    let session: ClaudeSession
    let action: () -> Void
    @State private var hover = false

    var color: Color {
        switch session.state {
        case .working: ClawdView.clay
        case .attention: ClawdView.ochre
        case .done: .green
        }
    }

    var label: String {
        switch session.state {
        case .working: "작업 중"
        case .attention: "확인 필요"
        case .done: "완료"
        }
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Circle().fill(color).frame(width: 7, height: 7)
                VStack(alignment: .leading, spacing: 0) {
                    Text(session.project).font(.system(size: 13, weight: .semibold)).foregroundStyle(.white)
                    if !session.detail.isEmpty {
                        Text(session.detail).font(.system(size: 10)).foregroundStyle(.white.opacity(0.45))
                    }
                }
                .lineLimit(1)
                Spacer(minLength: 6)
                Text(label).font(.system(size: 11, weight: .semibold)).foregroundStyle(color)
                TimelineView(.periodic(from: session.since, by: 1)) { tl in
                    Text(elapsedLabel(since: session.since, now: tl.date))
                        .font(.system(size: 11, weight: .medium).monospacedDigit())
                        .foregroundStyle(.white.opacity(0.5))
                        .frame(minWidth: 34, alignment: .trailing)
                }
            }
            .padding(.horizontal, 10)
            .frame(height: 30)
            .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(.white.opacity(hover ? 0.12 : 0.06)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
    }
}

/// 카메라 미러 (노치 = 카메라 자리). 펼친 동안만 카메라가 켜진다.
struct CameraPanel: View {
    @Environment(\.notchSize) var n
    let make: (() -> AnyView)?

    var body: some View {
        Group {
            if let make {
                make()
            } else {
                ZStack {
                    Color.white.opacity(0.06)
                    Image(systemName: "video.slash").foregroundStyle(.white.opacity(0.4))
                }
            }
        }
        .frame(width: 300, height: 190)
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .frame(maxWidth: .infinity)
        .padding(.top, n.height + 2)
    }
}

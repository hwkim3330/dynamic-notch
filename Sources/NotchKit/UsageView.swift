import SwiftUI

/// "1시간 23분 후" / "3일 11시간 후"
func untilLabel(_ d: Date, now: Date) -> String {
    let m = max(0, Int(d.timeIntervalSince(now) / 60))
    if m >= 1440 { return "\(m / 1440)일 \(m % 1440 / 60)시간 후" }
    if m >= 60 { return "\(m / 60)시간 \(m % 60)분 후" }
    return "\(m)분 후"
}

func money(_ v: Double) -> String { v >= 100 ? String(format: "$%.0f", v) : String(format: "$%.2f", v) }
func tokens(_ v: Double) -> String {
    v >= 1e9 ? String(format: "%.1fB", v / 1e9) : v >= 1e6 ? String(format: "%.1fM", v / 1e6)
        : v >= 1e3 ? String(format: "%.0fK", v / 1e3) : String(format: "%.0f", v)
}

/// 사용량 탭: 구독 한도(있으면) + 오늘/5시간/7일 API 환산 비용 + 24시간 막대
struct UsagePanel: View {
    @Environment(\.notchSize) var n
    let usage: UsageSnapshot?
    let limits: PlanLimits?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let l = limits, l.fiveHour != nil || l.week != nil {
                HStack(spacing: 14) {
                    if let v = l.fiveHour { LimitBar(title: "5시간 한도", pct: v, resets: l.fiveHourResets) }
                    if let v = l.week { LimitBar(title: "주간 한도", pct: v, resets: l.weekResets) }
                }
            }
            if let u = usage {
                if false, let l = u.limits {
                    HStack(spacing: 14) {
                        if let v = l.fiveHour { LimitBar(title: "5시간", pct: v, resets: l.fiveHourResets) }
                        if let v = l.week { LimitBar(title: "주간", pct: v, resets: l.weekResets) }
                    }
                }
                HStack(alignment: .top, spacing: 16) {
                    Stat(title: "오늘", value: money(u.todayCost), sub: tokens(u.todayTokens) + " 토큰")
                    Stat(title: "5시간", value: money(u.fiveHourCost), sub: nil)
                    Stat(title: "7일", value: money(u.weekCost), sub: nil)
                    if u.codexTodayTokens > 0 {
                        Stat(title: "Codex 오늘", value: tokens(u.codexTodayTokens), sub: "토큰")
                    }
                    Spacer(minLength: 0)
                    Hourly(values: u.hourly).frame(width: 120, height: 34)
                }
                HStack(spacing: 10) {
                    ForEach(u.byModel.prefix(3), id: \.0) { m in
                        Text("\(m.0) \(money(m.1))").font(.system(size: 10, weight: .medium))
                            .foregroundStyle(.white.opacity(0.5))
                    }
                    Spacer()
                    Text("API 가격 환산 추정").font(.system(size: 9)).foregroundStyle(.white.opacity(0.3))
                }
            } else {
                Text("사용량 읽는 중…").font(.system(size: 12)).foregroundStyle(.white.opacity(0.5))
                    .frame(maxWidth: .infinity, minHeight: 60)
            }
        }
        .padding(.horizontal, 22)
        .padding(.top, n.height + 6)
    }
}

private struct Stat: View {
    let title: String
    let value: String
    let sub: String?
    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(title).font(.system(size: 10, weight: .medium)).foregroundStyle(.white.opacity(0.45))
            Text(value).font(.system(size: 19, weight: .semibold).monospacedDigit()).foregroundStyle(.white)
            if let sub { Text(sub).font(.system(size: 9)).foregroundStyle(.white.opacity(0.4)) }
        }
    }
}

private struct LimitBar: View {
    let title: String
    let pct: Double
    let resets: Date?
    var color: Color { pct >= 90 ? .red : pct >= 70 ? ClawdView.ochre : ClawdView.clay }
    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(title).font(.system(size: 10, weight: .medium)).foregroundStyle(.white.opacity(0.5))
                Spacer()
                Text("\(Int(pct.rounded()))%").font(.system(size: 11, weight: .semibold).monospacedDigit())
                    .foregroundStyle(color)
                if let r = resets {
                    TimelineView(.periodic(from: .now, by: 30)) { tl in
                        Text(untilLabel(r, now: tl.date)).font(.system(size: 9)).foregroundStyle(.white.opacity(0.35))
                    }
                }
            }
            Bar(value: pct / 100, color: color)
        }
        .frame(maxWidth: .infinity)
    }
}

private struct Hourly: View {
    let values: [Double]
    var body: some View {
        GeometryReader { g in
            let mx = max(values.max() ?? 0, 0.0001)
            HStack(alignment: .bottom, spacing: 1.5) {
                ForEach(values.indices, id: \.self) { i in
                    RoundedRectangle(cornerRadius: 1)
                        .fill(i == values.count - 1 ? ClawdView.clay : ClawdView.clay.opacity(0.55))
                        .frame(height: max(1.5, g.size.height * values[i] / mx))
                }
            }
            .frame(maxHeight: .infinity, alignment: .bottom)
        }
    }
}

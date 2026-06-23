import SwiftUI

/// 燃尽计预警卡（设计稿「方向 B · 燃尽计」翻译）：燃料计 + 4 格全字段 + 断档高亮，
/// 严重度按断档时长三档配色（轻金 / 中橙 / 重红）。屏幕上方居中、纯淡入淡出。
/// 纯色背景——会淡出的视图垫毛玻璃会泛白（既往踩坑），故用常量深色 + accent 微染。
struct BurnoutAlertView: View {
    let remainingPct: Double
    let dropMinutes: Double      // 断档时长（gap）
    let timeLeft: TimeInterval   // 距重置（秒）
    var model: BurnoutCardModel

    // 设计稿严重度分档：断档 ≥120 重 / ≥60 中 / 其余轻
    private enum Sev { case light, mid, heavy }
    private var sev: Sev { dropMinutes >= 120 ? .heavy : dropMinutes >= 60 ? .mid : .light }
    private var accent: Color {
        switch sev {
        case .light: return Color(red: 0xE3/255, green: 0xA4/255, blue: 0x37/255)
        case .mid:   return Color(red: 0xF4/255, green: 0x7A/255, blue: 0x36/255)
        case .heavy: return Color(red: 0xFB/255, green: 0x54/255, blue: 0x4A/255)
        }
    }
    private var sevTag: String {
        switch sev { case .light: return "轻度断档"; case .mid: return "中度断档"; case .heavy: return "重度断档" }
    }
    private var glow: CGFloat { switch sev { case .light: return 0; case .mid: return 3; case .heavy: return 7 } }

    private var resetMin: Double { timeLeft / 60 }
    private var burnMin: Double { max(0, resetMin - dropMinutes) }   // 还能用多久

    // 设计稿色板（深色主题）
    private let cardBase = Color(red: 0x18/255, green: 0x1A/255, blue: 0x1F/255)
    private let ink = Color(red: 0xF4/255, green: 0xF4/255, blue: 0xF6/255)
    private let inkDim = Color(red: 0x98/255, green: 0x9A/255, blue: 0xA3/255)
    private let track = Color(red: 0x2C/255, green: 0x2E/255, blue: 0x36/255)
    private let ring = Color.white.opacity(0.07)

    var body: some View {
        VStack {
            card.opacity(model.shown ? 1 : 0)
            Spacer(minLength: 0)
        }
        .padding(.top, 120)   // 不贴顶，往下挪一点
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private var card: some View {
        VStack(alignment: .leading, spacing: 0) {
            head
            gauge.padding(.top, 16)
            grid.padding(.top, 14)
        }
        .padding(18)
        .frame(width: 412, alignment: .leading)
        .background(ZStack { cardBase; accent.opacity(0.09) })   // color-mix accent 9% 近似
        .clipShape(RoundedRectangle(cornerRadius: 15))
        .overlay(RoundedRectangle(cornerRadius: 15).strokeBorder(ring, lineWidth: 1))
        .shadow(color: .black.opacity(0.55), radius: 24, y: 22)
    }

    private var head: some View {
        HStack(alignment: .center, spacing: 13) {
            Image(systemName: sev == .light ? "exclamationmark.triangle" : "exclamationmark.triangle.fill")
                .font(.system(size: 30, weight: .semibold))
                .foregroundStyle(accent)
                .shadow(color: accent.opacity(glow > 0 ? 0.7 : 0), radius: glow)
                .frame(width: 38, height: 38)
            VStack(alignment: .leading, spacing: 3) {
                Text("5h 额度即将见底")
                    .font(.system(size: 15.5, weight: .semibold))
                    .foregroundStyle(ink)
                // 副行：约 {还能用} 后烧光，之后干等 {断档} 才恢复（断档用 accent 高亮）
                (Text("约 ")
                 + Text(Format.burnDur(burnMin)).font(.system(size: 12, weight: .bold, design: .monospaced)).foregroundColor(ink)
                 + Text(" 后烧光，之后干等 ")
                 + Text(Format.burnDur(dropMinutes)).font(.system(size: 12, weight: .bold, design: .monospaced)).foregroundColor(accent)
                 + Text(" 才恢复"))
                    .font(.system(size: 12))
                    .foregroundStyle(inkDim)
            }
            Spacer(minLength: 8)
            Text(sevTag)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(accent)
                .padding(.horizontal, 9).padding(.vertical, 4)
                .background(accent.opacity(0.16))
                .clipShape(RoundedRectangle(cornerRadius: 6))
        }
    }

    private var gauge: some View {
        VStack(alignment: .leading, spacing: 7) {
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 6).fill(track)
                    RoundedRectangle(cornerRadius: 6).fill(accent)
                        .frame(width: geo.size.width * max(remainingPct, 2) / 100)
                        .shadow(color: accent.opacity(0.6), radius: 5)
                }
            }
            .frame(height: 9)
            Text("\(Int(remainingPct))% 剩余")
                .font(.system(size: 10.5, design: .monospaced))
                .foregroundStyle(inkDim)
                .tracking(0.4)
        }
    }

    private var grid: some View {
        HStack(spacing: 1) {
            gridCell("\(Int(remainingPct))%", "剩余额度")
            gridCell(Format.burnDur(burnMin), "还能用")
            gridCell(Format.burnDur(resetMin), "距重置")
            gridCell(Format.burnDur(dropMinutes), "断档时长", hot: true)
        }
        .background(ring)
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    private func gridCell(_ num: String, _ lab: String, hot: Bool = false) -> some View {
        VStack(spacing: 3) {
            Text(num)
                .font(.system(size: 17, weight: .semibold, design: .monospaced))
                .foregroundStyle(hot ? accent : ink)
            Text(lab)
                .font(.system(size: 10))
                .foregroundStyle(inkDim)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 11).padding(.bottom, 10).padding(.horizontal, 10)
        .background(ZStack { cardBase; if hot { accent.opacity(0.18) } })
    }
}

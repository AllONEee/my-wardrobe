//
//  Theme.swift —— 全局设计变量与公共样式（对应 app.wxss）
//
//  小程序里尺寸用 rpx（750rpx = 屏幕宽度），iOS 上统一用 pt：1rpx = 0.5pt，
//  所以 app.wxss 里的 24rpx 圆角 = 12pt、28rpx 字号 = 14pt，下面按这个比例翻译。
//

import SwiftUI

enum Theme {
    /* ==================== 颜色（对应 app.wxss 的 CSS 变量） ==================== */

    static let primary = Color(hex: 0xE0745E)
    static let primaryDark = Color(hex: 0xC75F4A)
    static let primarySoft = Color(hex: 0xFBEDE9)
    static let text = Color(hex: 0x2E2A28)
    static let textSub = Color(hex: 0x8C8480)
    static let textLight = Color(hex: 0xB3ABA6)
    static let bg = Color(hex: 0xF7F5F3)
    static let card = Color.white
    static let border = Color(hex: 0xEDE7E3)
    static let danger = Color(hex: 0xE0564F)
    static let dangerSoft = Color(hex: 0xFDECEB)
    static let cellHover = Color(hex: 0xFAF7F5)

    /* ==================== 尺寸 ==================== */

    static let radius: CGFloat = 12
    static let radiusSM: CGFloat = 6
    static let radiusLG: CGFloat = 16
    /// 页面左右内边距（24rpx）
    static let pagePadding: CGFloat = 12
    /// 列表单元格高度（104rpx）
    static let cellHeight: CGFloat = 52
    /// 胶囊标签高度（48rpx）
    static let tagHeight: CGFloat = 24

    /* ==================== 字号 ==================== */

    static let fontTitle: CGFloat = 17 // 34rpx
    static let fontSubtitle: CGFloat = 15 // 30rpx
    static let fontBody: CGFloat = 14 // 28rpx
    static let fontSmall: CGFloat = 13 // 26rpx
    static let fontCaption: CGFloat = 12 // 24rpx
    static let fontTiny: CGFloat = 11 // 22rpx
}

extension Color {
    init(hex: UInt32, alpha: Double = 1) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255.0,
            green: Double((hex >> 8) & 0xFF) / 255.0,
            blue: Double(hex & 0xFF) / 255.0,
            opacity: alpha
        )
    }
}

/* ==================== 卡片 ==================== */

struct CardModifier: ViewModifier {
    var padding: CGFloat = 0

    func body(content: Content) -> some View {
        content
            .padding(padding)
            .background(Theme.card)
            .clipShape(RoundedRectangle(cornerRadius: Theme.radius, style: .continuous))
            .shadow(color: Color.black.opacity(0.06), radius: 12, x: 0, y: 4)
    }
}

extension View {
    /// 对应 .card
    func cardStyle(padding: CGFloat = 0) -> some View {
        modifier(CardModifier(padding: padding))
    }

    /// 卡片内的一行（对应 .cell），最后一行不画分隔线由调用方决定
    func cellDivider() -> some View {
        overlay(alignment: .bottom) {
            Rectangle()
                .fill(Theme.border)
                .frame(height: 0.5)
        }
    }
}

/* ==================== 按钮（对应 .btn / .btn--primary / .btn--ghost / .btn--soft / .btn--danger） ==================== */

enum AppButtonKind {
    case primary
    case soft
    case ghost
    case danger

    var background: Color {
        switch self {
        case .primary: return Theme.primary
        case .soft: return Theme.primarySoft
        case .ghost: return Theme.card
        case .danger: return Theme.dangerSoft
        }
    }

    var foreground: Color {
        switch self {
        case .primary: return .white
        case .soft: return Theme.primaryDark
        case .ghost: return Theme.text
        case .danger: return Theme.danger
        }
    }

    var borderColor: Color {
        self == .ghost ? Theme.border : .clear
    }
}

struct AppButtonStyle: ButtonStyle {
    var kind: AppButtonKind = .primary
    var small: Bool = false
    var fullWidth: Bool = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: small ? Theme.fontSmall : Theme.fontSubtitle, weight: .medium))
            .foregroundStyle(kind.foreground)
            .padding(.horizontal, small ? 14 : 18)
            .frame(height: small ? 32 : 42)
            .frame(maxWidth: fullWidth ? .infinity : nil)
            .background(kind.background)
            .clipShape(Capsule())
            .overlay(
                Capsule().stroke(kind.borderColor, lineWidth: kind == .ghost ? 0.5 : 0)
            )
            .opacity(configuration.isPressed ? 0.8 : 1)
    }
}

extension ButtonStyle where Self == AppButtonStyle {
    static var appPrimary: AppButtonStyle { AppButtonStyle(kind: .primary) }
    static var appSoft: AppButtonStyle { AppButtonStyle(kind: .soft) }
    static var appGhost: AppButtonStyle { AppButtonStyle(kind: .ghost) }
    static var appDanger: AppButtonStyle { AppButtonStyle(kind: .danger) }
    static var appPrimarySmall: AppButtonStyle { AppButtonStyle(kind: .primary, small: true) }
    static var appSoftSmall: AppButtonStyle { AppButtonStyle(kind: .soft, small: true) }
    static var appGhostSmall: AppButtonStyle { AppButtonStyle(kind: .ghost, small: true) }
    static var appDangerSmall: AppButtonStyle { AppButtonStyle(kind: .danger, small: true) }
}

/* ==================== 胶囊标签（对应 .tag / .tag--active / .tag--soft） ==================== */

struct TagChip: View {
    let title: String
    var active: Bool = false
    var soft: Bool = false
    var onTap: (() -> Void)?

    var body: some View {
        Text(title)
            .font(.system(size: Theme.fontCaption))
            .foregroundStyle(foreground)
            .padding(.horizontal, 11)
            .frame(height: Theme.tagHeight)
            .background(background)
            .clipShape(Capsule())
            .contentShape(Capsule())
            .onTapGesture { onTap?() }
    }

    private var background: Color {
        if active { return Theme.primary }
        if soft { return Theme.primarySoft }
        return Theme.bg
    }

    private var foreground: Color {
        if active { return .white }
        if soft { return Theme.primaryDark }
        return Theme.textSub
    }
}

/// 横向滚动的胶囊组（对应 .chips + scroll-view）
struct ChipRow<Item: Hashable, Content: View>: View {
    let items: [Item]
    let content: (Item) -> Content

    init(_ items: [Item], @ViewBuilder content: @escaping (Item) -> Content) {
        self.items = items
        self.content = content
    }

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(items, id: \.self) { item in
                    content(item)
                }
            }
            .padding(.vertical, 2)
        }
    }
}

/// 换行排列的胶囊组（分类 / 季节 / 尺码 / 天气都用它）
struct ChipFlow<Item: Hashable, Content: View>: View {
    let items: [Item]
    let spacing: CGFloat
    let content: (Item) -> Content

    init(_ items: [Item], spacing: CGFloat = 6, @ViewBuilder content: @escaping (Item) -> Content) {
        self.items = items
        self.spacing = spacing
        self.content = content
    }

    var body: some View {
        FlowLayout(spacing: spacing) {
            ForEach(items, id: \.self) { item in
                content(item)
            }
        }
    }
}

/// 简单的流式布局（SwiftUI 没有内置的换行 HStack）
struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var rowWidth: CGFloat = 0
        var rowHeight: CGFloat = 0
        var totalHeight: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if rowWidth > 0, rowWidth + spacing + size.width > maxWidth {
                totalHeight += rowHeight + spacing
                rowWidth = size.width
                rowHeight = size.height
            } else {
                rowWidth += rowWidth > 0 ? spacing + size.width : size.width
                rowHeight = max(rowHeight, size.height)
            }
        }
        totalHeight += rowHeight
        return CGSize(width: proposal.width ?? rowWidth, height: totalHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX
        var y = bounds.minY
        var rowHeight: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > bounds.minX, x + size.width > bounds.maxX {
                x = bounds.minX
                y += rowHeight + spacing
                rowHeight = 0
            }
            subview.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}

/* ==================== 空状态（对应 components/empty-state） ==================== */

struct EmptyStateView: View {
    var text: String = "暂无内容"
    var desc: String = ""
    var actionText: String = ""
    var action: (() -> Void)?

    var body: some View {
        VStack(spacing: 8) {
            // 纯代码画的占位图，不引入图片资源（对应 empty-state 的 CSS 占位图）
            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Theme.bg)
                    .frame(width: 88, height: 66)
                VStack(alignment: .leading, spacing: 6) {
                    Capsule().fill(Theme.border).frame(width: 52, height: 6)
                    Capsule().fill(Theme.border).frame(width: 32, height: 6)
                }
                .padding(.leading, 16)
                .padding(.top, 20)
            }
            .padding(.bottom, 12)

            Text(text)
                .font(.system(size: Theme.fontSubtitle, weight: .semibold))
                .foregroundStyle(Theme.text)

            if !desc.isEmpty {
                Text(desc)
                    .font(.system(size: Theme.fontSmall))
                    .foregroundStyle(Theme.textSub)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 24)
            }

            if !actionText.isEmpty {
                Button(actionText) { action?() }
                    .buttonStyle(AppButtonStyle(kind: .soft, small: true))
                    .padding(.top, 6)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 40)
    }
}

//
//  Theme.swift —— 全局设计变量与公共样式（对应 app.wxss）
//
//  小程序里尺寸用 rpx（750rpx = 屏幕宽度），iOS 上统一用 pt：1rpx = 0.5pt，
//  所以 app.wxss 里的 24rpx 圆角 = 12pt、28rpx 字号 = 14pt，下面按这个比例翻译。
//

import SwiftUI
import UIKit

enum Theme {
    /* ==================== 颜色（对应 app.wxss 的 CSS 变量） ==================== */

    // 每套颜色都给浅色 / 深色两个值：深色不是简单反色，背景压到暖黑、
    // 主色稍微提亮，保证在深底上对比度依然够（也顺带照顾到深色下的白色描边）。
    static let primary = Color.dynamic(light: 0xE0745E, dark: 0xE8836C)
    static let primaryDark = Color.dynamic(light: 0xC75F4A, dark: 0xEFA48F)
    static let primarySoft = Color.dynamic(light: 0xFBEDE9, dark: 0x3A2B26)
    static let text = Color.dynamic(light: 0x2E2A28, dark: 0xF1ECE8)
    static let textSub = Color.dynamic(light: 0x8C8480, dark: 0xA8A09A)
    static let textLight = Color.dynamic(light: 0xB3ABA6, dark: 0x7B736D)
    static let bg = Color.dynamic(light: 0xF7F5F3, dark: 0x151413)
    static let card = Color.dynamic(light: 0xFFFFFF, dark: 0x232120)
    static let border = Color.dynamic(light: 0xEDE7E3, dark: 0x393431)
    static let danger = Color.dynamic(light: 0xE0564F, dark: 0xFF736B)
    static let dangerSoft = Color.dynamic(light: 0xFDECEB, dark: 0x3C2523)
    static let cellHover = Color.dynamic(light: 0xFAF7F5, dark: 0x2C2926)
    /// 图片占位底色（衣柜卡片、弹层里的缩略图等）
    static let imageWell = Color.dynamic(light: 0xFAF8F7, dark: 0x1D1B1A)
    /// 编辑器里的透明棋盘格
    static let checkerboard = Color.dynamic(light: 0xE6E1DD, dark: 0x2E2B28)
    /// 轻提示底色
    static let toast = Color.dynamic(light: 0x2E2A28, dark: 0x55504B, lightAlpha: 0.88, darkAlpha: 0.95)
    /// 卡片阴影：深色下阴影几乎看不见，所以深色再补一圈描边
    static let shadow = Color.dynamic(light: 0x000000, dark: 0x000000, lightAlpha: 0.06, darkAlpha: 0.5)
    static let cardStroke = Color.dynamic(light: 0x000000, dark: 0x393431, lightAlpha: 0, darkAlpha: 1)
    /// 悬浮底栏的描边
    static let barStroke = Color.dynamic(light: 0xFFFFFF, dark: 0x4A443F, lightAlpha: 0.55, darkAlpha: 0.35)
    static let barShadow = Color.dynamic(light: 0x000000, dark: 0x000000, lightAlpha: 0.12, darkAlpha: 0.55)

    /// 悬浮底栏占的高度（页面底部要给它留位置）
    static let floatingBarHeight: CGFloat = 68
    static let floatingBarBottomGap: CGFloat = 6
    /// 滚动内容底部要留的空白（比底栏本身再多一点，滚到底时最后一行不会贴着玻璃）
    static let floatingBarSpace: CGFloat = 82

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

    /// 浅色 / 深色两套取值：跟随系统外观，也跟随 App 内「外观」设置
    static func dynamic(light: UInt32, dark: UInt32, lightAlpha: Double = 1, darkAlpha: Double = 1) -> Color {
        Color(UIColor { traits in
            traits.userInterfaceStyle == .dark
                ? UIColor(hex: dark, alpha: darkAlpha)
                : UIColor(hex: light, alpha: lightAlpha)
        })
    }
}

extension UIColor {
    convenience init(hex: UInt32, alpha: Double = 1) {
        self.init(
            red: CGFloat((hex >> 16) & 0xFF) / 255.0,
            green: CGFloat((hex >> 8) & 0xFF) / 255.0,
            blue: CGFloat(hex & 0xFF) / 255.0,
            alpha: CGFloat(alpha)
        )
    }
}

/* ==================== 悬浮底栏的高度（页面自带的底部操作栏要抬起来让开它） ==================== */

private struct FloatingBarInsetKey: EnvironmentKey {
    static let defaultValue: CGFloat = 0
}

/* ==================== 磨砂玻璃（底栏 / 二级页面的悬浮操作条共用） ==================== */

/// iOS 26 起用系统的 Liquid Glass，更早的系统退回 ultraThinMaterial —— 两种都是真·半透明
struct GlassCapsuleModifier: ViewModifier {
    func body(content: Content) -> some View {
        let shape = Capsule(style: .continuous)
        if #available(iOS 26.0, *) {
            content.glassEffect(.regular, in: shape)
        } else {
            content
                .background(.ultraThinMaterial, in: shape)
                .overlay(shape.stroke(Theme.barStroke, lineWidth: 0.5))
        }
    }
}

extension View {
    func glassCapsule() -> some View {
        modifier(GlassCapsuleModifier())
    }
}

/// 键盘状态：编辑页的悬浮操作条要据此决定还给不给底栏让位
/// （键盘弹起来的时候，底栏被键盘挡住，操作条应该贴着键盘，而不是再往上让 74pt）
final class KeyboardState: ObservableObject {
    static let shared = KeyboardState()

    @Published private(set) var visible = false

    private init() {
        let center = NotificationCenter.default
        center.addObserver(
            forName: UIResponder.keyboardWillShowNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.visible = true
        }
        center.addObserver(
            forName: UIResponder.keyboardWillHideNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.visible = false
        }
    }
}

/// 二级页面底部的悬浮操作条。
///
/// 原来是「白底 + 分割线」的一条，钉在页面底部，和 App 的悬浮 tab 栏叠在一起会
/// 露出一条突兀的白带（内容还从玻璃下面穿过去）。现在换成和底栏同一套磨砂玻璃胶囊：
/// 浮在 tab 栏上方，四周是透明的，内容从它下面滚过去。
struct FloatingActionBar<Content: View>: View {
    @ObservedObject private var keyboard = KeyboardState.shared
    @ViewBuilder var content: () -> Content

    var body: some View {
        HStack(spacing: 8) {
            content()
        }
        .padding(.horizontal, 10)
        .frame(height: 56)
        .glassCapsule()
        .shadow(color: Theme.barShadow, radius: 18, x: 0, y: 8)
        .padding(.horizontal, 20)
        .padding(.top, 10)
        // 给底栏让位；键盘弹起来时底栏被挡住，就让操作条贴着键盘
        .padding(.bottom, keyboard.visible ? 8 : (Theme.floatingBarBottomGap + Theme.floatingBarHeight + 6))
    }
}

extension EnvironmentValues {
    /// 底栏实际占掉的高度（高度 + 间距）。页面里自己固定在底部的操作栏加上这个内边距，
    /// 就会落在悬浮底栏的上方，而不是被压在后面。
    var floatingBarInset: CGFloat {
        get { self[FloatingBarInsetKey.self] }
        set { self[FloatingBarInsetKey.self] = newValue }
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
            .overlay(
                RoundedRectangle(cornerRadius: Theme.radius, style: .continuous)
                    .stroke(Theme.cardStroke, lineWidth: 1)
            )
            .shadow(color: Theme.shadow, radius: 12, x: 0, y: 4)
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

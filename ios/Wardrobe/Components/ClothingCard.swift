//
//  ClothingCard.swift —— 衣物卡片（衣橱网格 / 穿搭详情 / 选衣弹层共用）
//  对应 components/clothing-card。
//
//  交互约定（组件只负责「报告发生了什么」，业务逻辑由页面处理）：
//   - 点图片区域  -> onTapImage  —— 图片上的手势优先命中，不会触发卡片上的 onTapCard
//   - 点其余空白区 -> onTapCard   —— 衣橱页据此 wearCount++
//

import SwiftUI

struct ClothingCard: View {
    let item: ClothingItem
    /// 是否显示最近穿着日期（对应设置页的显示设置）
    var showLastWorn: Bool = true
    /// 是否显示穿着次数角标
    var showWearCount: Bool = true
    /// 是否显示单次成本角标（设置页的显示设置）
    var showCost: Bool = false
    /// 多选模式：nil = 普通模式；true / false = 是否被勾选。
    /// 多选时点哪儿都是「切换勾选」，点图片不再跳详情。
    var selected: Bool?
    var onTapImage: () -> Void = {}
    var onTapCard: () -> Void = {}

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                Theme.imageWell
                if image.isEmpty {
                    Text("暂无图片")
                        .font(.system(size: Theme.fontTiny))
                        .foregroundStyle(Theme.textLight)
                } else {
                    StoredImage(path: image, mode: .fit, maxPixel: 600, contentOnly: true)
                }
                badges
            }
            .aspectRatio(1, contentMode: .fit)
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
            .onTapGesture {
                if selected != nil { onTapCard() } else { onTapImage() }
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(item.name)
                    .font(.system(size: Theme.fontSmall))
                    .foregroundStyle(Theme.text)
                    .lineLimit(1)
                HStack(spacing: 3) {
                    Text(item.category)
                    if !lastWornText.isEmpty {
                        Text("·")
                        Text(lastWornText)
                    }
                }
                .font(.system(size: Theme.fontTiny))
                .foregroundStyle(Theme.textSub)
                .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 8)
            .padding(.top, 7)
            .padding(.bottom, 9)
        }
        .background(Theme.card)
        .clipShape(RoundedRectangle(cornerRadius: Theme.radius, style: .continuous))
        .shadow(color: Color.black.opacity(0.06), radius: 12, x: 0, y: 4)
        // 已处置的衣物整张压暗一点，一眼能和还在穿的区分开
        .opacity(item.isReleased ? 0.62 : 1)
        .contentShape(Rectangle())
        .onTapGesture { onTapCard() }
    }

    /* ==================== 图片上的角标 ==================== */

    @ViewBuilder
    private var badges: some View {
        // 三个角各放一个角标，窄卡片（4 列）时也不会叠在一起：
        //   左上 已处置 / 右上 穿着次数 / 左下 单次成本
        ZStack {
            if item.isReleased {
                corner(alignment: .topLeading) {
                    capsule(item.releaseMethod?.shortTitle ?? "已处置", fill: Theme.textSub)
                }
            }

            // 多选时右上角让给勾选圈，次数就不显示了（免得两个角标叠在一起）
            if showWearCount && item.wearCount > 0 && selected == nil {
                corner(alignment: .topTrailing) {
                    capsule("\(item.wearCount) 次", fill: Color(hex: 0x2E2A28).opacity(0.55))
                }
            }

            if showCost, let cost = item.costPerWear {
                corner(alignment: .bottomLeading) {
                    capsule(Money.costPerWear(cost), fill: Theme.primary.opacity(0.92), weight: .medium)
                }
            }

            // 多选：右上角盖住次数角标（多选时本来也不看次数）
            if let selected {
                corner(alignment: .topTrailing) {
                    Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                        .font(.system(size: 19))
                        .foregroundStyle(selected ? Theme.primary : Color.white)
                        .background(
                            Circle()
                                .fill(selected ? Color.white : Color(hex: 0x2E2A28).opacity(0.28))
                                .frame(width: 17, height: 17)
                        )
                        .padding(5)
                }
            }
        }
    }

    private func corner<Content: View>(
        alignment: Alignment,
        @ViewBuilder content: () -> Content
    ) -> some View {
        content()
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: alignment)
    }

    private func capsule(
        _ text: String,
        fill: Color,
        weight: Font.Weight = .regular
    ) -> some View {
        Text(text)
            .font(.system(size: 10, weight: weight))
            .foregroundStyle(.white)
            .lineLimit(1)
            .padding(.horizontal, 6)
            .frame(height: 17)
            .background(fill)
            .clipShape(Capsule())
            .padding(5)
    }

    /// coverImage 优先，没有再退回原图
    private var image: String {
        item.coverImage.isEmpty ? item.originalImage : item.coverImage
    }

    /// 今天 / 昨天 / M月D日，避免卡片上出现一长串日期
    private var lastWornText: String {
        guard showLastWorn, !item.lastWornDate.isEmpty else { return "" }
        return DateUtil.friendlyDate(item.lastWornDate)
    }
}

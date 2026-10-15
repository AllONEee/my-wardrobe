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
    var onTapImage: () -> Void = {}
    var onTapCard: () -> Void = {}

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                Color(hex: 0xFAF8F7)
                if image.isEmpty {
                    Text("暂无图片")
                        .font(.system(size: Theme.fontTiny))
                        .foregroundStyle(Theme.textLight)
                } else {
                    StoredImage(path: image, mode: .fit, maxPixel: 600, contentOnly: true)
                }
                if showWearCount && item.wearCount > 0 {
                    VStack {
                        Spacer()
                        HStack {
                            Spacer()
                            Text("\(item.wearCount) 次")
                                .font(.system(size: 10))
                                .foregroundStyle(.white)
                                .padding(.horizontal, 6)
                                .frame(height: 17)
                                .background(Color(hex: 0x2E2A28).opacity(0.55))
                                .clipShape(Capsule())
                                .padding(5)
                        }
                    }
                }
            }
            .aspectRatio(1, contentMode: .fit)
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
            .onTapGesture { onTapImage() }

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
        .contentShape(Rectangle())
        .onTapGesture { onTapCard() }
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

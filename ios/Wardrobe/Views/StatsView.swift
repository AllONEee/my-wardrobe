//
//  StatsView.swift —— 衣橱统计
//
//  这一页是「用数据思维看衣橱」的落点：
//   - 概览：在穿 / 已处置、总花费、平均单次成本
//   - 常青树：穿得最多、单次成本最低的那几件
//   - 假便宜：单次成本最高、以及很久没穿的
//   - 分类分布、最近 12 个月的购置花费
//
//  单次成本 = 价格 ÷ 穿着次数：没填价格、或者还没穿过的，不参与排名（宁可不显示，也别算出一个假数）。
//

import Charts
import SwiftUI

final class StatsModel: ObservableObject {
    struct RankRow: Identifiable, Hashable {
        var id: String
        var name: String
        var image: String
        var value: String
        var detail: String
    }

    struct CategoryRow: Identifiable, Hashable {
        var name: String
        var count: Int
        var spend: Double
        var ratio: Double

        var id: String { name }
    }

    struct MonthRow: Identifiable, Hashable {
        var key: String
        var label: String
        var spend: Double

        var id: String { key }
    }

    @Published var activeCount = 0
    @Published var releasedCount = 0
    @Published var totalSpend: Double = 0
    @Published var soldBack: Double = 0
    @Published var averageCost: Double?
    @Published var neverWornCount = 0
    @Published var outfitCount = 0
    @Published var outfitDays = 0
    @Published var thisYearDays = 0

    @Published var trees: [RankRow] = []
    @Published var bargain: [RankRow] = []
    @Published var idle: [RankRow] = []
    @Published var categories: [CategoryRow] = []
    @Published var months: [MonthRow] = []

    init() {
        reload()
        AppState.shared.bus.on(.clothingChange, ctx: self) { [weak self] _ in
            DispatchQueue.main.async { self?.reload() }
        }
        AppState.shared.bus.on(.outfitChange, ctx: self) { [weak self] _ in
            DispatchQueue.main.async { self?.reload() }
        }
    }

    deinit {
        AppState.shared.bus.offBy(ctx: self)
    }

    private static func image(_ item: ClothingItem) -> String {
        item.coverImage.isEmpty ? item.originalImage : item.coverImage
    }

    func reload() {
        let all = Database.shared.listAllClothing()
        let active = all.filter { $0.isActive }

        activeCount = active.count
        releasedCount = all.count - active.count
        totalSpend = all.reduce(0) { $0 + $1.price }
        soldBack = all.reduce(0) { $0 + ($1.releaseMethod == .sold ? $1.soldPrice : 0) }
        neverWornCount = active.filter { $0.wearCount == 0 }.count

        // 平均单次成本：只在「有价格且穿过」的衣物之间平均，不然会被一堆 0 拉平
        let costs = active.compactMap { $0.costPerWear }
        averageCost = costs.isEmpty ? nil : costs.reduce(0, +) / Double(costs.count)

        let outfits = Database.shared.listOutfits()
        outfitCount = outfits.count
        let dates = Set(outfits.map { $0.date }).filter { !$0.isEmpty }
        outfitDays = dates.count
        let yearPrefix = String(DateUtil.today().prefix(4))
        thisYearDays = dates.filter { $0.hasPrefix(yearPrefix) }.count

        // 常青树：穿得最多
        trees = active
            .filter { $0.wearCount > 0 }
            .sorted { $0.wearCount > $1.wearCount }
            .prefix(5)
            .map { item in
                var detail = "穿了 \(item.wearCount) 次"
                if let cost = item.costPerWear { detail += " · 单次 \(Money.costPerWear(cost))" }
                return RankRow(id: item.id, name: item.name, image: Self.image(item),
                               value: "\(item.wearCount)", detail: detail)
            }

        // 假便宜：单次成本最高（穿了才有单次成本）
        bargain = active
            .compactMap { item -> (ClothingItem, Double)? in
                guard let cost = item.costPerWear else { return nil }
                return (item, cost)
            }
            .sorted { $0.1 > $1.1 }
            .prefix(5)
            .map { item, cost in
                RankRow(id: item.id, name: item.name, image: Self.image(item),
                        value: Money.costPerWear(cost),
                        detail: "\(Money.text(item.price)) ÷ \(item.wearCount) 次")
            }

        // 很久没穿：有穿过记录、但上一次已经隔了很久；一次没穿过的单独统计
        let today = DateUtil.today()
        idle = active
            .compactMap { item -> (ClothingItem, Int)? in
                guard !item.lastWornDate.isEmpty else { return nil }
                let days = DateUtil.daysBetween(item.lastWornDate, today)
                guard days >= 30 else { return nil }
                return (item, days)
            }
            .sorted { $0.1 > $1.1 }
            .prefix(5)
            .map { item, days in
                RankRow(id: item.id, name: item.name, image: Self.image(item),
                        value: "\(days) 天", detail: "上次穿是 " + DateUtil.friendlyDate(item.lastWornDate))
            }

        // 分类分布（含已处置：花费是历史事实）
        var countMap: [String: Int] = [:]
        var spendMap: [String: Double] = [:]
        for item in all {
            countMap[item.category, default: 0] += 1
            spendMap[item.category, default: 0] += item.price
        }
        let maxSpend = spendMap.values.max() ?? 0
        categories = countMap
            .map { key, value in
                CategoryRow(
                    name: key,
                    count: value,
                    spend: spendMap[key] ?? 0,
                    ratio: maxSpend > 0 ? (spendMap[key] ?? 0) / maxSpend : 0
                )
            }
            .sorted { $0.spend > $1.spend }

        // 最近 12 个月的花费：优先按购买日期，没填的按添加时间
        var monthMap: [String: Double] = [:]
        for item in all where item.price > 0 {
            let date = item.purchaseDate.isEmpty
                ? DateUtil.formatDate(Date(timeIntervalSince1970: item.createTime / 1000))
                : item.purchaseDate
            let key = DateUtil.monthKeyOf(date)
            monthMap[key, default: 0] += item.price
        }
        let currentKey = DateUtil.monthKeyOf(DateUtil.today())
        var rows: [MonthRow] = []
        for offset in stride(from: -11, through: 0, by: 1) {
            let key = String(DateUtil.addMonths(currentKey + "-01", offset).prefix(7))
            let parts = key.split(separator: "-")
            let label = parts.count == 2 ? "\(Int(parts[1]) ?? 0)月" : key
            rows.append(MonthRow(key: key, label: label, spend: monthMap[key] ?? 0))
        }
        months = rows
    }

    var isEmpty: Bool { activeCount == 0 && releasedCount == 0 }
}

struct StatsView: View {
    @StateObject private var model = StatsModel()
    @Environment(\.floatingBarInset) private var floatingBarInset
    @State private var detailId: String?

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                if model.isEmpty {
                    EmptyStateView(
                        text: "还没有数据可以统计",
                        desc: "先去衣橱里加几件衣物吧，填了价格、穿过之后这里会算出单次成本、常青树和闲置清单。"
                    )
                } else {
                    overviewCard
                    rankCard("衣橱常青树", note: "穿得最多的几件，就是真正值的那几件", rows: model.trees)
                    rankCard("单次成本最高", note: "价格 ÷ 次数 ＝ 每次穿它花了多少钱；贵不贵不看标价", rows: model.bargain)
                    rankCard("很久没穿", note: "该穿一穿，或者考虑断舍离", rows: model.idle)
                    categoryCard
                    monthCard
                }
            }
            .padding(Theme.pagePadding)
            .padding(.bottom, 40)
        }
        .background(Theme.bg)
        .navigationTitle("统计")
        .navigationBarTitleDisplayMode(.inline)
        .navigationDestination(item: $detailId) { id in
            ClothingDetailView(clothingId: id)
        }
    }

    /* ==================== 概览 ==================== */

    private var overviewCard: some View {
        VStack(spacing: 12) {
            HStack(spacing: 0) {
                statCell(value: "\(model.activeCount)", label: "在穿", accent: true)
                divider
                statCell(value: "\(model.releasedCount)", label: "已处置")
                divider
                statCell(value: "\(model.neverWornCount)", label: "没穿过")
            }

            Rectangle().fill(Theme.border).frame(height: 0.5)

            HStack(spacing: 0) {
                statCell(value: Money.text(model.totalSpend), label: "累计花费")
                divider
                statCell(
                    value: model.averageCost.map { Money.costPerWear($0) } ?? "—",
                    label: "平均单次成本",
                    accent: true
                )
            }

            if model.soldBack > 0 {
                HStack {
                    Text("断舍离回血")
                        .font(.system(size: Theme.fontSmall))
                        .foregroundStyle(Theme.textSub)
                    Spacer()
                    Text(Money.text(model.soldBack))
                        .font(.system(size: Theme.fontSmall, weight: .medium))
                        .foregroundStyle(Theme.primaryDark)
                }
            }

            Rectangle().fill(Theme.border).frame(height: 0.5)

            HStack(spacing: 0) {
                statCell(value: "\(model.outfitCount)", label: "穿搭记录")
                divider
                statCell(value: "\(model.outfitDays)", label: "记录天数")
                divider
                statCell(value: "\(model.thisYearDays)", label: "今年天数")
            }
        }
        .padding(12)
        .cardStyle()
    }

    private var divider: some View {
        Rectangle()
            .fill(Theme.border)
            .frame(width: 0.5, height: 28)
    }

    private func statCell(value: String, label: String, accent: Bool = false) -> some View {
        VStack(spacing: 3) {
            Text(value)
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(accent ? Theme.primary : Theme.text)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
            Text(label)
                .font(.system(size: Theme.fontTiny))
                .foregroundStyle(Theme.textSub)
        }
        .frame(maxWidth: .infinity)
    }

    /* ==================== 排行榜 ==================== */

    @ViewBuilder
    private func rankCard(_ title: String, note: String, rows: [StatsModel.RankRow]) -> some View {
        if !rows.isEmpty {
            VStack(alignment: .leading, spacing: 0) {
                Text(title)
                    .font(.system(size: Theme.fontSubtitle, weight: .semibold))
                    .foregroundStyle(Theme.text)
                Text(note)
                    .font(.system(size: Theme.fontTiny))
                    .foregroundStyle(Theme.textLight)
                    .padding(.top, 3)
                    .padding(.bottom, 8)

                VStack(spacing: 0) {
                    ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                        HStack(spacing: 10) {
                            Text("\(index + 1)")
                                .font(.system(size: Theme.fontSmall, weight: .semibold))
                                .foregroundStyle(index == 0 ? Theme.primary : Theme.textLight)
                                .frame(width: 18, alignment: .leading)

                            StoredImage(path: row.image, mode: .fit, maxPixel: 200, contentOnly: true)
                                .frame(width: 40, height: 40)
                                .background(Theme.imageWell)
                                .clipShape(RoundedRectangle(cornerRadius: Theme.radiusSM, style: .continuous))

                            VStack(alignment: .leading, spacing: 2) {
                                Text(row.name)
                                    .font(.system(size: Theme.fontBody))
                                    .foregroundStyle(Theme.text)
                                    .lineLimit(1)
                                Text(row.detail)
                                    .font(.system(size: Theme.fontTiny))
                                    .foregroundStyle(Theme.textSub)
                                    .lineLimit(1)
                            }

                            Spacer(minLength: 4)

                            Text(row.value)
                                .font(.system(size: Theme.fontSmall, weight: .medium))
                                .foregroundStyle(Theme.text)
                        }
                        .padding(.vertical, 7)
                        .contentShape(Rectangle())
                        .onTapGesture { detailId = row.id }

                        if row.id != rows.last?.id {
                            Rectangle().fill(Theme.border).frame(height: 0.5)
                        }
                    }
                }
            }
            .padding(12)
            .cardStyle()
            .padding(.top, 12)
        }
    }

    /* ==================== 分类分布 ==================== */

    private var categoryCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("分类分布")
                .font(.system(size: Theme.fontSubtitle, weight: .semibold))
                .foregroundStyle(Theme.text)
            Text("条长按花费画，右边是件数")
                .font(.system(size: Theme.fontTiny))
                .foregroundStyle(Theme.textLight)
                .padding(.top, 3)
                .padding(.bottom, 10)

            ForEach(model.categories) { row in
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text(row.name)
                            .font(.system(size: Theme.fontSmall))
                            .foregroundStyle(Theme.text)
                        Spacer()
                        Text("\(row.count) 件 · \(Money.text(row.spend))")
                            .font(.system(size: Theme.fontTiny))
                            .foregroundStyle(Theme.textSub)
                    }
                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            Capsule().fill(Theme.bg)
                            Capsule()
                                .fill(Theme.primary.opacity(0.75))
                                .frame(width: max(4, geo.size.width * row.ratio))
                        }
                    }
                    .frame(height: 8)
                }
                .padding(.vertical, 6)
            }
        }
        .padding(12)
        .cardStyle()
        .padding(.top, 12)
    }

    /* ==================== 月度花费 ==================== */

    private var monthCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("最近 12 个月")
                .font(.system(size: Theme.fontSubtitle, weight: .semibold))
                .foregroundStyle(Theme.text)
            Text("按购买日期统计（没填购买日期的按添加时间）")
                .font(.system(size: Theme.fontTiny))
                .foregroundStyle(Theme.textLight)
                .padding(.top, 3)
                .padding(.bottom, 10)

            Chart(model.months) { row in
                BarMark(
                    x: .value("月份", row.label),
                    y: .value("花费", row.spend)
                )
                .foregroundStyle(Theme.primary.gradient)
                .cornerRadius(3)
            }
            .chartYAxis {
                AxisMarks(position: .leading) { value in
                    AxisGridLine()
                    AxisValueLabel {
                        if let number = value.as(Double.self) {
                            Text(compact(number))
                                .font(.system(size: 9))
                        }
                    }
                }
            }
            .chartXAxis {
                AxisMarks { _ in
                    AxisValueLabel()
                        .font(.system(size: 9))
                }
            }
            .frame(height: 150)

            let total = model.months.reduce(0) { $0 + $1.spend }
            Text(total > 0 ? "这 12 个月共 \(Money.text(total))" : "这 12 个月没有记录花费")
                .font(.system(size: Theme.fontTiny))
                .foregroundStyle(Theme.textSub)
                .padding(.top, 8)
        }
        .padding(12)
        .cardStyle()
        .padding(.top, 12)
    }

    private func compact(_ value: Double) -> String {
        if value >= 10000 { return String(format: "%.1f万", value / 10000) }
        if value >= 1000 {
            let thousands = value / 1000
            // 1500 不能显示成 2k（会跟 2000 的刻度撞在一起）
            return thousands == thousands.rounded()
                ? String(format: "%.0fk", thousands)
                : String(format: "%.1fk", thousands)
        }
        return String(Int(value))
    }
}

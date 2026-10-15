//
//  DeclutterView.swift —— 断舍离
//
//  两块内容：
//   1. 建议处理：从衣橱数据里挑出来的「值得看一眼」的衣物（从没穿过 / 单次成本高 / 很久没穿）
//   2. 已处置：从这里把衣物恢复到衣橱，或者补充「卖了多少」
//
//  处置不会删除数据：衣物仍在库里，历史穿搭里照样看得到，只是从「在穿」列表里退出去。
//

import SwiftUI

final class DeclutterModel: ObservableObject {
    enum Tab: String, CaseIterable, Identifiable {
        case candidates
        case released

        var id: String { rawValue }
        var title: String {
            switch self {
            case .candidates: return "建议处理"
            case .released: return "已处置"
            }
        }
    }

    struct Row: Identifiable, Hashable {
        var id: String
        var name: String
        var image: String
        var category: String
        var detail: String
        /// 已处置才有：处置方式 + 日期
        var method: ReleaseMethod?
        var statusDate: String = ""
    }

    struct Group: Identifiable {
        var id: String
        var title: String
        var note: String
        var rows: [Row]
    }

    @Published var tab: Tab = .candidates
    @Published var groups: [Group] = []
    @Published var released: [Row] = []
    /// 连续多少天没穿的，算「很久没穿」
    static let idleDays = 90
    /// 单次成本超过多少算「贵」
    static let costThreshold: Double = 100

    init() {
        reload()
        AppState.shared.bus.on(.clothingChange, ctx: self) { [weak self] _ in
            DispatchQueue.main.async { self?.reload() }
        }
    }

    deinit {
        AppState.shared.bus.offBy(ctx: self)
    }

    func reload() {
        let all = Database.shared.listAllClothing()
        let active = all.filter { $0.isActive }
        let today = DateUtil.today()

        func row(_ item: ClothingItem, detail: String) -> Row {
            Row(
                id: item.id,
                name: item.name,
                image: item.coverImage.isEmpty ? item.originalImage : item.coverImage,
                category: item.category,
                detail: detail
            )
        }

        // 1) 买回来挺久、一次都没穿过
        let neverWorn = active
            .filter { $0.wearCount == 0 && DateUtil.daysBetween($0.purchaseDate.isEmpty ? DateUtil.formatDate(Date(timeIntervalSince1970: $0.createTime / 1000)) : $0.purchaseDate, today) >= 30 }
            .sorted { $0.createTime < $1.createTime }
            .prefix(20)
            .map { row($0, detail: "一次都还没穿过") }

        // 2) 单次成本最高（真穿过的才算）
        let expensive = active
            .compactMap { item -> (ClothingItem, Double)? in
                guard let cost = item.costPerWear, cost >= Self.costThreshold else { return nil }
                return (item, cost)
            }
            .sorted { $0.1 > $1.1 }
            .prefix(20)
            .map { row($0.0, detail: "单次成本 \(Money.costPerWear($0.1))") }

        // 3) 很久没穿
        let idle = active
            .filter { item in
                guard let last = item.lastWornDate.isEmpty ? nil : item.lastWornDate else { return false }
                return DateUtil.daysBetween(last, today) >= Self.idleDays
            }
            .sorted { $0.lastWornDate < $1.lastWornDate }
            .prefix(20)
            .map { row($0, detail: "\(DateUtil.daysBetween($0.lastWornDate, today)) 天没穿过") }

        groups = [
            Group(id: "never", title: "从没穿过", note: "买回来超过 30 天、一次都没穿过的：要么马上穿一次，要么考虑放手", rows: neverWorn),
            Group(id: "cost", title: "单次成本偏高", note: "每次穿都超过 \(Money.text(Self.costThreshold)) 的，看看是不是「假便宜」", rows: expensive),
            Group(id: "idle", title: "很久没穿", note: "超过 \(Self.idleDays) 天没穿的", rows: idle),
        ].filter { !$0.rows.isEmpty }

        released = all
            .filter { $0.isReleased }
            .sorted { $0.statusDate > $1.statusDate }
            .map { item in
                var detail = item.releaseMethod?.title ?? "已处置"
                if !item.statusDate.isEmpty { detail += " · " + DateUtil.friendlyDate(item.statusDate) }
                if item.price > 0 {
                    let net = item.netPrice
                    detail += " · 净花费 \(Money.text(net))"
                }
                return Row(
                    id: item.id,
                    name: item.name,
                    image: item.coverImage.isEmpty ? item.originalImage : item.coverImage,
                    category: item.category,
                    detail: detail,
                    method: item.releaseMethod,
                    statusDate: item.statusDate
                )
            }
    }

    /// 处置一件（建议列表里的「放手」）
    func release(_ id: String, method: ReleaseMethod) {
        Database.shared.releaseClothing(id, method: method)
        Haptic.success()
        ToastCenter.shared.show("已\(method.title)，可在「已处置」里找回")
    }

    /// 让它回到衣橱
    func restore(_ id: String) {
        Database.shared.restoreClothing(id)
        Haptic.light()
        ToastCenter.shared.show("已放回衣橱")
    }

    /// 补充卖掉的钱
    func setSoldPrice(_ id: String, price: Double) {
        Database.shared.updateClothing(id) { item in
            item.status = ReleaseMethod.sold.rawValue
            if item.statusDate.isEmpty { item.statusDate = DateUtil.today() }
            item.soldPrice = max(0, price)
        }
        ToastCenter.shared.show(price > 0 ? "已记下回血 \(Money.text(price))" : "已清空回血金额")
    }
}

struct DeclutterView: View {
    @StateObject private var model = DeclutterModel()
    @State private var detailId: String?
    @State private var priceTarget: String?
    @State private var showPriceInput = false

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                picker
                if model.tab == .candidates {
                    candidates
                } else {
                    releasedList
                }
            }
            .padding(Theme.pagePadding)
            .padding(.bottom, 40)
        }
        .background(Theme.bg)
        .navigationTitle("断舍离")
        .navigationBarTitleDisplayMode(.inline)
        .navigationDestination(item: $detailId) { id in
            ClothingDetailView(clothingId: id)
        }
        .textInputDialog(
            isPresented: $showPriceInput,
            title: "卖了多少",
            message: "记下回血金额，统计里能看到这件衣服的净成本",
            placeholder: "例如：120",
            confirmText: "保存"
        ) { value in
            guard let id = priceTarget else { return }
            let cleaned = value.trimmingCharacters(in: .whitespacesAndNewlines)
            model.setSoldPrice(id, price: Double(cleaned) ?? 0)
        }
    }

    private var picker: some View {
        Picker("", selection: $model.tab) {
            ForEach(DeclutterModel.Tab.allCases) { value in
                Text(value.title).tag(value)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .padding(.bottom, 12)
    }

    /* ==================== 建议处理 ==================== */

    @ViewBuilder
    private var candidates: some View {
        if model.groups.isEmpty {
            EmptyStateView(
                text: "暂时没有需要处理的衣物",
                desc: "衣橱里每件衣服都在被穿，或者还不够久。过段时间再来看看。"
            )
        } else {
            ForEach(model.groups) { group in
                VStack(alignment: .leading, spacing: 0) {
                    HStack(spacing: 6) {
                        Text(group.title)
                            .font(.system(size: Theme.fontSubtitle, weight: .semibold))
                            .foregroundStyle(Theme.text)
                        Text("\(group.rows.count)")
                            .font(.system(size: Theme.fontTiny))
                            .foregroundStyle(Theme.textSub)
                            .padding(.horizontal, 6)
                            .frame(height: 16)
                            .background(Theme.bg)
                            .clipShape(Capsule())
                    }
                    Text(group.note)
                        .font(.system(size: Theme.fontTiny))
                        .foregroundStyle(Theme.textLight)
                        .padding(.top, 3)
                        .padding(.bottom, 8)

                    VStack(spacing: 0) {
                        ForEach(group.rows) { row in
                            itemRow(row) { method in
                                model.release(row.id, method: method)
                            }
                            if row.id != group.rows.last?.id {
                                Rectangle().fill(Theme.border).frame(height: 0.5)
                            }
                        }
                    }
                    .padding(.horizontal, 12)
                    .cardStyle()
                }
                .padding(.top, 12)
            }
        }
    }

    private func itemRow(_ row: DeclutterModel.Row, onRelease: @escaping (ReleaseMethod) -> Void) -> some View {
        HStack(spacing: 10) {
            StoredImage(path: row.image, mode: .fit, maxPixel: 200, contentOnly: true)
                .frame(width: 46, height: 46)
                .background(Theme.imageWell)
                .clipShape(RoundedRectangle(cornerRadius: Theme.radiusSM, style: .continuous))

            VStack(alignment: .leading, spacing: 2) {
                Text(row.name)
                    .font(.system(size: Theme.fontBody))
                    .foregroundStyle(Theme.text)
                    .lineLimit(1)
                Text("\(row.category) · \(row.detail)")
                    .font(.system(size: Theme.fontTiny))
                    .foregroundStyle(Theme.textSub)
                    .lineLimit(1)
            }

            Spacer(minLength: 4)

            Menu {
                ForEach(ReleaseMethod.allCases) { method in
                    Button(method.title) { onRelease(method) }
                }
            } label: {
                Text("放手")
                    .font(.system(size: Theme.fontSmall))
                    .foregroundStyle(Theme.primaryDark)
                    .padding(.horizontal, 10)
                    .frame(height: 26)
                    .background(Theme.primarySoft)
                    .clipShape(Capsule())
            }
        }
        .padding(.vertical, 8)
        .contentShape(Rectangle())
        .onTapGesture { detailId = row.id }
    }

    /* ==================== 已处置 ==================== */

    @ViewBuilder
    private var releasedList: some View {
        if model.released.isEmpty {
            EmptyStateView(
                text: "还没有处置过衣物",
                desc: "在「建议处理」里让不再适合的衣服离开衣橱，它们会出现在这里。"
            )
        } else {
            VStack(spacing: 0) {
                ForEach(model.released) { row in
                    releasedRow(row)
                    if row.id != model.released.last?.id {
                        Rectangle().fill(Theme.border).frame(height: 0.5)
                    }
                }
            }
            .padding(.horizontal, 12)
            .cardStyle()
        }
    }

    private func releasedRow(_ row: DeclutterModel.Row) -> some View {
        HStack(spacing: 10) {
            StoredImage(path: row.image, mode: .fit, maxPixel: 200, contentOnly: true)
                .frame(width: 46, height: 46)
                .background(Theme.imageWell)
                .clipShape(RoundedRectangle(cornerRadius: Theme.radiusSM, style: .continuous))
                .opacity(0.75)

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

            Menu {
                Button("放回衣橱") { model.restore(row.id) }
                Button("记一笔回血金额") {
                    priceTarget = row.id
                    showPriceInput = true
                }
                Button("看这件的详情") { detailId = row.id }
            } label: {
                Image(systemName: "ellipsis.circle")
                    .font(.system(size: 17))
                    .foregroundStyle(Theme.textSub)
            }
        }
        .padding(.vertical, 8)
    }
}

//
//  BatchImportView.swift —— 批量导入衣物
//
//  从相册一次选多张（最多 20 张），逐张：原图落盘 → 系统抠图 → 猜一个分类 →
//  变成一行「草稿」，用户可以在列表里改名字 / 改分类 / 删掉不要的，最后一次性导入。
//
//  抠图是逐张跑 Vision，几百毫秒到一两秒一张，所以这里显示进度；
//  猜分类用的是原图（带背景时更准），猜不出来就留空让用户自己选。
//

import PhotosUI
import SwiftUI

final class BatchImportModel: ObservableObject {
    struct Item: Identifiable, Hashable {
        var id = UUID().uuidString
        /// 原图（落盘后的文件名）
        var source: String
        /// 抠好的图；没抠出来时为空，导入时退回原图
        var cut: String
        var category: String
        var name: String

        var preview: String { cut.isEmpty ? source : cut }
    }

    static let maxCount = 20

    @Published var items: [Item] = []
    @Published var processing = false
    @Published var progress = ""
    @Published var categories: [String] = Database.shared.listCategories()
    /// 导入完成后由页面负责返回上一页
    @Published var finished = false

    init() {
        AppState.shared.bus.on(.categoryChange, ctx: self) { [weak self] _ in
            DispatchQueue.main.async { self?.categories = Database.shared.listCategories() }
        }
    }

    deinit {
        AppState.shared.bus.offBy(ctx: self)
        // 没导入的先别删：页面关了也可能用户还会回来？—— 不，页面销毁时把没用的中间文件都清掉
        cleanupUnused()
    }

    var countText: String {
        items.isEmpty ? "还没有选照片" : "\(items.count) 件待导入"
    }

    /* ==================== 处理选中的照片 ==================== */

    func handle(_ datas: [Data]) {
        guard !datas.isEmpty else { return }
        let limited = Array(datas.prefix(Self.maxCount))
        if datas.count > Self.maxCount {
            ToastCenter.shared.show("一次最多导入 \(Self.maxCount) 张，先处理前 \(Self.maxCount) 张")
        }
        processing = true
        Task {
            for (index, data) in limited.enumerated() {
                await MainActor.run { progress = "处理中 \(index + 1)/\(limited.count)" }
                guard let source = ImageStore.shared.saveData(data, prefix: "cloth-src") else { continue }

                var cut = ""
                if let image = ImageStore.shared.image(for: source, maxPixelSize: 1600) {
                    let result = await CutoutService.shared.cutout(image: image, prefix: "cloth-cut")
                    if result.onDevice, !result.path.isEmpty { cut = result.path }
                }

                var category = categories.first ?? Wardrobe.defaultCategory
                var name = ""
                if let image = ImageStore.shared.image(for: source, maxPixelSize: 900) {
                    if let guessed = await ClassificationService.shared.guessCategory(for: image, categories: categories) {
                        category = guessed
                        name = guessed
                    }
                }
                let item = Item(source: source, cut: cut, category: category, name: name)
                await MainActor.run { items.append(item) }
            }
            await MainActor.run {
                processing = false
                progress = ""
                if !items.isEmpty {
                    ToastCenter.shared.show("处理好了，改完名字和分类就能导入")
                }
            }
        }
    }

    func remove(_ id: String) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        let item = items[index]
        items.remove(at: index)
        ImageStore.shared.removeFile(item.source)
        if !item.cut.isEmpty { ImageStore.shared.removeFile(item.cut) }
    }

    /// 全部设为同一个分类
    func setAllCategory(_ value: String) {
        for index in items.indices {
            items[index].category = value
            if items[index].name.isEmpty { items[index].name = value }
        }
    }

    /* ==================== 导入 ==================== */

    func save() -> Bool {
        guard !items.isEmpty else {
            ToastCenter.shared.show("先选几张照片吧")
            return false
        }
        var drafts: [ClothingDraft] = []
        for item in items {
            var draft = ClothingDraft()
            let fallback = categories.first ?? Wardrobe.defaultCategory
            draft.name = item.name.trimmingCharacters(in: .whitespacesAndNewlines)
            if draft.name.isEmpty { draft.name = item.category.isEmpty ? fallback : item.category }
            draft.category = item.category.isEmpty ? fallback : item.category
            draft.originalImage = item.source
            draft.coverImage = item.cut.isEmpty ? item.source : item.cut
            drafts.append(draft)
        }
        let created = Database.shared.addClothingBatch(drafts)
        Haptic.success()
        ToastCenter.shared.show("已导入 \(created.count) 件")
        items = []
        finished = true
        return true
    }

    /// 还没导入就把页面关了：把落盘的中间图片清掉，不留垃圾
    private func cleanupUnused() {
        guard !finished else { return }
        items.forEach { item in
            ImageStore.shared.removeFile(item.source)
            if !item.cut.isEmpty { ImageStore.shared.removeFile(item.cut) }
        }
    }
}

struct BatchImportView: View {
    @StateObject private var model = BatchImportModel()
    @Environment(\.dismiss) private var dismiss

    @State private var showPicker = false
    @State private var showAllCategory = false

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                head
                if model.items.isEmpty && !model.processing {
                    EmptyStateView(
                        text: "还没有选照片",
                        desc: "从相册一次选最多 \(BatchImportModel.maxCount) 张衣物照片，会自动抠图并猜一个分类，你只要核对一下。",
                        actionText: "选照片",
                        action: { showPicker = true }
                    )
                } else {
                    list
                }
            }
            .padding(Theme.pagePadding)
            .padding(.bottom, 40)
        }
        .background(Theme.bg)
        .navigationTitle("批量导入")
        .navigationBarTitleDisplayMode(.inline)
        .safeAreaInset(edge: .bottom) {
            if !model.items.isEmpty { saveBar }
        }
        .imagePicker(isPresented: $showPicker, maxSelection: BatchImportModel.maxCount) { datas in
            model.handle(datas)
        }
        .sheet(isPresented: $showAllCategory) {
            BatchCategorySheet(categories: model.categories) { value in
                showAllCategory = false
                model.setAllCategory(value)
            }
            .presentationDetents([.height(280)])
        }
        .overlay {
            if model.processing {
                ZStack {
                    Color.black.opacity(0.25).ignoresSafeArea()
                    VStack(spacing: 10) {
                        ProgressView()
                        Text(model.progress)
                            .font(.system(size: Theme.fontSmall))
                            .foregroundStyle(Theme.text)
                    }
                    .padding(20)
                    .background(Theme.card)
                    .clipShape(RoundedRectangle(cornerRadius: Theme.radius, style: .continuous))
                }
            }
        }
        .onChange(of: model.finished) { _, done in
            if done { DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { dismiss() } }
        }
    }

    private var head: some View {
        HStack {
            Text(model.countText)
                .font(.system(size: Theme.fontCaption))
                .foregroundStyle(Theme.textSub)
            Spacer()
            Button("继续选照片") { showPicker = true }
                .font(.system(size: Theme.fontSmall))
                .foregroundStyle(Theme.primary)
        }
        .padding(.bottom, 8)
    }

    private var list: some View {
        VStack(spacing: 0) {
            ForEach($model.items) { $item in
                row(item: $item)
                if item.id != model.items.last?.id {
                    Rectangle().fill(Theme.border).frame(height: 0.5)
                }
            }
        }
        .padding(.horizontal, 12)
        .cardStyle()
    }

    private func row(item: Binding<BatchImportModel.Item>) -> some View {
        HStack(spacing: 10) {
            StoredImage(path: item.wrappedValue.preview, mode: .fit, maxPixel: 300, contentOnly: true)
                .frame(width: 54, height: 54)
                .background(Theme.imageWell)
                .clipShape(RoundedRectangle(cornerRadius: Theme.radiusSM, style: .continuous))

            VStack(alignment: .leading, spacing: 6) {
                TextField("名字", text: item.name)
                    .font(.system(size: Theme.fontBody))
                    .textFieldStyle(.plain)
                    .padding(.horizontal, 8)
                    .frame(height: 30)
                    .background(Theme.bg)
                    .clipShape(RoundedRectangle(cornerRadius: Theme.radiusSM, style: .continuous))

                Menu {
                    ForEach(model.categories, id: \.self) { value in
                        Button(value) { item.wrappedValue.category = value }
                    }
                } label: {
                    HStack(spacing: 3) {
                        Text(item.wrappedValue.category)
                            .font(.system(size: Theme.fontTiny))
                        Image(systemName: "chevron.down")
                            .font(.system(size: 9))
                    }
                    .foregroundStyle(Theme.primaryDark)
                    .padding(.horizontal, 8)
                    .frame(height: 22)
                    .background(Theme.primarySoft)
                    .clipShape(Capsule())
                }
            }

            Button {
                model.remove(item.wrappedValue.id)
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 18))
                    .foregroundStyle(Theme.textLight)
            }
            .buttonStyle(.plain)
        }
        .padding(.vertical, 10)
    }

    private var saveBar: some View {
        FloatingActionBar {
            Button("统一分类") { showAllCategory = true }
                .buttonStyle(AppButtonStyle(kind: .ghost, small: true))
            Button("导入 \(model.items.count) 件") {
                _ = model.save()
            }
            .buttonStyle(AppButtonStyle(kind: .primary, small: true))
            .frame(maxWidth: .infinity)
        }
    }
}

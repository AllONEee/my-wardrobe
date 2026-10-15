//
//  ImageEditorView.swift —— 抠图 / 图片编辑（对应 pages/image-editor）
//
//  进入方式：ImageEditorView(source: 图片文件名) { 处理结果文件名 in ... }
//  onDone 回传的是已经落盘的 PNG 文件名（带透明通道），由调用方决定怎么用；
//  点「取消」则什么都不回传。
//
//  抠图流程（模仿系统相册那套）：
//   1. 进页面自动调一次系统抠图（Vision 前景实例遮罩），直接给出一张抠好的图
//   2. 想只要其中一件时：长按画面里的衣物主体，只把手指底下那件抠出来
//      （系统也是长按提起主体，这里是同一个「实例」的粒度）
//   3. 不满意再用橡皮擦 / 画笔恢复 / 裁剪细修，每一步都能撤销 / 重做
//
//  布局（自上而下）：模式行（橡皮擦 / 画笔恢复 / 裁剪 + 笔刷滑块）→ 画面 →
//  提示 → 撤销 / 自动抠图 / 重做 → 取消 / 确定。
//

import SwiftUI

struct ImageEditorView: View {
    let source: String
    var onDone: ((String) -> Void)?

    @Environment(\.dismiss) private var dismiss
    @StateObject private var proxy = EditorProxy()
    /// 悬浮底栏占掉的高度：页面里自带的底部操作栏要按它往上让
    @Environment(\.floatingBarInset) private var floatingBarInset

    @State private var mode: EditorMode = .erase
    @State private var brush: Double = 18
    /// 进页面会自动抠出主体，所以默认就铺棋盘格（透明区域一眼可见）
    @State private var bgPlain = false
    @State private var bgTouched = false
    /// 自动抠图 / 长按抠图进行中
    @State private var processing = false
    @State private var exporting = false
    @State private var showResetConfirm = false
    @State private var dialogTitle = ""
    @State private var dialogMessage: String?
    /// 替换默认提示（自动抠图的结果 / 失败原因）
    @State private var hintOverride: String?
    @State private var didAutoCut = false
    /// 点过「确定」后不再清理本次产生的文件（最终图要留着）
    @State private var confirmed = false
    /// 本次进编辑器产生的中间文件（自动抠图 / 长按抠图的结果），离开时清理
    @State private var createdFiles: [String] = []

    init(source: String, onDone: ((String) -> Void)? = nil) {
        self.source = source
        self.onDone = onDone
    }

    var body: some View {
        VStack(spacing: 0) {
            modeRow
            stage
            hint
            actionRow
            confirmBar
        }
        .background(Theme.bg)
        .navigationTitle("抠图")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("重置") { showResetConfirm = true }
                    .font(.system(size: Theme.fontSmall))
                    .foregroundStyle(Theme.textSub)
            }
        }
        .task {
            // 等画布把图片装载好（大图解码要一点时间），然后自动跑一次系统抠图
            for _ in 0..<80 {
                if !proxy.loading, proxy.canvas != nil { break }
                try? await Task.sleep(nanoseconds: 50_000_000)
            }
            guard !Task.isCancelled, !didAutoCut else { return }
            didAutoCut = true
            autoCutout(automatic: true)
        }
        .onDisappear {
            // 没点「确定」就离开（左滑返回 / 取消）：本次产生的抠图文件全部删掉，不留垃圾
            guard !confirmed else { return }
            createdFiles.forEach { ImageStore.shared.removeFile($0) }
            createdFiles = []
        }
        .alert("重置", isPresented: $showResetConfirm) {
            Button("取消", role: .cancel) {}
            Button("重置", role: .destructive) {
                proxy.canvas?.reset()
                bgPlain = false
                hintOverride = "已回到原图，可以长按衣物主体重新抠，或者用橡皮擦手动擦"
                ToastCenter.shared.show("已回到原图")
            }
        } message: {
            Text("会清空本次的涂抹与裁剪，回到最初的原图（抠图结果也会一并撤销）。")
        }
        .messageDialog(
            isPresented: Binding(
                get: { dialogMessage != nil },
                set: { if !$0 { dialogMessage = nil } }
            ),
            title: dialogTitle,
            message: dialogMessage ?? ""
        )
    }

    /* ==================== 模式 + 笔刷（同一行） ==================== */

    private var modeRow: some View {
        HStack(spacing: 10) {
            ForEach(EditorMode.allCases, id: \.self) { value in
                Button {
                    mode = value
                    hintOverride = nil   // 换模式后就按当前模式给提示
                    proxy.canvas?.setMode(value)
                } label: {
                    VStack(spacing: 3) {
                        Text(value.title)
                            .font(.system(size: Theme.fontBody, weight: mode == value ? .medium : .regular))
                            .foregroundStyle(mode == value ? Theme.primary : Theme.textSub)
                            .fixedSize()
                        Rectangle()
                            .fill(mode == value ? Theme.primary : Color.clear)
                            .frame(height: 2)
                    }
                }
                .buttonStyle(.plain)
            }

            Spacer(minLength: 4)

            // 笔刷粗细：无级调节，橡皮擦与画笔恢复共用（裁剪模式下用不到，置灰但保留位置）
            HStack(spacing: 6) {
                Image(systemName: "paintbrush.pointed.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.textLight)
                Slider(value: $brush, in: 4...112)
                    .tint(Theme.primary)
                    .frame(width: 112)
                    .onChange(of: brush) { _, value in
                        proxy.canvas?.brushSize = CGFloat(value)
                    }
                Text("\(Int(brush))")
                    .font(.system(size: Theme.fontCaption).monospacedDigit())
                    .foregroundStyle(Theme.text)
                    .frame(width: 22, alignment: .trailing)
            }
            .opacity(mode == .crop ? 0.4 : 1)
            .disabled(mode == .crop)
        }
        .padding(.horizontal, 12)
        .padding(.top, 6)
        .padding(.bottom, 4)
        .background(Theme.card)
    }

    /* ==================== 画面 ==================== */

    private var stage: some View {
        ZStack {
            if bgPlain {
                Color.white
            } else {
                CheckerboardBackground()
            }
            EditorCanvasView(
                proxy: proxy,
                mode: mode,
                brushSize: brush,
                source: source,
                processing: processing,
                onFirstEdit: {
                    // 第一次擦 / 补 / 抠的时候自动切到棋盘格：白底照上不切，用户根本看不出擦掉了哪里
                    if !bgTouched { bgPlain = false }
                },
                onMessage: { message in
                    ToastCenter.shared.show(message)
                },
                onLongPress: { point in
                    longPressCutout(at: point)
                }
            )

            if proxy.loading || processing {
                ZStack {
                    Theme.bg.opacity(0.85)
                    HStack(spacing: 8) {
                        ProgressView().scaleEffect(0.8)
                        Text(processing ? "正在识别主体…" : "图片加载中…")
                            .font(.system(size: Theme.fontSmall))
                            .foregroundStyle(Theme.textSub)
                    }
                }
            }

            VStack {
                HStack {
                    Spacer()
                    Button {
                        bgTouched = true
                        bgPlain.toggle()
                        ToastCenter.shared.show(bgPlain ? "已切到白底" : "已切到棋盘格")
                    } label: {
                        Text(bgPlain ? "白底" : "棋盘格")
                            .font(.system(size: Theme.fontTiny))
                            .foregroundStyle(Theme.textSub)
                            .padding(.horizontal, 10)
                            .frame(height: 24)
                            .background(.ultraThinMaterial, in: Capsule())
                            .clipShape(Capsule())
                            .shadow(color: .black.opacity(0.14), radius: 4, x: 0, y: 1)
                    }
                    .padding(8)
                }
                Spacer()
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: Theme.radius, style: .continuous))
        .shadow(color: Color.black.opacity(0.06), radius: 12, x: 0, y: 4)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .frame(maxHeight: .infinity)
    }

    private var hint: some View {
        Text(hintOverride ?? mode.hint)
            .font(.system(size: Theme.fontCaption))
            .foregroundStyle(Theme.textSub)
            .multilineTextAlignment(.center)
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 16)
            .padding(.bottom, 8)
    }

    /* ==================== 撤销 / 自动抠图 / 重做 ==================== */

    private var actionRow: some View {
        HStack(spacing: 0) {
            historyButton(
                title: "撤销",
                icon: "arrow.uturn.backward",
                enabled: proxy.canUndo && !processing
            ) {
                proxy.canvas?.undo()
            }

            Spacer(minLength: 12)

            Button {
                autoCutout(automatic: false)
            } label: {
                HStack(spacing: 6) {
                    if processing {
                        ProgressView().scaleEffect(0.7)
                    } else {
                        Image(systemName: "wand.and.stars")
                            .font(.system(size: 14))
                    }
                    Text(processing ? "抠图中…" : "自动抠图")
                        .font(.system(size: Theme.fontSubtitle, weight: .medium))
                }
                .foregroundStyle(Theme.primaryDark)
                .padding(.horizontal, 18)
                .frame(height: 40)
                .background(Theme.primarySoft)
                .clipShape(Capsule())
                .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .disabled(processing || proxy.loading)

            Spacer(minLength: 12)

            historyButton(
                title: "重做",
                icon: "arrow.uturn.forward",
                enabled: proxy.canRedo && !processing
            ) {
                proxy.canvas?.redo()
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 8)
        .background(Theme.card)
        .overlay(alignment: .top) {
            Rectangle().fill(Theme.border).frame(height: 0.5)
        }
    }

    private func historyButton(
        title: String,
        icon: String,
        enabled: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            VStack(spacing: 2) {
                Image(systemName: icon)
                    .font(.system(size: 17, weight: .medium))
                Text(title)
                    .font(.system(size: Theme.fontTiny))
            }
            .foregroundStyle(enabled ? Theme.text : Theme.textLight)
            .frame(width: 54)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.5)
    }

    /* ==================== 底部确认栏 ==================== */

    private var confirmBar: some View {
        FloatingActionBar {
            Button("取消") { dismiss() }
                .buttonStyle(AppButtonStyle(kind: .ghost, fullWidth: true))
            Button(exporting ? "生成中…" : "确定") { confirm() }
                .buttonStyle(AppButtonStyle(kind: .primary, fullWidth: true))
                .disabled(exporting || processing)
        }
    }

    /* ==================== 动作 ==================== */

    private func confirm() {
        guard !exporting, let canvas = proxy.canvas else { return }
        exporting = true
        guard let path = canvas.exportPNG() else {
            exporting = false
            ToastCenter.shared.show("生成图片失败")
            return
        }
        exporting = false
        confirmed = true
        // 中间文件（自动抠图 / 长按抠图的结果）留着没用，只留最终这张
        createdFiles.forEach { file in
            if file != path { ImageStore.shared.removeFile(file) }
        }
        createdFiles = []
        onDone?(path)
        dismiss()
    }

    /// 自动抠图：直接走 iOS 视觉框架。
    /// - Parameter automatic: true = 进页面时自动跑的第一次（失败不弹框，只改提示文案，别一进来就打断用户）
    private func autoCutout(automatic: Bool) {
        guard !processing, let canvas = proxy.canvas, let image = canvas.currentCompositeImage() else {
            if !automatic { ToastCenter.shared.show("没有可处理的图片") }
            return
        }
        let box = canvas.currentSourceBox
        processing = true
        Task {
            let result = await CutoutService.shared.cutout(image: image, prefix: "cloth-cut")
            processing = false
            guard result.onDevice else {
                hintOverride = result.message
                if automatic {
                    ToastCenter.shared.show("没抠出主体，可以长按衣物试试，或用橡皮擦手动擦")
                } else {
                    dialogTitle = "自动抠图没有成功"
                    dialogMessage = result.message
                        + "\n\n也可以长按画面里的衣物主体只抠那一件；橡皮擦擦掉背景、画笔把抠多的涂回来。"
                }
                return
            }
            createdFiles.append(result.path)
            if canvas.replaceBase(stored: result.path, sourceBox: box) {
                bgPlain = false
                hintOverride = "长按衣物主体可以只抠出那一件；抠多了用橡皮擦，抠少了用画笔恢复"
                if !automatic { ToastCenter.shared.show("抠图完成") }
                Haptic.success()
            } else {
                ImageStore.shared.removeFile(result.path)
                createdFiles.removeAll { $0 == result.path }
                ToastCenter.shared.show("抠图结果应用失败，请重试")
            }
        }
    }

    /// 长按抠图：只抠出长按位置底下的那件衣物
    private func longPressCutout(at point: CGPoint) {
        guard !processing, let canvas = proxy.canvas else { return }
        guard let image = canvas.sourceImageForCutout() else {
            ToastCenter.shared.show("没有可处理的图片")
            return
        }
        let box = canvas.currentSourceBox
        processing = true
        Task {
            let result = await CutoutService.shared.cutoutInstance(image: image, at: point, prefix: "cloth-cut")
            processing = false
            guard result.ok else {
                ToastCenter.shared.show(result.message)
                return
            }
            createdFiles.append(result.path)
            if canvas.replaceBase(stored: result.path, sourceBox: box) {
                bgPlain = false
                hintOverride = "已抠出长按的那件；抠多了用橡皮擦，抠少了用画笔恢复"
                if result.instanceCount > 1 {
                    ToastCenter.shared.show("已抠出长按的衣物（这张图里共 \(result.instanceCount) 件）")
                } else {
                    ToastCenter.shared.show("已抠出长按的衣物")
                }
                Haptic.success()
            } else {
                ImageStore.shared.removeFile(result.path)
                createdFiles.removeAll { $0 == result.path }
                ToastCenter.shared.show("抠图结果应用失败，请重试")
            }
        }
    }
}

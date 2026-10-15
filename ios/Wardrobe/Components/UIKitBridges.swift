//
//  UIKitBridges.swift —— 小程序 API 在 iOS 上的对应实现
//
//   wx.showToast            -> ToastCenter + .appToast()
//   wx.showModal            -> .textInputDialog(...)（可编辑 / 只提示两种都走它）
//   wx.showActionSheet      -> 原生 confirmationDialog
//   imageUtil.chooseImage   -> .imagePicker(...)（相册用系统 PhotosPicker，拍照用相机面板）
//   wx.vibrateShort         -> Haptic
//   wx.previewImage         -> ImagePreviewSheet
//

import PhotosUI
import SwiftUI
import UIKit
import UniformTypeIdentifiers

/* ==================== 轻提示（对应 wx.showToast） ==================== */

final class ToastCenter: ObservableObject {
    static let shared = ToastCenter()

    @Published private(set) var message = ""
    @Published private(set) var visible = false
    /// 轻提示里的动作按钮（比如「+1」之后的「撤销」）
    @Published private(set) var actionTitle = ""

    private var work: DispatchWorkItem?
    private var action: (() -> Void)?

    private init() {}

    func show(
        _ text: String,
        duration: TimeInterval = 1.6,
        actionTitle: String = "",
        action: (() -> Void)? = nil
    ) {
        guard !text.isEmpty else { return }
        work?.cancel()
        message = text
        self.actionTitle = actionTitle
        self.action = action
        visible = true
        // 带按钮的提示要多停一会儿，不然手还没抬起来就没了
        let seconds = action == nil ? duration : max(duration, 3.4)
        let task = DispatchWorkItem { [weak self] in
            withAnimation(.easeOut(duration: 0.2)) { self?.visible = false }
        }
        work = task
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: task)
    }

    /// 点了提示里的动作按钮
    func performAction() {
        let block = action
        work?.cancel()
        action = nil
        actionTitle = ""
        withAnimation(.easeOut(duration: 0.2)) { visible = false }
        block?()
    }
}

struct ToastOverlayModifier: ViewModifier {
    @ObservedObject private var center = ToastCenter.shared

    func body(content: Content) -> some View {
        content.overlay(alignment: .bottom) {
            if center.visible {
                HStack(spacing: 14) {
                    Text(center.message)
                        .font(.system(size: Theme.fontSmall))
                        .foregroundStyle(.white)
                        .multilineTextAlignment(.center)
                    if !center.actionTitle.isEmpty {
                        Button(center.actionTitle) {
                            center.performAction()
                        }
                        .font(.system(size: Theme.fontSmall, weight: .semibold))
                        .foregroundStyle(Theme.primary)
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .background(Theme.toast)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .padding(.horizontal, 40)
                .padding(.bottom, 96)
                .transition(.opacity.combined(with: .move(edge: .bottom)))
            }
        }
        .animation(.easeOut(duration: 0.18), value: center.visible)
    }
}

extension View {
    /// 在页面根视图上挂一次就够了
    func appToast() -> some View {
        modifier(ToastOverlayModifier())
    }
}

/* ==================== 弹窗（对应 wx.showModal） ==================== */

struct TextInputDialogModifier: ViewModifier {
    @Binding var isPresented: Bool
    let title: String
    let message: String
    let placeholder: String
    let initialText: String
    let confirmText: String
    let cancelText: String
    /// false 时只展示 message 与一个确定按钮（对应没有 editable 的 showModal）
    let editable: Bool
    let showCancel: Bool
    let confirmColor: Color
    let onConfirm: (String) -> Void

    @State private var text: String = ""
    @FocusState private var focused: Bool

    func body(content: Content) -> some View {
        ZStack {
            content
            if isPresented {
                Color.black.opacity(0.35)
                    .ignoresSafeArea()
                    .onTapGesture {
                        if !editable && !showCancel {
                            dismiss()
                        }
                    }
                card
                    .transition(.scale(scale: 0.96).combined(with: .opacity))
            }
        }
        .animation(.easeOut(duration: 0.16), value: isPresented)
        .onChange(of: isPresented) { _, presented in
            if presented {
                text = initialText
                if editable {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { focused = true }
                }
            }
        }
    }

    private var card: some View {
        VStack(spacing: 0) {
            Text(title)
                .font(.system(size: Theme.fontTitle, weight: .semibold))
                .foregroundStyle(Theme.text)
                .padding(.top, 20)

            if !message.isEmpty {
                ScrollView {
                    Text(message)
                        .font(.system(size: Theme.fontSmall))
                        .foregroundStyle(Theme.textSub)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.top, 10)
                }
                .frame(maxHeight: 180)
                .padding(.horizontal, 20)
            }

            if editable {
                TextField(placeholder, text: $text)
                    .focused($focused)
                    .font(.system(size: Theme.fontBody))
                    .padding(.horizontal, 12)
                    .frame(height: 40)
                    .background(Theme.bg)
                    .clipShape(RoundedRectangle(cornerRadius: Theme.radiusSM, style: .continuous))
                    .padding(.horizontal, 20)
                    .padding(.top, 14)
            }

            HStack(spacing: 10) {
                if showCancel {
                    Button(cancelText) { dismiss() }
                        .buttonStyle(AppButtonStyle(kind: .ghost))
                        .frame(maxWidth: .infinity)
                }
                Button(confirmText) {
                    let value = text
                    dismiss()
                    onConfirm(value)
                }
                .buttonStyle(AppButtonStyle(kind: .primary))
                .frame(maxWidth: .infinity)
            }
            .padding(.horizontal, 20)
            .padding(.top, 18)
            .padding(.bottom, 18)
        }
        .frame(maxWidth: 320)
        .background(Theme.card)
        .clipShape(RoundedRectangle(cornerRadius: Theme.radiusLG, style: .continuous))
        .shadow(color: Color.black.opacity(0.18), radius: 24, x: 0, y: 12)
        .padding(.horizontal, 36)
    }

    private func dismiss() {
        focused = false
        withAnimation(.easeOut(duration: 0.16)) { isPresented = false }
    }
}

extension View {
    /// 可编辑弹窗（对应 wx.showModal 的 editable）
    func textInputDialog(
        isPresented: Binding<Bool>,
        title: String,
        message: String = "",
        placeholder: String = "",
        initialText: String = "",
        confirmText: String = "确定",
        cancelText: String = "取消",
        showCancel: Bool = true,
        confirmColor: Color = Theme.primary,
        onConfirm: @escaping (String) -> Void
    ) -> some View {
        modifier(
            TextInputDialogModifier(
                isPresented: isPresented,
                title: title,
                message: message,
                placeholder: placeholder,
                initialText: initialText,
                confirmText: confirmText,
                cancelText: cancelText,
                editable: true,
                showCancel: showCancel,
                confirmColor: confirmColor,
                onConfirm: onConfirm
            )
        )
    }

    /// 纯提示弹窗（对应 showModal 不带 editable 的用法）
    func messageDialog(
        isPresented: Binding<Bool>,
        title: String,
        message: String = "",
        confirmText: String = "知道了"
    ) -> some View {
        modifier(
            TextInputDialogModifier(
                isPresented: isPresented,
                title: title,
                message: message,
                placeholder: "",
                initialText: "",
                confirmText: confirmText,
                cancelText: "",
                editable: false,
                showCancel: false,
                confirmColor: Theme.primary,
                onConfirm: { _ in }
            )
        )
    }
}

/* ==================== 选图（对应 imageUtil.chooseImage） ==================== */

struct ImagePickerModifier: ViewModifier {
    @Binding var isPresented: Bool
    let maxSelection: Int
    let onPicked: ([Data]) -> Void
    let onCancel: () -> Void

    @State private var showPhotos = false
    @State private var showCamera = false
    @State private var selection: [PhotosPickerItem] = []
    @State private var loading = false

    func body(content: Content) -> some View {
        content
            .confirmationDialog("选择照片", isPresented: $isPresented, titleVisibility: .hidden) {
                Button("从相册选择") { showPhotos = true }
                if UIImagePickerController.isSourceTypeAvailable(.camera) {
                    Button("拍照") { showCamera = true }
                }
                Button("取消", role: .cancel) { onCancel() }
            }
            .photosPicker(
                isPresented: $showPhotos,
                selection: $selection,
                maxSelectionCount: max(1, maxSelection),
                matching: .images
            )
            .onChange(of: selection) { _, items in
                guard !items.isEmpty else { return }
                load(items)
            }
            .sheet(isPresented: $showCamera) {
                CameraPicker { data in
                    onPicked([data])
                }
                .ignoresSafeArea()
            }
            .overlay {
                if loading {
                    ZStack {
                        Color.black.opacity(0.25).ignoresSafeArea()
                        ProgressView()
                            .padding(18)
                            .background(Theme.card)
                            .clipShape(RoundedRectangle(cornerRadius: Theme.radius, style: .continuous))
                    }
                }
            }
    }

    private func load(_ items: [PhotosPickerItem]) {
        loading = true
        Task {
            var datas: [Data] = []
            for item in items {
                if let data = try? await item.loadTransferable(type: Data.self) {
                    datas.append(data)
                }
            }
            await MainActor.run {
                loading = false
                selection = []
                if datas.isEmpty {
                    onCancel()
                } else {
                    onPicked(datas)
                }
            }
        }
    }
}

extension View {
    /// 弹「相册 / 拍照」，回调的是图片数据（落盘走 ImageStore.saveData）
    func imagePicker(
        isPresented: Binding<Bool>,
        maxSelection: Int = 1,
        onCancel: @escaping () -> Void = {},
        onPicked: @escaping ([Data]) -> Void
    ) -> some View {
        modifier(
            ImagePickerModifier(
                isPresented: isPresented,
                maxSelection: maxSelection,
                onPicked: onPicked,
                onCancel: onCancel
            )
        )
    }
}

/// 相机（UIImagePickerController）
struct CameraPicker: UIViewControllerRepresentable {
    let onPicked: (Data) -> Void

    @Environment(\.dismiss) private var dismiss

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = .camera
        picker.cameraCaptureMode = .photo
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ uiViewController: UIImagePickerController, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        private let parent: CameraPicker

        init(_ parent: CameraPicker) {
            self.parent = parent
        }

        func imagePickerController(
            _ picker: UIImagePickerController,
            didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]
        ) {
            if let image = info[.originalImage] as? UIImage, let data = image.jpegData(compressionQuality: 0.9) {
                parent.onPicked(data)
            }
            parent.dismiss()
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            parent.dismiss()
        }
    }
}

/* ==================== 分享文件（对应 wx.shareFileMessage） ==================== */

struct ActivityView: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}

/* ==================== 选一个文件夹（恢复备份用） ==================== */

/// 让用户在「文件」App 里挑一个文件夹（备份就是一个文件夹：data.json + images/）
struct FolderPicker: UIViewControllerRepresentable {
    let onPick: (URL) -> Void
    let onCancel: () -> Void

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.folder], asCopy: false)
        picker.allowsMultipleSelection = false
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ uiViewController: UIDocumentPickerViewController, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    final class Coordinator: NSObject, UIDocumentPickerDelegate {
        private let parent: FolderPicker

        init(_ parent: FolderPicker) {
            self.parent = parent
        }

        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            guard let url = urls.first else {
                parent.onCancel()
                return
            }
            parent.onPick(url)
        }

        func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
            parent.onCancel()
        }
    }
}

/* ==================== 触感反馈（对应 wx.vibrateShort） ==================== */

enum Haptic {
    static func light() {
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
    }

    static func medium() {
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
    }

    static func success() {
        UINotificationFeedbackGenerator().notificationOccurred(.success)
    }
}

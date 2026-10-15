//
//  EditorCanvas.swift —— 抠图编辑器的画布视图（对应 components/image-canvas + 页面里的手势逻辑）
//
//  手势约定（和小程序一致）：
//   - 单指：橡皮擦 / 画笔涂抹，或拖动裁剪框；双指：缩放 + 平移（任何模式下都可用）
//   - 双指期间不再响应涂抹，等手指全部抬起才恢复，避免误画
//   - 笔刷粗细按屏幕上看到的尺寸折算到图像坐标，缩放后手感一致
//
//  页面只通过这里暴露的方法操作画布：加载、撤销、重做、重置、换底图（系统抠图）、导出。
//

import UIKit

/// 画布状态（回调给 SwiftUI 更新按钮可用性等）
struct EditorCanvasState {
    var canUndo = false
    var canRedo = false
    var loading = true
}

final class EditorCanvas: UIView {
    /// 编辑时的长边上限：超过就先缩小，避免超大图占内存（导出上限本来也只有 1600）
    private static let workingMaxSide: CGFloat = 2048
    /// 导出长边上限，控制文件体积（与小程序的 EXPORT_MAX_SIDE 一致）
    static let exportMaxSide: CGFloat = 1600
    /// 裁剪框最小边长（图像坐标 / 屏幕像素）
    private static let minCrop: CGFloat = 24
    private static let minCropScreen: CGFloat = 20
    private static let maxZoom: CGFloat = 8

    var onStateChange: ((EditorCanvasState) -> Void)?
    /// 第一次真的擦 / 补 / 抠时通知页面（页面据此把底色从白底切成棋盘格）
    var onFirstEdit: (() -> Void)?
    /// 提示（裁剪框太小、加载失败等）
    var onMessage: ((String) -> Void)?
    /// 长按衣物主体：回调带「原图坐标」的位置（模仿系统相册的抠图手势，画面自己换算好坐标）
    var onLongPress: ((CGPoint) -> Void)?
    /// 正在跑自动抠图 / 长按抠图：这段时间不接受涂抹，避免和识别结果打架
    var processing = false

    private(set) var mode: EditorMode = .erase
    var brushSize: CGFloat = 18

    private var renderer: EditorRenderer?
    private var sourceStored = ""
    private var sourceImage: CGImage?
    /// 当前底图里「有内容」的那块（衣服的外接矩形，图像坐标）。
    /// 画面按它来缩放：抠完的图四周是整片透明时，衣服也能撑满画布、涂抹更精确。
    private var contentBox: CGRect = .zero

    private var fitScale: CGFloat = 1
    private var viewScale: CGFloat = 1
    private var offset: CGPoint = .zero

    private var stroke: [CGPoint] = []
    private var cropStart: CGPoint?
    private var cropImageRect: CGRect?
    private var pinchStart: (distance: CGFloat, mid: CGPoint, scale: CGFloat, offset: CGPoint)?
    private var pinching = false
    private var suppressDrawing = false
    private var busy = false
    private var firstEditReported = false
    /// 长按识别（系统抠图手势）用
    private var pressWork: DispatchWorkItem?
    private var pressImagePoint: CGPoint?
    private var pressViewPoint: CGPoint?
    private var longPressFired = false
    private static let longPressDelay: TimeInterval = 0.5
    private static let longPressTolerance: CGFloat = 12

    private let imageView = UIImageView()
    private let overlay = CropOverlayView()

    override init(frame: CGRect) {
        super.init(frame: frame)
        setup()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setup()
    }

    private func setup() {
        backgroundColor = .clear
        isMultipleTouchEnabled = true
        clipsToBounds = true

        imageView.contentMode = .scaleToFill
        imageView.isUserInteractionEnabled = false
        addSubview(imageView)
        addSubview(overlay)
    }

    /* ==================== 对外接口 ==================== */

    func setMode(_ mode: EditorMode) {
        guard mode != self.mode else { return }
        finishStroke()
        cancelLongPress()
        cropStart = nil
        cropImageRect = nil
        overlay.cropRect = nil
        self.mode = mode
        refresh()
    }

    /// 加载底图（stored 是数据里记的文件名）
    func load(source stored: String) {
        sourceStored = stored
        busy = true
        emitState(loading: true)

        guard let image = EditorCanvas.decodeWorkingImage(stored: stored) else {
            busy = false
            emitState(loading: false)
            onMessage?("画布或图片加载失败")
            return
        }

        sourceImage = image
        renderer = EditorRenderer(
            stored: stored,
            base: image,
            source: image,
            sourceBox: CGRect(x: 0, y: 0, width: CGFloat(image.width), height: CGFloat(image.height))
        )
        busy = false
        viewScale = 1
        offset = .zero
        firstEditReported = false
        refreshContentBox()
        recalcFit()
        refresh()
        emitState(loading: false)
    }

    func undo() {
        guard !busy, let renderer else { return }
        handle(renderer.undo())
    }

    func redo() {
        guard !busy, let renderer else { return }
        handle(renderer.redo())
    }

    /// 重置：回到最初的原图（抠图结果也会一并撤销）
    func reset() {
        guard !busy, let renderer, let sourceImage else { return }
        renderer.resetToSource(stored: sourceStored, image: sourceImage)
        viewScale = 1
        offset = .zero
        refreshContentBox()
        recalcFit()
        refresh()
    }

    /// 系统抠图换了底图
    @discardableResult
    func replaceBase(stored: String) -> Bool {
        replaceBase(stored: stored, sourceBox: renderer?.sourceBox ?? .zero)
    }

    /// 换底图（系统抠图 / 长按抠图）
    /// - Parameter sourceBox: 新底图对应原图里的哪块区域；新底图和当前底图同框时保持原值即可
    @discardableResult
    func replaceBase(stored: String, sourceBox: CGRect) -> Bool {
        guard let renderer else { return false }
        guard let url = ImageStore.shared.url(for: stored),
              let image = UIImage(contentsOfFile: url.path),
              let cgImage = image.cgImage else {
            onMessage?("抠图结果读取失败，请重试")
            return false
        }
        reportFirstEdit()
        guard renderer.replaceBase(stored: stored, base: cgImage, sourceBox: sourceBox) else { return false }
        viewScale = 1
        offset = .zero
        refreshContentBox()
        recalcFit()
        refresh()
        return true
    }

    /// 长按抠图用的原图区域（裁剪过的话就是原图里对应的那一块）
    private var cutoutBox: CGRect {
        renderer?.sourceBox.integral ?? .zero
    }

    /// 当前底图对应的原图区域（长按抠图拿它去识别主体：原图上实例区分得最清楚）
    func sourceImageForCutout() -> UIImage? {
        guard let renderer else { return nil }
        let box = cutoutBox
        guard box.width >= 1, box.height >= 1, let cropped = renderer.source.cropping(to: box) else {
            return UIImage(cgImage: renderer.source)
        }
        return UIImage(cgImage: cropped)
    }

    /// 当前底图对应的原图区域
    var currentSourceBox: CGRect { renderer?.sourceBox ?? .zero }

    /// 导出 PNG（带透明通道）并落盘，返回文件名
    func exportPNG() -> String? {
        guard let renderer, let composite = renderer.compositeImage() else { return nil }
        // 抠图结果保留的是原图尺寸，衣服通常只占中间一块：存之前按内容外接矩形裁一刀，
        // 不然会「衣服小、定位框大」（试衣间里最难摆），衣柜卡片上的衣服也显小。
        let image = ImageStore.cropToContent(composite) ?? composite
        let longSide = CGFloat(max(image.width, image.height))
        let uiImage: UIImage
        if longSide > EditorCanvas.exportMaxSide {
            let ratio = EditorCanvas.exportMaxSide / longSide
            let size = CGSize(
                width: max(1, (CGFloat(image.width) * ratio).rounded()),
                height: max(1, (CGFloat(image.height) * ratio).rounded())
            )
            let format = UIGraphicsImageRendererFormat.default()
            format.scale = 1
            format.opaque = false
            uiImage = UIGraphicsImageRenderer(size: size, format: format).image { _ in
                UIImage(cgImage: image).draw(in: CGRect(origin: .zero, size: size))
            }
        } else {
            uiImage = UIImage(cgImage: image)
        }
        return ImageStore.shared.saveImage(uiImage, prefix: "cloth-cut", keepAlpha: true)
    }

    /// 当前画面（自动抠图这类「要一张图直接处理」的场景用）
    func currentCompositeImage() -> UIImage? {
        guard let image = renderer?.compositeImage() else { return nil }
        return UIImage(cgImage: image)
    }

    var currentImageSize: CGSize {
        renderer?.imageSize ?? .zero
    }

    /* ==================== 布局与坐标 ==================== */

    override func layoutSubviews() {
        super.layoutSubviews()
        overlay.frame = bounds
        recalcFit()
        updateImageFrame()
    }

    /// 当前「图像坐标 -> 视图坐标」的缩放倍率
    private var scaleFactor: CGFloat { fitScale * viewScale }

    private var displayRect: CGRect {
        let size = renderer?.imageSize ?? .zero
        guard size.width > 0, size.height > 0 else { return .zero }
        let k = scaleFactor
        let width = size.width * k
        let height = size.height * k
        return CGRect(
            x: bounds.midX + offset.x - width / 2,
            y: bounds.midY + offset.y - height / 2,
            width: width,
            height: height
        )
    }

    /// 图像适应画布（对应 recalcFit）
    private func recalcFit() {
        guard let full = renderer?.imageSize, full.width > 0, full.height > 0,
              bounds.width > 0, bounds.height > 0 else { return }
        // 有内容范围就按它来适应画面（衣服撑满画布），否则退回整张图
        let size = contentBox.isEmpty ? full : contentBox.size
        fitScale = min(bounds.width / size.width, bounds.height / size.height)
    }

    /// 重新量一下底图里衣服的范围（换底图 / 重置 / 裁剪之后调用）
    private func refreshContentBox() {
        guard let base = renderer?.base else {
            contentBox = .zero
            return
        }
        contentBox = ImageStore.contentRect(of: base) ?? .zero
    }

    private func updateImageFrame() {
        imageView.frame = displayRect
        if let image = renderer?.compositeImage() {
            imageView.image = UIImage(cgImage: image)
        }
        overlay.cropRect = cropViewRect
    }

    /// 重绘画面（不重新布局）
    private func refresh() {
        if let image = renderer?.compositeImage() {
            imageView.image = UIImage(cgImage: image)
        }
        overlay.cropRect = cropViewRect
        emitState()
    }

    /// 裁剪框在视图坐标里的位置（裁剪框是覆盖在画布上的普通视图，拖动时不用重绘画布）
    private var cropViewRect: CGRect? {
        guard let rect = cropImageRect else { return nil }
        let k = scaleFactor
        let origin = displayRect.origin
        return CGRect(
            x: origin.x + rect.minX * k,
            y: origin.y + rect.minY * k,
            width: rect.width * k,
            height: rect.height * k
        )
    }

    /// 视图坐标 -> 图像坐标
    private func imagePoint(_ point: CGPoint) -> CGPoint {
        let k = scaleFactor
        guard k > 0 else { return .zero }
        let rect = displayRect
        return CGPoint(x: (point.x - rect.minX) / k, y: (point.y - rect.minY) / k)
    }

    private func clampToImage(_ point: CGPoint) -> CGPoint {
        let size = renderer?.imageSize ?? .zero
        return CGPoint(
            x: min(max(0, point.x), size.width),
            y: min(max(0, point.y), size.height)
        )
    }

    private func clampOffset(_ point: CGPoint) -> CGPoint {
        guard viewScale > 1 else { return .zero }
        let limitX = bounds.width * viewScale / 2
        let limitY = bounds.height * viewScale / 2
        return CGPoint(
            x: min(max(-limitX, point.x), limitX),
            y: min(max(-limitY, point.y), limitY)
        )
    }

    /* ==================== 触摸：涂抹 / 裁剪 / 缩放 ==================== */

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        let all = Array(event?.allTouches ?? touches)
        if all.count >= 2 {
            finishStroke()
            cancelLongPress()
            // 框选到一半又搭上第二根手指：取消这次框选，别拿半个框去裁剪
            if cropStart != nil || cropImageRect != nil {
                cropStart = nil
                cropImageRect = nil
                overlay.cropRect = nil
            }
            startPinch(all)
            return
        }
        guard !pinching, !suppressDrawing, !busy, !processing, renderer != nil else { return }
        guard let touch = touches.first else { return }
        let point = imagePoint(touch.location(in: self))

        if mode == .crop {
            cropStart = clampToImage(point)
            cropImageRect = nil
            overlay.cropRect = nil
            return
        }

        stroke = [point]
        drawStrokeSegment(from: point, to: point)
        scheduleLongPress(imagePoint: point, viewPoint: touch.location(in: self))
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        let all = Array(event?.allTouches ?? touches)
        if all.count >= 2 {
            if pinchStart == nil { startPinch(all) } else { updatePinch(all) }
            return
        }
        guard !pinching, !suppressDrawing, let touch = touches.first else { return }
        let point = clampToImage(imagePoint(touch.location(in: self)))

        // 手指挪开了就不算长按，按普通涂抹处理
        if let start = pressViewPoint, !longPressFired {
            let moved = hypot(touch.location(in: self).x - start.x, touch.location(in: self).y - start.y)
            if moved > EditorCanvas.longPressTolerance { cancelLongPress() }
        }

        if mode == .crop {
            guard let start = cropStart else { return }
            cropImageRect = CGRect(
                x: min(start.x, point.x),
                y: min(start.y, point.y),
                width: abs(point.x - start.x),
                height: abs(point.y - start.y)
            )
            overlay.cropRect = cropViewRect
            return
        }

        guard let last = stroke.last else { return }
        // 抽稀：太近的点跳过，减少重绘开销
        if abs(last.x - point.x) < 0.6 && abs(last.y - point.y) < 0.6 { return }
        stroke.append(point)
        drawStrokeSegment(from: last, to: point)
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        handleTouchEnd(touches, event: event)
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        handleTouchEnd(touches, event: event)
    }

    private func handleTouchEnd(_ touches: Set<UITouch>, event: UIEvent?) {
        let remaining = (event?.allTouches ?? touches).filter {
            $0.phase != .ended && $0.phase != .cancelled
        }
        if remaining.isEmpty {
            let wasPinching = pinching
            pinching = false
            pinchStart = nil
            suppressDrawing = false
            cancelLongPress()
            if mode == .crop {
                finishCrop()
            } else if !wasPinching {
                finishStroke()
            }
            return
        }
        // 还有手指留在屏幕上（一般是双指变单指），等全部抬起再恢复绘制，避免误画
        if pinching { suppressDrawing = true }
    }

    private func drawStrokeSegment(from: CGPoint, to: CGPoint) {
        guard let renderer else { return }
        let k = scaleFactor
        guard k > 0 else { return }
        // 笔刷宽度按屏幕上看起来的粗细折算到图像坐标
        let width = max(0.5, brushSize / k)
        renderer.drawSegment(kind: mode, points: [from, to], width: width)
        reportFirstEdit()
        if let image = renderer.compositeImage() {
            imageView.image = UIImage(cgImage: image)
        }
    }

    private func finishStroke() {
        guard let renderer, !stroke.isEmpty, mode != .crop else {
            stroke = []
            return
        }
        let k = scaleFactor
        let width = max(0.5, brushSize / k)
        renderer.finishStroke(kind: mode, points: stroke, width: width)
        stroke = []
        emitState()
    }

    private func reportFirstEdit() {
        guard !firstEditReported else { return }
        firstEditReported = true
        onFirstEdit?()
    }

    /* ==================== 长按抠图（模仿系统相册的手势） ==================== */

    /// 按下后原地停住 0.5 秒 = 长按：通知页面把手指底下的那件衣物抠出来
    private func scheduleLongPress(imagePoint: CGPoint, viewPoint: CGPoint) {
        cancelLongPress()
        guard onLongPress != nil else { return }
        pressImagePoint = imagePoint
        pressViewPoint = viewPoint
        longPressFired = false
        let work = DispatchWorkItem { [weak self] in self?.fireLongPress() }
        pressWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + EditorCanvas.longPressDelay, execute: work)
    }

    private func cancelLongPress() {
        pressWork?.cancel()
        pressWork = nil
        pressImagePoint = nil
        pressViewPoint = nil
    }

    private func fireLongPress() {
        guard !longPressFired, let point = pressImagePoint else { return }
        longPressFired = true
        // 长按期间「按下就画」的那一笔要撤掉：整屏重绘一次，画面上不留痕迹
        stroke = []
        renderer?.renderAll()
        refresh()
        Haptic.medium()
        onLongPress?(cutoutPoint(fromBasePoint: point))
    }

    /// 底图坐标 -> sourceImageForCutout() 那张图上的坐标
    private func cutoutPoint(fromBasePoint point: CGPoint) -> CGPoint {
        guard let renderer else { return point }
        let base = renderer.imageSize
        let box = cutoutBox
        guard base.width > 0, base.height > 0 else { return point }
        return CGPoint(
            x: point.x * box.width / base.width,
            y: point.y * box.height / base.height
        )
    }

    /* ==================== 双指缩放 ==================== */

    private func startPinch(_ touches: [UITouch]) {
        guard touches.count >= 2 else { return }
        pinching = true
        suppressDrawing = true
        pinchStart = (distance(touches), midPoint(touches), viewScale, offset)
    }

    private func updatePinch(_ touches: [UITouch]) {
        guard let start = pinchStart, touches.count >= 2 else { return }
        let dist = distance(touches)
        let mid = midPoint(touches)
        let ratio = start.distance > 0 ? dist / start.distance : 1
        let scale = min(EditorCanvas.maxZoom, max(1, start.scale * ratio))
        // 让捏合中点下的那个图像点保持不动（否则一放大就「跑偏」）
        let rx = start.scale > 0 ? scale / start.scale : 1
        let centerX = bounds.midX
        let centerY = bounds.midY
        let x = mid.x - centerX - rx * (start.mid.x - centerX - start.offset.x)
        let y = mid.y - centerY - rx * (start.mid.y - centerY - start.offset.y)
        viewScale = scale
        offset = clampOffset(CGPoint(x: x, y: y))
        updateImageFrame()
    }

    private func distance(_ touches: [UITouch]) -> CGFloat {
        guard touches.count >= 2 else { return 0 }
        let a = touches[0].location(in: self)
        let b = touches[1].location(in: self)
        return sqrt(pow(a.x - b.x, 2) + pow(a.y - b.y, 2))
    }

    private func midPoint(_ touches: [UITouch]) -> CGPoint {
        guard touches.count >= 2 else { return .zero }
        let a = touches[0].location(in: self)
        let b = touches[1].location(in: self)
        return CGPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2)
    }

    /* ==================== 裁剪 ==================== */

    private func finishCrop() {
        guard let rect = cropImageRect else { return }
        cropStart = nil
        cropImageRect = nil
        overlay.cropRect = nil

        // 裁剪立刻生效，误触的代价比从前大，所以两个角度都拦一下：
        // 图像坐标下别太小（不然导出的是个渣），屏幕上看着也别太小（不然是手滑）
        let k = scaleFactor
        if rect.width < EditorCanvas.minCrop || rect.height < EditorCanvas.minCrop
            || rect.width * k < EditorCanvas.minCropScreen || rect.height * k < EditorCanvas.minCropScreen {
            onMessage?("框太小了，再拖大一点")
            refresh()
            return
        }

        busy = true
        let ok = renderer?.crop(rect) ?? false
        busy = false
        if ok {
            reportFirstEdit()
            viewScale = 1
            offset = .zero
            refreshContentBox()
            recalcFit()
            refresh()
            onMessage?("已裁剪，可撤销")
        } else {
            refresh()
            onMessage?("裁剪失败，请重试")
        }
    }

    /* ==================== 状态回调 ==================== */

    private func handle(_ outcome: EditorRenderer.UndoOutcome) {
        switch outcome {
        case .nothing:
            return
        case .redraw:
            refresh()
        case .rebase:
            viewScale = 1
            offset = .zero
            refreshContentBox()
            recalcFit()
            refresh()
        }
    }

    private func emitState(loading: Bool? = nil) {
        onStateChange?(
            EditorCanvasState(
                canUndo: renderer?.canUndo ?? false,
                canRedo: renderer?.canRedo ?? false,
                loading: loading ?? false
            )
        )
    }

    /* ==================== 图片解码 ==================== */

    /// 解码图片；长边超过上限时先缩小，避免超大图占内存
    private static func decodeWorkingImage(stored: String) -> CGImage? {
        guard let url = ImageStore.shared.url(for: stored) else { return nil }
        guard let image = ImageCache.downsample(url: url, maxPixelSize: Int(workingMaxSide)) else { return nil }
        return image.cgImage
    }
}

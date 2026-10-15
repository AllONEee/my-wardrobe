//
//  EditorRenderer.swift —— 抠图编辑器的画面渲染（底图 + 操作栈）
//  对应 pages/image-editor 里「在画布上画什么」的那一半逻辑。
//
//  坐标系约定：
//   - 图像坐标系：底图自身的像素坐标，原点在图像左上角（画布视图的触摸点会换算到这里）
//   - 所有笔画、裁剪框都用图像坐标记录，所以缩放 / 平移之后重绘、导出都不会错位
//
//  渲染：一张位图上下文（y 向下，与 canvas 的坐标语义一致）保存「当前画面」，
//  涂抹时增量画上去（跟手），撤销 / 重做时按操作栈整体重放。
//

import UIKit

/// 编辑模式（橡皮擦 / 画笔恢复 / 裁剪）
enum EditorMode: String, CaseIterable {
    case erase
    case brush
    case crop

    var title: String {
        switch self {
        case .erase: return "橡皮擦"
        case .brush: return "画笔恢复"
        case .crop: return "裁剪"
        }
    }

    var hint: String {
        switch self {
        case .erase: return "手指涂抹擦掉背景，双指捏合可放大细修"
        case .brush: return "涂回擦掉/抠掉的部分（取自原图），双指捏合可放大细修"
        case .crop: return "拖动框选要保留的区域，松手立刻裁剪（不满意点撤销）"
        }
    }
}

final class EditorRenderer {
    /// 一次状态快照（裁剪会换底图，撤销需要整体回滚）
    struct Snapshot {
        var stored: String
        var base: CGImage
        var source: CGImage
        var sourceBox: CGRect
        var ops: [EditorOp]
    }

    enum EditorOp {
        case erase(points: [CGPoint], width: CGFloat)
        case brush(points: [CGPoint], width: CGFloat)
        case crop(rect: CGRect, prev: Snapshot)
        /// 换底图（系统抠图 / 长按抠图）：前后两张底图 + 各自的取景范围，撤销重做都能还原
        case cutout(prevStored: String, prevImage: CGImage, prevBox: CGRect, nextStored: String, nextBase: CGImage, nextBox: CGRect)
    }

    /// 撤销 / 重做的结果：要不要重新布局（换了底图就要）
    enum UndoOutcome {
        case nothing
        case redraw
        case rebase
    }

    private(set) var stored: String
    private(set) var base: CGImage
    private(set) var source: CGImage
    private(set) var sourceBox: CGRect
    private(set) var ops: [EditorOp] = []
    private(set) var redoStack: [EditorOp] = []

    private var context: CGContext

    var imageWidth: CGFloat { CGFloat(base.width) }
    var imageHeight: CGFloat { CGFloat(base.height) }
    var imageSize: CGSize { CGSize(width: imageWidth, height: imageHeight) }
    var canUndo: Bool { !ops.isEmpty }
    var canRedo: Bool { !redoStack.isEmpty }

    init(stored: String, base: CGImage, source: CGImage, sourceBox: CGRect) {
        self.stored = stored
        self.base = base
        self.source = source
        self.sourceBox = sourceBox
        self.context = EditorRenderer.makeContext(width: base.width, height: base.height)
        renderAll()
    }

    /* ==================== 上下文与绘制基元 ==================== */

    /// 建一个 y 向下的位图上下文（和 canvas 的坐标语义一致）
    static func makeContext(width: Int, height: Int) -> CGContext {
        let context = CGContext(
            data: nil,
            width: max(1, width),
            height: max(1, height),
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )
        guard let context else {
            // 兜底：极端情况下给一张 1×1 的上下文，别让调用方崩溃
            return CGContext(
                data: nil,
                width: 1,
                height: 1,
                bitsPerComponent: 8,
                bytesPerRow: 0,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            )!
        }
        context.translateBy(x: 0, y: CGFloat(max(1, height)))
        context.scaleBy(x: 1, y: -1)
        return context
    }

    /// 在 y 向下的上下文里把一张图正着画到 rect（内部再翻一次，图片不会上下颠倒）
    private func drawUpright(_ image: CGImage, in rect: CGRect, context ctx: CGContext) {
        ctx.saveGState()
        ctx.translateBy(x: rect.minX, y: rect.minY + rect.height)
        ctx.scaleBy(x: 1, y: -1)
        ctx.draw(image, in: CGRect(origin: .zero, size: rect.size))
        ctx.restoreGState()
    }

    /// 描边路径（用来做「画笔恢复」的裁剪区域）
    private func strokeOutline(_ points: [CGPoint], width: CGFloat) -> CGPath {
        if points.count == 1 {
            let radius = max(0.5, width / 2)
            return CGPath(
                ellipseIn: CGRect(
                    x: points[0].x - radius,
                    y: points[0].y - radius,
                    width: radius * 2,
                    height: radius * 2
                ),
                transform: nil
            )
        }
        let path = CGMutablePath()
        path.move(to: points[0])
        for point in points.dropFirst() {
            path.addLine(to: point)
        }
        return path.copy(strokingWithWidth: width, lineCap: .round, lineJoin: .round, miterLimit: 10)
    }

    /// 橡皮擦：直接擦掉像素
    private func paintErase(_ points: [CGPoint], width: CGFloat, context ctx: CGContext) {
        guard !points.isEmpty else { return }
        ctx.saveGState()
        ctx.setBlendMode(.clear)
        ctx.setLineCap(.round)
        ctx.setLineJoin(.round)
        ctx.setLineWidth(width)
        ctx.setStrokeColor(UIColor.black.cgColor)
        ctx.setFillColor(UIColor.black.cgColor)
        if points.count == 1 {
            let radius = max(0.5, width / 2)
            ctx.fillEllipse(in: CGRect(
                x: points[0].x - radius,
                y: points[0].y - radius,
                width: radius * 2,
                height: radius * 2
            ))
        } else {
            ctx.beginPath()
            ctx.move(to: points[0])
            for point in points.dropFirst() { ctx.addLine(to: point) }
            ctx.strokePath()
        }
        ctx.restoreGState()
    }

    /// 画笔恢复：把最初的原图在被涂到的区域画回来
    /// （取的是 _source 而不是当前底图：抠图之后底图已经透明，拿它当来源就「刷不回」被抠掉的部分）
    private func paintBrush(_ points: [CGPoint], width: CGFloat, context ctx: CGContext) {
        guard !points.isEmpty else { return }
        ctx.saveGState()
        ctx.setBlendMode(.normal)
        ctx.addPath(strokeOutline(points, width: width))
        ctx.clip()
        if let cropped = source.cropping(to: sourceBox) {
            drawUpright(cropped, in: CGRect(x: 0, y: 0, width: imageWidth, height: imageHeight), context: ctx)
        }
        ctx.restoreGState()
    }

    private func paint(_ op: EditorOp, context ctx: CGContext) {
        switch op {
        case .erase(let points, let width):
            paintErase(points, width: width, context: ctx)
        case .brush(let points, let width):
            paintBrush(points, width: width, context: ctx)
        case .crop, .cutout:
            // 换底图的操作：底图已经换过，重放时不需要额外绘制
            break
        }
    }

    /* ==================== 涂抹 ==================== */

    /// 涂抹过程中的实时绘制（不压栈，保证跟手）
    func drawSegment(kind: EditorMode, points: [CGPoint], width: CGFloat) {
        switch kind {
        case .erase: paintErase(points, width: width, context: context)
        case .brush: paintBrush(points, width: width, context: context)
        case .crop: break
        }
    }

    /// 一笔画完：只压栈，画面已经在上面增量画过了
    func finishStroke(kind: EditorMode, points: [CGPoint], width: CGFloat) {
        guard !points.isEmpty else { return }
        redoStack = [] // 记录新操作后，原来的重做链就失效了
        switch kind {
        case .erase: ops.append(.erase(points: points, width: width))
        case .brush: ops.append(.brush(points: points, width: width))
        case .crop: break
        }
    }

    /// 整屏重放（撤销、重做、重置、换底图后调用）
    func renderAll() {
        // 坐标系一直是「y 向下」，清屏也在这个坐标系里做（这块矩形正好覆盖整张位图）
        context.saveGState()
        context.setBlendMode(.normal)
        context.setAlpha(1)
        context.clear(CGRect(x: 0, y: 0, width: imageWidth, height: imageHeight))
        context.restoreGState()

        drawUpright(base, in: CGRect(x: 0, y: 0, width: imageWidth, height: imageHeight), context: context)
        ops.forEach { paint($0, context: context) }
    }

    func compositeImage() -> CGImage? {
        context.makeImage()
    }

    /* ==================== 裁剪 / 抠图 / 撤销重做 ==================== */

    /// 裁剪即刻生效：把框内的画面（含已擦 / 已补的部分）烘成一张新底图
    @discardableResult
    func crop(_ rect: CGRect) -> Bool {
        let clipped = rect.intersection(CGRect(x: 0, y: 0, width: imageWidth, height: imageHeight))
        guard !clipped.isNull, clipped.width >= 1, clipped.height >= 1 else { return false }

        let prev = Snapshot(stored: stored, base: base, source: source, sourceBox: sourceBox, ops: ops)
        guard let next = renderRegion(clipped) else { return false }
        // 取景范围必须在换底图之前算：cropSourceBox 依赖当前底图的尺寸
        let nextBox = cropSourceBox(clipped)

        // 画面已经烘进底图：笔画栈清空，只留这次裁剪操作本身，撤销时整体回滚
        base = next
        stored = ""
        sourceBox = nextBox
        ops = [.crop(rect: clipped, prev: prev)]
        redoStack = []
        context = EditorRenderer.makeContext(width: next.width, height: next.height)
        renderAll()
        return true
    }

    /// 把图像坐标系里的某块区域渲染成一张 CGImage
    func renderRegion(_ rect: CGRect) -> CGImage? {
        let width = max(1, Int(rect.width.rounded()))
        let height = max(1, Int(rect.height.rounded()))
        let target = EditorRenderer.makeContext(width: width, height: height)
        drawUpright(base, in: CGRect(x: -rect.minX, y: -rect.minY, width: imageWidth, height: imageHeight), context: target)
        ops.forEach { paint($0, context: target) }
        return target.makeImage()
    }

    /// 裁剪后新的取景范围（按当前底图与原图的比例等比换算）
    func cropSourceBox(_ rect: CGRect) -> CGRect {
        let scaleX = imageWidth > 0 ? sourceBox.width / imageWidth : 1
        let scaleY = imageHeight > 0 ? sourceBox.height / imageHeight : 1
        return CGRect(
            x: sourceBox.minX + rect.minX * scaleX,
            y: sourceBox.minY + rect.minY * scaleY,
            width: max(1, rect.width * scaleX),
            height: max(1, rect.height * scaleY)
        )
    }

    /// 换底图（系统抠图 / 长按抠图）：可以撤销回上一张底图
    /// - Parameter sourceBox: 新底图对应原图里的哪块区域（同尺寸换底图时就是原来那块，保持不变）
    @discardableResult
    func replaceBase(stored newStored: String, base newBase: CGImage, sourceBox newBox: CGRect) -> Bool {
        let op = EditorOp.cutout(
            prevStored: stored,
            prevImage: base,
            prevBox: sourceBox,
            nextStored: newStored,
            nextBase: newBase,
            nextBox: newBox
        )
        stored = newStored
        base = newBase
        sourceBox = newBox
        // 换底图后旧底图上的涂抹不再适用（撤销回上一张底图时也是从头开始），操作栈从这张底图重新算
        ops = [op]
        redoStack = []
        context = EditorRenderer.makeContext(width: newBase.width, height: newBase.height)
        renderAll()
        return true
    }

    /// 回到最初的原图（重置）
    func resetToSource(stored newStored: String, image: CGImage) {
        stored = newStored
        base = image
        source = image
        sourceBox = CGRect(x: 0, y: 0, width: CGFloat(image.width), height: CGFloat(image.height))
        ops = []
        redoStack = []
        context = EditorRenderer.makeContext(width: image.width, height: image.height)
        renderAll()
    }

    func undo() -> UndoOutcome {
        guard let op = ops.popLast() else { return .nothing }
        redoStack.append(op)

        switch op {
        case .erase, .brush:
            renderAll()
            return .redraw
        case .crop(let rect, let prev):
            redoStack[redoStack.count - 1] = .crop(rect: rect, prev: prev)
            apply(prev)
            return .rebase
        case .cutout(let prevStored, let prevImage, let prevBox, let nextStored, let nextBase, let nextBox):
            stored = prevStored
            base = prevImage
            sourceBox = prevBox
            context = EditorRenderer.makeContext(width: prevImage.width, height: prevImage.height)
            redoStack[redoStack.count - 1] = .cutout(
                prevStored: prevStored,
                prevImage: prevImage,
                prevBox: prevBox,
                nextStored: nextStored,
                nextBase: nextBase,
                nextBox: nextBox
            )
            renderAll()
            return .rebase
        }
    }

    func redo() -> UndoOutcome {
        guard let op = redoStack.popLast() else { return .nothing }
        switch op {
        case .erase, .brush:
            ops.append(op)
            renderAll()
            return .redraw
        case .crop(let rect, let prev):
            if let next = renderRegion(rect) {
                let nextBox = cropSourceBox(rect)
                base = next
                stored = ""
                sourceBox = nextBox
                context = EditorRenderer.makeContext(width: next.width, height: next.height)
                ops = [.crop(rect: rect, prev: prev)]
                renderAll()
            } else {
                apply(prev)
            }
            return .rebase
        case .cutout(let prevStored, let prevImage, let prevBox, let nextStored, let nextBase, let nextBox):
            // 抠图结果本来就留在内存里，这里直接用它，不再依赖磁盘上的文件
            stored = nextStored
            base = nextBase
            sourceBox = nextBox
            context = EditorRenderer.makeContext(width: nextBase.width, height: nextBase.height)
            ops.append(.cutout(
                prevStored: prevStored,
                prevImage: prevImage,
                prevBox: prevBox,
                nextStored: nextStored,
                nextBase: nextBase,
                nextBox: nextBox
            ))
            renderAll()
            return .rebase
        }
    }

    private func apply(_ snapshot: Snapshot) {
        stored = snapshot.stored
        base = snapshot.base
        source = snapshot.source
        sourceBox = snapshot.sourceBox
        ops = snapshot.ops
        context = EditorRenderer.makeContext(width: snapshot.base.width, height: snapshot.base.height)
        renderAll()
    }
}

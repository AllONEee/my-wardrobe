//
//  CutoutService.swift —— 抠图（替代小程序的 utils/cutout.js）
//
//  小程序版本调的是「云端 AI 抠图接口」（要自己搭服务、配合法域名）。iOS 版不再依赖任何接口：
//  直接调系统自带的视觉框架 Vision，用 VNGenerateForegroundInstanceMaskRequest 把画面里的
//  主体（衣服）抠出来，得到带透明通道的前景图。
//
//  对外接口与小程序保持一致（cutout(path) -> { path, 是否走了系统能力, reason, message }）：
//   - 抠不出来时不抛错、也不阻塞流程，而是把原图返回并带上原因，页面据此提示用户手动画笔处理，
//     这样「没配接口 / 系统不支持 / 图不好抠」三种情况页面的处理逻辑完全一样。
//   - 系统要求：iOS 17 及以上（本项目的最低版本就是 17）。
//

import CoreImage
import Foundation
import UIKit
import Vision

/// 抠图结果（对应 utils/cutout.js 里 cutout() 的返回值）
struct CutoutResult {
    /// 抠好的前景图文件名；走了兜底逻辑时就是原图
    var path: String
    /// true = 用系统视觉框架抠成功
    var onDevice: Bool
    /// 兜底原因：unsupported / missing-image / no-subject / failed
    var reason: String
    /// 给用户看的一句话
    var message: String
}

/// 「长按抠图」的结果：只抠出长按位置下的那一个主体（模仿系统相册的长按抠图）
struct InstanceCutoutResult {
    /// 抠好的前景图文件名；失败时为空串
    var path: String
    /// true = 成功抠出了被长按的那个主体
    var ok: Bool
    /// 这张图里一共识别到几个主体（0 表示没识别出主体）
    var instanceCount: Int
    /// 给用户看的一句话（ok 为 false 时用）
    var message: String
}

/// 无状态的单例，抠图在后台线程跑，这里显式声明可以跨线程使用
final class CutoutService: @unchecked Sendable {
    static let shared = CutoutService()

    private init() {}

    /// 当前设备 / 系统是否支持系统抠图
    var isSupported: Bool {
        if #available(iOS 17.0, *) { return true }
        return false
    }

    /// 抠图。不做主线程阻塞，重活在后台线程跑完再回调。
    /// - Parameter stored: 数据里记的图片文件名（见 ImageStore）
    func cutout(_ stored: String, prefix: String = "cut") async -> CutoutResult {
        guard !stored.isEmpty,
              let url = ImageStore.shared.url(for: stored),
              let image = UIImage(contentsOfFile: url.path) else {
            return CutoutResult(path: stored, onDevice: false, reason: "missing-image", message: "没有可处理的图片")
        }
        return await cutout(image: image, prefix: prefix, fallback: stored)
    }

    /// 直接对一张图抠（图片编辑器里的「自动抠图」用，不依赖落盘的文件）
    func cutout(image: UIImage, prefix: String = "cut", fallback: String = "") async -> CutoutResult {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let result = self.performCutout(image: image, fallback: fallback, prefix: prefix)
                continuation.resume(returning: result)
            }
        }
    }

    /// 只抠出「point 处的那一个主体」：系统相册里长按衣服只提起衣服，就是用的这套实例遮罩。
    /// - Parameters:
    ///   - image: 要处理的图（一般是没抠过的原图，实例区分得最清楚）
    ///   - point: 长按位置，图像像素坐标（左上角为原点，和 UIImage 一致）
    func cutoutInstance(image: UIImage, at point: CGPoint, prefix: String = "cloth-cut") async -> InstanceCutoutResult {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let result = self.performInstanceCutout(image: image, point: point, prefix: prefix)
                continuation.resume(returning: result)
            }
        }
    }

    /* ==================== 实现 ==================== */

    private func performCutout(image: UIImage, fallback: String, prefix: String) -> CutoutResult {
        guard #available(iOS 17.0, *) else {
            return CutoutResult(
                path: fallback,
                onDevice: false,
                reason: "unsupported",
                message: "这台设备不支持系统抠图（需要 iOS 17 及以上），可以先用橡皮擦手动擦掉背景"
            )
        }
        guard let cgImage = image.cgImage else {
            return CutoutResult(path: fallback, onDevice: false, reason: "missing-image", message: "没有可处理的图片")
        }

        let handler = VNImageRequestHandler(
            cgImage: cgImage,
            orientation: CGImagePropertyOrientation(image.imageOrientation),
            options: [:]
        )
        let request = VNGenerateForegroundInstanceMaskRequest()

        do {
            try handler.perform([request])
        } catch {
            let message = error.localizedDescription
            // 模拟器（以及个别设备）没有推理后端，系统会报 inference context 相关的错误
            if message.lowercased().contains("inference") {
                return CutoutResult(
                    path: fallback,
                    onDevice: false,
                    reason: "unsupported",
                    message: "这台设备（或模拟器）不支持系统抠图，自动抠图需要真机 iOS 17 及以上。可以先用橡皮擦擦掉背景，画笔把抠多的部分涂回来"
                )
            }
            return CutoutResult(
                path: fallback,
                onDevice: false,
                reason: "failed",
                message: "系统抠图没能处理这张图片：\(message)"
            )
        }

        guard let observation = request.results?.first, !observation.allInstances.isEmpty else {
            return CutoutResult(
                path: fallback,
                onDevice: false,
                reason: "no-subject",
                message: "没找到可以抠出来的主体，换一张主体更清楚的图，或者用橡皮擦手动处理"
            )
        }

        do {
            let maskBuffer = try observation.generateMaskedImage(
                ofInstances: observation.allInstances,
                from: handler,
                croppedToInstancesExtent: false
            )
            let ciImage = CIImage(cvPixelBuffer: maskBuffer)
            let context = CIContext(options: [.useSoftwareRenderer: false])
            guard let outCGImage = context.createCGImage(ciImage, from: ciImage.extent) else {
                throw CutoutError.renderFailed
            }
            let outImage = UIImage(cgImage: outCGImage)
            guard let name = ImageStore.shared.saveImage(outImage, prefix: prefix, keepAlpha: true) else {
                throw CutoutError.saveFailed
            }
            return CutoutResult(path: name, onDevice: true, reason: "", message: "")
        } catch {
            return CutoutResult(
                path: fallback,
                onDevice: false,
                reason: "failed",
                message: "抠图结果保存失败：\(error.localizedDescription)"
            )
        }
    }

    private enum CutoutError: LocalizedError {
        case renderFailed
        case saveFailed

        var errorDescription: String? {
            switch self {
            case .renderFailed: return "生成前景图失败"
            case .saveFailed: return "写入本地文件失败"
            }
        }
    }

    /* ==================== 长按抠单个主体 ==================== */

    private func performInstanceCutout(image: UIImage, point: CGPoint, prefix: String) -> InstanceCutoutResult {
        func fail(_ message: String, count: Int = 0) -> InstanceCutoutResult {
            InstanceCutoutResult(path: "", ok: false, instanceCount: count, message: message)
        }

        guard #available(iOS 17.0, *) else {
            return fail("这台设备不支持系统抠图（需要 iOS 17 及以上），可以用橡皮擦手动擦掉背景")
        }
        guard let cgImage = image.cgImage else {
            return fail("没有可处理的图片")
        }

        let handler = VNImageRequestHandler(
            cgImage: cgImage,
            orientation: CGImagePropertyOrientation(image.imageOrientation),
            options: [:]
        )
        let request = VNGenerateForegroundInstanceMaskRequest()
        do {
            try handler.perform([request])
        } catch {
            let message = error.localizedDescription
            if message.lowercased().contains("inference") {
                return fail("这台设备（或模拟器）不支持系统抠图，长按抠图需要真机 iOS 17 及以上")
            }
            return fail("系统抠图没能处理这张图片：\(message)")
        }

        guard let observation = request.results?.first, !observation.allInstances.isEmpty else {
            return fail("没找到可以抠出来的主体，换一张主体更清楚的图，或者用橡皮擦手动处理")
        }

        let count = observation.allInstances.count
        let pixelX = Int(point.x.rounded())
        let pixelY = Int(point.y.rounded())
        guard pixelX >= 0, pixelY >= 0, pixelX < cgImage.width, pixelY < cgImage.height else {
            return fail("长按的位置跑到图片外面去了", count: count)
        }

        // 逐个实例生成遮罩：命中的实例里挑「面积最小」的那个，也就是手指底下最具体的那件衣物
        // （对着人身上的衬衫长按，应该只提起衬衫，而不是整个人）
        var best: (image: CGImage, area: Int)?
        for index in observation.allInstances {
            guard let buffer = try? observation.generateMaskedImage(
                ofInstances: [index],
                from: handler,
                croppedToInstancesExtent: false
            ), let masked = render(buffer) else { continue }

            guard let alpha = Self.alphaBuffer(masked) else { continue }
            guard alpha.alpha(atX: pixelX, y: pixelY, imageWidth: cgImage.width, imageHeight: cgImage.height) > 40 else {
                continue
            }
            if best == nil || alpha.opaqueCount < best!.area {
                best = (masked, alpha.opaqueCount)
            }
        }

        guard let picked = best else {
            return fail("长按的地方没有识别到衣物主体，对着衣物本身再长按一次试试", count: count)
        }
        guard let name = ImageStore.shared.saveImage(UIImage(cgImage: picked.image), prefix: prefix, keepAlpha: true) else {
            return fail("抠图结果保存失败，请重试", count: count)
        }
        return InstanceCutoutResult(path: name, ok: true, instanceCount: count, message: "")
    }

    /// CVPixelBuffer -> CGImage
    private func render(_ buffer: CVPixelBuffer) -> CGImage? {
        let ciImage = CIImage(cvPixelBuffer: buffer)
        let context = CIContext(options: [.useSoftwareRenderer: false])
        return context.createCGImage(ciImage, from: ciImage.extent)
    }

    /* ==================== 命中测试用的 alpha 小图 ==================== */

    /// 把遮罩图缩到小尺寸后取出每个像素的 alpha：
    /// 一边用来判断「长按的位置有没有落在这个实例上」，一边用来比较实例大小。
    private struct AlphaBuffer {
        let values: [UInt8]
        let width: Int
        let height: Int

        /// 原图坐标 -> 小图坐标后取 alpha
        func alpha(atX x: Int, y: Int, imageWidth: Int, imageHeight: Int) -> UInt8 {
            guard width > 0, height > 0, imageWidth > 0, imageHeight > 0 else { return 0 }
            let sx = min(width - 1, max(0, x * width / imageWidth))
            let sy = min(height - 1, max(0, y * height / imageHeight))
            return values[sy * width + sx]
        }

        /// 不透明的像素个数（缩略图上的计数，只用来比大小）
        var opaqueCount: Int {
            values.reduce(into: 0) { $0 += $1 > 40 ? 1 : 0 }
        }
    }

    private static func alphaBuffer(_ image: CGImage, maxSide: Int = 512) -> AlphaBuffer? {
        let scale = min(1, CGFloat(maxSide) / CGFloat(max(image.width, image.height)))
        let width = max(1, Int((CGFloat(image.width) * scale).rounded()))
        let height = max(1, Int((CGFloat(image.height) * scale).rounded()))
        let bytesPerRow = width * 4

        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: bytesPerRow,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }

        context.interpolationQuality = .low
        // 注意：这里不能再翻转坐标。CGBitmapContext 的缓冲区第 0 行本来就对应图片最上面一行，
        // 多翻一次会让命中测试上下颠倒（长按上半部分却命中了下半部分的主体）。
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))

        guard let raw = context.data else { return nil }
        let pixels = raw.bindMemory(to: UInt8.self, capacity: width * height * 4)
        var values = [UInt8](repeating: 0, count: width * height)
        for index in 0..<(width * height) {
            values[index] = pixels[index * 4 + 3]
        }
        return AlphaBuffer(values: values, width: width, height: height)
    }
}

extension CGImagePropertyOrientation {
    /// UIImage 的朝向 -> Vision 需要的朝向
    init(_ orientation: UIImage.Orientation) {
        switch orientation {
        case .up: self = .up
        case .down: self = .down
        case .left: self = .left
        case .right: self = .right
        case .upMirrored: self = .upMirrored
        case .downMirrored: self = .downMirrored
        case .leftMirrored: self = .leftMirrored
        case .rightMirrored: self = .rightMirrored
        @unknown default: self = .up
        }
    }
}

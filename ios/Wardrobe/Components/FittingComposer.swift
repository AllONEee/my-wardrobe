//
//  FittingComposer.swift —— 把画布合成一张搭配封面（对应 fitting.js 的 composeCover）
//
//  与画布区同宽高比，透明背景，衣物按 z 顺序、各自的缩放旋转画上去，
//  导出长边不超过 1600（和小程序的 EXPORT_RATIO / EXPORT_MAX_SIDE 一致）。
//

import UIKit

enum FittingComposer {
    static let exportRatio: CGFloat = 3
    static let exportMaxSide: CGFloat = 1600

    /// - Returns: 合成好的图片（透明背景的 PNG 素材），失败返回 nil
    static func compose(layers: [FittingLayer], stageSize: CGSize) -> UIImage? {
        guard !layers.isEmpty, stageSize.width > 0, stageSize.height > 0 else { return nil }
        let ratio = min(exportRatio, exportMaxSide / max(stageSize.width, stageSize.height))
        let size = CGSize(
            width: max(1, (stageSize.width * ratio).rounded()),
            height: max(1, (stageSize.height * ratio).rounded())
        )
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        format.opaque = false

        let image = UIGraphicsImageRenderer(size: size, format: format).image { renderer in
            let context = renderer.cgContext
            for layer in layers.sorted(by: { $0.z < $1.z }) {
                // 和画布上一致：只画有内容的那块（layer.w/h 也是按这块量的）
                guard let source = ImageStore.shared.contentImage(for: layer.image, maxPixelSize: 1200) else { continue }
                context.saveGState()
                context.translateBy(x: layer.center.x * ratio, y: layer.center.y * ratio)
                context.rotate(by: layer.rotation * .pi / 180)
                context.scaleBy(x: layer.scale, y: layer.scale)
                let rect = CGRect(
                    x: -layer.w * ratio / 2,
                    y: -layer.h * ratio / 2,
                    width: layer.w * ratio,
                    height: layer.h * ratio
                )
                source.draw(in: rect)
                context.restoreGState()
            }
        }
        return image
    }
}

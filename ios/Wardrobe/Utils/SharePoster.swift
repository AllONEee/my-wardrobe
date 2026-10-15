//
//  SharePoster.swift —— 生成可分享的卡片图 + 存到相册
//
//  用 UIGraphicsImageRenderer 画一张干净的长图（4:5，朋友圈 / 小红书都合适）：
//  衣物图 + 名字 + 关键数据（价格 / 次数 / 单次成本）。
//  分享图固定用浅色配色，不跟着 App 的深色模式走 —— 发出去的图要好看，不是要跟系统一致。
//

import Photos
import UIKit

enum SharePoster {
    /// 4:5 的长图，1080 宽
    static let size = CGSize(width: 1080, height: 1350)

    /* ==================== 配色（固定浅色） ==================== */

    private static let bg = UIColor(hex: 0xF7F5F3)
    private static let card = UIColor(hex: 0xFFFFFF)
    private static let primary = UIColor(hex: 0xE0745E)
    private static let text = UIColor(hex: 0x2E2A28)
    private static let textSub = UIColor(hex: 0x8C8480)
    private static let textLight = UIColor(hex: 0xB3ABA6)

    /* ==================== 单品 ==================== */

    static func clothing(_ item: ClothingItem) -> UIImage? {
        guard let image = mainImage(for: item) else { return nil }
        return render { context in
            drawBrand()

            // 图片区
            let wellRect = CGRect(x: 90, y: 150, width: size.width - 180, height: 700)
            roundedPath(wellRect, radius: 28).addClip()
            card.setFill()
            context.fill(wellRect)
            draw(image: image, in: wellRect.insetBy(dx: 30, dy: 30))
            UIGraphicsGetCurrentContext()?.resetClip()

            // 名字
            draw(
                item.name,
                at: CGPoint(x: 90, y: 900),
                font: .systemFont(ofSize: 54, weight: .semibold),
                color: text,
                maxWidth: size.width - 380
            )

            // 分类 · 尺码 · 季节
            var meta: [String] = [item.category]
            if !item.size.isEmpty { meta.append(item.size) }
            if !item.seasons.isEmpty { meta.append(item.seasons.joined(separator: "/")) }
            draw(
                meta.joined(separator: " · "),
                at: CGPoint(x: 90, y: 975),
                font: .systemFont(ofSize: 32),
                color: textSub
            )

            if !item.tags.isEmpty {
                draw(
                    item.tags.map { "#\($0)" }.joined(separator: "  "),
                    at: CGPoint(x: 90, y: 1025),
                    font: .systemFont(ofSize: 28),
                    color: textLight,
                    maxWidth: size.width - 180
                )
            }

            // 单次成本（右上角，主角）
            if let cost = item.costPerWear {
                let text = Money.costPerWear(cost)
                let font = UIFont.systemFont(ofSize: 52, weight: .semibold)
                let width = (text as NSString).size(withAttributes: [.font: font]).width
                draw(text, at: CGPoint(x: size.width - 90 - width, y: 92), font: font, color: primary)
            }

            // 底部三格
            drawStats(
                values: [
                    (Money.text(item.price), "价格"),
                    ("\(item.wearCount)", "穿着次数"),
                    (item.costPerWear.map { Money.text($0) } ?? "—", "单次成本"),
                ],
                top: 1120
            )
        }
    }

    /* ==================== 穿搭 ==================== */

    static func outfit(_ outfit: Outfit, items: [ClothingItem], cover: UIImage?) -> UIImage? {
        return render { context in
            drawBrand()

            let wellRect = CGRect(x: 90, y: 150, width: size.width - 180, height: 760)
            roundedPath(wellRect, radius: 28).addClip()
            card.setFill()
            context.fill(wellRect)
            if let cover {
                draw(image: cover, in: wellRect.insetBy(dx: 20, dy: 20))
            }
            UIGraphicsGetCurrentContext()?.resetClip()

            draw(
                DateUtil.friendlyDate(outfit.date) + " 的穿搭",
                at: CGPoint(x: 90, y: 950),
                font: .systemFont(ofSize: 50, weight: .semibold),
                color: text
            )

            let names = items.map { $0.name }.joined(separator: " · ")
            if !names.isEmpty {
                draw(
                    names,
                    at: CGPoint(x: 90, y: 1025),
                    font: .systemFont(ofSize: 30),
                    color: textSub,
                    maxWidth: size.width - 180
                )
            }

            if !outfit.note.isEmpty {
                draw(
                    outfit.note,
                    at: CGPoint(x: 90, y: 1080),
                    font: .systemFont(ofSize: 28),
                    color: textLight,
                    maxWidth: size.width - 180
                )
            }

            drawStats(
                values: [
                    ("\(items.count)", "件衣物"),
                    (Money.text(items.reduce(0) { $0 + $1.price }), "总价"),
                    (outfit.seasons.isEmpty ? "四季" : outfit.seasons.joined(separator: "/"), "季节"),
                ],
                top: 1170
            )
        }
    }

    /* ==================== 画 ==================== */

    private static func render(_ body: (CGContext) -> Void) -> UIImage? {
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        format.opaque = true
        return UIGraphicsImageRenderer(size: size, format: format).image { renderer in
            bg.setFill()
            renderer.fill(CGRect(origin: .zero, size: size))
            body(renderer.cgContext)
        }
    }

    private static func drawBrand() {
        draw("点点衣橱", at: CGPoint(x: 90, y: 92),
             font: .systemFont(ofSize: 34, weight: .medium), color: text)
        draw("每一件都物尽其用", at: CGPoint(x: 90, y: 136),
             font: .systemFont(ofSize: 24), color: textLight)
    }

    private static func drawStats(values: [(String, String)], top: CGFloat) {
        let width = (size.width - 180) / CGFloat(values.count)
        let rect = CGRect(x: 90, y: top, width: size.width - 180, height: 150)
        roundedPath(rect, radius: 24).addClip()
        card.setFill()
        UIGraphicsGetCurrentContext()?.fill(rect)
        UIGraphicsGetCurrentContext()?.resetClip()

        for (index, value) in values.enumerated() {
            let centerX = rect.minX + width * (CGFloat(index) + 0.5)
            let number = value.0 as NSString
            let numberFont = UIFont.systemFont(ofSize: 44, weight: .semibold)
            let numberWidth = number.size(withAttributes: [.font: numberFont]).width
            draw(value.0, at: CGPoint(x: centerX - numberWidth / 2, y: rect.minY + 36),
                 font: numberFont, color: index == values.count - 1 ? primary : text)

            let label = value.1 as NSString
            let labelFont = UIFont.systemFont(ofSize: 26)
            let labelWidth = label.size(withAttributes: [.font: labelFont]).width
            draw(value.1, at: CGPoint(x: centerX - labelWidth / 2, y: rect.minY + 96),
                 font: labelFont, color: textSub)
        }
    }

    private static func draw(
        _ text: String,
        at point: CGPoint,
        font: UIFont,
        color: UIColor,
        maxWidth: CGFloat = .greatestFiniteMagnitude
    ) {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byTruncatingTail
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: color,
            .paragraphStyle: paragraph,
        ]
        (text as NSString).draw(
            in: CGRect(x: point.x, y: point.y, width: maxWidth, height: font.lineHeight * 1.4),
            withAttributes: attributes
        )
    }

    /// 图片按等比缩放画进指定矩形（居中）
    private static func draw(image: UIImage, in rect: CGRect) {
        let imageSize = image.size
        guard imageSize.width > 0, imageSize.height > 0 else { return }
        let scale = min(rect.width / imageSize.width, rect.height / imageSize.height)
        let drawSize = CGSize(width: imageSize.width * scale, height: imageSize.height * scale)
        let target = CGRect(
            x: rect.midX - drawSize.width / 2,
            y: rect.midY - drawSize.height / 2,
            width: drawSize.width,
            height: drawSize.height
        )
        image.draw(in: target)
    }

    private static func roundedPath(_ rect: CGRect, radius: CGFloat) -> UIBezierPath {
        UIBezierPath(roundedRect: rect, cornerRadius: radius)
    }

    private static func mainImage(for item: ClothingItem) -> UIImage? {
        let path = item.coverImage.isEmpty ? item.originalImage : item.coverImage
        guard !path.isEmpty else { return nil }
        return ImageStore.shared.image(for: path, maxPixelSize: 1400)
    }
}

/* ==================== 保存到相册 ==================== */

enum PhotoSaver {
    /// 存相册并给一句提示（对应小程序保存到相册那条路径）
    static func save(_ image: UIImage) {
        PHPhotoLibrary.requestAuthorization(for: .addOnly) { status in
            guard status == .authorized || status == .limited else {
                DispatchQueue.main.async {
                    ToastCenter.shared.show("没有相册权限，去「设置 → 隐私 → 照片」里打开")
                }
                return
            }
            PHPhotoLibrary.shared().performChanges {
                PHAssetChangeRequest.creationRequestForAsset(from: image)
            } completionHandler: { success, _ in
                DispatchQueue.main.async {
                    ToastCenter.shared.show(success ? "已保存到相册" : "保存失败，请重试")
                }
            }
        }
    }
}

//
//  CropOverlayView.swift —— 裁剪框（框外压暗 + 白色细边 + 四角）
//  对应 image-editor.wxss 里的 .cropbox：用普通视图画，拖动时不需要重绘画布。
//

import UIKit

final class CropOverlayView: UIView {
    var cropRect: CGRect? {
        didSet { setNeedsDisplay() }
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        commonInit()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        commonInit()
    }

    private func commonInit() {
        isOpaque = false
        backgroundColor = .clear
        isUserInteractionEnabled = false
        contentMode = .redraw
    }

    override func draw(_ rect: CGRect) {
        guard let cropRect, cropRect.width > 1, cropRect.height > 1,
              let context = UIGraphicsGetCurrentContext() else { return }

        // 框外压暗（even-odd 填充，等效于小程序的超大 box-shadow）
        let mask = CGMutablePath()
        mask.addRect(bounds)
        mask.addRect(cropRect)
        context.saveGState()
        context.addPath(mask)
        context.setFillColor(UIColor.black.withAlphaComponent(0.45).cgColor)
        context.drawPath(using: .eoFill)
        context.restoreGState()

        // 白色细边
        context.setStrokeColor(UIColor.white.cgColor)
        context.setLineWidth(1)
        context.stroke(cropRect)

        // 四个橙色角
        let corner: CGFloat = 15
        context.setStrokeColor(UIColor(red: 224 / 255, green: 116 / 255, blue: 94 / 255, alpha: 1).cgColor)
        context.setLineWidth(2)
        let segments: [(CGPoint, CGPoint, CGPoint)] = [
            (CGPoint(x: cropRect.minX, y: cropRect.minY + corner),
             CGPoint(x: cropRect.minX, y: cropRect.minY),
             CGPoint(x: cropRect.minX + corner, y: cropRect.minY)),
            (CGPoint(x: cropRect.maxX - corner, y: cropRect.minY),
             CGPoint(x: cropRect.maxX, y: cropRect.minY),
             CGPoint(x: cropRect.maxX, y: cropRect.minY + corner)),
            (CGPoint(x: cropRect.minX, y: cropRect.maxY - corner),
             CGPoint(x: cropRect.minX, y: cropRect.maxY),
             CGPoint(x: cropRect.minX + corner, y: cropRect.maxY)),
            (CGPoint(x: cropRect.maxX - corner, y: cropRect.maxY),
             CGPoint(x: cropRect.maxX, y: cropRect.maxY),
             CGPoint(x: cropRect.maxX, y: cropRect.maxY - corner)),
        ]
        for (start, cornerPoint, end) in segments {
            context.beginPath()
            context.move(to: start)
            context.addLine(to: cornerPoint)
            context.addLine(to: end)
            context.strokePath()
        }
    }
}

//
//  FittingModels.swift —— 试衣间用到的展示结构
//

import CoreGraphics
import Foundation

/// 画布上的一层（衣物），对应 fitting.js 里 layers 的每一项
struct FittingLayer: Identifiable, Hashable {
    var clothingId: String
    var name: String
    var image: String
    /// 图层在画布上的显示尺寸（对应 sizeOf 算出来的 w/h）
    var w: CGFloat
    var h: CGFloat
    /// 左上角坐标（与小程序一致，x/y 是左上角，不是中心）
    var x: CGFloat
    var y: CGFloat
    var scale: CGFloat
    var rotation: CGFloat
    var z: Int
    var selected: Bool

    var id: String { clothingId }
    /// 中心点
    var center: CGPoint { CGPoint(x: x + w / 2, y: y + h / 2) }
}

/// 一件衣物在画布上的摆位（保存进 canvasData 的就是它）
struct FittingPose: Hashable {
    var x: CGFloat
    var y: CGFloat
    var scale: CGFloat = 1
    var rotation: CGFloat = 0
    var zIndex: Int = 1
}

/// 「我的搭配」列表里的一项
struct SavedOutfit: Identifiable, Hashable {
    var id: String
    var cover: String
    var count: Int
    var seasonText: String
    var dateLabel: String
}

/// 灵感网格里的一项
struct InspirationRow: Identifiable, Hashable {
    var id: String
    var folderId: String
    var images: [String]
    var clothingIds: [String]
    var thumb: String
    var note: String
    var imageCount: Int
    var clothingText: String
    var selected: Bool
}

/// 「设置季节」弹层
struct SeasonSheetState: Equatable {
    var show = false
    var outfitId = ""
    var selected: [String] = []
}

/// 试衣间的两种选衣场景（对应 selectorMode）
enum FittingSelectorMode {
    case stage
    case inspiration
}

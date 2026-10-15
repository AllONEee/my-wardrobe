//
//  ClassificationService.swift —— 用系统视觉框架猜衣物分类
//
//  VNClassifyImageRequest 给的是 ImageNet 那种英文标签（"jeans" / "sneaker" / "t-shirt" …），
//  这里维护一张「英文标签关键词 -> 中文分类」的映射表，把最匹配的那个翻成衣橱里的分类。
//  只做「猜」：猜不出来就返回 nil，让用户在批量导入页里自己选，绝不硬塞一个错的。
//

import UIKit
import Vision

final class ClassificationService {
    static let shared = ClassificationService()

    private init() {}

    /// 关键词 -> 分类（尽量用「词根」匹配，jeans / jean 都能命中）
    private static let rules: [(keywords: [String], category: String)] = [
        (["trouser", "jean", "pant", "denim", "shorts", "sweatpant", "legging", "cargo", "chino"], "裤子"),
        (["skirt", "dress", "gown", "frock"], "裙子"),
        (["sneaker", "boot", "sandal", "slipper", "shoe", "loafer", "footwear", "heel", "slipper"], "鞋"),
        (["suit", "tuxedo", "uniform"], "套装"),
        (["bag", "handbag", "purse", "backpack", "wallet", "hat", "cap", "scarf", "glove",
          "belt", "watch", "sunglasses", "tie", "necklace", "ring", "jewel", "earring",
          "bracelet", "umbrella"], "配饰"),
        (["shirt", "tshirt", "t-shirt", "tee", "sweater", "sweatshirt", "hoodie", "jacket",
          "coat", "blouse", "vest", "cardigan", "jersey", "pullover", "parka", "poncho",
          "tank", "top", "polo", "windbreaker", "overcoat", "raincoat", "sportswear",
          "outerwear", "clothing", "apparel"], "上衣"),
    ]

    /// 猜一个分类。
    /// - Parameters:
    ///   - image: 优先用**原图**（带背景时分类器的判断准得多，抠完的透明 PNG 反而少了上下文）
    ///   - categories: 用户当前的分类列表；猜出来的名字不在里面时返回 nil
    func guessCategory(for image: UIImage, categories: [String]) async -> String? {
        guard let cgImage = image.cgImage else { return nil }
        let orientation = CGImagePropertyOrientation(image.imageOrientation)
        return await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let handler = VNImageRequestHandler(cgImage: cgImage, orientation: orientation, options: [:])
                let request = VNClassifyImageRequest()
                do {
                    try handler.perform([request])
                } catch {
                    continuation.resume(returning: nil)
                    return
                }
                let observations = request.results ?? []
                continuation.resume(returning: Self.match(observations, categories: categories))
            }
        }
    }

    private static func match(_ observations: [VNClassificationObservation], categories: [String]) -> String? {
        // 置信度太低的不要（宁可不猜）
        for observation in observations where observation.confidence >= 0.15 {
            let label = observation.identifier.lowercased()
            for rule in rules where rule.keywords.contains(where: { label.contains($0) }) {
                if categories.contains(rule.category) { return rule.category }
                return nil
            }
        }
        return nil
    }
}

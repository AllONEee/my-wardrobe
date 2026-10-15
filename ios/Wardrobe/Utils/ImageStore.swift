//
//  ImageStore.swift —— 图片：压缩 / 沙箱读写 / 删除（对应 utils/image.js）
//
//  存储约定：
//   - 用户数据目录：Application Support/Wardrobe/images/
//   - 相册 / 相机选出来的图是临时的，需要长期保存的都要经过这里落盘
//   - 数据里只存「文件名」（例如 img_1712345678_123.png），不存 base64、也不存绝对路径：
//     iOS 的沙箱目录在重装 / 升级后会变，存绝对路径会全部失效（这是与小程序唯一的一处差异，
//     小程序可直接用绝对路径是因为它的沙箱目录不会变）
//
//  压缩注意：
//   - 抠图结果是带透明通道的 PNG，转成 JPEG 会丢掉透明背景，所以 PNG 一律原样保存
//   - 普通照片（JPEG / HEIC）统一压到 0.8 质量再落盘，控制体积
//

import Foundation
import ImageIO
import UIKit
import UniformTypeIdentifiers

final class ImageStore {
    static let shared = ImageStore()

    /// 图片目录
    let imagesDirectory: URL
    /// 导出目录（设置页「导出 JSON」的产物都放这里）
    let exportsDirectory: URL

    private init() {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        let root = base.appendingPathComponent("Wardrobe", isDirectory: true)
        imagesDirectory = root.appendingPathComponent("images", isDirectory: true)
        exportsDirectory = root.appendingPathComponent("exports", isDirectory: true)
        ensureDir(imagesDirectory)
        ensureDir(exportsDirectory)
    }

    /* ==================== 目录 ==================== */

    @discardableResult
    func ensureDir(_ url: URL) -> Bool {
        if FileManager.default.fileExists(atPath: url.path) { return true }
        do {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            return true
        } catch {
            print("[image] 创建目录失败：\(url.path) \(error)")
            return false
        }
    }

    /* ==================== 路径 ==================== */

    private func extOf(_ path: String, fallback: String = ".jpg") -> String {
        let ext = (path as NSString).pathExtension.lowercased()
        return ext.isEmpty ? fallback : "." + ext
    }

    func isPNG(_ path: String) -> Bool {
        extOf(path, fallback: "").contains("png")
    }

    private func uniqueName(_ prefix: String, _ ext: String) -> String {
        let stamp = Int(Date().timeIntervalSince1970 * 1000)
        let random = Int.random(in: 0..<10000)
        return "\(prefix)_\(stamp)_\(random)\(ext)"
    }

    /// 数据里存的文件名 -> 真正可用的沙箱路径。
    /// 兼容三种写法：文件名、绝对路径（小程序/旧数据导出）、带目录的相对路径。
    func url(for stored: String) -> URL? {
        let trimmed = stored.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        if trimmed.hasPrefix("/") {
            // 绝对路径：优先原样用（同机迁移）否则退回同名文件
            if FileManager.default.fileExists(atPath: trimmed) {
                return URL(fileURLWithPath: trimmed)
            }
            return imagesDirectory.appendingPathComponent((trimmed as NSString).lastPathComponent)
        }
        if trimmed.contains("/") {
            return imagesDirectory.appendingPathComponent((trimmed as NSString).lastPathComponent)
        }
        return imagesDirectory.appendingPathComponent(trimmed)
    }

    /// 是否是我们自己沙箱目录下的图片（相册 / 相机出来的临时路径都算「不是」）
    func isOwned(_ stored: String) -> Bool {
        guard !stored.isEmpty else { return false }
        if stored.hasPrefix(imagesDirectory.path) { return true }
        if stored.hasPrefix("/") { return false }
        return !stored.contains("/")
    }

    /* ==================== 保存 ==================== */

    /// 保存一段图片数据（相册 / 相机 / 分享进来的数据都走它）
    /// - Returns: 落盘后的文件名；失败返回 nil
    func saveData(_ data: Data, prefix: String = "img", forcePNG: Bool = false) -> String? {
        // PNG 图片原样保存，透明通道不能丢
        if forcePNG || isPNGData(data) {
            let name = uniqueName(prefix, ".png")
            let target = imagesDirectory.appendingPathComponent(name)
            do {
                try data.write(to: target, options: .atomic)
                return name
            } catch {
                print("[image] 写入失败：\(error)")
                return nil
            }
        }
        guard let image = UIImage(data: data) else { return nil }
        return saveImage(image, prefix: prefix, keepAlpha: false)
    }

    /// 保存一张 UIImage
    /// - Parameter keepAlpha: true（抠图结果 / 编辑器导出 / 搭配封面）存 PNG 保留透明通道；false 存 JPEG
    func saveImage(_ image: UIImage, prefix: String = "img", keepAlpha: Bool = false, quality: CGFloat = 0.8) -> String? {
        let data: Data?
        let ext: String
        if keepAlpha {
            data = image.pngData()
            ext = ".png"
        } else if let jpeg = image.jpegData(compressionQuality: quality) {
            data = jpeg
            ext = ".jpg"
        } else {
            data = image.pngData()
            ext = ".png"
        }
        guard let data, ensureDir(imagesDirectory) else { return nil }
        let name = uniqueName(prefix, ext)
        do {
            try data.write(to: imagesDirectory.appendingPathComponent(name), options: .atomic)
            return name
        } catch {
            print("[image] 写入失败：\(error)")
            return nil
        }
    }

    /// 保存一段文本（设置页导出 JSON 用）
    func writeTextFile(directory: URL, name: String, content: String) -> URL? {
        guard ensureDir(directory) else { return nil }
        let target = directory.appendingPathComponent(name)
        do {
            try content.write(to: target, atomically: true, encoding: .utf8)
            return target
        } catch {
            print("[image] 导出文件失败：\(error)")
            return nil
        }
    }

    /* ==================== 读取 ==================== */

    func image(for stored: String, maxPixelSize: Int = 1200) -> UIImage? {
        guard let url = url(for: stored) else { return nil }
        return ImageCache.shared.image(at: url, maxPixelSize: maxPixelSize)
    }

    func imageData(for stored: String) -> Data? {
        guard let url = url(for: stored) else { return nil }
        return try? Data(contentsOf: url)
    }

    /* ==================== 删除 ==================== */

    /// 只删除我们自己沙箱里的图片，其它路径一律忽略（避免误删系统临时文件）
    @discardableResult
    func removeFile(_ stored: String) -> Bool {
        guard isOwned(stored), let url = url(for: stored) else { return false }
        do {
            try FileManager.default.removeItem(at: url)
            ImageCache.shared.remove(url)
            return true
        } catch {
            print("[image] 删除失败：\(url.path) \(error)")
            return false
        }
    }

    func removeFiles(_ list: [String]) {
        list.forEach { removeFile($0) }
    }

    /// 清空所有已保存的图片（设置页「清空数据」用）
    @discardableResult
    func clearImages() -> Bool {
        try? FileManager.default.removeItem(at: imagesDirectory)
        ImageCache.shared.removeAll()
        return ensureDir(imagesDirectory)
    }

    /// 已保存图片的数量与总大小（KB），设置页展示用
    func imagesStat() -> (count: Int, sizeKB: Int) {
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: imagesDirectory,
            includingPropertiesForKeys: [.fileSizeKey]
        ) else {
            return (0, 0)
        }
        var bytes = 0
        for file in files {
            let size = (try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            bytes += size
        }
        return (files.count, Int((Double(bytes) / 1024.0).rounded()))
    }

    private func isPNGData(_ data: Data) -> Bool {
        let signature: [UInt8] = [0x89, 0x50, 0x4E, 0x47]
        guard data.count >= 4 else { return false }
        return Array(data.prefix(4)) == signature
    }
}

/// 图片内存缓存（对应小程序 image 组件的 lazy-load）
final class ImageCache {
    static let shared = ImageCache()

    private let cache = NSCache<NSString, UIImage>()
    /// 图片可能从后台线程解码后写入缓存，这里加锁保证 keys 与 cache 的一致性
    private let lock = NSLock()
    private var keys: Set<String> = []

    private init() {
        cache.countLimit = 300
    }

    func image(at url: URL, maxPixelSize: Int) -> UIImage? {
        let key = "\(url.path)#\(maxPixelSize)" as NSString
        lock.lock()
        let cached = cache.object(forKey: key)
        lock.unlock()
        if let cached { return cached }
        guard let image = ImageCache.downsample(url: url, maxPixelSize: maxPixelSize) else { return nil }
        lock.lock()
        cache.setObject(image, forKey: key)
        keys.insert(key as String)
        lock.unlock()
        return image
    }

    /// 文件被删除或替换时把相关缓存清掉（同一个路径被重新保存后不会读到旧图）
    func remove(_ url: URL) {
        let prefix = url.path + "#"
        lock.lock()
        keys.filter { $0.hasPrefix(prefix) }.forEach { key in
            cache.removeObject(forKey: key as NSString)
            keys.remove(key)
        }
        lock.unlock()
    }

    func removeAll() {
        lock.lock()
        cache.removeAllObjects()
        keys.removeAll()
        lock.unlock()
    }

    /// 用 ImageIO 做下采样，避免把整张原图读进内存（相册大图尤其明显）
    static func downsample(url: URL, maxPixelSize: Int) -> UIImage? {
        let sourceOptions = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithURL(url as CFURL, sourceOptions) else {
            return UIImage(contentsOfFile: url.path)
        }
        if maxPixelSize <= 0 {
            guard let cgImage = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
                return UIImage(contentsOfFile: url.path)
            }
            return UIImage(cgImage: cgImage)
        }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
        ]
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            return UIImage(contentsOfFile: url.path)
        }
        return UIImage(cgImage: cgImage)
    }
}

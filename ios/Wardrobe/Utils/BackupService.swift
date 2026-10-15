//
//  BackupService.swift —— 完整备份 / 恢复（数据 + 图片）
//
//  之前设置页只能导出 JSON，里面只有图片文件名，图片本身还留在沙箱里 ——
//  换手机、重装 App 的时候等于丢图。这里做一个自解释的备份文件夹：
//
//      点点衣橱-备份-2026-10-16/
//          data.json     ← 和「导出 JSON」同一份结构
//          images/       ← 所有还在用的图片（原图、抠图、封面、灵感图）
//
//  导出走系统分享面板（存到「文件」/ AirDrop 都行），恢复时在「文件」里把整个文件夹选回来。
//  不用第三方 zip 库：文件夹本身就是备份格式，用户打开还看得懂。
//

import Foundation
import UIKit

enum BackupService {
    struct Summary {
        var folderName: String
        var imageCount: Int
    }

    struct RestoreResult {
        var imageCount: Int
        var clothing: Int
        var outfits: Int
        var inspirations: Int
    }

    enum BackupError: LocalizedError {
        case emptyData
        case missingDataFile
        case badData

        var errorDescription: String? {
            switch self {
            case .emptyData: return "衣橱里还没有数据，先加几件衣物再备份吧"
            case .missingDataFile: return "这个文件夹里没有 data.json，不是点点衣橱的备份"
            case .badData: return "备份里的 data.json 读不出来，可能已经损坏"
            }
        }
    }

    /* ==================== 备份 ==================== */

    /// 生成备份文件夹（放在临时目录），返回文件夹 URL 与统计
    static func makeBackup() throws -> (url: URL, summary: Summary) {
        let all = Database.shared.listAllClothing()
        let outfits = Database.shared.listOutfits()
        let inspirations = Database.shared.listInspirations()
        guard !all.isEmpty || !outfits.isEmpty || !inspirations.isEmpty else {
            throw BackupError.emptyData
        }

        let name = "点点衣橱-备份-" + DateUtil.today()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(name, isDirectory: true)
        try? FileManager.default.removeItem(at: root)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        let json = Database.shared.exportJSONString()
        try json.write(to: root.appendingPathComponent("data.json"), atomically: true, encoding: .utf8)

        let images = root.appendingPathComponent("images", isDirectory: true)
        try FileManager.default.createDirectory(at: images, withIntermediateDirectories: true)

        var copied = 0
        for imageName in Database.shared.allImageNames() {
            guard let source = ImageStore.shared.url(for: imageName),
                  FileManager.default.fileExists(atPath: source.path) else { continue }
            let target = images.appendingPathComponent(source.lastPathComponent)
            guard !FileManager.default.fileExists(atPath: target.path) else { continue }
            if (try? FileManager.default.copyItem(at: source, to: target)) != nil { copied += 1 }
        }

        return (root, Summary(folderName: name, imageCount: copied))
    }

    /* ==================== 恢复 ==================== */

    /// 从用户选中的文件夹恢复（会覆盖当前数据）
    static func restore(from folder: URL) throws -> RestoreResult {
        // 用户从「文件」里选进来的目录要申请一次访问权限
        let scoped = folder.startAccessingSecurityScopedResource()
        defer { if scoped { folder.stopAccessingSecurityScopedResource() } }

        let jsonURL = folder.appendingPathComponent("data.json")
        guard FileManager.default.fileExists(atPath: jsonURL.path) else {
            throw BackupError.missingDataFile
        }
        guard let data = try? Data(contentsOf: jsonURL),
              let payload = Database.shared.decodePayload(data) else {
            throw BackupError.badData
        }

        // 先把图片搬进沙箱（同名覆盖），再换数据 —— 万一复制失败，至少数据没被改坏
        var copied = 0
        let imagesSource = folder.appendingPathComponent("images", isDirectory: true)
        if FileManager.default.fileExists(atPath: imagesSource.path) {
            let names = (try? FileManager.default.contentsOfDirectory(atPath: imagesSource.path)) ?? []
            for name in names {
                let from = imagesSource.appendingPathComponent(name)
                guard let to = ImageStore.shared.url(for: name) else { continue }
                try? FileManager.default.removeItem(at: to)
                if (try? FileManager.default.copyItem(at: from, to: to)) != nil { copied += 1 }
            }
        }
        // 图片文件被换过，内存缓存里的旧图必须清掉
        ImageCache.shared.removeAll()

        Database.shared.replaceAll(with: payload)
        return RestoreResult(
            imageCount: copied,
            clothing: payload.clothing.count,
            outfits: payload.outfits.count,
            inspirations: payload.inspirations.count
        )
    }
}

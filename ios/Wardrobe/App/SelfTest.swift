//
//  SelfTest.swift —— 临时自检（只在带 -selftest 启动参数时跑）
//
//  验证这一轮新增的数据层逻辑：单次成本、排序、穿搭自动计次与回滚、
//  断舍离、批量操作、标签管理、连带清理。跑完会把测试数据删掉。
//

import Foundation

enum SelfTest {
    private static var passed = 0
    private static var failed = 0

    static func runIfRequested() -> Bool {
        guard ProcessInfo.processInfo.arguments.contains("-selftest") else { return false }
        run()
        return true
    }

    private static func expect(_ condition: Bool, _ name: String, _ detail: String = "") {
        if condition {
            passed += 1
            print("  ✓ \(name)")
        } else {
            failed += 1
            print("  ✗ \(name) \(detail)")
        }
    }

    private static func draft(_ name: String, price: String = "", category: String = "上衣") -> ClothingDraft {
        var item = ClothingDraft()
        item.name = name
        item.price = price
        item.category = category
        return item
    }

    static func run() {
        let db = Database.shared
        let today = DateUtil.today()
        let before = db.listAllClothing().count
        print("[selftest] 开始（当前 \(before) 件衣物）")

        /* ---------- 迁移 ---------- */
        expect(Storage.shared.value(Storage.Key.schemaVersion, as: Int.self, default: 0) == 2, "数据结构版本 = 2")

        /* ---------- 单次成本 ---------- */
        let a = db.addClothing(draft("自检-衬衫", price: "299"))
        db.setWearCount(a.id, count: 6)
        let cost = db.getClothing(a.id)?.costPerWear ?? 0
        expect(abs(cost - 49.8333) < 0.01, "单次成本 = 价格 ÷ 次数", "得到 \(cost)")
        let b = db.addClothing(draft("自检-没穿过", price: "100", category: "裤子"))
        expect(db.getClothing(b.id)?.costPerWear == nil, "没穿过 → 没有单次成本")
        let c = db.addClothing(draft("自检-没价格", category: "鞋"))
        expect(db.getClothing(c.id)?.costPerWear == nil, "没填价格 → 没有单次成本")

        /* ---------- 金额格式化 ---------- */
        expect(Money.text(1280) == "¥1,280", "千分位", Money.text(1280))
        expect(Money.text(38.5) == "¥38.5", "小数不多余补零", Money.text(38.5))
        expect(Money.number(49.8333) == "49.83", "两位小数", Money.number(49.8333))
        expect(Money.costPerWear(29.95) == "¥29.95/次", "单次成本文案")

        /* ---------- 排序 ---------- */
        db.setWearCount(a.id, count: 6)      // 49.83/次
        db.setWearCount(b.id, count: 1)      // 100/次
        let byCost = Database.sortClothing(db.listAllClothing(), by: .costHigh)
        let costIds = byCost.compactMap { $0.costPerWear }.prefix(2)
        expect(costIds.first ?? 0 >= costIds.last ?? 0, "按单次成本排序：贵的在前")
        let byWear = Database.sortClothing(db.listAllClothing(), by: .mostWorn)
        expect(byWear.first!.wearCount >= byWear.last!.wearCount, "按次数排序：多的在前")
        let noneWear = db.addClothing(draft("自检-零次"))
        let sortedCost = Database.sortClothing(db.listAllClothing(), by: .costHigh)
        let zeroIndex = sortedCost.firstIndex { $0.id == noneWear.id }
        let costCount = sortedCost.filter { $0.costPerWear != nil }.count
        expect((zeroIndex ?? 0) >= costCount, "算不出单次成本的排在最后")

        /* ---------- 记穿搭自动计次 ---------- */
        var d1 = OutfitDraft()
        d1.clothingIds = [a.id, b.id]
        d1.countWear = true
        d1.date = today
        let outfit = db.saveOutfit(d1)
        expect(db.getClothing(a.id)?.wearCount == 7, "新建穿搭：关联衣物 +1", "\(db.getClothing(a.id)?.wearCount ?? -1)")
        expect(db.getClothing(b.id)?.wearCount == 2, "新建穿搭：第二件也 +1")
        expect(db.getClothing(a.id)?.lastWornDate == today, "最近穿着日期 = 穿搭日期")
        expect(db.getOutfit(outfit.id)?.wearCounted == true, "这套记录标为「已计入」")

        // 编辑：拿掉 b、加进 c
        var d2 = OutfitDraft()
        d2.id = outfit.id
        d2.clothingIds = [a.id, c.id]
        d2.date = today
        db.saveOutfit(d2)
        expect(db.getClothing(b.id)?.wearCount == 1, "编辑拿掉的 -1", "\(db.getClothing(b.id)?.wearCount ?? -1)")
        expect(db.getClothing(c.id)?.wearCount == 1, "编辑新加的 +1")
        expect(db.getClothing(a.id)?.wearCount == 7, "没动的不重复计次")

        // 取消「计入」
        var d3 = OutfitDraft()
        d3.id = outfit.id
        d3.clothingIds = [a.id, c.id]
        d3.countWear = false
        d3.date = today
        db.saveOutfit(d3)
        expect(db.getClothing(a.id)?.wearCount == 6, "取消计入：回滚 -1")
        expect(db.getClothing(c.id)?.wearCount == 0, "取消计入：新加的也回滚")

        // 计入后删除
        var d4 = OutfitDraft()
        d4.id = outfit.id
        d4.clothingIds = [a.id]
        d4.countWear = true
        d4.date = today
        db.saveOutfit(d4)
        expect(db.getClothing(a.id)?.wearCount == 7, "重新计入 +1")
        db.deleteOutfit(outfit.id)
        expect(db.getClothing(a.id)?.wearCount == 6, "删除计入过的穿搭：回滚")

        // 试衣间保存（countWear = nil、新建）默认不计次
        var d5 = OutfitDraft()
        d5.clothingIds = [a.id]
        let lookOnly = db.saveOutfit(d5)
        expect(db.getClothing(a.id)?.wearCount == 6, "试衣间摆的搭配默认不计次")
        expect(db.getOutfit(lookOnly.id)?.wearCounted == false, "并标为「未计入」")

        /* ---------- 断舍离 ---------- */
        db.releaseClothing(c.id, method: .sold, soldPrice: 50)
        db.updateClothing(c.id) { $0.price = 200 }
        expect(db.listClothing().contains { $0.id == c.id } == false, "已处置：不出现在在穿列表")
        expect(db.listAllClothing().contains { $0.id == c.id }, "已处置：全量列表里还在")
        expect(db.getClothing(c.id)?.isReleased == true, "已处置标记")
        expect(db.getClothing(c.id)?.netPrice == 150, "净成本 = 买价 - 回血", "\(db.getClothing(c.id)?.netPrice ?? -1)")
        db.restoreClothing(c.id)
        expect(db.listClothing().contains { $0.id == c.id }, "恢复后又回到在穿列表")
        expect(db.getClothing(c.id)?.soldPrice == 0, "恢复时清掉回血金额")

        /* ---------- 批量操作 ---------- */
        let changed = db.updateClothingBatch([a.id, b.id]) { $0.category = "裤子" }
        expect(changed == 2, "批量改分类", "\(changed)")
        expect(db.getClothing(a.id)?.category == "裤子" && db.getClothing(b.id)?.category == "裤子", "两件都改了")

        /* ---------- 标签 ---------- */
        db.addTagBatch("自检标签", ids: [a.id, b.id])
        expect(db.listTags().first { $0.name == "自检标签" }?.count == 2, "批量加标签")
        db.renameTag(from: "自检标签", to: "合并后的标签")
        expect(db.listTags().first { $0.name == "合并后的标签" }?.count == 2, "标签改名")
        expect(db.listTags().contains { $0.name == "自检标签" } == false, "旧名字消失")
        db.deleteTag("合并后的标签")
        expect(db.listTags().contains { $0.name == "合并后的标签" } == false, "删除标签")
        expect(db.getClothing(a.id)?.tags.isEmpty == true, "衣物上的标签被摘掉")

        /* ---------- 批量删除的连带清理 ---------- */
        var d6 = OutfitDraft()
        d6.clothingIds = [a.id, b.id]
        let linked = db.saveOutfit(d6)
        let result = db.deleteClothingBatch([a.id, b.id])
        expect(result.clothing == 2, "批量删除件数", "\(result.clothing)")
        // 这两件还被另一套（lookOnly）引用着，所以受影响的是 2 套
        expect(result.outfits == 2, "批量删除会清掉穿搭里的引用", "\(result.outfits)")
        expect(db.getOutfit(linked.id)?.clothingIds.isEmpty == true, "穿搭里已经不剩这两件")
        expect(db.getClothing(a.id) == nil, "删掉的衣物查不到了")

        /* ---------- 收尾 ---------- */
        db.deleteClothingBatch([c.id, noneWear.id])
        db.deleteOutfit(lookOnly.id)
        db.deleteOutfit(linked.id)
        let after = db.listAllClothing().count
        expect(after == before, "测试数据已清理干净", "\(before) -> \(after)")

        /* ---------- 备份 / 恢复 ---------- */
        do {
            let backup = try BackupService.makeBackup()
            let jsonURL = backup.url.appendingPathComponent("data.json")
            expect(FileManager.default.fileExists(atPath: jsonURL.path), "备份里生成了 data.json")
            expect(
                FileManager.default.fileExists(atPath: backup.url.appendingPathComponent("images").path),
                "备份里带了 images 目录"
            )
            expect(backup.summary.imageCount > 0, "备份打包了图片", "\(backup.summary.imageCount) 张")
            if let data = try? Data(contentsOf: jsonURL) {
                expect(db.decodePayload(data) != nil, "备份的 JSON 能解析回来")
            } else {
                expect(false, "备份的 JSON 能读出来")
            }
            let restored = try BackupService.restore(from: backup.url)
            expect(restored.clothing == before, "恢复后衣物件数一致", "\(restored.clothing) vs \(before)")
        } catch {
            expect(false, "备份 / 恢复流程", "\(error)")
        }

        print("[selftest] 通过 \(passed) 项，失败 \(failed) 项")
    }
}

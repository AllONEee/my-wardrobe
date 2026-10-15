//
//  CheckerboardBackground.swift —— 透明区域的棋盘格底纹
//  对应 image-editor.wxss 里 .stage 的 repeating-linear-gradient 棋盘格。
//

import SwiftUI

struct CheckerboardBackground: View {
    var cell: CGFloat = 12

    var body: some View {
        Canvas { context, size in
            context.fill(Path(CGRect(origin: .zero, size: size)), with: .color(.white))
            let columns = Int(ceil(size.width / cell))
            let rows = Int(ceil(size.height / cell))
            guard columns > 0, rows > 0 else { return }
            for row in 0..<rows {
                for column in 0..<columns where (row + column) % 2 == 0 {
                    let rect = CGRect(
                        x: CGFloat(column) * cell,
                        y: CGFloat(row) * cell,
                        width: cell,
                        height: cell
                    )
                    context.fill(Path(rect), with: .color(Theme.checkerboard))
                }
            }
        }
    }
}

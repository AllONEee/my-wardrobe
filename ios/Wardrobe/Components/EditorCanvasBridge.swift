//
//  EditorCanvasBridge.swift —— SwiftUI 与 UIKit 画布之间的桥
//  对应小程序里页面通过 selectComponent('#editor') 拿到画布组件、再调它的方法。
//

import SwiftUI

/// 画布代理：SwiftUI 通过它给 UIKit 画布下指令、读取状态
final class EditorProxy: ObservableObject {
    weak var canvas: EditorCanvas?

    @Published var canUndo = false
    @Published var canRedo = false
    @Published var loading = true
}

struct EditorCanvasView: UIViewRepresentable {
    let proxy: EditorProxy
    let mode: EditorMode
    let brushSize: Double
    let source: String
    /// 正在自动抠图 / 长按抠图：画布这段时间不接收涂抹
    var processing: Bool = false
    let onFirstEdit: () -> Void
    let onMessage: (String) -> Void
    /// 长按衣物主体（回调带原图坐标），用于「只抠出长按的那件」
    var onLongPress: ((CGPoint) -> Void)? = nil

    func makeUIView(context: Context) -> EditorCanvas {
        let view = EditorCanvas()
        view.onStateChange = { [weak proxy] state in
            guard let proxy else { return }
            proxy.canUndo = state.canUndo
            proxy.canRedo = state.canRedo
            proxy.loading = state.loading
        }
        view.onFirstEdit = onFirstEdit
        view.onMessage = onMessage
        view.onLongPress = onLongPress
        view.brushSize = CGFloat(brushSize)
        view.processing = processing
        view.setMode(mode)
        view.load(source: source)
        proxy.canvas = view
        return view
    }

    func updateUIView(_ view: EditorCanvas, context: Context) {
        view.brushSize = CGFloat(brushSize)
        view.processing = processing
        view.onLongPress = onLongPress
        view.setMode(mode)
    }
}

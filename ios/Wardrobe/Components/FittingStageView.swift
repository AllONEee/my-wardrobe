//
//  FittingStageView.swift —— 试衣间的画布区
//  对应 fitting.wxml 里 movable-area / movable-view 那一段：
//  每个图层单指拖动、双指捏合缩放与旋转，选中的图层显示虚线框和右上角的删除按钮。
//

import SwiftUI

struct FittingStageView: View {
    let layers: [FittingLayer]
    let stageSize: CGSize
    let onTapLayer: (String) -> Void
    let onTapStage: () -> Void
    let onRemove: (String) -> Void
    let onGestureBegin: (String) -> Void
    let onDrag: (String, CGSize) -> Void
    let onMagnify: (String, CGFloat) -> Void
    let onRotate: (String, CGFloat) -> Void
    let onGestureEnd: (String) -> Void

    var body: some View {
        ZStack(alignment: .topLeading) {
            Theme.card
            ForEach(layers) { layer in
                layerView(layer)
            }
            if layers.isEmpty {
                VStack(spacing: 6) {
                    Text("画布是空的")
                        .font(.system(size: Theme.fontSubtitle, weight: .medium))
                        .foregroundStyle(Theme.text)
                    Text("点下面的「添加衣物」把衣橱里的衣物放进来，单指拖动、双指缩放旋转")
                        .font(.system(size: Theme.fontCaption))
                        .foregroundStyle(Theme.textSub)
                        .multilineTextAlignment(.center)
                }
                .padding(.horizontal, 24)
                .frame(width: stageSize.width, height: stageSize.height, alignment: .center)
            }
        }
        .frame(width: stageSize.width, height: stageSize.height)
        .clipShape(RoundedRectangle(cornerRadius: Theme.radius, style: .continuous))
        .shadow(color: Color.black.opacity(0.06), radius: 12, x: 0, y: 4)
        .contentShape(Rectangle())
        .onTapGesture { onTapStage() }
    }

    private func layerView(_ layer: FittingLayer) -> some View {
        ZStack {
            // 只画有内容的那块：和 sizeOf 量出来的比例一致，衣服才会正好撑满定位框
            StoredImage(path: layer.image, mode: .fit, maxPixel: 600, contentOnly: true)

            if layer.selected {
                RoundedRectangle(cornerRadius: 3, style: .continuous)
                    .strokeBorder(
                        Theme.primary,
                        style: StrokeStyle(lineWidth: 1, dash: [4, 3])
                    )
            }
        }
        .frame(width: layer.w, height: layer.h)
        .overlay(alignment: .topTrailing) {
            if layer.selected {
                Button {
                    onRemove(layer.clothingId)
                } label: {
                    Text("✕")
                        .font(.system(size: 11))
                        .foregroundStyle(.white)
                        .frame(width: 22, height: 22)
                        .background(Theme.danger)
                        .clipShape(Circle())
                        .shadow(color: Color.black.opacity(0.24), radius: 6, x: 0, y: 2)
                }
                .offset(x: 7, y: -7)
            }
        }
        .scaleEffect(layer.scale)
        .rotationEffect(.degrees(layer.rotation))
        .position(layer.center)
        .zIndex(Double(layer.z))
        .contentShape(Rectangle())
        .onTapGesture { onTapLayer(layer.clothingId) }
        .gesture(dragGesture(layer))
        .simultaneousGesture(magnifyGesture(layer))
        .simultaneousGesture(rotateGesture(layer))
    }

    private func dragGesture(_ layer: FittingLayer) -> some Gesture {
        DragGesture(minimumDistance: 2)
            .onChanged { value in
                onGestureBegin(layer.clothingId)
                onDrag(layer.clothingId, value.translation)
            }
            .onEnded { _ in
                onGestureEnd(layer.clothingId)
            }
    }

    private func magnifyGesture(_ layer: FittingLayer) -> some Gesture {
        MagnifyGesture(minimumScaleDelta: 0.01)
            .onChanged { value in
                onGestureBegin(layer.clothingId)
                onMagnify(layer.clothingId, value.magnification)
            }
            .onEnded { _ in
                onGestureEnd(layer.clothingId)
            }
    }

    private func rotateGesture(_ layer: FittingLayer) -> some Gesture {
        RotateGesture(minimumAngleDelta: .degrees(1))
            .onChanged { value in
                onGestureBegin(layer.clothingId)
                onRotate(layer.clothingId, CGFloat(value.rotation.degrees))
            }
            .onEnded { _ in
                onGestureEnd(layer.clothingId)
            }
    }
}

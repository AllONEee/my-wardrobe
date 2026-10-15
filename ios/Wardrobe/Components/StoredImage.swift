//
//  StoredImage.swift —— 显示本地图片（对应 wxml 里的 <image src="..." mode="aspectFit" />）
//
//  数据里存的是文件名，这里负责换成沙箱路径、按需下采样、读取（带内存缓存），
//  所以页面里只写 StoredImage(path: item.coverImage) 就够了。
//

import SwiftUI
import UIKit

struct StoredImage: View {
    let path: String
    var mode: ContentMode = .fit
    /// 下采样长边（网格里的缩略图给小一点，省内存）
    var maxPixel: Int = 900
    /// 抠完的图四周可能有整片透明：true 时只显示有内容的那块（衣服撑满框，定位框也不会虚大）
    var contentOnly: Bool = false

    @State private var image: UIImage?

    var body: some View {
        GeometryReader { geo in
            Group {
                if let image {
                    Image(uiImage: image)
                        .resizable()
                        .aspectRatio(contentMode: mode)
                        .frame(width: geo.size.width, height: geo.size.height)
                        .clipped()
                } else {
                    Color.clear
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
        .task(id: "\(path)#\(maxPixel)#\(contentOnly)") {
            await load()
        }
    }

    private func load() async {
        guard !path.isEmpty, let url = ImageStore.shared.url(for: path) else {
            image = nil
            return
        }
        let cacheHit = contentOnly
            ? ImageStore.shared.contentImage(for: path, maxPixelSize: maxPixel)
            : ImageCache.shared.image(at: url, maxPixelSize: maxPixel)
        if let cached = cacheHit {
            image = cached
            return
        }
        let loaded: UIImage? = await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let result = contentOnly
                    ? ImageStore.shared.contentImage(for: path, maxPixelSize: maxPixel)
                    : ImageCache.shared.image(at: url, maxPixelSize: maxPixel)
                continuation.resume(returning: result)
            }
        }
        image = loaded
    }
}

/// 大图预览（对应 wx.previewImage）
struct ImagePreviewSheet: View {
    let paths: [String]
    @Binding var isPresented: Bool

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            ScrollView(.horizontal) {
                HStack(spacing: 0) {
                    ForEach(paths, id: \.self) { path in
                        StoredImage(path: path, mode: .fit, maxPixel: 2000)
                            .frame(maxWidth: .infinity)
                            .containerRelativeFrame(.horizontal)
                    }
                }
            }
            .scrollIndicators(.hidden)

            VStack {
                HStack {
                    Spacer()
                    Button {
                        isPresented = false
                    } label: {
                        Text("✕")
                            .font(.system(size: 16))
                            .foregroundStyle(.white)
                            .frame(width: 32, height: 32)
                            .background(Color.white.opacity(0.18))
                            .clipShape(Circle())
                    }
                    .padding(16)
                }
                Spacer()
            }
        }
    }
}

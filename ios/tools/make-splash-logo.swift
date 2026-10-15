//
//  make-splash-logo.swift —— 从 App 图标里抠出开屏页用的线稿 logo
//
//  App 图标（Assets.xcassets/AppIcon.appiconset/AppIcon-1024.png）是「黑线稿 + 白底」的方图，
//  直接贴到开屏页上会带一个白底方块（还有个圆角「框」）。这个脚本把白底转成透明、把线稿裁到外接框，
//  生成只含线条的 Asset（SplashLogo），开屏页再用模板渲染 + Theme.text 上色，
//  于是浅色下是深色线条、深色下自动变成浅色线条。
//
//  用法（换图标后重跑一次即可）：
//      swiftc -sdk "$(xcrun --show-sdk-path --sdk macosx)" -o /tmp/mklogo ios/tools/make-splash-logo.swift
//      /tmp/mklogo ios/Wardrobe/Assets.xcassets/AppIcon.appiconset/AppIcon-1024.png \
//                 ios/Wardrobe/Assets.xcassets/SplashLogo.imageset/SplashLogo.png
//

import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

// 把 App 图标（黑线稿 + 白底）转成「只有线条、背景透明」的 logo，并裁到线条外接框
let inputPath = CommandLine.arguments[1]
let outputPath = CommandLine.arguments[2]

guard let src = CGImageSourceCreateWithURL(URL(fileURLWithPath: inputPath) as CFURL, nil),
      let image = CGImageSourceCreateImageAtIndex(src, 0, nil) else {
    print("读不到图片"); exit(1)
}
let w = image.width, h = image.height
var pixels = [UInt8](repeating: 0, count: w * h * 4)
let space = CGColorSpaceCreateDeviceRGB()
guard let ctx = CGContext(data: &pixels, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                          space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { exit(1) }
// 不翻转：CGContext 默认 y 向上，draw 出来是正的，内存行序也与图片一致
ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))

// 白底 -> 透明：alpha = 255 - 亮度；线条本身是黑的，所以颜色保持黑（premultiplied 下就是 0,0,0）
var alpha = [UInt8](repeating: 0, count: w * h)
var minX = w, minY = h, maxX = -1, maxY = -1
for y in 0..<h {
    for x in 0..<w {
        let i = (y * w + x) * 4
        let lum = (0.299 * Double(pixels[i]) + 0.587 * Double(pixels[i + 1]) + 0.114 * Double(pixels[i + 2])) / 255.0
        let a = UInt8(max(0, min(255, (1.0 - lum) * 255.0).rounded()))
        alpha[y * w + x] = a
        if a > 6 {
            if x < minX { minX = x }; if x > maxX { maxX = x }
            if y < minY { minY = y }; if y > maxY { maxY = y }
        }
    }
}
guard maxX > minX, maxY > minY else { print("没找到线条"); exit(1) }

var out = [UInt8](repeating: 0, count: w * h * 4)
for y in 0..<h {
    for x in 0..<w {
        let a = alpha[y * w + x]
        let i = (y * w + x) * 4
        out[i] = 0; out[i + 1] = 0; out[i + 2] = 0; out[i + 3] = a   // 黑色线条 + 透明底
    }
}
guard let full = ctx.makeImage() else { exit(1) }
_ = full

// 用 alpha 重新写一张图（CGImage 从 buffer 建）
let provider = CGDataProvider(data: Data(out) as CFData)!
let outImage = CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: w * 4,
                       space: space, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)!

// 裁到线条外接框，四周留 4% 余量
let margin = Int(Double(max(maxX - minX, maxY - minY)) * 0.04)
let cropRect = CGRect(x: max(0, minX - margin), y: max(0, minY - margin),
                      width: min(w, maxX + margin + 1) - max(0, minX - margin),
                      height: min(h, maxY + margin + 1) - max(0, minY - margin))
guard let cropped = outImage.cropping(to: cropRect) else { print("裁剪失败"); exit(1) }

let dest = CGImageDestinationCreateWithURL(URL(fileURLWithPath: outputPath) as CFURL,
                                           UTType.png.identifier as CFString, 1, nil)!
CGImageDestinationAddImage(dest, cropped, nil)
CGImageDestinationFinalize(dest)
print("已写出 \(outputPath)  \(cropped.width)×\(cropped.height)（原图 \(w)×\(h)，线条框 \(minX),\(minY)-\(maxX),\(maxY)）")

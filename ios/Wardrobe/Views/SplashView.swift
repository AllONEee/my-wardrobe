//
//  SplashView.swift —— 开屏页
//
//  中间放 App 图标，下面一行字。图标直接取应用自己的图标（Assets 里的 AppIcon），
//  所以以后换图标时开屏页会跟着变，这里不用改。
//

import SwiftUI
import UIKit

enum AppIconImage {
    /// 应用自己的图标：先按资源名找，找不到再走 Info.plist 里的图标清单
    static let shared: UIImage? = {
        if let icon = UIImage(named: "AppIcon") { return icon }
        guard let icons = Bundle.main.infoDictionary?["CFBundleIcons"] as? [String: Any],
              let primary = icons["CFBundlePrimaryIcon"] as? [String: Any],
              let files = primary["CFBundleIconFiles"] as? [String],
              let name = files.last else { return nil }
        return UIImage(named: name)
    }()
}

struct SplashView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var appeared = false

    var body: some View {
        ZStack {
            Theme.bg.ignoresSafeArea()

            VStack(spacing: 20) {
                // 与系统桌面图标一致：1024 的图按 112pt 显示，圆角比例沿用 iOS 的连续圆角
                if let icon = AppIconImage.shared {
                    Image(uiImage: icon)
                        .resizable()
                        .aspectRatio(1, contentMode: .fit)
                        .frame(width: 112, height: 112)
                        .clipShape(RoundedRectangle(cornerRadius: 25, style: .continuous))
                        .shadow(color: Color.black.opacity(0.14), radius: 18, x: 0, y: 8)
                }

                Text("做给点点的衣橱")
                    .font(.system(size: Theme.fontSubtitle))
                    .foregroundStyle(Theme.textSub)
                    .tracking(2)
            }
            .scaleEffect(appeared || reduceMotion ? 1 : 0.94)
            .opacity(appeared || reduceMotion ? 1 : 0)
        }
        .onAppear {
            guard !reduceMotion else { return }
            withAnimation(.easeOut(duration: 0.55)) { appeared = true }
        }
    }
}

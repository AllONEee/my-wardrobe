//
//  SplashView.swift —— 开屏页
//
//  中间放 logo、下面一行字。
//
//  logo 是从 App 图标里抠出来的线稿（Assets 里的 SplashLogo：只有线条、背景透明），
//  用模板渲染 + Theme.text 上色，所以浅色下是深色线条、深色下自动变成浅色线条；
//  不带白色方块底，也不会像直接贴 App 图标那样出现一个「框」。
//

import SwiftUI

struct SplashView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var appeared = false

    var body: some View {
        ZStack {
            Theme.bg.ignoresSafeArea()

            VStack(spacing: 20) {
                Image("SplashLogo")
                    .renderingMode(.template)   // 只画线条，跟着深浅色反色
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 190)
                    .foregroundStyle(Theme.text)

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

//
//  FormControls.swift —— 表单里反复用到的小件（对应 app.wxss 的 .section-title / .cell / picker）
//

import SwiftUI

/// 小节标题（对应 .section-title）
struct SectionTitle: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: Theme.fontCaption))
            .foregroundStyle(Theme.textSub)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 4)
            .padding(.top, 16)
            .padding(.bottom, 8)
    }
}

/// 卡片里的一行：左边标签、右边内容（对应 .cell）
struct FormRow<Trailing: View>: View {
    let label: String
    var extra: String = ""
    var showDivider: Bool = true
    /// 整行可点（对应 .cell--tap）
    var onTap: (() -> Void)? = nil
    @ViewBuilder var trailing: () -> Trailing

    var body: some View {
        HStack(spacing: 8) {
            HStack(spacing: 4) {
                Text(label)
                    .font(.system(size: Theme.fontBody))
                    .foregroundStyle(Theme.textSub)
                if !extra.isEmpty {
                    Text(extra)
                        .font(.system(size: Theme.fontTiny))
                        .foregroundStyle(Theme.textLight)
                }
            }
            Spacer(minLength: 8)
            trailing()
        }
        .frame(minHeight: Theme.cellHeight)
        .contentShape(Rectangle())
        .onTapGesture { onTap?() }
        .overlay(alignment: .bottom) {
            if showDivider {
                Rectangle().fill(Theme.border).frame(height: 0.5)
            }
        }
    }
}

/// 只读的一行：标签 + 右对齐的值（没有箭头）
struct ValueRow: View {
    let label: String
    let value: String
    var placeholder: String = "未填写"
    var showDivider: Bool = true

    var body: some View {
        FormRow(label: label, extra: "", showDivider: showDivider, onTap: nil) {
            Text(value.isEmpty ? placeholder : value)
                .font(.system(size: Theme.fontBody))
                .foregroundStyle(value.isEmpty ? Theme.textLight : Theme.text)
                .multilineTextAlignment(.trailing)
        }
    }
}

/// 可点的一行：标签 + 值 + 箭头（对应 .cell--tap）
struct TapRow: View {
    let label: String
    let value: String
    var placeholder: String = "未填写"
    var danger: Bool = false
    var showDivider: Bool = true
    let onTap: () -> Void

    var body: some View {
        FormRow(label: label, extra: "", showDivider: showDivider, onTap: onTap) {
            HStack(spacing: 4) {
                Text(value.isEmpty ? placeholder : value)
                    .font(.system(size: Theme.fontBody))
                    .foregroundStyle(value.isEmpty ? Theme.textLight : (danger ? Theme.danger : Theme.text))
                    .multilineTextAlignment(.trailing)
                Text("›")
                    .font(.system(size: 15))
                    .foregroundStyle(Theme.textLight)
            }
        }
    }
}

/// 滚轮日期选择（对应 <picker mode="date">）
struct DatePickerSheet: View {
    let title: String
    /// 空串表示未填写
    @Binding var date: String
    var allowClear: Bool = true
    var allowsFuture: Bool = true

    @Environment(\.dismiss) private var dismiss
    @State private var temp = Date()

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Button("取消") { dismiss() }
                    .font(.system(size: Theme.fontSmall))
                    .foregroundStyle(Theme.textSub)
                Spacer()
                Text(title)
                    .font(.system(size: Theme.fontSubtitle, weight: .semibold))
                Spacer()
                Button("确定") {
                    date = DateUtil.formatDate(temp)
                    dismiss()
                }
                .font(.system(size: Theme.fontSmall, weight: .medium))
                .foregroundStyle(Theme.primary)
            }
            .padding(.horizontal, 16)
            .padding(.top, 16)

            DatePicker("", selection: $temp, in: range, displayedComponents: .date)
                .datePickerStyle(.wheel)
                .labelsHidden()
                .frame(maxWidth: .infinity)

            if allowClear {
                Button("清除日期") {
                    date = ""
                    dismiss()
                }
                .buttonStyle(AppButtonStyle(kind: .ghost, small: true))
                .padding(.bottom, 20)
            } else {
                Spacer().frame(height: 20)
            }
        }
        .background(Theme.card)
        .onAppear {
            temp = date.isEmpty ? Date() : DateUtil.parseDate(date)
        }
    }

    private var range: ClosedRange<Date> {
        let distant = DateUtil.parseDate("1970-01-01")
        if allowsFuture {
            return distant...DateUtil.parseDate("2100-01-01")
        }
        return distant...Date()
    }
}

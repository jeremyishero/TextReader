import SwiftUI

// MARK: - 全局反馈组件
// 规范：任何预计超过 1 秒的操作必须显示 BusyHUD；成功用轻提示 Toast；失败用 Alert 给出准确原因。

/// 居中模态进度框：用于导入/OCR/云端请求等超过 1 秒的操作。
struct BusyHUD: View {
    let title: String

    var body: some View {
        ZStack {
            Color.black.opacity(0.2)
                .ignoresSafeArea()
            VStack(spacing: 14) {
                ProgressView()
                    .scaleEffect(1.2)
                Text(title)
                    .font(.callout)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.primary)
            }
            .padding(26)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
            .shadow(radius: 10)
        }
        .transition(.opacity)
    }
}

/// 底部轻提示：操作成功或静默回退时给出结果确认，数秒后自动消失。
struct ToastView: View {
    let text: String
    var isErrorStyle = false

    var body: some View {
        VStack {
            Spacer()
            HStack(spacing: 8) {
                Image(systemName: isErrorStyle ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                    .foregroundColor(isErrorStyle ? .orange : .green)
                Text(text)
                    .font(.footnote)
                    .foregroundStyle(.primary)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(.regularMaterial, in: Capsule())
            .padding(.bottom, 28)
        }
        .transition(.move(edge: .bottom).combined(with: .opacity))
        .allowsHitTesting(false)
    }
}

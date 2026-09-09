import SwiftUI

/// Тонкая вертикальная черта — разделитель внутри строки (модель ▏Wi-Fi).
/// Вместо «·», «•» и «|»: геометрический волосок читается тише и не спорит с текстом.
struct Hairline: View {

    var height: CGFloat = 10

    var body: some View {
        Rectangle()
            .frame(width: 1, height: height)
            .opacity(0.4)
            .foregroundStyle(.secondary)
            .accessibilityHidden(true)
    }
}

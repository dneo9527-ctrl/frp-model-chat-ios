import SwiftUI
import UIKit

enum AppTheme {
    static let accent = Color(UIColor { $0.userInterfaceStyle == .dark
        ? UIColor(white: 0.90, alpha: 1)
        : UIColor(red: 0.00, green: 0.43, blue: 0.40, alpha: 1) })
    static let onAccent = Color(UIColor { $0.userInterfaceStyle == .dark ? .black : .white })
    static let secondaryAction = Color(UIColor { $0.userInterfaceStyle == .dark
        ? UIColor(white: 0.28, alpha: 1)
        : UIColor(red: 0.00, green: 0.43, blue: 0.40, alpha: 1) })
    static let background = Color(UIColor { $0.userInterfaceStyle == .dark
        ? .black
        : UIColor(red: 0.955, green: 0.970, blue: 0.980, alpha: 1) })
    static let surface = Color(UIColor { $0.userInterfaceStyle == .dark
        ? UIColor(white: 0.11, alpha: 1) : .white })
    static let userBubble = Color(UIColor { $0.userInterfaceStyle == .dark
        ? UIColor(white: 0.17, alpha: 1)
        : UIColor(red: 0.00, green: 0.43, blue: 0.40, alpha: 0.14) })

    static func scheme(_ appearance: String) -> ColorScheme? {
        appearance == "dark" ? .dark : appearance == "light" ? .light : nil
    }
}

struct BrandMark: View {
    var size: CGFloat = 48
    @Environment(\.colorScheme) private var colorScheme
    private var isDark: Bool { colorScheme == .dark }
    var body: some View {
        ZStack {
            LinearGradient(colors: isDark ? [Color(white: 0.08), Color(white: 0.22)]
                            : [Color(red: 0.03, green: 0.13, blue: 0.18),
                               Color(red: 0.04, green: 0.25, blue: 0.30)],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
            BrandBubble().fill(Color.white)
            BrandArch(left: 0.30, top: 0.32, right: 0.70, bottom: 0.63)
                .stroke(isDark ? Color(white: 0.18) : Color(red: 0.03, green: 0.20, blue: 0.25), style: StrokeStyle(lineWidth: size * 0.075, lineCap: .round))
            BrandArch(left: 0.43, top: 0.46, right: 0.57, bottom: 0.63)
                .stroke(isDark ? Color(white: 0.48) : Color(red: 0.02, green: 0.77, blue: 0.68), style: StrokeStyle(lineWidth: size * 0.065, lineCap: .round))
        }.frame(width: size, height: size)
            .clipShape(RoundedRectangle(cornerRadius: size * 0.23, style: .continuous))
            .accessibilityHidden(true)
    }
}

private struct BrandBubble: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path(roundedRect: CGRect(x: rect.width * 0.16, y: rect.height * 0.18,
                                       width: rect.width * 0.68, height: rect.height * 0.61),
                     cornerRadius: rect.width * 0.25)
        p.move(to: CGPoint(x: rect.width * 0.24, y: rect.height * 0.65))
        p.addLine(to: CGPoint(x: rect.width * 0.42, y: rect.height * 0.73))
        p.addLine(to: CGPoint(x: rect.width * 0.20, y: rect.height * 0.85))
        p.closeSubpath()
        return p
    }
}

private struct BrandArch: Shape {
    let left: CGFloat, top: CGFloat, right: CGFloat, bottom: CGFloat
    func path(in rect: CGRect) -> Path {
        let radius = (right - left) / 2
        var p = Path()
        p.move(to: CGPoint(x: rect.width * left, y: rect.height * bottom))
        p.addLine(to: CGPoint(x: rect.width * left, y: rect.height * (top + radius)))
        p.addQuadCurve(to: CGPoint(x: rect.width * 0.5, y: rect.height * top),
                       control: CGPoint(x: rect.width * left, y: rect.height * top))
        p.addQuadCurve(to: CGPoint(x: rect.width * right, y: rect.height * (top + radius)),
                       control: CGPoint(x: rect.width * right, y: rect.height * top))
        p.addLine(to: CGPoint(x: rect.width * right, y: rect.height * bottom))
        return p
    }
}

extension View {
    @ViewBuilder func dismissKeyboardWhenScrolling() -> some View {
        if #available(iOS 16.0, *) { self.scrollDismissesKeyboard(.interactively) }
        else { self }
    }
    @ViewBuilder func clearEditorBackground() -> some View {
        if #available(iOS 16.0, *) { self.scrollContentBackground(.hidden) }
        else { self }
    }
}

// SPDX-License-Identifier: MPL-2.0
import AppKit
import SwiftUI
import NeutrinoCore

extension Accent {
    var color: Color { switch self { case .blue: .blue; case .teal: .teal; case .orange: .orange; case .purple: .purple; case .pink: .pink } }
}
extension InterfaceColor { var color: Color { Color(red: red, green: green, blue: blue) } }
extension Theme {
    var canvas: Color { surfaceHex.flatMap(InterfaceColor.init(hex:))?.color ?? Color(nsColor: NSColor(name: nil) { $0.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? NSColor(red: 0.13, green: 0.13, blue: 0.17, alpha: 1) : NSColor(red: 0.94, green: 0.93, blue: 0.97, alpha: 1) }) }
    var card: Color { Color(nsColor: NSColor(name: nil) { $0.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? NSColor(red: 0.18, green: 0.18, blue: 0.22, alpha: 1) : .white }) }
    var scheme: ColorScheme? { switch colorMode { case .system: nil; case .light: .light; case .dark: .dark } }
    var spacing: CGFloat { (density == .compact ? 6 : 10) * (spacingScale ?? 1) }
    var controlSize: ControlSize { density == .compact ? .small : .regular }
    var foreground: Color { textHex.flatMap(InterfaceColor.init(hex:))?.color ?? .primary }
    var tint: Color { accentHex.flatMap(InterfaceColor.init(hex:))?.color ?? accent.color }
    func interfaceFont(_ size: CGFloat = 13, weight: Font.Weight = .regular) -> Font {
        let design: Font.Design = switch typography ?? .system { case .system: .default; case .rounded: .rounded; case .serif: .serif; case .monospaced: .monospaced }
        return .system(size: size * (fontScale ?? 1), weight: weight, design: design)
    }
    func component(_ appearance: ComponentAppearance?) -> Theme {
        var result = self
        if let density = appearance?.density { result.density = density }
        if let scale = appearance?.fontScale { result.fontScale = scale }
        if let radius = appearance?.cornerRadius { result.cornerRadius = radius }
        return result
    }
}
private struct BrowserThemeKey: EnvironmentKey { static let defaultValue = Theme() }
private struct BrowserSymbolsKey: EnvironmentKey { static let defaultValue: [String: String] = [:] }
extension EnvironmentValues {
    var browserTheme: Theme { get { self[BrowserThemeKey.self] } set { self[BrowserThemeKey.self] = newValue } }
    var browserSymbols: [String: String] { get { self[BrowserSymbolsKey.self] } set { self[BrowserSymbolsKey.self] = newValue } }
}
struct BrowserSymbol: View {
    let name: String
    @Environment(\.browserTheme) private var theme
    @Environment(\.browserSymbols) private var symbols
    private var resolved: String {
        let candidate = symbols[name] ?? name
        if theme.iconStyle == .outline, candidate.hasSuffix(".fill") {
            let outline = String(candidate.dropLast(5))
            if NSImage(systemSymbolName: outline, accessibilityDescription: nil) != nil { return outline }
        }
        let filled = candidate.hasSuffix(".fill") ? candidate : candidate + ".fill"
        if theme.iconStyle == .filled, NSImage(systemSymbolName: filled, accessibilityDescription: nil) != nil { return filled }
        return NSImage(systemSymbolName: candidate, accessibilityDescription: nil) != nil ? candidate : name
    }
    var body: some View { Image(systemName: resolved) }
}
struct ChromeSurface: ViewModifier {
    let theme: Theme
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast
    private var surface: AnyShapeStyle {
        if contrast == .increased { return AnyShapeStyle(Color(nsColor: .windowBackgroundColor)) }
        if let color = theme.surfaceHex.flatMap(InterfaceColor.init(hex:)) { return AnyShapeStyle(color.color) }
        switch theme.design {
        case .liquidGlass: return theme.transparency && !reduceTransparency ? AnyShapeStyle(.ultraThinMaterial) : AnyShapeStyle(Color(nsColor: .windowBackgroundColor))
        case .material: return AnyShapeStyle(theme.tint.opacity(0.075))
        case .graphite: return AnyShapeStyle(Color(nsColor: .controlBackgroundColor))
        case .native: return AnyShapeStyle(theme.canvas)
        }
    }
    private var foreground: Color {
        contrast == .increased ? .primary : (theme.textHex.flatMap(InterfaceColor.init(hex:))?.color ?? .primary)
    }
    func body(content: Content) -> some View {
        content.background(surface).foregroundStyle(foreground)
            .overlay(alignment: .bottom) { Rectangle().fill(contrast == .increased ? Color.primary : Color(nsColor: .separatorColor)).frame(height: contrast == .increased ? 1 : (theme.borderWidth ?? 1)) }
            .shadow(color: .black.opacity((theme.shadowStrength ?? 0) * 0.18), radius: (theme.shadowStrength ?? 0) * 6, y: 2)
            .font(theme.interfaceFont()).environment(\.browserTheme, theme)
    }
}
struct IconButton: View {
    let title: String
    let icon: String
    var active = false
    let action: () -> Void
    @Environment(\.browserTheme) private var theme
    @Environment(\.colorSchemeContrast) private var contrast
    @State private var hovering = false
    var body: some View {
        Button(action: action) {
            BrowserSymbol(name: icon).frame(width: theme.density == .compact ? 28 : 32, height: theme.density == .compact ? 28 : 32)
                .foregroundStyle(contrast == .increased ? Color.primary : (active ? theme.tint : theme.foreground))
                .background(active ? theme.tint.opacity(0.14) : (hovering ? theme.foreground.opacity(0.07) : .clear), in: RoundedRectangle(cornerRadius: 8))
        }.buttonStyle(.plain).onHover { hovering = $0 }.help(title).accessibilityLabel(title)
    }
}

struct NeutrinoButtonStyle: ButtonStyle {
    var prominent = false
    @Environment(\.browserTheme) private var theme
    @Environment(\.isEnabled) private var enabled
    func makeBody(configuration: ButtonStyle.Configuration) -> some View {
        configuration.label.font(theme.interfaceFont(13, weight: .semibold))
            .padding(.horizontal, 16).padding(.vertical, 10)
            .foregroundStyle(prominent ? Color.white : theme.foreground)
            .background(prominent ? theme.tint : theme.foreground.opacity(0.065), in: RoundedRectangle(cornerRadius: 10))
            .opacity(enabled ? (configuration.isPressed ? 0.7 : 1) : 0.4)
    }
}

struct NeutrinoMark: View {
    var size: CGFloat = 32
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.3).fill(LinearGradient(colors: [Color(red: 0.48, green: 0.36, blue: 0.88), Color(red: 0.25, green: 0.20, blue: 0.54)], startPoint: .topLeading, endPoint: .bottomTrailing))
            Image(systemName: "sparkle").font(.system(size: size * 0.55, weight: .medium)).foregroundStyle(.white)
        }.frame(width: size, height: size).accessibilityLabel("Neutrino")
    }
}

struct ChoiceCard: View {
    let title: String
    let detail: String
    let icon: String
    var selected = false
    let action: () -> Void
    @Environment(\.browserTheme) private var theme
    var body: some View {
        Button(action: action) {
            HStack(spacing: 14) {
                Image(systemName: icon).font(.system(size: 19)).foregroundStyle(theme.tint).frame(width: 28)
                VStack(alignment: .leading, spacing: 5) { Text(title).font(.system(size: 14, weight: .semibold)); Text(detail).font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
                Spacer(minLength: 10)
                Image(systemName: selected ? "checkmark.circle.fill" : "circle").foregroundStyle(selected ? theme.tint : .secondary)
            }.padding(16).frame(maxWidth: .infinity, alignment: .leading)
                .background(selected ? theme.tint.opacity(0.08) : theme.card, in: RoundedRectangle(cornerRadius: 14))
                .overlay(RoundedRectangle(cornerRadius: 14).stroke(selected ? theme.tint.opacity(0.5) : theme.foreground.opacity(0.08)))
        }.buttonStyle(.plain).accessibilityAddTraits(selected ? .isSelected : [])
    }
}
struct EmptyPanel: View {
    let title: String
    let icon: String
    let detail: String
    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: icon).font(.largeTitle).foregroundStyle(.secondary)
            Text(title).font(.headline)
            Text(detail).font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }.padding(24).frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
struct SheetHeader: View {
    let title: String
    let subtitle: String
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.system(size: 26, weight: .semibold))
            Text(subtitle).font(.callout).foregroundStyle(.secondary)
        }.frame(maxWidth: .infinity, alignment: .leading).padding(.bottom, 16)
    }
}

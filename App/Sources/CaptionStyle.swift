import CaptionSession
import SwiftUI
import UIKit

/// How captions look, resolved from settings and the system's own accessibility settings.
struct CaptionStyle {
    var settings: AppSettings
    var colorScheme: ColorScheme
    var systemHighContrast: Bool

    var highContrast: Bool {
        systemHighContrast || settings.theme == .highContrastLight
            || settings.theme == .highContrastDark
    }

    var background: Color {
        if highContrast { return colorScheme == .dark ? .black : .white }
        return Color(uiColor: .systemBackground)
    }

    var text: Color {
        if highContrast { return colorScheme == .dark ? .white : .black }
        return .primary
    }

    var secondaryText: Color {
        highContrast ? text : .secondary
    }

    /// The caption face: the size in settings, scaled by the system text size so a supporter's
    /// choice and the phone's Larger Text setting both count.
    func captionFont(scale: CGFloat = 1) -> Font {
        let weight: Font.Weight = settings.boldText || highContrast ? .semibold : .regular
        return .system(size: captionSize * scale, weight: weight, design: design)
    }

    /// Caption size for a column `width` points wide: no larger than fits about ten characters a
    /// line, so ordinary words are not broken in half on a phone held upright.
    func fitting(width: CGFloat) -> CaptionStyle {
        guard width > 0 else { return self }
        var style = self
        style.maxSize = width / 6
        return style
    }

    var maxSize: CGFloat = .infinity

    /// The caption size in points.
    ///
    /// The system's Larger Text setting adds to the size chosen here, but by at most half again,
    /// and never past the largest size the slider offers. Uncapped, the largest accessibility size
    /// triples a 34 pt caption to over 100 pt, where an ordinary word no longer fits across a phone
    /// and is broken in the middle — measured in the simulator, "Basketba / ll". Captions already
    /// start large; the size setting here is the control meant for them.
    var captionSize: CGFloat {
        let base = settings.textSize
        let scaled = UIFontMetrics(forTextStyle: .body).scaledValue(for: base)
        return min(max(base, min(scaled, base * 1.5)), AppSettings.textSizeRange.upperBound, maxSize)
    }

    var lineSpacing: CGFloat {
        captionSize * settings.lineSpacing
    }

    /// Space between paragraphs: half a line more than between their lines, so a new paragraph reads
    /// as one even without the break in the speaker bar, as in the simple view.
    var paragraphSpacing: CGFloat {
        lineSpacing + captionSize * 0.5
    }

    /// Further space above a new speaker's name, so a change of speaker stands out from one
    /// person's next paragraph.
    var speakerSpacing: CGFloat {
        captionSize * 0.4
    }

    var design: Font.Design {
        switch settings.typeface {
        case .standard: return .default
        case .rounded: return .rounded
        case .serif: return .serif
        }
    }

    /// One colour per speaker, from the Okabe–Ito palette, which stays distinguishable with the
    /// common colour-vision deficiencies. Colour is never the only cue: every change of speaker is
    /// also named in words.
    func speakerColor(_ number: Int?) -> Color {
        guard let number else { return secondaryText }
        let dark: [Color] = [
            Color(red: 0.90, green: 0.62, blue: 0.00),  // orange
            Color(red: 0.34, green: 0.71, blue: 0.91),  // sky blue
            Color(red: 0.00, green: 0.62, blue: 0.45),  // bluish green
            Color(red: 0.80, green: 0.47, blue: 0.65),  // reddish purple
            Color(red: 0.94, green: 0.89, blue: 0.26),  // yellow
        ]
        // Darker variants on light backgrounds, so the names keep their contrast against white.
        let light: [Color] = [
            Color(red: 0.70, green: 0.36, blue: 0.00),
            Color(red: 0.00, green: 0.45, blue: 0.70),
            Color(red: 0.00, green: 0.45, blue: 0.32),
            Color(red: 0.60, green: 0.25, blue: 0.45),
            Color(red: 0.50, green: 0.45, blue: 0.00),
        ]
        let palette = colorScheme == .dark ? dark : light
        return palette[(number - 1) % palette.count]
    }
}

private struct CaptionStyleKey: EnvironmentKey {
    static let defaultValue = CaptionStyle(settings: AppSettings(), colorScheme: .light,
                                           systemHighContrast: false)
}

extension EnvironmentValues {
    var captionStyle: CaptionStyle {
        get { self[CaptionStyleKey.self] }
        set { self[CaptionStyleKey.self] = newValue }
    }
}

/// Applies the theme's colour scheme, then publishes the resolved style to everything below.
private struct CaptionTheme: ViewModifier {
    let settings: AppSettings

    func body(content: Content) -> some View {
        content
            .modifier(ResolvedStyle(settings: settings))
            .preferredColorScheme(scheme)
    }

    private var scheme: ColorScheme? {
        switch settings.theme {
        case .system: return nil
        case .light, .highContrastLight: return .light
        case .dark, .highContrastDark: return .dark
        }
    }
}

private struct ResolvedStyle: ViewModifier {
    let settings: AppSettings
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var contrast
    // Read so the view re-resolves fonts when the system text size changes.
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    func body(content: Content) -> some View {
        content.environment(\.captionStyle, CaptionStyle(
            settings: settings, colorScheme: colorScheme,
            systemHighContrast: contrast == .increased))
    }
}

extension View {
    func captionTheme(_ settings: AppSettings) -> some View {
        modifier(CaptionTheme(settings: settings))
    }
}

import CaptionSession
import SwiftUI

/// Captions, one paragraph per turn, with the speaker named whenever it changes.
///
/// Live, it keeps the newest words in view until the reader scrolls back; then it stays put, and a
/// large "Back to now" button brings it back. Text that is being read never moves on its own.
struct TranscriptView: View {
    let lines: [CaptionLine]
    var live = false
    /// Open at the newest words rather than the first. True on the live screen even after Stop,
    /// where the last thing said is what the reader was looking at.
    var anchoredToEnd = false
    /// No scrolling at all: the newest words stay in view whatever the reader does.
    var lockedToEnd = false
    var showSpeakers = true
    /// Tap on a speaker's name. Nil when names cannot be changed from here.
    var onTapSpeaker: ((CaptionLine) -> Void)?

    @Environment(\.captionStyle) private var baseStyle
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var width: CGFloat = 0
    @State private var following = true
    @State private var jumpToEnd = 0

    /// The text column: the view less its margins and the speaker bar, at most 900 points.
    private var style: CaptionStyle {
        baseStyle.fitting(width: min(width, 900) - 40 - (showSpeakers ? 18 : 0))
    }

    var body: some View {
        CaptionList(
            lines: lines, live: live, anchoredToEnd: anchoredToEnd, locked: lockedToEnd,
            showSpeakers: showSpeakers, style: style,
            styleKey: .init(settings: baseStyle.settings, colorScheme: baseStyle.colorScheme,
                            systemHighContrast: baseStyle.systemHighContrast,
                            dynamicTypeSize: dynamicTypeSize, width: width, showSpeakers: showSpeakers),
            animated: !reduceMotion, onTapSpeaker: onTapSpeaker,
            onFollowingChange: { following = $0 }, jumpToEnd: jumpToEnd)
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
        .overlay(alignment: .bottom) {
            if live, !following, !lines.isEmpty {
                Button {
                    jumpToEnd += 1
                } label: {
                    Label("Back to now", systemImage: "arrow.down")
                        .font(style.captionFont(scale: 0.6).weight(.semibold))
                        .padding(.horizontal, 24)
                        .padding(.vertical, 14)
                }
                .buttonStyle(.borderedProminent)
                .buttonBorderShape(.capsule)
                .padding(.bottom, 12)
                .accessibilityIdentifier("backToNow")
            }
        }
    }
}

/// One turn: the speaker's name when it changes, a bar in their colour, and what they said.
struct CaptionParagraph: View {
    let line: CaptionLine
    /// The first paragraph shown, which needs no space above its name.
    let first: Bool
    let showSpeakers: Bool
    let style: CaptionStyle
    var onTapSpeaker: ((CaptionLine) -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if showSpeakers, line.startsNewSpeaker {
                speakerHeader
                    .padding(.top, first ? 0 : 18)
            }
            HStack(alignment: .top, spacing: 12) {
                if showSpeakers {
                    RoundedRectangle(cornerRadius: 3)
                        .fill(style.speakerColor(line.speakerNumber))
                        .frame(width: 6)
                        .accessibilityHidden(true)
                }
                Text(line.isOpen ? line.text + " …" : line.text)
                    .font(style.captionFont())
                    .lineSpacing(style.lineSpacing)
                    .foregroundStyle(style.text)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
            }
            .padding(.bottom, 10)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(showSpeakers ? "\(line.label): \(line.text)" : line.text)
    }

    private var speakerHeader: some View {
        let header = HStack(spacing: 8) {
            Circle()
                .fill(style.speakerColor(line.speakerNumber))
                .frame(width: 14, height: 14)
            Text(line.label)
                .font(style.captionFont(scale: 0.6).weight(.bold))
                .foregroundStyle(style.speakerColor(line.speakerNumber))
            if line.contested {
                Text("· two people talking")
                    .font(style.captionFont(scale: 0.5))
                    .foregroundStyle(style.secondaryText)
            }
        }
        return Group {
            if let onTapSpeaker, line.speaker != nil {
                Button { onTapSpeaker(line) } label: { header }
                    .buttonStyle(.plain)
                    .accessibilityHint("Change this speaker's name")
            } else {
                header
            }
        }
    }
}

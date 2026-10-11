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
    @State private var width: CGFloat = 0

    /// The text column: the view less its margins and the speaker bar, at most 900 points.
    private var style: CaptionStyle {
        baseStyle.fitting(width: min(width, 900) - 40 - (showSpeakers ? 18 : 0))
    }

    @State private var position = ScrollPosition(edge: .bottom)
    @State private var following = true
    @State private var atBottom = true
    @State private var userScrolling = false

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(lines) { line in
                    paragraph(line)
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 16)
            .frame(maxWidth: 900, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
        .scrollPosition($position)
        .scrollDisabled(lockedToEnd)
        .onChange(of: lockedToEnd) { _, locked in
            // Locking while scrolled back would otherwise leave the reader stranded there.
            if locked {
                following = true
                scrollToEnd()
            }
        }
        .defaultScrollAnchor(anchoredToEnd ? .bottom : .top)
        // When the screen around the captions changes size — a button appearing below them, the
        // phone turning — keep the newest words in view rather than the oldest.
        .defaultScrollAnchor(anchoredToEnd ? .bottom : .top, for: .sizeChanges)
        .onScrollGeometryChange(for: Bool.self) { geometry in
            geometry.contentOffset.y + geometry.containerSize.height
                >= geometry.contentSize.height - 60
        } action: { _, isAtBottom in
            atBottom = isAtBottom
            if userScrolling { following = isAtBottom }
        }
        .onScrollPhaseChange { old, new in
            // Only the reader's own scrolling decides whether to follow. Content growing while
            // nobody touches the screen is not the reader leaving the bottom.
            let byHand: [ScrollPhase] = [.tracking, .interacting, .decelerating]
            userScrolling = byHand.contains(new)
            if new == .idle, byHand.contains(old) { following = atBottom }
        }
        .onChange(of: lines) {
            guard live, following else { return }
            scrollToEnd()
        }
        .overlay(alignment: .bottom) {
            if live, !following, !lines.isEmpty {
                Button {
                    following = true
                    scrollToEnd()
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

    private func scrollToEnd() {
        if reduceMotion {
            position.scrollTo(edge: .bottom)
        } else {
            withAnimation(.easeOut(duration: 0.2)) { position.scrollTo(edge: .bottom) }
        }
    }

    @ViewBuilder
    private func paragraph(_ line: CaptionLine) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            if showSpeakers, line.startsNewSpeaker {
                speakerHeader(line)
                    .padding(.top, line.id == lines.first?.id ? 0 : 18)
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

    private func speakerHeader(_ line: CaptionLine) -> some View {
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

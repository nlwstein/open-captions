import CaptionSession
import SwiftUI

/// What the app knows about itself: the dedication, the changelog, the version.
enum About {
    /// `Dedication.md` with its comments removed, or nil while nothing has been written.
    static let dedication: String? = {
        guard let url = Bundle.main.url(forResource: "Dedication", withExtension: "md"),
              let text = try? String(contentsOf: url, encoding: .utf8)
        else { return nil }
        let stripped = text.replacing(#/<!--[\s\S]*?-->/#, with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return stripped.isEmpty ? nil : stripped
    }()

    /// Written into the bundle by the build; see `Scripts/make-changelog.sh`.
    static let changelog: Changelog = {
        Bundle.main.url(forResource: "changelog", withExtension: "txt")
            .flatMap(Changelog.load) ?? Changelog(entries: [])
    }()

    /// "0.1 (03429dd)": the version, and the commit it was built from.
    static var version: String {
        let short = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
        return changelog.buildCommit.map { "\(short) (\($0))" } ?? short
    }
}

struct DedicationView: View {
    let text: String

    @Environment(\.captionStyle) private var style

    var body: some View {
        ScrollView {
            VStack(spacing: 28) {
                Image(systemName: "heart.fill")
                    .font(.system(size: 44))
                    .foregroundStyle(.pink)
                    .accessibilityHidden(true)
                ForEach(Array(paragraphs.enumerated()), id: \.offset) { _, paragraph in
                    Text(paragraph)
                        .font(.system(.title2, design: .serif))
                        .lineSpacing(6)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(32)
            .frame(maxWidth: 640)
            .frame(maxWidth: .infinity)
        }
        .defaultScrollAnchor(.center, for: .alignment)
        .defaultScrollAnchor(.top, for: .initialOffset)
        .navigationTitle("Dedication")
        .navigationBarTitleDisplayMode(.inline)
    }

    /// Blank lines separate paragraphs; inside one, Markdown emphasis is honoured.
    private var paragraphs: [AttributedString] {
        text.components(separatedBy: "\n\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .map { paragraph in
                (try? AttributedString(markdown: paragraph,
                                       options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
                    ?? AttributedString(paragraph)
            }
    }
}

/// The changelog, newest first. Things someone using the app would notice by default; the rest of
/// the project's history one switch away.
struct ChangelogView: View {
    let changelog: Changelog

    @State private var showingAll = false

    var body: some View {
        List {
            Section {
                Toggle("Show every change", isOn: $showingAll)
            } footer: {
                Text("Off: only new features and fixes. On: documentation, tests and housekeeping too.")
            }
            let days = changelog.days(includingAll: showingAll)
            if days.isEmpty {
                Text("This build has no changelog.")
                    .foregroundStyle(.secondary)
            }
            ForEach(days) { day in
                Section(day.date.formatted(date: .complete, time: .omitted)) {
                    ForEach(day.groups) { group in
                        VStack(alignment: .leading, spacing: 8) {
                            Text(group.kind.heading)
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(color(group.kind))
                            ForEach(group.entries) { entry in
                                row(entry)
                            }
                        }
                        .padding(.vertical, 4)
                    }
                }
            }
        }
        .navigationTitle("What's new")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func row(_ entry: Changelog.Entry) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(entry.summary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 6) {
                if entry.breaking {
                    Text("Changes how something works").foregroundStyle(.orange)
                }
                if let scope = entry.scope { Text(scope) }
                Text(entry.shortHash).monospaced()
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
    }

    private func color(_ kind: Changelog.Kind) -> Color {
        switch kind {
        case .feat: return .accentColor
        case .fix: return .green
        case .perf: return .orange
        default: return .secondary
        }
    }
}

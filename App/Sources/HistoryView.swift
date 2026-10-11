import CaptionSession
import SwiftUI

/// Past conversations, newest first, each named the way a person would say when it happened.
struct HistoryView: View {
    let assistive: Bool
    @Environment(AppModel.self) private var model
    @Environment(\.captionStyle) private var style
    @State private var query = ""

    private var simple: Bool { model.settings.simpleMode || assistive }

    private var sessions: [SavedSession] {
        model.history.filter { $0.matches(query) }
    }

    var body: some View {
        List {
            if model.history.isEmpty {
                Text("No conversations yet. They are kept here after you press Stop.")
                    .font(style.captionFont(scale: 0.6))
                    .foregroundStyle(style.secondaryText)
                    .listRowBackground(Color.clear)
            }
            ForEach(sessions) { session in
                NavigationLink(value: AppModel.Route.transcript(session.id)) {
                    row(session)
                }
                .accessibilityIdentifier("historyRow")
                // Deleting is a supporter's job; in simple mode a stray swipe must not lose a
                // conversation.
                .deleteDisabled(simple)
            }
            .onDelete { offsets in
                for index in offsets { model.delete(sessions[index].id) }
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(style.background.ignoresSafeArea())
        .searchable(text: $query, prompt: "Find a word")
        .navigationTitle("Past conversations")
        .onAppear { model.reloadHistory() }
    }

    private func row(_ session: SavedSession) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(SessionTitle.make(for: session.startedAt))
                .font(style.captionFont(scale: 0.7).weight(.semibold))
                .foregroundStyle(style.text)
            Text(summary(session))
                .font(style.captionFont(scale: 0.5))
                .foregroundStyle(style.secondaryText)
            if let first = session.turns.first(where: { !$0.text.isEmpty }) {
                Text(first.text)
                    .font(style.captionFont(scale: 0.5))
                    .foregroundStyle(style.secondaryText)
                    .lineLimit(2)
            }
        }
        .padding(.vertical, 8)
    }

    private func summary(_ session: SavedSession) -> String {
        let time = session.startedAt.formatted(date: .omitted, time: .shortened)
        let minutes = max(1, Int((session.duration / 60).rounded()))
        let people = Set(session.turns.compactMap(\.speaker)).count
        var parts = [time, "\(minutes) min"]
        if people > 1 { parts.append("\(people) people") }
        if session.endedAt == nil, model.live.session?.id != session.id {
            parts.append("cut short")
        }
        return parts.joined(separator: " · ")
    }
}

/// One past conversation, to read back, search, name the speakers in, and share.
struct TranscriptScreen: View {
    let id: UUID
    let assistive: Bool
    @Environment(AppModel.self) private var model
    @Environment(\.captionStyle) private var style
    @Environment(\.dismiss) private var dismiss
    @State private var renaming: CaptionLine?
    @State private var newName = ""
    @State private var confirmingDelete = false

    private var simple: Bool { model.settings.simpleMode || assistive }

    /// Punctuation, as on the live screen. Reading `revision` redraws as paragraphs are done.
    private var format: CaptionLines.Format {
        let formatter = model.live.formatter
        _ = formatter.revision
        return { formatter.formatted($0, closed: $1) }
    }

    var body: some View {
        Group {
            if let session = model.session(id) {
                TranscriptView(lines: CaptionLines.make(turns: session.turns, names: session.names,
                                                        format: format),
                               showSpeakers: model.settings.showSpeakers,
                               onTapSpeaker: simple ? nil : { line in
                                   newName = session.names[line.speaker ?? -1] ?? ""
                                   renaming = line
                               })
                .navigationTitle(SessionTitle.make(for: session.startedAt))
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        ShareLink(item: TranscriptExport.plainText(session, format: format)) {
                            Label("Share", systemImage: "square.and.arrow.up")
                        }
                    }
                    if !simple {
                        ToolbarItem(placement: .topBarTrailing) {
                            Button(role: .destructive) { confirmingDelete = true } label: {
                                Label("Delete", systemImage: "trash")
                            }
                        }
                    }
                }
            } else {
                Text("This conversation was deleted.")
                    .font(style.captionFont(scale: 0.7))
            }
        }
        .background(style.background.ignoresSafeArea())
        .alert("Name this speaker", isPresented: Binding(get: { renaming != nil },
                                                          set: { if !$0 { renaming = nil } })) {
            TextField("Name", text: $newName).textInputAutocapitalization(.words)
            Button("Save") {
                if let speaker = renaming?.speaker { model.rename(speaker: speaker, to: newName, in: id) }
            }
            Button("Cancel", role: .cancel) {}
        }
        .confirmationDialog("Delete this conversation?", isPresented: $confirmingDelete,
                            titleVisibility: .visible) {
            Button("Delete", role: .destructive) {
                dismiss()
                model.delete(id)
            }
        }
    }
}

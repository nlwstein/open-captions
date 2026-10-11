import CaptionKit
import Foundation
import Observation

/// Punctuates paragraphs in the background and remembers the result.
///
/// The screen asks for a paragraph's text with ``formatted(_:closed:)``. The first time, that
/// answers nil — the screen shows the engine's text as it is — and the paragraph is queued; when
/// it is done, ``revision`` changes and the screen asks again. So the newest words are never held
/// back waiting for punctuation, and a paragraph can be re-punctuated as it grows: a full stop
/// written before the speaker went on may become a comma once the rest of the sentence arrives.
///
/// Without a model — none bundled, or it would not load — every answer is nil and captions read
/// exactly as the engine wrote them.
@MainActor
@Observable
public final class CaptionFormatter {
    /// Changes whenever a newly punctuated paragraph is ready.
    public private(set) var revision = 0

    @ObservationIgnored private var done: [Key: String] = [:]
    @ObservationIgnored private var queued: [Key] = []
    @ObservationIgnored private var queuedSet: Set<Key> = []
    @ObservationIgnored private var worker: Task<Void, Never>?
    @ObservationIgnored private var punctuator: Punctuator?
    @ObservationIgnored private var loading: Task<Punctuator?, Never>?
    @ObservationIgnored private let load: @Sendable () -> Punctuator?
    @ObservationIgnored private var unavailable = false

    struct Key: Hashable {
        var turns: [String]
        var closed: Bool
    }

    /// More finished paragraphs than any one conversation shows; past this, results nobody has
    /// asked for since the last trim are dropped.
    private static let keep = 4_000
    @ObservationIgnored private var asked: Set<Key> = []

    /// - Parameter load: Loads the model, off the main thread, the first time a paragraph is asked
    ///   for. Nil means no punctuation.
    public init(load: @escaping @Sendable () -> Punctuator?) {
        self.load = load
    }

    /// A formatter that never punctuates.
    public static func none() -> CaptionFormatter { CaptionFormatter { nil } }

    /// The model bundled with the app, if there is one: `Punctuation.mlmodelc` and
    /// `vocabulary.tsv` in the main bundle, from `Scripts/make-punctuation-model.sh`.
    public static func bundled(_ bundle: Bundle = .main) -> CaptionFormatter {
        let directory = bundle.resourceURL
        return CaptionFormatter {
            guard let directory else { return nil }
            return try? Punctuator.load(directory: directory)
        }
    }

    /// The punctuated text of one speaker's turns, or nil until it is ready.
    ///
    /// - Parameter closed: The speaker has finished this paragraph, so its last word ends a
    ///   sentence.
    public func formatted(_ turns: [String], closed: Bool) -> String? {
        guard !unavailable else { return nil }
        let key = Key(turns: turns, closed: closed)
        asked.insert(key)
        if let text = done[key] { return text }
        if !queuedSet.contains(key) {
            queued.append(key)
            queuedSet.insert(key)
            startWorking()
        }
        return nil
    }

    private func startWorking() {
        guard worker == nil else { return }
        worker = Task { [weak self] in
            while true {
                guard let self, let key = self.nextKey() else { break }
                guard let punctuator = await self.model() else {
                    // No model: nothing will ever be punctuated, so stop asking.
                    self.queued.removeAll()
                    self.queuedSet.removeAll()
                    self.unavailable = true
                    break
                }
                let text = await Task.detached(priority: .utility) {
                    Self.format(key, with: punctuator)
                }.value
                self.queuedSet.remove(key)
                self.done[key] = text
                self.trim()
                self.revision &+= 1
            }
            self?.worker = nil
        }
    }

    /// Newest first: the paragraph being spoken matters more than an old one scrolled past.
    private func nextKey() -> Key? {
        queued.popLast()
    }

    private func model() async -> Punctuator? {
        if let punctuator { return punctuator }
        if loading == nil {
            let load = self.load
            loading = Task.detached(priority: .utility) { load() }
        }
        punctuator = await loading?.value
        return punctuator
    }

    private func trim() {
        guard done.count > Self.keep else { return }
        done = done.filter { asked.contains($0.key) }
        asked.removeAll()
    }

    nonisolated private static func format(_ key: Key, with punctuator: Punctuator) -> String {
        let words = ParagraphFormatter.words(in: key.turns).words
        guard let labels = try? punctuator.label(words) else { return key.turns.joined(separator: " ") }
        return ParagraphFormatter.format(turns: key.turns, labels: labels, closed: key.closed)
    }
}

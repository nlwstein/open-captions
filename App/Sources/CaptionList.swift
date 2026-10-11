import CaptionSession
import ChatLayout
import SwiftUI
import UIKit

/// The captions as a collection view: only the paragraphs on screen exist as views, and the
/// newest one can grow without the screen jumping.
///
/// SwiftUI's lazy stack was tried first and could not do both. It guesses the height of the
/// paragraphs it has not built, and when a guess was corrected while the captions were growing,
/// the scroll offset was left past the end of the text and the screen went blank. A plain stack
/// avoids that by building every paragraph, which a conversation of several hours cannot afford.
/// `CollectionViewChatLayout` is a layout for exactly this case: it measures the cells it shows,
/// keeps the bottom where it is while following, and the top where it is while someone reads back.
struct CaptionList: UIViewRepresentable {
    var lines: [CaptionLine]
    var live: Bool
    var anchoredToEnd: Bool
    var locked: Bool
    var showSpeakers: Bool
    var style: CaptionStyle
    /// Whatever the paragraphs' look depends on; a change re-measures every paragraph.
    var styleKey: StyleKey
    var animated: Bool
    var onTapSpeaker: ((CaptionLine) -> Void)?
    /// Set from here when the reader scrolls away from the newest words or back to them.
    var onFollowingChange: (Bool) -> Void
    /// Bumped by the owner to bring the newest words back into view.
    var jumpToEnd: Int

    struct StyleKey: Equatable {
        var settings: AppSettings
        var colorScheme: ColorScheme
        var systemHighContrast: Bool
        var dynamicTypeSize: DynamicTypeSize
        var width: CGFloat
        var showSpeakers: Bool
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> UICollectionView {
        context.coordinator.makeView()
    }

    func updateUIView(_ view: UICollectionView, context: Context) {
        context.coordinator.update(self)
    }

    @MainActor
    final class Coordinator: NSObject, UICollectionViewDelegate, ChatLayoutDelegate {
        private var parent: CaptionList?
        private let layout = CollectionViewChatLayout()
        private var collectionView: CaptionCollectionView!
        private var dataSource: ChatLayoutDiffableDataSource<Int, Int>!

        private var lines: [Int: CaptionLine] = [:]
        private var order: [Int] = []
        private var styleKey: StyleKey?
        private var following = true
        private var wasLocked = false
        private var jumpToEnd = 0
        private var placedInitially = false

        func makeView() -> UICollectionView {
            layout.delegate = self
            layout.settings.estimatedItemSize = CGSize(width: 300, height: 120)
            layout.settings.interItemSpacing = 0
            layout.settings.additionalInsets = UIEdgeInsets(top: 16, left: 20, bottom: 16, right: 20)
            layout.keepContentOffsetAtBottomOnBatchUpdates = true

            let view = CaptionCollectionView(frame: .zero, collectionViewLayout: layout)
            view.backgroundColor = .clear
            view.alwaysBounceVertical = true
            view.showsHorizontalScrollIndicator = false
            // The SwiftUI frame around this is already inside the safe area.
            view.contentInsetAdjustmentBehavior = .never
            view.delegate = self
            view.register(CaptionCell.self, forCellWithReuseIdentifier: CaptionCell.reuseIdentifier)
            view.onResize = { [weak self] in self?.resized() }
            collectionView = view

            dataSource = ChatLayoutDiffableDataSource(collectionView: view) { [weak self] view, indexPath, id in
                let cell = view.dequeueReusableCell(withReuseIdentifier: CaptionCell.reuseIdentifier,
                                                    for: indexPath)
                self?.configure(cell, id: id)
                return cell
            }
            return view
        }

        func update(_ parent: CaptionList) {
            self.parent = parent

            // Wider than 900 points, the text column stays 900 wide and centred.
            let width = parent.styleKey.width
            let side = max(20, (width - 900) / 2 + 20)
            if layout.settings.additionalInsets.left != side {
                layout.settings.additionalInsets = UIEdgeInsets(top: 16, left: side, bottom: 16, right: side)
            }

            collectionView.isScrollEnabled = !parent.locked
            if parent.locked, !wasLocked {
                // Locking while scrolled back would otherwise leave the reader stranded there.
                setFollowing(true)
                scrollToEnd(animated: parent.animated)
            }
            wasLocked = parent.locked

            if parent.jumpToEnd != jumpToEnd {
                jumpToEnd = parent.jumpToEnd
                setFollowing(true)
                scrollToEnd(animated: parent.animated)
            }

            let restyled = styleKey != nil && styleKey != parent.styleKey
            styleKey = parent.styleKey
            apply(parent.lines, reloadingAll: restyled)
        }

        // MARK: - Data

        private func apply(_ newLines: [CaptionLine], reloadingAll: Bool) {
            let newOrder = newLines.map(\.id)
            var changed: [Int] = []
            var byID: [Int: CaptionLine] = [:]
            byID.reserveCapacity(newLines.count)
            for line in newLines {
                byID[line.id] = line
                if let old = lines[line.id], old != line { changed.append(line.id) }
            }
            // Only the last few lines change from one update to the next; nothing else is touched.
            guard reloadingAll || newOrder != order || !changed.isEmpty || !placedInitially else { return }

            var snapshot = NSDiffableDataSourceSnapshot<Int, Int>()
            snapshot.appendSections([0])
            snapshot.appendItems(newOrder, toSection: 0)
            let commit = { [weak self] in
                self?.lines = byID
                self?.order = newOrder
            }

            if reloadingAll || !placedInitially {
                dataSource.applySnapshotUsingReloadData(snapshot, commitAlongsideUpdates: commit)
                placeAfterReload()
                return
            }
            snapshot.reconfigureItems(changed.filter { order.contains($0) && newOrder.contains($0) })
            dataSource.apply(snapshot, animatingDifferences: false, commitAlongsideUpdates: commit) { [weak self] in
                guard let self, let parent, parent.live, following else { return }
                scrollToEnd(animated: false)
            }
        }

        /// Where to be after everything was measured afresh: at the newest words when following,
        /// or at the start for a saved conversation opened from the top.
        private func placeAfterReload() {
            guard let parent, !order.isEmpty else { return }
            collectionView.layoutIfNeeded()
            if !placedInitially {
                placedInitially = true
                if parent.anchoredToEnd { scrollToEnd(animated: false) }
            } else if following, parent.anchoredToEnd || parent.live {
                scrollToEnd(animated: false)
            }
        }

        private func configure(_ cell: UICollectionViewCell, id: Int) {
            guard let parent, let line = lines[id] else { return }
            let first = id == order.first
            cell.contentConfiguration = UIHostingConfiguration {
                CaptionParagraph(line: line, first: first, showSpeakers: parent.showSpeakers,
                                 style: parent.style, onTapSpeaker: parent.onTapSpeaker)
            }
            .margins(.all, 0)
            cell.backgroundConfiguration = .clear()
        }

        // MARK: - Following

        private var isAtBottom: Bool {
            let view = collectionView!
            return view.contentOffset.y + view.bounds.height - view.adjustedContentInset.bottom
                >= layout.collectionViewContentSize.height - 60
        }

        private func setFollowing(_ value: Bool) {
            // Following: growth below pushes the text up, keeping the newest words in view.
            // Reading back: the top stays put, so the words being read do not move.
            layout.keepContentOffsetAtBottomOnBatchUpdates = value
            guard value != following else { return }
            following = value
            let report = parent?.onFollowingChange
            // Not during SwiftUI's update of this view.
            DispatchQueue.main.async { report?(value) }
        }

        private func scrollToEnd(animated: Bool) {
            guard let view = collectionView, !order.isEmpty else { return }
            let visible = view.bounds.height - view.adjustedContentInset.top - view.adjustedContentInset.bottom
            // Shorter than the screen: it starts at the top, like a page.
            guard layout.collectionViewContentSize.height > visible else { return }
            let last = ChatLayoutPositionSnapshot(indexPath: IndexPath(item: order.count - 1, section: 0),
                                                  edge: .bottom)
            if animated {
                UIView.animate(withDuration: 0.2, delay: 0, options: [.curveEaseOut, .allowUserInteraction]) {
                    self.layout.restoreContentOffset(with: last)
                }
            } else {
                layout.restoreContentOffset(with: last)
            }
        }

        /// The phone turning, or a button appearing below the captions: keep the newest words in
        /// view rather than whatever happened to be at the top.
        private func resized() {
            guard following, parent?.anchoredToEnd == true || parent?.live == true else { return }
            scrollToEnd(animated: false)
        }

        // MARK: - Scrolling by hand

        // Only the reader's own scrolling decides whether to follow. Content growing while nobody
        // touches the screen is not the reader leaving the bottom.
        func scrollViewDidScroll(_ scrollView: UIScrollView) {
            guard scrollView.isTracking || scrollView.isDragging || scrollView.isDecelerating else { return }
            setFollowing(isAtBottom)
        }

        func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
            if !decelerate { setFollowing(isAtBottom) }
        }

        func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) {
            setFollowing(isAtBottom)
        }

        func scrollViewShouldScrollToTop(_ scrollView: UIScrollView) -> Bool {
            !(parent?.locked ?? false)
        }

        // MARK: - ChatLayoutDelegate

        func alignmentForItem(_ chatLayout: CollectionViewChatLayout, at indexPath: IndexPath) -> ChatItemAlignment {
            .fullWidth
        }
    }
}

/// Says when its size changes, which UIKit otherwise only tells the view itself.
final class CaptionCollectionView: UICollectionView {
    var onResize: (() -> Void)?
    private var lastSize: CGSize = .zero

    override func layoutSubviews() {
        super.layoutSubviews()
        guard bounds.size != lastSize else { return }
        let first = lastSize == .zero
        lastSize = bounds.size
        if !first { onResize?() }
    }
}

/// A paragraph, measured at the width the layout gives it.
final class CaptionCell: UICollectionViewCell {
    static let reuseIdentifier = "caption"

    override func preferredLayoutAttributesFitting(
        _ layoutAttributes: UICollectionViewLayoutAttributes
    ) -> UICollectionViewLayoutAttributes {
        let attributes = layoutAttributes.copy() as! UICollectionViewLayoutAttributes
        let width = layoutAttributes.size.width
        let size = contentView.systemLayoutSizeFitting(
            CGSize(width: width, height: UIView.layoutFittingCompressedSize.height),
            withHorizontalFittingPriority: .required,
            verticalFittingPriority: .fittingSizeLevel)
        attributes.size = CGSize(width: width, height: ceil(size.height))
        return attributes
    }
}

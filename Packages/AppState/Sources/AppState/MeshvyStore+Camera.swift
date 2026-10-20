import AppKit
import Foundation
import SwiftUI
import MeshvyModels

// Framing the board: fit, reveal, zoom.
extension MeshvyStore {
    // MARK: - Camera

    @discardableResult
    public func fit() -> Bool {
        guard viewport.hasSize, let rect = graph.contentRect, !rect.isEmpty else { return false }
        viewport.fit(rect)
        persistLayout()
        return true
    }

    public func fitIfNeeded() {
        guard !hasFitInitially else { return }
        if fit() { hasFitInitially = true }
    }

    public func zoom(by factor: CGFloat) {
        viewport.zoom(to: viewport.scale * factor, anchor: viewport.screenCenter)
        persistLayout()
    }

    public func zoomToActualSize() {
        viewport.zoom(to: 1, anchor: viewport.screenCenter)
        persistLayout()
    }

    /// Frames whatever is selected. On a board bigger than the screen this is
    /// the quickest way back to the thing you were working on, and it is what
    /// every other canvas binds to the same key.
    public func zoomToSelection() {
        // `boardNode(for:)` and not `graph.node`: a repository has no node of
        // its own — it is a chip on the workspace node — so looking it up in
        // the graph finds nothing, and an empty selection would quietly frame
        // the whole board instead of the thing you selected.
        let frames = selected.compactMap { boardNode(for: $0)?.frame }
        guard let rect = CGRect.bounding(frames.isEmpty ? graph.nodes.map(\.frame) : frames) else { return }
        withAnimation(.easeOut(duration: 0.25)) { viewport.fit(rect, margin: 120) }
        persistLayout()
    }

    public func focusMatches() {
        let targets = isSearching ? graph.nodes.filter { matches($0.id) } : graph.nodes
        guard let rect = CGRect.bounding(targets.map(\.frame)) else { return }
        withAnimation(.easeOut(duration: 0.25)) { viewport.fit(rect, margin: 140) }
        persistLayout()
    }

    public func reveal(_ id: NodeID) {
        guard let node = boardNode(for: id) else { return }
        withAnimation(.easeOut(duration: 0.25)) {
            viewport.scale = max(viewport.scale, 0.8)
            viewport.center = node.frame.center
        }
        selection = id
        markRead(id)
        if case .session(let sessionID) = id { loadTranscript(sessionID) }
    }
}

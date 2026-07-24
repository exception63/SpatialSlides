//
//  PresentationModel.swift
//  Spatial Slides
//
//  The one engine. A show is one HTML deck + per-page spatial sidecar; everything
//  hangs off `currentPage`. Changing the page (carousel drag, control bar, or a
//  tap) drives the far HTML (deckAPI.setActive), the near spatial elements, and
//  the transcript — all in sync. In edit mode the near elements are placed by hand
//  and saved back to show.json.
//

import SwiftUI
import simd

@MainActor
@Observable
final class PresentationModel {
    var show: Show
    var currentPage: Int = 0
    /// Bumped whenever the show is replaced, so the stage rebuilds from scratch.
    private(set) var version: Int = 0

    // MARK: Editing (near-field elements)
    var isEditing = false
    var selectedElementID: String?
    private(set) var hasUnsavedEdits = false

    /// When on, the carousel itself is being repositioned (grab it to move the whole
    /// wheel); its scroll/tap navigation is suspended until turned off.
    var carouselAdjust = false

    /// HTML "motion" mode. Off (default) → the far deck is dampened and uses the fast
    /// switcher for smooth immersive navigation; on → the deck keeps its build animations
    /// (via deckAPI), for rehearsal/recording where frame drops are acceptable. See HTMLPanel.
    var motionMode = false

    /// Stepless model resize from the remote's slider. `modelScaleSlider` (0…1) maps
    /// exponentially to an absolute scale; dragging it bumps `modelScaleAbsNonce` and
    /// the stage sets the active model to `modelScaleAbs`. When a different model
    /// becomes active (tapped in the headset, or just pinch-scaled), the stage calls
    /// `syncModelScaleSlider` so the slider follows without re-applying.
    static let modelScaleMin: Float = 0.02
    static let modelScaleMax: Float = 2.5
    var modelScaleSlider: Double = 0.5
    private(set) var modelScaleAbs: Float = 0.15
    private(set) var modelScaleAbsNonce = 0
    private(set) var modelScaleCommitNonce = 0
    /// Called from the slider while the user is dragging it → drive the active model.
    func applyModelScaleSlider() {
        modelScaleAbs = Self.scale(fromSlider: modelScaleSlider)
        modelScaleAbsNonce += 1
    }
    func finishModelScaleAdjustment() { modelScaleCommitNonce += 1 }
    /// Called by the stage when the active model changes → move the slider to match
    /// (the remote's `onChange` ignores this because the user isn't dragging).
    func syncModelScaleSlider(toScale s: Float) { modelScaleSlider = Self.slider(fromScale: s) }
    static func scale(fromSlider t: Double) -> Float {
        modelScaleMin * powf(modelScaleMax / modelScaleMin, Float(min(max(t, 0), 1)))
    }
    static func slider(fromScale s: Float) -> Double {
        let c = min(max(s, modelScaleMin), modelScaleMax)
        return Double(logf(c / modelScaleMin) / logf(modelScaleMax / modelScaleMin))
    }

    /// The full-immersion 3D environment to load, if any: the show's configured scene,
    /// or a `environment.usdz` dropped beside show.json. Nil → keep the plain dark dome.
    var environmentSpec: ResolvedEnvironment? {
        if let env = show.environment, let url = DeckLoader.assetURL(env.asset) {
            return ResolvedEnvironment(url: url, scale: env.scale, position: env.position, yaw: env.yaw)
        }
        if let url = DeckLoader.assetURL("environment.usdz") {
            return ResolvedEnvironment(url: url, scale: 1, position: .zero, yaw: 0)
        }
        return nil
    }

    var hasEnvironment: Bool { environmentSpec != nil }

    /// In-headset fit for the 3D environment: the remote nudges scale/position/yaw,
    /// which update `show.environment` (persisted on save) and bump `envNonce` so the
    /// stage re-fits the loaded scene live. Lets you size an arbitrary USDZ to the room.
    private(set) var envNonce = 0
    private func ensureEnv() { if show.environment == nil { show.environment = EnvironmentConfig() } }
    func nudgeEnvScale(_ factor: Float) {
        ensureEnv(); show.environment!.scale = min(max(show.environment!.scale * factor, 0.02), 50)
        envNonce += 1; hasUnsavedEdits = true
    }
    func nudgeEnvHeight(_ dy: Float) { ensureEnv(); show.environment!.position.y += dy; envNonce += 1; hasUnsavedEdits = true }
    func nudgeEnvDepth(_ dz: Float) { ensureEnv(); show.environment!.position.z += dz; envNonce += 1; hasUnsavedEdits = true }
    func nudgeEnvYaw(_ dr: Float) { ensureEnv(); show.environment!.yaw += dr; envNonce += 1; hasUnsavedEdits = true }

    var currentHasModel: Bool { currentElements.contains { $0.kind == .model } }
    /// How many 3D models are on this page (>1 → the remote hints to tap-to-pick one).
    var currentModelCount: Int { currentElements.filter { $0.kind == .model }.count }
    /// Move the slider to the first model's authored scale when the page changes.
    func syncSliderToPageModel() {
        if let m = currentElements.first(where: { $0.kind == .model }) {
            modelScaleSlider = Self.slider(fromScale: m.transform?.scale ?? m.modelScale)
        }
    }

    /// Presenter-tunable transcript type size (讲稿字号 ±). Every size on the native
    /// transcript board is multiplied by this, so the whole board scales together.
    private(set) var transcriptScale: CGFloat = 1.15
    func nudgeTranscriptScale(_ delta: CGFloat) {
        transcriptScale = min(max(transcriptScale + delta, 0.8), 2.2)
    }

    /// Live resize of the far HTML board (a reliable alternative to two-handed pinch,
    /// which is finicky). Only meaningful in edit mode.
    private(set) var deckScaleNonce = 0
    private(set) var deckScaleFactor: Float = 1
    func nudgeDeckScale(_ factor: Float) { deckScaleFactor = factor; deckScaleNonce += 1 }

    /// Transcript board resize + re-facing (from the remote). One nonce carries either a
    /// scale factor (yaw 0) or a yaw delta (factor 1); the stage applies whichever is set.
    private(set) var transcriptBoardNonce = 0
    private(set) var transcriptBoardScaleFactor: Float = 1
    private(set) var transcriptBoardYaw: Float = 0
    func nudgeTranscriptBoardScale(_ factor: Float) { transcriptBoardScaleFactor = factor; transcriptBoardYaw = 0; transcriptBoardNonce += 1 }
    func nudgeTranscriptBoardYaw(_ delta: Float) { transcriptBoardScaleFactor = 1; transcriptBoardYaw = delta; transcriptBoardNonce += 1 }

    /// Right reference board (asides) resize + re-facing — mirror of the transcript board
    /// controls, applied by the stage's `adjustAsideBoard`.
    private(set) var asideBoardNonce = 0
    private(set) var asideBoardScaleFactor: Float = 1
    private(set) var asideBoardYaw: Float = 0
    func nudgeAsideBoardScale(_ factor: Float) { asideBoardScaleFactor = factor; asideBoardYaw = 0; asideBoardNonce += 1 }
    func nudgeAsideBoardYaw(_ delta: Float) { asideBoardScaleFactor = 1; asideBoardYaw = delta; asideBoardNonce += 1 }

    init(show: Show? = nil) {
        self.show = show ?? DeckLoader.loadDefault()
    }

    func replace(with show: Show) {
        self.show = show
        currentPage = 0
        currentBeat = 0
        version += 1
        isEditing = false
        selectedElementID = nil
        hasUnsavedEdits = false
    }

    // MARK: Pages

    var pageCount: Int { max(show.pages.count, 0) }
    var hasContent: Bool { pageCount > 0 }

    private var clampedPage: Int { min(max(currentPage, 0), max(pageCount - 1, 0)) }

    var currentShowPage: ShowPage? { hasContent ? show.pages[clampedPage] : nil }
    var currentElements: [ExhibitElement] { currentShowPage?.elements ?? [] }
    /// Right-board reference cards (backup evidence / citations / appendix) for this page.
    /// The board (grammar §5) appears only when this is non-empty — backup material is
    /// secondary and on-demand, so empty pages leave the right side clear.
    var currentAsides: [ExhibitElement] { currentShowPage?.asides ?? [] }
    var currentHasAsides: Bool { !(currentShowPage?.asides.isEmpty ?? true) }
    var currentSection: String? { currentShowPage?.section }
    var currentAnchor: String { currentShowPage?.anchor ?? "" }
    var currentSlideImage: String? { currentShowPage?.slide }   // hi-res static far-panel image (#1)
    var currentTitle: String { currentShowPage?.title ?? "" }
    var currentTranscript: String { currentShowPage?.transcript ?? "" }

    var canGoPrevious: Bool { currentPage > 0 }
    var canGoNext: Bool { currentPage < pageCount - 1 }

    func next() { if canGoNext { currentPage += 1; currentBeat = 0 } }         // forward → page starts at its base beat
    func previous() { if canGoPrevious { currentPage -= 1; currentBeat = currentMaxBeat } }  // back → prior page fully built
    func go(to page: Int) { setPage(page) }

    /// Snaps to a page (used by the carousel on release, and by jumps). A jump arrives
    /// at the page's base state (beat 0), then the presenter builds it up.
    func setPage(_ page: Int) {
        guard hasContent else { return }
        currentPage = min(max(page, 0), pageCount - 1)
        currentBeat = 0
    }

    var counterText: String { hasContent ? "\(clampedPage + 1) / \(pageCount)" : "—" }

    // MARK: Attention timeline (#4) — per-page beats

    /// How many attention beats of THIS page are revealed. 0 = only the base accents
    /// (no beat / beat 0); each advance reveals the next beat's accents in authored
    /// (cognitive) order. Reset whenever the page changes.
    private(set) var currentBeat = 0
    /// The highest beat authored on this page (0 = no stepped beats → nothing to build).
    var currentMaxBeat: Int { currentElements.compactMap { $0.animation?.buildIn?.order }.max() ?? 0 }
    /// While true, the presenter's forward action reveals the next beat rather than
    /// turning the page (Keynote-style builds).
    var beatsRemaining: Bool { currentBeat < currentMaxBeat }
    /// "2/4" while a page is building; empty when it has no stepped beats.
    var beatLabel: String { currentMaxBeat > 0 ? "\(currentBeat)/\(currentMaxBeat)" : "" }

    /// Presenter's forward action: reveal the next beat, else advance the page.
    func advance() { if beatsRemaining { currentBeat += 1 } else { next() } }
    func revealNextBeat() { if beatsRemaining { currentBeat += 1 } }

    // MARK: Editing near elements

    func setEditing(_ on: Bool) {
        isEditing = on
        if !on { selectedElementID = nil }
    }

    /// Commits a manipulated element's live placement back into the model.
    func setTransform(elementID: String, position: SIMD3<Float>, orientation: simd_quatf, scale: Float) {
        guard hasContent,
              let e = show.pages[clampedPage].elements.firstIndex(where: { $0.id == elementID }) else { return }
        show.pages[clampedPage].elements[e].transform = .from(position: position, orientation: orientation, scale: scale)
        hasUnsavedEdits = true
    }

    /// Clears an element's authored transform (returns it to its default spot).
    func resetTransform(elementID: String) {
        guard hasContent,
              let e = show.pages[clampedPage].elements.firstIndex(where: { $0.id == elementID }) else { return }
        show.pages[clampedPage].elements[e].transform = nil
        hasUnsavedEdits = true
        version += 1
    }

    @discardableResult
    func save() -> URL? {
        let url = DeckLoader.save(show)
        if url != nil { hasUnsavedEdits = false }
        return url
    }
}

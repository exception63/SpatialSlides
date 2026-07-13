//
//  StageView.swift
//  Spatial Slides
//
//  The unified stage. One `currentPage` drives four synced layers:
//   • far 主屏 (≈3 m) — the HTML deck in present mode
//   • carousel (a ring of page thumbnails around you) — spin to navigate
//   • near (≈0.5 m) — this page's extracted spatial elements (key lines, 3D models)
//   • left window — the synced transcript
//
//  Spin the carousel with gaze + pinch + a left/right drag; release snaps to the
//  nearest page. Tap empty space to advance. In edit mode the near elements are
//  grabbed/rotated/scaled with ManipulationComponent and saved back to show.json.
//

import SwiftUI
import RealityKit
import UIKit

private let ppm: CGFloat = 1360   // visionOS renders SwiftUI attachments at ~1360 pt/m

struct StageView: View {
    @Environment(PresentationModel.self) private var presentation
    @Environment(AppModel.self) private var appModel
    @State private var coordinator = StageCoordinator()
    @State private var pendingPageCommit: Task<Void, Never>?

    var body: some View {
        RealityView { content, _ in
            content.add(coordinator.root)
            coordinator.installBackdrop()
            coordinator.manipBeginSub = content.subscribe(to: ManipulationEvents.WillBegin.self) { event in
                guard let (node, _) = coordinator.resolve(event.entity) else { return }
                coordinator.setManipulating(node, true)    // freeze this node's loop while hands hold it
            }
            coordinator.manipEndSub = content.subscribe(to: ManipulationEvents.WillEnd.self) { event in
                guard let (node, id) = coordinator.resolve(event.entity) else { return }
                presentation.setTransform(elementID: id, position: node.position,
                                          orientation: node.orientation, scale: node.scale.x)
                presentation.selectedElementID = id
                coordinator.noteManipulated(node)   // if a model was pinch-scaled, sync the remote slider
                coordinator.setManipulating(node, false)   // resume its loop from where it was left
            }
            coordinator.onModelRescaled = { id, pos, ori, s in
                presentation.setTransform(elementID: id, position: pos, orientation: ori, scale: s)
            }
            coordinator.onActiveModelScale = { s in presentation.syncModelScaleSlider(toScale: s) }
            // Per-frame: drive the lightweight carousel tween and, in adjust mode,
            // mirror the grab handle's motion onto the whole wheel.
            coordinator.updateSub = content.subscribe(to: SceneEvents.Update.self) { event in
                coordinator.tick(deltaTime: event.deltaTime)
            }
        } update: { _, attachments in
            reconcile(attachments: attachments)
        } attachments: {
            Attachment(id: Self.controlBarID) { ControlBarView() }
            if presentation.hasContent {
                Attachment(id: Self.deckWebID) { DeckWebView() }
                Attachment(id: Self.transcriptWebID) { TranscriptBoard() }
                Attachment(id: Self.asideBoardID) { AsideBoard() }
                ForEach(presentation.show.pages) { page in
                    Attachment(id: Self.cardID(page.index)) {
                        CarouselCard(page: page)
                    }
                }
                ForEach(presentation.currentElements.filter { $0.usesAttachment }) { element in
                    Attachment(id: element.id) { ExhibitElementView(element: element) }
                }
            }
        }
        .gesture(carouselDrag)
        .gesture(tapGesture)
        .onChange(of: presentation.isEditing) { _, editing in coordinator.setEditing(editing); refreshFarPanel() }
        .onChange(of: presentation.motionMode) { _, _ in refreshFarPanel() }
        .onChange(of: presentation.selectedElementID) { _, id in coordinator.highlightElement(id) }
        .onChange(of: presentation.carouselAdjust) { _, on in coordinator.setCarouselAdjust(on) }
        .onChange(of: presentation.modelScaleAbsNonce) { _, _ in coordinator.setActiveModelScale(presentation.modelScaleAbs) }
        .onChange(of: presentation.currentPage) { _, _ in
            pendingPageCommit?.cancel()
            pendingPageCommit = nil
            presentation.syncSliderToPageModel()
        }
        .onChange(of: presentation.currentBeat) { _, beat in
            coordinator.revealBeat(beat)   // #4: presenter advanced the attention timeline
        }
        .onChange(of: presentation.deckScaleNonce) { _, _ in coordinator.scaleDeckPanel(presentation.deckScaleFactor) }
        .onChange(of: presentation.transcriptBoardNonce) { _, _ in
            coordinator.adjustTranscriptBoard(scale: presentation.transcriptBoardScaleFactor, yaw: presentation.transcriptBoardYaw)
        }
        .onChange(of: presentation.asideBoardNonce) { _, _ in
            coordinator.adjustAsideBoard(scale: presentation.asideBoardScaleFactor, yaw: presentation.asideBoardYaw)
        }
        .onChange(of: appModel.fullImmersion) { _, on in
            coordinator.setImmersiveEnvironment(on, spec: presentation.environmentSpec)
        }
        .onChange(of: presentation.envNonce) { _, _ in coordinator.applyEnvironmentTransform(presentation.environmentSpec) }
    }

    // MARK: - Gestures

    /// Spin the wheel: gaze + pinch + drag left/right on any card scrolls the
    /// cover-flow; release snaps to the nearest page. A `minimumDistance` keeps
    /// pure taps (which jump — see tapGesture) from starting a scroll.
    private var carouselDrag: some Gesture {
        DragGesture(minimumDistance: 12)
            .targetedToAnyEntity()
            .onChanged { value in
                guard !presentation.carouselAdjust, coordinator.cardIndex(for: value.entity) != nil else { return }
                coordinator.dragCarousel(translation: Float(value.translation.width))
            }
            .onEnded { value in
                guard !presentation.carouselAdjust, coordinator.cardIndex(for: value.entity) != nil else { return }
                let page = coordinator.endCarouselDrag()
                navigateViaCarousel(to: page)
            }
    }

    /// Tap a card → jump to that page. Tap a 3D model → make it the active one (so
    /// the remote's ± magnifier and any emphasis target it). Tap empty space → next.
    /// Tap a near element in edit mode → select it. While repositioning the carousel
    /// every tap is ignored (you're grabbing the handle, not navigating).
    private var tapGesture: some Gesture {
        SpatialTapGesture()
            .targetedToAnyEntity()
            .onEnded { value in
                guard !presentation.carouselAdjust else { return }
                if let card = coordinator.cardIndex(for: value.entity) {
                    navigateViaCarousel(to: card)
                } else if presentation.isEditing {
                    presentation.selectedElementID = coordinator.resolve(value.entity)?.1
                } else if coordinator.selectModelIfTarget(value.entity) {
                    // tapped a 3D model in play mode → now the active model for ± resize
                } else if !coordinator.playEmphasisIfTarget(value.entity) {
                    // #4: a tap first builds the current page's remaining attention beats,
                    // then (page fully built) turns to the next page.
                    if presentation.beatsRemaining { presentation.revealNextBeat() }
                    else { navigateViaCarousel(to: presentation.currentPage + 1) }
                }
            }
    }

    /// Keep the wheel animation isolated from the expensive page commit. Heavy HTML
    /// slides still need one large WKWebView rasterization, but it now happens after the
    /// carousel has reached its target instead of during the spin.
    private func navigateViaCarousel(to rawPage: Int) {
        guard presentation.hasContent else { return }
        let page = min(max(rawPage, 0), presentation.pageCount - 1)
        pendingPageCommit?.cancel()
        let delay = coordinator.rotateCarousel(toPage: page, count: presentation.pageCount, animated: true)
        guard page != presentation.currentPage else { return }
        pendingPageCommit = Task { @MainActor in
            try? await Task.sleep(for: .seconds(delay + 0.03))
            guard !Task.isCancelled else { return }
            presentation.setPage(page)
        }
    }

    // MARK: - Reconcile

    private func reconcile(attachments: RealityViewAttachments) {
        placePanels(attachments)
        buildCarouselIfNeeded(attachments)

        guard presentation.hasContent else { return }
        coordinator.setAsideVisible(presentation.currentHasAsides)   // right board: only on pages with asides
        if presentation.currentPage != coordinator.renderedPage || presentation.version != coordinator.renderedVersion {
            coordinator.renderedPage = presentation.currentPage
            let versionChanged = presentation.version != coordinator.renderedVersion
            coordinator.renderedVersion = presentation.version
            rebuildNear(attachments)
            coordinator.rotateCarousel(toPage: presentation.currentPage, count: presentation.pageCount,
                                       animated: !versionChanged)
            refreshFarPanel()
        }
    }

    /// #1: pick the far-panel renderer for the current page/mode — the static hi-res
    /// texture in perf mode when a slide image exists, else the live WKWebView.
    private func refreshFarPanel() {
        let url = presentation.currentSlideImage.flatMap { DeckLoader.assetURL($0) }
        coordinator.updateFarPanel(slideURL: url, motion: presentation.motionMode, editing: presentation.isEditing)
    }

    private func placePanels(_ attachments: RealityViewAttachments) {
        if coordinator.controlBar == nil, let bar = attachments.entity(for: Self.controlBarID) {
            bar.position = [0, 0.62, -1.35]
            coordinator.root.addChild(bar)
            coordinator.controlBar = bar
        }
        if coordinator.deckPanel == nil, let deck = attachments.entity(for: Self.deckWebID) {
            deck.position = [0, 1.62, -3.0]          // far 主屏
            coordinator.root.addChild(deck)
            coordinator.deckPanel = deck
            coordinator.installStaticFarPanel()      // #1: the static hi-res alternative panel
            // Movable/resizable only in edit ("摆放空间元素") mode — locked while presenting.
        }
        if coordinator.transcriptPanel == nil, let tx = attachments.entity(for: Self.transcriptWebID) {
            tx.position = [-1.5, 1.4, -1.25]         // left window
            tx.orientation = simd_quatf(angle: 0.6, axis: [0, 1, 0])   // yaw toward the viewer
            coordinator.root.addChild(tx)
            coordinator.transcriptPanel = tx
            // Move by the top strip only, so the body stays scrollable.
            coordinator.makeMovableByHandle(tx, panelHalf: [Float(TranscriptBoard.boardW) / 2, Float(TranscriptBoard.boardH) / 2])
        }
        // Right reference board — mirror of the transcript window (grammar §5). Hidden by
        // default; reconcile shows it only on pages that carry asides (backup material is
        // secondary/on-demand). Movable by its top strip, like the transcript board.
        if coordinator.asidePanel == nil, let aside = attachments.entity(for: Self.asideBoardID) {
            aside.position = [1.5, 1.4, -1.25]                          // right window (mirrors left)
            aside.orientation = simd_quatf(angle: -0.6, axis: [0, 1, 0])   // yaw toward the viewer from the right
            aside.isEnabled = false
            coordinator.root.addChild(aside)
            coordinator.asidePanel = aside
            coordinator.makeMovableByHandle(aside, panelHalf: [Float(AsideBoard.boardW) / 2, Float(AsideBoard.boardH) / 2])
        }
    }

    private func buildCarouselIfNeeded(_ attachments: RealityViewAttachments) {
        guard presentation.hasContent else { return }
        guard presentation.version != coordinator.carouselVersion else { return }
        let pages = presentation.show.pages
        guard pages.allSatisfy({ attachments.entity(for: Self.cardID($0.index)) != nil }) else { return }
        coordinator.carouselVersion = presentation.version
        coordinator.buildCarousel(cards: pages.map { attachments.entity(for: Self.cardID($0.index)) },
                                  count: pages.count)
        coordinator.rotateCarousel(toPage: presentation.currentPage, count: pages.count, animated: false)
    }

    private func rebuildNear(_ attachments: RealityViewAttachments) {
        let elements = presentation.currentElements
        let attachmentElements = elements.filter { $0.usesAttachment }
        guard attachmentElements.allSatisfy({ attachments.entity(for: $0.id) != nil }) else { return }

        coordinator.clearNear()
        let container = Entity()
        // #4 attention timeline: elements carry a beat (buildIn.order). Those at or below
        // the page's currentBeat are shown now; later beats start hidden and are revealed
        // one presenter-advance at a time. A small stagger orders same-beat reveals.
        var revealIdx = 0
        for element in elements {
            let node: Entity
            if element.usesAttachment {
                guard let e = attachments.entity(for: element.id) else { continue }
                node = e
            } else {
                node = ExhibitBuilder.build(element) { [coordinator] modelNode, shape, halfExtent in
                    coordinator.refreshLoadedModel(modelNode, shape: shape, halfExtent: halfExtent)
                }
            }
            let t = element.transform ?? ElementTransform(position: [0, 1.2, -0.5])
            node.position = t.position
            node.orientation = t.rotationEuler == .zero ? Self.facing(t.position) : t.orientation
            node.scale = [t.scale, t.scale, t.scale]
            container.addChild(node)
            coordinator.registerTappable(node, element: element)
            if !element.usesAttachment, let loop = element.animation?.loop {
                coordinator.registerLooper(node, loop: loop, startDelay: 0.45)
            }
            let beat = element.animation?.buildIn?.order ?? 0
            if beat <= presentation.currentBeat {
                coordinator.buildIn(node, delay: Double(revealIdx) * 0.06)
                revealIdx += 1
            } else {
                node.isEnabled = false                    // future beat — hidden until its cue
                coordinator.registerBeatNode(node, beat: beat)
            }
        }
        coordinator.root.addChild(container)
        coordinator.nearContainer = container
    }

    /// Orientation that turns an entity's face (+z) toward the viewer's eye.
    static func facing(_ pos: SIMD3<Float>) -> simd_quatf {
        let toEye = SIMD3<Float>(0, 1.45, 0) - pos
        guard length(toEye) > 0.0001 else { return simd_quatf(angle: 0, axis: [0, 1, 0]) }
        return simd_quatf(from: [0, 0, 1], to: normalize(toEye))
    }

    static let controlBarID = "controlBar"
    static let deckWebID = "deckWeb"
    static let transcriptWebID = "transcriptWeb"
    static let asideBoardID = "asideBoard"
    static func cardID(_ index: Int) -> String { "card-\(index)" }
}

// MARK: - Web attachment views

private struct DeckWebView: View {
    @Environment(PresentationModel.self) private var presentation
    var body: some View {
        Group {
            if let url = DeckLoader.assetURL(presentation.show.html) {
                HTMLPanel(fileURL: url, page: presentation.currentPage, motionMode: presentation.motionMode)
            } else {
                Color.black.opacity(0.3)
            }
        }
        .frame(width: 2.6 * ppm, height: 1.4625 * ppm)   // 16:9 screen ≈ 2.6 × 1.46 m
        .clipShape(.rect(cornerRadius: 20))
        .overlay(RoundedRectangle(cornerRadius: 20).strokeBorder(.white.opacity(0.12), lineWidth: 1))
    }
}

/// A dedicated, native speaker-transcript board — the current page's script in
/// large, editorial type. Cue lines (stage directions) read as amber asides;
/// golden quotes get an accent card. Top strip is the grab handle (move it
/// anywhere); the body scrolls. No dependency on the HTML deck's presenter scheme.
private struct TranscriptBoard: View {
    @Environment(PresentationModel.self) private var presentation

    private let accent = Color(hex: "#E0602A")
    private let cue = Color(hex: "#E7A33E")

    /// The presenter tunes this live from the remote (讲稿字号 ±); every size below
    /// is multiplied by it, so the whole board grows/shrinks together.
    private var s: CGFloat { presentation.transcriptScale }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Capsule().fill(.white.opacity(0.35))
                .frame(width: 66, height: 5)
                .frame(maxWidth: .infinity)
                .padding(.top, 16).padding(.bottom, 14)

            HStack(alignment: .center, spacing: 14) {
                RoundedRectangle(cornerRadius: 2).fill(accent).frame(width: 6, height: 46 * s)
                VStack(alignment: .leading, spacing: 3) {
                    Text("讲稿 · SCRIPT").font(.system(size: 15, weight: .heavy)).tracking(4)
                        .foregroundStyle(.secondary)
                    Text(presentation.currentTitle).font(.system(size: 36 * s, weight: .bold))
                        .foregroundStyle(.white).lineLimit(2).minimumScaleFactor(0.6)
                }
                Spacer(minLength: 8)
                Text(presentation.counterText)
                    .font(.system(size: 22, weight: .semibold, design: .rounded)).monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 36).padding(.bottom, 18)

            Rectangle().fill(.white.opacity(0.12)).frame(height: 1).padding(.horizontal, 32)

            ScrollView {
                VStack(alignment: .leading, spacing: 26) {
                    if paragraphs.isEmpty {
                        Text("（本页没有讲稿）").font(.system(size: 34 * s)).foregroundStyle(.tertiary).padding(.top, 30)
                    }
                    ForEach(Array(paragraphs.enumerated()), id: \.offset) { _, p in
                        paragraph(p)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 38).padding(.top, 24).padding(.bottom, 48)
            }
            .scrollIndicators(.visible)
        }
        .frame(width: Self.boardW * ppm, height: Self.boardH * ppm)
        .glassBackgroundEffect(in: .rect(cornerRadius: 34))
    }

    static let boardW: CGFloat = 1.28
    static let boardH: CGFloat = 1.62

    private var paragraphs: [String] {
        presentation.currentTranscript.isEmpty ? []
            : presentation.currentTranscript.components(separatedBy: "\n\n").filter { !$0.isEmpty }
    }

    @ViewBuilder
    private func paragraph(_ p: String) -> some View {
        if p.hasPrefix("〔") {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "waveform").font(.system(size: 22 * s)).foregroundStyle(cue).padding(.top, 5)
                Text(p.trimmingCharacters(in: CharacterSet(charactersIn: "〔〕")))
                    .font(.system(size: 32 * s, weight: .medium)).italic()
                    .foregroundStyle(cue.opacity(0.95)).lineSpacing(8)
            }
        } else if p.hasPrefix("【金句】") {
            Text(p.replacingOccurrences(of: "【金句】", with: ""))
                .font(.system(size: 46 * s, weight: .semibold)).foregroundStyle(.white).lineSpacing(13)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(22)
                .background(accent.opacity(0.16), in: RoundedRectangle(cornerRadius: 18))
                .overlay(RoundedRectangle(cornerRadius: 18).strokeBorder(accent.opacity(0.55), lineWidth: 1))
        } else {
            Text(p).font(.system(size: 46 * s, weight: .regular)).lineSpacing(17)
                .foregroundStyle(.white.opacity(0.96))
        }
    }
}

/// The right reference board (grammar §5): the current page's backup evidence,
/// citations, and appendix material — the supporting layer you glance to when an
/// argument needs backing. Deliberately more restrained than the near-field accents
/// and cooler than the warm transcript board (steel-blue = "reference / source", not
/// "speaker script"), so it reads as secondary. Only shown on pages that carry asides;
/// moved by its top strip, resized/re-faced from the remote.
private struct AsideBoard: View {
    @Environment(PresentationModel.self) private var presentation

    private let accent = Color(hex: "#5AC8FA")   // cool steel-blue — "evidence / source"

    /// Shares the transcript board's type scale so the two flanking boards read at the
    /// same size by default — and the remote's 讲稿字号 ± grows both together.
    private var s: CGFloat { presentation.transcriptScale }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Capsule().fill(.white.opacity(0.35))
                .frame(width: 66, height: 5)
                .frame(maxWidth: .infinity)
                .padding(.top, 16).padding(.bottom, 14)

            HStack(alignment: .center, spacing: 14) {
                RoundedRectangle(cornerRadius: 2).fill(accent).frame(width: 6, height: 46 * s)
                VStack(alignment: .leading, spacing: 3) {
                    Text("参考 · EVIDENCE").font(.system(size: 15, weight: .heavy)).tracking(4)
                        .foregroundStyle(.secondary)
                    Text(heading).font(.system(size: 36 * s, weight: .bold))
                        .foregroundStyle(.white).lineLimit(2).minimumScaleFactor(0.6)
                }
                Spacer(minLength: 8)
                Image(systemName: "text.quote").font(.system(size: 22)).foregroundStyle(accent.opacity(0.6))
            }
            .padding(.horizontal, 34).padding(.bottom, 16)

            Rectangle().fill(.white.opacity(0.12)).frame(height: 1).padding(.horizontal, 30)

            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    ForEach(presentation.currentAsides) { aside in card(aside) }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 32).padding(.top, 22).padding(.bottom, 44)
            }
            .scrollIndicators(.visible)
        }
        .frame(width: Self.boardW * ppm, height: Self.boardH * ppm)
        .glassBackgroundEffect(in: .rect(cornerRadius: 34))
    }

    static let boardW: CGFloat = 1.28
    static let boardH: CGFloat = 1.62

    /// Prefer the page's section label (the argument's current chapter) if present,
    /// else the page title.
    private var heading: String {
        if let s = presentation.currentSection, !s.isEmpty { return s }
        return presentation.currentTitle
    }

    /// One reference card: the evidence text, plus an optional source line (the aside's
    /// `caption`, carried from `data-spatial-aside-cite`).
    @ViewBuilder
    private func card(_ aside: ExhibitElement) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            if let head = aside.text, !head.isEmpty {
                Text(head).font(.system(size: 46 * s, weight: .regular)).lineSpacing(17)
                    .foregroundStyle(.white.opacity(0.95))
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            if let cite = aside.caption, !cite.isEmpty {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Image(systemName: "quote.opening").font(.system(size: 20 * s)).foregroundStyle(accent)
                    Text(cite).font(.system(size: 28 * s, weight: .medium)).italic()
                        .foregroundStyle(accent.opacity(0.9))
                }
            }
        }
        .padding(22)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 18))
        .overlay(RoundedRectangle(cornerRadius: 18).strokeBorder(accent.opacity(0.28), lineWidth: 1))
    }
}

// MARK: - Coordinator

@MainActor
final class StageCoordinator {
    let root = Entity()
    var controlBar: Entity?
    var deckPanel: Entity?
    var staticDeckPanel: ModelEntity?     // #1: hi-res static slide texture (perf mode) — alternative to deckPanel's WKWebView
    var transcriptPanel: Entity?
    var asidePanel: Entity?               // right reference board (grammar §5); shown only on pages with asides
    var backdrop: Entity?
    var nearContainer: Entity?
    var manipEndSub: EventSubscription?
    var manipBeginSub: EventSubscription?

    var renderedPage = -1
    var renderedVersion = -1
    var carouselVersion = -1
    var updateSub: EventSubscription?

    // Carousel (cover-flow). Cards live in `carousel` (a direct child of root). To
    // reposition the whole wheel, adjust mode spawns a SEPARATE grab handle that is
    // a SIBLING of the cards — never an ancestor — and mirrors its motion onto the
    // container each frame. The card entities are never given/stripped a
    // ManipulationComponent, so scroll + tap navigation is always intact when adjust
    // turns off. (The earlier "manipulate the cards' parent" scheme left the cards'
    // gaze/pinch input dead after exiting adjust — this avoids that entirely.)
    private var carousel: Entity?
    private var adjustHandle: Entity?
    private var carouselAnchor: SIMD3<Float> = .zero   // wheel position when adjust began
    private var handleAnchor: SIMD3<Float> = .zero     // handle position when adjust began
    private var carouselOffset: Float = 0        // fractional scroll position (0 = page 0 at front)
    private var skybox: Entity?                   // dark immersive environment (full-immersion mode)
    private var dragBaseOffset: Float = 0
    private var dragging = false
    private var indexForCard: [ObjectIdentifier: Int] = [:]
    private var cards: [Entity?] = []
    private var carouselAnimation: CarouselAnimation?
    /// Pages per drag-point. Higher = faster. Negate to flip drag direction.
    private let dragSensitivity: Float = 0.004

    private struct CarouselAnimation {
        var startOffset: Float
        var targetOffset: Float
        var elapsed: TimeInterval
        var duration: TimeInterval
    }

    // Near-element editing (ported)
    private(set) var isEditing = false
    private var elementForEntity: [ObjectIdentifier: String] = [:]
    private var nodeForElement: [String: Entity] = [:]
    private var shapeForNode: [ObjectIdentifier: ShapeResource] = [:]
    private var halfExtentForEntity: [ObjectIdentifier: SIMD2<Float>] = [:]
    private var alwaysGrabNodes: Set<ObjectIdentifier> = []   // 3D models — grabbable outside edit too
    private var emphasisMap: [ObjectIdentifier: EmphasisEffect] = [:]
    private var selectedNode: Entity?
    private var selectionOutline: Entity?

    // Loop animations (spin/float/breathe). Restored after the 2026-07 refactor dropped
    // the old tickLoops driver. Only the 3D nodes (models/charts) loop; flat panels
    // breathe via NeonGlow. See the "Loop animations" section for how they compose with
    // manipulation without fighting it.
    private var loopers: [Looper] = []
    private var manipulatingNodes: Set<ObjectIdentifier> = []

    // MARK: Backdrop (tap empty → next)

    func installBackdrop() {
        guard backdrop == nil else { return }
        let e = Entity()
        e.position = [0, 1.3, -3.6]
        e.components.set(InputTargetComponent())
        e.components.set(CollisionComponent(shapes: [.generateBox(size: [18, 12, 0.05])]))
        root.addChild(e)
        backdrop = e
    }

    // MARK: Carousel

    func buildCarousel(cards: [Entity?], count: Int) {
        carousel?.removeFromParent()
        adjustHandle?.removeFromParent()
        carouselAnimation = nil
        indexForCard.removeAll()
        let container = Entity()                 // holds the cards; a direct child of root
        root.addChild(container)
        carousel = container
        self.cards = cards
        for (i, card) in cards.enumerated() {
            guard let card else { continue }
            card.components.set(InputTargetComponent())
            card.components.set(HoverEffectComponent())
            card.components.set(CollisionComponent(shapes: [.generateBox(size: Carousel.collisionSize)]))
            indexForCard[ObjectIdentifier(card)] = i
            container.addChild(card)
        }
        let handle = makeAdjustHandle()          // sibling of the cards; only live in adjust mode
        handle.isEnabled = false
        root.addChild(handle)
        adjustHandle = handle
        if carouselAdjustOn { setCarouselAdjust(true) }   // re-arm after a rebuild
    }

    /// A glowing amber bar the presenter grabs to slide the whole wheel closer /
    /// farther / aside. It carries the ManipulationComponent — the cards never do —
    /// so nothing about the cards' input changes when adjust turns off.
    private func makeAdjustHandle() -> Entity {
        var mat = PhysicallyBasedMaterial()
        let c = UIColor(hex: "#E7A33E")
        mat.baseColor = .init(tint: c)
        mat.roughness = 0.3
        mat.metallic = 0.1
        mat.emissiveColor = .init(color: c)
        mat.emissiveIntensity = 0.9
        let bar = ModelEntity(mesh: .generateBox(size: [0.34, 0.05, 0.05], cornerRadius: 0.025), materials: [mat])
        // two end knobs read as a grab bar
        for side in [Float(-1), 1] {
            let knob = ModelEntity(mesh: .generateSphere(radius: 0.038), materials: [mat])
            knob.position = [side * 0.19, 0, 0]
            bar.addChild(knob)
        }
        return bar
    }

    /// Adjust mode. On: reveal the handle at the wheel's front and make it grabbable;
    /// remember where wheel & handle start so `tickCarouselAdjust` can mirror the
    /// handle's motion onto the wheel. Off: hide + de-arm the handle. Navigation is
    /// gated off (in StageView) while adjusting. The cards are never touched.
    private var carouselAdjustOn = false
    func setCarouselAdjust(_ on: Bool) {
        carouselAdjustOn = on
        guard let handle = adjustHandle, let container = carousel else { return }
        if on {
            handle.position = container.position + [0, Carousel.y - 0.26, -Carousel.radius + 0.02]
            handle.orientation = StageView.facing(handle.position)
            handle.isEnabled = true
            let box = ShapeResource.generateBox(size: [0.44, 0.14, 0.14])
            enableManipulation(handle, shape: box, allowsScaling: false, allowsRotation: false)
            carouselAnchor = container.position
            handleAnchor = handle.position
        } else {
            handle.isEnabled = false
            handle.components.remove(ManipulationComponent.self)
            handle.components.remove(CollisionComponent.self)
            handle.components.remove(InputTargetComponent.self)
            handle.components.remove(HoverEffectComponent.self)
        }
    }

    /// Called every frame. While adjusting, the wheel tracks the grab handle by the
    /// same offset the handle has been dragged — so grabbing the bar slides the whole
    /// carousel (cards + all) as one, and it stays put on release.
    func tickCarouselAdjust() {
        guard carouselAdjustOn, let handle = adjustHandle, let container = carousel else { return }
        container.position = carouselAnchor + (handle.position - handleAnchor)
    }

    func tick(deltaTime: TimeInterval) {
        tickCarouselAdjust()
        tickCarouselAnimation(deltaTime: deltaTime)
        tickLoops(deltaTime: deltaTime)
    }

    @discardableResult
    func rotateCarousel(toPage page: Int, count: Int, animated: Bool) -> TimeInterval {
        let target = Float(min(max(page, 0), max(count - 1, 0)))
        guard animated else {
            carouselAnimation = nil
            carouselOffset = target
            layoutCards(offset: carouselOffset)
            return 0
        }

        let distance = abs(target - carouselOffset)
        guard distance > 0.001 else {
            carouselAnimation = nil
            carouselOffset = target
            layoutCards(offset: carouselOffset)
            return 0
        }

        let duration = min(0.55, max(0.22, 0.18 + TimeInterval(distance) * 0.06))
        carouselAnimation = CarouselAnimation(
            startOffset: carouselOffset,
            targetOffset: target,
            elapsed: 0,
            duration: duration
        )
        return duration
    }

    /// Live drag: scroll the cover-flow under the hand (no snap yet).
    func dragCarousel(translation: Float) {
        guard !cards.isEmpty else { return }
        carouselAnimation = nil
        if !dragging { dragging = true; dragBaseOffset = carouselOffset }
        let count = cards.count
        carouselOffset = min(max(dragBaseOffset - translation * dragSensitivity, 0), Float(count - 1))
        layoutCards(offset: carouselOffset)
    }

    /// Release: the page to snap to (StageView animates the model to it).
    func endCarouselDrag() -> Int {
        dragging = false
        return min(max(Int(carouselOffset.rounded()), 0), max(cards.count - 1, 0))
    }

    private func tickCarouselAnimation(deltaTime: TimeInterval) {
        guard var animation = carouselAnimation else { return }
        animation.elapsed += deltaTime
        let rawT = min(max(Float(animation.elapsed / animation.duration), 0), 1)
        let eased = rawT * rawT * (3 - 2 * rawT)
        carouselOffset = animation.startOffset + (animation.targetOffset - animation.startOffset) * eased
        layoutCards(offset: carouselOffset)
        if rawT >= 1 {
            carouselOffset = animation.targetOffset
            carouselAnimation = nil
            layoutCards(offset: carouselOffset)
        } else {
            carouselAnimation = animation
        }
    }

    /// Positions every card by its fractional distance from the front slot.
    private func layoutCards(offset: Float) {
        for (i, card) in cards.enumerated() {
            guard let card else { continue }
            let slot = Carousel.slot(f: Float(i) - offset)
            card.isEnabled = slot.visible
            guard slot.visible else { continue }
            let orient = StageView.facing(slot.position) * simd_quatf(angle: slot.yaw, axis: [0, 1, 0])
            let target = Transform(scale: [slot.scale, slot.scale, slot.scale],
                                   rotation: orient, translation: slot.position)
            card.transform = target
            // Only fading cards get an OpacityComponent — an opaque card with one is
            // still forced into the transparent render pass (costly overdraw). Opaque
            // cards have it removed so they render on the cheap opaque path.
            if slot.opacity >= 0.999 { card.components.remove(OpacityComponent.self) }
            else { card.components.set(OpacityComponent(opacity: slot.opacity)) }
        }
    }

    func cardIndex(for tapped: Entity) -> Int? {
        var cur: Entity? = tapped
        while let n = cur { if let i = indexForCard[ObjectIdentifier(n)] { return i }; cur = n.parent }
        return nil
    }

    // MARK: Model resize — native two-handed pinch (primary) + a stepless slider

    var onModelRescaled: ((String, SIMD3<Float>, simd_quatf, Float) -> Void)?
    /// Fired when a model becomes active (tapped, or just manipulated), with its
    /// current scale — the remote's slider follows it.
    var onActiveModelScale: ((Float) -> Void)?
    private var modelNodes: Set<ObjectIdentifier> = []
    /// The model the remote slider drives — the last one tapped or manipulated.
    /// Defaults to the page's first model so the slider works before anything is picked.
    private(set) var activeModelID: String?

    /// Walks up from a tapped entity to the owning 3D-model node, if any.
    private func modelNode(for tapped: Entity) -> Entity? {
        var cur: Entity? = tapped
        while let n = cur {
            if modelNodes.contains(ObjectIdentifier(n)) { return n }
            cur = n.parent
        }
        return nil
    }

    func refreshLoadedModel(_ node: Entity, shape: ShapeResource, halfExtent: SIMD2<Float>) {
        let key = ObjectIdentifier(node)
        guard modelNodes.contains(key), elementForEntity[key] != nil else { return }
        shapeForNode[key] = shape
        halfExtentForEntity[key] = halfExtent
        enableManipulation(node, shape: shape)
    }

    /// Remote slider: set the ACTIVE model's absolute scale (stepless). Only touches
    /// one model, so a page with several 3D objects resizes them one at a time.
    func setActiveModelScale(_ scale: Float) {
        let node: Entity?
        if let id = activeModelID, let n = nodeForElement[id], modelNodes.contains(ObjectIdentifier(n)) {
            node = n
        } else {
            node = nodeForElement.first { modelNodes.contains(ObjectIdentifier($0.value)) }?.value
        }
        guard let node else { return }
        let s = max(0.02, min(scale, 2.5))
        node.scale = [s, s, s]
        if let id = elementForEntity[ObjectIdentifier(node)] {
            activeModelID = id
            onModelRescaled?(id, node.position, node.orientation, s)
        }
    }

    /// Marks a model active and reports its scale so the remote slider follows.
    private func markActiveModel(_ node: Entity) {
        guard modelNodes.contains(ObjectIdentifier(node)),
              let id = elementForEntity[ObjectIdentifier(node)] else { return }
        activeModelID = id
        onActiveModelScale?(node.scale.x)
    }

    /// A manipulation just ended — if it was a model (e.g. a two-handed pinch-scale),
    /// make it active and sync the slider to its new size.
    func noteManipulated(_ node: Entity) { markActiveModel(node) }

    /// Tap on a 3D model in play mode → make it the active model (so the slider drives
    /// it) and give a small pulse. Returns false if the tap wasn't on a model.
    @discardableResult
    func selectModelIfTarget(_ tapped: Entity) -> Bool {
        guard let node = modelNode(for: tapped) else { return false }
        markActiveModel(node)
        playEmphasis(node, .pulse)
        return true
    }

    /// Live-resize the far HTML board (magnifier fallback to two-handed pinch).
    func scaleDeckPanel(_ factor: Float) {
        guard let deck = deckPanel else { return }
        let s = min(max(deck.scale.x * factor, 0.4), 2.5)
        deck.scale = [s, s, s]
    }

    /// Remote-driven resize + re-facing of the transcript board (a reliable path since a
    /// two-hand pinch on the thin handle strip can be finicky). Scale multiplies; yaw adds.
    func adjustTranscriptBoard(scale factor: Float, yaw: Float) {
        guard let tx = transcriptPanel else { return }
        if factor != 1 {
            let s = min(max(tx.scale.x * factor, 0.5), 2.2)
            tx.scale = [s, s, s]
        }
        if yaw != 0 {
            tx.orientation = simd_quatf(angle: yaw, axis: [0, 1, 0]) * tx.orientation
        }
    }

    /// Show/hide the right reference board — driven by whether the current page has asides.
    /// Its transform (a user-dragged/scaled placement) is preserved across hide/show.
    func setAsideVisible(_ on: Bool) {
        guard let aside = asidePanel, aside.isEnabled != on else { return }
        aside.isEnabled = on
    }

    /// Remote-driven resize + re-facing of the right reference board (mirror of the
    /// transcript board control). Scale multiplies; yaw adds.
    func adjustAsideBoard(scale factor: Float, yaw: Float) {
        guard let aside = asidePanel else { return }
        if factor != 1 {
            let s = min(max(aside.scale.x * factor, 0.5), 2.2)
            aside.scale = [s, s, s]
        }
        if yaw != 0 {
            aside.orientation = simd_quatf(angle: yaw, axis: [0, 1, 0]) * aside.orientation
        }
    }

    func installStaticFarPanel() {
        guard staticDeckPanel == nil, deckPanel != nil else { return }
        let plane = ModelEntity(mesh: .generatePlane(width: 2.6, height: 1.4625, cornerRadius: 0.02),
                                materials: [UnlitMaterial(color: UIColor(hex: "#0A0E17"))])
        plane.isEnabled = false
        root.addChild(plane)
        staticDeckPanel = plane
    }

    /// #1 static far panel. In perf mode (motion off, not editing) with a hi-res slide
    /// image available, show a crisp static texture and disable the live WKWebView —
    /// constant cost, no per-slide rasterization of a heavy DOM. Otherwise the WKWebView.
    func updateFarPanel(slideURL: URL?, motion: Bool, editing: Bool) {
        guard let web = deckPanel, let plane = staticDeckPanel else { return }
        guard !motion, !editing, let url = slideURL else {
            plane.isEnabled = false
            web.isEnabled = true
            return
        }
        plane.transform = web.transform
        plane.position.z += 0.01
        Task { @MainActor in
            guard let tex = try? await TextureResource(contentsOf: url) else { return }
            var mat = UnlitMaterial()
            mat.color = .init(tint: .white, texture: .init(tex))
            plane.model?.materials = [mat]
            plane.isEnabled = true
            web.isEnabled = false
        }
    }

    private var envScene: Entity?

    /// Full-immersion backdrop. Always lays a large gradient dome (dark studio so the
    /// slides pop, never flat black). If the package ships a 3D environment (a baked
    /// low-poly stage etc., see `ResolvedEnvironment`), it's loaded in FRONT of the
    /// dome — the dome then only shows through the scene's gaps as a dark sky. The
    /// scene is stripped of collision/input so gaze+pinch pass straight through to the
    /// slides. NOTE: visionOS apps can't use the system Environments (moon/lake) —
    /// those are user-only and an app's immersive space replaces them; this is ours.
    func setImmersiveEnvironment(_ on: Bool, spec: ResolvedEnvironment? = nil) {
        if on {
            if skybox == nil {
                let dome = ModelEntity(mesh: .generateSphere(radius: 60), materials: [Self.skyMaterial()])
                dome.scale = [-1, 1, 1]          // flip normals inward so we see the interior
                root.addChild(dome)
                skybox = dome
            }
            if envScene == nil, let spec {
                Task { @MainActor in
                    guard let scene = try? await Entity(contentsOf: spec.url) else { return }
                    scene.position = spec.position
                    scene.orientation = simd_quatf(angle: spec.yaw, axis: [0, 1, 0])
                    scene.scale = [spec.scale, spec.scale, spec.scale]
                    Self.stripInteraction(scene)   // pure backdrop — no collision/input
                    root.addChild(scene)
                    envScene = scene
                }
            }
        } else {
            skybox?.removeFromParent(); skybox = nil
            envScene?.removeFromParent(); envScene = nil
        }
    }

    /// Re-fit the already-loaded environment scene live (remote scale/position/yaw
    /// nudges) without reloading it.
    func applyEnvironmentTransform(_ spec: ResolvedEnvironment?) {
        guard let scene = envScene, let spec else { return }
        scene.position = spec.position
        scene.orientation = simd_quatf(angle: spec.yaw, axis: [0, 1, 0])
        scene.scale = [spec.scale, spec.scale, spec.scale]
    }

    /// Recursively removes collision + input so an environment scene never intercepts
    /// the gaze/pinch meant for the slides, carousel, or near elements.
    private static func stripInteraction(_ e: Entity) {
        e.components.remove(CollisionComponent.self)
        e.components.remove(InputTargetComponent.self)
        for child in e.children { stripInteraction(child) }
    }

    private static func skyMaterial() -> RealityKit.Material {
        // A soft vertical gradient — near-black at the horizon, a faint cool glow above.
        let size = CGSize(width: 8, height: 512)
        let image = UIGraphicsImageRenderer(size: size).image { ctx in
            let colors = [UIColor(hex: "#121A2B").cgColor, UIColor(hex: "#0A0E17").cgColor, UIColor(hex: "#05070C").cgColor]
            let grad = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                                  colors: colors as CFArray, locations: [0, 0.5, 1])!
            ctx.cgContext.drawLinearGradient(grad, start: .zero, end: CGPoint(x: 0, y: size.height), options: [])
        }
        if let cg = image.cgImage,
           let tex = try? TextureResource(image: cg, options: .init(semantic: .color)) {
            var m = UnlitMaterial()
            m.color = .init(tint: .white, texture: .init(tex))
            m.faceCulling = .none
            return m
        }
        var fallback = UnlitMaterial(color: UIColor(hex: "#0A0E17"))
        fallback.faceCulling = .none
        return fallback
    }

    // MARK: Loop animations (spin / float / breathe)

    /// The per-page "life" of the 3D accents — restored after the 2026-07 refactor
    /// dropped the old tickLoops driver. Effects are applied INCREMENTALLY (frame
    /// deltas, never set-from-a-stored-base), so they compose with two-hand
    /// manipulation instead of overwriting it, and a node held by the hands freezes
    /// its loop (phase held) and resumes without a jump on release. Only the RealityKit
    /// 3D nodes (models/charts) loop; flat text/key-line panels already breathe via
    /// NeonGlow.
    private struct Looper {
        weak var node: Entity?
        let effect: LoopEffect
        let omega: Double         // 2π / period (rad/s)
        let amplitude: Float
        var phase: Double = 0     // advances only while the node isn't being held
        let startDelay: Double    // wait out the build-in move before animating
        var elapsed: Double = 0
    }

    func registerLooper(_ node: Entity, loop: LoopAnim, startDelay: Double) {
        guard loop.effect != .none else { return }
        let period = max(0.4, loop.period)
        loopers.append(Looper(node: node, effect: loop.effect,
                              omega: 2 * .pi / period,
                              amplitude: Float(max(0, loop.amplitude)),
                              startDelay: startDelay))
    }

    /// Freeze/resume a node's loop while it's under a hand — called from the
    /// manipulation Will-Begin / Will-End subscriptions so a grab never fights the loop.
    func setManipulating(_ node: Entity, _ on: Bool) {
        if on { manipulatingNodes.insert(ObjectIdentifier(node)) }
        else { manipulatingNodes.remove(ObjectIdentifier(node)) }
    }

    private func tickLoops(deltaTime dt: TimeInterval) {
        guard !loopers.isEmpty else { return }
        for i in loopers.indices {
            guard let node = loopers[i].node else { continue }
            if !node.isEnabled { continue }                                      // #4: parked (future-beat) → no loop yet
            loopers[i].elapsed += dt
            if loopers[i].elapsed < loopers[i].startDelay { continue }
            if manipulatingNodes.contains(ObjectIdentifier(node)) { continue }   // held → hold phase
            let w = loopers[i].omega
            let p = loopers[i].phase
            loopers[i].phase += dt
            let t = loopers[i].phase
            switch loopers[i].effect {
            case .spin:
                node.orientation = simd_quatf(angle: Float(w * dt), axis: [0, 1, 0]) * node.orientation
            case .float:
                let amp = (loopers[i].amplitude <= 0 ? 1 : loopers[i].amplitude) * 0.03   // ±3 cm × amplitude
                node.position.y += amp * Float(sin(w * t) - sin(w * p))
            case .breathe:
                let amp = (loopers[i].amplitude <= 0 ? 1 : loopers[i].amplitude) * 0.04   // ±4 % scale × amplitude
                node.scale *= (1 + amp * Float(sin(w * t))) / (1 + amp * Float(sin(w * p)))
            case .none:
                break
            }
        }
    }

    // MARK: Near elements

    func clearNear() {
        // Exit animation: the 3D nodes we own (models/charts = alwaysGrabNodes) shrink and
        // sink out before removal instead of vanishing hard. Flat panels are SwiftUI
        // attachments (managed by the RealityView), so they leave with currentElements.
        if let exiting = nearContainer {
            let owned = alwaysGrabNodes
            let leaving = exiting.children.filter { owned.contains(ObjectIdentifier($0)) }
            for node in leaving {
                var t = node.transform
                t.scale *= 0.6
                t.translation += [0, -0.05, -0.14]
                node.move(to: t, relativeTo: node.parent, duration: 0.24, timingFunction: .easeIn)
            }
            if leaving.isEmpty {
                exiting.removeFromParent()
            } else {
                Task { @MainActor in
                    try? await Task.sleep(for: .seconds(0.26))
                    exiting.removeFromParent()
                }
            }
        }
        nearContainer = nil
        elementForEntity.removeAll()
        nodeForElement.removeAll()
        shapeForNode.removeAll()
        halfExtentForEntity.removeAll()
        alwaysGrabNodes.removeAll()
        modelNodes.removeAll()
        activeModelID = nil
        emphasisMap.removeAll()
        selectedNode = nil
        selectionOutline = nil
        loopers.removeAll()
        manipulatingNodes.removeAll()
        beatNodes.removeAll()
    }

    func buildIn(_ node: Entity, delay: Double = 0) {
        let final = node.transform
        var start = final
        start.scale = final.scale * 0.85
        start.translation = final.translation + [0, -0.04, -0.12]
        node.transform = start
        Task { @MainActor in
            if delay > 0 { try? await Task.sleep(for: .seconds(delay)) }
            node.move(to: final, relativeTo: node.parent, duration: 0.4, timingFunction: .easeOut)
        }
    }

    // #4 attention timeline: near accents whose beat is above the page's current level,
    // parked hidden until the presenter advances to their cue.
    private var beatNodes: [Int: [Entity]] = [:]
    func registerBeatNode(_ node: Entity, beat: Int) { beatNodes[beat, default: []].append(node) }

    /// Reveal a beat's parked accents with the entrance animation — called when the
    /// presenter advances the timeline (PresentationModel.currentBeat changed).
    func revealBeat(_ beat: Int) {
        guard let nodes = beatNodes[beat] else { return }
        for (i, node) in nodes.enumerated() {
            node.isEnabled = true
            buildIn(node, delay: Double(i) * 0.06)
        }
    }

    private func collisionShape(for element: ExhibitElement) -> ShapeResource {
        if let s = element.size { return .generateBox(size: [max(s.x, 0.05), max(s.y, 0.05), 0.05]) }
        switch element.kind {
        case .barChart, .scatter, .model: return .generateBox(size: [0.4, 0.4, 0.4])
        default: return .generateBox(size: [0.5, 0.32, 0.1])
        }
    }
    private func halfExtent(for element: ExhibitElement) -> SIMD2<Float> {
        if let s = element.size { return [max(s.x, 0.05) / 2, max(s.y, 0.05) / 2] }
        switch element.kind {
        case .barChart, .scatter, .model: return [0.2, 0.2]
        default: return [0.25, 0.16]
        }
    }

    func registerTappable(_ node: Entity, element: ExhibitElement) {
        let key = ObjectIdentifier(node)
        elementForEntity[key] = element.id
        nodeForElement[element.id] = node
        let shape = collisionShape(for: element)
        shapeForNode[key] = shape
        halfExtentForEntity[key] = halfExtent(for: element)
        node.components.set(InputTargetComponent())
        node.components.set(HoverEffectComponent())
        node.components.set(CollisionComponent(shapes: [shape]))
        let effect = element.animation?.emphasis?.effect ?? .pulse
        if effect != .none { emphasisMap[key] = effect }

        // 3D primitives are always grabbable — pick them up, rotate, pinch-scale like
        // a real product, in play mode too. Models start with a reliable fallback
        // collider, then refresh to mesh bounds when their USDZ finishes loading.
        // Flat accents wait for edit.
        switch element.kind {
        case .model:
            modelNodes.insert(key)
            alwaysGrabNodes.insert(key)
            enableManipulation(node, shape: shape)
            if activeModelID == nil { activeModelID = element.id }   // page's first model = default ± target
        case .barChart, .scatter:
            alwaysGrabNodes.insert(key)
            enableManipulation(node, shape: shape)   // charts keep full native manipulation
        default:
            if isEditing { enableManipulation(node, shape: shape) }
        }
    }

    private func enableManipulation(_ node: Entity, shape: ShapeResource,
                                    allowsScaling: Bool = true,
                                    allowsRotation: Bool = true) {
        node.components.set(InputTargetComponent())
        node.components.set(HoverEffectComponent())
        node.components.set(CollisionComponent(shapes: [shape]))
        ManipulationComponent.configureEntity(node, collisionShapes: [shape])
        if var manip = node.components[ManipulationComponent.self] {
            manip.releaseBehavior = .stay
            manip.dynamics.inertia = .low
            manip.dynamics.translationBehavior = .unconstrained
            manip.dynamics.scalingBehavior = allowsScaling ? .unconstrained : .none
            manip.dynamics.primaryRotationBehavior = allowsRotation ? .unconstrained : .none
            manip.dynamics.secondaryRotationBehavior = allowsRotation ? .unconstrained : .none
            node.components.set(manip)
        }
    }
    private func disableManipulation(_ node: Entity) { node.components.remove(ManipulationComponent.self) }

    /// Makes a window (deck) grabbable like a physical object — move, scale,
    /// one- or two-handed rotate — staying where released.
    func makeManipulable(_ node: Entity, size: SIMD2<Float>) {
        enableManipulation(node, shape: .generateBox(size: [size.x, size.y, 0.05]))
    }

    /// Makes a panel repositionable by its top strip only (like a window bar), so
    /// the body stays free to scroll — used by the transcript board.
    func makeMovableByHandle(_ node: Entity, panelHalf h: SIMD2<Float>) {
        let handleHalf: Float = 0.03
        let shape = ShapeResource.generateBox(size: [h.x * 2, handleHalf * 2, 0.06])
            .offsetBy(translation: [0, h.y - handleHalf, 0])
        // Grab the top strip to move; a two-hand pinch on it scales the board, and hand
        // rotation re-faces it freely (360°, all axes — e.g. lay it flat on a desk), like
        // the deck panel. The remote's yaw ± is a precise shortcut. The body stays
        // collision-free, so it still scrolls.
        enableManipulation(node, shape: shape, allowsScaling: true, allowsRotation: true)
    }

    func resolve(_ tapped: Entity) -> (Entity, String)? {
        var cur: Entity? = tapped
        while let n = cur { if let id = elementForEntity[ObjectIdentifier(n)] { return (n, id) }; cur = n.parent }
        return nil
    }

    func setEditing(_ on: Bool) {
        isEditing = on
        // The far deck board is only movable/resizable while editing — locked when
        // presenting (so a stray pinch doesn't drag the screen mid-talk).
        if let deck = deckPanel {
            if on { makeManipulable(deck, size: [2.6, 1.4625]) }
            else { disableManipulation(deck) }
        }
        if on {
            for (_, node) in nodeForElement where !alwaysGrabNodes.contains(ObjectIdentifier(node)) {
                if let shape = shapeForNode[ObjectIdentifier(node)] { enableManipulation(node, shape: shape) }
            }
        } else {
            highlightElement(nil)
            for node in nodeForElement.values where !alwaysGrabNodes.contains(ObjectIdentifier(node)) {
                disableManipulation(node)   // keep 3D models grabbable
            }
        }
    }

    func highlightElement(_ id: String?) { select(id.flatMap { nodeForElement[$0] }) }

    private func select(_ node: Entity?) {
        guard node !== selectedNode else { return }
        selectionOutline?.removeFromParent()
        selectionOutline = nil
        selectedNode = node
        guard let node else { return }
        let outline = makeOutline(for: node)
        node.addChild(outline)
        selectionOutline = outline
    }

    private func makeOutline(for node: Entity) -> Entity {
        let half = halfExtentForEntity[ObjectIdentifier(node)] ?? [0.25, 0.16]
        let hx = half.x, hy = half.y, t: Float = 0.01, z: Float = 0.04
        let material = UnlitMaterial(color: UIColor(hex: "#5AC8FA"))
        let frame = Entity()
        func bar(_ w: Float, _ h: Float, _ x: Float, _ y: Float) {
            let b = ModelEntity(mesh: .generateBox(size: [w, h, t]), materials: [material])
            b.position = [x, y, z]; frame.addChild(b)
        }
        bar(2 * hx + t, t, 0, hy); bar(2 * hx + t, t, 0, -hy)
        bar(t, 2 * hy + t, -hx, 0); bar(t, 2 * hy + t, hx, 0)
        return frame
    }

    @discardableResult
    func playEmphasisIfTarget(_ tapped: Entity) -> Bool {
        var cur: Entity? = tapped
        while let n = cur, emphasisMap[ObjectIdentifier(n)] == nil { cur = n.parent }
        guard let node = cur, let effect = emphasisMap[ObjectIdentifier(node)] else { return false }
        playEmphasis(node, effect)
        return true
    }

    private func playEmphasis(_ node: Entity, _ effect: EmphasisEffect) {
        let base = node.transform
        var peak = base
        peak.scale = base.scale * 1.2
        node.move(to: peak, relativeTo: node.parent, duration: 0.16, timingFunction: .easeOut)
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(0.16))
            node.move(to: base, relativeTo: node.parent, duration: 0.24, timingFunction: .easeInOut)
        }
    }
}

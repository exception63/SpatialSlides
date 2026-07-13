//
//  Carousel.swift
//  Spatial Slides
//
//  The page carousel — an iTunes-cover-flow-style wheel in front of the viewer.
//  The CURRENT page always sits front-and-centre; a window of ~5 pages on each
//  side fans out and tilts away (cover-flow), the rest hidden. Gaze + pinch + a
//  left/right drag spins it; release snaps to the nearest page; tapping a card
//  jumps straight to it. Thumbnails are the pre-rendered per-page PNGs.
//

import SwiftUI
import RealityKit
import simd
import UIKit
import ImageIO

// MARK: - Card

struct CarouselCard: View {
    let page: ShowPage
    var isCurrent: Bool = false

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            if let img = thumb {
                Image(uiImage: img).resizable().scaledToFill()
            } else {
                LinearGradient(colors: [Color(hex: "#26324C"), Color(hex: "#3A2340")],
                               startPoint: .topLeading, endPoint: .bottomTrailing)
                Text(page.title).font(.system(size: 24, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.9)).lineLimit(3).padding(16)
            }
            Text("\(page.index + 1)")
                .font(.system(size: 19, weight: .bold, design: .rounded)).monospacedDigit()
                .foregroundStyle(.white)
                .padding(.horizontal, 9).padding(.vertical, 4)
                .background(.black.opacity(0.55), in: Capsule()).padding(10)
        }
        .frame(width: Carousel.frameSize.width, height: Carousel.frameSize.height)
        .background(Color(hex: "#0C1018"), in: .rect(cornerRadius: 14))
        .clipShape(.rect(cornerRadius: 14))
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                .strokeBorder(isCurrent ? Color.accentColor : .white.opacity(0.18),
                              lineWidth: isCurrent ? 6 : 1)
        )
        // NOTE: no glassBackgroundEffect here. A ring of ~9–11 live glass panels is a
        // heavy real-time backdrop-blur cost — it dropped the whole scene's frame rate
        // (carousel spin AND near-element build-ins looked low-fps on element pages).
        // Thumbnails are opaque images, so a solid backing + border reads just as well.
    }

    private var thumb: UIImage? { ThumbnailCache.image(page.thumbnail) }
}

/// Decoded thumbnails are cached AND downsampled. `CarouselCard.body` re-evaluates on
/// every page change (re-reading a 1280×720 PNG from disk each time hitched), and a
/// card only renders ~420 pt wide — decoding the full 1280×720 wastes ~4× the memory
/// (44 cards × 3.7 MB ≈ 160 MB → ≈ 40 MB). ImageIO decodes straight to a small size.
enum ThumbnailCache {
    private static let cache = NSCache<NSString, UIImage>()
    private static let maxPixel = 640   // covers a ~420 pt card with headroom

    static func image(_ relativePath: String) -> UIImage? {
        guard !relativePath.isEmpty, let url = DeckLoader.assetURL(relativePath) else { return nil }
        let key = url.path as NSString
        if let hit = cache.object(forKey: key) { return hit }
        guard let img = downsampled(url) else { return nil }
        cache.setObject(img, forKey: key)
        return img
    }

    private static func downsampled(_ url: URL) -> UIImage? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary) else {
            return UIImage(contentsOfFile: url.path)
        }
        let opts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
        ]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary) else {
            return UIImage(contentsOfFile: url.path)
        }
        return UIImage(cgImage: cg)
    }
}

// MARK: - Cover-flow geometry

enum Carousel {
    static let frameSize = CGSize(width: 420, height: 236)   // bigger thumbnails (16:9)
    static let radius: Float = 0.62      // front card ≈ 60 cm away
    static let y: Float = 1.16           // ring height (in front of the viewer, a touch low)
    static let window = 4                // show current ± this many (~9 cards); rest hidden (fewer = lighter)

    static let cardHalf = SIMD2<Float>(Float(frameSize.width) / 1360 / 2,
                                       Float(frameSize.height) / 1360 / 2)
    static var collisionSize: SIMD3<Float> { [cardHalf.x * 2, cardHalf.y * 2, 0.02] }

    struct Slot { var position: SIMD3<Float>; var yaw: Float; var scale: Float; var opacity: Float; var visible: Bool }

    /// Cover-flow placement for a card at fractional offset `f` (= index − scrollPos).
    /// Front (f≈0) is flat and largest; neighbours fan out, recede, and tilt. Depth is
    /// carried by scale + tilt + position — NOT opacity — so cards stay OPAQUE and out
    /// of the expensive transparent-render pass. Only the single outermost card fades,
    /// purely so it doesn't pop in/out at the window edge.
    static func slot(f: Float) -> Slot {
        let a = abs(f)
        let visible = a <= Float(window) + 0.5
        let sign: Float = f < 0 ? -1 : 1
        let x = sign * (min(a, 1) * 0.30 + max(a - 1, 0) * 0.155)
        let z = -radius - a * 0.05
        let scale = max(0.5, 1 - a * 0.11)
        let yaw = -sign * min(a, 1) * 0.52          // ~30° cover-flow tilt; front flat
        let fadeStart = Float(window) - 0.5          // opaque through the window…
        let opacity: Float = !visible ? 0 : (a <= fadeStart ? 1 : max(0, Float(window) + 0.5 - a))
        return Slot(position: [x, y, z], yaw: yaw, scale: scale, opacity: opacity, visible: visible)
    }
}

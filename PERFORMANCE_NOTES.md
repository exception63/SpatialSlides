# Spatial Slides Performance Notes

## 2026-07-13: USDZ scaling and carousel jank

### USDZ models did not scale reliably

Loaded USDZ files arrive as an entity subtree. If any child in that subtree keeps
its own collision or input target, a two-handed pinch can resolve the two hands to
different entities. Single-hand movement may still work, but the two-hand scale
gesture never pairs on the wrapper entity that owns `ManipulationComponent`.

The fix keeps the loaded USDZ subtree passive and makes the wrapper the only hit
target. The wrapper gets a fallback collision box immediately, then refreshes to a
bounds-matched collision box after the USDZ has loaded and settled.

### Carousel animation janked on specific target pages

The carousel transform math was not the main bottleneck. The slow targets were
content-heavy HTML slides. Switching the far WKWebView to those pages forced a
large first-frame rasterization and also ran the deck's regular navigation work:
class toggles across all slides, hidden outline/thumb/progress updates, and the
slide build/count-up observer. That work shared the same moment as the carousel
spin, so the wheel appeared to stutter only when the destination slide was heavy.

The fix separates the expensive page commit from the wheel motion:

- Carousel cards now animate through a lightweight `SceneEvents.Update` tween.
- A tap or drag first moves the wheel to the requested card.
- `currentPage` is committed after the wheel reaches the target.
- The WKWebView uses an injected present-mode fast switcher that only hides the
  previous slide and shows the requested slide. It avoids the deck's hidden
  outline/thumb/progress updates and build/count-up observer during immersive use.

The original HTML deck can still keep its animations in a normal browser or
presenter setting. In the immersive app, those animations are intentionally
dampened because the WKWebView is rendered as a large spatial surface; replaying
heavy DOM/SVG/CSS animation on every page change can still cause visible frame
drops on complex slides.

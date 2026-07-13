# Claude Code Handoff

## Current state

The app is a visionOS spatial presentation tool. One `currentPage` drives:

- a far WKWebView slide panel,
- a cover-flow carousel of slide thumbnails,
- near-field spatial elements such as text callouts and USDZ models,
- a native transcript panel.

The latest pushed baseline is `63b86be perf(carousel): smooth immersive navigation`.

## Issues fixed

### USDZ two-hand scaling

File: `Spatial Slides/ExhibitBuilder.swift`

USDZ assets load as entity subtrees. Child collisions/input targets can steal one
hand of a two-hand pinch, so scaling fails even when single-hand movement works.
The loaded model subtree is now made passive; the wrapper entity owns the input,
collision, and `ManipulationComponent`. It starts with a fallback collision box,
then refreshes to model bounds after the USDZ has loaded.

### Carousel jank on heavy target slides

Files:

- `Spatial Slides/HTMLPanel.swift`
- `Spatial Slides/StageView.swift`

The carousel itself was not the primary bottleneck. The hitch came from changing
the large spatial WKWebView to DOM/SVG-heavy slides at the same time as the wheel
animation. The deck's original navigation also updated hidden outline/thumb UI
and triggered build/count-up observers.

Current behavior:

- The carousel animation is driven by `SceneEvents.Update`.
- Tapping or dragging first moves the wheel to the target card.
- The app commits `currentPage` after the wheel arrives.
- The WKWebView uses an injected present-mode fast switcher that only hides the
  previous slide and shows the requested slide.
- HTML/CSS build animations are dampened in immersive mode on purpose.

The original HTML deck can still keep animations in a normal browser/presenter
context. In the immersive app, replaying those animations on a large spatial
WKWebView surface can still drop frames on complex slides.

## Latest local change to preserve

Files:

- `Spatial Slides/Carousel.swift`
- `Spatial Slides/StageView.swift`

The frosted-glass carousel thumbnail experiment was reverted because it looked
soft and visually noisy. The thumbnail cards are back to the clean image-card
style. Thumbnail cache decoding now uses `maxPixel = 1256`, matching the source
thumbnail size, because the previous `640` decode looked blurry in the headset.
The extra blue RealityKit current-card outline was removed.

Avoid reintroducing live `glassBackgroundEffect` on every carousel card unless
you profile it on device. A ring of live backdrop-blur panels is expensive in an
immersive scene.

## Validation command

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
xcodebuild -project "Spatial Slides.xcodeproj" \
  -scheme "Spatial Slides" \
  -configuration Debug \
  -destination "generic/platform=visionOS Simulator" \
  build
```

Expected result: `BUILD SUCCEEDED`. The AppIntents metadata warning is currently
benign because the app does not depend on AppIntents.

## Useful next directions

- Add a presenter-facing toggle for "performance mode" vs "original HTML motion".
- Consider rendering high-resolution static slide images for the far main panel
  during formal presentation, while keeping HTML as the editable/source deck.
- Add device-side profiling markers around WKWebView page commits and carousel
  animation ticks.
- Treat spatial elements as a semantic layer instead of only manually authored
  decorations: claims, evidence, objects, speaker cues, and audience attention
  targets should each get distinct spatial behaviors.

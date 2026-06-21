import SwiftUI
#if canImport(UIKit)
import UIKit
typealias PlatformImage = UIImage
#else
import AppKit
typealias PlatformImage = NSImage
#endif

/// Halftone dot field that fills the entire orb disc. Three behaviors play
/// out simultaneously:
///
///   1. **Inside-emoji dots** — render as a halftone of the glyph's
///      brightness (bright pixels grow big dots, dark pixels shrink). These
///      dots are static; they're not affected by the wave.
///
///   2. **Outline dots** — cells just outside the emoji's silhouette get a
///      brightness boost that traces the emoji's edge as a ring of dots,
///      visually outlining the shape.
///
///   3. **Outside-emoji dots** — animate as a living radial wave that
///      pulses outward from the orb's center. The wave's amplitude grows
///      with the live audio level (mic input when listening, TTS amplitude
///      when speaking), so the orb visibly "breathes" with the conversation.
///
/// When there's no emoji at all, the whole disc is wave dots — a calm
/// pulsing field. As soon as a glyph arrives, the silhouette emerges from
/// the wave with the outline ring tracing its edge.
struct HalftoneEmojiView: View {
    let glyph:       String?
    /// Fraction of the halftone canvas that the rendered emoji should
    /// occupy (0…1). Computed by the parent so the emoji's visible size
    /// stays correct even when the halftone canvas is larger than the
    /// orb disc (which it is, to leave room for the pulse to reveal more
    /// dots outside the disc).
    let emojiCoverage: CGFloat
    let color:       Color
    let density:     Double   // 0…1 → grid 12…40 per side
    /// Live amplitude that drives the wave (0…1). The parent supplies mic
    /// level when listening and TTS amplitude when speaking.
    let audioLevel:  Float

    @State private var cells: [Cell] = []
    @State private var lastGlyph:   String?  = nil
    @State private var lastDensity: Double   = -1
    @State private var lastFont:    CGFloat  = -1
    /// Timestamp of the most recent glyph change. When set, the canvas
    /// overlays a brief static burst that fades out over `transitionDuration`,
    /// giving the orb a glitchy "tuning in" feel between emoji changes.
    @State private var transitionStartedAt: Date? = nil
    /// Static phases: full static for `staticHoldDuration`, then linear
    /// fade-out from there to the end of `transitionDuration`. Tune these
    /// to make the glitch shorter or longer.
    private let transitionDuration:    TimeInterval = 0.40
    private let staticHoldDuration:    TimeInterval = 0.12

    private struct Cell {
        let normPoint:        CGPoint   // 0…1 within the disc bounds
        let radialFromCenter: CGFloat   // 0 at center, 0.5 at disc edge
        let glyphBrightness:  CGFloat   // 0 = outside glyph, 0…1 = inside
        let edgeDistance:     CGFloat   // 0 = touching glyph, +1 = far away
    }

    private var sideCount: Int {
        max(10, min(48, Int(14 + density * 30)))
    }

    /// Inside-glyph threshold. Cells with sampled brightness above this are
    /// treated as part of the emoji silhouette.
    private let insideThreshold: CGFloat = 0.10
    /// Exclusion halo around the emoji. Cells within this normalised distance
    /// of the silhouette have their wave brightness *shrunk* toward zero,
    /// producing a clean ring of negative space around the glyph so the
    /// emoji reads clearly instead of fighting the background dots.
    private let exclusionHalo: CGFloat = 0.10

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: false)) { context in
            Canvas { ctx, size in
                let cellSize = min(size.width, size.height) / CGFloat(sideCount)
                let maxRadius = cellSize * 0.48
                let resolved = ctx.resolve(.color(color))
                let time = context.date.timeIntervalSinceReferenceDate
                let audio = CGFloat(min(max(audioLevel, 0), 1))

                let hasGlyph  = !(glyph?.isEmpty ?? true)
                let staticMix = currentStaticMix(at: context.date)

                for cell in cells {
                    var b = brightness(
                        for: cell,
                        time: time,
                        audio: audio,
                        hasGlyph: hasGlyph
                    )

                    // During an emoji transition, blend the cell's normal
                    // brightness with a fresh random value so the orb
                    // briefly "tunes in" to the new glyph through static.
                    if staticMix > 0 {
                        let noise = CGFloat.random(in: 0 ... 1)
                        b = b * (1 - staticMix) + noise * staticMix
                    }

                    guard b > 0.03 else { continue }
                    let radius = b * maxRadius
                    guard radius > 0.3 else { continue }

                    let center = CGPoint(
                        x: cell.normPoint.x * size.width,
                        y: cell.normPoint.y * size.height
                    )
                    let rect = CGRect(
                        x: center.x - radius,
                        y: center.y - radius,
                        width:  radius * 2,
                        height: radius * 2
                    )
                    ctx.fill(Path(ellipseIn: rect), with: resolved)
                }
            }
        }
        .onAppear { regenerate() }
        .onChange(of: glyph ?? "") { _ in
            // Punch in the glitch transition the moment the glyph swaps so
            // the user perceives a quick "tuning in" before the new emoji
            // emerges from the static.
            transitionStartedAt = Date()
            regenerate()
        }
        .onChange(of: density)        { _ in regenerate() }
        .onChange(of: emojiCoverage)  { _ in regenerate() }
    }

    /// Returns 0…1: 1 = pure static, 0 = no static. Hold full static for
    /// `staticHoldDuration`, then linear fade out across the rest of
    /// `transitionDuration`. Past that, no transition is active.
    private func currentStaticMix(at now: Date) -> CGFloat {
        guard let start = transitionStartedAt else { return 0 }
        let elapsed = now.timeIntervalSince(start)
        if elapsed >= transitionDuration { return 0 }
        if elapsed < staticHoldDuration  { return 1 }
        let fadeWindow = transitionDuration - staticHoldDuration
        return CGFloat(1.0 - (elapsed - staticHoldDuration) / fadeWindow)
    }

    /// Final per-cell brightness combining glyph, exclusion halo, and wave.
    private func brightness(
        for cell: Cell,
        time: TimeInterval,
        audio: CGFloat,
        hasGlyph: Bool
    ) -> CGFloat {
        // 1. Inside the emoji silhouette → static halftone brightness.
        if cell.glyphBrightness >= insideThreshold {
            return cell.glyphBrightness
        }

        // 2. Wave field. With NO emoji on screen, a lighthearted radial wave
        // is allowed to breathe across the orb so the field feels alive
        // even before audio arrives. With an emoji present the wave is
        // damped hard so it doesn't compete with the glyph.
        let freq:  Double = 9
        let speed: Double = 1.4
        let phase = Double(cell.radialFromCenter) * freq - time * speed
        let wave  = sin(phase) * 0.5 + 0.5   // 0…1

        // Wave swing — visibly alive at idle so the orb is never static,
        // but heavily damped when an emoji is on screen so the glyph stays
        // the visual focus.
        let baseFloor: CGFloat = hasGlyph ? 0.13 : 0.16
        let baseSwing: CGFloat = hasGlyph ? 0.04 : 0.18
        // Audio multiplier — full wave-driven pulse when no emoji; gentle
        // when an emoji is on screen so the glyph stays the focus.
        let audioMul:  CGFloat = hasGlyph ? 0.20 : 0.45

        let base       = baseFloor + baseSwing * CGFloat(wave)
        let audioGain  = audio * audioMul * CGFloat(wave)
        var brightness = base + audioGain

        // 3. Exclusion halo: dots near the emoji's silhouette SHRINK toward
        // zero so a clean ring of negative space surrounds the glyph,
        // letting the emoji read clearly against the background.
        if hasGlyph && cell.edgeDistance.isFinite && cell.edgeDistance < exclusionHalo {
            let fadeIn = cell.edgeDistance / exclusionHalo   // 0 at silhouette edge, 1 at halo rim
            brightness *= fadeIn
        }

        return min(brightness, 1.0)
    }

    // MARK: - Cell regeneration

    @MainActor
    private func regenerate() {
        let g = glyph ?? ""
        let count = sideCount

        // Skip if nothing changed.
        if g == (lastGlyph ?? "") && density == lastDensity && emojiCoverage == lastFont && !cells.isEmpty {
            return
        }
        lastGlyph   = g.isEmpty ? nil : g
        lastDensity = density
        lastFont    = emojiCoverage

        // Sample brightness at fixed off-screen resolution so density changes
        // don't shift the underlying glyph signal.
        let renderSide: CGFloat = 192
        let glyphGrid: [[CGFloat]]
        if g.isEmpty {
            glyphGrid = Array(repeating: Array(repeating: 0, count: count), count: count)
        } else {
            let raster = renderGlyphImage(glyph: g,
                                          fontSize: renderSide * emojiCoverage,
                                          side: renderSide)
            let pixels = grayscalePixels(from: raster)
            glyphGrid = (0 ..< count).map { y in
                (0 ..< count).map { x in
                    let nx = (CGFloat(x) + 0.5) / CGFloat(count)
                    let ny = (CGFloat(y) + 0.5) / CGFloat(count)
                    let px = Int(nx * renderSide)
                    let py = Int(ny * renderSide)
                    return pixels?.brightness(atX: px, y: py) ?? 0
                }
            }
        }

        // Build a distance field from non-silhouette cells to the nearest
        // silhouette cell, normalised to 0…1 of the side length.
        let distField = computeDistanceField(
            glyphGrid: glyphGrid,
            threshold: insideThreshold,
            sideCount: count
        )

        var newCells: [Cell] = []
        newCells.reserveCapacity(count * count)
        for y in 0 ..< count {
            for x in 0 ..< count {
                let nx = (CGFloat(x) + 0.5) / CGFloat(count)
                let ny = (CGFloat(y) + 0.5) / CGFloat(count)
                let dx = nx - 0.5
                let dy = ny - 0.5
                let r  = sqrt(dx * dx + dy * dy)
                // Clip dots to the visible disc (with a tiny safety margin).
                guard r <= 0.485 else { continue }
                newCells.append(Cell(
                    normPoint:        CGPoint(x: nx, y: ny),
                    radialFromCenter: r,
                    glyphBrightness:  glyphGrid[y][x],
                    edgeDistance:     distField[y][x]
                ))
            }
        }
        cells = newCells
    }

    /// Brute-force 2-D distance field. For each cell outside the silhouette,
    /// store the Euclidean distance to the nearest cell inside the
    /// silhouette, divided by `sideCount` so the value is in normalised
    /// units (0…~1). Cells inside the silhouette get 0. If the glyph is
    /// absent, every cell gets `.infinity` so the outline boost is skipped.
    private func computeDistanceField(
        glyphGrid: [[CGFloat]],
        threshold: CGFloat,
        sideCount: Int
    ) -> [[CGFloat]] {
        var inside: [(Int, Int)] = []
        inside.reserveCapacity(sideCount * sideCount / 4)
        for y in 0 ..< sideCount {
            for x in 0 ..< sideCount {
                if glyphGrid[y][x] >= threshold { inside.append((x, y)) }
            }
        }

        var dist = Array(
            repeating: Array(repeating: CGFloat.infinity, count: sideCount),
            count: sideCount
        )
        guard !inside.isEmpty else { return dist }   // no glyph → all infinity

        let inv = 1.0 / CGFloat(sideCount)
        for y in 0 ..< sideCount {
            for x in 0 ..< sideCount {
                if glyphGrid[y][x] >= threshold {
                    dist[y][x] = 0
                    continue
                }
                var minD: CGFloat = .infinity
                for (px, py) in inside {
                    let dx = CGFloat(x - px)
                    let dy = CGFloat(y - py)
                    let d  = sqrt(dx * dx + dy * dy)
                    if d < minD { minD = d }
                }
                dist[y][x] = minD * inv
            }
        }
        return dist
    }

    // MARK: - Glyph rasterisation

    @MainActor
    private func renderGlyphImage(glyph: String, fontSize: CGFloat, side: CGFloat) -> PlatformImage {
        let renderer = ImageRenderer(content:
            Text(glyph)
                .font(.system(size: fontSize))
                .frame(width: side, height: side)
        )
        renderer.scale = 1.0
        renderer.isOpaque = false
#if canImport(UIKit)
        return renderer.uiImage ?? UIImage()
#else
        return renderer.nsImage ?? NSImage()
#endif
    }

    private struct PixelGrid {
        let bytes:        UnsafePointer<UInt8>
        let bytesPerRow:  Int
        let bytesPerPixel: Int
        let width:        Int
        let height:       Int
        let data:         CFData

        func brightness(atX x: Int, y: Int) -> CGFloat {
            let sx = max(0, min(width - 1, x))
            let sy = max(0, min(height - 1, y))
            let offset = sy * bytesPerRow + sx * bytesPerPixel
            let r = CGFloat(bytes[offset])     / 255
            let g = CGFloat(bytes[offset + 1]) / 255
            let b = CGFloat(bytes[offset + 2]) / 255
            let a = CGFloat(bytes[offset + 3]) / 255
            let luma = 0.299 * r + 0.587 * g + 0.114 * b
            return luma * a
        }
    }

    private func grayscalePixels(from image: PlatformImage) -> PixelGrid? {
        guard let cgImage = image.cgImage,
              let provider = cgImage.dataProvider,
              let data = provider.data,
              let bytes = CFDataGetBytePtr(data)
        else { return nil }
        return PixelGrid(
            bytes:         bytes,
            bytesPerRow:   cgImage.bytesPerRow,
            bytesPerPixel: cgImage.bitsPerPixel / 8,
            width:         cgImage.width,
            height:        cgImage.height,
            data:          data
        )
    }
}

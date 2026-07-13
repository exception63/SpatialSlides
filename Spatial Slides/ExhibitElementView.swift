//
//  ExhibitElementView.swift
//  Spatial Slides
//
//  SwiftUI content for the near-field spatial accents (the ~0.5 m layer): text,
//  key lines, stats, tables, images — each grounded on a native visionOS glass
//  panel so it reads as a solid object floating in front of the far slide. Charts
//  and models are RealityKit entities (see ExhibitBuilder).
//

import SwiftUI

struct ExhibitElementView: View {
    let element: ExhibitElement

    var body: some View {
        switch element.kind {
        case .title:
            panel {
                Text(element.text ?? "")
                    .font(.system(size: 46, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 44).padding(.vertical, 26)
            }

        case .statement:
            panel {
                VStack(spacing: 16) {
                    Text(element.text ?? "")
                        .font(.system(size: 60, weight: .heavy, design: .rounded))
                        .multilineTextAlignment(.center).foregroundStyle(.white)
                    if let sub = element.subtitle {
                        Text(sub).font(.system(size: 28, weight: .medium)).foregroundStyle(.secondary)
                    }
                }
                .padding(.horizontal, 56).padding(.vertical, 40)
            }

        case .text:
            panel {
                Text(element.text ?? "")
                    .font(.system(size: 34, weight: .medium))
                    .multilineTextAlignment(element.align == "left" ? .leading : .center)
                    .foregroundStyle(.white)
                    .padding(.horizontal, 40).padding(.vertical, 26)
                    .frame(maxWidth: 640)
            }

        case .bullets:
            panel {
                VStack(alignment: .leading, spacing: 20) {
                    ForEach(element.bullets ?? [], id: \.self) { line in
                        HStack(alignment: .firstTextBaseline, spacing: 16) {
                            Circle().fill(Color.accentColor).frame(width: 13, height: 13)
                            Text(line).font(.system(size: 32, weight: .medium)).foregroundStyle(.white)
                        }
                    }
                }
                .padding(40)
            }

        case .stat:
            panel {
                VStack(spacing: 6) {
                    Text(element.value ?? "")
                        .font(.system(size: 120, weight: .heavy, design: .rounded))
                        .foregroundStyle(LinearGradient(colors: [Color(hex: "#5AC8FA"), Color(hex: "#FF375F")],
                                                        startPoint: .leading, endPoint: .trailing))
                    Text(element.caption ?? "").font(.system(size: 28, weight: .medium)).foregroundStyle(.secondary)
                }
                .padding(.horizontal, 52).padding(.vertical, 36)
            }

        case .table:
            if let data = element.table { TableCard(data: data) } else { EmptyView() }

        case .image:
            ImageBoard(element: element)

        case .barChart, .scatter, .model:
            EmptyView()   // built as RealityKit entities
        }
    }

    /// Wraps content in the panel its `background` calls for: frosted glass, a
    /// cyber-neon key line, or bare/background-less.
    @ViewBuilder
    private func panel<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        switch element.background {
        case "none":
            content()
        case "glow":
            content().modifier(NeonGlow(corner: 30))
        default:
            content().glassBackgroundEffect(in: .rect(cornerRadius: 30))
        }
    }
}

/// Cyber-neon treatment for the near-field key lines: a dark panel with a cyan→magenta
/// glowing edge that breathes. Intentionally NO glass and NO drop-shadow — both are
/// offscreen render passes (real-time backdrop blur / shadow blur), which Apple flags
/// as very expensive on visionOS and which tanked the frame rate on element-heavy
/// pages. The neon read comes entirely from an opaque dark fill + a bright DOUBLE
/// stroke (a wider dim halo ring under a crisp bright ring) whose opacity breathes —
/// all cheap, blur-free compositing.
struct NeonGlow: ViewModifier {
    var corner: CGFloat = 30
    @State private var breathe = false

    private let cyan = Color(hex: "#00E5FF")
    private let magenta = Color(hex: "#FF2D9B")

    func body(content: Content) -> some View {
        let grad = LinearGradient(colors: [cyan, magenta], startPoint: .topLeading, endPoint: .bottomTrailing)
        return content
            .background(Color(hex: "#0B0E16").opacity(0.85), in: .rect(cornerRadius: corner))
            .overlay(   // wider, dim ring = a fake "glow" halo without a real blur pass
                RoundedRectangle(cornerRadius: corner + 3)
                    .strokeBorder(grad, lineWidth: 7)
                    .opacity(breathe ? 0.5 : 0.18)
            )
            .overlay(   // crisp bright ring on top
                RoundedRectangle(cornerRadius: corner)
                    .strokeBorder(grad, lineWidth: 2.5)
                    .opacity(breathe ? 1.0 : 0.6)
            )
            .onAppear {
                breathe = false
                withAnimation(.easeInOut(duration: 1.9).repeatForever(autoreverses: true)) { breathe = true }
            }
    }
}

/// An image accent: a transparent-content snapshot on the surface its `background`
/// calls for, sized to its authored physical size.
private let boardPointsPerMeter: CGFloat = 1360

private struct ImageBoard: View {
    let element: ExhibitElement

    var body: some View {
        let w = CGFloat(element.size?.x ?? 0.7) * boardPointsPerMeter
        let h = CGFloat(element.size?.y ?? 0.45) * boardPointsPerMeter
        let pad = min(w, h) * 0.08

        Group {
            if let ui = loadedImage { Image(uiImage: ui).resizable().scaledToFit() }
            else { Color.clear }
        }
        .frame(width: w, height: h)
        .modifier(BoardSurface(style: element.background ?? "glass", pad: pad))
    }

    private var loadedImage: UIImage? {
        if let asset = element.asset, let url = DeckLoader.assetURL(asset), let ui = UIImage(contentsOfFile: url.path) { return ui }
        if let name = element.imageName, !name.isEmpty { return UIImage(named: name) }
        return nil
    }
}

private struct BoardSurface: ViewModifier {
    let style: String
    let pad: CGFloat
    func body(content: Content) -> some View {
        switch style {
        case "none":
            content
        case "glow":
            content.padding(pad).modifier(NeonGlow(corner: 28))
        default:
            content.padding(pad).glassBackgroundEffect(in: .rect(cornerRadius: 28))
        }
    }
}

private struct TableCard: View {
    let data: TableData
    var body: some View {
        VStack(spacing: 4) {
            if data.header {
                row(data.columns, isHeader: true)
                Divider().overlay(Color.white.opacity(0.35))
            }
            ForEach(Array(data.rows.enumerated()), id: \.offset) { _, cells in row(cells, isHeader: false) }
        }
        .padding(28).frame(minWidth: 400)
        .glassBackgroundEffect(in: .rect(cornerRadius: 30))
    }
    private func row(_ cells: [String], isHeader: Bool) -> some View {
        HStack(spacing: 0) {
            ForEach(Array(cells.enumerated()), id: \.offset) { _, cell in
                Text(cell)
                    .font(.system(size: isHeader ? 28 : 26, weight: isHeader ? .bold : .regular, design: .rounded))
                    .foregroundStyle(isHeader ? Color(hex: "#5AC8FA") : .white)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 9).padding(.horizontal, 18)
            }
        }
    }
}

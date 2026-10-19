// Draws the Zapdrop app icon as a 1024 px PNG: a white brush-stroke arc on glossy black, bridging an Android
// phone (left) and a laptop (right). Both devices are generic drawings with no Apple or Google marks
// (App Review guideline 5.2.5, Android brand rules).
//   swift Scripts/make-icon.swift <output.png>
// Scripts/make-icon.sh turns it into App/Ferry/AppIcon.icns.
import AppKit
import SwiftUI

/// macOS icon grid: an 824 pt rounded square centred on a 1024 pt canvas.
let canvas: CGFloat = 1024
let tile: CGFloat = 824
let tileShape = RoundedRectangle(cornerRadius: tile * 0.225, style: .continuous)

func rgb(_ hex: UInt32) -> Color {
    Color(red: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255, blue: Double(hex & 0xFF) / 255)
}
let androidGreen = rgb(0x3DDC84)

// MARK: - Brush stroke

/// A cubic Bézier in unit coordinates (0…1 of the tile).
struct Segment { let p0, c1, c2, p1: CGPoint }

func point(on s: Segment, at t: CGFloat) -> CGPoint {
    let u = 1 - t
    let a = u * u * u, b = 3 * u * u * t, c = 3 * u * t * t, d = t * t * t
    return CGPoint(x: a * s.p0.x + b * s.c1.x + c * s.c2.x + d * s.p1.x,
                   y: a * s.p0.y + b * s.c1.y + c * s.c2.y + d * s.p1.y)
}

/// A tapered brush stroke: segments plus a width profile (position along the stroke 0…1 → width in tile units).
struct BrushStroke {
    let segments: [Segment]
    let widths: [(CGFloat, CGFloat)]

    func width(at t: CGFloat) -> CGFloat {
        guard let i = widths.firstIndex(where: { $0.0 >= t }) else { return widths.last!.1 }
        if i == 0 { return widths[0].1 }
        let (t0, w0) = widths[i - 1], (t1, w1) = widths[i]
        let f = (t - t0) / max(t1 - t0, 0.0001)
        return w0 + (w1 - w0) * (f * f * (3 - 2 * f))
    }

    /// Stamps overlapping round nibs densely along the curve, like ink from a brush.
    func path(in rect: CGRect) -> Path {
        let steps = 900
        var path = Path()
        for (si, s) in segments.enumerated() {
            for k in 0...steps {
                let t = CGFloat(k) / CGFloat(steps)
                let along = CGFloat(si * steps + k) / CGFloat(segments.count * steps)
                let p = point(on: s, at: t)
                let r = width(at: along) * rect.width / 2
                let c = CGPoint(x: rect.minX + p.x * rect.width, y: rect.minY + p.y * rect.height)
                path.addEllipse(in: CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r))
            }
        }
        return path
    }
}

func P(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: x, y: y) }

/// The bridge: a single brush-stroke arc, slightly heavier at the top, landing on top of each device.
let bridge = BrushStroke(
    segments: [Segment(p0: P(0.22, 0.56), c1: P(0.30, 0.18), c2: P(0.70, 0.18), p1: P(0.78, 0.56))],
    widths: [(0.0, 0.020), (0.2, 0.036), (0.5, 0.046), (0.8, 0.036), (1.0, 0.020)])

// MARK: - Tile

/// Glossy black, like lacquer: a soft sheen across the top and a fine rim.
struct BlackTile: View {
    var body: some View {
        ZStack {
            tileShape.fill(LinearGradient(colors: [rgb(0x2C2C30), rgb(0x141416), rgb(0x0A0A0B)], startPoint: .top, endPoint: .bottom))
            tileShape.fill(LinearGradient(colors: [Color.white.opacity(0.13), .clear], startPoint: .top, endPoint: .center))
                .mask(Ellipse().frame(width: tile * 1.4, height: tile * 0.9).offset(y: -tile * 0.42))
            tileShape.strokeBorder(LinearGradient(colors: [Color.white.opacity(0.30), Color.white.opacity(0.04)],
                                                  startPoint: .top, endPoint: .bottom), lineWidth: 4)
        }
        .frame(width: tile, height: tile)
        .shadow(color: .black.opacity(0.35), radius: 24, y: 12)
    }
}

// MARK: - Devices

/// A modern Android-style phone: metal frame, punch-hole camera, colourful wallpaper, app icons, gesture bar.
struct Phone: View {
    var body: some View {
        let w = tile * 0.15, h = tile * 0.31
        let frame = RoundedRectangle(cornerRadius: w * 0.19, style: .continuous)
        let screen = RoundedRectangle(cornerRadius: w * 0.14, style: .continuous)
        let bezel = w * 0.055
        let sw = w - 2 * bezel
        let icon = sw * 0.19
        let iconColors: [[Color]] = [[rgb(0xFF8A65), rgb(0x64B5F6), rgb(0xFFD54F)], [rgb(0xBA68C8), androidGreen, rgb(0x4DD0E1)]]
        ZStack {
            // Volume and power keys on the right edge.
            VStack(spacing: h * 0.035) {
                Capsule().fill(rgb(0x9AA2AD)).frame(width: w * 0.045, height: h * 0.12)
                Capsule().fill(rgb(0x9AA2AD)).frame(width: w * 0.045, height: h * 0.07)
            }
            .offset(x: w * 0.515, y: -h * 0.17)
            frame.fill(LinearGradient(colors: [rgb(0x41464F), rgb(0x1A1D21)], startPoint: .top, endPoint: .bottom))
            frame.strokeBorder(LinearGradient(colors: [rgb(0xE3E7EC), rgb(0x6B727C), rgb(0xB8BEC6)], startPoint: .topLeading,
                                              endPoint: .bottomTrailing), lineWidth: w * 0.022)
            ZStack {
                // Wallpaper: Android green flowing into teal, with a soft light bloom.
                screen.fill(LinearGradient(colors: [rgb(0xB9F8D3), androidGreen, rgb(0x1A9E8F), rgb(0x0E5E6B)],
                                           startPoint: .top, endPoint: .bottom))
                screen.fill(RadialGradient(colors: [Color.white.opacity(0.55), .clear], center: .init(x: 0.25, y: 0.22),
                                           startRadius: 0, endRadius: sw * 0.75))
                VStack(spacing: 0) {
                    // Status bar: time on the left, signal and battery on the right.
                    HStack {
                        Capsule().fill(Color.white.opacity(0.9)).frame(width: sw * 0.18, height: sw * 0.045)
                        Spacer()
                        Capsule().fill(Color.white.opacity(0.9)).frame(width: sw * 0.14, height: sw * 0.045)
                    }
                    .padding(.horizontal, sw * 0.10)
                    .padding(.top, sw * 0.09)
                    Spacer()
                    // Two rows of colourful app icons and a search pill.
                    VStack(spacing: icon * 0.5) {
                        ForEach(0..<2, id: \.self) { row in
                            HStack(spacing: icon * 0.42) {
                                ForEach(0..<3, id: \.self) { col in
                                    Circle().fill(iconColors[row][col]).frame(width: icon, height: icon)
                                        .overlay(Circle().fill(Color.white.opacity(0.35)).frame(width: icon * 0.45).offset(x: -icon * 0.12, y: -icon * 0.12))
                                }
                            }
                        }
                        Capsule().fill(Color.white.opacity(0.85)).frame(width: sw * 0.72, height: icon * 0.75)
                    }
                    .padding(.bottom, sw * 0.20)
                    Capsule().fill(Color.white.opacity(0.92)).frame(width: sw * 0.34, height: sw * 0.035)
                        .padding(.bottom, sw * 0.07)
                }
                Circle().fill(rgb(0x07090B)).frame(width: w * 0.085, height: w * 0.085)
                    .frame(maxHeight: .infinity, alignment: .top).padding(.top, sw * 0.075)
                // Glass reflection across the screen.
                screen.fill(LinearGradient(colors: [Color.white.opacity(0.22), .clear], startPoint: .topLeading, endPoint: .center))
            }
            .clipShape(screen)
            .padding(bezel)
        }
        .frame(width: w, height: h)
        .shadow(color: .black.opacity(0.55), radius: 14, y: 8)
        .shadow(color: androidGreen.opacity(0.45), radius: 22)
    }
}

/// A generic aluminium laptop: thin bezels, colourful wallpaper with app windows, a base with a front notch.
struct Laptop: View {
    var body: some View {
        let w = tile * 0.30, h = tile * 0.195
        let lid = RoundedRectangle(cornerRadius: w * 0.045, style: .continuous)
        let screen = RoundedRectangle(cornerRadius: w * 0.022, style: .continuous)
        let aluminium = LinearGradient(colors: [rgb(0xF4F6F9), rgb(0xC9CFD8), rgb(0xA9B0BB)], startPoint: .top, endPoint: .bottom)
        VStack(spacing: 0) {
            ZStack {
                lid.fill(aluminium)
                lid.fill(rgb(0x0B0C0F)).padding(w * 0.012)
                ZStack {
                    // Wallpaper: indigo into violet and coral, with two app windows.
                    screen.fill(LinearGradient(colors: [rgb(0x3B4BDB), rgb(0x8E4FD9), rgb(0xF07A8A)],
                                               startPoint: .topLeading, endPoint: .bottomTrailing))
                    screen.fill(RadialGradient(colors: [rgb(0x7FE3FF).opacity(0.55), .clear], center: .init(x: 0.85, y: 0.15),
                                               startRadius: 0, endRadius: w * 0.5))
                    window.frame(width: w * 0.40, height: h * 0.40).offset(x: -w * 0.16, y: -h * 0.06)
                    window.frame(width: w * 0.34, height: h * 0.34).offset(x: w * 0.16, y: h * 0.12)
                    screen.fill(LinearGradient(colors: [Color.white.opacity(0.20), .clear], startPoint: .topLeading, endPoint: .center))
                }
                .clipShape(screen)
                .padding(w * 0.035)
            }
            .frame(width: w, height: h)
            // Base: a slim slab with a finger notch at the front.
            ZStack(alignment: .top) {
                UnevenRoundedRectangle(topLeadingRadius: w * 0.01, bottomLeadingRadius: w * 0.05, bottomTrailingRadius: w * 0.05,
                                       topTrailingRadius: w * 0.01)
                    .fill(LinearGradient(colors: [rgb(0xEEF1F5), rgb(0x9DA4AF)], startPoint: .top, endPoint: .bottom))
                    .frame(width: w * 1.18, height: h * 0.075)
                UnevenRoundedRectangle(topLeadingRadius: 0, bottomLeadingRadius: w * 0.02, bottomTrailingRadius: w * 0.02,
                                       topTrailingRadius: 0)
                    .fill(rgb(0x8C939E))
                    .frame(width: w * 0.16, height: h * 0.028)
            }
        }
        .shadow(color: .black.opacity(0.55), radius: 14, y: 8)
        .shadow(color: Color.white.opacity(0.18), radius: 20)
    }

    /// A small app window: title bar with three dots, then content lines.
    private var window: some View {
        GeometryReader { g in
            let r = RoundedRectangle(cornerRadius: g.size.width * 0.06, style: .continuous)
            VStack(spacing: 0) {
                HStack(spacing: g.size.width * 0.04) {
                    ForEach(0..<3, id: \.self) { _ in Circle().fill(Color.white.opacity(0.7)).frame(width: g.size.width * 0.06) }
                    Spacer()
                }
                .padding(.horizontal, g.size.width * 0.07)
                .frame(height: g.size.height * 0.22)
                .background(Color.white.opacity(0.35))
                VStack(alignment: .leading, spacing: g.size.height * 0.08) {
                    ForEach([0.8, 0.6, 0.7], id: \.self) { f in
                        Capsule().fill(Color.white.opacity(0.55)).frame(width: g.size.width * f, height: g.size.height * 0.08)
                    }
                }
                .padding(g.size.width * 0.08)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
            .background(Color.white.opacity(0.22))
            .clipShape(r)
            .overlay(r.strokeBorder(Color.white.opacity(0.45), lineWidth: 1.5))
        }
    }
}

// MARK: - Icon

struct Icon: View {
    var body: some View {
        ZStack {
            BlackTile()
            Canvas { ctx, size in ctx.fill(bridge.path(in: CGRect(origin: .zero, size: size)), with: .color(.white)) }
                .frame(width: tile, height: tile)
                .shadow(color: .black.opacity(0.35), radius: 8, y: 5)
            // Devices at 80 %, their tops where the arc lands.
            Phone().scaleEffect(0.80).offset(x: -tile * 0.28, y: tile * 0.184)
            Laptop().scaleEffect(0.80).offset(x: tile * 0.28, y: tile * 0.142)
        }
        .frame(width: canvas, height: canvas)
    }
}

@MainActor
func render(to path: String) throws {
    let renderer = ImageRenderer(content: Icon())
    renderer.scale = 1
    renderer.isOpaque = false
    guard let image = renderer.cgImage,
          let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else {
        throw NSError(domain: "icon", code: 1)
    }
    try png.write(to: URL(fileURLWithPath: path))
}

let output = CommandLine.arguments.dropFirst().first ?? "AppIcon-1024.png"
try MainActor.assumeIsolated { try render(to: output) }
print("Wrote \(output)")

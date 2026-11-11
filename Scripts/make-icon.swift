// Draws the Zapdrop app icon as a 1024 px PNG: videos, documents, music and photos streaming out of an Android-style
// phone whose gallery holds all of them, on a warm sunset gradient. The phone and every card are generic drawings
// with no Apple or Google marks (App Review guideline 5.2.5, Android brand rules).
//   swift Scripts/make-icon.swift <output.png>
// Scripts/make-icon.sh turns it into App/Zapdrop/AppIcon.icns.
import AppKit
import SwiftUI

/// macOS icon grid: an 824 pt rounded square centred on a 1024 pt canvas.
let canvas: CGFloat = 1024
let tile: CGFloat = 824
let tileShape = RoundedRectangle(cornerRadius: tile * 0.225, style: .continuous)

func rgb(_ hex: UInt32, _ alpha: Double = 1) -> Color {
    Color(red: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255, blue: Double(hex & 0xFF) / 255)
        .opacity(alpha)
}
func P(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: x, y: y) }
/// Tile coordinates (0…1 of the tile) to points.
func T(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: x * tile, y: y * tile) }
func polyline(_ pts: [CGPoint]) -> Path { var p = Path(); p.addLines(pts); return p }

/// A closed polygon in unit coordinates (0…1 of its frame).
struct Poly: Shape {
    let pts: [CGPoint]
    func path(in r: CGRect) -> Path {
        var p = Path()
        p.addLines(pts.map { CGPoint(x: r.minX + $0.x * r.width, y: r.minY + $0.y * r.height) })
        p.closeSubpath()
        return p
    }
}

/// SplitMix64, so the sparkles land in the same places on every run.
struct SeededGenerator {
    private var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func unit() -> CGFloat {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        z ^= z >> 31
        return CGFloat(z >> 11) / CGFloat(UInt64(1) << 53)
    }
}

let darkInk = rgb(0x111318)
let textLine = rgb(0xC5CBD3)
let playTriangle = Poly(pts: [P(0.38, 0.27), P(0.78, 0.5), P(0.38, 0.73)])

// MARK: - Content

/// A tiny landscape (sky, sun, two hill bands) standing in for a photo or a video frame.
struct PhotoScene: View {
    let i: Int
    var body: some View {
        let palettes: [(sky: [UInt32], sun: UInt32, far: UInt32, near: UInt32)] = [
            ([0xFF9A6B, 0xFFD27A], 0xFFF4D6, 0x9B5DE5, 0x5B2A86), // sunset
            ([0x4CC3FF, 0xBFEFFF], 0xFFE066, 0x5FBF8F, 0x2F8F5B), // meadow
            ([0x2E3192, 0xC86DD7], 0xFFD1F0, 0x4B2C82, 0x1F1446), // dusk
            ([0x7FDBFF, 0xFFF1C1], 0xFFFFFF, 0x00A6C8, 0xF7D59C), // beach
            ([0xFFB199, 0xFFE3A3], 0xFFFFFF, 0xE76F51, 0x8E3B2E), // desert
        ]
        let p = palettes[i % palettes.count]
        GeometryReader { g in
            ZStack {
                LinearGradient(colors: p.sky.map { rgb($0) }, startPoint: .top, endPoint: .bottom)
                Circle().fill(rgb(p.sun)).frame(width: g.size.width * 0.2, height: g.size.width * 0.2)
                    .position(x: g.size.width * 0.72, y: g.size.height * 0.32)
                Poly(pts: [P(0, 0.75), P(0.25, 0.42), P(0.45, 0.62), P(0.62, 0.38), P(1, 0.70), P(1, 1), P(0, 1)]).fill(rgb(p.far))
                Poly(pts: [P(0, 0.88), P(0.35, 0.70), P(0.7, 0.84), P(1, 0.76), P(1, 1), P(0, 1)]).fill(rgb(p.near))
            }
        }
    }
}

/// One tile of the phone's gallery: a photo, a video (photo with a play button) or a document.
struct GalleryTile: View {
    enum Kind { case photo, video, document }
    let kind: Kind
    let scene: Int
    var body: some View {
        GeometryReader { g in
            let m = min(g.size.width, g.size.height)
            ZStack {
                switch kind {
                case .document:
                    Color.white
                    VStack(alignment: .leading, spacing: m * 0.1) {
                        RoundedRectangle(cornerRadius: m * 0.05).fill(rgb(scene % 2 == 0 ? 0xE5484D : 0x3B82F6))
                            .frame(width: m * 0.32, height: m * 0.2)
                        ForEach([0.6, 0.45, 0.55], id: \.self) { f in Capsule().fill(textLine).frame(width: m * f, height: m * 0.07) }
                    }
                case .photo, .video:
                    PhotoScene(i: scene)
                    if kind == .video {
                        Circle().fill(Color.white.opacity(0.92)).frame(width: m * 0.38, height: m * 0.38)
                        playTriangle.fill(darkInk).frame(width: m * 0.38, height: m * 0.38)
                    }
                }
            }
        }
    }
}

/// The phone's gallery: a grid that cycles photo, video, photo, document.
struct Gallery: View {
    let cols: Int
    let rows: Int
    var body: some View {
        let kinds: [GalleryTile.Kind] = [.photo, .video, .photo, .document]
        GeometryReader { g in
            let gap = g.size.width * 0.045
            let cw = (g.size.width - gap * CGFloat(cols + 1)) / CGFloat(cols)
            let ch = (g.size.height - gap * CGFloat(rows + 1)) / CGFloat(rows)
            ZStack(alignment: .topLeading) {
                ForEach(0..<(cols * rows), id: \.self) { i in
                    GalleryTile(kind: kinds[i % kinds.count], scene: i * 3)
                        .frame(width: cw, height: ch)
                        .clipShape(RoundedRectangle(cornerRadius: min(cw, ch) * 0.14, style: .continuous))
                        .offset(x: gap + CGFloat(i % cols) * (cw + gap), y: gap + CGFloat(i / cols) * (ch + gap))
                }
            }
        }
    }
}

// MARK: - Phone

/// A modern Android-style phone: metal frame, punch-hole camera, a bright gallery on screen.
struct Phone: View {
    let w: CGFloat
    var body: some View {
        let h = w * 2.05
        let frame = RoundedRectangle(cornerRadius: w * 0.17, style: .continuous)
        let screen = RoundedRectangle(cornerRadius: w * 0.12, style: .continuous)
        ZStack {
            frame.fill(LinearGradient(colors: [rgb(0x464B55), rgb(0x16181C)], startPoint: .top, endPoint: .bottom))
            frame.strokeBorder(LinearGradient(colors: [rgb(0xF0F3F6), rgb(0x6B727C), rgb(0xC3C9D1)], startPoint: .topLeading,
                                              endPoint: .bottomTrailing), lineWidth: w * 0.025)
            ZStack {
                screen.fill(LinearGradient(colors: [rgb(0xFFFFFF), rgb(0xD8F7FF), rgb(0x8AD0FF)], startPoint: .top, endPoint: .bottom))
                Gallery(cols: 3, rows: 5).padding(.top, w * 0.16).padding(.bottom, w * 0.10).padding(.horizontal, w * 0.02)
                // Glass reflection across the screen.
                screen.fill(LinearGradient(colors: [Color.white.opacity(0.30), .clear], startPoint: .topLeading, endPoint: .center))
            }
            .clipShape(screen)
            .padding(w * 0.055)
            Circle().fill(Color.black).frame(width: w * 0.07, height: w * 0.07).offset(y: -h * 0.43)
        }
        .frame(width: w, height: h)
    }
}

// MARK: - Flying cards

/// A printed photo with a white border.
struct PhotoCard: View {
    let w: CGFloat
    let scene: Int
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: w * 0.07, style: .continuous).fill(Color.white)
            PhotoScene(i: scene).clipShape(RoundedRectangle(cornerRadius: w * 0.045, style: .continuous)).padding(w * 0.045)
        }
        .frame(width: w, height: w * 0.78)
    }
}

/// A film-strip frame with sprocket holes, a play button and a playback bar.
struct VideoCard: View {
    let w: CGFloat
    let scene: Int
    var body: some View {
        let h = w * 0.64, band = h * 0.13
        let shape = RoundedRectangle(cornerRadius: w * 0.06, style: .continuous)
        ZStack {
            shape.fill(darkInk)
            VStack(spacing: 0) {
                sprockets(band)
                PhotoScene(i: scene).frame(height: h - 2 * band)
                sprockets(band)
            }
            .clipShape(shape)
            Capsule().fill(Color.white.opacity(0.35)).frame(width: w * 0.78, height: h * 0.025)
                .overlay(alignment: .leading) { Capsule().fill(rgb(0xFF4D6D)).frame(width: w * 0.32, height: h * 0.025) }
                .offset(y: h / 2 - band - h * 0.07)
            ZStack {
                Circle().fill(Color.white.opacity(0.94))
                playTriangle.fill(darkInk)
            }
            .frame(width: h * 0.36, height: h * 0.36)
            .shadow(color: .black.opacity(0.35), radius: h * 0.04, y: h * 0.02)
        }
        .frame(width: w, height: h)
    }

    private func sprockets(_ band: CGFloat) -> some View {
        HStack(spacing: w * 0.04) {
            ForEach(0..<9, id: \.self) { _ in
                RoundedRectangle(cornerRadius: band * 0.15).fill(Color.white.opacity(0.85)).frame(width: w * 0.055, height: band * 0.48)
            }
        }
        .frame(width: w, height: band)
        .background(darkInk)
    }
}

/// A page with a folded corner, a coloured header block and lines of text.
struct DocumentCard: View {
    let w: CGFloat
    let accent: UInt32
    var body: some View {
        let fold: CGFloat = 0.24
        ZStack(alignment: .topLeading) {
            Poly(pts: [P(0, 0), P(1 - fold, 0), P(1, fold / 1.3), P(1, 1), P(0, 1)]).fill(Color.white)
            Poly(pts: [P(1 - fold, 0), P(1, fold / 1.3), P(1 - fold, fold / 1.3)]).fill(rgb(0xD3D9E1))
            RoundedRectangle(cornerRadius: w * 0.05, style: .continuous).fill(rgb(accent))
                .frame(width: w * 0.34, height: w * 0.24).offset(x: w * 0.12, y: w * 0.13)
            VStack(alignment: .leading, spacing: w * 0.075) {
                ForEach([0.76, 0.60, 0.70, 0.48, 0.66], id: \.self) { len in
                    Capsule().fill(textLine).frame(width: w * len, height: w * 0.05)
                }
            }
            .offset(x: w * 0.12, y: w * 0.50)
        }
        .frame(width: w, height: w * 1.3)
        .clipShape(RoundedRectangle(cornerRadius: w * 0.07, style: .continuous))
    }
}

/// A music file: two beamed notes on a teal-to-blue tile.
struct MusicCard: View {
    let w: CGFloat
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: w * 0.22, style: .continuous)
                .fill(LinearGradient(colors: [rgb(0x2DD4BF), rgb(0x0EA5E9), rgb(0x2563EB)], startPoint: .topLeading, endPoint: .bottomTrailing))
            Canvas { ctx, size in
                func s(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: x * size.width, y: y * size.height) }
                var stems = Path()
                stems.addLines([s(0.40, 0.30), s(0.76, 0.22), s(0.76, 0.32), s(0.40, 0.40)])
                stems.closeSubpath()
                stems.addRect(CGRect(origin: s(0.40, 0.30), size: CGSize(width: size.width * 0.06, height: size.height * 0.38)))
                stems.addRect(CGRect(origin: s(0.70, 0.22), size: CGSize(width: size.width * 0.06, height: size.height * 0.38)))
                ctx.fill(stems, with: .color(.white))
                for (x, y) in [(0.255, 0.70), (0.555, 0.62)] {
                    let head = Path(ellipseIn: CGRect(x: 0, y: 0, width: size.width * 0.20, height: size.height * 0.15))
                    ctx.fill(head.applying(CGAffineTransform(translationX: s(x, y).x, y: s(x, y).y).rotated(by: -0.35)), with: .color(.white))
                }
            }
        }
        .frame(width: w, height: w)
    }
}

enum Card {
    case photo(scene: Int), video(scene: Int), document(accent: UInt32), music
}

struct CardView: View {
    let card: Card
    let w: CGFloat
    var body: some View {
        Group {
            switch card {
            case .photo(let scene): PhotoCard(w: w, scene: scene)
            case .video(let scene): VideoCard(w: w, scene: scene)
            case .document(let accent): DocumentCard(w: w, accent: accent)
            case .music: MusicCard(w: w)
            }
        }
        .shadow(color: .black.opacity(0.32), radius: w * 0.08, y: w * 0.05)
    }
}

/// Where each card flies: small near the phone, big and close at the end. Later cards draw on top.
let cards: [(x: CGFloat, y: CGFloat, w: CGFloat, angle: Double, card: Card)] = [
    (0.37, 0.47, 0.075, -20, .music),
    (0.445, 0.375, 0.09, -14, .document(accent: 0xE5484D)),
    (0.535, 0.30, 0.15, -8, .photo(scene: 1)),
    (0.80, 0.27, 0.18, 14, .document(accent: 0x3B82F6)),
    (0.70, 0.315, 0.29, 7, .photo(scene: 0)),
    (0.66, 0.505, 0.34, -4, .video(scene: 3)),
]

// MARK: - Icon

/// Motion trails along the cards' path, and a scatter of four-point sparkles.
struct TrailsAndSparkles: View {
    var body: some View {
        Canvas { ctx, _ in
            let trail = [T(0.31, 0.58), T(0.37, 0.47), T(0.445, 0.375), T(0.535, 0.30), T(0.63, 0.40)]
            for i in 1..<trail.count {
                ctx.drawLayer { layer in
                    layer.addFilter(.blur(radius: 10))
                    layer.stroke(polyline([trail[i - 1], trail[i]]), with: .color(.white.opacity(0.5)),
                                 style: StrokeStyle(lineWidth: tile * (0.02 + CGFloat(i) * 0.012), lineCap: .round))
                }
            }
            var random = SeededGenerator(seed: 42)
            for _ in 0..<14 {
                let c = T(0.30 + random.unit() * 0.6, 0.06 + random.unit() * 0.62), r = tile * (0.012 + random.unit() * 0.024)
                var star = Path()
                star.move(to: CGPoint(x: c.x, y: c.y - r))
                star.addQuadCurve(to: CGPoint(x: c.x + r, y: c.y), control: c)
                star.addQuadCurve(to: CGPoint(x: c.x, y: c.y + r), control: c)
                star.addQuadCurve(to: CGPoint(x: c.x - r, y: c.y), control: c)
                star.addQuadCurve(to: CGPoint(x: c.x, y: c.y - r), control: c)
                ctx.fill(star, with: .color(.white.opacity(0.9)))
            }
        }
    }
}

struct Icon: View {
    var body: some View {
        ZStack {
            ZStack {
                LinearGradient(colors: [rgb(0xFFB36B), rgb(0xFF5E8A), rgb(0x6D3CE0)], startPoint: .topLeading, endPoint: .bottomTrailing)
                // Light spilling from the phone's screen and up along the cards' path.
                RadialGradient(colors: [Color.white.opacity(0.55), .clear], center: UnitPoint(x: 0.33, y: 0.58), startRadius: 0,
                               endRadius: tile * 0.45)
                Poly(pts: [P(0.24, 0.55), P(0.40, 0.50), P(0.98, 0.14), P(0.62, 0.02)])
                    .fill(LinearGradient(colors: [Color.white.opacity(0.45), .clear], startPoint: .bottomLeading, endPoint: .topTrailing))
                    .blur(radius: 18)
                Phone(w: tile * 0.27)
                    .shadow(color: Color.white.opacity(0.7), radius: 30)
                    .shadow(color: .black.opacity(0.35), radius: 18, y: 12)
                    .rotationEffect(.degrees(-14))
                    .position(x: tile * 0.29, y: tile * 0.72)
                TrailsAndSparkles()
                ForEach(0..<cards.count, id: \.self) { i in
                    CardView(card: cards[i].card, w: tile * cards[i].w)
                        .rotationEffect(.degrees(cards[i].angle))
                        .position(x: tile * cards[i].x, y: tile * cards[i].y)
                }
            }
            .frame(width: tile, height: tile)
            .clipShape(tileShape)
            tileShape.strokeBorder(LinearGradient(colors: [Color.white.opacity(0.22), Color.white.opacity(0.02)],
                                                  startPoint: .top, endPoint: .bottom), lineWidth: 3)
        }
        .frame(width: tile, height: tile)
        .compositingGroup()
        .shadow(color: .black.opacity(0.35), radius: 24, y: 12)
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

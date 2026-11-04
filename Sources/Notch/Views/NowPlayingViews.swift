import AppKit
import SwiftUI

// MARK: - Marquee

/// Single-line text that scrolls horizontally (with a pause) only when it doesn't fit.
struct MarqueeText: View {
    let text: String
    var font: Font = .system(size: 12, weight: .semibold)
    var color: Color = .white
    var height: CGFloat = 16
    var speed: CGFloat = 30        // points per second
    var gap: CGFloat = 36
    var pause: Double = 1.6

    @State private var textWidth: CGFloat = 0
    @State private var start = Date()

    var body: some View {
        GeometryReader { geo in
            let available = geo.size.width
            Group {
                if textWidth <= available + 0.5 {
                    label
                } else {
                    TimelineView(.animation) { ctx in
                        let travel = textWidth + gap
                        let cycle = Double(travel / speed) + pause
                        let t = ctx.date.timeIntervalSince(start).truncatingRemainder(dividingBy: cycle)
                        let x = t < pause ? 0 : -CGFloat(t - pause) * speed
                        HStack(spacing: gap) { label; label }
                            .offset(x: x)
                    }
                    .mask(
                        LinearGradient(stops: [
                            .init(color: .clear, location: 0),
                            .init(color: .black, location: 0.06),
                            .init(color: .black, location: 0.92),
                            .init(color: .clear, location: 1),
                        ], startPoint: .leading, endPoint: .trailing))
                }
            }
            .frame(width: available, height: height, alignment: .leading)
            .clipped()
        }
        .frame(height: height)
        .background(
            label.hidden().background(GeometryReader { g in
                Color.clear.preference(key: WidthKey.self, value: g.size.width)
            }),
            alignment: .leading)
        .onPreferenceChange(WidthKey.self) { textWidth = $0 }
        .onChange(of: text) { _, _ in start = Date() }
    }

    private var label: some View {
        Text(text).font(font).foregroundStyle(color).lineLimit(1).fixedSize()
    }

    private struct WidthKey: PreferenceKey {
        static var defaultValue: CGFloat = 0
        static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
    }
}

// MARK: - Source logos (drawn, no runtime downloads)

struct SourceLogo: View {
    let source: MediaSourceKind?
    var size: CGFloat = 18

    var body: some View {
        Group {
            switch source {
            case .spotify: SpotifyLogo()
            case .youtube: YouTubeLogo()
            case .youtubeMusic: YouTubeMusicLogo()
            default:
                ZStack {
                    Circle().fill(Color.white.opacity(0.18))
                    Image(systemName: "music.note")
                        .font(.system(size: size * 0.55, weight: .semibold))
                        .foregroundStyle(.white)
                }
            }
        }
        .frame(width: size, height: size)
    }
}

private struct SpotifyLogo: View {
    var body: some View {
        Canvas { ctx, size in
            let s = min(size.width, size.height)
            ctx.fill(Path(ellipseIn: CGRect(x: 0, y: 0, width: s, height: s)),
                     with: .color(Color(red: 0.11, green: 0.73, blue: 0.33)))
            func arc(_ y0: CGFloat, _ x0: CGFloat, _ x1: CGFloat, _ lift: CGFloat, _ w: CGFloat) {
                var p = Path()
                p.move(to: CGPoint(x: x0 * s, y: (y0 + 0.035) * s))
                p.addQuadCurve(to: CGPoint(x: x1 * s, y: (y0 + 0.07) * s),
                               control: CGPoint(x: 0.5 * s, y: (y0 - lift) * s))
                ctx.stroke(p, with: .color(.black), style: StrokeStyle(lineWidth: w * s, lineCap: .round))
            }
            arc(0.33, 0.22, 0.79, 0.10, 0.095)
            arc(0.50, 0.26, 0.74, 0.08, 0.078)
            arc(0.655, 0.30, 0.69, 0.06, 0.062)
        }
    }
}

private struct PlayTriangle: Shape {
    func path(in r: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: r.minX, y: r.minY))
        p.addLine(to: CGPoint(x: r.maxX, y: r.midY))
        p.addLine(to: CGPoint(x: r.minX, y: r.maxY))
        p.closeSubpath()
        return p
    }
}

private struct YouTubeLogo: View {
    var body: some View {
        GeometryReader { g in
            let s = min(g.size.width, g.size.height)
            ZStack {
                RoundedRectangle(cornerRadius: s * 0.2, style: .continuous)
                    .fill(Color(red: 1, green: 0, blue: 0))
                    .frame(width: s, height: s * 0.7)
                PlayTriangle().fill(.white)
                    .frame(width: s * 0.27, height: s * 0.3)
                    .offset(x: s * 0.03)
            }
            .frame(width: g.size.width, height: g.size.height)
        }
    }
}

private struct YouTubeMusicLogo: View {
    var body: some View {
        GeometryReader { g in
            let s = min(g.size.width, g.size.height)
            ZStack {
                Circle().fill(Color(red: 1, green: 0, blue: 0))
                Circle().stroke(.white, lineWidth: s * 0.065).frame(width: s * 0.6, height: s * 0.6)
                PlayTriangle().fill(.white)
                    .frame(width: s * 0.2, height: s * 0.24)
                    .offset(x: s * 0.025)
            }
            .frame(width: s, height: s)
        }
    }
}

// MARK: - Artwork

struct ArtworkView: View {
    let image: NSImage?
    var size: CGFloat
    var corner: CGFloat = 6

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image).resizable().interpolation(.high).aspectRatio(contentMode: .fill)
            } else {
                ZStack {
                    Color.white.opacity(0.12)
                    Image(systemName: "music.note").font(.system(size: size * 0.45)).foregroundStyle(.white.opacity(0.6))
                }
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: corner, style: .continuous))
    }
}

/// Little animated level bars shown while playing.
struct PlayingBars: View {
    let playing: Bool
    var color: Color = .white

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 20, paused: !playing)) { ctx in
            let t = ctx.date.timeIntervalSinceReferenceDate
            HStack(alignment: .center, spacing: 2) {
                ForEach(0..<4, id: \.self) { i in
                    let phase = sin(t * (5 + Double(i) * 1.7) + Double(i) * 1.3)
                    Capsule()
                        .fill(color)
                        .frame(width: 2.5, height: playing ? 4 + 8 * CGFloat((phase + 1) / 2) : 3)
                }
            }
            .frame(height: 12)
        }
    }
}

// MARK: - Compact (closed notch) player

/// Art fixed far left, source logo fixed far right; only the middle text scrolls.
/// On notch screens the text sits beside the camera housing, between art and notch.
struct CompactMusicView: View {
    @ObservedObject var vm: NotchViewModel
    @ObservedObject var player: NowPlayingService

    var body: some View {
        let g = vm.geometry
        let h = g.notchSize.height
        if let info = player.info {
            let art = h - 10
            HStack(spacing: 0) {
                HStack(spacing: 8) {
                    ArtworkView(image: info.artwork, size: art, corner: 5)
                    VStack(alignment: .leading, spacing: 0) {
                        MarqueeText(text: info.title, font: .system(size: 11, weight: .semibold), height: 14)
                        if !info.artist.isEmpty {
                            MarqueeText(text: info.artist, font: .system(size: 10),
                                        color: .white.opacity(0.6), height: 13)
                        }
                    }
                }
                .padding(.leading, 6)
                .padding(.trailing, g.hasNotch ? 10 : 4)
                .frame(width: NotchViewModel.musicWing + (g.hasNotch ? 0 : 70), alignment: .leading)

                Color.clear.frame(width: g.notchSize.width)

                HStack(spacing: 10) {
                    Spacer(minLength: 0)
                    PlayingBars(playing: info.isPlaying, color: .white.opacity(0.75))
                    SourceLogo(source: player.source, size: min(20, h - 12))
                }
                .padding(.trailing, 8)
                .frame(width: NotchViewModel.musicWing - (g.hasNotch ? 0 : 70))
            }
            .padding(.horizontal, vm.topRadius)
            .frame(height: h)
        }
    }
}

// MARK: - Player with controls (hover card + expanded panel)

struct PlayerControlsView: View {
    @ObservedObject var player: NowPlayingService
    var artSize: CGFloat = 64

    var body: some View {
        if let info = player.info {
            HStack(alignment: .center, spacing: 14) {
                ArtworkView(image: info.artwork, size: artSize, corner: 10)
                VStack(alignment: .leading, spacing: 4) {
                    HStack(alignment: .top, spacing: 8) {
                        VStack(alignment: .leading, spacing: 1) {
                            MarqueeText(text: info.title, font: .system(size: 13, weight: .semibold), height: 17)
                            MarqueeText(text: info.artist.isEmpty ? (player.source?.displayName ?? "") : info.artist,
                                        font: .system(size: 11.5), color: .white.opacity(0.65), height: 15)
                        }
                        SourceLogo(source: player.source, size: 18)
                    }
                    ProgressRow(info: info)
                    HStack(spacing: 22) {
                        Spacer(minLength: 0)
                        controlButton("backward.fill", size: 14) { player.send(.previous) }
                        controlButton(info.isPlaying ? "pause.fill" : "play.fill", size: 20) {
                            player.send(.togglePlayPause)
                        }
                        controlButton("forward.fill", size: 14) { player.send(.next) }
                        Spacer(minLength: 0)
                    }
                }
            }
        }
    }

    private func controlButton(_ symbol: String, size: CGFloat, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: size, weight: .semibold))
                .frame(width: 30, height: 26)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.white)
    }
}

private struct ProgressRow: View {
    let info: NowPlayingInfo

    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.5)) { ctx in
            let elapsed = info.elapsed(at: ctx.date)
            let fraction = info.duration > 0 ? min(1, elapsed / info.duration) : 0
            HStack(spacing: 8) {
                Text(elapsed.mmss).monospacedDigit()
                GeometryReader { g in
                    ZStack(alignment: .leading) {
                        Capsule().fill(.white.opacity(0.18))
                        Capsule().fill(.white).frame(width: max(4, g.size.width * fraction))
                    }
                }
                .frame(height: 4)
                Text(info.duration > 0 ? info.duration.mmss : "--:--").monospacedDigit()
            }
            .font(.system(size: 9.5, weight: .medium))
            .foregroundStyle(.white.opacity(0.55))
        }
    }
}

/// Hover card for the music state.
struct MusicPeekView: View {
    @ObservedObject var vm: NotchViewModel
    @ObservedObject var player: NowPlayingService

    var body: some View {
        let g = vm.geometry
        VStack(spacing: 0) {
            HStack {
                Text("Now Playing").font(.system(size: 11, weight: .semibold)).foregroundStyle(.white.opacity(0.6))
                Spacer()
                Text(player.source?.displayName ?? "").font(.system(size: 11)).foregroundStyle(.white.opacity(0.5))
            }
            .frame(height: g.notchSize.height)
            .padding(.horizontal, 4)
            PlayerControlsView(player: player, artSize: 76)
                .padding(.top, 6)
            Spacer(minLength: 0)
        }
        .foregroundStyle(.white)
        .padding(.horizontal, vm.topRadius + 16)
        .padding(.bottom, 10)
    }
}

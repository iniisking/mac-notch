import SwiftUI

/// One lyric line that scrolls (once, not looping) when it's wider than the space, timed so the
/// end is reached within the line's duration. With `karaoke`, the sung part is drawn bright over a
/// dim line and long lines scroll to keep the sweep in view.
struct LyricLineText: View {
    let text: String
    let duration: Double
    let start: Date
    var font: Font = .system(size: 12, weight: .semibold)
    var color: Color = .white
    var height: CGFloat = 16
    var alignment: Alignment = .center
    /// Sung fraction (0…1) at a given time; nil = plain line.
    var karaoke: ((Date) -> Double)? = nil
    var playing = true
    var dimColor: Color = .white.opacity(0.38)

    @State private var textWidth: CGFloat = 0

    var body: some View {
        GeometryReader { geo in
            let available = geo.size.width
            let overflow = textWidth - available
            if let karaoke {
                TimelineView(.animation(minimumInterval: 1 / 30, paused: !playing)) { ctx in
                    let p = karaoke(ctx.date)
                    let fill = textWidth * CGFloat(p)
                    let shift = overflow > 0.5 ? min(overflow, max(0, fill - available * 0.6)).rounded() : 0
                    ZStack(alignment: .leading) {
                        label(dimColor)
                        label(color).mask(alignment: .leading) {
                            HStack(spacing: 0) {
                                Rectangle().frame(width: max(0, fill))
                                LinearGradient(colors: [.black, .clear], startPoint: .leading, endPoint: .trailing)
                                    .frame(width: 10)
                            }
                        }
                    }
                    .offset(x: -shift)
                    .frame(width: available, height: height, alignment: overflow > 0.5 ? .leading : alignment)
                    .clipped()
                    .mask(edgeFade(left: shift > 0, right: overflow > 0.5 && shift < overflow))
                }
            } else if overflow <= 0.5 {
                label(color).frame(width: available, height: height, alignment: alignment)
            } else {
                TimelineView(.animation) { ctx in
                    let lead = 0.6                                   // read the start first
                    let travel = max(0.8, duration * 0.85 - lead)    // finish before the next line
                    let p = min(1, max(0, (ctx.date.timeIntervalSince(start) - lead) / travel))
                    label(color).offset(x: -(overflow * CGFloat(p)).rounded())
                        .frame(width: available, height: height, alignment: .leading)
                        .clipped()
                        .mask(edgeFade(left: p > 0, right: p < 1))
                }
            }
        }
        .frame(height: height)
        .background(alignment: .leading) {
            label(color).hidden().background(GeometryReader { g in
                Color.clear.preference(key: LyricWidthKey.self, value: g.size.width)
            })
        }
        .onPreferenceChange(LyricWidthKey.self) { textWidth = $0 }
    }

    private func label(_ c: Color) -> some View {
        Text(text).font(font).foregroundStyle(c).lineLimit(1).fixedSize(horizontal: true, vertical: false)
    }

    private func edgeFade(left: Bool, right: Bool) -> some View {
        LinearGradient(stops: [
            .init(color: left ? .clear : .black, location: 0),
            .init(color: .black, location: 0.06),
            .init(color: .black, location: 0.94),
            .init(color: right ? .clear : .black, location: 1),
        ], startPoint: .leading, endPoint: .trailing)
    }
}

private struct LyricWidthKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

/// The slim strip under the compact notch with the line being sung.
struct LyricStripView: View {
    @ObservedObject var lyrics: LyricsService

    var body: some View {
        ZStack {
            if let i = lyrics.currentIndex, lyrics.currentLine != nil {
                LyricLineText(text: lyrics.stripText(for: i), duration: lyrics.currentLineDuration,
                              start: lyrics.currentLineStart,
                              font: .system(size: 11.5, weight: .semibold), color: .white.opacity(0.95), height: 16,
                              karaoke: lyrics.karaokeEnabled ? { lyrics.karaokeProgress(at: $0) } : nil,
                              playing: lyrics.isPlaying)
                    .id(i)
                    .transition(.asymmetric(
                        insertion: .move(edge: .bottom).combined(with: .opacity),
                        removal: .move(edge: .top).combined(with: .opacity)))
            }
        }
        .animation(.easeInOut(duration: 0.28), value: lyrics.currentIndex)
        .clipped()
    }
}

/// Previous / current / next lines for the hover card. Click a line to seek there.
struct LyricsContextView: View {
    @ObservedObject var lyrics: LyricsService

    var body: some View {
        Group {
            switch lyrics.state {
            case .off:
                EmptyView()
            case .loading:
                note("Loading lyrics…")
            case .plainOnly:
                note("No synced lyrics")
            case .notFound:
                note("No lyrics found")
            case .synced(let lines):
                let a = lyrics.anchorIndex
                VStack(spacing: 3) {
                    row(lines, a - 1, current: false)
                    row(lines, a, current: true)
                    if lyrics.hasExtraLine { extraRow(a) }
                    row(lines, a + 1, current: false)
                }
                .animation(.easeInOut(duration: 0.25), value: a)
            }
        }
        .frame(maxWidth: .infinity)
    }

    @ViewBuilder private func row(_ lines: [LyricLine], _ i: Int, current: Bool) -> some View {
        let valid = i >= 0 && i < lines.count
        let text = valid ? (lines[i].text.isEmpty ? "♪" : lines[i].text) : (current && i < 0 ? "♪" : " ")
        Group {
            if current, valid, !lines[i].text.isEmpty {
                LyricLineText(text: text, duration: lyrics.currentLineDuration, start: lyrics.currentLineStart,
                              font: .system(size: 13.5, weight: .bold), color: .white, height: 18,
                              karaoke: lyrics.karaokeEnabled && lyrics.currentIndex == i
                                  ? { lyrics.karaokeProgress(at: $0) } : nil,
                              playing: lyrics.isPlaying, dimColor: .white.opacity(0.45))
            } else {
                Text(text)
                    .font(.system(size: current ? 13.5 : 11.5, weight: current ? .bold : .regular))
                    .foregroundStyle(.white.opacity(current ? 1 : 0.42))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: .infinity)
                    .frame(height: current ? 18 : 15)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { if valid { lyrics.seek(to: lines[i]) } }
        .help(valid ? "Jump here" : "")
    }

    /// Romanization / translation of the current line, or the reason there is none.
    private func extraRow(_ i: Int) -> some View {
        let text = lyrics.extras[i] ?? (lyrics.extras.isEmpty ? lyrics.extrasNote : nil) ?? " "
        return Text(text)
            .font(.system(size: 10.5, weight: .medium))
            .foregroundStyle(.white.opacity(0.6))
            .lineLimit(1)
            .truncationMode(.tail)
            .frame(maxWidth: .infinity)
            .frame(height: 13)
            .animation(nil, value: i)
    }

    private func note(_ s: String) -> some View {
        Text(s).font(.system(size: 11)).foregroundStyle(.white.opacity(0.45)).frame(height: 18)
    }
}

/// Per-song timing nudge for the hover card header: − / offset / +. Click the value to reset.
struct LyricsTimingControl: View {
    @ObservedObject var lyrics: LyricsService

    var body: some View {
        HStack(spacing: 2) {
            step("minus", -0.2, help: "Lyrics are early: show them later")
            Button { lyrics.resetTrackOffset() } label: {
                Text(lyrics.trackOffset == 0 ? "Sync" : String(format: "%+.1fs", lyrics.trackOffset))
                    .font(.system(size: 10, weight: .medium)).monospacedDigit()
                    .foregroundStyle(.white.opacity(lyrics.trackOffset == 0 ? 0.45 : 0.85))
                    .frame(minWidth: 34)
            }
            .buttonStyle(.plain)
            .help("Lyric timing for this song (click to reset)")
            step("plus", 0.2, help: "Lyrics are late: show them earlier")
        }
    }

    private func step(_ symbol: String, _ delta: Double, help: String) -> some View {
        Button { lyrics.nudgeTrackOffset(delta) } label: {
            Image(systemName: symbol).font(.system(size: 9, weight: .bold))
                .frame(width: 18, height: 16)
                .background(Circle().fill(.white.opacity(0.12)))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.white.opacity(0.8))
        .help(help)
    }
}

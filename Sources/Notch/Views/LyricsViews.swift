import SwiftUI

/// One lyric line that scrolls (once, not looping) when it's wider than the space, timed so the
/// end is reached within the line's duration.
struct LyricLineText: View {
    let text: String
    let duration: Double
    let start: Date
    var font: Font = .system(size: 12, weight: .semibold)
    var color: Color = .white
    var height: CGFloat = 16
    var alignment: Alignment = .center

    @State private var textWidth: CGFloat = 0

    var body: some View {
        GeometryReader { geo in
            let available = geo.size.width
            let overflow = textWidth - available
            if overflow <= 0.5 {
                label.frame(width: available, height: height, alignment: alignment)
            } else {
                TimelineView(.animation) { ctx in
                    let lead = 0.6                                   // read the start first
                    let travel = max(0.8, duration * 0.85 - lead)    // finish before the next line
                    let p = min(1, max(0, (ctx.date.timeIntervalSince(start) - lead) / travel))
                    label.offset(x: -(overflow * CGFloat(p)).rounded())
                        .frame(width: available, height: height, alignment: .leading)
                        .clipped()
                        .mask(LinearGradient(stops: [
                            .init(color: p > 0 ? .clear : .black, location: 0),
                            .init(color: .black, location: 0.06),
                            .init(color: .black, location: 0.94),
                            .init(color: p < 1 ? .clear : .black, location: 1),
                        ], startPoint: .leading, endPoint: .trailing))
                }
            }
        }
        .frame(height: height)
        .background(alignment: .leading) {
            label.hidden().background(GeometryReader { g in
                Color.clear.preference(key: LyricWidthKey.self, value: g.size.width)
            })
        }
        .onPreferenceChange(LyricWidthKey.self) { textWidth = $0 }
    }

    private var label: some View {
        Text(text).font(font).foregroundStyle(color).lineLimit(1).fixedSize(horizontal: true, vertical: false)
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
            if let i = lyrics.currentIndex, let line = lyrics.currentLine {
                LyricLineText(text: line.text, duration: lyrics.currentLineDuration, start: lyrics.currentLineStart,
                              font: .system(size: 11.5, weight: .semibold), color: .white.opacity(0.92), height: 16)
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
                              font: .system(size: 13.5, weight: .bold), color: .white, height: 18)
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

    private func note(_ s: String) -> some View {
        Text(s).font(.system(size: 11)).foregroundStyle(.white.opacity(0.45)).frame(height: 18)
    }
}

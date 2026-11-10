import AppKit
import SwiftUI

/// The launcher: hangs from the notch as one black shape. Search row, results, footer.
struct LauncherView: View {
    @ObservedObject var model: LauncherModel
    @ObservedObject var services: LauncherServices
    @ObservedObject var settings: LauncherSettings
    let onField: (NSTextField) -> Void

    private let topRadius: CGFloat = 14

    var body: some View {
        let notchH = model.geometry?.notchSize.height ?? 32
        let size = LauncherModel.size
        ZStack(alignment: .top) {
            NotchShape(topRadius: topRadius, bottomRadius: 22)
                .fill(Color.black)
            VStack(spacing: 0) {
                topBand.frame(height: notchH)
                searchRow
                Rectangle().fill(.white.opacity(0.08)).frame(height: 1)
                content
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .overlay(alignment: .bottomTrailing) {
                        if model.showActions, let item = model.selectedItem {
                            ActionsMenu(model: model, item: item).padding(10)
                                .transition(.scale(scale: 0.95, anchor: .bottomTrailing).combined(with: .opacity))
                        }
                    }
                    .overlay {
                        if case .hotkey(let item) = model.editing {
                            HotKeyCapturePrompt(item: item, current: settings.commandHotKeys[item.id]?.display)
                                .transition(.opacity)
                        }
                    }
                Rectangle().fill(.white.opacity(0.08)).frame(height: 1)
                footer.frame(height: 34)
            }
            .padding(.horizontal, topRadius)
            .padding(.bottom, 4)
        }
        .frame(width: size.width, height: size.height + notchH)
        .scaleEffect(x: model.isOpen ? 1 : 0.6, y: model.isOpen ? 1 : 0.2, anchor: .top)
        .opacity(model.isOpen ? 1 : 0)
        .animation(.spring(response: 0.32, dampingFraction: 0.84), value: model.isOpen)
        .animation(.easeOut(duration: 0.12), value: model.showActions)
        .foregroundStyle(.white)
        .environment(\.colorScheme, .dark)
    }

    // MARK: Top band (beside the camera)

    private var topBand: some View {
        let gap = (model.geometry?.hasNotch ?? false) ? (model.geometry?.notchSize.width ?? 0) + 16 : 0
        return HStack(spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: model.mode.symbol).font(.system(size: 10, weight: .semibold))
                Text(model.mode.title).font(.system(size: 11, weight: .semibold))
            }
            .foregroundStyle(.white.opacity(0.5))
            .padding(.leading, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            Color.clear.frame(width: gap)
            HStack(spacing: 8) {
                if let t = services.timers.timer {
                    TimelineView(.periodic(from: .now, by: 1)) { ctx in
                        Label(t.display(at: ctx.date), systemImage: t.symbol)
                            .font(.system(size: 11, weight: .semibold).monospacedDigit())
                            .foregroundStyle(ContinuityColors.orange)
                    }
                }
                if services.timers.isCaffeinated {
                    Image(systemName: "cup.and.saucer.fill").font(.system(size: 10.5)).foregroundStyle(ContinuityColors.orange)
                }
            }
            .padding(.trailing, 10)
            .frame(maxWidth: .infinity, alignment: .trailing)
        }
    }

    // MARK: Search row

    private var searchRow: some View {
        HStack(spacing: 10) {
            if model.mode != .root {
                Button { model.pop() } label: {
                    Image(systemName: "chevron.left").font(.system(size: 12, weight: .semibold))
                        .frame(width: 24, height: 24)
                        .background(RoundedRectangle(cornerRadius: 6).fill(.white.opacity(0.1)))
                }
                .buttonStyle(.plain)
                .help("Back (Esc)")
            } else {
                Image(systemName: "magnifyingglass").font(.system(size: 16, weight: .medium)).foregroundStyle(.white.opacity(0.5))
                    .frame(width: 24)
            }
            LauncherSearchField(text: $model.query, placeholder: model.mode.placeholder, onCreate: onField)
                .frame(height: 28)
            if services.files.isSearching, [.root, .files].contains(model.mode) {
                ProgressView().controlSize(.small).scaleEffect(0.7)
            }
            if model.mode == .clipboard {
                Menu {
                    ForEach(ClipFilter.allCases, id: \.self) { f in
                        Button(f.rawValue) { model.clipFilter = f; model.refresh() }
                    }
                } label: {
                    Text(model.clipFilter.rawValue).font(.system(size: 11.5, weight: .medium))
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .help("Filter (Tab)")
            }
            if model.mode == .emoji {
                SkinTonePicker(settings: settings) { model.refresh(keepSelection: true) }
            }
        }
        .padding(.horizontal, 10)
        .frame(height: 50)
    }

    // MARK: Content

    @ViewBuilder private var content: some View {
        switch model.mode.layout {
        case .grid:
            EmojiGridView(model: model)
        case .list:
            if model.items.isEmpty {
                emptyState
            } else {
                ResultsList(model: model)
            }
        case .listWithPreview:
            if model.items.isEmpty {
                emptyState
            } else {
                HStack(spacing: 0) {
                    ResultsList(model: model).frame(width: 290)
                    Rectangle().fill(.white.opacity(0.08)).frame(width: 1)
                    PreviewPane(model: model, services: services)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: model.mode == .clipboard ? "doc.on.clipboard" : model.mode.symbol)
                .font(.system(size: 26, weight: .light)).foregroundStyle(.white.opacity(0.3))
            Text(emptyText).font(.system(size: 12.5)).foregroundStyle(.white.opacity(0.45)).multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var emptyText: String {
        switch model.mode {
        case .files: return model.query.count < 2 ? "Type at least two letters to search files" : "No files found"
        case .clipboard:
            if !settings.clipboardHistory { return "Clipboard history is off.\nTurn it on in Settings › Launcher." }
            return model.query.isEmpty && model.clipFilter == .all ? "Copy something and it shows up here" : "Nothing matches"
        case .shortcuts: return services.shortcuts.isEmpty ? "No Shortcuts found" : "No matching Shortcuts"
        default: return "No results"
        }
    }

    // MARK: Footer

    private var footer: some View {
        HStack(spacing: 14) {
            if let prompt = model.editingPrompt {
                Label(prompt, systemImage: "keyboard")
                    .font(.system(size: 11.5, weight: .medium)).foregroundStyle(LauncherColors.blue)
                    .lineLimit(1)
            } else if let msg = model.confirmMessage {
                Label(msg, systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 11.5, weight: .medium)).foregroundStyle(ContinuityColors.orange)
                    .lineLimit(1)
            } else if model.mode == .emoji, let cell = model.selectedCell {
                Text(cell.glyph).font(.system(size: 15))
                Text(cell.name.capitalized).font(.system(size: 11.5)).foregroundStyle(.white.opacity(0.6)).lineLimit(1)
            } else {
                Text(footerStatus).font(.system(size: 11.5)).foregroundStyle(.white.opacity(0.45)).lineLimit(1)
            }
            Spacer(minLength: 8)
            if model.mode == .emoji {
                keyHint("Paste", "↩")
                keyHint("Copy", "⌘↩")
                keyHint("Skin tone", "⇥")
            } else if model.editing != nil {
                EmptyView()
            } else if let item = model.selectedItem, let first = item.actions.first {
                keyHint(first.title, "↩")
                if model.allActions(for: item).count > 1 {
                    Rectangle().fill(.white.opacity(0.15)).frame(width: 1, height: 14)
                    keyHint("Actions", "⌘K")
                }
            }
        }
        .padding(.horizontal, 12)
    }

    private var footerStatus: String {
        switch model.mode {
        case .clipboard: return "\(model.items.count) item\(model.items.count == 1 ? "" : "s") · Tab to filter"
        case .root: return model.query.isEmpty ? "Type to search · ⌘, Settings" : "\(model.items.count) results"
        default: return "\(model.items.count) item\(model.items.count == 1 ? "" : "s")"
        }
    }

    private func keyHint(_ title: String, _ key: String) -> some View {
        HStack(spacing: 5) {
            Text(title).font(.system(size: 11.5, weight: .medium)).foregroundStyle(.white.opacity(0.75)).lineLimit(1)
            Text(key).font(.system(size: 10.5, weight: .semibold))
                .padding(.horizontal, 5).padding(.vertical, 1.5)
                .background(RoundedRectangle(cornerRadius: 4).fill(.white.opacity(0.12)))
                .foregroundStyle(.white.opacity(0.6))
        }
    }
}

// MARK: - Search field

/// AppKit text field (reliable focus inside a non-activating panel; arrow/return keys are
/// intercepted by the controller before they reach it).
struct LauncherSearchField: NSViewRepresentable {
    @Binding var text: String
    var placeholder: String
    var onCreate: (NSTextField) -> Void

    func makeNSView(context: Context) -> NSTextField {
        let f = NSTextField()
        f.isBordered = false
        f.drawsBackground = false
        f.focusRingType = .none
        f.font = .systemFont(ofSize: 18, weight: .regular)
        f.textColor = .white
        f.cell?.usesSingleLineMode = true
        f.cell?.wraps = false
        f.cell?.isScrollable = true
        f.lineBreakMode = .byClipping
        f.delegate = context.coordinator
        setPlaceholder(f)
        onCreate(f)
        return f
    }

    func updateNSView(_ f: NSTextField, context: Context) {
        if f.stringValue != text {
            f.stringValue = text
            // Keep the caret at the end after programmatic changes ("g " quicklink prefill).
            if let editor = f.currentEditor() { editor.selectedRange = NSRange(location: (text as NSString).length, length: 0) }
        }
        if f.placeholderAttributedString?.string != placeholder { setPlaceholder(f) }
    }

    private func setPlaceholder(_ f: NSTextField) {
        f.placeholderAttributedString = NSAttributedString(string: placeholder, attributes: [
            .foregroundColor: NSColor.white.withAlphaComponent(0.35),
            .font: NSFont.systemFont(ofSize: 18, weight: .regular),
        ])
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: LauncherSearchField
        init(_ p: LauncherSearchField) { parent = p }

        func controlTextDidChange(_ note: Notification) {
            guard let f = note.object as? NSTextField else { return }
            parent.text = f.stringValue
        }

        func controlTextDidBeginEditing(_ note: Notification) {
            (note.object as? NSTextField)?.currentEditor().flatMap { $0 as? NSTextView }?.insertionPointColor = .white
        }
    }
}

// MARK: - Results list

struct ResultsList: View {
    @ObservedObject var model: LauncherModel

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical) {
                LazyVStack(alignment: .leading, spacing: 1) {
                    ForEach(Array(model.items.enumerated()), id: \.element.id) { idx, item in
                        if idx == 0 || model.items[idx - 1].section != item.section {
                            Text(item.section)
                                .font(.system(size: 10.5, weight: .semibold))
                                .foregroundStyle(.white.opacity(0.4))
                                .padding(.horizontal, 10)
                                .padding(.top, idx == 0 ? 6 : 10)
                                .padding(.bottom, 3)
                        }
                        ResultRow(item: item, selected: idx == model.selection, index: idx,
                                  compact: model.mode.layout == .listWithPreview)
                            .id(item.id)
                            .contentShape(Rectangle())
                            .onTapGesture {
                                model.selection = idx
                                model.activateSelection()
                            }
                            .onHover { if $0 { model.hover(idx) } }
                    }
                }
                .padding(.vertical, 4)
                .padding(.horizontal, 6)
            }
            .scrollIndicators(.never)
            .onChange(of: model.selection) { _, new in
                guard model.items.indices.contains(new) else { return }
                if Date().timeIntervalSince(model.lastKeyboardNav) < 0.5 {
                    proxy.scrollTo(model.items[new].id, anchor: nil)
                }
            }
            .onChange(of: model.mode) { _, _ in
                if let first = model.items.first { proxy.scrollTo(first.id, anchor: .top) }
            }
        }
    }
}

struct ResultRow: View {
    let item: LauncherItem
    let selected: Bool
    let index: Int
    var compact = false

    var body: some View {
        HStack(spacing: 10) {
            LauncherIconView(icon: item.icon, size: compact ? 20 : 24)
            VStack(alignment: .leading, spacing: 1) {
                Text(item.title)
                    .font(.system(size: compact ? 12.5 : 13.5, weight: .medium))
                    .lineLimit(1)
                if !compact, let sub = item.subtitle, !sub.isEmpty {
                    Text(sub).font(.system(size: 11)).foregroundStyle(.white.opacity(0.45)).lineLimit(1)
                }
            }
            Spacer(minLength: 6)
            if let alias = item.alias {
                Text(alias).font(.system(size: 10.5, weight: .semibold, design: .monospaced))
                    .padding(.horizontal, 5).padding(.vertical, 1.5)
                    .background(RoundedRectangle(cornerRadius: 4).strokeBorder(.white.opacity(0.25)))
                    .foregroundStyle(.white.opacity(0.6))
            }
            if let hk = item.hotkey {
                Text(hk).font(.system(size: 11, weight: .semibold))
                    .padding(.horizontal, 5).padding(.vertical, 1.5)
                    .background(RoundedRectangle(cornerRadius: 4).fill(.white.opacity(0.12)))
                    .foregroundStyle(.white.opacity(0.75))
            } else if let acc = item.accessory {
                Text(acc).font(.system(size: 11)).foregroundStyle(.white.opacity(0.4)).lineLimit(1)
            }
            if selected, index < 9, !compact {
                Text("⌘\(index + 1)").font(.system(size: 10, weight: .medium)).foregroundStyle(.white.opacity(0.3))
            }
        }
        .padding(.horizontal, 10)
        .frame(height: compact ? 34 : 42)
        .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(.white.opacity(selected ? 0.12 : 0)))
    }
}

// MARK: - Actions (⌘K)

struct ActionsMenu: View {
    @ObservedObject var model: LauncherModel
    let item: LauncherItem

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(item.title).font(.system(size: 10.5, weight: .semibold)).foregroundStyle(.white.opacity(0.4))
                .lineLimit(1).padding(.horizontal, 8).padding(.vertical, 4)
            ForEach(Array(model.allActions(for: item).enumerated()), id: \.element.id) { idx, a in
                HStack(spacing: 8) {
                    Image(systemName: a.symbol).font(.system(size: 11.5)).frame(width: 16)
                    Text(a.title).font(.system(size: 12.5))
                    Spacer(minLength: 16)
                    Text(idx == 0 ? "↩" : (a.shortcut ?? "")).font(.system(size: 11)).foregroundStyle(.white.opacity(0.4))
                }
                .foregroundStyle(a.destructive ? ContinuityColors.red : .white)
                .padding(.horizontal, 8)
                .frame(height: 28)
                .background(RoundedRectangle(cornerRadius: 6).fill(.white.opacity(idx == model.actionSelection ? 0.14 : 0)))
                .contentShape(Rectangle())
                .onTapGesture { model.run(a, of: item) }
                .onHover { if $0 { model.actionSelection = idx } }
            }
        }
        .padding(6)
        .frame(width: 270)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color(white: 0.11))
                .shadow(color: .black.opacity(0.5), radius: 16, y: 6))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(.white.opacity(0.1)))
    }
}

// MARK: - Preview (clipboard, snippets)

struct PreviewPane: View {
    @ObservedObject var model: LauncherModel
    let services: LauncherServices

    var body: some View {
        if let item = model.selectedItem {
            VStack(alignment: .leading, spacing: 0) {
                Group {
                    switch item.preview {
                    case .text(let t, let mono):
                        ScrollView {
                            Text(t)
                                .font(mono ? .system(size: 12, design: .monospaced) : .system(size: 13))
                                .foregroundStyle(.white.opacity(0.9))
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .topLeading)
                                .padding(14)
                        }
                    case .image(let img):
                        Image(nsImage: img).resizable().aspectRatio(contentMode: .fit)
                            .clipShape(RoundedRectangle(cornerRadius: 6))
                            .padding(14)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    case .files(let urls):
                        ScrollView {
                            VStack(alignment: .leading, spacing: 8) {
                                ForEach(urls, id: \.self) { u in
                                    HStack(spacing: 8) {
                                        Image(nsImage: IconCache.icon(forFile: u)).resizable().frame(width: 28, height: 28)
                                        VStack(alignment: .leading, spacing: 1) {
                                            Text(u.lastPathComponent).font(.system(size: 12.5, weight: .medium)).lineLimit(1)
                                            Text(u.deletingLastPathComponent().path).font(.system(size: 10.5))
                                                .foregroundStyle(.white.opacity(0.4)).lineLimit(1).truncationMode(.middle)
                                        }
                                    }
                                }
                            }
                            .padding(14)
                        }
                    case .color(let c, let text):
                        VStack(alignment: .leading, spacing: 10) {
                            RoundedRectangle(cornerRadius: 12).fill(Color(nsColor: c)).frame(height: 120)
                                .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.white.opacity(0.15)))
                            ForEach([("Copied", text), ("Hex", ColorParser.hex(c)), ("RGB", ColorParser.rgb(c)), ("HSL", ColorParser.hsl(c))], id: \.0) { row in
                                HStack {
                                    Text(row.0).foregroundStyle(.white.opacity(0.45))
                                    Spacer()
                                    Text(row.1).textSelection(.enabled)
                                }
                                .font(.system(size: 12, design: .monospaced))
                            }
                            Spacer()
                        }
                        .padding(14)
                    case nil:
                        Color.clear
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                if model.mode == .clipboard, let entry = clipEntry(for: item) {
                    metadata(entry)
                }
            }
        } else {
            Color.clear
        }
    }

    private func clipEntry(for item: LauncherItem) -> ClipEntry? {
        services.clipboard.entries.first { "clip:\($0.id)" == item.id }
    }

    private func metadata(_ e: ClipEntry) -> some View {
        VStack(spacing: 4) {
            Rectangle().fill(.white.opacity(0.08)).frame(height: 1).padding(.bottom, 4)
            if let app = e.app {
                row("Source", AppInfoProvider.shared.info(for: app).name)
            }
            row("Copied", e.date.formatted(date: .abbreviated, time: .shortened))
            if let t = e.text, e.kind == .text || e.kind == .link {
                row("Characters", "\(t.count) · \(t.split(whereSeparator: \.isWhitespace).count) words")
            }
            if let s = e.imageSize { row("Size", "\(Int(s.width)) × \(Int(s.height))") }
            if e.useCount > 0 { row("Pasted", "\(e.useCount)×") }
        }
        .padding(.horizontal, 14)
        .padding(.bottom, 8)
    }

    private func row(_ k: String, _ v: String) -> some View {
        HStack {
            Text(k).foregroundStyle(.white.opacity(0.4))
            Spacer()
            Text(v).foregroundStyle(.white.opacity(0.75)).lineLimit(1)
        }
        .font(.system(size: 11))
    }
}

// MARK: - Emoji grid

struct EmojiGridView: View {
    @ObservedObject var model: LauncherModel

    private struct Row: Identifiable {
        let id: String
        let header: String?
        let cells: [(Int, EmojiStore.GridCell)]
    }

    private var rows: [Row] {
        var out: [Row] = []
        var flat = 0
        for s in model.emojiSections {
            out.append(Row(id: "h:\(s.id)", header: s.title, cells: []))
            var chunk: [(Int, EmojiStore.GridCell)] = []
            for c in s.items {
                chunk.append((flat, c))
                flat += 1
                if chunk.count == LauncherModel.emojiColumns {
                    out.append(Row(id: "r:\(s.id):\(chunk[0].0)", header: nil, cells: chunk))
                    chunk = []
                }
            }
            if !chunk.isEmpty { out.append(Row(id: "r:\(s.id):\(chunk[0].0)", header: nil, cells: chunk)) }
        }
        return out
    }

    var body: some View {
        if model.emojiCells.isEmpty {
            VStack(spacing: 6) {
                Image(systemName: "face.dashed").font(.system(size: 26, weight: .light)).foregroundStyle(.white.opacity(0.3))
                Text("No emoji found").font(.system(size: 12.5)).foregroundStyle(.white.opacity(0.45))
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            let rows = self.rows
            ScrollViewReader { proxy in
                ScrollView(.vertical) {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        ForEach(rows) { row in
                            if let h = row.header {
                                Text(h).font(.system(size: 10.5, weight: .semibold)).foregroundStyle(.white.opacity(0.4))
                                    .padding(.horizontal, 8).padding(.top, 8).padding(.bottom, 2)
                            } else {
                                HStack(spacing: 2) {
                                    ForEach(row.cells, id: \.0) { idx, cell in
                                        Text(cell.glyph)
                                            .font(.system(size: 27))
                                            .frame(width: 48, height: 44)
                                            .background(RoundedRectangle(cornerRadius: 8, style: .continuous)
                                                .fill(.white.opacity(idx == model.selection ? 0.16 : 0)))
                                            .contentShape(Rectangle())
                                            .help(cell.name)
                                            .onTapGesture { model.selection = idx; model.activateSelection() }
                                            .onHover { if $0 { model.hover(idx) } }
                                    }
                                }
                                .id(row.id)
                            }
                        }
                    }
                    .padding(.horizontal, 6)
                    .padding(.vertical, 4)
                }
                .scrollIndicators(.never)
                .onChange(of: model.selection) { _, new in
                    guard Date().timeIntervalSince(model.lastKeyboardNav) < 0.5,
                          let row = rows.first(where: { $0.cells.contains { $0.0 == new } }) else { return }
                    proxy.scrollTo(row.id, anchor: nil)
                }
                .onChange(of: model.query) { _, _ in
                    if let first = rows.first { proxy.scrollTo(first.id, anchor: .top) }
                }
            }
        }
    }
}

struct SkinTonePicker: View {
    @ObservedObject var settings: LauncherSettings
    let changed: () -> Void
    private let tones = ["👋", "👋🏻", "👋🏼", "👋🏽", "👋🏾", "👋🏿"]

    var body: some View {
        Menu {
            ForEach(0..<tones.count, id: \.self) { i in
                Button(tones[i] + (i == 0 ? "  Default" : "")) { settings.emojiSkinTone = i; changed() }
            }
        } label: {
            Text(tones[min(max(settings.emojiSkinTone, 0), 5)]).font(.system(size: 16))
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("Skin tone (Tab)")
    }
}

/// Shown over the results while a hotkey is being recorded for a command.
struct HotKeyCapturePrompt: View {
    let item: LauncherItem
    let current: String?

    var body: some View {
        ZStack {
            Color.black.opacity(0.75)
            VStack(spacing: 12) {
                LauncherIconView(icon: item.icon, size: 40)
                Text(item.title).font(.system(size: 15, weight: .semibold))
                Text(current ?? "Press a shortcut…")
                    .font(.system(size: 20, weight: .semibold, design: .rounded))
                    .padding(.horizontal, 16).padding(.vertical, 8)
                    .background(RoundedRectangle(cornerRadius: 10).strokeBorder(LauncherColors.blue, lineWidth: 1.5))
                Text("Use at least one of ⌘ ⌥ ⌃ ⇧ (or an F-key). ⌫ removes it, Esc cancels.")
                    .font(.system(size: 11.5)).foregroundStyle(.white.opacity(0.55))
            }
        }
    }
}

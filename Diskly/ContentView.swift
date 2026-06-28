//
//  ContentView.swift
//  Diskly
//

import SwiftUI

struct ContentView: View {
    @State private var model = AppModel()
    @State private var columns: NavigationSplitViewVisibility = .all

    var body: some View {
        // ponytail: no NavigationSplitView until a folder is scanned — that's
        // what auto-generates the sidebar toggle. Welcome screen stands alone.
        Group {
            if model.root == nil {
                Welcome(model: model)
            } else {
                NavigationSplitView(columnVisibility: $columns) {
                    Sidebar(model: model)
                        .navigationSplitViewColumnWidth(min: 240, ideal: 300, max: 420)
                } detail: {
                    Detail(model: model)
                }
            }
        }
        .toolbar { Toolbar(model: model) }
        .navigationTitle("Diskly")
        .alert("Trash failed", isPresented: Binding(
            get: { model.lastError != nil },
            set: { if !$0 { model.lastError = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(model.lastError ?? "")
        }
    }
}

// MARK: - Welcome (no folder scanned)

private struct Welcome: View {
    @Bindable var model: AppModel
    @State private var dropping = false

    // 4 quick-location buttons + 3 gaps — recents box matches this width.
    private let columnWidth: CGFloat = 4 * 80 + 3 * 10

    var body: some View {
        Group {
            if model.isScanning {
                VStack(spacing: 14) {
                    ProgressView("Scanning… \(model.scannedCount.formatted()) items")
                        .controlSize(.large)
                    Button("Cancel") { model.cancelScan() }
                        .keyboardShortcut(.cancelAction)
                }
            } else {
                content
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(dropping ? Color.accentColor.opacity(0.08) : .clear)
        .dropDestination(for: URL.self) { urls, _ in
            guard let url = urls.first else { return false }
            model.scan(dropped: url)
            return true
        } isTargeted: { dropping = $0 }
    }

    private var content: some View {
        VStack(spacing: 22) {
            VStack(spacing: 8) {
                Image(systemName: "chart.pie")
                    .font(.system(size: 46))
                    .foregroundStyle(.tint)
                Text("Diskly").font(.largeTitle.weight(.semibold))
                Text("Scan a folder to visualize disk usage, or drag one here.")
                    .foregroundStyle(.secondary)
            }

            Button("Choose Folder…") { model.open() }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)

            HStack(spacing: 10) {
                ForEach(QuickLocation.all) { loc in
                    Button { model.openQuick(loc.url) } label: {
                        VStack(spacing: 5) {
                            Image(systemName: loc.icon).font(.title2)
                            Text(loc.name).font(.caption)
                        }
                        .frame(maxWidth: .infinity)
                        .frame(height: 62)
                    }
                    .buttonStyle(.bordered)
                }
            }
            .frame(width: columnWidth)

            if !model.recents.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("RECENT")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .padding(.leading, 4)
                    ForEach(model.recents) { r in
                        Button { model.scanRecent(r) } label: {
                            HStack(spacing: 8) {
                                Image(systemName: "folder").foregroundStyle(.tint)
                                Text(r.url.lastPathComponent)
                                Spacer(minLength: 12)
                                Text(r.url.deletingLastPathComponent().path)
                                    .font(.caption).foregroundStyle(.secondary)
                                    .lineLimit(1).truncationMode(.head)
                            }
                            .padding(.vertical, 5).padding(.horizontal, 8)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(8)
                .frame(width: columnWidth)
                .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
            }
        }
        .padding(40)
    }
}

// MARK: - Toolbar

private struct Toolbar: ToolbarContent {
    @Bindable var model: AppModel

    var body: some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            Button { model.rescan() } label: { Image(systemName: "arrow.clockwise") }
                .help("Rescan")
                .disabled(model.root == nil || model.isScanning)
            Button { model.goHome() } label: { Image(systemName: "house") }
                .help("Back to start — choose another folder")
                .disabled(model.root == nil)
        }
    }
}

// MARK: - Path bar (breadcrumb)

private struct PathBar: View {
    @Bindable var model: AppModel

    var body: some View {
        let crumbs = model.breadcrumbs
        HStack(spacing: 4) {
            ForEach(Array(crumbs.enumerated()), id: \.element.id) { i, node in
                if i > 0 {
                    Image(systemName: "chevron.compact.right")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
                let isLast = i == crumbs.count - 1
                Button {
                    model.navigate(to: i == 0 ? nil : node)
                } label: {
                    Text(node.name.isEmpty ? "/" : node.name)
                        .fontWeight(isLast ? .semibold : .regular)
                        .foregroundStyle(isLast ? Color.primary : Color.secondary)
                }
                .buttonStyle(.plain)
                .disabled(isLast)
            }
            Spacer(minLength: 0)
        }
        .lineLimit(1)
        .padding(.horizontal, 14)
        .frame(height: 36)
        .background(.bar)
    }
}

// MARK: - Sidebar (size breakdown of current folder)

private struct Sidebar: View {
    @Bindable var model: AppModel

    var body: some View {
        if let current = model.current {
            let _ = model.version
            let kids = current.sortedChildren
            let total = max(current.size, 1)
            List(selection: Binding(
                get: { model.selected?.id },
                set: { id in model.selected = kids.first { $0.id == id } }
            )) {
                ForEach(kids) { node in
                    Row(node: node,
                        fraction: Double(node.size) / Double(total),
                        marked: model.isMarked(node),
                        onHover: { model.hovered = $0 ? node : nil },
                        onDrill: { model.drill(into: node) })
                        .tag(node.id)
                        .contextMenu { rowMenu(node) }
                }
            }
            .listStyle(.inset)
        } else {
            ContentUnavailableView {
                Label("No folder scanned", systemImage: "internaldrive")
            } description: {
                Text("Choose a folder to see what's taking up space.")
            } actions: {
                Button("Choose Folder…") { model.open() }
                    .buttonStyle(.borderedProminent)
            }
        }
    }

    @ViewBuilder private func rowMenu(_ node: FileNode) -> some View {
        if node.isDirectory && !node.children.isEmpty {
            Button("Drill In") { model.drill(into: node) }
        }
        Button("Reveal in Finder") { model.reveal(node) }
        Divider()
        Button(model.isMarked(node) ? "Unmark" : "Mark for Deletion") {
            model.toggleMark(node)
        }
        .disabled(node.parent == nil)
    }
}

private struct Row: View {
    let node: FileNode
    let fraction: Double
    let marked: Bool
    let onHover: (Bool) -> Void
    let onDrill: () -> Void

    @State private var hovering = false

    private var canDrill: Bool { node.isDirectory && !node.children.isEmpty }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Image(systemName: marked ? "trash"
                      : (node.isDirectory ? "folder.fill" : "doc.fill"))
                    .foregroundStyle(marked ? Color.red : node.tileColor)
                    .imageScale(.small)
                Text(node.name)
                    .lineLimit(1).truncationMode(.middle)
                    .strikethrough(marked, color: .red)
                    .foregroundStyle(marked ? Color.secondary : Color.primary)
                Spacer(minLength: 8)
                Text(node.size.byteString)
                    .foregroundStyle(.secondary)
                    .font(.callout.monospacedDigit())
                if canDrill {
                    Button(action: onDrill) {
                        Image(systemName: "chevron.right")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.tertiary)
                    }
                    .buttonStyle(.plain)
                    .help("Open folder")
                    .opacity(hovering ? 1 : 0.35)
                }
            }
            GeometryReader { g in
                Capsule().fill(.quaternary)
                    .overlay(alignment: .leading) {
                        Capsule().fill(marked ? Color.red : node.tileColor)
                            .frame(width: max(2, g.size.width * fraction))
                    }
            }
            .frame(height: 3)
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
        .onHover { h in hovering = h; onHover(h) }
        .background(hovering ? Color.primary.opacity(0.06) : .clear)
    }
}

// MARK: - Detail (path bar + treemap + bottom bars)

private struct Detail: View {
    @Bindable var model: AppModel

    var body: some View {
        ZStack {
            if let current = model.current, !current.children.isEmpty {
                TreemapView(node: current,
                            version: model.version,
                            markedIDs: Set(model.marked.keys),
                            selected: $model.selected,
                            hovered: $model.hovered,
                            onDrill: { model.drill(into: $0) })
            } else {
                ContentUnavailableView("Empty folder", systemImage: "tray")
            }

            if model.isScanning {
                Rectangle().fill(.regularMaterial)
                VStack(spacing: 14) {
                    ProgressView("Scanning… \(model.scannedCount.formatted()) items")
                        .controlSize(.large)
                    Button("Cancel") { model.cancelScan() }
                        .keyboardShortcut(.cancelAction)
                }
            }
        }
        .safeAreaInset(edge: .top) {
            if model.root != nil { PathBar(model: model) }
        }
        .safeAreaInset(edge: .bottom) {
            VStack(spacing: 0) {
                if !model.marked.isEmpty { CleanupBar(model: model) }
                if model.root != nil { InfoBar(model: model) }
            }
        }
    }
}

private struct CleanupBar: View {
    @Bindable var model: AppModel

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "trash.circle.fill")
                .foregroundStyle(.red)
                .imageScale(.large)
            Text("^[\(model.marked.count) item](inflect: true) marked")
                .font(.callout.weight(.medium))
            Text(model.markedTotal.byteString)
                .font(.callout.monospacedDigit())
                .foregroundStyle(.secondary)
            Spacer()
            Button("Clear") { model.clearMarks() }
            Button("Move to Trash") { model.cleanMarked() }
                .buttonStyle(.borderedProminent)
                .tint(.red)
        }
        .padding(.horizontal, 14)
        .frame(height: 44)
        .background(.bar)
    }
}

private struct InfoBar: View {
    @Bindable var model: AppModel

    var body: some View {
        let target = model.selected ?? model.current
        HStack(spacing: 12) {
            if let target {
                Image(systemName: target.isDirectory ? "folder.fill" : "doc.fill")
                    .foregroundStyle(target.tileColor)
                VStack(alignment: .leading, spacing: 1) {
                    Text(model.selected == nil ? "\(target.name) (total)" : target.name)
                        .font(.callout.weight(.medium)).lineLimit(1)
                    Text(target.url.path).font(.caption).foregroundStyle(.secondary)
                        .lineLimit(1).truncationMode(.middle)
                }
                Spacer()
                Text(target.size.byteString)
                    .font(.callout.monospacedDigit().weight(.medium))
                if let sel = model.selected {
                    Button { model.reveal(sel) } label: { Image(systemName: "magnifyingglass") }
                        .help("Reveal in Finder")
                    Button { model.toggleMark(sel) } label: {
                        Image(systemName: model.isMarked(sel) ? "trash.slash" : "trash")
                    }
                    .help(model.isMarked(sel) ? "Unmark" : "Mark for Deletion")
                    .disabled(sel.parent == nil)
                }
            } else {
                Text("Ready").foregroundStyle(.secondary)
                Spacer()
            }
        }
        .padding(.horizontal, 14)
        .frame(height: 44)
        .background(.bar)
    }
}

#Preview {
    ContentView()
}

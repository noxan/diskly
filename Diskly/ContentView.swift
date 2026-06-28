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

            ForEach(DiskVolume.all) { disk in
                Button { model.openQuick(disk.url) } label: {
                    DiskRow(disk: disk)
                }
                .buttonStyle(.plain)
                .frame(width: columnWidth)
            }

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

            // Hide recents that are already one click away as a disk or quick item.
            let pinned = Set((DiskVolume.all.map(\.url) + QuickLocation.all.map(\.url))
                .map { $0.standardizedFileURL.path })
            let recents = model.recents.filter { !pinned.contains($0.url.standardizedFileURL.path) }

            if !recents.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("RECENT")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .padding(.leading, 4)
                    ForEach(recents) { r in
                        Button { model.scanRecent(r) } label: {
                            HStack(spacing: 8) {
                                Image(systemName: "folder").foregroundStyle(.tint)
                                Text(displayName(for: r.url))
                                Spacer(minLength: 12)
                                Text(subtitlePath(for: r.url))
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

private struct DiskRow: View {
    let disk: DiskVolume

    var body: some View {
        let nearFull = disk.fraction > 0.9
        HStack(spacing: 12) {
            Image(systemName: "internaldrive")
                .font(.system(size: 30))
                .foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 5) {
                HStack {
                    Text(disk.name).fontWeight(.medium)
                    Spacer()
                    Text("\(disk.used.byteString) of \(disk.total.byteString)")
                        .font(.caption).foregroundStyle(.secondary)
                }
                GeometryReader { g in
                    Capsule().fill(.quaternary)
                        .overlay(alignment: .leading) {
                            Capsule().fill(nearFull ? Color.red : Color.accentColor)
                                .frame(width: max(3, g.size.width * disk.fraction))
                        }
                }
                .frame(height: 6)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 8))
        .contentShape(Rectangle())
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

/// Parent-path subtitle for a recent. Uses the volume's friendly name when
/// the parent is the volume root (otherwise the subtitle would just read "/").
private func subtitlePath(for url: URL) -> String {
    let parent = url.deletingLastPathComponent()
    if parent.path == "/" { return displayName(for: parent) }
    return parent.path
}

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
            Spacer(minLength: 8)
            if let current = model.current {
                let displaySize = model.isScanning ? model.scannedBytes : current.size
                Text(displaySize.byteString)
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
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
            let kids = current.displayChildren
            let total = max(current.size, 1)
            List(selection: Binding(
                get: { model.selected?.id },
                set: { id in
                    // Single click selects; drilling is handled by the row's
                    // double-tap gesture so it also fires on the already-
                    // selected row (where this setter wouldn't be called).
                    model.selected = kids.first { $0.id == id }
                }
            )) {
                ForEach(kids) { node in
                    Row(node: node,
                        fraction: Double(node.size) / Double(total),
                        marked: model.isMarked(node),
                        onHover: { model.hovered = $0 ? node : nil },
                        onDrill: { model.drill(into: node) })
                        .tag(node.id)
                        // A gesture over the row hit-tests its content area, so it
                        // must handle BOTH clicks — otherwise single clicks there
                        // get swallowed and only margin clicks select. Double also
                        // drills the already-selected row (the setter won't fire).
                        .simultaneousGesture(TapGesture(count: 1).onEnded {
                            model.selected = node
                        })
                        .simultaneousGesture(TapGesture(count: 2).onEnded {
                            model.drill(into: node)
                        })
                        .listRowSeparator(.hidden)
                        // Hover fill sized/shaped to match the native selection
                        // highlight (skipped when selected so the system draws it).
                        .listRowBackground(
                            model.hovered === node && model.selected !== node
                            ? RoundedRectangle(cornerRadius: 5)
                                .fill(Color.primary.opacity(0.08))
                                .padding(.vertical, 2)
                                .padding(.horizontal, 10)   // match inset selection width
                            : nil
                        )
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
        nodeContextMenu(model, node)
    }
}

/// Shared right-click menu for a file node — used by sidebar rows and treemap tiles.
@ViewBuilder
func nodeContextMenu(_ model: AppModel, _ node: FileNode) -> some View {
    if node.isAggregate {
        Button("Open") { model.drill(into: node) }
    } else {
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
                Image(systemName: node.isAggregate ? "ellipsis.circle.fill"
                      : marked ? "trash"
                      : (node.isDirectory ? "folder.fill" : "doc.fill"))
                    .foregroundStyle(marked ? Color.red : node.tileColor)
                    .imageScale(.small)
                Text(node.isAggregate ? "Other — \(node.aggregatedCount) items" : node.name)
                    .lineLimit(1).truncationMode(.middle)
                    .strikethrough(marked, color: .red)
                    .foregroundStyle(node.isAggregate ? Color.secondary
                                     : marked ? Color.secondary : Color.primary)
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
    }
}

// MARK: - Scan spinner

/// A compact spinning-arc indicator tuned to sit inside a glass pill.
private struct ScanSpinner: View {
    @State private var rotation = 0.0

    var body: some View {
        Circle()
            .trim(from: 0, to: 0.28)
            .stroke(
                AngularGradient(colors: [.accentColor, .accentColor.opacity(0)],
                               center: .center),
                style: StrokeStyle(lineWidth: 2.4, lineCap: .round)
            )
            .frame(width: 16, height: 16)
            .rotationEffect(.degrees(rotation))
            .onAppear {
                withAnimation(.linear(duration: 0.8).repeatForever(autoreverses: false)) {
                    rotation = 360
                }
            }
    }
}

// MARK: - Detail (path bar + treemap + bottom bars)

private struct Detail: View {
    @Bindable var model: AppModel

    var body: some View {
        ZStack(alignment: .top) {
            if let current = model.current, !current.children.isEmpty {
                TreemapView(node: current,
                            version: model.version,
                            markedIDs: Set(model.marked.keys),
                            selected: $model.selected,
                            hovered: $model.hovered,
                            onDrill: { model.drill(into: $0) },
                            onToggleMark: { model.toggleMark($0) },
                            menu: { nodeContextMenu(model, $0) })
                    .padding(6)
            } else if !model.isScanning {
                ContentUnavailableView("Empty folder", systemImage: "tray")
            }

            // Non-blocking pill so results stream in visibly behind it.
            if model.isScanning {
                HStack(spacing: 12) {
                    ScanSpinner()
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Scanning…")
                            .font(.callout.weight(.medium))
                        Text("\(model.scannedCount.formatted()) items · \(model.scannedBytes.byteStringFixed)")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                    Button { model.cancelScan() } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(.secondary)
                            .frame(width: 18, height: 18)
                            .background(Circle().fill(.quaternary))
                    }
                    .buttonStyle(.plain)
                    .keyboardShortcut(.cancelAction)
                    .help("Cancel scan")
                }
                .padding(.horizontal, 16).padding(.vertical, 10)
                .background(.regularMaterial, in: Capsule())
                .overlay(Capsule().stroke(.quaternary, lineWidth: 0.5))
                .shadow(radius: 10, y: 3)
                .padding(.bottom, 14)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
            }
        }
        .safeAreaInset(edge: .top) {
            if model.root != nil { PathBar(model: model) }
        }
        .safeAreaInset(edge: .bottom) {
            if !model.marked.isEmpty { CleanupBar(model: model) }
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


#Preview {
    ContentView()
}

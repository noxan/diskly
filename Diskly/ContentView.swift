//
//  ContentView.swift
//  Diskly
//

import SwiftUI

struct ContentView: View {
    @State private var model = AppModel()

    var body: some View {
        NavigationSplitView {
            Sidebar(model: model)
                .navigationSplitViewColumnWidth(min: 240, ideal: 300, max: 420)
        } detail: {
            Detail(model: model)
        }
        .toolbar { Toolbar(model: model) }
        .navigationTitle(model.current?.name ?? "Diskly")
    }
}

// MARK: - Toolbar

private struct Toolbar: ToolbarContent {
    @Bindable var model: AppModel

    var body: some ToolbarContent {
        ToolbarItem(placement: .navigation) {
            // Breadcrumb trail.
            HStack(spacing: 2) {
                ForEach(Array(model.breadcrumbs.enumerated()), id: \.element.id) { i, node in
                    if i > 0 {
                        Image(systemName: "chevron.compact.right")
                            .foregroundStyle(.tertiary)
                    }
                    Button(node.name.isEmpty ? "/" : node.name) {
                        model.navigate(to: i == 0 ? nil : node)
                    }
                    .buttonStyle(.link)
                    .disabled(i == model.breadcrumbs.count - 1)
                }
            }
        }
        ToolbarItemGroup(placement: .primaryAction) {
            Button { model.rescan() } label: { Image(systemName: "arrow.clockwise") }
                .help("Rescan")
                .disabled(model.root == nil || model.isScanning)
            Button { model.open() } label: { Image(systemName: "folder.badge.plus") }
                .help("Choose folder to scan")
        }
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
                    Row(node: node, fraction: Double(node.size) / Double(total))
                        .tag(node.id)
                        .contentShape(Rectangle())
                        .onTapGesture(count: 2) { model.drill(into: node) }
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
        Button("Move to Trash") { model.trash(node) }
    }
}

private struct Row: View {
    let node: FileNode
    let fraction: Double

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Image(systemName: node.isDirectory ? "folder.fill" : "doc.fill")
                    .foregroundStyle(node.tileColor)
                    .imageScale(.small)
                Text(node.name).lineLimit(1).truncationMode(.middle)
                Spacer(minLength: 8)
                Text(node.size.byteString)
                    .foregroundStyle(.secondary)
                    .font(.callout.monospacedDigit())
            }
            GeometryReader { g in
                Capsule().fill(.quaternary)
                    .overlay(alignment: .leading) {
                        Capsule().fill(node.tileColor)
                            .frame(width: max(2, g.size.width * fraction))
                    }
            }
            .frame(height: 3)
        }
        .padding(.vertical, 2)
    }
}

// MARK: - Detail (treemap + info bar)

private struct Detail: View {
    @Bindable var model: AppModel

    var body: some View {
        ZStack {
            if let current = model.current, !current.children.isEmpty {
                TreemapView(node: current,
                            version: model.version,
                            selected: $model.selected,
                            onDrill: { model.drill(into: $0) })
            } else if model.root != nil {
                ContentUnavailableView("Empty folder", systemImage: "tray")
            } else {
                ContentUnavailableView {
                    Label("Diskly", systemImage: "chart.pie")
                } description: {
                    Text("Scan a folder to visualize disk usage.")
                } actions: {
                    Button("Choose Folder…") { model.open() }
                        .buttonStyle(.borderedProminent)
                }
            }

            if model.isScanning {
                Rectangle().fill(.regularMaterial)
                ProgressView("Scanning…").controlSize(.large)
            }
        }
        .safeAreaInset(edge: .bottom) { InfoBar(model: model) }
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
                    Button { model.trash(sel) } label: { Image(systemName: "trash") }
                        .help("Move to Trash")
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

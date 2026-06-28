//
//  TreemapView.swift
//  Diskly
//
//  Squarified treemap of a folder's immediate children.
//

import SwiftUI

struct Tile {
    let node: FileNode
    let rect: CGRect
}

enum Treemap {
    /// Squarified treemap layout (Bruls et al.). Keeps tiles near square so
    /// sizes stay visually comparable.
    static func layout(_ nodes: [FileNode], in rect: CGRect) -> [Tile] {
        let positive = nodes.filter { $0.size > 0 }.sorted { $0.size > $1.size }
        let total = Double(positive.reduce(Int64(0)) { $0 + $1.size })
        guard total > 0, rect.width > 1, rect.height > 1 else { return [] }

        let fullArea = Double(rect.width * rect.height)
        let items = positive.map { (node: $0, area: Double($0.size) / total * fullArea) }

        var tiles: [Tile] = []
        var free = rect
        var row: [(node: FileNode, area: Double)] = []

        func side() -> Double { Double(min(free.width, free.height)) }

        // Worst (largest) aspect ratio in a row given the fixed side length.
        func worst(_ row: [(node: FileNode, area: Double)], _ w: Double) -> Double {
            guard !row.isEmpty, w > 0 else { return .infinity }
            let s = row.reduce(0) { $0 + $1.area }
            guard s > 0 else { return .infinity }
            let rmax = row.map(\.area).max()!
            let rmin = row.map(\.area).min()!
            let w2 = w * w, s2 = s * s
            return max(w2 * rmax / s2, s2 / (w2 * rmin))
        }

        func placeRow() {
            let s = row.reduce(0) { $0 + $1.area }
            let w = side()
            guard s > 0, w > 0 else { row = []; return }
            let thickness = s / w
            if free.width <= free.height {           // pack across the top
                var x = free.minX
                for item in row {
                    let width = item.area / s * w
                    tiles.append(Tile(node: item.node,
                        rect: CGRect(x: x, y: free.minY, width: width, height: thickness)))
                    x += width
                }
                free = CGRect(x: free.minX, y: free.minY + thickness,
                              width: free.width, height: free.height - thickness)
            } else {                                  // pack down the left
                var y = free.minY
                for item in row {
                    let height = item.area / s * w
                    tiles.append(Tile(node: item.node,
                        rect: CGRect(x: free.minX, y: y, width: thickness, height: height)))
                    y += height
                }
                free = CGRect(x: free.minX + thickness, y: free.minY,
                              width: free.width - thickness, height: free.height)
            }
            row = []
        }

        var i = 0
        while i < items.count {
            let item = items[i]
            let w = side()
            if row.isEmpty || worst(row, w) >= worst(row + [item], w) {
                row.append(item)
                i += 1
            } else {
                placeRow()
            }
        }
        if !row.isEmpty { placeRow() }
        return tiles
    }
}

extension FileNode {
    /// Soft, type-derived fill. Folders read as cool neutral; files get a stable
    /// pastel hue per extension.
    var tileColor: Color {
        if isDirectory {
            return Color(hue: 0.58, saturation: 0.12, brightness: 0.78)
        }
        let ext = url.pathExtension.lowercased()
        guard !ext.isEmpty else {
            return Color(hue: 0, saturation: 0, brightness: 0.7)
        }
        var h = 5381
        for b in ext.utf8 { h = (h &* 33) &+ Int(b) }
        let hue = Double(((h % 360) + 360) % 360) / 360.0
        return Color(hue: hue, saturation: 0.42, brightness: 0.82)
    }
}

/// Memoizes the squarified layout so it isn't recomputed on hover/selection.
@Observable final class LayoutCache {
    private var key = ""
    private(set) var tiles: [Tile] = []

    func tiles(_ node: FileNode, _ version: Int, _ size: CGSize) -> [Tile] {
        let k = "\(node.id)|\(node.size)|\(version)|\(Int(size.width))x\(Int(size.height))"
        if k != key {
            tiles = Treemap.layout(node.sortedChildren,
                                   in: CGRect(origin: .zero, size: size))
            key = k
        }
        return tiles
    }
}

struct TreemapView: View {
    let node: FileNode
    let version: Int
    @Binding var selected: FileNode?
    let onDrill: (FileNode) -> Void

    @State private var cache = LayoutCache()
    @State private var hovered: FileNode?

    var body: some View {
        GeometryReader { geo in
            let tiles = cache.tiles(node, version, geo.size)
            ZStack(alignment: .topLeading) {
                // Heavy layer: only re-renders when layout or selection changes,
                // never on hover (Equatable gate below).
                TreemapCanvas(tiles: tiles, selectedID: selected?.id)
                    .equatable()
                // Cheap hover highlight — a single overlaid shape.
                if let r = tiles.first(where: { $0.node === hovered })?.rect,
                   r.width > 2, r.height > 2 {
                    RoundedRectangle(cornerRadius: 5)
                        .fill(.white.opacity(0.18))
                        .frame(width: r.width - 2, height: r.height - 2)
                        .offset(x: r.minX + 1, y: r.minY + 1)
                        .allowsHitTesting(false)
                }
            }
            .contentShape(Rectangle())
            .gesture(ExclusiveGesture(
                SpatialTapGesture(count: 2).onEnded { e in
                    if let t = hit(tiles, e.location) { onDrill(t.node) }
                },
                SpatialTapGesture(count: 1).onEnded { e in
                    selected = hit(tiles, e.location)?.node
                }
            ))
            .onContinuousHover { phase in
                switch phase {
                case .active(let p): hovered = hit(tiles, p)?.node
                case .ended: hovered = nil
                }
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private func hit(_ tiles: [Tile], _ p: CGPoint) -> Tile? {
        tiles.first { $0.rect.contains(p) }
    }
}

/// The base treemap drawing. Equatable so SwiftUI skips redraws unless the tile
/// set or selection actually changed.
private struct TreemapCanvas: View, Equatable {
    let tiles: [Tile]
    let selectedID: URL?

    static func == (l: TreemapCanvas, r: TreemapCanvas) -> Bool {
        l.selectedID == r.selectedID
            && l.tiles.count == r.tiles.count
            && l.tiles.first?.node.id == r.tiles.first?.node.id
            && l.tiles.first?.rect == r.tiles.first?.rect   // catches resize
    }

    var body: some View {
        Canvas { ctx, _ in
            for tile in tiles { draw(tile, in: &ctx) }
        }
    }

    private func draw(_ tile: Tile, in ctx: inout GraphicsContext) {
        let inset = tile.rect.insetBy(dx: 1, dy: 1)
        guard inset.width > 1.5, inset.height > 1.5 else { return }  // skip invisible
        let path = Path(roundedRect: inset, cornerRadius: min(5, inset.height / 3))

        ctx.fill(path, with: .color(tile.node.tileColor))
        ctx.stroke(path, with: .color(.black.opacity(0.08)), lineWidth: 1)
        if selectedID == tile.node.id {
            ctx.stroke(path, with: .color(.accentColor), lineWidth: 2.5)
        }

        // Label only where there's room.
        if inset.width > 54 && inset.height > 26 {
            var label = ctx
            label.clip(to: path)
            label.draw(label.resolve(Text(tile.node.name)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.black.opacity(0.72))),
                at: CGPoint(x: inset.minX + 6, y: inset.minY + 5), anchor: .topLeading)
            if inset.height > 42 {
                label.draw(label.resolve(Text(tile.node.size.byteString)
                    .font(.system(size: 9))
                    .foregroundStyle(.black.opacity(0.5))),
                    at: CGPoint(x: inset.minX + 6, y: inset.minY + 20), anchor: .topLeading)
            }
        }
    }
}

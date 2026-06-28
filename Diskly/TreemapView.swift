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

struct TreemapView<Menu: View>: View {
    let node: FileNode
    let version: Int
    let markedIDs: Set<URL>
    @Binding var selected: FileNode?
    @Binding var hovered: FileNode?
    let onDrill: (FileNode) -> Void
    let onToggleMark: (FileNode) -> Void
    @ViewBuilder let menu: (FileNode) -> Menu

    @State private var cache = LayoutCache()

    private enum Move { case left, right, up, down }

    var body: some View {
        GeometryReader { geo in
            let tiles = cache.tiles(node, version, geo.size)
            ZStack(alignment: .topLeading) {
                // Heavy layer: only re-renders when layout, selection, or marks
                // change — never on hover (Equatable gate below).
                TreemapCanvas(tiles: tiles, selectedID: selected?.id, markedIDs: markedIDs)
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
            // Right-click acts on the tile under the cursor (tracked via hover).
            .contextMenu {
                if let target = hovered { menu(target) }
            }
            // Select fires instantly on the first tap; double-tap also drills.
            // (Not exclusive — exclusive makes the single tap wait out the
            // double-click window, which is the delay we're killing.)
            .gesture(SpatialTapGesture(count: 1).onEnded { e in
                selected = hit(tiles, e.location)?.node
            })
            .gesture(SpatialTapGesture(count: 2).onEnded { e in
                if let t = hit(tiles, e.location) { onDrill(t.node) }
            })
            .onContinuousHover { phase in
                switch phase {
                case .active(let p): hovered = hit(tiles, p)?.node
                case .ended: hovered = nil
                }
            }
            // Keyboard: arrows move selection spatially, delete toggles the mark,
            // return drills in. Needs focus — clicking the treemap grants it.
            .focusable()
            .focusEffectDisabled()
            .onKeyPress(.leftArrow)  { move(.left, tiles);  return .handled }
            .onKeyPress(.rightArrow) { move(.right, tiles); return .handled }
            .onKeyPress(.upArrow)    { move(.up, tiles);    return .handled }
            .onKeyPress(.downArrow)  { move(.down, tiles);  return .handled }
            .onKeyPress(.return)     { if let s = selected { onDrill(s) }; return .handled }
            .onKeyPress(.delete)        { toggleSelected(); return .handled }
            .onKeyPress(.deleteForward) { toggleSelected(); return .handled }
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private func hit(_ tiles: [Tile], _ p: CGPoint) -> Tile? {
        tiles.first { $0.rect.contains(p) }
    }

    private func toggleSelected() {
        if let s = selected { onToggleMark(s) }
    }

    /// Move selection to the nearest tile in `dir`. With nothing selected, picks
    /// the first (largest) tile so the keyboard has an entry point.
    private func move(_ dir: Move, _ tiles: [Tile]) {
        guard let cur = tiles.first(where: { $0.node === selected }) else {
            selected = tiles.first?.node
            return
        }
        let c = CGPoint(x: cur.rect.midX, y: cur.rect.midY)
        let next = tiles
            .filter { t in
                switch dir {
                case .left:  return t.rect.midX < c.x - 1
                case .right: return t.rect.midX > c.x + 1
                case .up:    return t.rect.midY < c.y - 1
                case .down:  return t.rect.midY > c.y + 1
                }
            }
            // Distance along the travel axis, with off-axis drift penalized so
            // an arrow tends to land on the neighbor it visually points at.
            .min { a, b in score(a.rect, c, dir) < score(b.rect, c, dir) }
        if let next { selected = next.node }
    }

    private func score(_ r: CGRect, _ from: CGPoint, _ dir: Move) -> Double {
        let dx = abs(Double(r.midX - from.x)), dy = abs(Double(r.midY - from.y))
        switch dir {
        case .left, .right: return dx + 2 * dy
        case .up, .down:    return dy + 2 * dx
        }
    }
}

/// The base treemap drawing. Equatable so SwiftUI skips redraws unless the tile
/// set or selection actually changed.
private struct TreemapCanvas: View, Equatable {
    let tiles: [Tile]
    let selectedID: URL?
    let markedIDs: Set<URL>

    static func == (l: TreemapCanvas, r: TreemapCanvas) -> Bool {
        l.selectedID == r.selectedID
            && l.markedIDs == r.markedIDs
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
        let isMarked = markedIDs.contains(tile.node.id)

        ctx.fill(path, with: .color(tile.node.tileColor))
        if isMarked {
            ctx.fill(path, with: .color(.red.opacity(0.45)))
        }
        ctx.stroke(path, with: .color(.black.opacity(0.08)), lineWidth: 1)
        if isMarked {
            ctx.stroke(path, with: .color(.red), lineWidth: 2)
        }
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

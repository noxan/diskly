//
//  PreviewPanel.swift
//  Diskly
//
//  Finder-style Quick Look preview — space opens, space or escape closes,
//  tracks the current selection while open.
//

import SwiftUI
import Quartz
import AppKit

// MARK: - Quick Look bridge

/// Wraps `QLPreviewView` — the same engine Finder's Quick Look uses — so SwiftUI
/// can render a native preview for any file or folder URL.
struct QuickLookView: NSViewRepresentable {
    let url: URL

    func makeNSView(context: Context) -> QLPreviewView {
        let view = QLPreviewView(frame: .zero, style: .normal)!
        view.previewItem = PreviewItem(url: url)
        return view
    }

    func updateNSView(_ nsView: QLPreviewView, context: Context) {
        if (nsView.previewItem as? PreviewItem)?.url != url {
            nsView.previewItem = PreviewItem(url: url)
        }
    }
}

/// Feeds a URL (and optional title) to `QLPreviewView` via `QLPreviewItem`.
private final class PreviewItem: NSObject, QLPreviewItem {
    let url: URL
    init(url: URL) { self.url = url }
    var previewItemURL: URL? { url }
    var previewItemTitle: String? { nil }
}

// MARK: - Preview panel

/// Floating, non-modal preview panel. Mirrors Finder's Quick Look: space opens,
/// space or escape closes, and the panel follows the current selection while open.
struct PreviewPanel: View {
    @Bindable var model: AppModel
    let node: FileNode

    var body: some View {
        VStack(spacing: 0) {
            header
            QuickLookView(url: node.url)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(width: 560, height: 400)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(.quaternary, lineWidth: 0.5))
        .shadow(radius: 24, y: 8)
        .focusable()
        .onKeyPress(.space) { model.closePreview(); return .handled }
        .onKeyPress(.escape) { model.closePreview(); return .handled }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: node.isAggregate ? "ellipsis.circle.fill"
                  : node.isDirectory ? "folder.fill" : "doc.fill")
                .foregroundStyle(node.tileColor)
                .imageScale(.small)
            Text(node.isAggregate ? "Other" : node.name)
                .lineLimit(1).truncationMode(.middle)
                .fontWeight(.medium)
            Text(node.size.byteString)
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
            Spacer()
            Button { model.closePreview() } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.title3)
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("Close preview (Space)")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(.bar)
    }
}

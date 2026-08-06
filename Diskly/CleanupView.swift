import AppKit
import SwiftUI

struct CleanupPreview: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: "broom.fill")
                    .font(.title2)
                    .foregroundStyle(.tint)
                VStack(alignment: .leading, spacing: 2) {
                    Text("NEW").font(.caption2.bold()).foregroundStyle(.tint)
                    Text("Clean developer caches").fontWeight(.medium)
                    Text("Start with Bun").font(.caption).foregroundStyle(.secondary)
                }
                Image(systemName: "chevron.right").foregroundStyle(.tertiary)
            }
            .padding(14)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(.quaternary))
            .shadow(radius: 8, y: 3)
        }
        .buttonStyle(.plain)
    }
}

struct CleanupView: View {
    let model: AppModel
    let onDone: () -> Void
    @State private var pending: CleanupTarget?
    @State private var isCleaning = false
    @State private var isScanning = false
    @State private var needsAccess = false
    @State private var sizes: [String: Int64] = [:]
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack {
                Text("Clean Up").font(.title.bold())
                Spacer()
                if needsAccess {
                    Button("Allow Home Access") {
                        guard let access = requestHomeAccess() else { return }
                        Task { await scanSizes(access: access) }
                    }
                }
                Button("Done", action: onDone)
            }

            ForEach(CleanupTarget.all) { target in
                HStack(spacing: 12) {
                    Image(systemName: target.icon).font(.title2).foregroundStyle(.tint)
                    VStack(alignment: .leading) {
                        Text(target.name).fontWeight(.medium)
                        Text(target.cacheURL.path).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if let size = sizes[target.id] {
                        Text(size.byteString)
                            .font(.callout.monospacedDigit())
                            .foregroundStyle(.secondary)
                    } else if isScanning {
                        ProgressView().controlSize(.small)
                    }
                    Button(isCleaning ? "Cleaning…" : "Clean…") { pending = target }
                        .disabled(isCleaning || isScanning)
                }
                .padding()
                .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))
            }

            Spacer()
        }
        .padding(24)
        .frame(maxWidth: 700, maxHeight: .infinity)
        .task { await refreshSizes() }
        .confirmationDialog("Clean \(pending?.name ?? "cache")?", isPresented: Binding(
            get: { pending != nil }, set: { if !$0 { pending = nil } }
        )) {
            if let target = pending {
                Button("Clean", role: .destructive) {
                    pending = nil
                    clean(target)
                }
            }
        } message: {
            Text("Bun will permanently remove its cached packages. They can be downloaded again.")
        }
        .alert("Cleanup failed", isPresented: Binding(
            get: { error != nil }, set: { if !$0 { error = nil } }
        )) { Button("OK", role: .cancel) {} } message: { Text(error ?? "") }
    }

    private func clean(_ target: CleanupTarget) {
        let access = model.beginGrantedAccess(for: QuickLocation.realHome) ?? requestHomeAccess()
        guard let access else { return }
        let homePath = QuickLocation.realHome.path
        isCleaning = true
        Task {
            let failure = await Task.detached(priority: .userInitiated) {
                defer { access.stopAccessingSecurityScopedResource() }
                let process = Process()
                process.executableURL = target.executableURL
                process.arguments = target.arguments
                process.environment = ProcessInfo.processInfo.environment.merging(
                    ["HOME": homePath], uniquingKeysWith: { _, home in home })
                do {
                    try process.run()
                    process.waitUntilExit()
                    return process.terminationReason == .exit && process.terminationStatus == 0
                        ? nil : "\(target.name) exited with status \(process.terminationStatus)."
                } catch { return error.localizedDescription }
            }.value
            isCleaning = false
            if let failure { error = "Couldn't clean \(target.name): \(failure)" }
            else { await refreshSizes() }
        }
    }

    private func refreshSizes() async {
        guard !isScanning,
              let access = model.beginGrantedAccess(for: QuickLocation.realHome) else {
            needsAccess = true
            return
        }
        await scanSizes(access: access)
    }

    private func scanSizes(access: URL) async {
        needsAccess = false
        isScanning = true
        defer {
            access.stopAccessingSecurityScopedResource()
            isScanning = false
        }
        await withTaskGroup(of: (String, Int64).self) { group in
            for target in CleanupTarget.all {
                let id = target.id
                let url = target.cacheURL
                group.addTask { (id, await Scanner.size(of: url)) }
            }
            for await (id, size) in group { sizes[id] = size }
        }
    }

    private func requestHomeAccess() -> URL? {
        let home = QuickLocation.realHome
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = home.deletingLastPathComponent()
        panel.prompt = "Allow"
        panel.message = "Choose your Home folder to let Diskly clean developer caches"
        guard panel.runModal() == .OK, let url = panel.url,
              home.path == url.path || home.path.hasPrefix(url.path + "/"),
              url.startAccessingSecurityScopedResource() else { return nil }
        model.rememberRecent(url)
        return url
    }
}

private struct CleanupTarget: Identifiable, Sendable {
    let name: String
    let icon: String
    let cacheURL: URL
    let executableURL: URL
    let arguments: [String]
    var id: String { name }

    static var all: [CleanupTarget] {
        let home = QuickLocation.realHome
        return [.init(name: "Bun cache", icon: "shippingbox",
                      cacheURL: home.appending(path: ".bun/install/cache"),
                      executableURL: home.appending(path: ".bun/bin/bun"),
                      arguments: ["pm", "cache", "rm"])]
    }
}

private extension Scanner {
    /// Reuse the production walker; discard its tree and keep the byte counter.
    static func size(of url: URL) async -> Int64 {
        let root = FileNode(name: url.lastPathComponent, isDirectory: true,
                            parent: nil, fixedURL: url)
        let progress = ScanProgress()
        await scanStreaming(url, parent: root, progress: progress) { _ in }
        return progress.bytes
    }
}

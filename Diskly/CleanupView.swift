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
                    Text("See what can be safely reclaimed")
                        .font(.caption).foregroundStyle(.secondary)
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
    @State private var pending: CleanupTarget?
    @State private var isCleaning = false
    @State private var isScanning = false
    @State private var needsRescan = false
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
            }

            ForEach(CleanupTarget.all) { target in
                HStack(spacing: 12) {
                    Image(systemName: target.icon).font(.title2).foregroundStyle(.tint)
                    VStack(alignment: .leading) {
                        Text(target.name).fontWeight(.medium)
                        Text(target.sizeSource.label).font(.caption).foregroundStyle(.secondary)
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
                        .disabled(isCleaning)
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
            Text(pending?.message ?? "")
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
            let failure: String? = await Task.detached(priority: .userInitiated) {
                defer { access.stopAccessingSecurityScopedResource() }
                do {
                    switch target.action {
                    case .trashContents(let url):
                        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
                        for item in try FileManager.default.contentsOfDirectory(
                            at: url, includingPropertiesForKeys: nil) {
                            try FileManager.default.trashItem(at: item, resultingItemURL: nil)
                        }
                        return nil
                    case .command(let executable, let arguments):
                        let process = Process()
                        process.executableURL = executable
                        process.arguments = arguments
                        process.environment = ProcessInfo.processInfo.environment.merging(
                            ["HOME": homePath], uniquingKeysWith: { _, home in home })
                        try process.run()
                        process.waitUntilExit()
                        return process.terminationReason == .exit && process.terminationStatus == 0
                            ? nil : "\(target.name) exited with status \(process.terminationStatus)."
                    }
                } catch { return error.localizedDescription }
            }.value
            isCleaning = false
            if let failure { error = "Couldn't clean \(target.name): \(failure)" }
            else if isScanning { needsRescan = true }
            else { await refreshSizes() }
        }
    }

    private func refreshSizes() async {
        guard !isScanning else { return }
        guard let access = model.beginGrantedAccess(for: QuickLocation.realHome) else {
            needsAccess = true
            return
        }
        await scanSizes(access: access)
    }

    private func scanSizes(access: URL) async {
        needsAccess = false
        isScanning = true
        await withTaskGroup(of: (String, Int64).self) { group in
            for target in CleanupTarget.all {
                let id = target.id
                let source = target.sizeSource
                group.addTask { (id, await source.size()) }
            }
            for await (id, size) in group { sizes[id] = size }
        }
        access.stopAccessingSecurityScopedResource()
        isScanning = false
        if needsRescan {
            needsRescan = false
            await refreshSizes()
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
    let sizeSource: CleanupSizeSource
    let action: CleanupAction
    let message: String
    var id: String { name }

    static var all: [CleanupTarget] {
        let home = QuickLocation.realHome
        return [
            .init(name: "Homebrew", icon: "mug.fill",
                  sizeSource: .files(home.appending(path: "Library/Caches/Homebrew")),
                  action: .trashContents(home.appending(path: "Library/Caches/Homebrew")),
                  message: "Diskly will move Homebrew's cached downloads to the Trash."),
            .init(name: "Bun cache", icon: "shippingbox",
                  sizeSource: .files(home.appending(path: ".bun/install/cache")),
                  action: .command(executable(named: "bun", home: home),
                                   ["pm", "cache", "rm"]),
                  message: "Bun will permanently remove its cached packages. They can be downloaded again."),
            .init(name: "Docker", icon: "shippingbox.fill",
                  sizeSource: .docker(executable(named: "docker", home: home), home.path),
                  action: .command(executable(named: "docker", home: home),
                                   ["system", "prune", "--all", "--force"]),
                  message: "Docker will remove stopped containers, unused networks, build cache, and all unused images. Volumes are kept.")
        ]
    }

    private static func executable(named name: String, home: URL) -> URL {
        let candidates = [home.appending(path: ".bun/bin/\(name)"),
                          URL(filePath: "/etc/profiles/per-user/\(NSUserName())/bin/\(name)"),
                          URL(filePath: "/opt/homebrew/bin/\(name)"),
                          URL(filePath: "/usr/local/bin/\(name)")]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0.path) }
            ?? candidates[0]
    }
}

private enum CleanupAction: Sendable {
    case trashContents(URL)
    case command(URL, [String])
}

private enum CleanupSizeSource: Sendable {
    case files(URL)
    case docker(URL, String)

    var label: String {
        switch self {
        case .files(let url): url.path
        case .docker: "Docker-managed storage"
        }
    }

    func size() async -> Int64 {
        switch self {
        case .files(let url): await Scanner.size(of: url)
        case .docker(let executable, let home): await Self.dockerSize(executable, home: home)
        }
    }

    private static func dockerSize(_ executable: URL, home: String) async -> Int64 {
        await Task.detached {
            assert(byteCount("1.5GB") == 1_500_000_000)
            let process = Process()
            let output = Pipe()
            process.executableURL = executable
            process.arguments = ["system", "df", "--format", "{{json .}}"]
            process.environment = ProcessInfo.processInfo.environment.merging(
                ["HOME": home], uniquingKeysWith: { _, home in home })
            process.standardOutput = output
            process.standardError = FileHandle.nullDevice
            do {
                try process.run()
                process.waitUntilExit()
                guard process.terminationStatus == 0 else { return 0 }
                let data = output.fileHandleForReading.readDataToEndOfFile()
                return String(decoding: data, as: UTF8.self).split(separator: "\n").reduce(0) {
                    guard let json = try? JSONSerialization.jsonObject(with: Data($1.utf8)) as? [String: String],
                          let value = json["Reclaimable"]?.split(separator: " ").first else { return $0 }
                    return $0 + byteCount(String(value))
                }
            } catch { return 0 }
        }.value
    }

    nonisolated private static func byteCount(_ value: String) -> Int64 {
        let units: [(String, Double)] = [("TB", 1e12), ("GB", 1e9), ("MB", 1e6),
                                         ("kB", 1e3), ("B", 1)]
        guard let (suffix, multiplier) = units.first(where: { value.hasSuffix($0.0) }),
              let number = Double(value.dropLast(suffix.count)) else { return 0 }
        return Int64(number * multiplier)
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

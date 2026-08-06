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

            ScrollView {
                LazyVStack(spacing: 10) {
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
                        .background(.quaternary.opacity(0.5),
                                    in: RoundedRectangle(cornerRadius: 10))
                    }
                }
            }
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
                    case .trashContents(let urls):
                        try trashContents(urls, named: target.name,
                                          home: URL(filePath: homePath))
                        return nil
                    case .command(let executable, let arguments):
                        let process = Process()
                        let errors = Pipe()
                        process.executableURL = executable
                        process.arguments = arguments
                        process.standardError = errors
                        process.environment = ProcessInfo.processInfo.environment.merging(
                            ["HOME": homePath], uniquingKeysWith: { _, home in home })
                        try process.run()
                        process.waitUntilExit()
                        guard process.terminationReason != .exit || process.terminationStatus != 0
                        else { return nil }
                        let detail = String(decoding: errors.fileHandleForReading.readDataToEndOfFile(),
                                            as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
                        return detail.isEmpty
                            ? "\(target.name) exited with status \(process.terminationStatus)."
                            : detail
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
        // Each filesystem scan already fans out across all cores. Running all
        // targets together oversubscribes the machine and starves the UI.
        for target in CleanupTarget.all {
            if Task.isCancelled { break }
            sizes[target.id] = await target.sizeSource.size()
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

nonisolated private func trashContents(_ urls: [URL], named name: String,
                                       home: URL) throws {
    let files = FileManager.default
    let staging = home.appending(path: "Library/Caches/Diskly \(name) Cache \(UUID().uuidString.prefix(8))")
    var staged = false
    do {
        for url in urls where files.fileExists(atPath: url.path) {
            let destination = urls.count == 1 ? staging : staging.appending(path: url.lastPathComponent)
            try files.createDirectory(at: destination, withIntermediateDirectories: true)
            for item in try files.contentsOfDirectory(at: url, includingPropertiesForKeys: nil) {
                try files.moveItem(at: item, to: destination.appending(path: item.lastPathComponent))
                staged = true
            }
        }
    } catch {
        if staged { try? files.trashItem(at: staging, resultingItemURL: nil) }
        throw error
    }
    if staged { try files.trashItem(at: staging, resultingItemURL: nil) }
    else { try? files.removeItem(at: staging) }
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
        let environment = ProcessInfo.processInfo.environment
        let bunCache = configuredPath(["BUN_INSTALL_CACHE_DIR"], environment: environment)
            ?? home.appending(path: ".bun/install/cache")
        let brewCache = configuredPath(["HOMEBREW_CACHE"], environment: environment)
            ?? home.appending(path: "Library/Caches/Homebrew")
        let gradleHome = configuredPath(["GRADLE_USER_HOME"], environment: environment)
            ?? home.appending(path: ".gradle")
        let npmCache = configuredPath(["npm_config_cache", "NPM_CONFIG_CACHE"],
                                      environment: environment)
            ?? home.appending(path: ".npm")
        let cargoHome = configuredPath(["CARGO_HOME"], environment: environment)
            ?? home.appending(path: ".cargo")
        let pipCache = configuredPath(["PIP_CACHE_DIR"], environment: environment)
            ?? home.appending(path: "Library/Caches/pip")
        let cypressCache = configuredPath(["CYPRESS_CACHE_FOLDER"], environment: environment)
            ?? home.appending(path: "Library/Caches/Cypress")
        let playwrightCache = environment["PLAYWRIGHT_BROWSERS_PATH"] == "0" ? nil
            : configuredPath(["PLAYWRIGHT_BROWSERS_PATH"], environment: environment)
                ?? home.appending(path: "Library/Caches/ms-playwright")
        return [
            .init(name: "Homebrew", icon: "mug.fill",
                  sizeSource: .files([brewCache]),
                  action: .trashContents([brewCache]),
                  message: "Diskly will move Homebrew's cached downloads to the Trash."),
            .init(name: "Bun cache", icon: "shippingbox",
                  sizeSource: .files([bunCache]),
                  action: .trashContents([bunCache]),
                  message: "Diskly will move Bun's cached packages to the Trash. They can be downloaded again."),
            .init(name: "Docker", icon: "shippingbox.fill",
                  sizeSource: .docker(executable(named: "docker", home: home), home.path),
                  action: .command(executable(named: "docker", home: home),
                                   ["system", "prune", "--all", "--force"]),
                  message: "Docker will remove stopped containers, unused networks, build cache, and all unused images. Volumes are kept."),
            fileTarget("Gradle", icon: "hammer.fill", urls: [gradleHome.appending(path: "caches")]),
            fileTarget("Xcode DerivedData", icon: "hammer.circle.fill",
                       urls: [home.appending(path: "Library/Developer/Xcode/DerivedData")]),
            fileTarget("npm", icon: "shippingbox.circle.fill",
                       urls: [npmCache.appending(path: "_cacache")]),
            fileTarget("Cargo", icon: "shippingbox.fill", urls: [
                cargoHome.appending(path: "registry/cache"),
                cargoHome.appending(path: "registry/src"),
                cargoHome.appending(path: "git/db"),
                cargoHome.appending(path: "git/checkouts")
            ]),
            fileTarget("pip", icon: "cube.fill", urls: [pipCache]),
            fileTarget("Cypress", icon: "checkmark.circle.fill", urls: [cypressCache])
        ] + (playwrightCache.map {
            [fileTarget("Playwright browsers", icon: "globe", urls: [$0])]
        } ?? [])
    }

    private static func fileTarget(_ name: String, icon: String,
                                   urls: [URL]) -> CleanupTarget {
        .init(name: name, icon: icon, sizeSource: .files(urls),
              action: .trashContents(urls),
              message: "Diskly will move \(name)'s disposable cache to the Trash.")
    }

    private static func configuredPath(_ keys: [String],
                                       environment: [String: String]) -> URL? {
        guard let value = keys.lazy.compactMap({ environment[$0] }).first(where: { !$0.isEmpty })
        else { return nil }
        return URL(filePath: NSString(string: value).expandingTildeInPath)
    }

    private static func executable(named name: String, home: URL) -> URL {
        let pathCandidates = (ProcessInfo.processInfo.environment["PATH"] ?? "")
            .split(separator: ":")
            .map { URL(filePath: String($0)).appending(path: name) }
        let candidates = pathCandidates + [
            home.appending(path: ".local/bin/\(name)"),
            home.appending(path: ".bun/bin/\(name)"),
            URL(filePath: "/etc/profiles/per-user/\(NSUserName())/bin/\(name)"),
            URL(filePath: "/run/current-system/sw/bin/\(name)"),
            URL(filePath: "/opt/homebrew/bin/\(name)"),
            URL(filePath: "/usr/local/bin/\(name)"),
            URL(filePath: "/opt/local/bin/\(name)")
        ]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0.path) }
            ?? home.appending(path: ".local/bin/\(name)")
    }
}

private enum CleanupAction: Sendable {
    case trashContents([URL])
    case command(URL, [String])
}

private enum CleanupSizeSource: Sendable {
    case files([URL])
    case docker(URL, String)

    var label: String {
        switch self {
        case .files(let urls): urls.count == 1 ? urls[0].path : "\(urls.count) cache locations"
        case .docker: "Docker-managed storage"
        }
    }

    func size() async -> Int64 {
        switch self {
        case .files(let urls):
            var total: Int64 = 0
            for url in urls { total += await Scanner.size(of: url) }
            return total
        case .docker(let executable, let home):
            return await Self.dockerSize(executable, home: home)
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

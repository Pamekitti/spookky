import AppKit
import SpookkyCore
import SpookkyRuntime
import GhosttyKit

@MainActor final class GhosttyAppearanceFollower {
    var onAppearance: ((GhosttyAppearanceProfile) -> Void)?
    var onError: ((String) -> Void)?
    private let watcher = AppearanceFileWatcher()
    private var task: Task<Void, Never>?
    private var activation: NSObjectProtocol?
    private var refreshPending = false
    private let folders: [String]
    private let sourceFile: String?
    private let cache: URL?
    private var restoredCache = false
    private var cachedProfile: GhosttyAppearanceProfile?
    init(file: String? = nil, cache: URL? = nil) {
        sourceFile = file; self.cache = cache
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let xdg = ProcessInfo.processInfo.environment["XDG_CONFIG_HOME"] ?? home + "/.config"
        folders = (file.map { [URL(fileURLWithPath: $0).deletingLastPathComponent().path] } ?? [xdg + "/ghostty", home + "/Library/Application Support/com.mitchellh.ghostty"])
    }
    func start() {
        watcher.onChange = { [weak self] in self?.refresh() }
        activation = NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
        refresh()
    }
    private func watch(_ dependencies: [String]) async -> Bool {
        let defaults = sourceFile.map { [$0] } ?? folders.flatMap { [$0 + "/config", $0 + "/config.ghostty"] }
        return await watcher.watch(defaults + dependencies.prefix(64).filter { $0.hasPrefix("/") })
    }
    func refresh() {
        refreshPending = true
        guard task == nil else { return }
        task = Task { [weak self] in
            guard let self else { return }
            defer { task = nil }
            if !restoredCache {
                restoredCache = true
                _ = await watch([])
                let cacheURL = cache
                if let saved = await Task.detached(priority: .utility, operation: { () -> GhosttyAppearanceProfile? in
                    guard let cacheURL, let size = try? cacheURL.resourceValues(forKeys: [.fileSizeKey]).fileSize, size <= 524288,
                          let data = try? Data(contentsOf: cacheURL) else { return nil }
                    return try? JSONDecoder().decode(GhosttyAppearanceProfile.self, from: data)
                }).value {
                    cachedProfile = saved
                    _ = await watch(saved.dependencies); onAppearance?(saved)
                }
            }
            while refreshPending && !Task.isCancelled {
                refreshPending = false
                do {
                    let file = sourceFile, cacheURL = cache, saved = cachedProfile
                    let (next, cacheUpdated) = try await Task.detached(priority: .utility) {
                        let result = try Self.readProfile(file: file)
                        let cacheUpdated: Bool
                        if let cacheURL, result != saved {
                            cacheUpdated = (try? PrivateFiles.write(result, to: cacheURL)) != nil
                        } else { cacheUpdated = false }
                        return (result, cacheUpdated)
                    }.value
                    guard !Task.isCancelled else { return }
                    if cacheUpdated { cachedProfile = next }
                    if await watch(next.dependencies) { refreshPending = true }
                    onAppearance?(next)
                } catch { onError?(error.localizedDescription) }
            }
        }
    }
    nonisolated static func readProfile(file: String? = nil) throws -> GhosttyAppearanceProfile {
        guard let config = ghostty_config_new() else { throw LaunchError.invalid("Could not initialize terminal appearance.") }
        defer { ghostty_config_free(config) }
        if let file {
            file.withCString { ghostty_config_load_file(config, $0) }
            ghostty_config_load_recursive_files(config); ghostty_config_finalize(config)
        } else if !spookky_config_load_default_files(config) {
            throw LaunchError.invalid("Ghostty configuration is invalid. The last valid appearance is retained.")
        }
        guard ghostty_config_diagnostics_count(config) == 0 else { throw LaunchError.invalid("Ghostty configuration is invalid. The last valid appearance is retained.") }
        func export(dark: Bool) throws -> GhosttyAppearance {
            let result = spookky_config_export_appearance(config, dark)
            defer { ghostty_string_free(result) }
            guard let pointer = result.ptr, result.len > 0, result.len <= 262144 else { throw LaunchError.invalid("Could not resolve the Ghostty theme. The last valid appearance is retained.") }
            return GhosttyAppearance(export: String(decoding: UnsafeBufferPointer(start: UnsafeRawPointer(pointer).assumingMemoryBound(to: UInt8.self), count: Int(result.len)), as: UTF8.self))
        }
        return try GhosttyAppearanceProfile(light: export(dark: false), dark: export(dark: true))
    }
    func stop() { watcher.stop(); task?.cancel(); task = nil; if let activation { NotificationCenter.default.removeObserver(activation) }; activation = nil }
}

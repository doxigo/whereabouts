import Foundation

/// settings.json + history.json under ~/Library/Application Support/Whereabouts.
/// On first launch it adopts GeoMeister's files, which share the format.
enum Store {
    static let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Whereabouts", isDirectory: true)
    static let settingsURL = dir.appendingPathComponent("settings.json")
    static let historyURL = dir.appendingPathComponent("history.json")
    static let maxHistory = 200

    static func loadSettings() -> AppSettings {
        importGeoMeisterOnce()
        guard let data = try? Data(contentsOf: settingsURL),
              var settings = try? JSONDecoder().decode(AppSettings.self, from: data) else { return AppSettings() }
        settings.normalize()
        return settings
    }

    static func save(_ settings: AppSettings) { write(settings, to: settingsURL) }

    static func loadHistory() -> [HistoryEntry] {
        guard let data = try? Data(contentsOf: historyURL),
              let list = try? JSONDecoder().decode([HistoryEntry].self, from: data) else { return [] }
        return Array(list.prefix(maxHistory))
    }

    static func save(_ history: [HistoryEntry]) { write(history, to: historyURL) }

    private static func write<T: Encodable>(_ value: T, to url: URL) {
        guard !Demo.enabled else { return }
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(value).write(to: url, options: .atomic)
        } catch {
            log.error("Failed to write \(url.lastPathComponent): \(error.localizedDescription)")
        }
    }

    /// Copies GeoMeister's settings/history the first time Whereabouts runs.
    private static func importGeoMeisterOnce() {
        let fm = FileManager.default
        guard !fm.fileExists(atPath: settingsURL.path) else { return }
        let support = dir.deletingLastPathComponent()
        // The locally built Glaze app is the one installed; the store build is the fallback.
        for bundle in ["app.glaze.macos.12fbzqnu-local", "app.glaze.macos.12fbzqnu"] {
            let source = support.appendingPathComponent(bundle)
            guard fm.fileExists(atPath: source.appendingPathComponent("settings.json").path) else { continue }
            try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
            try? fm.copyItem(at: source.appendingPathComponent("settings.json"), to: settingsURL)
            try? fm.copyItem(at: source.appendingPathComponent("history.json"), to: historyURL)
            log.info("Imported GeoMeister settings from \(bundle)")
            return
        }
    }
}

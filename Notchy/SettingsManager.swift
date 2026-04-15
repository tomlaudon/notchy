import Foundation

@Observable
class SettingsManager {
    static let shared = SettingsManager()

    var showNotch: Bool {
        didSet { UserDefaults.standard.set(showNotch, forKey: "replaceNotch") }
    }

    var soundsEnabled: Bool {
        didSet { UserDefaults.standard.set(soundsEnabled, forKey: "soundsEnabled") }
    }

    /// Default repo path for new projects
    var defaultRepoPath: String {
        didSet { UserDefaults.standard.set(defaultRepoPath, forKey: "defaultRepoPath") }
    }

    /// Addons paths for Odoo module detection
    var addonsPaths: [String] {
        didSet {
            if let data = try? JSONEncoder().encode(addonsPaths) {
                UserDefaults.standard.set(data, forKey: "addonsPaths")
            }
        }
    }

    init() {
        let defaults = UserDefaults.standard
        if defaults.object(forKey: "replaceNotch") == nil { defaults.set(true, forKey: "replaceNotch") }
        if defaults.object(forKey: "soundsEnabled") == nil { defaults.set(true, forKey: "soundsEnabled") }

        showNotch = defaults.bool(forKey: "replaceNotch")
        soundsEnabled = defaults.bool(forKey: "soundsEnabled")

        // Default repo path — falls back to ~/Projects
        defaultRepoPath = defaults.string(forKey: "defaultRepoPath")
            ?? NSHomeDirectory() + "/Projects"

        // Addons paths — falls back to empty (user configures in settings)
        if let data = defaults.data(forKey: "addonsPaths"),
           let paths = try? JSONDecoder().decode([String].self, from: data) {
            addonsPaths = paths
        } else {
            addonsPaths = []
        }
    }
}

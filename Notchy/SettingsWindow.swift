import SwiftUI
import AppKit

enum SettingsTab: String, CaseIterable {
    case about = "About"
    case general = "General"
    case paths = "Paths"

    var icon: String {
        switch self {
        case .general: return "gearshape"
        case .paths: return "folder"
        case .about: return "info.circle"
        }
    }
}

struct SettingsContentView: View {
    @State private var selectedTab: SettingsTab = .about
    var onShowNotchChanged: ((Bool) -> Void)?

    var body: some View {
        TabView(selection: $selectedTab) {
            AboutTab()
                .tabItem { Label(SettingsTab.about.rawValue, systemImage: SettingsTab.about.icon) }
                .tag(SettingsTab.about)

            GeneralTab(onShowNotchChanged: onShowNotchChanged)
                .tabItem { Label(SettingsTab.general.rawValue, systemImage: SettingsTab.general.icon) }
                .tag(SettingsTab.general)

            PathsTab()
                .tabItem { Label(SettingsTab.paths.rawValue, systemImage: SettingsTab.paths.icon) }
                .tag(SettingsTab.paths)
        }
        .frame(width: 500, height: 320)
    }
}

struct GeneralTab: View {
    @Bindable private var settings = SettingsManager.shared
    var onShowNotchChanged: ((Bool) -> Void)?

    var body: some View {
        Form {
            Toggle("Show notch overlay", isOn: $settings.showNotch)
                .onChange(of: settings.showNotch) { _, newValue in
                    onShowNotchChanged?(newValue)
                }
            Toggle("Enable sounds", isOn: $settings.soundsEnabled)
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

struct PathsTab: View {
    @Bindable private var settings = SettingsManager.shared
    @State private var newPath = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Default repo path
            VStack(alignment: .leading, spacing: 4) {
                Text("Default Repo Path")
                    .font(.caption.bold())
                Text("Where \"New Project\" creates branches and modules")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                HStack {
                    TextField("Path", text: $settings.defaultRepoPath)
                        .textFieldStyle(.roundedBorder)
                    Button("Browse") {
                        let panel = NSOpenPanel()
                        panel.canChooseFiles = false
                        panel.canChooseDirectories = true
                        if panel.runModal() == .OK, let url = panel.url {
                            settings.defaultRepoPath = url.path
                        }
                    }
                }
            }

            Divider()

            // Addons paths
            VStack(alignment: .leading, spacing: 4) {
                Text("Addons Paths")
                    .font(.caption.bold())
                Text("Directories scanned for Odoo modules")
                    .font(.caption2)
                    .foregroundStyle(.secondary)

                ForEach(settings.addonsPaths, id: \.self) { path in
                    HStack {
                        Text(path)
                            .font(.system(size: 11, design: .monospaced))
                            .lineLimit(1)
                        Spacer()
                        Button(action: {
                            settings.addonsPaths.removeAll { $0 == path }
                        }) {
                            Image(systemName: "minus.circle")
                                .foregroundColor(.red)
                        }
                        .buttonStyle(.plain)
                    }
                }

                HStack {
                    Button("Add Path...") {
                        let panel = NSOpenPanel()
                        panel.canChooseFiles = false
                        panel.canChooseDirectories = true
                        if panel.runModal() == .OK, let url = panel.url {
                            if !settings.addonsPaths.contains(url.path) {
                                settings.addonsPaths.append(url.path)
                            }
                        }
                    }
                }
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

struct AboutTab: View {
    var body: some View {
        VStack(spacing: 12) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 64, height: 64)

            Text("Notchy")
                .font(.title2.bold())

            Text("by Adam Lyttle")
                .font(.body)
                .foregroundStyle(.secondary)

            Button("github.com/adamlyttleapps") {
                if let url = URL(string: "https://github.com/adamlyttleapps") {
                    NSWorkspace.shared.open(url)
                }
            }
            .buttonStyle(.link)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

class SettingsWindowController {
    static let shared = SettingsWindowController()
    private var window: NSWindow?

    func show(onShowNotchChanged: @escaping (Bool) -> Void) {
        if let existing = window {
            existing.level = .floating
            existing.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let content = SettingsContentView(onShowNotchChanged: onShowNotchChanged)
        let hostingView = NSHostingView(rootView: content)

        let win = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 500, height: 320),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        win.title = "Notchy Settings"
        win.contentView = hostingView
        win.center()
        win.isReleasedWhenClosed = false
        win.level = .floating
        win.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        window = win
    }
}

import Foundation

struct DetectedModule {
    let name: String
    let path: String      // full path to the module directory
    let repoPath: String  // git repo root containing this module
}

enum OdooModuleDetector {
    /// Odoo addons directories to scan — reads from settings
    private static var addonsPaths: [String] {
        SettingsManager.shared.addonsPaths
    }

    /// Detect all Odoo modules (directories containing __manifest__.py) in known addons paths.
    /// Groups by git repo root so workspaces point to the repo, not individual modules.
    static func detectModules() -> [DetectedModule] {
        var modules: [DetectedModule] = []
        let fm = FileManager.default

        for addonsPath in addonsPaths {
            guard let entries = try? fm.contentsOfDirectory(atPath: addonsPath) else { continue }
            let repoPath = gitRoot(for: addonsPath) ?? addonsPath

            for entry in entries.sorted() {
                let modulePath = (addonsPath as NSString).appendingPathComponent(entry)
                let manifestPath = (modulePath as NSString).appendingPathComponent("__manifest__.py")
                var isDir: ObjCBool = false
                guard fm.fileExists(atPath: modulePath, isDirectory: &isDir), isDir.boolValue else { continue }
                guard fm.fileExists(atPath: manifestPath) else { continue }
                // Skip hidden dirs and common non-module dirs
                guard !entry.hasPrefix("."), entry != "__pycache__" else { continue }

                modules.append(DetectedModule(
                    name: entry,
                    path: modulePath,
                    repoPath: repoPath
                ))
            }
        }

        return modules
    }

    /// Find the git repository root for a given path
    private static func gitRoot(for path: String) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["-C", path, "rev-parse", "--show-toplevel"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else { return nil }
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            return String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
        } catch {
            return nil
        }
    }
}

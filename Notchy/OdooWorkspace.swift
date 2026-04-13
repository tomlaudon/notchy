import SwiftUI

struct OdooWorkspace: Identifiable, Codable, Equatable {
    let id: UUID
    var name: String
    var repoPath: String
    var port: Int
    var colorName: String  // system color name for visual coding

    init(name: String, repoPath: String, port: Int = 8069, colorName: String = "blue") {
        self.id = UUID()
        self.name = name
        self.repoPath = repoPath
        self.port = port
        self.colorName = colorName
    }

    var color: Color {
        switch colorName {
        case "red": return .red
        case "orange": return .orange
        case "yellow": return .yellow
        case "green": return .green
        case "blue": return .blue
        case "purple": return .purple
        case "pink": return .pink
        case "teal": return .teal
        default: return .blue
        }
    }

    var nsColor: NSColor {
        switch colorName {
        case "red": return .systemRed
        case "orange": return .systemOrange
        case "yellow": return .systemYellow
        case "green": return .systemGreen
        case "blue": return .systemBlue
        case "purple": return .systemPurple
        case "pink": return .systemPink
        case "teal": return .systemTeal
        default: return .systemBlue
        }
    }

    /// Optional git branch to expect for this workspace (safety check)
    var expectedBranch: String?

    /// Slug used for worktree directory and context file names
    private var nameSlug: String {
        name.lowercased().replacingOccurrences(of: " ", with: "_")
    }

    /// Path to the git worktree for this workspace (if it has an expectedBranch)
    var worktreePath: String? {
        guard let branch = expectedBranch, !branch.isEmpty else { return nil }
        return NSHomeDirectory() + "/.notchy/worktrees/\(nameSlug)"
    }

    /// The effective working directory — worktree if available, otherwise repoPath
    var effectivePath: String {
        if let wt = worktreePath, FileManager.default.fileExists(atPath: wt + "/.git") {
            return wt
        }
        return repoPath
    }

    /// Path to project context file that Claude reads on startup
    var contextFilePath: String {
        return (effectivePath as NSString).appendingPathComponent(".notchy/\(nameSlug).md")
    }

    /// Ensure the context file exists, creating it with a template if needed
    func ensureContextFile() {
        let fm = FileManager.default
        let dirPath = (repoPath as NSString).appendingPathComponent(".notchy")
        if !fm.fileExists(atPath: dirPath) {
            try? fm.createDirectory(atPath: dirPath, withIntermediateDirectories: true)
        }
        if !fm.fileExists(atPath: contextFilePath) {
            let template = """
            # \(name) — Project Context

            ## Overview
            <!-- What is this project? What problem does it solve? -->

            ## Key Files
            <!-- List the main files/modules this project touches -->

            ## Architecture
            <!-- How is the code structured? Key design decisions? -->

            ## Current Status
            <!-- What's done? What's in progress? What's next? -->

            ## Gotchas & Lessons
            <!-- Things to watch out for, past mistakes, edge cases -->

            ## Port: \(port)
            ## Branch: \(expectedBranch ?? "")
            ## Repo: \(repoPath)
            """
            try? template.write(toFile: contextFilePath, atomically: true, encoding: .utf8)
        }
    }

    static let availableColors = ["blue", "green", "orange", "red", "purple", "pink", "teal", "yellow"]

    static func colorFromName(_ name: String) -> Color {
        switch name {
        case "red": return .red
        case "orange": return .orange
        case "yellow": return .yellow
        case "green": return .green
        case "blue": return .blue
        case "purple": return .purple
        case "pink": return .pink
        case "teal": return .teal
        default: return .blue
        }
    }

    /// Create a git worktree for this workspace if it has an expectedBranch and the worktree doesn't exist yet.
    /// Must be called from a background thread (runs git commands synchronously).
    /// Returns the worktree path on success, nil if not applicable or failed.
    @discardableResult
    func ensureWorktree() -> String? {
        guard let wtPath = worktreePath, let branch = expectedBranch, !branch.isEmpty else { return nil }
        let fm = FileManager.default

        // Already exists — just make sure we're on the right branch
        if fm.fileExists(atPath: wtPath + "/.git") {
            return wtPath
        }

        // Create parent directory
        let parentDir = (wtPath as NSString).deletingLastPathComponent
        if !fm.fileExists(atPath: parentDir) {
            try? fm.createDirectory(atPath: parentDir, withIntermediateDirectories: true)
        }

        // Create worktree checked out to the expected branch
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["-C", repoPath, "worktree", "add", wtPath, branch]
        let errPipe = Pipe()
        process.standardOutput = FileHandle.nullDevice
        process.standardError = errPipe
        do {
            try process.run()
            process.waitUntilExit()
            if process.terminationStatus == 0 {
                return wtPath
            }
            // Log error for debugging
            let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
            let errMsg = String(data: errData, encoding: .utf8) ?? ""
            NSLog("Notchy: git worktree add failed: \(errMsg)")
            return nil
        } catch {
            NSLog("Notchy: git worktree add exception: \(error)")
            return nil
        }
    }

    /// Read the current git branch for this workspace (checks worktree if available)
    func currentGitBranch() -> String? {
        let dir = effectivePath
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["-C", dir, "branch", "--show-current"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            return String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
        } catch {
            return nil
        }
    }
}

@Observable
class WorkspaceStore {
    static let shared = WorkspaceStore()

    var workspaces: [OdooWorkspace] = []
    var activeWorkspaceId: UUID?

    private static let workspacesKey = "odooWorkspaces"
    private static let activeWorkspaceKey = "activeWorkspaceId"

    var activeWorkspace: OdooWorkspace? {
        workspaces.first { $0.id == activeWorkspaceId }
    }

    init() {
        restore()
    }

    private func restore() {
        guard let data = UserDefaults.standard.data(forKey: Self.workspacesKey),
              let decoded = try? JSONDecoder().decode([OdooWorkspace].self, from: data) else { return }
        workspaces = decoded
        if let savedId = UserDefaults.standard.string(forKey: Self.activeWorkspaceKey),
           let uuid = UUID(uuidString: savedId),
           workspaces.contains(where: { $0.id == uuid }) {
            activeWorkspaceId = uuid
        } else {
            activeWorkspaceId = workspaces.first?.id
        }
    }

    func persist() {
        if let data = try? JSONEncoder().encode(workspaces) {
            UserDefaults.standard.set(data, forKey: Self.workspacesKey)
        }
        if let activeId = activeWorkspaceId {
            UserDefaults.standard.set(activeId.uuidString, forKey: Self.activeWorkspaceKey)
        } else {
            UserDefaults.standard.removeObject(forKey: Self.activeWorkspaceKey)
        }
    }

    func addWorkspace(_ workspace: OdooWorkspace) {
        workspaces.append(workspace)
        if activeWorkspaceId == nil {
            activeWorkspaceId = workspace.id
        }
        persist()
    }

    func removeWorkspace(_ id: UUID) {
        workspaces.removeAll { $0.id == id }
        if activeWorkspaceId == id {
            activeWorkspaceId = workspaces.first?.id
        }
        persist()
    }

    func selectWorkspace(_ id: UUID) {
        activeWorkspaceId = id
        persist()
    }

    func updateWorkspace(_ id: UUID, name: String? = nil, repoPath: String? = nil, port: Int? = nil, colorName: String? = nil, expectedBranch: String?? = nil) {
        guard let index = workspaces.firstIndex(where: { $0.id == id }) else { return }
        if let name { workspaces[index].name = name }
        if let repoPath { workspaces[index].repoPath = repoPath }
        if let port { workspaces[index].port = port }
        if let colorName { workspaces[index].colorName = colorName }
        if let expectedBranch { workspaces[index].expectedBranch = expectedBranch }
        persist()
    }
}

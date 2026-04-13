import AppKit
import SwiftTerm

class ClickThroughTerminalView: LocalProcessTerminalView {
    var sessionId: UUID?
    private var keyMonitor: Any?
    private var statusDebounceWork: DispatchWorkItem?
    private static let statusQueue = DispatchQueue(label: "com.notchy.status", qos: .utility)

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override init(frame: NSRect) {
        super.init(frame: frame)
        registerForDraggedTypes([.fileURL])
        installArrowKeyMonitor()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        registerForDraggedTypes([.fileURL])
        installArrowKeyMonitor()
    }

    deinit {
        if let monitor = keyMonitor {
            NSEvent.removeMonitor(monitor)
        }
    }

    /// Intercept arrow key events locally and send standard VT100/xterm sequences
    /// to avoid kitty keyboard protocol (CSI u) encoding issues.
    private func installArrowKeyMonitor() {
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self = self, self.window?.firstResponder === self else { return event }

            let arrowCode: String?
            switch event.keyCode {
            case 126: arrowCode = "A" // Up
            case 125: arrowCode = "B" // Down
            case 124: arrowCode = "C" // Right
            case 123: arrowCode = "D" // Left
            default: arrowCode = nil
            }

            guard let code = arrowCode else { return event }

            let mods = event.modifierFlags.intersection([.shift, .option, .control])
            if mods.isEmpty {
                self.send(txt: "\u{1b}[\(code)")
            } else {
                var modifier = 1
                if mods.contains(.shift) { modifier += 1 }
                if mods.contains(.option) { modifier += 2 }
                if mods.contains(.control) { modifier += 4 }
                self.send(txt: "\u{1b}[1;\(modifier)\(code)")
            }
            return nil // consume the event
        }
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        return .copy
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard let items = sender.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] else {
            return false
        }
        let paths = items.map { "'" + $0.path.replacingOccurrences(of: "'", with: "'\\''") + "'" }.joined(separator: " ")
        send(txt: paths)
        return true
    }

    /// Returns all visible lines from the terminal buffer.
    private func extractAllLines() -> [String]? {
        let terminal = getTerminal()
        guard terminal.rows >= 20 else { return nil }
        var lineTexts: [String] = []
        for row in 0..<terminal.rows {
            var line = ""
            for col in 0..<terminal.cols {
                let ch = terminal.getCharacter(col: col, row: row) ?? " "
                line.append(ch == "\u{0}" ? " " : ch)
            }
            lineTexts.append(line)
        }
        return lineTexts
    }

    /// Returns the last 20 non-blank lines from the given lines, joined by newlines.
    private func relevantText(from lines: [String]) -> String {
        let nonBlankLines = lines.filter { !$0.allSatisfy({ $0 == " " }) }
        return nonBlankLines.suffix(20).joined(separator: "\n")
    }

    /// Returns the last 20 non-blank lines of terminal output above the prompt separator.
    func extractVisibleText() -> String? {
        guard var lineTexts = extractAllLines() else { return nil }

        // Find the last horizontal rule separator (────...) which divides
        // Claude's output from the user's current prompt input area.
        // Only consider text above it so we don't capture the in-progress prompt.
        let separator = "────────"
        if let lastSeparatorIndex = lineTexts.lastIndex(where: { $0.contains(separator) }) {
            lineTexts = Array(lineTexts.prefix(lastSeparatorIndex))
        }

        return relevantText(from: lineTexts)
    }

    /// Returns the last 20 non-blank lines of the full terminal output (including prompt area).
    func extractFullVisibleText() -> String? {
        guard let lineTexts = extractAllLines() else { return nil }
        return relevantText(from: lineTexts)
    }

    override func dataReceived(slice: ArraySlice<UInt8>) {
        super.dataReceived(slice: slice)

        guard let id = sessionId else { return }

        // Debounce status checks on a background queue to avoid
        // blocking the main thread with per-cell buffer reads.
        statusDebounceWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.evaluateStatus(for: id)
        }
        statusDebounceWork = work
        Self.statusQueue.asyncAfter(deadline: .now() + 0.15, execute: work)
    }

    private func evaluateStatus(for id: UUID) {
        guard let session = SessionStore.shared.sessions.first(where: { $0.id == id }) else { return }

        let isWaiting = isAtPermissionPrompt()

        DispatchQueue.main.async {
            guard let current = SessionStore.shared.sessions.first(where: { $0.id == id }) else { return }
            if isWaiting {
                if current.terminalStatus != .waitingForInput {
                    SessionStore.shared.updateTerminalStatus(id, status: .waitingForInput)
                }
            } else if current.terminalStatus == .waitingForInput {
                // Prompt cleared — return to idle
                SessionStore.shared.updateTerminalStatus(id, status: .idle)
            }
        }

        if isWaiting && session.autoAcceptEnabled {
            DispatchQueue.main.async { [weak self] in
                self?.send(txt: "y")
            }
        }
    }

    /// Detects Claude Code permission/confirmation prompts.
    /// Catches: tool permission prompts, bash command confirmations,
    /// --dangerously-skip-permissions confirmation, and trust prompts.
    private func isAtPermissionPrompt() -> Bool {
        guard let fullText = extractFullVisibleText() else { return false }

        return
            // Standard permission prompt: "Allow" + accept option
            ((fullText.contains("Allow") || fullText.contains("allow"))
                && (fullText.contains("Yes") || fullText.contains("(y)") || fullText.contains("to allow")))
            // Bash command confirmation
            || fullText.contains("Do you want to proceed?")
            // --dangerously-skip-permissions confirmation
            || fullText.contains("I understand the risks")
            // Trust/workspace prompt
            || fullText.contains("Do you trust")
            || fullText.contains("Trust this project")
    }
}

class TerminalManager: NSObject, LocalProcessTerminalViewDelegate {
    static let shared = TerminalManager()

    private var terminals: [UUID: LocalProcessTerminalView] = [:]

    func terminal(for sessionId: UUID, workingDirectory: String, workspaceId: UUID? = nil, autoAccept: Bool = false) -> LocalProcessTerminalView {
        if let existing = terminals[sessionId] {
            return existing
        }

        // Resolve the effective working directory — use worktree if workspace has one
        var effectiveDir = workingDirectory
        if let wsId = workspaceId,
           let ws = WorkspaceStore.shared.workspaces.first(where: { $0.id == wsId }),
           let wtPath = ws.worktreePath {
            // Ensure worktree exists (synchronous — fast if already created)
            if let created = ws.ensureWorktree() {
                effectiveDir = created
            }
        }

        let terminal = ClickThroughTerminalView(frame: NSRect(x: 0, y: 0, width: 720, height: 460))
        terminal.sessionId = sessionId
        terminal.processDelegate = self

        // Match macOS Terminal default font size
        terminal.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        terminal.nativeBackgroundColor = NSColor(white: 0.1, alpha: 1.0)
        terminal.nativeForegroundColor = NSColor(white: 0.9, alpha: 1.0)

        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        let environment = buildEnvironment()

        terminal.startProcess(
            executable: shell,
            args: ["--login"],
            environment: environment,
            execName: "-" + (shell as NSString).lastPathComponent
        )

        let escapedDir = shellEscape(effectiveDir)
        let claudeCmd = autoAccept ? "claude --dangerously-skip-permissions" : "claude"
        terminal.send(txt: "cd \(escapedDir) && clear && \(claudeCmd)\r")

        // Auto-accept the trust prompt after claude starts
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
            terminal.send(txt: "\r")
        }

        // Load project context file into Claude as the first prompt
        if let wsId = workspaceId,
           let ws = WorkspaceStore.shared.workspaces.first(where: { $0.id == wsId }) {
            ws.ensureContextFile()
            let contextPath = ws.contextFilePath
            // Wait for claude to fully start (trust prompt + loading), then send context
            DispatchQueue.main.asyncAfter(deadline: .now() + 8.0) {
                let prompt = "Read \(contextPath) for project context. This is your primary reference for this project — keep it updated with decisions, architecture changes, and status as we work. You have full access to all files, databases, and other project context files on this machine.\r"
                terminal.send(txt: prompt)
            }
        }

        terminals[sessionId] = terminal
        return terminal
    }

    // MARK: - LocalProcessTerminalViewDelegate

    func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {}

    func setTerminalTitle(source: LocalProcessTerminalView, title: String) {}

    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {
        guard let dir = directory,
              let terminal = source as? ClickThroughTerminalView,
              let sessionId = terminal.sessionId else { return }
        // SwiftTerm may report file:// URLs — convert to plain path
        let cleanDir: String
        if dir.hasPrefix("file://"), let url = URL(string: dir) {
            cleanDir = url.path
        } else {
            cleanDir = dir
        }
        DispatchQueue.main.async {
            SessionStore.shared.updateWorkingDirectory(sessionId, directory: cleanDir)
        }
    }

    func processTerminated(source: TerminalView, exitCode: Int32?) {}

    /// Returns the visible text from a terminal's buffer
    func visibleText(for sessionId: UUID) -> String? {
        guard let terminal = terminals[sessionId] as? ClickThroughTerminalView else { return nil }
        return terminal.extractVisibleText()
    }

    func destroyTerminal(for sessionId: UUID) {
        terminals.removeValue(forKey: sessionId)
    }

    /// Send a message to the running Claude session
    func sendToTerminal(_ sessionId: UUID, text: String) {
        guard let terminal = terminals[sessionId] else { return }
        terminal.send(txt: text)
    }

    /// Ask Claude to update the context file, then destroy the terminal after a delay
    func saveContextAndDestroy(sessionId: UUID, delay: TimeInterval = 12.0) {
        guard terminals[sessionId] != nil else { return }
        let prompt = "Update your project context file with any new decisions, status changes, or lessons from this session. Be concise. Then run /exit.\r"
        sendToTerminal(sessionId, text: prompt)
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            self?.destroyTerminal(for: sessionId)
        }
    }

    private func buildEnvironment() -> [String] {
        var env = ProcessInfo.processInfo.environment
        env["TERM"] = "xterm-256color"
        env["LANG"] = env["LANG"] ?? "en_US.UTF-8"
        // Prepend Notchy git wrapper to PATH so write operations are serialized across tabs
        let notchyBin = NSHomeDirectory() + "/.notchy/bin"
        if let path = env["PATH"] {
            env["PATH"] = notchyBin + ":" + path
        } else {
            env["PATH"] = notchyBin + ":/usr/bin:/bin"
        }
        return env.map { "\($0.key)=\($0.value)" }
    }

    /// Check if a directory has uncommitted git changes (staged or unstaged, tracked files only).
    /// Untracked files are ignored — stray build artifacts / .DS_Store shouldn't trigger the close warning.
    func hasUncommittedChanges(in directory: String) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["-C", directory, "status", "--porcelain", "--untracked-files=no"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let output = String(data: data, encoding: .utf8) ?? ""
            return !output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        } catch {
            return false
        }
    }

    private func shellEscape(_ path: String) -> String {
        "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}

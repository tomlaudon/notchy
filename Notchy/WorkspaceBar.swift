import SwiftUI

struct WorkspaceBar: View {
    @Bindable var workspaceStore: WorkspaceStore
    @Bindable var sessionStore: SessionStore
    var foregroundOpacity: Double

    @State private var showAddSheet = false
    @State private var showEditSheet = false
    @State private var editingWorkspace: OdooWorkspace?

    private var activeLabel: String {
        workspaceStore.activeWorkspace?.name ?? "Select a Project..."
    }

    private var activeColor: Color {
        workspaceStore.activeWorkspace?.color ?? .gray
    }

    /// Mini status dots for each session — visible when panel is collapsed
    private var sessionStatusDots: some View {
        HStack(spacing: 4) {
            ForEach(sessionStore.visibleSessions) { session in
                Group {
                    switch session.terminalStatus {
                    case .working:
                        TabSpinnerView()
                            .frame(width: 6, height: 6)
                    case .waitingForInput:
                        Circle()
                            .fill(Color.red)
                            .frame(width: 6, height: 6)
                    case .taskCompleted:
                        Circle()
                            .fill(Color.green)
                            .frame(width: 6, height: 6)
                    case .idle, .interrupted:
                        Circle()
                            .fill(Color.gray.opacity(0.3))
                            .frame(width: 6, height: 6)
                    }
                }
                .overlay(
                    RoundedRectangle(cornerRadius: 3)
                        .stroke(session.id == sessionStore.activeSessionId ? Color.white.opacity(0.5) : Color.clear, lineWidth: 1)
                )
            }
        }
    }

    var body: some View {
        Menu {
            // Existing workspaces — just click to switch
            ForEach(workspaceStore.workspaces) { ws in
                Button(action: { sessionStore.switchWorkspace(ws.id) }) {
                    HStack {
                        if ws.id == workspaceStore.activeWorkspaceId {
                            Image(systemName: "checkmark")
                        }
                        Text(ws.name)
                    }
                }
            }

            if !workspaceStore.workspaces.isEmpty {
                Divider()
            }

            Button(action: { showAddSheet = true }) {
                Label("New Project...", systemImage: "plus.circle.fill")
            }

            if let ws = workspaceStore.activeWorkspace {
                Divider()
                Button("Edit \"\(ws.name)\"...") {
                    editingWorkspace = ws
                    showEditSheet = true
                }
                Button("Remove \"\(ws.name)\"", role: .destructive) {
                    WorkspaceStore.shared.removeWorkspace(ws.id)
                }
            }
        } label: {
            HStack(spacing: 6) {
                HStack(spacing: 5) {
                    Circle()
                        .fill(activeColor)
                        .frame(width: 7, height: 7)
                    Text(activeLabel)
                        .font(.system(size: 11, weight: .semibold))
                        .lineLimit(1)
                    Image(systemName: "chevron.down")
                        .font(.system(size: 8, weight: .bold))
                }

                sessionStatusDots

                Spacer()

                // Port + branch badge for active workspace
                if let ws = workspaceStore.activeWorkspace {
                    WorkspaceInfoBadge(workspace: ws)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .foregroundColor(activeColor)
        .background(workspaceAccentBackground)
        .sheet(isPresented: $showAddSheet) {
            WorkspaceEditorSheet(mode: .add)
        }
        .sheet(isPresented: $showEditSheet) {
            if let ws = editingWorkspace {
                WorkspaceEditorSheet(mode: .edit(ws))
            }
        }
    }

    private var workspaceAccentBackground: some View {
        let ws = workspaceStore.activeWorkspace
        return ZStack {
            Color(nsColor: NSColor(white: 0.12, alpha: 1.0))
            if let ws {
                ws.color.opacity(0.06)
            }
        }
    }

    private func nextColor() -> String {
        let used = Set(workspaceStore.workspaces.map(\.colorName))
        return OdooWorkspace.availableColors.first { !used.contains($0) } ?? "blue"
    }

    private func nextPort() -> Int {
        let usedPorts = Set(workspaceStore.workspaces.map(\.port))
        var port = 8069
        while usedPorts.contains(port) {
            port += 1
        }
        return port
    }

}

// MARK: - Workspace Info Badge

struct WorkspaceInfoBadge: View {
    let workspace: OdooWorkspace
    @State private var currentBranch: String?
    @State private var timer: Timer?

    private var branchMismatch: Bool {
        guard let expected = workspace.expectedBranch, !expected.isEmpty,
              let current = currentBranch, !current.isEmpty else { return false }
        return current != expected
    }

    var body: some View {
        HStack(spacing: 8) {
            // Port
            HStack(spacing: 3) {
                Circle()
                    .fill(Color.green)
                    .frame(width: 5, height: 5)
                Text(":\(workspace.port)")
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(workspace.color.opacity(0.15))
            .clipShape(RoundedRectangle(cornerRadius: 4))
            .foregroundColor(workspace.color)

            // Branch
            if let branch = currentBranch, !branch.isEmpty {
                HStack(spacing: 3) {
                    Image(systemName: "arrow.triangle.branch")
                        .font(.system(size: 8, weight: .semibold))
                    Text(branch)
                        .font(.system(size: 10, weight: .medium, design: .monospaced))
                    if branchMismatch {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.system(size: 8))
                            .foregroundColor(.yellow)
                    }
                }
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
                .background(branchMismatch ? Color.yellow.opacity(0.15) : workspace.color.opacity(0.1))
                .clipShape(RoundedRectangle(cornerRadius: 4))
                .foregroundColor(branchMismatch ? .yellow : workspace.color.opacity(0.8))
                .help(branchMismatch ? "Expected branch: \(workspace.expectedBranch ?? "")" : "Current git branch")
            }
        }
        .onAppear { refreshBranch(); startTimer() }
        .onDisappear { timer?.invalidate() }
    }

    private func refreshBranch() {
        DispatchQueue.global(qos: .utility).async {
            let branch = workspace.currentGitBranch()
            DispatchQueue.main.async { currentBranch = branch }
        }
    }

    private func startTimer() {
        timer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { _ in
            refreshBranch()
        }
    }
}

// MARK: - New Project Sheet (name only — everything else is automatic)

struct WorkspaceEditorSheet: View {
    let mode: WorkspaceEditorMode
    @Environment(\.dismiss) private var dismiss

    @State private var name = ""
    @State private var status = ""
    @State private var isCreating = false

    private var isEditing: Bool {
        if case .edit = mode { return true }
        return false
    }

    var body: some View {
        VStack(spacing: 16) {
            if case .edit(let ws) = mode {
                editView(ws)
            } else {
                newProjectView
            }
        }
        .padding(20)
        .frame(width: 380)
    }

    // MARK: - New Project (name only)

    private var newProjectView: some View {
        VStack(spacing: 16) {
            Image(systemName: "folder.badge.plus")
                .font(.system(size: 28))
                .foregroundColor(.accentColor)

            Text("New Odoo Project")
                .font(.headline)

            Text("Just enter a name. A git branch and port will be set up automatically in your natureswarehouse repo.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            TextField("Project name (e.g. analytics_allocation)", text: $name)
                .textFieldStyle(.roundedBorder)
                .onSubmit { if !name.isEmpty && !isCreating { createProject() } }

            if !status.isEmpty {
                Text(status)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Create") { createProject() }
                    .buttonStyle(.borderedProminent)
                    .disabled(name.isEmpty || isCreating)
            }
        }
    }

    private func createProject() {
        isCreating = true
        let projectName = name.trimmingCharacters(in: .whitespaces)
        let repoPath = SettingsManager.shared.defaultRepoPath

        // Auto-assign next available port
        let usedPorts = Set(WorkspaceStore.shared.workspaces.map(\.port))
        var port = 8069
        while usedPorts.contains(port) { port += 1 }

        // Auto-pick next color
        let usedColors = Set(WorkspaceStore.shared.workspaces.map(\.colorName))
        let color = OdooWorkspace.availableColors.first { !usedColors.contains($0) } ?? "blue"

        DispatchQueue.global(qos: .userInitiated).async {
            // Create a git branch for this project (from main)
            let branchName = "feature/\(projectName.lowercased().replacingOccurrences(of: " ", with: "_"))"
            let branchList = runGit(in: repoPath, args: ["branch", "--list", branchName])
            let branchExists = branchList.contains(branchName)

            if !branchExists {
                _ = runGit(in: repoPath, args: ["branch", branchName])
            }

            // Create workspace
            DispatchQueue.main.async {
                var ws = OdooWorkspace(name: projectName, repoPath: repoPath, port: port, colorName: color)
                ws.expectedBranch = branchName
                WorkspaceStore.shared.addWorkspace(ws)
                ws.ensureContextFile()
                SessionStore.shared.switchWorkspace(ws.id)
                status = "Ready — port :\(port), branch \(branchName)"
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    dismiss()
                }
            }
        }
    }

    // MARK: - Edit existing workspace

    @State private var editName = ""
    @State private var editRepoPath = ""
    @State private var editPort = ""
    @State private var editBranch = ""
    @State private var editColor = "blue"

    private func editView(_ ws: OdooWorkspace) -> some View {
        VStack(spacing: 16) {
            Text("Edit Workspace")
                .font(.headline)

            Form {
                TextField("Name:", text: $editName)
                    .textFieldStyle(.roundedBorder)
                HStack {
                    TextField("Repo Path:", text: $editRepoPath)
                        .textFieldStyle(.roundedBorder)
                    Button("Browse...") {
                        let panel = NSOpenPanel()
                        panel.canChooseFiles = false
                        panel.canChooseDirectories = true
                        panel.allowsMultipleSelection = false
                        if panel.runModal() == .OK, let url = panel.url {
                            editRepoPath = url.path
                        }
                    }
                }
                HStack {
                    TextField("Port:", text: $editPort)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 80)
                    TextField("Branch:", text: $editBranch)
                        .textFieldStyle(.roundedBorder)
                }
                HStack(spacing: 8) {
                    Text("Color:")
                    ForEach(OdooWorkspace.availableColors, id: \.self) { c in
                        Circle()
                            .fill(OdooWorkspace.colorFromName(c))
                            .frame(width: 16, height: 16)
                            .overlay(Circle().stroke(Color.white, lineWidth: editColor == c ? 2 : 0))
                            .onTapGesture { editColor = c }
                    }
                }
            }

            HStack {
                Button("Delete", role: .destructive) {
                    WorkspaceStore.shared.removeWorkspace(ws.id)
                    dismiss()
                }
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Save") {
                    WorkspaceStore.shared.updateWorkspace(
                        ws.id,
                        name: editName.isEmpty ? nil : editName,
                        repoPath: editRepoPath.isEmpty ? nil : editRepoPath,
                        port: Int(editPort),
                        colorName: editColor,
                        expectedBranch: editBranch.isEmpty ? nil : editBranch
                    )
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .onAppear {
            editName = ws.name
            editRepoPath = ws.repoPath
            editPort = String(ws.port)
            editBranch = ws.expectedBranch ?? ""
            editColor = ws.colorName
        }
    }
}

enum WorkspaceEditorMode {
    case add
    case edit(OdooWorkspace)
}

private func runGit(in dir: String, args: [String]) -> String {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
    process.arguments = ["-C", dir] + args
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = FileHandle.nullDevice
    do {
        try process.run()
        process.waitUntilExit()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        return String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    } catch {
        return ""
    }
}

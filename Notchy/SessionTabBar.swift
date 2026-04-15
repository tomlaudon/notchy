import SwiftUI

struct SessionTabBar: View {
    @Bindable var sessionStore: SessionStore

    var body: some View {
        HStack(spacing: 2) {
            ForEach(sessionStore.visibleSessions) { session in
                SessionTab(
                    session: session,
                    isActive: session.id == sessionStore.activeSessionId,
                    terminalStatus: session.terminalStatus,
                    foregroundOpacity: sessionStore.isWindowFocused ? 1.0 : 0.6,
                    workspaceColor: Self.workspaceColor(for: session),
                    onSelect: { sessionStore.selectSession(session.id) },
                    onClose: { sessionStore.closeSession(session.id) },
                    onRename: { newName in
                        sessionStore.renameSession(session.id, to: newName)
                    }
                )
            }
        }
        .fixedSize(horizontal: true, vertical: false)
    }

    /// Look up the workspace color for a session, falling back to blue
    static func workspaceColor(for session: TerminalSession) -> Color {
        guard let wsId = session.workspaceId,
              let ws = WorkspaceStore.shared.workspaces.first(where: { $0.id == wsId }) else {
            return .blue
        }
        return ws.color
    }
}

struct SessionTab: View {
    let session: TerminalSession
    let isActive: Bool
    var terminalStatus: TerminalStatus = .idle
    var foregroundOpacity: Double = 1.0
    var workspaceColor: Color = .blue
    let onSelect: () -> Void
    let onClose: () -> Void
    let onRename: (String) -> Void

    @State private var isHovering = false
    @State private var showRenameDialog = false
    @State private var renameText = ""
    @State private var latestCheckpoint: Checkpoint?
    @State private var showRestoreConfirmation = false
    @State private var showDirtyCloseWarning = false

    private var name: String { session.projectName }

    /// The tab's primary color — workspace color when idle, status color when noteworthy
    private var tabColor: Color {
        switch terminalStatus {
        case .working: return .yellow
        case .waitingForInput: return .red
        case .taskCompleted: return .green
        case .idle, .interrupted: return workspaceColor
        }
    }

    /// Bottom accent bar color — always visible
    private var statusAccentColor: Color {
        switch terminalStatus {
        case .working: return .yellow
        case .waitingForInput: return .red
        case .taskCompleted: return .green
        case .idle, .interrupted: return isActive ? workspaceColor.opacity(0.6) : workspaceColor.opacity(0.25)
        }
    }

    private var tabBackground: some View {
        let fill: Color = if isActive {
            tabColor.opacity(0.25)
        } else if isHovering {
            Color.white.opacity(0.08)
        } else {
            tabColor.opacity(0.06)
        }
        return RoundedRectangle(cornerRadius: 6).fill(fill)
    }

    private var tabBorder: some View {
        let strokeColor = isActive ? tabColor.opacity(0.5) : statusAccentColor.opacity(0.2)
        let width: CGFloat = isActive ? 1.5 : 1
        return RoundedRectangle(cornerRadius: 6).stroke(strokeColor, lineWidth: width)
    }

    private var tabAccentBar: some View {
        RoundedRectangle(cornerRadius: 1.5)
            .fill(statusAccentColor)
            .frame(height: 3)
            .padding(.horizontal, 2)
    }

    private func updateDialogState() {
        SessionStore.shared.isShowingDialog = showRenameDialog || showRestoreConfirmation || showDirtyCloseWarning
    }

    private func attemptClose() {
        let dir = session.workingDirectory
        DispatchQueue.global(qos: .userInitiated).async {
            let isDirty = TerminalManager.shared.hasUncommittedChanges(in: dir)
            DispatchQueue.main.async {
                if isDirty {
                    showDirtyCloseWarning = true
                } else {
                    onClose()
                }
            }
        }
    }

    private func refreshLatestCheckpoint() {
        guard let dir = session.projectPath else { return }
        let projectDir = (dir as NSString).deletingLastPathComponent
        latestCheckpoint = CheckpointManager.shared.checkpoints(for: session.projectName, in: projectDir).first
    }

    @ViewBuilder
    private var statusIndicator: some View {
        switch terminalStatus {
        case .working:
            TabSpinnerView()
                .frame(width: 10, height: 10)
        case .waitingForInput:
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 11, weight: .bold))
                .foregroundColor(.red)
        case .taskCompleted:
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 10, weight: .bold))
                .foregroundColor(.green)
        case .idle, .interrupted:
            Circle()
                .fill(workspaceColor.opacity(isActive ? 0.7 : 0.4))
                .frame(width: 8, height: 8)
        }
    }

    var body: some View {
        HStack(spacing: 4) {
            statusIndicator

            ZStack {
                // Hidden semibold text prevents tab width change on selection
                Text(name)
                    .font(.system(size: 11, weight: .semibold))
                    .lineLimit(1)
                    .opacity(0)

                Text(name)
                    .font(.system(size: 11, weight: isActive ? .semibold : .regular))
                    .lineLimit(1)
                    .foregroundColor(.white.opacity(foregroundOpacity))
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(tabBackground)
        .overlay(tabBorder)
        .overlay(alignment: .bottom) { tabAccentBar }
        .onHover { hovering in
            isHovering = hovering
            if hovering {
                NSCursor.arrow.push()
            } else {
                NSCursor.pop()
            }
        }
        .onTapGesture(perform: onSelect)
        .overlay(MiddleClickView { attemptClose() })
        .contextMenu {
//            Button("Save Checkpoint") {
//                SessionStore.shared.createCheckpointForActiveSession()
//            }
//            .disabled(session.projectPath == nil)
//
//            if latestCheckpoint != nil {
//                Button("Restore Last Checkpoint") {
//                    showRestoreConfirmation = true
//                }
//            }
//
//            Divider()
        
//            Button("Refresh") {
//                SessionStore.shared.restartSession(session.id)
//            }

            Button("Rename Tab") {
                renameText = name
                showRenameDialog = true
            }

            Button("Close", role: .destructive) {
                attemptClose()
            }
        }
        .onAppear {
            refreshLatestCheckpoint()
        }
        .onChange(of: isHovering) {
            if isHovering {
                refreshLatestCheckpoint()
            }
        }
        .alert("Restore Last Checkpoint", isPresented: $showRestoreConfirmation) {
            Button("Restore", role: .destructive) {
                if let checkpoint = latestCheckpoint {
                    guard let dir = session.projectPath else { return }
                    let projectDir = (dir as NSString).deletingLastPathComponent
                    try? CheckpointManager.shared.restoreCheckpoint(checkpoint, to: projectDir)
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This will overwrite your current working directory with the checkpoint. Are you sure?")
        }
        .alert("Rename Tab", isPresented: $showRenameDialog) {
            TextField("Tab name", text: $renameText)
            Button("Rename") {
                if !renameText.isEmpty {
                    onRename(renameText)
                }
            }
            Button("Cancel", role: .cancel) {}
        }
        .alert("Uncommitted Changes", isPresented: $showDirtyCloseWarning) {
            Button("Close Anyway", role: .destructive) {
                onClose()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This tab has uncommitted changes that will be lost if you close it.")
        }
        .onChange(of: showRenameDialog) { updateDialogState() }
        .onChange(of: showRestoreConfirmation) { updateDialogState() }
        .onChange(of: showDirtyCloseWarning) { updateDialogState() }
    }
}

private struct MiddleClickView: NSViewRepresentable {
    let action: () -> Void

    func makeNSView(context: Context) -> MiddleClickNSView {
        let view = MiddleClickNSView()
        view.action = action
        return view
    }

    func updateNSView(_ nsView: MiddleClickNSView, context: Context) {
        nsView.action = action
    }
}

private class MiddleClickNSView: NSView {
    var action: (() -> Void)?

    override func hitTest(_ point: NSPoint) -> NSView? {
        // Only claim hits during middle-click so left clicks pass through to SwiftUI
        guard let event = NSApp.currentEvent, event.type == .otherMouseDown || event.type == .otherMouseUp else {
            return nil
        }
        return super.hitTest(point)
    }

    override func otherMouseUp(with event: NSEvent) {
        if event.buttonNumber == 2 {
            action?()
        } else {
            super.otherMouseUp(with: event)
        }
    }
}

struct TabSpinnerView: View {
    @State private var isAnimating = false

    var body: some View {
        Circle()
            .trim(from: 0.05, to: 0.8)
            .stroke(Color.white, style: StrokeStyle(lineWidth: 1.5, lineCap: .round))
            .rotationEffect(.degrees(isAnimating ? 360 : 0))
            .animation(.linear(duration: 0.8).repeatForever(autoreverses: false), value: isAnimating)
            .onAppear { isAnimating = true }
    }
}


import AppKit
import SwiftUI

/// Which modal flow is open. One enum keeps the presentation logic in `RootView`
/// to a single `.sheet`.
enum ForgeSheet: Identifiable {
    case newWorkspace
    case addRepos
    case newStack
    case launchAgent(NodeID?)

    var id: String {
        switch self {
        case .newWorkspace: return "newWorkspace"
        case .addRepos: return "addRepos"
        case .newStack: return "newStack"
        case .launchAgent(let node): return "launchAgent:" + (node?.storageKey ?? "-")
        }
    }
}

// MARK: - Shared chrome

struct SheetFrame<Content: View, Footer: View>: View {
    var title: String
    var subtitle: String?
    @ViewBuilder var content: Content
    @ViewBuilder var footer: Footer

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(Theme.ui(15, .bold))
                    .foregroundStyle(Theme.textPrimary)
                if let subtitle {
                    Text(subtitle)
                        .font(Theme.ui(11.5))
                        .foregroundStyle(Theme.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(16)

            Divider().overlay(Theme.hairline)

            ScrollView { content.padding(16) }
                .frame(maxHeight: 460)

            Divider().overlay(Theme.hairline)

            HStack(spacing: 8) { footer }
                .padding(14)
        }
        .frame(width: 540)
        .background(Theme.surfaceSunken)
        .preferredColorScheme(.dark)
    }
}

struct FormField<Content: View>: View {
    var label: String
    var hint: String?
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(label.uppercased())
                .font(Theme.ui(9.5, .heavy))
                .tracking(0.7)
                .foregroundStyle(Theme.textTertiary)
            content
            if let hint {
                Text(hint)
                    .font(Theme.ui(10.5))
                    .foregroundStyle(Theme.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

struct BoxedField: ViewModifier {
    func body(content: Content) -> some View {
        content
            .textFieldStyle(.plain)
            .font(Theme.ui(12))
            .foregroundStyle(Theme.textPrimary)
            .padding(.horizontal, 9)
            .padding(.vertical, 7)
            .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Theme.surface))
            .overlay(
                RoundedRectangle(cornerRadius: 7, style: .continuous).stroke(Theme.hairlineStrong, lineWidth: 1)
            )
    }
}

extension View {
    func boxedField() -> some View { modifier(BoxedField()) }
}

struct PrimaryButton: View {
    var title: String
    var isEnabled: Bool = true
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(Theme.ui(12, .semibold))
                .foregroundStyle(isEnabled ? Color.black.opacity(0.85) : Theme.textTertiary)
                .padding(.horizontal, 14)
                .padding(.vertical, 7)
                .background(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(isEnabled ? Theme.accent : Color.white.opacity(0.07))
                )
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .keyboardShortcut(.defaultAction)
    }
}

struct SecondaryButton: View {
    var title: String
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(Theme.ui(12, .medium))
                .foregroundStyle(Theme.textSecondary)
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Color.white.opacity(0.06)))
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Repository picker

/// Collects repositories for a workspace, either from folders on disk or by
/// cloning a remote.
struct RepoPicker: View {
    @Bindable var store: ForgeStore
    @Binding var picked: [WorkspaceRepo]
    @Binding var cloneTargets: [String]
    @State private var remote = ""
    @State private var rejected: [String] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                SecondaryButton(title: "Choose folders…", action: chooseFolders)
                Text("or paste a GitHub URL")
                    .font(Theme.ui(10.5))
                    .foregroundStyle(Theme.textTertiary)
            }

            HStack(spacing: 6) {
                TextField("anthropics/claude-code  or  https://github.com/…", text: $remote)
                    .boxedField()
                    .onSubmit(addRemote)
                SecondaryButton(title: "Add", action: addRemote)
            }

            if !rejected.isEmpty {
                Text("Not a git repository: " + rejected.joined(separator: ", "))
                    .font(Theme.ui(10.5))
                    .foregroundStyle(Theme.dirty)
            }

            if picked.isEmpty && cloneTargets.isEmpty {
                Text("No repositories yet.")
                    .font(Theme.ui(11))
                    .foregroundStyle(Theme.textTertiary)
                    .padding(.vertical, 6)
            } else {
                VStack(spacing: 4) {
                    ForEach(picked) { repo in
                        row(
                            icon: "shippingbox.fill",
                            tint: Theme.worktree,
                            title: repo.name,
                            detail: abbreviate(repo.path),
                            remove: { picked.removeAll { $0.id == repo.id } }
                        )
                    }
                    ForEach(cloneTargets, id: \.self) { target in
                        row(
                            icon: "arrow.down.circle",
                            tint: Theme.accent,
                            title: StackService.repoName(from: StackService.normalizeRemote(target)),
                            detail: "will be cloned",
                            remove: { cloneTargets.removeAll { $0 == target } }
                        )
                    }
                }
            }
        }
    }

    private func row(icon: String, tint: Color, title: String, detail: String, remove: @escaping () -> Void) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon).font(Theme.ui(10)).foregroundStyle(tint).frame(width: 14)
            Text(title).font(Theme.ui(12, .medium)).foregroundStyle(Theme.textPrimary)
            Text(detail)
                .font(Theme.mono(10))
                .foregroundStyle(Theme.textTertiary)
                .lineLimit(1)
                .truncationMode(.head)
            Spacer(minLength: 0)
            Button(action: remove) {
                Image(systemName: "xmark").font(Theme.ui(9, .bold)).foregroundStyle(Theme.textTertiary)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Theme.surface))
    }

    private func chooseFolders() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        panel.prompt = "Add"
        panel.message = "Pick one or more git repositories"
        guard panel.runModal() == .OK else { return }

        let result = store.inspectRepos(at: panel.urls.map(\.path))
        rejected = result.rejected
        let existing = Set(picked.map(\.id))
        picked.append(contentsOf: result.repos.filter { !existing.contains($0.id) })
    }

    private func addRemote() {
        let trimmed = remote.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !cloneTargets.contains(trimmed) else { return }
        cloneTargets.append(trimmed)
        remote = ""
    }

    private func abbreviate(_ path: String) -> String {
        path.replacingOccurrences(of: NSHomeDirectory(), with: "~")
    }
}

// MARK: - New workspace

struct NewWorkspaceSheet: View {
    @Bindable var store: ForgeStore
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var picked: [WorkspaceRepo] = []
    @State private var cloneTargets: [String] = []

    private var canCreate: Bool {
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && (!picked.isEmpty || !cloneTargets.isEmpty)
    }

    var body: some View {
        SheetFrame(
            title: "New workspace",
            subtitle: "A workspace is the set of repositories you work on together. Stacks cut the same branch across all of them at once."
        ) {
            VStack(alignment: .leading, spacing: 16) {
                FormField(label: "Name") {
                    TextField("Payments revamp", text: $name).boxedField()
                }
                FormField(
                    label: "Repositories",
                    hint: "New worktrees will be created under ~/Forge/\(Workspace.slug(name.isEmpty ? "workspace" : name))."
                ) {
                    RepoPicker(store: store, picked: $picked, cloneTargets: $cloneTargets)
                }
            }
        } footer: {
            Spacer()
            SecondaryButton(title: "Cancel") { dismiss() }
            PrimaryButton(title: "Create workspace", isEnabled: canCreate) {
                store.createWorkspace(name: name, repos: picked)
                if !cloneTargets.isEmpty { store.cloneRepos(cloneTargets) }
                dismiss()
            }
        }
    }
}

// MARK: - Add repositories

struct AddReposSheet: View {
    @Bindable var store: ForgeStore
    @Environment(\.dismiss) private var dismiss
    @State private var picked: [WorkspaceRepo] = []
    @State private var cloneTargets: [String] = []

    var body: some View {
        SheetFrame(
            title: "Add repositories",
            subtitle: store.activeWorkspace.map { "Adding to “\($0.name)”." }
        ) {
            RepoPicker(store: store, picked: $picked, cloneTargets: $cloneTargets)
        } footer: {
            Spacer()
            SecondaryButton(title: "Cancel") { dismiss() }
            PrimaryButton(title: "Add", isEnabled: !picked.isEmpty || !cloneTargets.isEmpty) {
                if !picked.isEmpty { store.addRepos(picked) }
                if !cloneTargets.isEmpty { store.cloneRepos(cloneTargets) }
                dismiss()
            }
        }
    }
}

// MARK: - New stack

struct NewStackSheet: View {
    @Bindable var store: ForgeStore
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var branch = ""
    @State private var branchEdited = false
    @State private var baseRef = ""
    @State private var intent = ""

    private var repos: [WorkspaceRepo] { store.activeWorkspace?.repos ?? [] }
    private var resolvedBranch: String {
        branchEdited ? branch : Workspace.slug(name)
    }
    private var canCreate: Bool {
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !repos.isEmpty
    }

    var body: some View {
        SheetFrame(
            title: "New stack",
            subtitle: "Creates the same branch as a worktree in every repository of this workspace, so one change can span all of them."
        ) {
            VStack(alignment: .leading, spacing: 16) {
                FormField(label: "Name") {
                    TextField("Add passkey login", text: $name).boxedField()
                }
                FormField(label: "Branch", hint: "Created in each repository. Reused if it already exists.") {
                    TextField(Workspace.slug(name.isEmpty ? "branch-name" : name), text: Binding(
                        get: { resolvedBranch },
                        set: { branch = $0; branchEdited = true }
                    ))
                    .boxedField()
                }
                FormField(label: "Base", hint: "Leave empty to branch from each repository's default branch.") {
                    TextField("origin/main", text: $baseRef).boxedField()
                }
                FormField(label: "Intent", hint: "Included in the brief given to agents launched in this stack.") {
                    TextField("What this stack is for", text: $intent, axis: .vertical)
                        .lineLimit(2...4)
                        .boxedField()
                }

                VStack(alignment: .leading, spacing: 5) {
                    Text("WILL CREATE")
                        .font(Theme.ui(9.5, .heavy))
                        .tracking(0.7)
                        .foregroundStyle(Theme.textTertiary)
                    ForEach(repos) { repo in
                        HStack(spacing: 7) {
                            Image(systemName: "square.on.square")
                                .font(Theme.ui(9))
                                .foregroundStyle(Theme.worktree)
                            Text(repo.name).font(Theme.ui(11.5, .medium)).foregroundStyle(Theme.textPrimary)
                            Text(destination(for: repo))
                                .font(Theme.mono(10))
                                .foregroundStyle(Theme.textTertiary)
                                .lineLimit(1)
                                .truncationMode(.head)
                            Spacer(minLength: 0)
                        }
                    }
                    if repos.isEmpty {
                        Text("This workspace has no repositories yet.")
                            .font(Theme.ui(11))
                            .foregroundStyle(Theme.dirty)
                    }
                }
            }
        } footer: {
            Spacer()
            SecondaryButton(title: "Cancel") { dismiss() }
            PrimaryButton(title: "Create stack", isEnabled: canCreate) {
                store.createStack(
                    name: name,
                    branch: resolvedBranch,
                    baseRef: baseRef.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : baseRef,
                    intent: intent
                )
                dismiss()
            }
        }
    }

    private func destination(for repo: WorkspaceRepo) -> String {
        guard let workspace = store.activeWorkspace else { return "" }
        let folder = Workspace.slug(name.isEmpty ? "stack" : name)
        return (workspace.worktreeRoot + "/" + folder + "/" + repo.name)
            .replacingOccurrences(of: NSHomeDirectory(), with: "~")
    }
}

// MARK: - Launch agent

struct LaunchAgentSheet: View {
    @Bindable var store: ForgeStore
    var node: NodeID?
    @Environment(\.dismiss) private var dismiss
    @State private var request = AgentLaunch()
    @State private var loaded = false

    private var stack: Stack? { node.flatMap { store.stack(containing: $0) } }

    var body: some View {
        SheetFrame(
            title: "Launch agent",
            subtitle: stack.map { "In stack “\($0.name)” on branch \($0.branch)." }
                ?? "Starts a Claude Code session in this checkout."
        ) {
            VStack(alignment: .leading, spacing: 16) {
                FormField(label: "Role") {
                    HStack(spacing: 8) {
                        ForEach(AgentRole.allCases) { role in
                            roleCard(role)
                        }
                    }
                }

                FormField(label: "Task") {
                    TextField("What should it do?", text: $request.prompt, axis: .vertical)
                        .lineLimit(4...10)
                        .boxedField()
                }

                HStack(alignment: .top, spacing: 12) {
                    FormField(label: "Model") {
                        Picker("", selection: $request.model) {
                            ForEach(AgentLaunch.models, id: \.label) { model in
                                Text(model.label).tag(model.id)
                            }
                        }
                        .labelsHidden()
                        .pickerStyle(.menu)
                    }
                    FormField(label: "Permissions") {
                        Picker("", selection: $request.permissionMode) {
                            ForEach(AgentLaunch.permissionModes, id: \.self) { mode in
                                Text(mode).tag(mode)
                            }
                        }
                        .labelsHidden()
                        .pickerStyle(.menu)
                    }
                }

                FormField(label: "Name", hint: "Shown on the card and in `claude agents`. Left empty, one is derived.") {
                    TextField("auto", text: $request.name).boxedField()
                }

                Toggle(isOn: $request.runsInBackground) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Run in the background")
                            .font(Theme.ui(11.5, .medium))
                            .foregroundStyle(Theme.textPrimary)
                        Text(request.runsInBackground
                             ? "Headless. Watch it on the board and read the transcript here."
                             : "Opens a Terminal window you can talk to.")
                            .font(Theme.ui(10.5))
                            .foregroundStyle(Theme.textTertiary)
                    }
                }
                .toggleStyle(.switch)
                .tint(Theme.accent)

                targets
            }
        } footer: {
            Spacer()
            SecondaryButton(title: "Cancel") { dismiss() }
            PrimaryButton(
                title: "Launch",
                isEnabled: !request.prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    && !request.cwd.isEmpty
            ) {
                store.launchAgent(request)
                dismiss()
            }
        }
        .onAppear {
            guard !loaded else { return }
            loaded = true
            request = store.launchTemplate(for: node)
        }
    }

    private func roleCard(_ role: AgentRole) -> some View {
        let selected = request.role == role
        return Button {
            request.role = role
        } label: {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 5) {
                    Image(systemName: role.icon).font(Theme.ui(11, .semibold))
                    Text(role.label).font(Theme.ui(12, .semibold))
                }
                .foregroundStyle(selected ? Theme.accent : Theme.textSecondary)
                Text(role.detail)
                    .font(Theme.ui(10))
                    .foregroundStyle(Theme.textTertiary)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(9)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(selected ? Theme.accent.opacity(0.12) : Theme.surface)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(selected ? Theme.accent.opacity(0.5) : Theme.hairline, lineWidth: 1)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private var targets: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("WORKING DIRECTORIES")
                .font(Theme.ui(9.5, .heavy))
                .tracking(0.7)
                .foregroundStyle(Theme.textTertiary)
            ForEach(request.additionalDirs, id: \.self) { path in
                HStack(spacing: 6) {
                    Image(systemName: path == request.cwd ? "largecircle.fill.circle" : "circle")
                        .font(Theme.ui(8))
                        .foregroundStyle(path == request.cwd ? Theme.accent : Theme.textTertiary)
                    Text(path.replacingOccurrences(of: NSHomeDirectory(), with: "~"))
                        .font(Theme.mono(10))
                        .foregroundStyle(Theme.textSecondary)
                        .lineLimit(1)
                        .truncationMode(.head)
                    Spacer(minLength: 0)
                }
            }
            if request.additionalDirs.count > 1 {
                Text("The filled one is the working directory; the rest are granted with --add-dir, so one agent can change all of them together.")
                    .font(Theme.ui(10))
                    .foregroundStyle(Theme.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

import AppKit
import AppState
import DesignSystem
import MeshvyModels
import SwiftUI
import WorkspaceKit

/// Collects repositories for a workspace, either from folders on disk or by
/// cloning a remote.
public struct RepoPicker: View {
    @Bindable public var store: MeshvyStore
    @Binding public var picked: [WorkspaceRepo]
    @Binding public var cloneTargets: [String]

    public init(
        store: MeshvyStore,
        picked: Binding<[WorkspaceRepo]>,
        cloneTargets: Binding<[String]>
    ) {
        self.store = store
        self._picked = picked
        self._cloneTargets = cloneTargets
    }
    @State private var remote = ""
    @State private var rejected: [String] = []

    public var body: some View {
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
                    .foregroundStyle(Theme.danger)
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
                            detail: abbreviate(repo.originPath),
                            remove: { picked.removeAll { $0.id == repo.id } }
                        )
                    }
                    ForEach(cloneTargets, id: \.self) { target in
                        row(
                            icon: "arrow.down.circle",
                            tint: Theme.accent,
                            title: WorkspaceBuilder.repoName(from: WorkspaceBuilder.normalizeRemote(target)),
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

    /// Picks repositories with a folder panel. Multiple selection is on, so a
    /// whole set can be added in one go.
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

public struct NewWorkspaceSheet: View {
    @Bindable public var store: MeshvyStore

    public init(
        store: MeshvyStore
    ) {
        self.store = store
    }
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var picked: [WorkspaceRepo] = []
    @State private var cloneTargets: [String] = []
    @State private var baseRef = ""
    @State private var branches: [String] = []
    @State private var branchOverride = ""

    private var branch: String {
        branchOverride.isEmpty ? Workspace.slug(name.isEmpty ? "workspace" : name) : branchOverride
    }

    private var canCreate: Bool {
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !picked.isEmpty
    }

    public var body: some View {
        SheetFrame(
            title: "New workspace",
            subtitle: "Pick the repositories you work on together. Meshvy cuts one branch across all of them and checks each one out side by side under ~/.meshvy."
        ) {
            VStack(alignment: .leading, spacing: 16) {
                FormField(label: "Name") {
                    TextField("Payments revamp", text: $name).boxedField()
                }

                FormField(label: "Repositories") {
                    RepoPicker(store: store, picked: $picked, cloneTargets: $cloneTargets)
                }

                if !picked.isEmpty {
                    HStack(alignment: .top, spacing: 12) {
                        FormField(label: "Branch from", hint: "The base each worktree is cut from.") {
                            Picker("", selection: $baseRef) {
                                Text("Each repo's default").tag("")
                                ForEach(branches, id: \.self) { Text($0).tag($0) }
                            }
                            .labelsHidden()
                            .pickerStyle(.menu)
                        }
                        FormField(label: "New branch", hint: "Created in every repository.") {
                            TextField(Workspace.slug(name.isEmpty ? "branch" : name), text: Binding(
                                get: { branch },
                                set: { branchOverride = $0 }
                            ))
                            .boxedField()
                        }
                    }

                    VStack(alignment: .leading, spacing: 5) {
                        Text("WILL CREATE")
                            .font(Theme.ui(9.5, .heavy))
                            .tracking(0.7)
                            .foregroundStyle(Theme.textTertiary)
                        ForEach(picked) { repo in
                            HStack(spacing: 7) {
                                Image(systemName: "square.on.square")
                                    .font(Theme.ui(9))
                                    .foregroundStyle(Theme.worktree)
                                Text(repo.name).font(Theme.ui(11.5, .medium)).foregroundStyle(Theme.textPrimary)
                                Text("~/.meshvy/\(Workspace.slug(name.isEmpty ? "workspace" : name))/\(repo.name)")
                                    .font(Theme.mono(10))
                                    .foregroundStyle(Theme.textTertiary)
                                    .lineLimit(1)
                                    .truncationMode(.head)
                                Spacer(minLength: 0)
                            }
                        }
                    }
                }
            }
        } footer: {
            Spacer()
            SecondaryButton(title: "Cancel") { dismiss() }
            PrimaryButton(title: "Create workspace", isEnabled: canCreate) {
                store.createWorkspace(
                    name: name,
                    repos: picked,
                    baseRef: baseRef.isEmpty ? nil : baseRef,
                    branch: branch
                )
                if !cloneTargets.isEmpty { store.cloneRepos(cloneTargets, thenAddToActive: true) }
                dismiss()
            }
        }
        .onChange(of: picked) { _, repos in
            branches = store.branches(for: repos)
        }
    }
}

public struct AddReposSheet: View {
    @Bindable public var store: MeshvyStore

    public init(
        store: MeshvyStore
    ) {
        self.store = store
    }
    @Environment(\.dismiss) private var dismiss
    @State private var picked: [WorkspaceRepo] = []
    @State private var cloneTargets: [String] = []

    public var body: some View {
        SheetFrame(
            title: "Add repositories",
            subtitle: store.activeWorkspace.map {
                "They will be checked out on “\($0.branch)” alongside the others."
            }
        ) {
            RepoPicker(store: store, picked: $picked, cloneTargets: $cloneTargets)
        } footer: {
            Spacer()
            SecondaryButton(title: "Cancel") { dismiss() }
            PrimaryButton(title: "Add", isEnabled: !picked.isEmpty || !cloneTargets.isEmpty) {
                if !picked.isEmpty { store.addRepos(picked) }
                if !cloneTargets.isEmpty { store.cloneRepos(cloneTargets, thenAddToActive: true) }
                dismiss()
            }
        }
    }
}

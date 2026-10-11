import SwiftUI

/// What is in the new version, and one button to take it.
struct UpdateSheet: View {
    @Bindable var store: MeshvyStore
    @Environment(\.dismiss) private var dismiss

    private var release: UpdateService.Release? { store.updates.availableRelease }

    var body: some View {
        SheetFrame(
            title: release.map { "Meshvy \($0.version) is available" } ?? "Updates",
            subtitle: subtitle
        ) {
            VStack(alignment: .leading, spacing: 14) {
                switch store.updates.state {
                case .downloading(let fraction):
                    VStack(alignment: .leading, spacing: 7) {
                        ProgressView(value: fraction)
                            .tint(Theme.accent)
                        Text("Downloading… \(Int(fraction * 100))%")
                            .font(Theme.ui(11))
                            .foregroundStyle(Theme.textTertiary)
                    }
                case .failed(let message):
                    Label(message, systemImage: "exclamationmark.triangle.fill")
                        .font(Theme.ui(11.5))
                        .foregroundStyle(Theme.dirty)
                        .fixedSize(horizontal: false, vertical: true)
                case .upToDate:
                    Label("You are on the latest version.", systemImage: "checkmark.circle.fill")
                        .font(Theme.ui(11.5))
                        .foregroundStyle(Theme.clean)
                default:
                    EmptyView()
                }

                if let release, !release.notes.isEmpty {
                    Text("WHAT'S NEW")
                        .font(Theme.ui(9.5, .heavy))
                        .tracking(0.7)
                        .foregroundStyle(Theme.textTertiary)
                    Text(release.notes)
                        .font(Theme.ui(11.5))
                        .foregroundStyle(Theme.textSecondary)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if release != nil {
                    Text("Meshvy will quit, swap itself for the new version, and reopen.")
                        .font(Theme.ui(10.5))
                        .foregroundStyle(Theme.textTertiary)
                }
            }
        } footer: {
            Spacer()
            SecondaryButton(title: release == nil ? "Close" : "Not now") {
                store.updates.dismiss()
                dismiss()
            }
            if release != nil {
                PrimaryButton(title: "Install and restart", isEnabled: !store.updates.isBusy) {
                    store.updates.installAndRestart()
                }
            } else {
                PrimaryButton(title: "Check again", isEnabled: !store.updates.isBusy) {
                    store.updates.check(announceNoUpdate: true)
                }
            }
        }
    }

    private var subtitle: String {
        let current = UpdateService.currentVersion.map { "You have \($0)." } ?? "Development build."
        guard let release else { return current }
        let megabytes = Double(release.sizeBytes) / 1_000_000
        return current + String(format: "  Download is %.1f MB.", megabytes)
    }
}

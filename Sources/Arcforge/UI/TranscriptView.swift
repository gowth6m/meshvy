import SwiftUI

/// Reader for one transcript. Tool calls, results and thinking blocks start
/// collapsed so the conversation stays legible; expand what you need.
///
/// The visible slice is cached rather than recomputed in `body`: a long session
/// runs to thousands of events, and re-filtering them on every render is what
/// made the panel feel slow to open.
struct TranscriptView: View {
    var transcript: Transcript
    @Environment(\.arcforgeSnapshotMode) private var isSnapshot
    @State private var expanded: Set<String> = []
    @State private var hidden: Set<EventFilter> = [.tools]
    @State private var visible: [TranscriptEvent] = []

    enum EventFilter: String, CaseIterable, Hashable {
        case tools, thinking, system

        var label: String {
            switch self {
            case .tools: return "Tools"
            case .thinking: return "Thinking"
            case .system: return "System"
            }
        }

        func matches(_ kind: TranscriptEvent.Kind) -> Bool {
            switch (self, kind) {
            case (.tools, .toolUse), (.tools, .toolResult): return true
            case (.thinking, .thinking): return true
            case (.system, .system), (.system, .attachment): return true
            default: return false
            }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            filterBar
            Divider().overlay(Theme.hairline)
            ScrollableStack(alignment: .leading) {
                LazyVStack(alignment: .leading, spacing: 8) {
                    if transcript.truncated {
                        Text("Showing the most recent events in this session.")
                            .font(Theme.ui(10.5))
                            .foregroundStyle(Theme.textTertiary)
                            .padding(.bottom, 4)
                    }
                    ForEach(isSnapshot ? Array(visible.prefix(12)) : visible) { event in
                        EventRow(
                            event: event,
                            isExpanded: expanded.contains(event.id) || !event.startsCollapsed,
                            toggle: {
                                if expanded.contains(event.id) { expanded.remove(event.id) }
                                else { expanded.insert(event.id) }
                            }
                        )
                    }
                    if visible.isEmpty {
                        Text("Nothing to show with the current filters.")
                            .font(Theme.ui(11))
                            .foregroundStyle(Theme.textTertiary)
                    }
                }
                .padding(12)
            }
        }
        .onAppear(perform: recompute)
        .onChange(of: transcript.sessionId) { _, _ in
            expanded.removeAll()
            recompute()
        }
        .onChange(of: hidden) { _, _ in recompute() }
    }

    private func recompute() {
        visible = hidden.isEmpty
            ? transcript.events
            : transcript.events.filter { event in
                !hidden.contains { $0.matches(event.kind) }
            }
    }

    private var filterBar: some View {
        HStack(spacing: 8) {
            ForEach(EventFilter.allCases, id: \.self) { filter in
                toggle(filter)
            }
            Spacer(minLength: 0)
            Text("\(visible.count) events")
                .font(Theme.mono(9.5))
                .foregroundStyle(Theme.textTertiary)
        }
        .padding(.horizontal, 12)
        .frame(height: 34)
    }

    private func count(_ filter: EventFilter) -> Int {
        switch filter {
        case .tools: return transcript.toolEventCount
        case .thinking: return transcript.thinkingEventCount
        case .system: return transcript.systemEventCount
        }
    }

    private func toggle(_ filter: EventFilter) -> some View {
        let isOn = !hidden.contains(filter)
        let total = count(filter)
        return Button {
            if isOn { hidden.insert(filter) } else { hidden.remove(filter) }
        } label: {
            HStack(spacing: 3) {
                Image(systemName: isOn ? "checkmark.square.fill" : "square")
                    .font(Theme.ui(9))
                Text(filter.label).font(Theme.ui(10.5, .medium))
                if total > 0 {
                    Text("\(total)").font(Theme.mono(9)).foregroundStyle(Theme.textTertiary)
                }
            }
            .foregroundStyle(isOn ? Theme.textSecondary : Theme.textTertiary)
        }
        .buttonStyle(.plain)
        .disabled(total == 0)
    }
}

private struct EventRow: View {
    var event: TranscriptEvent
    var isExpanded: Bool
    var toggle: () -> Void

    private var tint: Color {
        switch event.kind {
        case .userMessage: return Theme.accent
        case .assistantMessage: return Theme.textPrimary
        case .thinking: return Theme.sidechain
        case .toolUse: return Theme.worktree
        case .toolResult(let ok): return ok ? Theme.clean : Theme.dirty
        case .system, .attachment: return Theme.textTertiary
        }
    }

    private var icon: String {
        switch event.kind {
        case .userMessage: return "person.fill"
        case .assistantMessage: return "sparkle"
        case .thinking: return "brain"
        case .toolUse: return "wrench.and.screwdriver.fill"
        case .toolResult(let ok): return ok ? "arrow.turn.down.right" : "exclamationmark.triangle.fill"
        case .system: return "gearshape"
        case .attachment: return "paperclip"
        }
    }

    private var isMonospaced: Bool {
        switch event.kind {
        case .toolUse, .toolResult, .system: return true
        default: return false
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Button(action: toggle) {
                HStack(spacing: 5) {
                    Image(systemName: icon)
                        .font(Theme.ui(9, .semibold))
                        .foregroundStyle(tint)
                        .frame(width: 13)
                    Text(event.kind.label)
                        .font(Theme.ui(10.5, .semibold))
                        .foregroundStyle(tint)
                    if let model = Format.model(event.model), case .assistantMessage = event.kind {
                        Text(model).font(Theme.ui(9.5)).foregroundStyle(Theme.textTertiary)
                    }
                    Spacer(minLength: 0)
                    if let timestamp = event.timestamp {
                        Text(timestamp, format: .dateTime.hour().minute().second())
                            .font(Theme.mono(9))
                            .foregroundStyle(Theme.textTertiary)
                    }
                    if event.startsCollapsed {
                        Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                            .font(Theme.ui(8, .bold))
                            .foregroundStyle(Theme.textTertiary)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(!event.startsCollapsed)

            if isExpanded {
                Text(event.text)
                    .font(isMonospaced ? Theme.mono(10.5) : Theme.ui(11.5))
                    .foregroundStyle(event.kind == .thinking ? Theme.textSecondary : Theme.textPrimary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                Text(event.preview)
                    .font(Theme.mono(10))
                    .foregroundStyle(Theme.textTertiary)
                    .lineLimit(1)
            }
        }
        .padding(9)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(backgroundTint))
        .overlay(alignment: .leading) {
            if case .userMessage = event.kind {
                Rectangle().fill(Theme.accent).frame(width: 2)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private var backgroundTint: Color {
        switch event.kind {
        case .userMessage: return Theme.accent.opacity(0.07)
        case .assistantMessage: return Theme.surface
        default: return Theme.surfaceSunken
        }
    }
}

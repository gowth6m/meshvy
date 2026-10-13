import SwiftUI

/// Compact segmented picker used for board grouping.
public struct SegmentedControl<Option: Hashable>: View {
    public var options: [Option]
    @Binding public var selection: Option
    public var label: (Option) -> String
    public var icon: (Option) -> String

    public init(
        options: [Option],
        selection: Binding<Option>,
        label: @escaping (Option) -> String,
        icon: @escaping (Option) -> String
    ) {
        self.options = options
        self._selection = selection
        self.label = label
        self.icon = icon
    }

    public var body: some View {
        HStack(spacing: 2) {
            ForEach(options, id: \.self) { option in
                let selected = option == selection
                Button { selection = option } label: {
                    HStack(spacing: 4) {
                        Image(systemName: icon(option)).font(Theme.ui(9.5, .semibold))
                        Text(label(option)).font(Theme.ui(10.5, .medium))
                    }
                    .foregroundStyle(selected ? Theme.textPrimary : Theme.textTertiary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(
                        RoundedRectangle(cornerRadius: 5, style: .continuous)
                            .fill(selected ? Theme.fillStrong : .clear)
                    )
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(2)
        .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Theme.fill))
    }
}

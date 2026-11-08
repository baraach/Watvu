import SwiftUI
import Combine

/// One choice in a glass dropdown or player panel.
struct DropdownOption<Value: Hashable>: Identifiable {
    let value: Value
    let title: String
    var symbol: String? = nil
    var subtitle: String? = nil

    var id: Value { value }
}

/// Replaces a native pop-up menu: the label opens a popover (Apple's
/// default glass popover on macOS 26) with icon rows, hover highlights and
/// an accent checkmark on the current choice. Picking closes it.
struct GlassDropdown<Value: Hashable, Label: View>: View {
    var title: String? = nil
    let options: [DropdownOption<Value>]
    @Binding var selection: Value
    var width: CGFloat = 220
    @ViewBuilder var label: Label
    @StateObject private var state = DropdownState()

    var body: some View {
        Button {
            state.isOpen.toggle()
        } label: {
            label
        }
        .popover(isPresented: $state.isOpen, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 1) {
                if let title {
                    MenuSection(title: title)
                }
                ForEach(options) { option in
                    MenuRow(title: option.title, subtitle: option.subtitle, symbol: option.symbol,
                            isSelected: option.value == selection) {
                        selection = option.value
                        state.isOpen = false
                    }
                }
            }
            .padding(6)
            .frame(width: width)
        }
    }
}

private final class DropdownState: ObservableObject {
    @Published var isOpen = false
}

/// A labelled field-style dropdown for forms and Settings: current icon and
/// title in a clear-glass capsule with an up/down chevron.
struct DropdownField<Value: Hashable>: View {
    var title: String? = nil
    let options: [DropdownOption<Value>]
    @Binding var selection: Value
    var width: CGFloat = 220

    private var current: DropdownOption<Value>? {
        options.first { $0.value == selection }
    }

    var body: some View {
        GlassDropdown(title: title, options: options, selection: $selection, width: width) {
            HStack(spacing: 7) {
                if let symbol = current?.symbol {
                    Image(systemName: symbol)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Theme.accent)
                }
                Text(current?.title ?? "Choose")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Theme.textPrimary)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(Theme.textSecondary)
            }
            .padding(.horizontal, 4)
        }
        .buttonBorderShape(.capsule)
        .glassButton()
        .accessibilityValue(current?.title ?? "")
    }
}

/// Small uppercase caption above a group of rows.
struct MenuSection: View {
    let title: String

    var body: some View {
        Text(title.uppercased())
            .font(.system(size: 10, weight: .bold))
            .tracking(0.8)
            .opacity(0.6)
            .padding(.horizontal, 10)
            .padding(.top, 6)
            .padding(.bottom, 2)
    }
}

/// One choice row: optional icon, title and subtitle, hover highlight, and
/// an accent checkmark when selected.
struct MenuRow: View {
    let title: String
    var subtitle: String? = nil
    var symbol: String? = nil
    let isSelected: Bool
    let action: () -> Void
    @StateObject private var hover = MenuRowHover()

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                if let symbol {
                    Image(systemName: symbol)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Theme.accent)
                        .frame(width: 18)
                }
                VStack(alignment: .leading, spacing: 1) {
                    Text(title)
                        .font(.system(size: 13, weight: isSelected ? .semibold : .medium))
                        .lineLimit(1)
                    if let subtitle, !subtitle.isEmpty {
                        Text(subtitle)
                            .font(.system(size: 11))
                            .opacity(0.6)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 8)
                if isSelected {
                    Image(systemName: "checkmark")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(Theme.accent)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, subtitle == nil ? 8 : 6)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color.primary.opacity(hover.isHovering ? 0.1 : 0))
            )
            .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.12)) { hover.isHovering = hovering }
        }
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

private final class MenuRowHover: ObservableObject {
    @Published var isHovering = false
}

import SwiftUI

/// Manual channel → XMLTV channel id mapping. Needed when a playlist has no
/// `tvg-id` and the display-name fallback is ambiguous.
struct ChannelMappingView: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    let channel: MediaItem

    @StateObject private var state = MappingState()

    private var current: String? { model.epgChannelID(for: channel) }

    private var options: [(id: String, name: String)] {
        let names = model.epgChannelNames[channel.playlistID] ?? [:]
        let query = state.query.trimmed.lowercased()
        return names
            .map { (id: $0.key, name: $0.value.first ?? $0.key) }
            .filter {
                query.isEmpty
                    || $0.name.lowercased().contains(query)
                    || $0.id.lowercased().contains(query)
            }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            search

            if model.epgChannelNames[channel.playlistID]?.isEmpty != false {
                emptyState
            } else {
                ScrollView(.vertical, showsIndicators: false) {
                    LazyVStack(spacing: 0) {
                        automaticRow
                        Divider().padding(.leading, 18)
                        ForEach(options, id: \.id) { option in
                            optionRow(option)
                            Divider().padding(.leading, 18)
                        }
                    }
                }
            }
        }
        .frame(width: 580, height: 540)
        .background(Theme.background)
    }

    private var header: some View {
        SheetHeader(title: "Map EPG Channel", subtitle: channel.name) {
            SheetArtwork(key: channel.group, logo: channel.logo)
        } onClose: { dismiss() }
    }

    private var search: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(Theme.textSecondary)
            TextField("Search XMLTV channels", text: $state.query)
                .textFieldStyle(.plain)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(Color.primary.opacity(0.05), in: Capsule())
        .padding(.horizontal, 16)
        .padding(.bottom, 10)
    }

    private var automaticRow: some View {
        Button {
            model.setEPGChannel(nil, for: channel)
            dismiss()
        } label: {
            HStack {
                Image(systemName: "wand.and.stars")
                    .foregroundStyle(Theme.accent)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Automatic matching")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(Theme.textPrimary)
                    Text(channel.tvgID.map { "Uses tvg-id \($0) or the channel name" } ?? "Uses the channel name")
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.textSecondary)
                }
                Spacer()
                if current == nil {
                    Image(systemName: "checkmark")
                        .foregroundStyle(Theme.accent)
                }
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 12)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func optionRow(_ option: (id: String, name: String)) -> some View {
        Button {
            model.setEPGChannel(option.id, for: channel)
            dismiss()
        } label: {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(option.name)
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(Theme.textPrimary)
                        .lineLimit(1)
                    Text(option.id)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(Theme.textSecondary)
                        .lineLimit(1)
                }
                Spacer()
                if current == option.id {
                    Image(systemName: "checkmark")
                        .foregroundStyle(Theme.accent)
                }
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 10)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "calendar.badge.exclamationmark")
                .font(.system(size: 36, weight: .light))
                .foregroundStyle(Theme.textSecondary)
            Text("No XMLTV channels loaded")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(Theme.textPrimary)
            Text("Refresh the guide first, then map this channel.")
                .font(.system(size: 13))
                .foregroundStyle(Theme.textSecondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private final class MappingState: ObservableObject {
    @Published var query = ""
}

import SwiftUI
import Combine

/// Timeline grid guide: channels down the side, programmes laid out along a
/// time axis. Click a current programme to watch live, a past one to watch
/// it from the archive (catch-up), when the channel has one.
struct GuideTimeline: View {
    @EnvironmentObject var model: AppModel
    let channels: [MediaItem]
    let onSelect: (MediaItem, EPGProgram) -> Void
    @StateObject private var scroll = TimelineScroll()

    private let start: Date
    private let end: Date
    private let channelWidth: CGFloat = 200
    private let rowHeight: CGFloat = 60
    private let pointsPerMinute: CGFloat = 4

    let dayOffset: Int

    init(channels: [MediaItem], onSelect: @escaping (MediaItem, EPGProgram) -> Void, dayOffset: Int = 0) {
        self.channels = channels
        self.onSelect = onSelect
        self.dayOffset = dayOffset
        // From three hours ago (on a half hour) to fifteen hours ahead.
        let halfHour: TimeInterval = 1800
        let now = Date().timeIntervalSince1970 + Double(dayOffset) * 86_400
        start = Date(timeIntervalSince1970: (now / halfHour).rounded(.down) * halfHour - 3 * 3600)
        end = start.addingTimeInterval(18 * 3600)
    }

    private var timelineWidth: CGFloat { x(for: end) }

    private var dayLabel: String {
        switch dayOffset {
        case -1: return "Yesterday"
        case 0: return "Today"
        case 1: return "Tomorrow"
        default: return start.formatted(date: .abbreviated, time: .omitted)
        }
    }

    private func x(for date: Date) -> CGFloat {
        CGFloat(date.timeIntervalSince(start) / 60) * pointsPerMinute
    }

    var body: some View {
        GeometryReader { viewport in
            ScrollView([.horizontal, .vertical]) {
                LazyVStack(alignment: .leading, spacing: 6, pinnedViews: [.sectionHeaders]) {
                    Section {
                        ForEach(channels) { channel in
                            row(channel)
                        }
                    } header: {
                        ruler
                    }
                }
                .padding(.bottom, 40)
            }
            // Open at the top, scrolled so half an hour ago sits just right
            // of the channel column. An anchor u gives offset u·(content −
            // viewport), so solve for the offset we want.
            .defaultScrollAnchor(UnitPoint(x: initialAnchorX(viewportWidth: viewport.size.width), y: 0))
            .onScrollGeometryChange(for: CGFloat.self, of: { $0.contentOffset.x }) { _, x in
                scroll.x = max(0, x)
            }
        }
    }

    private func initialAnchorX(viewportWidth: CGFloat) -> CGFloat {
        let scrollable = channelWidth + timelineWidth - viewportWidth
        guard scrollable > 0 else { return 0 }
        return min(max(x(for: Date().addingTimeInterval(-1800)) / scrollable, 0), 1)
    }

    // MARK: - Time ruler

    private var ruler: some View {
        let ticks = stride(from: 0, to: 18 * 2, by: 1).map { start.addingTimeInterval(Double($0) * 1800) }
        return ZStack(alignment: .topLeading) {
            HStack(spacing: 0) {
                ForEach(ticks, id: \.self) { tick in
                    Text(tick.formatted(date: .omitted, time: .shortened))
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Theme.textSecondary)
                        .frame(width: 30 * pointsPerMinute, alignment: .leading)
                }
            }
            .padding(.leading, channelWidth)

            PinnedColumn(scroll: scroll, width: channelWidth) {
                Text(dayLabel)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Theme.textSecondary)
                    .padding(.leading, 28)
            }
        }
        .frame(width: channelWidth + timelineWidth, height: 28, alignment: .leading)
        .background(Theme.background)
    }

    // MARK: - Channel rows

    private func row(_ channel: MediaItem) -> some View {
        let now = Date()
        let programs = model.programs(for: channel).filter { $0.end > start && $0.start < end }

        return ZStack(alignment: .topLeading) {
            ForEach(programs) { program in
                let left = max(x(for: program.start), 0)
                let right = min(x(for: program.end), timelineWidth)
                ProgramBlock(
                    program: program,
                    isNow: program.start <= now && now < program.end,
                    canRewind: model.canCatchup(channel, program),
                    isFuture: program.start > now
                ) {
                    onSelect(channel, program)
                }
                .frame(width: max(right - left - 4, 8), height: rowHeight - 6)
                .offset(x: channelWidth + left + 2)
            }

            // Current time.
            Rectangle()
                .fill(Theme.accent)
                .frame(width: 2, height: rowHeight)
                .offset(x: channelWidth + x(for: now))
                .allowsHitTesting(false)

            PinnedColumn(scroll: scroll, width: channelWidth) {
                ChannelLabel(channel: channel) { model.activate(channel) }
            }
        }
        .frame(width: channelWidth + timelineWidth, height: rowHeight, alignment: .topLeading)
    }

}

/// Horizontal scroll offset, observed only by the pinned channel column so
/// scrolling doesn't re-render whole rows.
private final class TimelineScroll: ObservableObject {
    @Published var x: CGFloat = 0
}

/// Keeps its content at the left edge while the grid scrolls sideways.
private struct PinnedColumn<Content: View>: View {
    @ObservedObject var scroll: TimelineScroll
    let width: CGFloat
    @ViewBuilder var content: Content

    var body: some View {
        content
            .frame(width: width, alignment: .leading)
            .frame(maxHeight: .infinity)
            .background(Theme.background)
            .offset(x: scroll.x)
    }
}

private struct ChannelLabel: View {
    let channel: MediaItem
    let play: () -> Void

    var body: some View {
        Button(action: play) {
            HStack(spacing: 10) {
                ZStack {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Theme.gradient(for: channel.group))
                    if let logo = channel.logo, let url = URL(string: logo) {
                        AsyncImage(url: url) { image in
                            image.resizable().scaledToFit().padding(5)
                        } placeholder: {
                            Color.clear
                        }
                    }
                }
                .frame(width: 44, height: 32)

                Text(channel.name)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(2)
                Spacer(minLength: 0)
            }
            .padding(.leading, 28)
            .padding(.trailing, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Watch \(channel.name) live")
    }
}

private struct ProgramBlock: View {
    let program: EPGProgram
    let isNow: Bool
    let canRewind: Bool
    let isFuture: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    if canRewind && !isNow {
                        Image(systemName: "gobackward")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(GuideStyle.current == .greyscale ? Theme.textSecondary : Theme.accent)
                    }
                    Text(program.title)
                        .font(.system(size: 12, weight: .semibold))
                        .lineLimit(1)
                }
                Text(program.timeRange)
                    .font(.system(size: 10))
                    .foregroundStyle(Theme.textSecondary)
                    .lineLimit(1)
            }
            .foregroundStyle(Theme.textPrimary)
            .padding(.horizontal, 8)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(isNow ? Theme.accent.opacity(0.16) : Theme.surface)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(isNow ? Theme.accent.opacity(0.6) : .clear, lineWidth: 1)
            )
            .opacity(isFuture ? 0.72 : 1)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(helpText)
    }

    private var helpText: String {
        let detail = program.description.map { "\n\n\($0)" } ?? ""
        if isNow { return "\(program.title) — watch live\(detail)" }
        if canRewind { return "\(program.title) — watch from the archive\(detail)" }
        return program.title + detail
    }
}

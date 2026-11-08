import SwiftUI
import Combine

// Shared page building blocks: the scrolling page with a floating glass
// header, the header capsules, filter chips, and scroll tracking.

/// A library page: scrolling content with a glass header above it. Content
/// stops at the header, because clear glass takes its look from what's behind
/// it: over passing posters it would look different at every scroll position.
struct LibraryPage<Header: View, Content: View>: View {
    @ViewBuilder var header: Header
    @ViewBuilder var content: Content
    @StateObject private var scroll = ScrollActivity()

    var body: some View {
        ScrollView(.vertical, showsIndicators: false) {
            content
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .tracksScrolling(scroll)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .pinnedHeader {
            VStack(alignment: .leading, spacing: 0) { header }
        }
        .background(Theme.background)
    }
}

extension View {
    /// Puts a header above this scroll view, so nothing scrolls behind it.
    func pinnedHeader<Header: View>(@ViewBuilder _ header: () -> Header) -> some View {
        VStack(spacing: 0) {
            header().padding(.bottom, 6)
            self
        }
    }
}

/// Page title in a glass capsule sized to its text, with the page's actions
/// as icons in one glass capsule on the right. Actions must be plain
/// `Button`s or `HeaderDropdown`s — they're styled here, so they never get their
/// own glass (glass on glass) or text labels that get squeezed.
struct PageHeader<Actions: View>: View {
    let title: String
    var subtitle: String? = nil
    @ViewBuilder var actions: Actions

    private static var capsuleGlass: Glass { .clear }

    var body: some View {
        GlassEffectContainer(spacing: 10) {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(title)
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(Theme.textPrimary)
                    if let subtitle {
                        Text(subtitle)
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(Theme.textSecondary)
                    }
                }
                .lineLimit(1)
                .padding(.horizontal, 20)
                .frame(minHeight: 52, alignment: .leading)
                .glassEffect(Self.capsuleGlass, in: Capsule())
                .layoutPriority(1)

                Spacer(minLength: 0)

                if Actions.self != EmptyView.self {
                    HStack(spacing: 2) { actions }
                        .buttonStyle(HeaderIconButtonStyle())
                        .padding(.horizontal, 7)
                        .frame(minHeight: 52)
                        .glassEffect(Self.capsuleGlass, in: Capsule())
                        .fixedSize()
                }
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 4)
    }
}

extension PageHeader where Actions == EmptyView {
    init(title: String, subtitle: String? = nil) {
        self.init(title: title, subtitle: subtitle) { EmptyView() }
    }
}

/// Icon button inside the header's actions capsule. `prominent` fills the
/// circle with the accent (the page's main action, e.g. Add Playlist);
/// `active` marks a toggle that's on.
struct HeaderIconButtonStyle: ButtonStyle {
    var prominent = false
    var active = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .labelStyle(.iconOnly)
            .font(.system(size: 16, weight: prominent ? .bold : .medium))
            .foregroundStyle(prominent ? Color.white : (active ? Theme.accent : Theme.textPrimary))
            .frame(width: 38, height: 38)
            .background {
                Circle().fill(background(pressed: configuration.isPressed))
            }
            .contentShape(Circle())
            .scaleEffect(configuration.isPressed ? 0.92 : 1)
            .animation(.spring(response: 0.25, dampingFraction: 0.7), value: configuration.isPressed)
            .animation(.easeOut(duration: 0.15), value: active)
    }

    private func background(pressed: Bool) -> Color {
        if prominent { return Theme.accent.opacity(pressed ? 0.8 : 1) }
        if active { return Theme.accent.opacity(pressed ? 0.24 : 0.16) }
        return Color.primary.opacity(pressed ? 0.12 : 0)
    }
}

/// A header icon that opens one of the app's glass dropdowns (icon rows,
/// accent checkmark) instead of a plain system menu. Shows as active when the
/// choice isn't the default.
struct HeaderDropdown<Value: Hashable>: View {
    let title: String
    let systemImage: String
    let options: [DropdownOption<Value>]
    @Binding var selection: Value
    var isActive = false
    var width: CGFloat = 230

    var body: some View {
        GlassDropdown(title: title, options: options, selection: $selection, width: width) {
            Image(systemName: systemImage)
        }
        .buttonStyle(HeaderIconButtonStyle(active: isActive))
        .accessibilityLabel(title)
        .accessibilityValue(options.first { $0.value == selection }?.title ?? "")
        .help(title)
    }
}

/// Horizontally scrolling group filter: glass chips with one accent
/// highlight that glides to the selected chip. The bar pages with hover
/// arrows, fades at an edge that has more chips behind it, and keeps the
/// selected chip in view.
struct FilterChipBar: View {
    let options: [String]
    @Binding var selection: String
    /// Display names for options whose value isn't their title (e.g. IDs).
    var labels: [String: String] = [:]
    @Namespace private var highlight

    var body: some View {
        SlidingRow(margin: 20, spacing: 6, arrowSize: 28, scrollTo: selection,
                   fadesEdges: true, verticalPadding: 8) {
            ForEach(options, id: \.self, content: chip)
        }
    }

    private func chip(_ option: String) -> some View {
        let isSelected = selection == option
        return Button {
            withAnimation(.spring(response: 0.34, dampingFraction: 0.86)) { selection = option }
        } label: {
            Text(labels[option] ?? option)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(isSelected ? Color.white : Theme.textPrimary)
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background {
                    if isSelected {
                        Capsule()
                            .fill(Theme.accent)
                            .shadow(color: Theme.accent.opacity(0.35), radius: 6, y: 2)
                            .matchedGeometryEffect(id: "chip", in: highlight)
                    }
                }
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        // Not interactive glass: that repaints as the pointer passes over,
        // including while the page scrolls underneath.
        .glassSurface(in: Capsule())
        .id(option)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

// MARK: - Sliding row

/// Clips left and right only, leaving room for card shadows above and below.
private struct SidesOnlyClip: Shape {
    func path(in rect: CGRect) -> Path {
        Path(CGRect(x: rect.minX, y: rect.minY - 200, width: rect.width, height: rect.height + 400))
    }
}

extension View {
    /// Starts a full-width shelf at the sidebar's edge and clips it there, so
    /// its cards stop at the edge instead of sliding under the glass.
    func stopsAtSidebar(_ inset: CGFloat) -> some View {
        clipShape(SidesOnlyClip()).padding(.leading, inset)
    }
}

/// A horizontal scroller shared by filter chips and Home shelves: smooth
/// view-aligned snapping, glass arrows that appear on hover and page by
/// about one screen (hidden at either end), and optional edge fades.
struct SlidingRow<Content: View>: View {
    /// Leading/trailing content margins (the row itself runs full width).
    var margin: CGFloat
    var trailingMargin: CGFloat? = nil
    var spacing: CGFloat
    var arrowSize: CGFloat = 36
    /// When this changes, the item with this id scrolls into view.
    var scrollTo: String? = nil
    var fadesEdges = false
    /// Room above/below items for shadows and hover effects.
    var verticalPadding: CGFloat = 4
    @ViewBuilder var content: Content

    @StateObject private var state = SlidingRowState()

    private var trailing: CGFloat { trailingMargin ?? margin }

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            LazyHStack(spacing: spacing) { content }
                .padding(.vertical, verticalPadding)
                .scrollTargetLayout()
        }
        // A lazy stack fills whatever height it is offered; keep the row as
        // tall as its items (otherwise a chip bar swallows the page).
        .fixedSize(horizontal: false, vertical: true)
        .contentMargins(.leading, margin, for: .scrollContent)
        .contentMargins(.trailing, trailing, for: .scrollContent)
        .scrollTargetBehavior(.viewAligned(limitBehavior: .never))
        .scrollPosition($state.position)
        .scrollClipDisabled()
        .onScrollGeometryChange(for: SlidingRowState.Metrics.self) { geometry in
            .init(offset: geometry.contentOffset.x,
                  minOffset: -geometry.contentInsets.leading,
                  maxOffset: geometry.contentSize.width + geometry.contentInsets.trailing
                    - geometry.containerSize.width,
                  width: geometry.containerSize.width)
        } action: { _, metrics in
            if state.metrics != metrics { state.metrics = metrics }
        }
        .modifier(EdgeFade(enabled: fadesEdges, leading: state.canGoBack, trailing: state.canGoForward))
        .overlay(alignment: .leading) {
            if state.hovering && state.canGoBack {
                arrow("chevron.left", label: "Scroll back") { page(-1) }
                    .padding(.leading, max(margin - arrowSize / 2, 6))
                    .transition(.opacity.combined(with: .scale(scale: 0.8)))
            }
        }
        .overlay(alignment: .trailing) {
            if state.hovering && state.canGoForward {
                arrow("chevron.right", label: "Scroll forward") { page(1) }
                    .padding(.trailing, max(trailing - arrowSize / 2, 6))
                    .transition(.opacity.combined(with: .scale(scale: 0.8)))
            }
        }
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.18)) { state.hovering = hovering }
        }
        .onChange(of: scrollTo) { _, id in
            guard let id else { return }
            withAnimation(.smooth(duration: 0.35)) { state.position.scrollTo(id: id, anchor: .center) }
        }
    }

    private func arrow(_ symbol: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: arrowSize * 0.4, weight: .bold))
                .frame(width: arrowSize * 0.62, height: arrowSize * 0.62)
        }
        .buttonBorderShape(.circle)
        .controlSize(arrowSize >= 34 ? .large : .regular)
        .glassButton()
        .accessibilityLabel(label)
        .help(label)
    }

    private func page(_ direction: CGFloat) {
        let metrics = state.metrics
        let step = max(metrics.width - margin - trailing - 40, 120)
        let target = min(max(metrics.offset + direction * step, metrics.minOffset), metrics.maxOffset)
        withAnimation(.smooth(duration: 0.45)) { state.position.scrollTo(x: target) }
    }
}

/// Fades an edge only while there is more content behind it. Applied only
/// when wanted: a mask also clips, which would cut off card shadows.
private struct EdgeFade: ViewModifier {
    let enabled: Bool
    let leading: Bool
    let trailing: Bool

    func body(content: Content) -> some View {
        if enabled {
            content.mask {
                HStack(spacing: 0) {
                    LinearGradient(colors: [.black.opacity(leading ? 0 : 1), .black],
                                   startPoint: .leading, endPoint: .trailing)
                        .frame(width: 36)
                    Color.black
                    LinearGradient(colors: [.black, .black.opacity(trailing ? 0 : 1)],
                                   startPoint: .leading, endPoint: .trailing)
                        .frame(width: 36)
                }
            }
        } else {
            content
        }
    }
}

final class SlidingRowState: ObservableObject {
    struct Metrics: Equatable {
        var offset: CGFloat = 0
        var minOffset: CGFloat = 0
        var maxOffset: CGFloat = 0
        var width: CGFloat = 0
    }

    @Published var position = ScrollPosition(edge: .leading)
    @Published var metrics = Metrics()
    @Published var hovering = false

    var canGoBack: Bool { metrics.offset > metrics.minOffset + 2 }
    var canGoForward: Bool { metrics.offset < metrics.maxOffset - 2 }
}

// MARK: - Scroll tracking

/// True while the enclosing page scrolls. Cards skip hover effects then, so
/// cards sliding under the pointer don't each fire a hover animation.
private struct IsScrollingKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    var isScrolling: Bool {
        get { self[IsScrollingKey.self] }
        set { self[IsScrollingKey.self] = newValue }
    }
}

final class ScrollActivity: ObservableObject {
    @Published var active = false
}

extension View {
    /// Publishes this scroll view's scrolling state to its content.
    func tracksScrolling(_ activity: ScrollActivity) -> some View {
        onScrollPhaseChange { _, phase in
            let scrolling = phase != .idle
            if activity.active != scrolling { activity.active = scrolling }
        }
        .environment(\.isScrolling, activity.active)
    }
}

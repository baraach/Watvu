import SwiftUI

/// Shared header for every sheet: optional artwork, title and subtitle on
/// the left, a round glass close button (Esc) on the right. No divider; the
/// sheet content starts right below.
struct SheetHeader<Leading: View>: View {
    let title: String
    var subtitle: String? = nil
    @ViewBuilder var leading: Leading
    let onClose: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            leading
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 20, weight: .bold))
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(1)
                if let subtitle, !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Theme.textSecondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 12)
            SheetCloseButton(action: onClose)
        }
        .padding(.horizontal, 20)
        .padding(.top, 18)
        .padding(.bottom, 12)
    }
}

extension SheetHeader where Leading == EmptyView {
    init(title: String, subtitle: String? = nil, onClose: @escaping () -> Void) {
        self.init(title: title, subtitle: subtitle, leading: { EmptyView() }, onClose: onClose)
    }
}

/// Round clear-glass ✕ button, bound to Esc.
struct SheetCloseButton: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "xmark")
                .font(.system(size: 12, weight: .bold))
                .frame(width: 22, height: 22)
        }
        .buttonBorderShape(.circle)
        .controlSize(.large)
        .glassButton()
        .keyboardShortcut(.cancelAction)
        .accessibilityLabel("Close")
        .help("Close (Esc)")
    }
}

/// Small rounded artwork tile used in sheet headers.
struct SheetArtwork: View {
    let key: String
    let logo: String?
    var size = CGSize(width: 46, height: 34)

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(Theme.gradient(for: key))
            if let logo, let url = URL(string: logo) {
                AsyncImage(url: url) { phase in
                    if case .success(let image) = phase {
                        image.resizable().scaledToFit().padding(5)
                    }
                }
            }
        }
        .frame(width: size.width, height: size.height)
        .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
    }
}

/// Simple sheet content wrapper: header with close button + content.
struct Sheet<Content: View>: View {
    let title: String
    var subtitle: String? = nil
    @ViewBuilder var content: Content
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            SheetHeader(title: title, subtitle: subtitle) { dismiss() }
            content
        }
        .frame(minWidth: 440, minHeight: 320)
    }
}

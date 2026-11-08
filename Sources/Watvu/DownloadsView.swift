import SwiftUI

struct DownloadsView: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject var downloadManager = DownloadManager.shared
    @StateObject private var ui = DownloadsUI()

    var body: some View {
        LibraryPage {
            PageHeader(title: L("Downloads"), subtitle: L("Offline playback")) {
                Button {
                    DownloadManager.shared.clearCompleted()
                } label: {
                    Label(L("Clear Completed"), systemImage: "trash")
                }
                .help(L("Clear Completed"))
            }
        } content: {
            if downloadManager.downloads.isEmpty {
                VStack(spacing: 16) {
                    Image(systemName: "arrow.down.circle")
                        .font(.system(size: 32))
                        .foregroundStyle(.secondary)
                    Text(L("No downloads yet"))
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.top, 80)
            } else {
                ScrollView(.vertical, showsIndicators: false) {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 292, maximum: 380), spacing: 20)], spacing: 24) {
                        ForEach(downloadManager.downloads) { download in
                            DownloadCard(download: download)
                                .onTapGesture {
                                    ui.selectedDownload = download
                                }
                        }
                    }
                    .padding(.horizontal, 28)
                    .padding(.top, 20)
                }
            }
        }
        .sheet(item: Binding(get: { ui.selectedDownload }, set: { ui.selectedDownload = $0 })) { download in
            DownloadDetailView(download: download)
        }
    }
}

private struct DownloadCard: View {
    let download: Download

    var body: some View {
        MediaCardContent(
            item: download.item,
            style: .landscape,
            now: nil,
            resume: download.progress,
            onActivate: {}
        )
        .overlay(alignment: .topTrailing) {
            statusBadge
                .padding(8)
        }
    }

    private var statusBadge: some View {
        Group {
            switch download.status {
            case .queued:
                Label(L("Queued"), systemImage: "clock")
            case .downloading:
                Label(L("Downloading"), systemImage: "arrow.down.circle.fill")
            case .paused:
                Label(L("Paused"), systemImage: "pause.circle.fill")
            case .completed:
                Label(L("Completed"), systemImage: "checkmark.circle.fill")
            case .failed:
                Label(L("Failed"), systemImage: "xmark.circle.fill")
            case .cancelled:
                Label(L("Cancelled"), systemImage: "xmark.circle.fill")
            }
        }
        .font(.system(size: 12, weight: .semibold))
        .foregroundStyle(.white)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(Color.black.opacity(0.7), in: Capsule())
    }
}

private struct DownloadDetailView: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject var downloadManager = DownloadManager.shared
    let download: Download
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        Sheet(title: download.item.name, subtitle: L("Download Details")) {
            VStack(spacing: 16) {
                MediaCard(item: download.item, style: .landscape)
                    .frame(height: 180)

                VStack(spacing: 8) {
                    ProgressView(value: download.progress, total: 1.0)
                        .progressViewStyle(.linear)

                    HStack {
                        Text("Status:")
                        Spacer()
                        Text(statusText)
                    }
                    .font(.system(size: 14))

                    if let error = download.error {
                        HStack {
                            Text("Error:")
                            Spacer()
                            Text(error)
                                .foregroundStyle(.red)
                        }
                        .font(.system(size: 14))
                    }
                }
                .padding(.horizontal, 16)

                Spacer()

                HStack(spacing: 16) {
                    if download.status == .completed {
                        Button(L("Play")) {
                            playDownload()
                        }
                        .controlSize(.large)
                        .buttonBorderShape(.capsule)
                        .glassProminentButton()
                    } else if download.status == .downloading || download.status == .queued {
                        Button(L("Cancel")) {
                            downloadManager.cancelDownload(download.id)
                        }
                        .controlSize(.large)
                        .buttonBorderShape(.capsule)
                        .glassButton()
                    } else if download.status == .downloading || download.status == .queued {
                        Button(L("Pause")) {
                            downloadManager.pauseDownload(download.id)
                        }
                        .controlSize(.large)
                        .buttonBorderShape(.capsule)
                        .glassButton()
                    } else if download.status == .paused {
                        Button(L("Resume")) {
                            downloadManager.resumeDownload(download.id)
                        }
                        .controlSize(.large)
                        .buttonBorderShape(.capsule)
                        .glassButton()
                    }

                    Button(L("Delete")) {
                        downloadManager.deleteDownload(download.id)
                        dismiss()
                    }
                    .controlSize(.large)
                    .buttonBorderShape(.capsule)
                    .glassDestructiveButton()
                }
                .padding(16)
            }
        }
    }

    private var statusText: String {
        switch download.status {
        case .queued: return L("Queued")
        case .downloading: return L("Downloading")
        case .paused: return L("Paused")
        case .completed: return L("Completed")
        case .failed: return L("Failed")
        case .cancelled: return L("Cancelled")
        }
    }

    private func playDownload() {
        guard let localURL = download.localURL else { return }
        
        var item = download.item
        item.streamURL = localURL.absoluteString
        _ = item
        
        model.activate(item)
        dismiss()
    }
}

private final class DownloadsUI: ObservableObject {
    @Published var selectedDownload: Download?
}

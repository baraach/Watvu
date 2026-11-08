import SwiftUI
import Combine

/// Progress of adding or updating a playlist, shown step by step.
@MainActor
final class SyncSession: ObservableObject, Identifiable {
    enum StepState { case pending, running, done, failed }
    struct Step: Identifiable {
        let id: String
        var state: StepState = .pending
    }

    let title: String
    @Published private(set) var steps: [Step]
    @Published var detail: String?
    @Published private(set) var errorText: String?
    @Published var isHidden = false

    init(title: String, steps: [String]) {
        self.title = title
        self.steps = steps.map { Step(id: $0) }
    }

    /// Marks earlier steps done and `step` running.
    func start(_ step: String) {
        guard let index = steps.firstIndex(where: { $0.id == step }) else { return }
        for i in steps.indices where i < index { steps[i].state = .done }
        steps[index].state = .running
        detail = nil
    }

    func finish() {
        for i in steps.indices { steps[i].state = .done }
    }

    func fail(_ message: String) {
        if let index = steps.firstIndex(where: { $0.state == .running }) { steps[index].state = .failed }
        errorText = message
        isHidden = false
    }
}

extension AppModel {
    enum SyncStep {
        static let checkLink = "Checking the playlist link"
        static let download = "Downloading and reading the list"
        static let checkServer = "Checking server status"
        static let live = "Fetching live channels"
        static let films = "Fetching films"
        static let series = "Fetching series"
        static let signIn = "Signing in"
        static let libraries = "Fetching libraries"
        static let organise = "Organising your library"
        static let save = "Saving information"
    }

    static var m3uSteps: [String] { [SyncStep.checkLink, SyncStep.download, SyncStep.organise, SyncStep.save] }
    static var xtreamSteps: [String] { [SyncStep.checkServer, SyncStep.live, SyncStep.films, SyncStep.series, SyncStep.organise, SyncStep.save] }
    static var serverSteps: [String] { [SyncStep.signIn, SyncStep.libraries, SyncStep.organise, SyncStep.save] }

    /// Shows the failure in the progress sheet, or as an alert if none is open.
    func reportSyncFailure(_ error: Error) {
        if let sync { sync.fail(error.localizedDescription) } else { errorMessage = error.localizedDescription }
    }

    /// The last steps of every sync: wait for the index and the save, then close.
    func finishSync(summaryFor playlistID: UUID) async {
        sync?.start(SyncStep.organise)
        await libraryIndexIsReady()
        sync?.start(SyncStep.save)
        await itemsAreSaved()
        let counts = (live: libraryIndex.live, movies: libraryIndex.movies, shows: libraryIndex.shows)
        let summary = [
            ("channels", counts.live.lazy.filter { $0.playlistID == playlistID }.count),
            ("films", counts.movies.lazy.filter { $0.playlistID == playlistID }.count),
            ("series", counts.shows.lazy.filter { $0.playlistID == playlistID }.count),
        ].filter { $0.1 > 0 }.map { "\($0.1.formatted()) \(L($0.0))" }.joined(separator: " · ")
        sync?.finish()
        sync?.detail = summary
        try? await Task.sleep(for: .seconds(1.5))
        sync = nil
    }
}

/// The "Syncing playlist" card. Long syncs can carry on in the background.
struct SyncProgressView: View {
    @ObservedObject var session: SyncSession
    let onClose: () -> Void

    var body: some View {
        ZStack {
            Color.black.opacity(0.25).ignoresSafeArea()
            VStack(spacing: 16) {
                Text(L(session.title))
                    .font(.system(size: 20, weight: .bold))
                    .foregroundStyle(Theme.textPrimary)
                VStack(alignment: .leading, spacing: 6) {
                    Text(L("Status"))
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Theme.textSecondary)
                        .padding(.leading, 4)
                    VStack(alignment: .leading, spacing: 14) {
                        ForEach(session.steps) { step in
                            HStack(spacing: 10) {
                                icon(step.state).frame(width: 18, height: 18)
                                Text(L(step.id))
                                    .font(.system(size: 14))
                                    .foregroundStyle(step.state == .pending ? Theme.textSecondary : Theme.textPrimary)
                                Spacer(minLength: 0)
                            }
                        }
                    }
                    .padding(16)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                }
                if let detail = session.detail {
                    Text(detail)
                        .font(.system(size: 12, weight: .medium))
                        .monospacedDigit()
                        .foregroundStyle(Theme.textSecondary)
                }
                if let error = session.errorText {
                    Text(error)
                        .font(.system(size: 12))
                        .foregroundStyle(.red)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                    Button(L("Close"), action: onClose)
                        .buttonBorderShape(.capsule)
                        .glassButton()
                } else {
                    Button(L("Continue in background")) { session.isHidden = true }
                        .buttonStyle(.plain)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Theme.textSecondary)
                }
            }
            .padding(24)
            .frame(width: 400)
            .background(Theme.background, in: RoundedRectangle(cornerRadius: 26, style: .continuous))
            .shadow(color: .black.opacity(0.25), radius: 30, y: 12)
        }
        .transition(.opacity)
    }

    @ViewBuilder
    private func icon(_ state: SyncSession.StepState) -> some View {
        switch state {
        case .pending:
            Circle().stroke(Theme.textSecondary.opacity(0.4), lineWidth: 1.5).padding(3)
        case .running:
            ProgressView().controlSize(.small)
        case .done:
            Image(systemName: "checkmark").font(.system(size: 13, weight: .bold)).foregroundStyle(.green)
        case .failed:
            Image(systemName: "xmark").font(.system(size: 13, weight: .bold)).foregroundStyle(.red)
        }
    }
}

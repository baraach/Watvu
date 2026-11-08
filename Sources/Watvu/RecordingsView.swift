import SwiftUI

struct RecordingsView: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject var recordingManager = RecordingManager.shared
    @StateObject private var ui = RecordingsUI()

    var body: some View {
        LibraryPage {
            PageHeader(title: L("Recordings"), subtitle: L("Live TV recordings")) {
                Button {
                    RecordingManager.shared.clearCompleted()
                } label: {
                    Label(L("Clear Completed"), systemImage: "trash")
                }
                .help(L("Clear Completed"))
            }
        } content: {
            VStack(spacing: 24) {
                if !recordingManager.scheduled.isEmpty {
                    scheduledRecordingsSection
                }
                
                if !recordingManager.recordings.isEmpty {
                    recordingsSection
                }
                
                if recordingManager.scheduled.isEmpty && recordingManager.recordings.isEmpty {
                    emptyState
                }
            }
            .padding(.top, 20)
        }
        .sheet(item: Binding(get: { ui.selectedRecording }, set: { ui.selectedRecording = $0 })) { recording in
            RecordingDetailView(recording: recording)
        }
        .sheet(item: Binding(get: { ui.selectedScheduledRecording }, set: { ui.selectedScheduledRecording = $0 })) { scheduledRecording in
            ScheduledRecordingDetailView(scheduledRecording: scheduledRecording)
        }
    }

    private var scheduledRecordingsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(L("Scheduled Recordings"))
                .font(.system(size: 18, weight: .semibold))
                .padding(.horizontal, 28)

            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: 16) {
                    ForEach(recordingManager.scheduled) { scheduledRecording in
                        ScheduledRecordingCard(scheduledRecording: scheduledRecording)
                            .onTapGesture {
                                ui.selectedScheduledRecording = scheduledRecording
                            }
                    }
                }
                .padding(.horizontal, 28)
            }
        }
    }

    private var recordingsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(L("Recorded Content"))
                .font(.system(size: 18, weight: .semibold))
                .padding(.horizontal, 28)

            ScrollView(.vertical, showsIndicators: false) {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 292, maximum: 380), spacing: 20)], spacing: 24) {
                    ForEach(recordingManager.recordings) { recording in
                        RecordingCard(recording: recording)
                            .onTapGesture {
                                ui.selectedRecording = recording
                            }
                    }
                }
                .padding(.horizontal, 28)
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 16) {
            Image(systemName: "recordingtape")
                .font(.system(size: 32))
                .foregroundStyle(.secondary)
            Text(L("No recordings yet"))
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 80)
    }
}

private struct ScheduledRecordingCard: View {
    let scheduledRecording: ScheduledRecording

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(scheduledRecording.program.title)
                .font(.system(size: 14, weight: .semibold))
                .lineLimit(1)

            Text(scheduledRecording.channel.name)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .lineLimit(1)

            Text("\(scheduledRecording.program.start.formatted(date: .omitted, time: .shortened)) - \(scheduledRecording.program.end.formatted(date: .omitted, time: .shortened))")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
        }
        .frame(width: 200, height: 100)
        .padding(12)
        .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 12))
    }
}

private struct RecordingCard: View {
    let recording: Recording

    var body: some View {
        MediaCardContent(
            item: recording.channel,
            style: .landscape,
            now: nil,
            resume: recording.progress,
            onActivate: {}
        )
        .overlay(alignment: .topTrailing) {
            statusBadge
                .padding(8)
        }
    }

    private var statusBadge: some View {
        Group {
            switch recording.status {
            case .recording:
                Label(L("Recording"), systemImage: "record.circle.fill")
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

private struct RecordingDetailView: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject var recordingManager = RecordingManager.shared
    let recording: Recording
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        Sheet(title: recording.program.title, subtitle: L("Recording Details")) {
            VStack(spacing: 16) {
                MediaCard(item: recording.channel, style: .landscape)
                    .frame(height: 180)

                VStack(spacing: 8) {
                    ProgressView(value: recording.progress, total: 1.0)
                        .progressViewStyle(.linear)

                    HStack {
                        Text("Status:")
                        Spacer()
                        Text(statusText)
                    }
                    .font(.system(size: 14))

                    if let error = recording.error {
                        HStack {
                            Text("Error:")
                            Spacer()
                            Text(error)
                                .foregroundStyle(.red)
                        }
                        .font(.system(size: 14))
                    }

                    HStack {
                        Text("Channel:")
                        Spacer()
                        Text(recording.channel.name)
                    }
                    .font(.system(size: 14))

                    HStack {
                        Text("Time:")
                        Spacer()
                        Text("\(recording.program.start.formatted(date: .omitted, time: .shortened)) - \(recording.program.end.formatted(date: .omitted, time: .shortened))")
                    }
                    .font(.system(size: 14))
                }
                .padding(.horizontal, 16)

                Spacer()

                HStack(spacing: 16) {
                    if recording.status == .completed {
                        Button(L("Play")) {
                            playRecording()
                        }
                        .controlSize(.large)
                        .buttonBorderShape(.capsule)
                        .glassProminentButton()
                    }

                    Button(L("Delete")) {
                        recordingManager.deleteRecording(recording.id)
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
        switch recording.status {
        case .recording: return L("Recording")
        case .completed: return L("Completed")
        case .failed: return L("Failed")
        case .cancelled: return L("Cancelled")
        }
    }

    private func playRecording() {
        guard let localURL = recording.localURL else { return }
        
        var item = recording.channel
        item.streamURL = localURL.absoluteString
        item.name = recording.program.title
        model.activate(item)
        dismiss()
    }
}

private struct ScheduledRecordingDetailView: View {
    @ObservedObject var recordingManager = RecordingManager.shared
    let scheduledRecording: ScheduledRecording
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        Sheet(title: scheduledRecording.program.title, subtitle: L("Scheduled Recording")) {
            VStack(spacing: 16) {
                MediaCard(item: scheduledRecording.channel, style: .landscape)
                    .frame(height: 180)

                VStack(spacing: 8) {
                    HStack {
                        Text("Channel:")
                        Spacer()
                        Text(scheduledRecording.channel.name)
                    }
                    .font(.system(size: 14))

                    HStack {
                        Text("Time:")
                        Spacer()
                        Text("\(scheduledRecording.program.start.formatted(date: .omitted, time: .shortened)) - \(scheduledRecording.program.end.formatted(date: .omitted, time: .shortened))")
                    }
                    .font(.system(size: 14))
                }
                .padding(.horizontal, 16)

                Spacer()

                HStack(spacing: 16) {
                    Button(L("Cancel")) {
                        recordingManager.cancelRecording(scheduledRecording.id)
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
}

private final class RecordingsUI: ObservableObject {
    @Published var selectedRecording: Recording?
    @Published var selectedScheduledRecording: ScheduledRecording?
}

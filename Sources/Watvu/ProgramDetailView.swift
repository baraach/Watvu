import SwiftUI
import UserNotifications

struct ProgramDetailItem: Identifiable {
    var id: String { "\(channel.id)|\(program.id)" }
    let channel: MediaItem
    let program: EPGProgram
}

/// Programme details from the guide: description, times, live/catch-up
/// playback, and (for upcoming programmes) a local reminder.
struct ProgramDetailSheet: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    let item: ProgramDetailItem

    @StateObject private var reminder = ReminderState()

    private var program: EPGProgram { item.program }
    private var channel: MediaItem { item.channel }

    private var isNow: Bool {
        program.start <= Date() && Date() < program.end
    }

    private var canCatchup: Bool {
        model.canCatchup(channel, program)
    }

    private var isFuture: Bool {
        program.start > Date()
    }

    private var duration: String {
        let minutes = max(0, Int(program.end.timeIntervalSince(program.start) / 60))
        if minutes >= 60 {
            let h = minutes / 60, m = minutes % 60
            return m == 0 ? "\(h) hr" : "\(h) hr \(m) min"
        }
        return "\(minutes) min"
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 16) {
                    Text(program.title)
                        .font(.system(size: 28, weight: .bold))
                        .foregroundStyle(Theme.textPrimary)
                        .fixedSize(horizontal: false, vertical: true)

                    HStack(spacing: 8) {
                        if isNow {
                            badge("LIVE", color: Theme.accent)
                        } else if canCatchup {
                            badge("CATCH-UP", color: Theme.accent)
                        } else if isFuture {
                            badge("UPCOMING", color: Theme.textSecondary)
                        }
                        Text("\(program.timeRange) · \(duration)")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(Theme.textSecondary)
                        if let category = program.category, !category.isEmpty {
                            Text("·")
                                .foregroundStyle(Theme.textSecondary)
                            Text(category)
                                .font(.system(size: 13, weight: .medium))
                                .foregroundStyle(Theme.textSecondary)
                        }
                    }

                    if let subtitle = program.subtitle, !subtitle.isEmpty {
                        Text(subtitle)
                            .font(.system(size: 15, weight: .medium))
                            .foregroundStyle(Theme.textPrimary)
                    }

                    Text(program.description?.isEmpty == false ? program.description! : "No description available.")
                        .font(.system(size: 15))
                        .foregroundStyle(Theme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)

                    if let message = reminder.message {
                        Label(message, systemImage: reminder.failed ? "exclamationmark.triangle.fill" : "bell.badge.fill")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(reminder.failed ? .red : Theme.textSecondary)
                    }
                }
                .padding(24)
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            footer
        }
        .frame(width: 640, height: 480)
        .background(Theme.background)
    }

    private var header: some View {
        SheetHeader(title: channel.name, subtitle: channel.group) {
            SheetArtwork(key: channel.group, logo: channel.logo, size: CGSize(width: 54, height: 38))
        } onClose: { dismiss() }
    }

    @ViewBuilder
    private var footer: some View {
        HStack(spacing: 10) {
            if isNow {
                Button {
                    model.activate(channel)
                    dismiss()
                } label: {
                    Label("Watch Live", systemImage: "play.fill")
                }
                .controlSize(.large)
                .buttonBorderShape(.capsule)
                .glassProminentButton()
            } else if canCatchup {
                Button {
                    model.playCatchup(channel, program)
                    dismiss()
                } label: {
                    Label("Watch from Archive", systemImage: "gobackward")
                }
                .controlSize(.large)
                .buttonBorderShape(.capsule)
                .glassProminentButton()
            }

            if isNow || isFuture {
                Button {
                    RecordingManager.shared.scheduleRecording(program, channel: channel)
                } label: {
                    Label("Record", systemImage: "record.circle")
                }
                .controlSize(.large)
                .buttonBorderShape(.capsule)
                .glassButton()
            }

            if isFuture {
                Button {
                    Task { await reminder.schedule(program: program, channel: channel) }
                } label: {
                    Label(reminder.scheduled ? "Reminder Set" : "Remind Me", systemImage: "bell")
                }
                .controlSize(.large)
                .buttonBorderShape(.capsule)
                .glassButton()
                .disabled(reminder.scheduled || reminder.working)
            }

            Spacer()
        }
        .padding(20)
    }

    private func badge(_ text: String, color: Color) -> some View {
        Text(text)
            .font(.system(size: 10, weight: .bold))
            .tracking(0.8)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(color.opacity(0.14), in: Capsule())
            .foregroundStyle(color)
    }
}

private final class ReminderState: ObservableObject {
    @Published var working = false
    @Published var scheduled = false
    @Published var failed = false
    @Published var message: String?

    @MainActor
    func schedule(program: EPGProgram, channel: MediaItem) async {
        working = true
        failed = false
        message = nil
        defer { working = false }

        do {
            guard try await Reminders.schedule(
                id: "program-\(program.id)", title: channel.name,
                body: "\(program.title) starts at \(program.start.formatted(date: .omitted, time: .shortened)).",
                at: program.start
            ) else {
                failed = true
                message = "Notifications are disabled in System Settings."
                return
            }
            scheduled = true
            message = program.start.addingTimeInterval(-300).timeIntervalSinceNow > 2
                ? "Reminder set for 5 minutes before." : "Starts soon — reminder sent now."
        } catch {
            failed = true
            message = "Couldn’t set reminder: \(error.localizedDescription)"
        }
    }
}

/// Programme and event reminders: a notification 5 minutes before `start`,
/// or straight away if that's already past.
enum Reminders {
    /// Returns false when notifications are turned off for the app.
    @discardableResult
    static func schedule(id: String, title: String, body: String, at start: Date) async throws -> Bool {
        let center = UNUserNotificationCenter.current()
        guard try await center.requestAuthorization(options: [.alert, .sound]) else { return false }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        // Seconds-from-now trigger: a minute-precision calendar trigger for
        // the current minute never fires (programme < 5 min away).
        let lead = start.addingTimeInterval(-300).timeIntervalSinceNow
        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: max(lead, 2), repeats: false)
        try await center.add(UNNotificationRequest(identifier: id, content: content, trigger: trigger))
        return true
    }
}

import SwiftUI
import UniformTypeIdentifiers
import Combine

private final class AddPlaylistForm: ObservableObject {
    @Published var kind: PlaylistKind = .m3u

    init(initialURL: String, initialName: String, initialKind: PlaylistKind, initialUsesFile: Bool) {
        self.url = initialURL
        self.name = initialName
        self.kind = initialKind
        self.useFile = initialUsesFile
    }
    @Published var useFile = false
    @Published var name = ""
    @Published var url = ""
    @Published var epgURL = ""
    @Published var username = ""
    @Published var password = ""
    @Published var fileURL: URL?
    @Published var isWorking = false
    @Published var errorText: String?
    @Published var showingFilePicker = false
    @Published var plexStatus: String?
}

struct AddPlaylistView: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    var initialURL = ""
    var initialName = ""
    @StateObject private var form: AddPlaylistForm

    init(initialURL: String = "", initialName: String = "", initialKind: PlaylistKind = .m3u, initialUsesFile: Bool = false) {
        self.initialURL = initialURL
        self.initialName = initialName
        _form = StateObject(wrappedValue: AddPlaylistForm(initialURL: initialURL, initialName: initialName,
                                                          initialKind: initialKind, initialUsesFile: initialUsesFile))
    }

    private var needsCredentials: Bool { form.kind != .m3u }
    private var canSubmit: Bool {
        guard !form.isWorking else { return false }
        let hasURL = !form.url.trimmed.isEmpty, hasUser = !form.username.trimmed.isEmpty
        switch form.kind {
        case .m3u: return form.useFile ? form.fileURL != nil : hasURL
        case .xtream, .smb: return hasURL && hasUser && !form.password.isEmpty
        case .jellyfin, .emby: return hasURL && hasUser   // accounts may have no password
        case .plex: return !form.password.isEmpty         // the token; the address is optional
        }
    }

    var body: some View {
        Sheet(title: L("Add Playlist"), subtitle: L("M3U, Xtream, Jellyfin, Emby, Plex or SMB")) {
            VStack(spacing: 16) {
                DropdownField(
                    title: L("Playlist type"),
                    options: PlaylistKind.allCases.map { DropdownOption(value: $0, title: L($0.title), symbol: $0.symbol) },
                    selection: $form.kind,
                    width: 240
                )

                if form.kind == .m3u {
                    Toggle(L("Local file"), isOn: $form.useFile)
                        .padding(.horizontal, 16)
                }

                VStack(spacing: 10) {
                    if form.useFile && form.kind == .m3u {
                        Button(L("Select M3U File")) { form.showingFilePicker = true }
                            .buttonBorderShape(.capsule)
                            .glassButton()
                        if let fileURL = form.fileURL {
                            Text(fileURL.lastPathComponent).font(.caption).foregroundStyle(.secondary)
                        }
                    } else if form.kind == .plex {
                        Button {
                            signInWithPlex()
                        } label: {
                            Label(L("Sign in with Plex"), systemImage: "person.badge.key")
                        }
                        .controlSize(.large)
                        .buttonBorderShape(.capsule)
                        .glassProminentButton()
                        .disabled(form.isWorking)
                        if let status = form.plexStatus {
                            Text(status).font(.caption).foregroundStyle(.secondary)
                        }
                        Text(L("Or connect with a token:")).font(.caption).foregroundStyle(.secondary)
                        SecureField(L("Plex token"), text: $form.password)
                            .textFieldStyle(.roundedBorder)
                        TextField(L("Server address (optional, e.g. http://192.168.1.10:32400)"), text: $form.url)
                            .textFieldStyle(.roundedBorder)
                    } else {
                        TextField(L("Server / Playlist URL"), text: $form.url)
                            .textFieldStyle(.roundedBorder)
                        if form.kind == .m3u {
                            TextField(L("EPG URL (optional)"), text: $form.epgURL)
                                .textFieldStyle(.roundedBorder)
                        }
                        if needsCredentials {
                            TextField(L("Username"), text: $form.username)
                                .textFieldStyle(.roundedBorder)
                            SecureField(L("Password"), text: $form.password)
                                .textFieldStyle(.roundedBorder)
                        }
                    }
                    TextField(L("Name (optional)"), text: $form.name)
                        .textFieldStyle(.roundedBorder)

                    if let errorText = form.errorText {
                        Text(errorText).font(.caption).foregroundStyle(.red)
                    }
                }
                .padding(.horizontal, 16)

                Spacer()

                HStack(spacing: 16) {
                    Button(L("Cancel")) { dismiss() }
                        .controlSize(.large)
                        .buttonBorderShape(.capsule)
                        .glassButton()
                    Button(L("Add")) { add() }
                        .controlSize(.large)
                        .buttonBorderShape(.capsule)
                        .glassProminentButton()
                        .disabled(!canSubmit)
                }
                .padding(16)
            }
            .fileImporter(isPresented: Binding(get: { form.showingFilePicker }, set: { form.showingFilePicker = $0 }), allowedContentTypes: [.text, .plainText], allowsMultipleSelection: false) { result in
                if case .success(let urls) = result, let url = urls.first { form.fileURL = url }
            }
        }
    }


    /// Opens plex.tv to approve a PIN, waits for the token, then adds the server.
    private func signInWithPlex() {
        form.isWorking = true
        form.errorText = nil
        Task {
            do {
                let pin = try await PlexAuth.requestPIN()
                NSWorkspace.shared.open(PlexAuth.approvalURL(for: pin))
                form.plexStatus = L("Approve the sign-in in your browser…")
                let token = try await PlexAuth.waitForToken(pin: pin)
                dismiss()
                do { try await model.addPlex(name: form.name, token: token, address: form.url) }
                catch { model.reportSyncFailure(error) }
            } catch {
                form.errorText = error.localizedDescription
                form.plexStatus = nil
                form.isWorking = false
            }
        }
    }

    private func add() {
        let form = self.form
        let model = self.model
        dismiss()
        Task {
            do {
                switch form.kind {
                case .m3u:
                    if form.useFile, let fileURL = form.fileURL {
                        try await model.addM3UFile(name: form.name, fileURL: fileURL, epgURL: form.epgURL)
                    } else {
                        try await model.addM3U(name: form.name, urlString: form.url, epgURL: form.epgURL)
                    }
                case .xtream:
                    try await model.addXtream(name: form.name, server: form.url, username: form.username, password: form.password)
                case .jellyfin, .emby:
                    try await model.addMediaServer(form.kind, name: form.name, server: form.url, username: form.username, password: form.password)
                case .plex:
                    try await model.addPlex(name: form.name, token: form.password, address: form.url)
                case .smb:
                    try await model.addSMB(name: form.name, server: form.url, username: form.username, password: form.password)
                }
            } catch {
                model.reportSyncFailure(error)
            }
        }
    }
}

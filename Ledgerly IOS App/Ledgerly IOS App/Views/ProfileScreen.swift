import SwiftUI
import FirebaseAuth
import PhotosUI

/// Profile editing contains personal details only. Sign-in and security actions
/// live on the Account security screen, outside the name-editing form.
struct ProfileScreen: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var auth: AuthSession
    @State private var name = ""
    @State private var selectedPhoto: PhotosPickerItem?
    @State private var photoData: Data?
    @State private var removingPhoto = false
    @State private var loadingPhoto = false
    @State private var loadedAccountID: String?
    @State private var loaded = false
    @State private var message: String?
    @State private var confirmingDiscard = false
    @FocusState private var nameFocused: Bool

    private var cleanName: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var hasChanges: Bool { cleanName != (auth.user?.displayName ?? "") || photoData != nil || removingPhoto }

    var body: some View {
        Form {
            if let user = auth.user {
                Section {
                    VStack(spacing: 12) {
                        if let photoData, let image = UIImage(data: photoData) {
                            Image(uiImage: image).resizable().scaledToFill().frame(width: 80, height: 80).clipShape(Circle())
                        } else {
                            AccountAvatar(accountID: removingPhoto ? nil : user.uid, name: user.displayName,
                                          photoURL: auth.profilePhotoURL, size: 80)
                        }
                        PhotosPicker(selection: $selectedPhoto, matching: .images) {
                            Label("Choose profile photo", systemImage: "photo")
                        }
                        .disabled(auth.isBusy || loadingPhoto)
                        if loadingPhoto { ProgressView("Loading photo…") }
                        if photoData != nil || AccountPhotoStore.data(user.uid) != nil {
                            Button("Use sign-in photo or initials") { photoData = nil; removingPhoto = true }
                        }
                        Text(auth.profileName).font(.title3.bold())
                        Text("Choose a photo for your Ledgerly profile, or use the photo from your sign-in account.")
                            .font(.footnote).foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }
                    .frame(maxWidth: .infinity).padding(.vertical, 12)
                }
                Section {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Display name").font(.subheadline).foregroundStyle(.secondary)
                        TextField("Your name", text: $name)
                            .textContentType(.name)
                            .textInputAutocapitalization(.words)
                            .focused($nameFocused)
                            .submitLabel(.done)
                            .onSubmit { nameFocused = false }
                            .accessibilityLabel("Display name")
                    }
                    .padding(.vertical, 4)
                    if cleanName.count > 80 {
                        Text("Use 80 characters or fewer.").font(.footnote).foregroundStyle(.red)
                    }
                } header: {
                    Text("Personal information")
                } footer: {
                    Text("Your name is saved to your Ledgerly account. An internet connection is required.")
                }
                .disabled(auth.isBusy)
                Section {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Email address").font(.subheadline).foregroundStyle(.secondary)
                        Text(user.email ?? "Not provided").textSelection(.enabled)
                    }.padding(.vertical, 4)
                } header: {
                    Text("Account email")
                } footer: {
                    Text("Manage your email address and sign-in details in Account security.")
                }
                if let message {
                    Section {
                        Label(message, systemImage: "exclamationmark.circle")
                            .foregroundStyle(.red)
                    }
                }
            } else {
                ContentUnavailableView("Sign in to edit your profile", systemImage: "person.crop.circle",
                                       description: Text("Return to Settings to sign in."))
            }
        }
        .navigationTitle("Edit profile")
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden(true)
        .scrollDismissesKeyboard(.interactively)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") {
                    if hasChanges { confirmingDiscard = true } else { dismiss() }
                }.disabled(auth.isBusy)
            }
            ToolbarItem(placement: .confirmationAction) {
                if auth.isBusy {
                    ProgressView().accessibilityLabel("Saving profile")
                } else {
                    Button("Save") { Task { await saveName() } }
                        .disabled(loadingPhoto || !loaded || !hasChanges || cleanName.isEmpty || cleanName.count > 80)
                }
            }
        }
        .confirmationDialog("Discard profile changes?", isPresented: $confirmingDiscard, titleVisibility: .visible) {
            Button("Discard changes", role: .destructive) { dismiss() }
            Button("Keep editing", role: .cancel) { }
        }
        .onAppear {
            guard !loaded else { return }
            loaded = true
            loadedAccountID = auth.user?.uid
            name = auth.user?.displayName ?? ""
        }
        .onChange(of: selectedPhoto) { _, item in
            guard let item, let owner = loadedAccountID else { return }
            loadingPhoto = true
            Task {
                defer { loadingPhoto = false; selectedPhoto = nil }
                do {
                    guard let data = try await item.loadTransferable(type: Data.self) else { throw CocoaError(.fileReadCorruptFile) }
                    guard auth.user?.uid == owner else { return }
                    photoData = try AccountPhotoStore.preparedData(data); removingPhoto = false
                } catch { message = "Could not load that photo. Choose another image." }
            }
        }
        .onChange(of: auth.user?.uid) { _, _ in
            name = ""
            message = nil
            dismiss()
        }
    }

    @MainActor
    private func saveName() async {
        guard let loadedAccountID else { return }
        nameFocused = false
        message = nil
        do {
            if cleanName != (auth.user?.displayName ?? "") {
                try await auth.updateDisplayName(name, expectedAccountID: loadedAccountID)
            }
            if photoData != nil || removingPhoto {
                try auth.updateCustomPhoto(photoData, expectedAccountID: loadedAccountID)
            }
            dismiss()
        } catch {
            message = auth.accountErrorMessage(error)
        }
    }
}

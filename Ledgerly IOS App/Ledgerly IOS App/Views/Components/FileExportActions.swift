import SwiftUI
import UniformTypeIdentifiers
import UIKit

private struct ExportFileDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.pdf, .commaSeparatedText, .json] }
    let data: Data

    init(data: Data) { self.data = data }
    init(configuration: ReadConfiguration) throws {
        guard let contents = configuration.file.regularFileContents else {
            throw CocoaError(.fileReadCorruptFile)
        }
        data = contents
    }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}

private struct ExportActivitySheet: UIViewControllerRepresentable {
    let url: URL
    let onComplete: (String?) -> Void

    func makeUIViewController(context: Context) -> UIActivityViewController {
        let controller = UIActivityViewController(activityItems: [url], applicationActivities: nil)
        controller.completionWithItemsHandler = { _, _, _, error in
            let message = error == nil ? nil : "Could not share this file. Try another sharing option."
            Task { @MainActor in onComplete(message) }
        }
        // SwiftUI owns presentation; provide a valid anchor for iPad popovers too.
        if let popover = controller.popoverPresentationController {
            popover.sourceView = controller.view
            popover.sourceRect = CGRect(x: controller.view.bounds.midX,
                                        y: controller.view.bounds.maxY, width: 1, height: 1)
            popover.permittedArrowDirections = []
        }
        return controller
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) { }
}

/// Shared save/share controls for an already prepared, immutable local file.
struct FileExportActions: View {
    let url: URL
    let contents: Data
    let contentType: UTType
    @Binding var isPresenting: Bool
    @State private var showingSave = false
    @State private var showingShare = false
    @State private var shareError: String?
    @State private var exportError: String?
    @State private var saveConfirmation: String?

    private var savePresentation: Binding<Bool> {
        Binding(get: { showingSave }, set: {
            showingSave = $0
            isPresenting = $0 || showingShare
        })
    }

    private var sharePresentation: Binding<Bool> {
        Binding(get: { showingShare }, set: {
            showingShare = $0
            isPresenting = $0 || showingSave
        })
    }

    var body: some View {
        VStack(spacing: 12) {
            if let saveConfirmation {
                Label(saveConfirmation, systemImage: "checkmark.circle.fill")
                    .font(.callout).foregroundStyle(.secondary)
            }
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 12) { saveButton; shareButton }
                VStack(spacing: 12) { saveButton; shareButton }
            }
        }
        .padding()
        .frame(maxWidth: .infinity)
        .background(.bar)
        .fileExporter(isPresented: savePresentation,
                      document: ExportFileDocument(data: contents),
                      contentType: contentType,
                      defaultFilename: url.deletingPathExtension().lastPathComponent) { result in
            switch result {
            case .success(let savedURL): saveConfirmation = "Saved \(savedURL.lastPathComponent)"
            case .failure(let error):
                if (error as NSError).code != NSUserCancelledError {
                    exportError = "Could not save this file. Choose another folder and try again."
                }
            }
        }
        .sheet(isPresented: sharePresentation, onDismiss: {
            exportError = shareError
            shareError = nil
        }) {
            ExportActivitySheet(url: url) { error in
                shareError = error
                sharePresentation.wrappedValue = false
            }
        }
        .alert("Could not export report", isPresented: Binding(
            get: { exportError != nil }, set: { if !$0 { exportError = nil } }
        )) {
            Button("OK") { exportError = nil }
        } message: {
            Text(exportError ?? "Please try again.")
        }
    }

    private var saveButton: some View {
        Button {
            savePresentation.wrappedValue = true
        } label: {
            Label("Save to Files", systemImage: "folder")
                .frame(maxWidth: .infinity).fixedSize(horizontal: true, vertical: false)
        }
        .buttonStyle(.borderedProminent)
        .disabled(showingShare || showingSave)
    }

    private var shareButton: some View {
        Button {
            sharePresentation.wrappedValue = true
        } label: {
            Label("Share", systemImage: "square.and.arrow.up")
                .frame(maxWidth: .infinity).fixedSize(horizontal: true, vertical: false)
        }
        .buttonStyle(.bordered)
        .disabled(showingShare || showingSave)
    }
}

// FileImportButton.swift — drop-in "Import" control backed by FileImportHandler.
//
// Lets the user pick game images or a .PUP firmware file from anywhere in Files
// and copies them into the app's own sandbox. Because the copy path owns the
// file afterwards, the imported library survives any re-sign — unlike the
// bookmark/app-group approaches that leave other sideloaded emulators unable to
// select their firmware after the signer changes.

import SwiftUI
import UniformTypeIdentifiers

struct FileImportButton<Label: View>: View {
    var handler: FileImportHandler = .shared
    @ViewBuilder var label: () -> Label

    @State private var picking = false
    @State private var showResults = false

    var body: some View {
        Button { picking = true } label: { label() }
            .disabled(handler.isImporting)
            // `.item` accepts any file: game images and .PUP firmware alike.
            // FileImportHandler classifies and routes each one; anything it does
            // not recognise comes back as a clear per-file error, never a crash.
            .fileImporter(isPresented: $picking,
                          allowedContentTypes: [.item],
                          allowsMultipleSelection: true) { result in
                switch result {
                case .success(let urls):
                    Task {
                        await handler.importFiles(urls)
                        await MainActor.run { showResults = true }
                    }
                case .failure(let error):
                    NSLog("[iPS3 Import] picker failed: %@", error.localizedDescription)
                }
            }
            .alert("Import", isPresented: $showResults) {
                Button("OK", role: .cancel) { }
            } message: {
                Text(handler.lastResults.isEmpty
                     ? "Nothing was imported."
                     : handler.lastResults.map(\.message).joined(separator: "\n"))
            }
    }
}

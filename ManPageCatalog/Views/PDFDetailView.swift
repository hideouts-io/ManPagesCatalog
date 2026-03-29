import SwiftUI
import PDFKit

struct PDFDetailView: View {
    let url: URL
    let title: String
    let sourcePath: String?
    let executablePath: String?

    var body: some View {
        if FileManager.default.fileExists(atPath: url.path) {
            VStack(spacing: 0) {
                // Source path + executable path info bar
                if sourcePath != nil || executablePath != nil {
                    VStack(spacing: 0) {
                        if let exec = executablePath, !exec.isEmpty {
                            infoRow(icon: "terminal", label: "Run:", value: exec)
                            Divider().padding(.leading, 32)
                        }
                        if let src = sourcePath, !src.isEmpty {
                            infoRow(icon: "doc.plaintext", label: "Source:", value: src)
                        }
                    }
                    .background(.bar)
                    Divider()
                }
                PDFKitView(url: url)
            }
            .navigationTitle(title)
            .toolbar {
                ToolbarItem {
                    Button {
                        NSWorkspace.shared.open(url)
                    } label: {
                        Label("Open in Preview", systemImage: "arrow.up.forward.app")
                    }
                    .help("Open in Preview.app")
                }
            }
        } else {
            VStack(spacing: 12) {
                Image(systemName: "exclamationmark.triangle")
                    .font(.system(size: 48))
                    .foregroundStyle(.secondary)
                Text("PDF Not Found")
                    .font(.title2).fontWeight(.semibold)
                Text("Run Generate to create PDFs for all man pages.")
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
    @ViewBuilder
    private func infoRow(icon: String, label: String, value: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 16)
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.primary)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer()
            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(value, forType: .string)
            } label: {
                Image(systemName: "doc.on.doc")
                    .font(.caption)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help("Copy")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 5)
    }
}

struct PDFKitView: NSViewRepresentable {
    let url: URL

    func makeNSView(context: Context) -> PDFView {
        let pdfView = PDFView()
        pdfView.autoScales = true
        pdfView.displayMode = .singlePageContinuous
        pdfView.displayDirection = .vertical
        return pdfView
    }

    func updateNSView(_ pdfView: PDFView, context: Context) {
        if let doc = PDFDocument(url: url) {
            pdfView.document = doc
        }
    }
}

import SwiftUI
import PDFKit

struct PDFDetailView: View {
    let url: URL
    let title: String
    let sourcePath: String?
    let executablePath: String?
    let revision: Int
    @StateObject private var reader = PDFReader()
    @State private var showFind = false
    @State private var findQuery = ""
    @FocusState private var findFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            if let exec = executablePath, !exec.isEmpty {
                infoRow(icon: "terminal", label: "Executable", value: exec, identifier: "copyExecutable")
            }
            if let source = sourcePath, !source.isEmpty {
                infoRow(icon: "doc.plaintext", label: "Source", value: source, identifier: "copySource")
            }
            HStack {
                Text(title).font(.headline).accessibilityIdentifier("readerTitle")
                Spacer()
                Button("Find in Page") { openFind() }.accessibilityIdentifier("showReaderFind")
                Button("Open in Preview") { NSWorkspace.shared.open(url) }
                    .disabled(reader.errorMessage != nil).accessibilityIdentifier("openPreview")
            }.padding(10)
            if showFind {
                HStack {
                    TextField("Find in \(title)…", text: $findQuery)
                        .textFieldStyle(.roundedBorder).focused($findFocused)
                        .accessibilityIdentifier("readerFind")
                        .onSubmit { reader.nextMatch() }
                    Text(reader.searching ? "Searching…" : "\(reader.matchIndex) of \(reader.matchCount)")
                        .font(.caption).accessibilityIdentifier("readerMatchCount")
                    Button { reader.previousMatch() } label: { Image(systemName: "chevron.up") }
                        .accessibilityLabel("Previous match").accessibilityIdentifier("previousMatch")
                        .disabled(reader.matchCount == 0 || reader.searching)
                    Button { reader.nextMatch() } label: { Image(systemName: "chevron.down") }
                        .accessibilityLabel("Next match").accessibilityIdentifier("nextMatch")
                        .disabled(reader.matchCount == 0 || reader.searching)
                    Button { closeFind() } label: { Image(systemName: "xmark") }
                        .accessibilityLabel("Close Find").accessibilityIdentifier("closeReaderFind")
                }.padding(.horizontal, 10).padding(.bottom, 8)
            }
            Divider()
            if let message = reader.errorMessage {
                VStack(spacing: 12) {
                    Image(systemName: "exclamationmark.triangle").font(.largeTitle)
                    Text("PDF Unavailable").font(.title2)
                    Text(message).textSelection(.enabled)
                    Button("Retry PDF") { reader.load(url: url) }.accessibilityIdentifier("retryPDF")
                }.padding().frame(maxWidth: .infinity, maxHeight: .infinity)
                    .accessibilityIdentifier("pdfError")
            } else {
                PDFKitView(reader: reader)
            }
        }
        .onAppear { reader.load(url: url) }
        .onChange(of: url) { newURL in reader.load(url: newURL) }
        .onChange(of: revision) { _ in reader.load(url: url) }
        .onChange(of: findQuery) { query in reader.search(query: query) }
        .onReceive(NotificationCenter.default.publisher(for: .findInPage)) { _ in openFind() }
        .onReceive(NotificationCenter.default.publisher(for: .nextMatch)) { _ in reader.nextMatch() }
        .onReceive(NotificationCenter.default.publisher(for: .previousMatch)) { _ in reader.previousMatch() }
        .onExitCommand { if showFind { closeFind() } }
    }

    private func openFind() {
        showFind = true
        findFocused = true
    }

    private func closeFind() {
        showFind = false
        findFocused = false
    }

    private func infoRow(icon: String, label: String, value: String, identifier: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon).foregroundStyle(.secondary).frame(width: 16)
            Text("\(label):").foregroundStyle(.secondary)
            Text(value).font(.system(.caption, design: .monospaced)).lineLimit(1).truncationMode(.middle)
            Spacer()
            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(value, forType: .string)
            } label: { Image(systemName: "doc.on.doc") }
                .buttonStyle(.plain).help("Copy \(label.lowercased()) path")
                .accessibilityLabel("Copy \(label.lowercased()) path").accessibilityIdentifier(identifier)
        }.font(.caption).padding(.horizontal, 12).padding(.vertical, 5).background(.bar)
    }
}

struct PDFKitView: NSViewRepresentable {
    let reader: PDFReader

    func makeNSView(context: Context) -> PDFView { reader.view }

    func updateNSView(_ pdfView: PDFView, context: Context) {
        // PDFReader changes the document only when its file identity changes.
    }
}

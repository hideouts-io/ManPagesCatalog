import Foundation
import PDFKit
import Combine

/// Owns PDFKit objects so ordinary SwiftUI updates cannot reset the reader.
@MainActor
final class PDFReader: NSObject, ObservableObject, @preconcurrency PDFDocumentDelegate {
    let view: PDFView
    @Published private(set) var errorMessage: String?
    @Published private(set) var matchCount = 0
    @Published private(set) var matchIndex = 0
    @Published private(set) var searching = false
    private var identity: PDFIdentity?
    private var matches: [PDFSelection] = []
    private var findTask: Task<Void, Never>?
    private var findQuery = ""

    override init() {
        view = PDFView()
        super.init()
        view.autoScales = true
        view.displayMode = .singlePageContinuous
        view.displayDirection = .vertical
        view.setAccessibilityIdentifier("pdfReader")
    }

    func load(url: URL) {
        do {
            let attributes = try url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
            let next = PDFIdentity(url: url, modified: attributes.contentModificationDate, size: attributes.fileSize)
            guard identity != next else { return }
            guard let document = PDFDocument(url: url), document.pageCount > 0 else {
                throw PDFReadError(message: "The PDF is corrupt, empty, or unreadable: \(url.path). Regenerate this catalog or choose another page.")
            }
            findTask?.cancel()
            view.document?.cancelFindString()
            view.document?.delegate = nil
            view.document = document
            document.delegate = self
            identity = next
            errorMessage = nil
            search(query: findQuery)
        } catch {
            findTask?.cancel()
            view.document?.cancelFindString()
            view.document?.delegate = nil
            view.document = nil
            identity = nil
            matches = []
            matchCount = 0
            matchIndex = 0
            searching = false
            errorMessage = "Cannot open PDF: \(error.localizedDescription)\n\(url.path)\nUse Catalog… to regenerate missing or damaged PDFs."
        }
    }

    func search(query: String) {
        findQuery = query
        findTask?.cancel()
        view.document?.cancelFindString()
        matches = []
        matchCount = 0
        matchIndex = 0
        view.highlightedSelections = []
        searching = !query.isEmpty && view.document != nil
        guard searching else { return }
        findTask = Task { [weak self] in
            do {
                try await Task.sleep(nanoseconds: 150_000_000)
            } catch is CancellationError {
                return
            } catch {
                self?.errorMessage = "Cannot schedule PDF search: \(error.localizedDescription)"
                return
            }
            guard !Task.isCancelled, let self else { return }
            self.view.document?.beginFindString(query, withOptions: .caseInsensitive)
        }
    }

    func didMatchString(_ instance: PDFSelection) {
        matches.append(instance)
        matchCount = matches.count
    }

    func documentDidEndDocumentFind(_ notification: Notification) {
        guard let document = notification.object as? PDFDocument, document === view.document else { return }
        searching = false
        view.highlightedSelections = matches
        if !matches.isEmpty { selectMatch(index: 0) }
    }

    func nextMatch() {
        guard !matches.isEmpty else { return }
        selectMatch(index: matchIndex % matches.count)
    }

    func previousMatch() {
        guard !matches.isEmpty else { return }
        selectMatch(index: (matchIndex + matches.count - 2) % matches.count)
    }

    private func selectMatch(index: Int) {
        matchIndex = index + 1
        view.setCurrentSelection(matches[index], animate: false)
        view.go(to: matches[index])
    }
}

private struct PDFIdentity: Equatable {
    let url: URL
    let modified: Date?
    let size: Int?
}

private struct PDFReadError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

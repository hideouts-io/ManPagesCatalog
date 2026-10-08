import SwiftUI
import WebKit
import UniformTypeIdentifiers

struct ReaderHeading: Identifiable, Decodable {
    let id: String
    let title: String
}

struct BrowseContext: Equatable {
    let query: String
    let section: String?
    let root: String?
    let fullText: Bool
}

struct ReaderVisit {
    let page: ManualPage
    let context: BrowseContext
    let scroll: Double
    let find: String
    let zoom: Double
}

/// Owns the WebKit document and navigation so a global search never replaces the open page.
@MainActor
final class ManualReader: NSObject, ObservableObject, WKNavigationDelegate {
    let webView: WKWebView
    @Published private(set) var page: ManualPage?
    @Published private(set) var headings: [ReaderHeading] = []
    @Published private(set) var errorMessage: String?
    @Published private(set) var loading = false
    @Published private(set) var exporting = false
    @Published private(set) var message = ""
    @Published private(set) var canBack = false
    @Published private(set) var canForward = false
    @Published var showFind = false
    @Published var findQuery = ""
    @Published private(set) var findStatus = ""
    @Published private(set) var readerGeneration: UUID?
    @Published private(set) var findGeneration: UUID?
    @Published private(set) var findOperation = InteractionOperation.findNext
    private(set) var pendingFindCallbacks = 0
    var onReference: ((String, String) -> Void)?
    private var previous: [ReaderVisit] = []
    private var following: [ReaderVisit] = []
    private var context = BrowseContext(query: "", section: nil, root: nil, fullText: false)
    private var pendingScroll = 0.0
    private var pendingFind = ""
    private var task: Task<Void, Never>?
    private var request = UUID()
    private var findRequest = UUID()
    private var openRequest = UUID()
    private var activeNavigation: WKNavigation?

    override init() {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        webView = WKWebView(frame: .zero, configuration: config)
        super.init()
        webView.navigationDelegate = self
        webView.setAccessibilityIdentifier("manualWebView")
        // Initialize WebKit's local content process while the catalog opens, before the first manual activation.
        _ = webView.loadHTMLString("<!doctype html><html><body></body></html>", baseURL: nil)
    }

    func open(page: ManualPage, context: BrowseContext) async {
        let token = UUID()
        InteractionDiagnostics.started(operation: .reader, generation: token, query: context.query, documentID: page.id)
        if !page.fingerprint.isEmpty && self.page?.id == page.id && self.page?.fingerprint == page.fingerprint && errorMessage == nil {
            InteractionDiagnostics.documentBound(operation: .reader, generation: token, documentGeneration: request)
            InteractionDiagnostics.finished(operation: .reader, generation: token, outcome: loading ? .blocked : .reused,
                detail: loading ? "The unchanged document is still loading." : "The existing document was retained without formatting or navigation.")
            if InteractionDiagnostics.isEnabled && !loading { readerGeneration = token }
            return
        }
        openRequest = token
        do {
            let visit = try await currentVisit()
            guard token == openRequest else {
                InteractionDiagnostics.finished(operation: .reader, generation: token, outcome: .superseded, detail: "A newer reader activation replaced this request.")
                return
            }
            if let visit { previous.append(visit) }
            following = []
            load(ReaderVisit(page: page, context: context, scroll: 0, find: "", zoom: 1), generation: token)
        } catch {
            guard token == openRequest else { return }
            errorMessage = "Cannot preserve reader position: \(error.localizedDescription)"
            InteractionDiagnostics.finished(operation: .reader, generation: token, outcome: .failed, detail: errorMessage)
        }
    }

    func back() async -> BrowseContext? {
        guard let visit = previous.last, !loading else { return nil }
        do {
            if let current = try await currentVisit() { following.append(current) }
            previous.removeLast()
            load(visit, generation: UUID())
            return visit.context
        } catch { errorMessage = error.localizedDescription; return nil }
    }

    func forward() async -> BrowseContext? {
        guard let visit = following.last, !loading else { return nil }
        do {
            if let current = try await currentVisit() { previous.append(current) }
            following.removeLast()
            load(visit, generation: UUID())
            return visit.context
        } catch { errorMessage = error.localizedDescription; return nil }
    }

    func retry() {
        guard let page else { return }
        load(ReaderVisit(page: page, context: context, scroll: pendingScroll, find: findQuery, zoom: webView.pageZoom), generation: UUID())
    }

    private func load(_ visit: ReaderVisit, generation: UUID) {
        InteractionDiagnostics.started(operation: .reader, generation: generation, query: visit.context.query, documentID: visit.page.id)
        task?.cancel()
        activeNavigation = nil
        webView.stopLoading()
        request = generation
        let token = request
        InteractionDiagnostics.documentBound(operation: .reader, generation: token, documentGeneration: token)
        supersedeFind()
        InteractionDiagnostics.findInputCancelled()
        if InteractionDiagnostics.isEnabled { readerGeneration = nil }
        page = visit.page
        context = visit.context
        pendingScroll = visit.scroll
        pendingFind = visit.find
        findQuery = visit.find
        findStatus = ""
        showFind = !visit.find.isEmpty
        headings = []
        errorMessage = nil
        message = ""
        loading = true
        canBack = !previous.isEmpty
        canForward = !following.isEmpty
        webView.pageZoom = visit.zoom
        task = Task {
            do {
                let html = try await manualHTML(source: visit.page.source)
                try Task.checkCancellation()
                guard request == token else { return }
                activeNavigation = webView.loadHTMLString(html, baseURL: nil)
            } catch is CancellationError { return }
            catch {
                guard request == token else { return }
                loading = false
                errorMessage = "Cannot render \(visit.page.source.path): \(error.localizedDescription)"
                InteractionDiagnostics.finished(operation: .reader, generation: token, outcome: .failed, detail: errorMessage)
            }
        }
    }

    private func currentVisit() async throws -> ReaderVisit? {
        guard let page else { return nil }
        let scroll: Double
        if !loading && errorMessage == nil {
            guard let value = try await webView.evaluateJavaScript("window.scrollY") as? Double else {
                throw ManualToolError(message: "WebKit returned an invalid reading position.")
            }
            scroll = value
        } else { scroll = pendingScroll }
        return ReaderVisit(page: page, context: context, scroll: scroll, find: findQuery, zoom: webView.pageZoom)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard let navigation, navigation === activeNavigation else { return }
        let token = request
        Task {
            do {
                let value = try await webView.evaluateJavaScript("JSON.stringify(Array.from(document.querySelectorAll('h1[id],h2[id],h3[id]')).map(e=>({id:e.id,title:e.textContent.trim()})))")
                guard token == request else { return }
                guard let json = value as? String else { throw ManualToolError(message: "WebKit returned an invalid outline.") }
                headings = try JSONDecoder().decode([ReaderHeading].self, from: Data(json.utf8))
                _ = try await webView.callAsyncJavaScript("window.scrollTo(0, offset)", arguments: ["offset": pendingScroll], in: nil, contentWorld: .page)
                guard token == request else { return }
                loading = false
                if !pendingFind.isEmpty { findStatus = "Use Next or Previous to resume Find" }
                InteractionDiagnostics.finished(operation: .reader, generation: token, outcome: .completed, detail: "WebKit navigation, outline decoding and scroll restoration completed.")
                if InteractionDiagnostics.isEnabled { readerGeneration = token }
            } catch {
                guard token == request else { return }
                loading = false
                errorMessage = "Cannot initialize the reader: \(error.localizedDescription)"
                InteractionDiagnostics.finished(operation: .reader, generation: token, outcome: .failed, detail: errorMessage)
            }
        }
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        guard let navigation, navigation === activeNavigation else { return }
        loading = false
        errorMessage = "WebKit could not load this manual: \(error.localizedDescription)"
        InteractionDiagnostics.finished(operation: .reader, generation: request, outcome: .failed, detail: errorMessage)
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        guard let navigation, navigation === activeNavigation else { return }
        loading = false
        errorMessage = "WebKit could not begin loading this manual: \(error.localizedDescription)"
        InteractionDiagnostics.finished(operation: .reader, generation: request, outcome: .failed, detail: errorMessage)
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard navigationAction.navigationType == .linkActivated else { decisionHandler(.allow); return }
        guard let url = navigationAction.request.url else { decisionHandler(.cancel); return }
        if url.scheme == "manpagescatalog", let parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
           let name = parts.queryItems?.first(where: { $0.name == "name" })?.value,
           let section = parts.queryItems?.first(where: { $0.name == "section" })?.value {
            decisionHandler(.cancel)
            onReference?(name, section)
        } else if url.scheme == "about", url.fragment != nil {
            decisionHandler(.allow)
        } else {
            decisionHandler(.cancel)
            message = "External link: \(url.absoluteString). Copy the link to open it outside the reader."
        }
    }

    func setFindQuery(_ query: String) {
        guard query != findQuery else { return }
        InteractionDiagnostics.findInput(query: query, documentID: page?.id, window: webView.window)
        findQuery = query
    }

    private func supersedeFind() {
        InteractionDiagnostics.finished(operation: .findNext, generation: findRequest, outcome: .superseded, detail: "A new Find request or document replaced this search.")
        InteractionDiagnostics.finished(operation: .findPrevious, generation: findRequest, outcome: .superseded, detail: "A new Find request or document replaced this search.")
        findRequest = UUID()
        if InteractionDiagnostics.isEnabled { findGeneration = nil }
    }

    func findNext() {
        supersedeFind()
        let token = findRequest
        let document = request
        let query = findQuery
        InteractionDiagnostics.started(operation: .findNext, generation: token, query: query, documentID: page?.id)
        InteractionDiagnostics.documentBound(operation: .findNext, generation: token, documentGeneration: document)
        guard !loading else {
            InteractionDiagnostics.finished(operation: .findNext, generation: token, outcome: .blocked, detail: "The reader is still loading.")
            return
        }
        let config = WKFindConfiguration()
        config.caseSensitive = false
        config.wraps = true
        pendingFindCallbacks += 1
        webView.find(query, configuration: config) { [weak self] result in
            guard let self else { return }
            self.pendingFindCallbacks -= 1
            guard token == self.findRequest, document == self.request, query == self.findQuery else {
                InteractionDiagnostics.finished(operation: .findNext, generation: token, outcome: .superseded, detail: "The document or Find query changed before WebKit completed.")
                return
            }
            self.findStatus = query.isEmpty ? "" : result.matchFound ? "Match found" : "No matches"
            InteractionDiagnostics.finished(operation: .findNext, generation: token, outcome: .completed, detail: self.findStatus)
            if InteractionDiagnostics.isEnabled { self.findOperation = .findNext; self.findGeneration = token }
        }
    }

    func findPrevious() {
        supersedeFind()
        let token = findRequest
        let document = request
        let query = findQuery
        InteractionDiagnostics.started(operation: .findPrevious, generation: token, query: query, documentID: page?.id)
        InteractionDiagnostics.documentBound(operation: .findPrevious, generation: token, documentGeneration: document)
        guard !loading else {
            InteractionDiagnostics.finished(operation: .findPrevious, generation: token, outcome: .blocked, detail: "The reader is still loading.")
            return
        }
        let config = WKFindConfiguration()
        config.caseSensitive = false
        config.backwards = true
        config.wraps = true
        pendingFindCallbacks += 1
        webView.find(query, configuration: config) { [weak self] result in
            guard let self else { return }
            self.pendingFindCallbacks -= 1
            guard token == self.findRequest, document == self.request, query == self.findQuery else {
                InteractionDiagnostics.finished(operation: .findPrevious, generation: token, outcome: .superseded, detail: "The document or Find query changed before WebKit completed.")
                return
            }
            self.findStatus = query.isEmpty ? "" : result.matchFound ? "Match found" : "No matches"
            InteractionDiagnostics.finished(operation: .findPrevious, generation: token, outcome: .completed, detail: self.findStatus)
            if InteractionDiagnostics.isEnabled { self.findOperation = .findPrevious; self.findGeneration = token }
        }
    }

    func jump(to heading: ReaderHeading) {
        Task {
            do { _ = try await webView.callAsyncJavaScript("document.getElementById(anchor).scrollIntoView()", arguments: ["anchor": heading.id], in: nil, contentWorld: .page) }
            catch { message = "Cannot jump to heading: \(error.localizedDescription)" }
        }
    }

    func enlarge() { webView.pageZoom = min(webView.pageZoom + 0.1, 2) }
    func reduce() { webView.pageZoom = max(webView.pageZoom - 0.1, 0.7) }

    func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        if NSPasteboard.general.setString(text, forType: .string) { message = "Copied to clipboard" }
        else { errorMessage = "The system clipboard did not accept the text." }
    }

    func copySelection() {
        Task {
            do {
                guard let text = try await webView.evaluateJavaScript("window.getSelection().toString()") as? String else {
                    throw ManualToolError(message: "WebKit returned an invalid selection.")
                }
                if text.isEmpty { message = "Select documentation text or an example first." }
                else { copy(text) }
            } catch { errorMessage = error.localizedDescription }
        }
    }

    func copyCommandAndOpenTerminal() {
        guard let page else { return }
        let command: String
        do {
            let target = resolveCommandExecutable(name: page.name, section: page.section, environment: ProcessInfo.processInfo.environment)
            command = try generatedCommandText(target: target)
        } catch {
            message = "Cannot prepare a runnable command: \(error.localizedDescription) Use Build Command to locate the executable."
            return
        }
        do {
            try copyCommandAndOpenSystemTerminal(text: command) { [weak self] error in
                if let error { self?.message = "Cannot open Terminal: \(error.localizedDescription) The command remains on the clipboard." }
                else { self?.message = "Command copied. Paste into Terminal when ready. Nothing was inserted or executed." }
            }
        } catch { message = error.localizedDescription }
    }

    func exportPDF() {
        guard let page else { return }
        guard let window = webView.window else {
            message = "Cannot open PDF export: the manual is not attached to a reading window. Reopen the manual and try again."
            return
        }
        guard !exporting else { return }
        exporting = true
        Task {
            defer { exporting = false }
            var destination: URL?
            do {
                destination = try await chooseExportDestination(window: window, filename: "\(page.name).\(page.section).pdf",
                    contentType: .pdf, title: "Export Manual as PDF", identifier: "manualPDFExportPanel")
                guard let destination else { return }
                try await renderManual(source: page.source, destination: destination)
                message = "Exported \(destination.lastPathComponent)"
            } catch {
                if let destination {
                    message = "PDF export failed for \(page.title) at \(destination.path): \(error.localizedDescription)"
                } else { message = "Cannot open PDF export: \(error.localizedDescription)" }
            }
        }
    }
}

struct ManualWebView: NSViewRepresentable {
    let reader: ManualReader
    func makeNSView(context: Context) -> WKWebView { reader.webView }
    func updateNSView(_ nsView: WKWebView, context: Context) { }
}

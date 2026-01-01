import Cocoa

// Own one mixed-file import. The sheet prevents edits from moving its insertion point mid-request.
@MainActor
final class AudioFileImportController: NSObject {
    let sheet = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 460, height: 164), styleMask: [.titled], backing: .buffered, defer: false)
    let statusLabel = NSTextField(labelWithString: "Preparing transcription…")
    let fileLabel = NSTextField(labelWithString: "")
    let progressBar = NSProgressIndicator()
    private weak var parent: NSWindow?
    private let urls: [URL]
    private let provider: AudioTranscriptionProvider
    private let language: String
    private var task: Task<Void, Never>?
    private var closeObserver: NSObjectProtocol?
    private var completion: (([String], [String]) -> Void)?
    private var pieces: [String] = []
    private var failures: [String] = []
    private var currentFileID: UUID?
    private(set) var finished = false

    // init(parent, urls, provider, language, completion): Capture the provider
    // and language once so a batch cannot switch destinations halfway through.
    init(parent: NSWindow, urls: [URL], provider: AudioTranscriptionProvider, language: String,
         completion: @escaping ([String], [String]) -> Void) {
        self.parent = parent
        self.urls = urls
        self.provider = provider
        self.language = language
        self.completion = completion
        super.init()
        buildSheet()
        closeObserver = NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: parent, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.cancel(nil) }
        }
    }

    // buildSheet(): Lay out a compact progress sheet with a native,
    // keyboard-accessible Cancel button.
    private func buildSheet() {
        sheet.title = "Import Audio"
        sheet.isReleasedWhenClosed = false
        let body = NSView()
        sheet.contentView = body
        // Keep the current stage readable while long filenames truncate in the
        // middle.
        statusLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        fileLabel.font = .systemFont(ofSize: 12)
        fileLabel.textColor = .secondaryLabelColor
        fileLabel.lineBreakMode = .byTruncatingMiddle
        progressBar.style = .bar
        progressBar.minValue = 0
        progressBar.maxValue = 1
        // Allow cancellation from the button or Escape.
        let cancel = NSButton(title: localized("cancel", "Cancel"), target: self, action: #selector(cancel(_:)))
        cancel.bezelStyle = .rounded
        cancel.keyEquivalent = "\u{1b}"
        for view in [statusLabel, fileLabel, progressBar, cancel] {
            view.translatesAutoresizingMaskIntoConstraints = false
            body.addSubview(view)
        }
        // Align the status, filename, progress, and cancellation controls.
        NSLayoutConstraint.activate([
            statusLabel.leadingAnchor.constraint(equalTo: body.leadingAnchor, constant: 24),
            statusLabel.trailingAnchor.constraint(equalTo: body.trailingAnchor, constant: -24),
            statusLabel.topAnchor.constraint(equalTo: body.topAnchor, constant: 20),
            fileLabel.leadingAnchor.constraint(equalTo: statusLabel.leadingAnchor),
            fileLabel.trailingAnchor.constraint(equalTo: statusLabel.trailingAnchor),
            fileLabel.topAnchor.constraint(equalTo: statusLabel.bottomAnchor, constant: 8),
            progressBar.leadingAnchor.constraint(equalTo: statusLabel.leadingAnchor),
            progressBar.trailingAnchor.constraint(equalTo: statusLabel.trailingAnchor),
            progressBar.topAnchor.constraint(equalTo: fileLabel.bottomAnchor, constant: 14),
            cancel.trailingAnchor.constraint(equalTo: body.trailingAnchor, constant: -24),
            cancel.bottomAnchor.constraint(equalTo: body.bottomAnchor, constant: -18)
        ])
    }

    // start(): Check Pro access and upload permission before starting an OpenAI
    // import.
    func start() {
        // Prevent a completed import from restarting or starting twice.
        guard !finished, task == nil else { return }
        // Require purchase access and explicit sharing approval before any upload.
        if provider == .openAI {
            // Dismiss the pending import when either access or sharing is declined.
            guard ensureProAccess(.cloudTranscription), confirmRemoteAudioSharingIfNeeded() else {
                finish()
                return
            }
        }
        // Closing the launcher during a permission dialog cancels the pending import.
        guard !finished, let parent else { finish(); return }
        parent.beginSheet(sheet)
        task = Task { [weak self] in await self?.run() }
    }

    // run(): Process files in drop order and keep completed text when another
    // file fails.
    private func run() async {
        for (index, url) in urls.enumerated() {
            // Stop between files when the import has been cancelled or dismissed.
            guard !Task.isCancelled, !finished else { break }
            let fileID = UUID()
            currentFileID = fileID
            fileLabel.stringValue = urls.count == 1 ? url.lastPathComponent : "\(index + 1) of \(urls.count) · \(url.lastPathComponent)"
            let update: @Sendable (AudioTranscriptionProgress) -> Void = { [weak self] progress in
                Task { @MainActor in
                    // A previous file's queued update must not overwrite the next file's status.
                    guard self?.currentFileID == fileID else { return }
                    self?.updateProgress(progress)
                }
            }
            // Hold any sandbox extension for the full asynchronous read, then release our reference.
            let scoped = url.startAccessingSecurityScopedResource()
            defer { /* Release only the sandbox access this import acquired. */ if scoped { url.stopAccessingSecurityScopedResource() } }
            do {
                let text: String
                // Send recordings through the selected transcription provider.
                if droppedFileSupportsAudioTranscription(url) {
                    updateProgress(.init(message: "Preparing \(provider.title)…"))
                    // Never fall back from local recognition to an upload without a new user choice.
                    switch provider {
                    // Apple uses the selected language, or the Mac's locale by default.
                    case .apple:
                        text = try await transcribeAppleAudioFile(url, language: language, progress: update)
                    // Recheck Pro access before reading a key or uploading audio.
                    case .openAI:
                        text = try await transcribeOpenAIAudioFile(url, progress: update)
                    }
                } else {
                    // Extract document or image text without invoking transcription.
                    updateProgress(.init(message: "Reading document…"))
                    // Existing synchronous document/OCR readers must not block the UI task.
                    text = try await Task.detached { try extractTextFromDroppedFile(url) }.value
                }
                try Task.checkCancellation()
                // Discard a late result after the import sheet has finished.
                guard !finished else { return }
                pieces.append(text)
            } catch is CancellationError {
                // A cancelled file contributes no partial transcript; earlier files remain usable.
                break
            } catch {
                // Do not turn cancellation into a file-error alert.
                guard !Task.isCancelled, !finished else { break }
                failures.append("\(url.lastPathComponent): \(error.localizedDescription)")
            }
        }
        finish()
    }

    // updateProgress(progress): Ignore late updates after cancellation; use an
    // indeterminate bar when progress is unknown.
    func updateProgress(_ progress: AudioTranscriptionProgress) {
        // Ignore progress arriving after dismissal.
        guard !finished else { return }
        statusLabel.stringValue = progress.message
        progressBar.isIndeterminate = progress.fraction == nil
        // Show measured progress only when the provider supplies a finite fraction.
        if let fraction = progress.fraction, fraction.isFinite {
            progressBar.stopAnimation(nil)
            progressBar.doubleValue = min(1, max(0, fraction))
        } else {
            // Keep the spinner running when progress cannot be measured.
            progressBar.startAnimation(nil)
        }
    }

    // cancel(sender): Restore the input immediately even if a system decoder
    // takes time to acknowledge cancellation.
    @objc func cancel(_ sender: Any?) {
        task?.cancel()
        finish()
    }

    // finish(): Deliver once, after dismissing the sheet so any file-error
    // alert has an available parent.
    private func finish() {
        // Deliver the accumulated import results only once.
        guard !finished else { return }
        finished = true
        currentFileID = nil
        // Stop observing the launcher after this import finishes.
        if let closeObserver { NotificationCenter.default.removeObserver(closeObserver) }
        closeObserver = nil
        // End an attached sheet before returning text or showing errors.
        if let host = sheet.sheetParent { host.endSheet(sheet) }
        sheet.orderOut(nil)
        let callback = completion
        completion = nil
        callback?(pieces, failures)
    }
}

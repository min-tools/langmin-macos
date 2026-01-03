import Cocoa
import AVFoundation
import Speech

// Speech recognition is chosen separately from the model that later edits the transcript.
enum AudioTranscriptionProvider: String, CaseIterable {
    // Apple stays on the Mac; OpenAI uploads require separate audio permission.
    case apple, openAI

    var title: String { self == .apple ? "Apple · On-device" : "OpenAI · Pro" }

    // resolved(value): Use the saved provider, falling back to Apple for an
    // unknown value.
    static func resolved(_ value: String) -> Self {
        return Self(rawValue: value) ?? .apple
    }
}

// droppedFileSupportsAudioTranscription(url): Accept local audio files in
// formats supported by both providers.
func droppedFileSupportsAudioTranscription(_ url: URL) -> Bool {
    url.isFileURL && ["m4a", "mp3", "wav"].contains(url.pathExtension.lowercased())
}

// audioTranscriptionLocale(identifier): Use the Mac's locale when no Apple
// transcription language is selected.
func audioTranscriptionLocale(_ identifier: String) -> Locale {
    identifier.isEmpty || identifier == "auto" ? Locale.current : Locale(identifier: identifier)
}

// checkedAudioTranscript(text): Trim transcript boundaries and reject empty
// results.
func checkedAudioTranscript(_ text: String) throws -> String {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    // Treat an empty transcript as a recognition failure.
    guard !trimmed.isEmpty else {
        throw HelperFailure(message: "No speech was found in this recording.")
    }
    return trimmed
}

// Report a named stage; a fraction is present only when the provider exposes real progress.
struct AudioTranscriptionProgress: Sendable {
    let message: String
    var fraction: Double? = nil
}

// confirmSpeechModelDownload(language): Ask before macOS downloads a speech
// model for an audio import.
@MainActor
func confirmSpeechModelDownload(language: String) -> Bool {
    // Cancellation may arrive while this prompt is queued for the main actor.
    guard !Task.isCancelled else { return false }
    let alert = NSAlert()
    alert.messageText = "Download speech recognition for \(language)?"
    alert.informativeText = "macOS needs a speech model before it can transcribe this language. The download requires internet access and disk space. Your recording stays on this Mac."
    alert.addButton(withTitle: localized("cancel", "Cancel"))
    alert.addButton(withTitle: "Download")
    return runLangminModalAlert(alert) == .alertSecondButtonReturn
}

// confirmRemoteAudioSharingIfNeeded(): Keep audio approval separate from
// text/image approval, but use the existing permission reset.
@MainActor
func confirmRemoteAudioSharingIfNeeded() -> Bool {
    let store = langminPreferencesStore()
    let key = remoteAIConsentPrefix + "audio.openai.api.openai.com"
    // A prior audio-specific approval covers future recordings until permissions are reset.
    if store.bool(forKey: key) { return true }
    let alert = NSAlert()
    alert.messageText = "Send recordings to OpenAI?"
    alert.informativeText = "Recordings go directly to OpenAI using your API key. OpenAI bills your account and may process or retain recordings under its policy. Langmin's developer does not receive them.\n\nAlways Allow saves permission. Revoke it in Settings → Models → Reset AI Permissions."
    alert.addButton(withTitle: localized("cancel", "Cancel"))
    alert.addButton(withTitle: "Allow Once")
    alert.addButton(withTitle: "Always Allow")
    // A one-time approval covers this import batch only; cancellation never saves consent.
    switch runLangminModalAlert(alert) {
    case .alertSecondButtonReturn:
        return true
    case .alertThirdButtonReturn:
        store.set(true, forKey: key)
        return true
    default:
        return false
    }
}

// availableAppleTranscriptionLocales(): Query speech support without loading
// Foundation Models or requiring Apple Intelligence.
func availableAppleTranscriptionLocales() async -> [Locale] {
    // Expose no language choices when local transcription is unavailable.
    guard #available(macOS 26.0, *), SpeechTranscriber.isAvailable else { return [] }
    return await SpeechTranscriber.supportedLocales
}

// Finish cancelled Apple work before the next import can reuse or replace its model reservation.
private actor AppleTranscriptionQueue {
    static let shared = AppleTranscriptionQueue()
    private var tail: (id: UUID, completion: Task<Void, Never>)?

    // run(operation): Chain complete imports because an actor alone allows
    // other calls to enter during an await.
    func run(_ operation: @escaping @Sendable () async throws -> String) async throws -> String {
        try Task.checkCancellation()
        let previous = tail?.completion
        let id = UUID()
        let task = Task {
            await previous?.value
            try Task.checkCancellation()
            return try await operation()
        }
        tail = (id, Task { _ = try? await task.value })
        // Clear only our own queue tail; a later import may already be waiting behind us.
        defer { /* Clear the queue tail only if a newer request has not replaced it. */ if tail?.id == id { tail = nil } }
        return try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
    }
}

// prepareAppleTranscriptionModel(transcriber, locale, language, progress,
// approveDownload): Keep installed models reserved across imports and app
// launches so macOS can reuse them.
@available(macOS 26.0, *)
private func prepareAppleTranscriptionModel(
    _ transcriber: SpeechTranscriber, locale: Locale, language: String,
    progress: @escaping @Sendable (AudioTranscriptionProgress) -> Void,
    approveDownload: @escaping @Sendable (String) async -> Bool
) async throws {
    try Task.checkCancellation()
    let reservations = await AssetInventory.reservedLocales
    let alreadyReserved = reservations.contains { $0.identifier(.bcp47) == locale.identifier(.bcp47) }
    var replacedLocale: Locale?
    // The queue has finished earlier analysis, so an old reservation is safe to replace at capacity.
    if !alreadyReserved, reservations.count >= AssetInventory.maximumReservedLocales, let unused = reservations.first {
        try Task.checkCancellation()
        replacedLocale = unused
        await AssetInventory.release(reservedLocale: unused)
    }
    var reservedHere = false
    do {
        try Task.checkCancellation()
        reservedHere = try await AssetInventory.reserve(locale: locale)
        try Task.checkCancellation()
        // Reserving first lets the system recognize assets already available to this app.
        guard let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) else { return }
        let status = await AssetInventory.status(forModules: [transcriber])
        try Task.checkCancellation()
        // An existing download already has approval; installed assets need no further prompt.
        if status != .installed && status != .downloading {
            // Stop before downloading when the user declines.
            guard await approveDownload(language) else { throw CancellationError() }
            try Task.checkCancellation()
        }
        progress(.init(message: "Downloading speech model…"))
        // Cancel the system request along with the import, but retain every successful installation.
        try await withTaskCancellationHandler {
            try await request.downloadAndInstall()
        } onCancel: {
            request.progress.cancel()
        }
    } catch {
        // A declined or failed installation must not consume a new reservation.
        if reservedHere { await AssetInventory.release(reservedLocale: locale) }
        // Restore the displaced reservation where possible without starting another download.
        if let replacedLocale { _ = try? await AssetInventory.reserve(locale: replacedLocale) }
        throw error
    }
}

// transcribeAppleAudioFile(url, language, progress, [approveDownload]): Stream
// a file through Apple's local speech model; no recording is sent to Apple's
// servers.
func transcribeAppleAudioFile(
    _ url: URL, language: String,
    progress: @escaping @Sendable (AudioTranscriptionProgress) -> Void,
    approveDownload: @escaping @Sendable (String) async -> Bool = { name in
        await MainActor.run { confirmSpeechModelDownload(language: name) }
    }
) async throws -> String {
    try await AppleTranscriptionQueue.shared.run {
        try await performAppleAudioTranscription(url, language: language,
                                                progress: progress, approveDownload: approveDownload)
    }
}

// performAppleAudioTranscription(url, language, progress, approveDownload):
// Keep model preparation and analysis in the same queue slot, including
// cancellation cleanup.
private func performAppleAudioTranscription(
    _ url: URL, language: String,
    progress: @escaping @Sendable (AudioTranscriptionProgress) -> Void,
    approveDownload: @escaping @Sendable (String) async -> Bool
) async throws -> String {
    try Task.checkCancellation()
    let cloudHint = " You can choose OpenAI in Settings → Transcription."
    // Reject older systems before using the speech analyzer APIs.
    guard #available(macOS 26.0, *) else {
        throw HelperFailure(message: "Apple transcription requires macOS 26 or later." + cloudHint)
    }
    // Report unavailable speech support instead of silently uploading audio.
    guard SpeechTranscriber.isAvailable else {
        throw HelperFailure(message: "Apple transcription is unavailable on this Mac." + cloudHint)
    }
    let requested = audioTranscriptionLocale(language)
    let name = Locale.current.localizedString(forIdentifier: requested.identifier) ?? requested.identifier
    // Reject languages that the on-device model cannot transcribe.
    guard let locale = await SpeechTranscriber.supportedLocale(equivalentTo: requested) else {
        throw HelperFailure(message: "Apple cannot transcribe \(name). Choose a supported audio language in Settings → Transcription." + cloudHint)
    }
    try Task.checkCancellation()
    let file: AVAudioFile
    // Decode before offering a model download, so a damaged file does not trigger a large download.
    do { file = try AVAudioFile(forReading: url) }
    catch { throw HelperFailure(message: "This audio file could not be read. Try exporting it as M4A, MP3, or WAV.") }
    let duration = Double(file.length) / file.processingFormat.sampleRate
    // Reject empty or invalid audio before reserving a speech model.
    guard duration.isFinite, duration > 0 else {
        throw HelperFailure(message: "This recording contains no audio.")
    }
    let transcriber = SpeechTranscriber(locale: locale, preset: .transcription)
    try await prepareAppleTranscriptionModel(transcriber, locale: locale, language: name,
                                            progress: progress, approveDownload: approveDownload)
    try Task.checkCancellation()
    let analyzer = SpeechAnalyzer(modules: [transcriber])
    progress(.init(message: "Transcribing with Apple…", fraction: 0))
    let text = try await withTaskCancellationHandler {
        // Read finalized results concurrently, or the analyzer may wait for its consumer.
        async let transcript: String = collectAppleTranscript(transcriber, duration: duration, progress: progress)
        do {
            // Finalize through the last analyzed sample so remaining text is delivered.
            if let end = try await analyzer.analyzeSequence(from: file) {
                try await analyzer.finalizeAndFinish(through: end)
            } else {
                // An empty stream must still finish the result sequence.
                await analyzer.cancelAndFinishNow()
            }
            return try await transcript
        } catch {
            // Unblock the result consumer before unwinding its structured child task.
            await analyzer.cancelAndFinishNow()
            throw error
        }
    } onCancel: {
        Task { await analyzer.cancelAndFinishNow() }
    }
    try Task.checkCancellation()
    return try checkedAudioTranscript(text)
}

// collectAppleTranscript(transcriber, duration, progress): Append final
// segments once and derive progress from their position in the recording.
@available(macOS 26.0, *)
private func collectAppleTranscript(
    _ transcriber: SpeechTranscriber, duration: Double,
    progress: @escaping @Sendable (AudioTranscriptionProgress) -> Void
) async throws -> String {
    var text = ""
    for try await result in transcriber.results {
        try Task.checkCancellation()
        text += String(result.text.characters)
        let elapsed = CMTimeGetSeconds(CMTimeRangeGetEnd(result.range))
        // Ignore invalid timestamps instead of displaying a misleading percentage.
        let fraction = elapsed.isFinite ? min(1, max(0, elapsed / duration)) : nil
        progress(.init(message: "Transcribing with Apple…", fraction: fraction))
    }
    return text
}

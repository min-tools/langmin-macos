#!/usr/bin/env python3
"""Check Apple model reuse and cancellation with a fake asset inventory and no downloads."""
from pathlib import Path
import os
import subprocess
import tempfile
import wave

from source_files import app_path


# block(source, marker, [body_marker = '{']): Compile the real preparation and
# transcription functions against isolated speech services.
def block(source, marker, body_marker='{'):
    start = source.index(marker)
    # A default closure belongs to the signature, not the function body.
    end = source.index(body_marker, start) + len(body_marker)
    depth = 1
    while depth:
        depth += (source[end] == '{') - (source[end] == '}')
        end += 1
    return source[start:end]


source = r'''
import Cocoa
import AVFoundation

struct HelperFailure: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}
// confirmSpeechModelDownload(language): Fail if the fixture reaches the real
// approval path.
func confirmSpeechModelDownload(language: String) -> Bool { fatalError("Unexpected real prompt") }

// Keep model state in memory while exercising the production import lifecycle.
enum Fixture {
    static var installed = false
    static var downloading = false
    static var failDownload = false
    static var failAnalysis = false
    static var slowDownload = false
    static var slowStatus = false
    static var slowAnalysis = false
    static var forceRequest = false
    static var transcript = "Spoken words"
    static var prompts = 0
    static var downloads = 0
    static var analysisStarted = false
    static var statusStarted = false
    static var request: AssetInstallationRequest?
    static var reservations: Set<String> = []
    static var releases = 0
    static var maximumReservations = 2

    // reset(): Start each scenario with no saved models or outstanding
    // requests.
    static func reset() {
        installed = false; downloading = false; failDownload = false; failAnalysis = false
        slowDownload = false; slowStatus = false; slowAnalysis = false; forceRequest = false
        transcript = "Spoken words"; prompts = 0; downloads = 0
        analysisStarted = false; statusStarted = false; request = nil
        reservations = []; releases = 0
        maximumReservations = 2
    }
}

// Match the framework's persistent reservations and optional installation request.
enum AssetInventory {
    enum Status { case supported, downloading, installed }
    static var maximumReservedLocales: Int { Fixture.maximumReservations }
    static var reservedLocales: [Locale] {
        get async { Fixture.reservations.sorted().map { Locale(identifier: $0) } }
    }
    // contains(locale): Apple may return an equivalent locale with different
    // identifier punctuation.
    static func contains(_ locale: Locale) -> Bool {
        Fixture.reservations.contains { Locale(identifier: $0).identifier(.bcp47) == locale.identifier(.bcp47) }
    }
    // reserve(locale): Reserve a fixture locale while enforcing the configured
    // capacity.
    static func reserve(locale: Locale) async throws -> Bool {
        // Do not consume another reservation for an already reserved locale.
        if contains(locale) { return false }
        // Simulate the speech service reservation limit.
        guard Fixture.reservations.count < maximumReservedLocales else {
            throw HelperFailure(message: "Fixture locale reservation limit reached")
        }
        return Fixture.reservations.insert(locale.identifier).inserted
    }
    // release(locale): Release the fixture locale and count the release.
    static func release(reservedLocale locale: Locale) async {
        Fixture.reservations.remove(locale.identifier)
        Fixture.releases += 1
    }
    // status(modules): Return the configured model status, optionally delaying
    // the response.
    static func status(forModules modules: [SpeechTranscriber]) async -> Status {
        Fixture.statusStarted = true
        // Model a system lookup that takes time to return after its caller cancels.
        if Fixture.slowStatus {
            await Task.detached { try? await Task.sleep(nanoseconds: 150_000_000) }.value
        }
        return Fixture.installed ? .installed : Fixture.downloading ? .downloading : .supported
    }
    // assetInstallationRequest(modules): Return a simulated installation
    // request when the model needs one.
    static func assetInstallationRequest(supporting modules: [SpeechTranscriber]) async throws -> AssetInstallationRequest? {
        precondition(contains(modules[0].locale), "Reserve before checking installation")
        // Skip installation when the fixture model is already available.
        if Fixture.installed && !Fixture.forceRequest { return nil }
        let request = AssetInstallationRequest()
        Fixture.request = request
        return request
    }
}

// Fake installation exposes real Foundation progress so cancellation remains observable.
final class AssetInstallationRequest: @unchecked Sendable {
    let progress = Progress(totalUnitCount: 100)
    // downloadAndInstall(): Simulate a completed, delayed, or failed model
    // download.
    func downloadAndInstall() async throws {
        Fixture.downloads += 1
        // Keep the fixture download pending to exercise cancellation.
        if Fixture.slowDownload { try await Task.sleep(nanoseconds: 5_000_000_000) }
        // Simulate a failed model download without changing system assets.
        if Fixture.failDownload { throw HelperFailure(message: "Fixture download failed") }
        Fixture.installed = true
        Fixture.downloading = false
    }
}

// Supply final speech segments without loading a system model or sending audio anywhere.
final class SpeechTranscriber: @unchecked Sendable {
    static let isAvailable = true
    // supportedLocale(locale): Accept the requested locale in the isolated
    // speech fixture.
    static func supportedLocale(equivalentTo locale: Locale) async -> Locale? { locale }
    enum Preset { case transcription }
    struct Result { let text: AttributedString; let range: CMTimeRange }
    let locale: Locale
    let results: AsyncThrowingStream<Result, Error>
    let continuation: AsyncThrowingStream<Result, Error>.Continuation
    // init(locale, preset): Create the fixture transcript stream for the
    // requested locale.
    init(locale: Locale, preset: Preset) {
        self.locale = locale
        (results, continuation) = AsyncThrowingStream<Result, Error>.makeStream()
    }
}

// Finish the result stream on both success and cancellation, like the real analyzer.
actor SpeechAnalyzer {
    let transcriber: SpeechTranscriber
    // init(modules): Use the supplied fixture transcriber for analysis.
    init(modules: [SpeechTranscriber]) { transcriber = modules[0] }
    // analyzeSequence(file): Record analysis and simulate its configured delay
    // or failure.
    func analyzeSequence(from file: AVAudioFile) async throws -> CMTime? {
        Fixture.analysisStarted = true
        // Keep fixture analysis pending to exercise cancellation.
        if Fixture.slowAnalysis { try await Task.sleep(nanoseconds: 5_000_000_000) }
        // Simulate an analysis failure after the request starts.
        if Fixture.failAnalysis { throw HelperFailure(message: "Fixture analysis failed") }
        return CMTime(seconds: 1, preferredTimescale: 16000)
    }
    // finalizeAndFinish(end): Deliver the fixture transcript and finish the
    // result stream.
    func finalizeAndFinish(through end: CMTime) async throws {
        transcriber.continuation.yield(.init(text: AttributedString(Fixture.transcript), range: CMTimeRange(start: .zero, end: end)))
        transcriber.continuation.finish()
    }
    // cancelAndFinishNow(): Finish the fixture stream with a cancellation
    // error.
    func cancelAndFinishNow() async { transcriber.continuation.finish(throwing: CancellationError()) }
}
'''
production = app_path('AudioTranscription.swift').read_text()
for marker in ['func audioTranscriptionLocale(', 'func checkedAudioTranscript(',
               'private actor AppleTranscriptionQueue',
               'struct AudioTranscriptionProgress:', 'private func prepareAppleTranscriptionModel(',
               'func transcribeAppleAudioFile(', 'private func performAppleAudioTranscription(',
               'private func collectAppleTranscript(']:
    body_marker = ') async throws -> String {' if marker == 'func transcribeAppleAudioFile(' else '{'
    source += block(production, marker, body_marker) + '\n'
source += r'''
var checks = 0
// check(condition, message): Stop the fixture with its message when the
// assertion fails.
func check(_ condition: @autoclosure () -> Bool, _ message: String) {
    // Fail immediately with the assertion message.
    guard condition() else { fputs("FAIL: \(message)\n", stderr); exit(1) }
    checks += 1
}
// waitFor(predicate): Wait for a named stage without allowing a broken fixture
// to hang indefinitely.
func waitFor(_ predicate: () -> Bool) async throws {
    for _ in 0..<100 {
        // Stop polling when the expected fixture stage is reached.
        if predicate() { return }
        try await Task.sleep(nanoseconds: 10_000_000)
    }
    throw HelperFailure(message: "Fixture stage did not start")
}
let file = URL(fileURLWithPath: CommandLine.arguments[1])
// transcribe([approve = true], [language = "en_US"]): Run the production
// transcription path with fixture approval and language.
func transcribe(approve: Bool = true, language: String = "en_US") async throws -> String {
    try await transcribeAppleAudioFile(file, language: language, progress: { _ in }, approveDownload: { _ in
        Fixture.prompts += 1
        return approve
    })
}
// rejects(message, operation): Assert that the asynchronous operation throws
// instead of returning a transcript.
func rejects(_ message: String, operation: () async throws -> String) async {
    do { _ = try await operation(); check(false, message) } catch { checks += 1 }
}
Task { @MainActor in
    do {
        // Repeated complete imports must reuse the first installation and its reservation.
        Fixture.reset()
        for _ in 0..<3 {
            let text = try await transcribe()
            check(text == "Spoken words", "Each import still returns a transcript")
        }
        check(Fixture.prompts == 1 && Fixture.downloads == 1, "Repeated imports ask and download only once")
        check(Fixture.reservations == ["en_US"] && Fixture.releases == 0, "Successful imports retain the model reservation")

        // A system-installed model needs no prompt, even without an earlier app reservation.
        Fixture.reset(); Fixture.installed = true
        _ = try await transcribe()
        check(Fixture.prompts == 0 && Fixture.downloads == 0, "Installed models skip the download dialog")
        check(Fixture.reservations == ["en_US"], "Existing models are reserved for future imports")

        // Finishing or joining an existing installation must not ask for redundant approval.
        Fixture.reset(); Fixture.downloading = true
        _ = try await transcribe()
        check(Fixture.prompts == 0 && Fixture.downloads == 1, "An existing download continues without another prompt")
        Fixture.reset(); Fixture.installed = true; Fixture.forceRequest = true
        _ = try await transcribe()
        check(Fixture.prompts == 0, "An installation completed during the lookup needs no approval")

        // Declining or failing a new installation frees its slot and permits a later retry.
        Fixture.reset()
        await rejects("Declining must cancel the import") { try await transcribe(approve: false) }
        check(Fixture.downloads == 0 && Fixture.reservations.isEmpty, "Declining starts no download and leaves no reservation")
        _ = try await transcribe()
        check(Fixture.prompts == 2 && Fixture.installed, "A later import can approve a declined model")
        Fixture.reset(); Fixture.failDownload = true
        await rejects("Failed installation must fail the import") { try await transcribe() }
        check(Fixture.reservations.isEmpty && Fixture.releases == 1, "Failed installation releases its new reservation")
        Fixture.failDownload = false
        _ = try await transcribe()
        check(Fixture.installed && Fixture.reservations == ["en_US"], "A successful retry keeps the model")

        // Failure must never remove a reservation that predates the current import.
        Fixture.reset(); Fixture.reservations = ["en_US"]; Fixture.failDownload = true
        await rejects("Existing reservation can still have an installation failure") { try await transcribe() }
        check(Fixture.reservations == ["en_US"] && Fixture.releases == 0, "An installation failure preserves an existing reservation")

        // Transcription errors and empty results do not invalidate a successfully installed model.
        Fixture.reset(); Fixture.failAnalysis = true
        await rejects("Analysis failure must reach the caller") { try await transcribe() }
        check(Fixture.installed && Fixture.releases == 0, "An analysis error retains the installed model")
        Fixture.failAnalysis = false; Fixture.transcript = "   "
        await rejects("An empty transcript must fail") { try await transcribe() }
        Fixture.transcript = "Spoken words"
        _ = try await transcribe()
        check(Fixture.prompts == 1 && Fixture.downloads == 1, "Retrying failed or empty transcription reuses the model")

        // Cancel at each asynchronous stage to check both prompt suppression and reservation cleanup.
        Fixture.reset(); Fixture.slowStatus = true
        let lookup = Task { try await transcribe() }
        try await waitFor { Fixture.statusStarted }
        lookup.cancel()
        await rejects("Cancelled lookup must fail") { try await lookup.value }
        check(Fixture.prompts == 0 && Fixture.reservations.isEmpty, "A cancelled lookup never prompts or keeps a new reservation")
        Fixture.reset(); Fixture.slowDownload = true
        let download = Task { try await transcribe() }
        try await waitFor { Fixture.downloads == 1 }
        download.cancel()
        await rejects("Cancelled download must fail") { try await download.value }
        check(Fixture.request?.progress.isCancelled == true && Fixture.reservations.isEmpty, "Cancel stops the download and releases its unfinished reservation")
        Fixture.reset(); Fixture.slowAnalysis = true
        let analysis = Task { try await transcribe() }
        try await waitFor { Fixture.analysisStarted }
        analysis.cancel()
        await rejects("Cancelled analysis must fail") { try await analysis.value }
        check(Fixture.installed && Fixture.releases == 0, "Cancelling analysis retains the downloaded model")
        Fixture.slowAnalysis = false
        _ = try await transcribe()
        check(Fixture.prompts == 1 && Fixture.downloads == 1, "The next import after cancellation needs no download")

        // A replacement import must wait until the cancelled request has finished releasing assets.
        Fixture.reset(); Fixture.slowStatus = true
        let oldImport = Task { try await transcribe() }
        try await waitFor { Fixture.statusStarted }
        oldImport.cancel()
        Fixture.slowStatus = false
        _ = try await transcribe()
        await rejects("The old import stays cancelled") { try await oldImport.value }
        check(Fixture.reservations == ["en_US"], "Old cleanup cannot release the replacement import's model")

        // A full reservation cache must still allow importing a recording in a new language.
        Fixture.reset(); Fixture.maximumReservations = 1; Fixture.reservations = ["en_US"]
        _ = try await transcribe(language: "fr_FR")
        check(Fixture.reservations == ["fr_FR"] && Fixture.releases == 1, "A new language replaces one unused reservation when the cache is full")
        Fixture.reset(); Fixture.maximumReservations = 1; Fixture.reservations = ["en_US"]; Fixture.installed = true
        _ = try await transcribe(language: "en-US")
        check(Fixture.releases == 0 && Fixture.prompts == 0, "Equivalent locale identifiers reuse the same reservation at capacity")
        Fixture.reset(); Fixture.maximumReservations = 1; Fixture.reservations = ["en_US"]
        await rejects("Declining a replacement must cancel the import") { try await transcribe(approve: false, language: "fr_FR") }
        check(Fixture.reservations == ["en_US"], "Declining a replacement restores the previous reservation")
        Fixture.reset(); Fixture.maximumReservations = 1; Fixture.reservations = ["en_US"]; Fixture.failDownload = true
        await rejects("A replacement download can fail") { try await transcribe(language: "fr_FR") }
        check(Fixture.reservations == ["en_US"], "A failed replacement restores the previous reservation")
        Fixture.reset(); Fixture.reservations = ["en_US"]
        _ = try await transcribe(language: "fr_FR")
        check(Fixture.reservations == ["en_US", "fr_FR"] && Fixture.releases == 0, "Spare capacity preserves previously reserved languages")

        // A cancelled queued import must never evict the active import's model or start a download.
        Fixture.reset(); Fixture.maximumReservations = 1; Fixture.slowAnalysis = true
        let active = Task { try await transcribe() }
        try await waitFor { Fixture.analysisStarted }
        let queued = Task { try await transcribe(language: "fr_FR") }
        try await Task.sleep(nanoseconds: 30_000_000)
        check(Fixture.reservations == ["en_US"] && Fixture.releases == 0, "Queued imports leave active model reservations intact")
        queued.cancel()
        active.cancel()
        await rejects("Active import cancellation must finish") { try await active.value }
        await rejects("Queued import cancellation must finish") { try await queued.value }
        check(Fixture.prompts == 1 && Fixture.downloads == 1 && Fixture.reservations == ["en_US"], "Cancelling a queued import performs no model work")
        print("\(checks) speech model lifecycle checks passed; no system assets or downloads")
        exit(0)
    } catch {
        fputs("FAIL: \(error.localizedDescription)\n", stderr)
        exit(1)
    }
}
RunLoop.main.run()
'''

with tempfile.TemporaryDirectory(prefix='langmin-speech-assets-', dir='/private/tmp') as directory:
    folder = Path(directory)
    recording = folder / 'fixture.wav'
    # Exercise the real file decoder with synthetic audio, never a user's recording.
    with wave.open(str(recording), 'wb') as audio:
        audio.setnchannels(1)
        audio.setsampwidth(2)
        audio.setframerate(16000)
        audio.writeframes(b'\0\0' * 16000)
    (folder / 'main.swift').write_text(source)
    cache = os.environ.get('LANGMIN_TEST_MODULE_CACHE', str(folder / 'modules'))
    subprocess.run(['swiftc', '-swift-version', '5', '-module-cache-path', cache,
                    str(folder / 'main.swift'), '-o', str(folder / 'tests')], check=True)
    subprocess.run([str(folder / 'tests'), str(recording)], check=True, timeout=30)

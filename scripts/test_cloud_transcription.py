#!/usr/bin/env python3
"""Exercise real OpenAI request code against URLProtocol responses, without network or credentials."""
from pathlib import Path
import os
import subprocess
import tempfile
from source_files import ROOT as CORE

source = r'''
import Cocoa
struct HelperFailure: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}
struct AudioTranscriptionProgress: Sendable { let message: String; var fraction: Double? = nil }
// Use fake Pro access and keys; without Pro, even the fake key must stay unread.
final class ProStore { static let shared = ProStore(); var hasFullAccess = false }
var keyReads = 0
// loadOpenAIAPIKey(): Count key reads and return a synthetic fixture key.
func loadOpenAIAPIKey() -> String { keyReads += 1; return "fixture-key" }
'''


# block(text, marker): Include the core's real validation helpers without the
# speech model or UI.
def block(text, marker):
    start = text.index(marker)
    end = text.index('{', start) + 1
    depth = 1
    while depth:
        depth += (text[end] == '{') - (text[end] == '}')
        end += 1
    return text[start:end]


core_source = (CORE / 'langmin/Sources/LangminApp/AudioTranscription.swift').read_text()
for marker in ['func droppedFileSupportsAudioTranscription(', 'func checkedAudioTranscript(']:
    source += block(core_source, marker) + '\n'
source += r'''
// Handle every request locally so this session cannot contact a provider.
final class RecordingProtocol: URLProtocol {
    static var status = 200
    static var responseBody = Data(#"{"text":"Hello from the recording."}"#.utf8)
    static var respond = true
    static var requests: [URLRequest] = []
    static var cancellations = 0
    // canInit(request): Intercept every request so the fixture cannot contact
    // the network.
    override class func canInit(with request: URLRequest) -> Bool { true }
    // canonicalRequest(request): Preserve the request for fixture assertions.
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    // startLoading(): Record the request and deliver the configured HTTP
    // response.
    override func startLoading() {
        Self.requests.append(request)
        // Leave the fixture request pending when testing cancellation.
        guard Self.respond else { return }
        let response = HTTPURLResponse(url: request.url!, statusCode: Self.status, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Self.responseBody)
        client?.urlProtocolDidFinishLoading(self)
    }
    // stopLoading(): Count cancellation of the intercepted request.
    override func stopLoading() { Self.cancellations += 1 }
}
var checks = 0
// check(condition, message): Stop the fixture with its message when the
// assertion fails.
func check(_ condition: @autoclosure () -> Bool, _ message: String) {
    // Fail immediately with the assertion message.
    guard condition() else { fputs("FAIL: \(message)\n", stderr); exit(1) }
    checks += 1
}
// rejects(message, operation): Check failures without printing request headers
// or provider payloads on assertion errors.
func rejects(_ message: String, _ operation: () throws -> Void) {
    do { try operation(); check(false, message) } catch { checks += 1 }
}
let root = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
Task { @MainActor in
    do {
        let file = root.appendingPathComponent("private-name.MP3")
        let audio = Data([1, 2, 3, 4])
        try audio.write(to: file)
        try validateOpenAIAudioFile(file)
        let encoded = try openAIAudioMultipart(data: audio, fileExtension: "mp3", boundary: "FixtureBoundary")
        let body = String(decoding: encoded, as: UTF8.self)
        check(body.contains("filename=\"recording.mp3\""), "Upload uses a generic filename")
        check(!body.contains("private-name") && !body.contains(root.path), "Local paths and filenames are not uploaded")
        check(body.contains("Content-Type: audio/mpeg"), "The MIME type matches MP3")
        check(body.contains("\r\n\r\ngpt-transcribe\r\n"), "Request selects the dedicated transcription model")
        check(body.hasSuffix("--FixtureBoundary--\r\n"), "Multipart body closes correctly")
        check(encoded.range(of: audio) != nil, "Multipart body preserves exact audio bytes")
        rejects("Empty audio is rejected") { _ = try openAIAudioMultipart(data: Data(), fileExtension: "wav", boundary: "x") }
        rejects("Unknown formats are rejected") { _ = try openAIAudioMultipart(data: audio, fileExtension: "exe", boundary: "x") }
        rejects("Oversized audio is rejected") { _ = try openAIAudioMultipart(data: Data(repeating: 0, count: openAITranscriptionFileLimit + 1), fileExtension: "wav", boundary: "x") }
        let large = root.appendingPathComponent("large.wav")
        FileManager.default.createFile(atPath: large.path, contents: nil)
        let handle = try FileHandle(forWritingTo: large)
        try handle.truncate(atOffset: UInt64(openAITranscriptionFileLimit + 1))
        try handle.close()
        rejects("Size is checked before reading a large file") { try validateOpenAIAudioFile(large) }

        let success = HTTPURLResponse(url: openAITranscriptionEndpoint, statusCode: 200, httpVersion: nil, headerFields: nil)!
        let decoded = try decodedOpenAITranscript(data: Data(#"{"text":"  Привет!  "}"#.utf8), response: success)
        check(decoded == "Привет!", "Unicode transcript text is preserved")
        for invalid in ["not json", "{}", #"{"text":12}"#, #"{"text":"  "}"#] {
            rejects("Invalid or empty transcripts are rejected") { _ = try decodedOpenAITranscript(data: Data(invalid.utf8), response: success) }
        }
        for status in [301, 400, 401, 403, 413, 429, 500, 503] {
            let response = HTTPURLResponse(url: openAITranscriptionEndpoint, statusCode: status, httpVersion: nil, headerFields: nil)!
            rejects("HTTP failure cannot become transcript text") { _ = try decodedOpenAITranscript(data: Data(#"{"text":"should not be accepted"}"#.utf8), response: response) }
        }

        // Verify the Pro access check without reading Keychain or making a network request.
        do { _ = try await transcribeOpenAIAudioFile(file, progress: { _ in }); check(false, "Pro is required") }
        catch { check(error.localizedDescription.contains("Pro"), "A missing entitlement explains the requirement") }
        check(keyReads == 0, "Denied Pro access never reads a key")

        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [RecordingProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let result = try await requestOpenAITranscript(file, apiKey: "fixture-key", session: session, progress: { _ in })
        check(result == "Hello from the recording.", "The actual async upload returns decoded text")
        let request = RecordingProtocol.requests.last!
        check(request.url == openAITranscriptionEndpoint && request.httpMethod == "POST", "Audio uses the fixed transcription endpoint")
        check(request.value(forHTTPHeaderField: "Authorization") == "Bearer fixture-key", "Transport supplies only the configured fixture key")
        check(request.value(forHTTPHeaderField: "Content-Type")?.hasPrefix("multipart/form-data; boundary=") == true, "Request declares multipart form data")

        RecordingProtocol.status = 429
        let before = RecordingProtocol.requests.count
        do { _ = try await requestOpenAITranscript(file, apiKey: "fixture-key", session: session, progress: { _ in }); check(false, "Quota error should fail") }
        catch { check(error.localizedDescription.contains("billing"), "Quota errors explain billing and usage limits") }
        check(RecordingProtocol.requests.count == before + 1, "HTTP failures do not retry billable uploads")
        do { _ = try await requestOpenAITranscript(file, apiKey: "", session: session, progress: { _ in }); check(false, "Missing key should fail") }
        catch { check(error.localizedDescription.contains("Settings"), "Missing keys explain where to configure them") }
        check(RecordingProtocol.requests.count == before + 1, "A missing key never starts a request")

        // Hold the mocked connection open until cancellation reaches URLSession.
        RecordingProtocol.respond = false
        let cancelled = Task { try await requestOpenAITranscript(file, apiKey: "fixture-key", session: session, progress: { _ in }) }
        try await Task.sleep(nanoseconds: 100_000_000)
        cancelled.cancel()
        do { _ = try await cancelled.value; check(false, "Cancelled upload should fail") }
        catch { check(error is CancellationError || (error as? URLError)?.code == .cancelled, "Cancellation reaches the network task") }
        check(RecordingProtocol.cancellations > 0, "The held connection is stopped")

        // Exercise the redirect policy without allowing the protocol fixture to perform a redirect.
        let delegate = AudioUploadDelegate(progress: { _ in })
        let task = session.dataTask(with: URLRequest(url: openAITranscriptionEndpoint))
        let redirect = HTTPURLResponse(url: openAITranscriptionEndpoint, statusCode: 307, httpVersion: nil, headerFields: nil)!
        var blocked = false
        delegate.urlSession(session, task: task, willPerformHTTPRedirection: redirect, newRequest: URLRequest(url: URL(string: "https://example.com/upload")!)) { blocked = $0 == nil }
        check(blocked, "A redirect cannot forward recordings or credentials")
        task.cancel()
        print("\(checks) cloud transcription checks passed")
        exit(0)
    } catch {
        fputs("FAIL: \(error.localizedDescription)\n", stderr)
        exit(1)
    }
}
RunLoop.main.run()
'''

with tempfile.TemporaryDirectory(prefix='langmin-cloud-audio-', dir='/private/tmp') as directory:
    folder = Path(directory)
    (folder / 'main.swift').write_text(source)
    cache = os.environ.get('LANGMIN_TEST_MODULE_CACHE', str(folder / 'modules'))
    subprocess.run(['swiftc', '-swift-version', '5', '-module-cache-path', cache,
                    str(CORE / 'langmin/Sources/LangminApp/CloudTranscription.swift'), str(folder / 'main.swift'),
                    '-o', str(folder / 'tests')], check=True)
    subprocess.run([str(folder / 'tests'), directory], check=True, timeout=30)

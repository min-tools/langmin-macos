import Foundation

// Keep the recording endpoint and model independent of text-model settings and endpoint overrides.
let openAITranscriptionEndpoint = URL(string: "https://api.openai.com/v1/audio/transcriptions")!
let openAITranscriptionModel = "gpt-transcribe"
let openAITranscriptionFileLimit = 25_000_000

// validateOpenAIAudioFile(url): Check the size before loading the recording
// into a bounded multipart request.
func validateOpenAIAudioFile(_ url: URL) throws {
    // Reject unsupported recording formats before reading the file.
    guard droppedFileSupportsAudioTranscription(url) else {
        throw HelperFailure(message: "OpenAI audio import supports M4A, MP3, and WAV files.")
    }
    let values = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
    // Require a nonempty regular file rather than a directory or missing item.
    guard values.isRegularFile == true, let size = values.fileSize, size > 0 else {
        throw HelperFailure(message: "This recording is empty or cannot be read.")
    }
    // Reject oversized recordings before loading them into memory.
    guard size <= openAITranscriptionFileLimit else {
        throw HelperFailure(message: "OpenAI accepts recordings up to 25 MB. Export a smaller M4A or MP3, split the recording, or choose Apple in Settings → Transcription.")
    }
}

// openAIAudioMultipart(data, fileExtension, boundary): Use a generic upload
// filename instead of the recording's local name or path.
func openAIAudioMultipart(data: Data, fileExtension: String, boundary: String) throws -> Data {
    let types = ["m4a": "audio/mp4", "mp3": "audio/mpeg", "wav": "audio/wav"]
    // Recheck format and size when constructing the upload body.
    guard let mime = types[fileExtension], !data.isEmpty, data.count <= openAITranscriptionFileLimit else {
        throw HelperFailure(message: "The recording must be an M4A, MP3, or WAV file no larger than 25 MB.")
    }
    var body = Data()
    // Keep fields explicit: transcribe in the original language without adding a writing prompt.
    for (name, value) in [("model", openAITranscriptionModel), ("response_format", "json")] {
        body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"\r\n\r\n\(value)\r\n".utf8))
    }
    body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"recording.\(fileExtension)\"\r\nContent-Type: \(mime)\r\n\r\n".utf8))
    body.append(data)
    body.append(Data("\r\n--\(boundary)--\r\n".utf8))
    return body
}

// decodedOpenAITranscript(data, response): Decode only completed text and show
// actionable failures without exposing response bodies or keys.
func decodedOpenAITranscript(data: Data, response: URLResponse) throws -> String {
    // Require an HTTP status before interpreting the provider response.
    guard let response = response as? HTTPURLResponse else {
        throw HelperFailure(message: "OpenAI returned an unreadable response.")
    }
    // Translate failed HTTP statuses into useful, bounded error messages.
    guard (200..<300).contains(response.statusCode) else {
        let detail: String
        // Authentication, billing limits, and request limits each need a different user action.
        switch response.statusCode {
        case 401: detail = "Check your OpenAI API key in Settings → Models."
        case 403: detail = "Your OpenAI account does not have access to this transcription model."
        case 413: detail = "The recording is too large. Export a smaller file and try again."
        case 429: detail = "Check your OpenAI billing and usage limits, or try again later."
        case 500...599: detail = "OpenAI is temporarily unavailable. Try again later."
        default: detail = "OpenAI could not transcribe this recording."
        }
        throw HelperFailure(message: "\(detail) (HTTP \(response.statusCode))")
    }
    // Require transcript text in the successful JSON response.
    guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let text = object["text"] as? String else {
        throw HelperFailure(message: "OpenAI returned no readable transcript.")
    }
    return try checkedAudioTranscript(text)
}

// Report upload progress and reject redirects, preventing a recording from reaching another host.
final class AudioUploadDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    private let progress: @Sendable (AudioTranscriptionProgress) -> Void

    // init(progress): Keep the callback immutable while URLSession invokes it
    // on its delegate queue.
    init(progress: @escaping @Sendable (AudioTranscriptionProgress) -> Void) { self.progress = progress }

    // urlSession(session, task, bytesSent, totalBytesSent,
    // totalBytesExpectedToSend): After upload, show transcription progress as
    // indeterminate until a response arrives.
    func urlSession(_ session: URLSession, task: URLSessionTask, didSendBodyData bytesSent: Int64,
                    totalBytesSent: Int64, totalBytesExpectedToSend: Int64) {
        // Show a fraction while a known upload length remains incomplete.
        if totalBytesExpectedToSend > 0 && totalBytesSent < totalBytesExpectedToSend {
            progress(.init(message: "Uploading to OpenAI…", fraction: Double(totalBytesSent) / Double(totalBytesExpectedToSend)))
        } else {
            // Use indeterminate progress while waiting for transcription.
            progress(.init(message: "Transcribing with OpenAI…"))
        }
    }

    // urlSession(session, task, response, request, completionHandler): The user
    // approved this endpoint only; return the redirect response as an error.
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

// requestOpenAITranscript(url, apiKey, session, progress): Execute one request
// with no automatic retries, which could bill the same recording twice.
func requestOpenAITranscript(_ url: URL, apiKey: String, session: URLSession,
                            progress: @escaping @Sendable (AudioTranscriptionProgress) -> Void) async throws -> String {
    try Task.checkCancellation()
    try validateOpenAIAudioFile(url)
    // Fail before uploading if no usable API key was supplied.
    guard !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
        throw HelperFailure(message: "Add your OpenAI API key in Settings → Models before transcribing.")
    }
    let boundary = "Langmin-" + UUID().uuidString
    // Reading at most the accepted limit also catches a file that grows after its size check.
    let file = try FileHandle(forReadingFrom: url)
    defer { try? file.close() }
    let data = try file.read(upToCount: openAITranscriptionFileLimit + 1) ?? Data()
    let body = try openAIAudioMultipart(data: data, fileExtension: url.pathExtension.lowercased(), boundary: boundary)
    try Task.checkCancellation()
    var request = URLRequest(url: openAITranscriptionEndpoint)
    request.httpMethod = "POST"
    request.timeoutInterval = 120
    request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
    request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
    progress(.init(message: "Uploading to OpenAI…", fraction: 0))
    let (responseData, response) = try await session.upload(for: request, from: body, delegate: AudioUploadDelegate(progress: progress))
    try Task.checkCancellation()
    return try decodedOpenAITranscript(data: responseData, response: response)
}

// transcribeOpenAIAudioFile(url, progress): Recheck Pro access before reading
// an API key or starting the upload.
func transcribeOpenAIAudioFile(_ url: URL, progress: @escaping @Sendable (AudioTranscriptionProgress) -> Void) async throws -> String {
    // Recheck access before reading credentials or sending audio.
    guard await MainActor.run(body: { ProStore.shared.hasFullAccess }) else {
        throw HelperFailure(message: "OpenAI transcription requires Langmin Pro.")
    }
    try Task.checkCancellation()
    try validateOpenAIAudioFile(url)
    let key = loadOpenAIAPIKey()
    let configuration = URLSessionConfiguration.ephemeral
    configuration.timeoutIntervalForResource = 600
    configuration.urlCache = nil
    configuration.httpCookieStorage = nil
    let session = URLSession(configuration: configuration)
    defer { session.invalidateAndCancel() }
    return try await requestOpenAITranscript(url, apiKey: key, session: session, progress: progress)
}

import Cocoa

// refreshVoiceCatalogAfterUse(provider): Refresh a used provider's voice
// catalog and update voice menus on the main queue.
func refreshVoiceCatalogAfterUse(provider: NarrationProvider) {
    DispatchQueue.main.async {
        let refreshMenus = {
            // Skip menu refresh when the app delegate is no longer available.
            guard let delegate = NSApp.delegate as? AppDelegate else {
                return
            }
            delegate.preferencesController.refreshVoiceMenu()
        }

        // Refresh only the catalog belonging to the speech provider that was used.
        switch provider {
        case .apple:
            // Settings refreshes the installed Apple voice list.
            break
        // Refresh Grok's network catalog once per successful app-run refresh.
        case .grok:
            // Avoid repeated Grok catalog requests after a successful refresh.
            guard !grokVoiceCatalogRefreshedThisRun else {
                return
            }
            grokVoiceCatalogRefreshedThisRun = true
            fetchGrokVoices(then: refreshMenus)
        // Refresh OpenAI's network catalog once per successful app-run refresh.
        case .openAI:
            // Avoid repeated OpenAI catalog requests after a successful refresh.
            guard !openAIVoiceCatalogRefreshedThisRun else {
                return
            }
            openAIVoiceCatalogRefreshedThisRun = true
            fetchOpenAIVoices(then: refreshMenus)
        }
    }
}

// fetchGrokVoices(refresh): Fetch the Grok voice catalog only when a provider
// key and endpoint are available.
func fetchGrokVoices(then refresh: @escaping () -> Void) {
    let key = loadGrokAPIKey()
    // Skip the catalog request without an xAI key or a valid endpoint.
    guard !key.isEmpty, let url = URL(string: "\(grokAPIBaseURL)/tts/voices") else {
        return
    }
    var request = URLRequest(url: url)
    request.timeoutInterval = 30
    request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
    URLSession.shared.dataTask(with: request) { data, response, _ in
        // Cache only a successful, valid, nonempty Grok catalog response.
        guard
            let data,
            let http = response as? HTTPURLResponse,
            (200..<300).contains(http.statusCode),
            !parseGrokVoices(data).isEmpty
        // Keep existing catalog state when the refresh fails validation.
        else {
            return
        }
        storeGrokVoices(data)
        DispatchQueue.main.async {
            refresh()
        }
    }.resume()
}

// fetchOpenAIVoices(refresh): Try the configured OpenAI voices endpoint and
// retain built-in voices if it is unavailable.
func fetchOpenAIVoices(then refresh: @escaping () -> Void) {
    let key = loadOpenAIAPIKey()
    // Skip voice discovery until an API key is available.
    guard !key.isEmpty, let url = URL(string: "https://api.openai.com/v1/audio/voices") else {
        return
    }
    var request = URLRequest(url: url)
    request.timeoutInterval = 30
    request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
    URLSession.shared.dataTask(with: request) { data, response, _ in
        // Cache only a successful OpenAI response containing usable voice names.
        guard
            let data,
            let http = response as? HTTPURLResponse,
            (200..<300).contains(http.statusCode),
            !parseOpenAIVoiceNames(data).isEmpty
        // Keep existing OpenAI catalog state when refresh fails validation.
        else {
            return
        }
        storeOpenAIVoices(data)
        DispatchQueue.main.async {
            refresh()
        }
    }.resume()
}

// startSpeechRequest(apiKey, text, model, voice, outputURL, completion):
// Request speech from OpenAI and write the returned MP3 to disk.
func startSpeechRequest(
    apiKey: String,
    text: String,
    model: String,
    voice: String,
    outputURL: URL,
    completion: @escaping (Result<Void, Error>) -> Void
) throws -> NarrationRequestTask {
    var request = URLRequest(url: openAISpeechEndpoint)
    request.httpMethod = "POST"
    request.timeoutInterval = speechRequestTimeout
    request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    var body: [String: Any] = [
        "model": model,
        "voice": voice,
        "response_format": "mp3",
        "input": text
    ]
    // Add the newer audio stream format only for models that support it.
    if !["tts-1", "tts-1-hd"].contains(model) {
        body["stream_format"] = "audio"
    }
    request.httpBody = try JSONSerialization.data(withJSONObject: body)

    return RetryingDataTask(request: request) { data, response, error in
        // Propagate OpenAI speech transport failures before inspecting the body.
        if let error {
            completion(.failure(error))
            return
        }

        // Report an absent audio response instead of creating an empty output file.
        guard let data else {
            completion(.failure(HelperFailure(message: "OpenAI returned no audio.")))
            return
        }

        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        // Handle HTTP failures before treating response bytes as OpenAI audio.
        guard (200..<300).contains(status) else {
            let message = openAIErrorMessage(from: data)
                ?? "OpenAI speech request failed with HTTP status \(status)."
            completion(.failure(HelperFailure(message: message)))
            return
        }

        // Write the OpenAI recording atomically before reporting speech completion.
        do {
            try data.write(to: outputURL, options: .atomic)
            completion(.success(()))
        } catch {
            // Report failure to persist the generated OpenAI audio.
            completion(.failure(error))
        }
    }
}

// startGrokSpeechRequest(apiKey, text, voiceID, outputURL, completion):
// Generate one MP3 file through xAI's native /v1/tts endpoint.
func startGrokSpeechRequest(
    apiKey: String,
    text: String,
    voiceID: String,
    outputURL: URL,
    completion: @escaping (Result<Void, Error>) -> Void
) throws -> NarrationRequestTask {
    // Reject an invalid Grok speech endpoint before constructing its request.
    guard let url = URL(string: "\(grokAPIBaseURL)/tts") else {
        throw HelperFailure(message: "The Grok speech URL is not valid.")
    }
    var request = URLRequest(url: url)
    request.httpMethod = "POST"
    request.timeoutInterval = speechRequestTimeout
    request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.httpBody = try JSONSerialization.data(withJSONObject: [
        "text": text,
        "voice_id": voiceID,
        "language": "auto",
        "output_format": ["codec": "mp3", "sample_rate": 44100, "bit_rate": 128000]
    ])

    return RetryingDataTask(request: request) { data, response, error in
        // Propagate Grok speech transport failures before inspecting the body.
        if let error {
            completion(.failure(error))
            return
        }

        // Report an absent Grok audio response.
        guard let data else {
            completion(.failure(HelperFailure(message: "Grok returned no audio.")))
            return
        }

        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        // Handle HTTP failures before treating response bytes as Grok audio.
        guard (200..<300).contains(status) else {
            let detail = openAIErrorMessage(from: data).map { ": \($0)" } ?? "."
            completion(.failure(HelperFailure(message: "Grok speech request failed (HTTP \(status))\(detail)")))
            return
        }

        // Write the Grok recording atomically before exposing its output path.
        do {
            try data.write(to: outputURL, options: .atomic)
            completion(.success(()))
        } catch {
            // Report failure to persist the generated Grok audio.
            completion(.failure(error))
        }
    }
}

// Refresh catalogs once per app session after a successful speech request.
var grokVoiceCatalogRefreshedThisRun = false
var openAIVoiceCatalogRefreshedThisRun = false

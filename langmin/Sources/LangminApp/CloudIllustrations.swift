import Cocoa

// dictionaryImageRequest(apiKey, prompt): Do not retry image requests
// automatically: a retry could incur another charge. The caller handles
// cancellation and rejects outdated results.
func dictionaryImageRequest(apiKey: String, prompt: String) throws -> URLRequest {
    var request = URLRequest(url: dictionaryImageEndpoint)
    request.httpMethod = "POST"
    request.timeoutInterval = 180
    request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.httpBody = try JSONSerialization.data(withJSONObject: [
        "model": dictionaryImageModel, "prompt": prompt, "n": 1,
        "size": "1536x1024", "quality": "medium", "output_format": "png"
    ])
    return request
}

// parseDictionaryImageResponse(data, statusCode): Validate the provider
// response and decode a bounded PNG image payload.
func parseDictionaryImageResponse(data: Data, statusCode: Int) throws -> Data {
    // Handle image-provider HTTP errors before decoding generated assets.
    guard (200..<300).contains(statusCode) else {
        throw HelperFailure(message: openAIErrorMessage(from: data) ?? "OpenAI image request failed (HTTP \(statusCode)).")
    }
    // Require a bounded response containing a usable base64 image payload.
    guard data.count <= 30 * 1024 * 1024,
          let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
          let images = object["data"] as? [[String: Any]],
          let encoded = images.first?["b64_json"] as? String,
          let decoded = Data(base64Encoded: encoded)
    // Report a successful response that contains no usable illustration.
    else { throw HelperFailure(message: "OpenAI did not return an illustration.") }
    return try dictionaryIllustrationPNG(from: decoded)
}

// startDictionaryImageRequest(apiKey, prompt, [session = .shared], completion):
// Allow a test URLSession to replace the network transport.
func startDictionaryImageRequest(apiKey: String, prompt: String, session: URLSession = .shared,
                                 completion: @escaping (Result<Data, Error>) -> Void) throws -> URLSessionDataTask {
    let request = try dictionaryImageRequest(apiKey: apiKey, prompt: prompt)
    return session.dataTask(with: request) { data, response, error in
        completion(Result {
            // Propagate the request's transport error before validating its HTTP response.
            if let error { throw error }
            // Require both response bytes and HTTP metadata before parsing the illustration.
            guard let data, let response = response as? HTTPURLResponse else {
                throw HelperFailure(message: "OpenAI returned an empty image response.")
            }
            return try parseDictionaryImageResponse(data: data, statusCode: response.statusCode)
        })
    }
}

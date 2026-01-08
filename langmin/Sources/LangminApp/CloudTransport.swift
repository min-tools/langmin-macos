import Cocoa

// Retry selected connection failures after a short delay. A dropped connection
// does not prove that the server never received the request.
final class RetryingDataTask: NarrationRequestTask, @unchecked Sendable {
    // Retry connection errors only. Return HTTP, TLS, timeout and cancellation errors immediately.
    private static let transientCodes: Set<URLError.Code> = [
        .networkConnectionLost,
        .cannotConnectToHost,
        .notConnectedToInternet,
        .dnsLookupFailed
    ]

    private let request: URLRequest
    private let handler: (Data?, URLResponse?, Error?) -> Void
    private let retryDelays: [TimeInterval]
    private let lock = NSLock()
    private var attempt = 0
    private var cancelled = false
    private var currentTask: URLSessionDataTask?

    // init(request, [retryDelays = [0.5, 1.5]], handler): Capture the request,
    // bounded retry delays, and final response handler.
    init(
        request: URLRequest,
        retryDelays: [TimeInterval] = [0.5, 1.5],
        handler: @escaping (Data?, URLResponse?, Error?) -> Void
    ) {
        self.request = request
        self.retryDelays = retryDelays
        self.handler = handler
    }

    // resume(): Start the first attempt through the shared resumable-request
    // interface.
    func resume() {
        startAttempt()
    }

    // cancel(): Mark cancellation under the lock before cancelling the current
    // network task.
    func cancel() {
        lock.lock()
        cancelled = true
        let task = currentTask
        lock.unlock()
        task?.cancel()
    }

    // startAttempt(): Start one network attempt and either schedule an eligible
    // retry or deliver its response.
    private func startAttempt() {
        let task = URLSession.shared.dataTask(with: request) { [self] data, response, error in
            // Schedule another attempt only for an eligible transport error.
            if let error, shouldRetry(error) {
                scheduleRetry()
                return
            }
            handler(data, response, error)
        }
        lock.lock()
        let wasCancelled = cancelled
        currentTask = task
        lock.unlock()
        // Cancelling a not-yet-resumed task still delivers the standard
        // cancellation error to the handler, matching URLSessionDataTask.
        if wasCancelled {
            task.cancel()
        }
        task.resume()
    }

    // shouldRetry(error): Retry only eligible connection errors while retry
    // capacity remains and cancellation has not occurred.
    private func shouldRetry(_ error: Error) -> Bool {
        lock.lock()
        // Release the retry-state lock on every decision path.
        defer { lock.unlock() }
        // Do not retry after cancellation or after exhausting the configured retry delays.
        guard !cancelled, attempt < retryDelays.count else { return false }
        // Non-URL errors are outside the connection-retry policy.
        guard let urlError = error as? URLError else { return false }
        return Self.transientCodes.contains(urlError.code)
    }

    // scheduleRetry(): Reserve the next delay and restart only if the request
    // remains uncancelled.
    private func scheduleRetry() {
        lock.lock()
        let delay = retryDelays[attempt]
        attempt += 1
        lock.unlock()
        DispatchQueue.global().asyncAfter(deadline: .now() + delay) { [self] in
            lock.lock()
            let wasCancelled = cancelled
            lock.unlock()
            // Report cancellation even when a retry is waiting and has no active task.
            guard !wasCancelled else {
                handler(nil, nil, URLError(.cancelled))
                return
            }
            startAttempt()
        }
    }
}

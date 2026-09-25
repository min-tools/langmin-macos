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
    private let session: URLSession
    private let totalTimeout: TimeInterval?
    private var deadline: DispatchWorkItem?
    private var started = false
    private var finished = false
    private let lock = NSLock()
    private var attempt = 0
    private var cancelled = false
    private var currentTask: URLSessionDataTask?

    // init(request, [retryDelays], [totalTimeout], [session], handler): Capture
    // retry timing, an optional total deadline, and the final response handler.
    init(
        request: URLRequest,
        retryDelays: [TimeInterval] = [0.5, 1.5],
        totalTimeout: TimeInterval? = nil,
        session: URLSession = .shared,
        handler: @escaping (Data?, URLResponse?, Error?) -> Void
    ) {
        self.request = request
        self.retryDelays = retryDelays
        self.handler = handler
        self.totalTimeout = totalTimeout
        self.session = session
    }

    // resume(): Start the first attempt through the shared resumable-request
    // interface.
    func resume() {
        lock.lock()
        // Starting twice must not issue duplicate paid requests.
        guard !started, !finished else { lock.unlock(); return }
        started = true
        // A wall-clock deadline also bounds retries and provider keep-alives.
        if let totalTimeout {
            let work = DispatchWorkItem { [weak self] in
                self?.finish(nil, nil, URLError(.timedOut), cancelTask: true)
            }
            deadline = work
            DispatchQueue.global().asyncAfter(deadline: .now() + totalTimeout, execute: work)
        }
        lock.unlock()
        startAttempt()
    }

    // cancel(): Mark cancellation under the lock before cancelling the current
    // network task.
    func cancel() {
        lock.lock()
        cancelled = true
        lock.unlock()
        finish(nil, nil, URLError(.cancelled), cancelTask: true)
    }

    // finish(data, response, error, [cancelTask]): Complete once even when a
    // timeout, cancellation, retry and network callback race each other.
    private func finish(_ data: Data?, _ response: URLResponse?, _ error: Error?, cancelTask: Bool = false) {
        lock.lock()
        guard !finished else { lock.unlock(); return }
        finished = true
        let task = currentTask
        currentTask = nil
        let pendingDeadline = deadline
        deadline = nil
        lock.unlock()
        pendingDeadline?.cancel()
        if cancelTask { task?.cancel() }
        handler(data, response, error)
    }

    // startAttempt(): Start one network attempt and either schedule an eligible
    // retry or deliver its response.
    private func startAttempt() {
        let task = session.dataTask(with: request) { [self] data, response, error in
            // Schedule another attempt only for an eligible transport error.
            if let error, shouldRetry(error) {
                scheduleRetry()
                return
            }
            finish(data, response, error)
        }
        lock.lock()
        // A scheduled retry may lose a race against cancellation or the deadline.
        guard !finished, !cancelled else {
            lock.unlock()
            task.cancel()
            return
        }
        currentTask = task
        task.resume()
        lock.unlock()
    }

    // shouldRetry(error): Retry only eligible connection errors while retry
    // capacity remains and cancellation has not occurred.
    private func shouldRetry(_ error: Error) -> Bool {
        lock.lock()
        // Release the retry-state lock on every decision path.
        defer { lock.unlock() }
        // Do not retry after cancellation or after exhausting the configured retry delays.
        guard !finished, !cancelled, attempt < retryDelays.count else { return false }
        // Non-URL errors are outside the connection-retry policy.
        guard let urlError = error as? URLError else { return false }
        return Self.transientCodes.contains(urlError.code)
    }

    // scheduleRetry(): Reserve the next delay and restart only if the request
    // remains uncancelled.
    private func scheduleRetry() {
        lock.lock()
        // Completion can win between the retry decision and scheduling it.
        guard !finished, !cancelled, attempt < retryDelays.count else { lock.unlock(); return }
        let delay = retryDelays[attempt]
        attempt += 1
        lock.unlock()
        DispatchQueue.global().asyncAfter(deadline: .now() + delay) { [self] in
            lock.lock()
            let shouldStop = finished || cancelled
            lock.unlock()
            // Finished requests must never start a delayed retry.
            guard !shouldStop else { return }
            startAttempt()
        }
    }
}

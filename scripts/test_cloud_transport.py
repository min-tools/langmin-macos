#!/usr/bin/env python3
"""Exercise real URLSession retries, keep-alives, deadlines and cancellation offline."""
from pathlib import Path
import subprocess
import tempfile
from source_files import app_path, swift_fixture_args

folder = Path(tempfile.mkdtemp(prefix='langmin-cloud-transport-', dir='/private/tmp'))
source = r'''
import Foundation
protocol NarrationRequestTask: AnyObject, Sendable {
    func resume()
    func cancel()
}
// FixtureProtocol feeds URLSession real callbacks without a network connection.
final class FixtureProtocol: URLProtocol, @unchecked Sendable {
    static let lock = NSLock()
    static var attempts: [String: Int] = [:]
    private var stopped = false
    private let stateLock = NSLock()
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    // startLoading(): Simulate successful, slow, retrying and rejected providers.
    override func startLoading() {
        let path = request.url!.path
        Self.lock.lock()
        let attempt = (Self.attempts[path] ?? 0) + 1
        Self.attempts[path] = attempt
        Self.lock.unlock()
        if (path == "/retry" && attempt == 1) || path == "/retry-deadline" {
            client?.urlProtocol(self, didFailWithError: URLError(.networkConnectionLost))
            return
        }
        let status = path == "/http-error" ? 429 : 200
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: nil)!, cacheStoragePolicy: .notAllowed)
        // Keep-alive bytes repeatedly reset the inactivity timer; the total deadline must still fire.
        if path == "/keepalive" {
            for index in 1...30 {
                DispatchQueue.global().asyncAfter(deadline: .now() + Double(index) * 0.02) { [self] in
                    stateLock.lock()
                    defer { stateLock.unlock() }
                    if !stopped { client?.urlProtocol(self, didLoad: Data("\n".utf8)) }
                }
            }
            return
        }
        if path == "/cancel" { return }
        client?.urlProtocol(self, didLoad: Data("answer".utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    // stopLoading(): Suppress mock provider callbacks after URLSession cancels.
    override func stopLoading() { stateLock.lock(); stopped = true; stateLock.unlock() }
}
// Completion records callbacks under a lock to detect duplicate completion races.
final class Completion: @unchecked Sendable {
    let ready = DispatchSemaphore(value: 0)
    let lock = NSLock()
    var count = 0
    var error: URLError.Code?
    var status: Int?
    var text: String?
    func receive(_ data: Data?, _ response: URLResponse?, _ error: Error?) {
        lock.lock()
        count += 1
        self.error = (error as? URLError)?.code
        status = (response as? HTTPURLResponse)?.statusCode
        text = data.flatMap { String(data: $0, encoding: .utf8) }
        lock.unlock()
        ready.signal()
    }
}
func check(_ value: @autoclosure () -> Bool, _ name: String) {
    guard value() else { fatalError(name) }
}
@main struct Tests {
    static func main() {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [FixtureProtocol.self]
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }
        for path in ["success", "retry", "http-error", "keepalive", "retry-deadline", "cancel", "cancel-before-start"] {
            let result = Completion()
            let request = URLRequest(url: URL(string: "https://fixture.invalid/" + path)!, timeoutInterval: 1)
            let started = Date()
            let task = RetryingDataTask(request: request, retryDelays: [path == "retry-deadline" ? 0.3 : 0.01], totalTimeout: 0.15, session: session, handler: result.receive)
            if path == "cancel-before-start" { task.cancel() }
            task.resume()
            task.resume()
            if path == "cancel" { task.cancel() }
            check(result.ready.wait(timeout: .now() + 2) == .success, path + ": completion arrived")
            check(Date().timeIntervalSince(started) < 1, path + ": total deadline is bounded")
            // Wait past the original deadline and queued retry to catch late second callbacks.
            Thread.sleep(forTimeInterval: 0.4)
            result.lock.lock()
            check(result.count == 1, path + ": one completion")
            if path == "keepalive" || path == "retry-deadline" {
                check(result.error == .timedOut, path + ": timed out")
            } else if path.hasPrefix("cancel") {
                check(result.error == .cancelled, path + ": cancelled")
            } else {
                check(result.error == nil && result.text == "answer", path + ": complete response")
                check(result.status == (path == "http-error" ? 429 : 200), path + ": status preserved")
            }
            result.lock.unlock()
            FixtureProtocol.lock.lock()
            let attempts = FixtureProtocol.attempts["/" + path, default: 0]
            if path == "cancel" {
                check(attempts <= 1, path + ": cancellation may precede the first protocol callback")
            } else {
                check(attempts == (path == "cancel-before-start" ? 0 : path == "retry" ? 2 : 1), path + ": no duplicate or late request")
            }
            FixtureProtocol.lock.unlock()
            print("PASS " + path)
        }
        print("7 URLSession transport scenarios passed")
    }
}
'''
fixture = folder / 'TransportTests.swift'
fixture.write_text(source)
subprocess.run(['swiftc', *swift_fixture_args(), '-parse-as-library', '-module-cache-path', str(folder/'modules'), str(fixture), str(app_path('CloudTransport.swift')), '-o', str(folder/'tests')], check=True)
subprocess.run([str(folder/'tests')], check=True, timeout=20)

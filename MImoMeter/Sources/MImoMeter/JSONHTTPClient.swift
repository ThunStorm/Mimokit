import Foundation

enum HTTPError: Error, Equatable {
    case invalidResponse
    case timeout
    case transport(String)
    case status(Int)
}

protocol HTTPPerforming: Sendable {
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

/// Collects Set-Cookie headers across redirects so phase2 serviceToken is not lost.
final class CookieCaptureDelegate: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var setCookieHeaders: [String] = []

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        if let http = response as? HTTPURLResponse {
            capture(from: http)
        }
        completionHandler(.allow)
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        capture(from: response)
        completionHandler(request)
    }

    private func capture(from response: HTTPURLResponse) {
        var collected: [String] = []
        if let single = response.value(forHTTPHeaderField: "Set-Cookie") {
            collected.append(single)
        }
        for (key, value) in response.allHeaderFields {
            guard let key = key as? String, key.lowercased() == "set-cookie",
                  let value = value as? String else { continue }
            if !collected.contains(value) {
                collected.append(value)
            }
        }
        lock.lock()
        setCookieHeaders.append(contentsOf: collected)
        lock.unlock()
    }

    func allSetCookieHeaders() -> [String] {
        lock.lock()
        defer { lock.unlock() }
        return setCookieHeaders
    }

    func cookieValue(named name: String) -> String? {
        let lower = name.lowercased()
        for field in allSetCookieHeaders() {
            // Split on "; " attributes but keep the first name=value pair intact.
            let parts = field.split(separator: ";")
            guard let first = parts.first else { continue }
            let piece = first.trimmingCharacters(in: .whitespaces)
            guard piece.lowercased().hasPrefix(lower + "=") else { continue }
            let value = String(piece.dropFirst(name.count + 1))
            if !value.isEmpty { return value }
        }
        return nil
    }
}

struct URLSessionHTTPClient: HTTPPerforming {
    let session: URLSession

    init(timeout: TimeInterval = 10) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = timeout
        configuration.timeoutIntervalForResource = timeout
        configuration.waitsForConnectivity = false
        configuration.httpShouldSetCookies = true
        self.session = URLSession(configuration: configuration)
    }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                throw HTTPError.invalidResponse
            }
            return (data, http)
        } catch let error as HTTPError {
            throw error
        } catch let error as URLError where error.code == .timedOut {
            throw HTTPError.timeout
        } catch {
            throw HTTPError.transport(error.localizedDescription)
        }
    }
}

/// Follows redirects while remembering every Set-Cookie (needed for Xiaomi SSO phase2).
struct RedirectAwareHTTPClient: HTTPPerforming {
    let timeout: TimeInterval

    init(timeout: TimeInterval = 10) {
        self.timeout = timeout
    }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let delegate = CookieCaptureDelegate()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = timeout
        configuration.timeoutIntervalForResource = timeout
        configuration.waitsForConnectivity = false
        let session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }

        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                throw HTTPError.invalidResponse
            }
            // Attach captured Set-Cookie values onto the final response via userInfo-like side channel.
            // Callers that need cookies should use `sendCapturingCookies`.
            _ = delegate.allSetCookieHeaders()
            return (data, http)
        } catch let error as URLError where error.code == .timedOut {
            throw HTTPError.timeout
        } catch let error as HTTPError {
            throw error
        } catch {
            throw HTTPError.transport(error.localizedDescription)
        }
    }

    func sendCapturingCookies(_ request: URLRequest) async throws -> (Data, HTTPURLResponse, CookieCaptureDelegate) {
        let delegate = CookieCaptureDelegate()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = timeout
        configuration.timeoutIntervalForResource = timeout
        configuration.waitsForConnectivity = false
        let session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }

        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                throw HTTPError.invalidResponse
            }
            return (data, http, delegate)
        } catch let error as URLError where error.code == .timedOut {
            throw HTTPError.timeout
        } catch let error as HTTPError {
            throw error
        } catch {
            throw HTTPError.transport(error.localizedDescription)
        }
    }
}

enum JSONHTTP {
    static func cookieHeader(from cookies: [String: String]) -> String {
        cookies
            .sorted { $0.key < $1.key }
            .map { "\($0.key)=\($0.value)" }
            .joined(separator: "; ")
    }
}

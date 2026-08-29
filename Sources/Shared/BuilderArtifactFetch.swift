import Foundation

/// Platform-neutral bounded downloader for hosted-builder share artifacts.
/// The authorization token travels only in the `Authorization` header; request
/// URLs are fragment-free, redirects are forbidden, and streaming is capped at
/// the portable artifact size limit.
public protocol BuilderArtifactFetching: Sendable {
    func fetch(_ reference: BuilderArtifactShareReference) async throws -> Data
}

public enum BuilderArtifactFetchError: Error, Equatable, Sendable, LocalizedError {
    case requestFailed
    case redirectForbidden
    case crossOriginResponse
    case unexpectedStatus
    case invalidContentType
    case artifactTooLarge
    case cancelled

    public var errorDescription: String? {
        switch self {
        case .requestFailed: "The shared build could not be downloaded."
        case .redirectForbidden, .crossOriginResponse: "The shared-build server returned an unsafe response."
        case .unexpectedStatus: "The shared build is unavailable or expired."
        case .invalidContentType: "The shared-build server returned an unsupported format."
        case .artifactTooLarge: "The shared build exceeds the size limit."
        case .cancelled: "The shared-build download was cancelled."
        }
    }
}

/// Header-authorized, redirect-free, streaming-bounded share fetcher.
/// `protocolClasses` exists for URLProtocol-injected tests only.
public final class URLSessionBuilderArtifactFetcher: BuilderArtifactFetching, @unchecked Sendable {
    private let protocolClasses: [AnyClass]
    private let timeout: TimeInterval

    public init(protocolClasses: [AnyClass] = [], timeout: TimeInterval = 15) {
        self.protocolClasses = protocolClasses
        self.timeout = timeout
    }

    public func fetch(_ reference: BuilderArtifactShareReference) async throws -> Data {
        let loader = BoundedBuilderArtifactLoader(
            reference: reference,
            protocolClasses: protocolClasses,
            timeout: timeout
        )
        return try await withTaskCancellationHandler {
            try await loader.start()
        } onCancel: {
            loader.cancel()
        }
    }
}

final class BoundedBuilderArtifactLoader: NSObject, URLSessionDataDelegate, URLSessionTaskDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private let reference: BuilderArtifactShareReference
    private let configuration: URLSessionConfiguration
    private var session: URLSession?
    private var task: URLSessionDataTask?
    private var continuation: CheckedContinuation<Data, Error>?
    private var received = Data()
    private var completed = false

    init(reference: BuilderArtifactShareReference, protocolClasses: [AnyClass], timeout: TimeInterval) {
        self.reference = reference
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.urlCredentialStorage = nil
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        configuration.timeoutIntervalForRequest = timeout
        configuration.timeoutIntervalForResource = timeout
        configuration.waitsForConnectivity = false
        if !protocolClasses.isEmpty { configuration.protocolClasses = protocolClasses }
        self.configuration = configuration
        received.reserveCapacity(64 * 1024)
    }

    func start() async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            lock.lock()
            guard !completed else {
                lock.unlock()
                continuation.resume(throwing: BuilderArtifactFetchError.cancelled)
                return
            }
            self.continuation = continuation
            let session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
            self.session = session
            var request = URLRequest(
                url: reference.requestURL,
                cachePolicy: .reloadIgnoringLocalAndRemoteCacheData,
                timeoutInterval: configuration.timeoutIntervalForRequest
            )
            request.httpMethod = "GET"
            request.setValue(reference.authorizationHeaderValue, forHTTPHeaderField: "Authorization")
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            let task = session.dataTask(with: request)
            self.task = task
            lock.unlock()
            task.resume()
        }
    }

    func cancel() {
        finish(.failure(BuilderArtifactFetchError.cancelled))
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        completionHandler(nil)
        finish(.failure(BuilderArtifactFetchError.redirectForbidden))
    }

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        guard let response = response as? HTTPURLResponse else {
            completionHandler(.cancel)
            finish(.failure(BuilderArtifactFetchError.requestFailed))
            return
        }
        guard response.url == reference.requestURL else {
            completionHandler(.cancel)
            finish(.failure(BuilderArtifactFetchError.crossOriginResponse))
            return
        }
        guard response.statusCode == 200 else {
            completionHandler(.cancel)
            finish(.failure(BuilderArtifactFetchError.unexpectedStatus))
            return
        }
        guard response.mimeType?.lowercased() == "application/json" else {
            completionHandler(.cancel)
            finish(.failure(BuilderArtifactFetchError.invalidContentType))
            return
        }
        let length = response.expectedContentLength
        guard length == -1
                || (length >= 0 && length <= Int64(PortableProfileArtifact.maximumBytes))
        else {
            completionHandler(.cancel)
            finish(.failure(BuilderArtifactFetchError.artifactTooLarge))
            return
        }
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        lock.lock()
        guard !completed else { lock.unlock(); return }
        guard data.count <= PortableProfileArtifact.maximumBytes,
              received.count <= PortableProfileArtifact.maximumBytes - data.count
        else {
            lock.unlock()
            dataTask.cancel()
            finish(.failure(BuilderArtifactFetchError.artifactTooLarge))
            return
        }
        received.append(data)
        lock.unlock()
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if error != nil {
            finish(.failure(BuilderArtifactFetchError.requestFailed))
        } else {
            lock.lock()
            let data = received
            lock.unlock()
            finish(.success(data))
        }
    }

    private func finish(_ result: Result<Data, Error>) {
        lock.lock()
        guard !completed else { lock.unlock(); return }
        completed = true
        let continuation = self.continuation
        self.continuation = nil
        let task = self.task
        self.task = nil
        let session = self.session
        self.session = nil
        lock.unlock()
        task?.cancel()
        session?.finishTasksAndInvalidate()
        continuation?.resume(with: result)
    }
}

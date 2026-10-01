import Foundation

/// Credentials never enter the disk-backed URL cache or a cross-origin redirect.
enum ProviderHTTP {
    static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.urlCache = nil; config.httpCookieStorage = nil
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: config,delegate: RedirectPolicy(),delegateQueue: nil)
    }()
    static func permitsRedirect(from original: URL?, to target: URL?) -> Bool {
        guard let original, let target else { return false }
        return original.scheme == "https" && target.scheme == "https" && original.host == target.host && (original.port ?? 443) == (target.port ?? 443)
    }
    private final class RedirectPolicy: NSObject, URLSessionTaskDelegate {
        func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
            completionHandler(ProviderHTTP.permitsRedirect(from: task.originalRequest?.url,to: request.url) ? request : nil)
        }
    }
}

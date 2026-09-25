import Foundation

public struct HTTPClient: Sendable {
    public static let shared = HTTPClient()

    private let session: URLSession

    public init(timeout: TimeInterval = 20) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = timeout
        configuration.timeoutIntervalForResource = timeout * 2
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.httpAdditionalHeaders = ["User-Agent": AppInfo.userAgent, "Accept": "application/json"]
        session = URLSession(configuration: configuration)
    }

    /// Performs the request and maps transport/status failures onto `ProviderIssue`.
    public func json(_ request: URLRequest) async throws -> JSON {
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch let error as URLError {
            switch error.code {
            case .timedOut:
                throw ProviderIssue.timeout
            case .notConnectedToInternet, .networkConnectionLost, .cannotFindHost, .cannotConnectToHost,
                 .dnsLookupFailed, .dataNotAllowed, .internationalRoamingOff, .secureConnectionFailed:
                throw ProviderIssue.offline
            case .cancelled:
                throw CancellationError()
            default:
                throw ProviderIssue.unexpected(error.localizedDescription)
            }
        }

        guard let http = response as? HTTPURLResponse else { throw ProviderIssue.unexpected("Invalid response") }
        switch http.statusCode {
        case 200..<300:
            break
        case 401, 403:
            throw ProviderIssue.unauthorized
        case 429:
            throw ProviderIssue.rateLimited
        default:
            throw ProviderIssue.server(status: http.statusCode)
        }

        do {
            return try JSON(data: data)
        } catch {
            throw ProviderIssue.unexpected("Could not parse the response")
        }
    }

    /// Connect-protocol unary call with a JSON body, as used by the Cursor and Devin backends.
    public func connect(_ url: URL, body: Data = Data("{}".utf8), bearer: String? = nil) async throws -> JSON {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = body
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("1", forHTTPHeaderField: "Connect-Protocol-Version")
        if let bearer { request.setValue("Bearer \(bearer)", forHTTPHeaderField: "Authorization") }
        return try await json(request)
    }
}

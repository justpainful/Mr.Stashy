import Foundation
@testable import MrStashy

/// Serves canned responses so extractors can be exercised without a network.
struct StubTransport: HTTPTransport {
    struct Route {
        var matches: @Sendable (URLRequest) -> Bool
        var status: Int
        var body: Data
        var contentType: String
        var finalURL: URL?
    }

    final class Log: @unchecked Sendable {
        private let lock = NSLock()
        private(set) var requests: [URLRequest] = []
        func record(_ request: URLRequest) {
            lock.lock()
            requests.append(request)
            lock.unlock()
        }
    }

    var routes: [Route]
    let log = Log()

    func perform(_ request: URLRequest) async throws -> HTTPResponse {
        log.record(request)
        guard let route = routes.first(where: { $0.matches(request) }) else {
            return HTTPResponse(data: Data("<html>not found</html>".utf8), status: 404, headers: ["content-type": "text/html"], finalURL: request.url!)
        }
        return HTTPResponse(data: route.body, status: route.status, headers: ["content-type": route.contentType, "content-length": String(route.body.count)], finalURL: route.finalURL ?? request.url!)
    }

    static func json(_ contains: String, _ body: String, status: Int = 200) -> Route {
        Route(matches: { $0.url?.absoluteString.contains(contains) == true }, status: status, body: Data(body.utf8), contentType: "application/json; charset=utf-8")
    }

    static func html(_ contains: String, _ body: String, status: Int = 200) -> Route {
        Route(matches: { $0.url?.absoluteString.contains(contains) == true }, status: status, body: Data(body.utf8), contentType: "text/html; charset=utf-8")
    }

    static func media(_ contains: String, type: String, bytes: Int = 4096) -> Route {
        Route(matches: { $0.url?.absoluteString.contains(contains) == true }, status: 206, body: Data(repeating: 0, count: bytes), contentType: type)
    }
}

extension ExtractorRegistry {
    static func stubbed(_ routes: [StubTransport.Route], credentials: any CredentialSource = NoCredentials()) -> ExtractorRegistry {
        ExtractorRegistry(client: HTTPClient(transport: StubTransport(routes: routes)), credentials: credentials)
    }
}

struct StaticCredentials: CredentialSource {
    var values: [Credential: String]
    func value(for credential: Credential) -> String? { values[credential] }
}

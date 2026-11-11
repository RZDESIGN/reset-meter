import AppKit
import CryptoKit
import Foundation
import Security

/// Cursor's official desktop PKCE browser exchange (`loginDeepControl`), used when Cursor 3.29+
/// encrypts its local `state.vscdb` token at rest and `cursor-agent` CLI is not signed in.
public enum CursorLogin {
    public struct Challenge: Sendable {
        public let id: String
        public let verifier: String

        public init() throws {
            var bytes = [UInt8](repeating: 0, count: 32)
            guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
                throw UsageReadError.cursorLoginFailed
            }
            id = UUID().uuidString
            verifier = Self.base64URL(Data(bytes))
        }

        public init(id: String, verifier: String) {
            self.id = id
            self.verifier = verifier
        }

        public var loginURL: URL {
            var url = URLComponents(string: "https://cursor.com/loginDeepControl")!
            let digest = Data(SHA256.hash(data: Data(verifier.utf8)))
            url.queryItems = [
                URLQueryItem(name: "challenge", value: Self.base64URL(digest)),
                URLQueryItem(name: "uuid", value: id),
                URLQueryItem(name: "mode", value: "login"),
            ]
            return url.url!
        }

        public var pollRequest: URLRequest {
            var url = URLComponents(string: "https://api2.cursor.sh/auth/poll")!
            url.queryItems = [
                URLQueryItem(name: "uuid", value: id),
                URLQueryItem(name: "verifier", value: verifier),
            ]
            var request = URLRequest(url: url.url!)
            request.httpShouldHandleCookies = false
            request.timeoutInterval = 12
            request.setValue("true", forHTTPHeaderField: "x-ghost-mode")
            request.setValue("ide", forHTTPHeaderField: "x-cursor-client-type")
            return request
        }

        private static func base64URL(_ data: Data) -> String {
            data.base64EncodedString()
                .replacingOccurrences(of: "+", with: "-")
                .replacingOccurrences(of: "/", with: "_")
                .replacingOccurrences(of: "=", with: "")
        }
    }

    public static func signIn(account: ProviderAccount) async throws {
        guard account.isValid, account.provider == .cursor else {
            throw UsageReadError.cursorLoginFailed
        }
        let credentials = try await authenticate(
            challenge: Challenge(),
            openBrowser: { url in
                await MainActor.run { NSWorkspace.shared.open(url) }
            },
            request: { try await CursorHTTP.request($0) }
        )
        try Task.checkCancellation()
        try CursorCredentials.save(credentials, account: account)
    }

    public static func disconnect(account: ProviderAccount) {
        CursorCredentials.remove(account: account)
    }

    static func authenticate(
        challenge: Challenge,
        timeout: Duration = .seconds(180),
        pollInterval: Duration = .seconds(1),
        openBrowser: @Sendable (URL) async -> Bool,
        request: @Sendable (URLRequest) async throws -> (Data, HTTPURLResponse)
    ) async throws -> CursorCredentials {
        try Task.checkCancellation()
        guard await openBrowser(challenge.loginURL) else {
            throw UsageReadError.cursorLoginFailed
        }
        let deadline = ContinuousClock.now.advanced(by: timeout)
        do {
            while ContinuousClock.now < deadline {
                try Task.checkCancellation()
                let (data, response) = try await request(challenge.pollRequest)
                try Task.checkCancellation()
                switch response.statusCode {
                case 200:
                    guard let credentials = try? JSONDecoder().decode(CursorCredentials.self, from: data),
                          !credentials.accessToken.isEmpty,
                          !credentials.refreshToken.isEmpty else {
                        throw UsageReadError.cursorLoginFailed
                    }
                    return credentials
                case 404:
                    break
                default:
                    throw UsageReadError.cursorLoginFailed
                }
                try await Task.sleep(for: pollInterval)
            }
        } catch {
            try Task.checkCancellation()
            // Network diagnostics may contain the verifier URL; never surface them.
            throw UsageReadError.cursorLoginFailed
        }
        throw UsageReadError.cursorLoginFailed
    }

    static func refreshRequest(credentials: CursorCredentials) throws -> URLRequest {
        var request = URLRequest(url: URL(string: "https://api2.cursor.sh/oauth/token")!)
        request.httpMethod = "POST"
        request.timeoutInterval = 12
        request.httpShouldHandleCookies = false
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("ide", forHTTPHeaderField: "x-cursor-client-type")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "grant_type": "refresh_token",
            "client_id": "KbZUR41cY7W6zRSdpSUJ7I7mLYBKOCmB",
            "refresh_token": credentials.refreshToken,
        ])
        return request
    }

    static func refreshedCredentials(data: Data) throws -> CursorCredentials {
        guard let response = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              response["shouldLogout"] as? Bool != true,
              let token = response["access_token"] as? String,
              !token.isEmpty else {
            throw UsageReadError.cursorAuthorizationFailed
        }
        return CursorCredentials(
            accessToken: token,
            refreshToken: response["refresh_token"] as? String ?? token
        )
    }
}

enum CursorHTTP {
    static let session = URLSession(configuration: .ephemeral, delegate: NoRedirects(), delegateQueue: nil)

    static func request(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw UsageReadError.malformedCursorResponse
        }
        return (data, http)
    }

    private final class NoRedirects: NSObject, URLSessionTaskDelegate {
        func urlSession(
            _ session: URLSession,
            task: URLSessionTask,
            willPerformHTTPRedirection response: HTTPURLResponse,
            newRequest request: URLRequest,
            completionHandler: @escaping @Sendable (URLRequest?) -> Void
        ) {
            completionHandler(nil)
        }
    }
}

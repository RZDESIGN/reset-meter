import Foundation
import Testing
@testable import UsageMeterCore

@Test func cursorBrowserChallengeUsesPKCEAndKeepsVerifierOutOfBrowser() throws {
    // RFC 7636 S256 test vector.
    let verifier = "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk"
    let flow = CursorLogin.Challenge(id: "synthetic-id", verifier: verifier)
    let url = try #require(URLComponents(url: flow.loginURL, resolvingAgainstBaseURL: false))
    #expect(url.host == "cursor.com")
    #expect(url.queryItems?.first(where: { $0.name == "challenge" })?.value == "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM")
    #expect(!flow.loginURL.absoluteString.contains(verifier))
    #expect(flow.pollRequest.url?.host == "api2.cursor.sh")
    #expect(flow.pollRequest.url?.absoluteString.contains(verifier) == true)
    #expect(!flow.pollRequest.httpShouldHandleCookies)
    let first = try CursorLogin.Challenge()
    let second = try CursorLogin.Challenge()
    #expect(first.id != second.id)
    #expect(first.verifier != second.verifier)
    #expect(first.verifier.count == 43)
}

@Test func cursorBrowserSignInPollsUntilComplete() async throws {
    let server = CursorTestServer()
    let credentials = try await CursorLogin.authenticate(
        challenge: .init(id: "synthetic-id", verifier: "synthetic-verifier"), pollInterval: .milliseconds(1),
        openBrowser: { url in #expect(url.host == "cursor.com"); return true },
        request: { await server.poll($0) })
    #expect(credentials.accessToken == "synthetic-access")
    #expect(credentials.refreshToken == "synthetic-refresh")
    #expect(await server.pollCount == 2)
}

@Test(arguments: [200, 302, 403, 500]) func cursorBrowserLoginRejectsMalformedAndErrorResponses(status: Int) async {
    await #expect(throws: UsageReadError.self) {
        try await CursorLogin.authenticate(challenge: .init(id: "synthetic", verifier: "secret-verifier"),
            openBrowser: { _ in true }, request: { request in
                (Data(#"{"error":"private diagnostics"}"#.utf8), response(request, status: status))
            })
    }
}

@Test func cursorLoginTimeoutCancellationAndBrowserFailureDoNotStoreCredentials() async {
    await #expect(throws: UsageReadError.self) {
        try await CursorLogin.authenticate(challenge: .init(id: "synthetic", verifier: "synthetic"), timeout: .milliseconds(1),
            pollInterval: .milliseconds(1), openBrowser: { _ in true },
            request: { request in (Data(), response(request, status: 404)) })
    }
    await #expect(throws: UsageReadError.self) {
        try await CursorLogin.authenticate(challenge: .init(id: "synthetic", verifier: "synthetic"),
            openBrowser: { _ in false }, request: { request in
                Issue.record("Must not poll if the browser could not open"); return (Data(), response(request, status: 404))
            })
    }
    let task = Task {
        try await CursorLogin.authenticate(challenge: .init(id: "synthetic", verifier: "synthetic"),
            openBrowser: { _ in true }, request: { request in
                try await Task.sleep(for: .seconds(30)); return (Data(), response(request, status: 404))
            })
    }
    task.cancel()
    await #expect(throws: CancellationError.self) { try await task.value }
    do {
        _ = try await CursorLogin.authenticate(challenge: .init(id: "synthetic", verifier: "secret-verifier"),
            openBrowser: { _ in true }, request: { _ in
                throw NSError(domain: "Synthetic", code: 1, userInfo: [NSLocalizedDescriptionKey: "secret-verifier"])
            })
        Issue.record("Expected network failure")
    } catch { #expect(!error.localizedDescription.contains("secret-verifier")) }
}

@Test(arguments: [ConnectionMode.local, .login]) func cursorUsageOnlyReadsSelectedMode(mode: ConnectionMode) async throws {
    let server = CursorTestServer()
    let account = CursorAccount(id: "default", name: "Default", mode: mode)
    let usage = try await CursorUsageReader.fetch(account: account,
        loadLocal: { #expect(mode == .local); return "synthetic-local" },
        loadLogin: { selected in
            #expect(mode == .login); #expect(selected == account)
            return CursorCredentials(accessToken: "synthetic-login", refreshToken: "synthetic-refresh")
        }, saveLogin: { _ in Issue.record("No refresh needed") },
        request: { request in
            #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer synthetic-\(mode.rawValue)")
            return await server.usage(request)
        })
    #expect(usage.headlinePercent == 70)
}

@Test func cursorRenewsRejectedLoginOnceAndSavesOnlyRenewedCredentials() async throws {
    let server = CursorTestServer(rejectFirstUsage: true)
    let usage = try await CursorUsageReader.fetch(account: CursorAccount(name: "Work"),
        loadLocal: { Issue.record("Login cannot fall back to Local"); return "wrong" },
        loadLogin: { _ in CursorCredentials(accessToken: "synthetic-old", refreshToken: "synthetic-refresh") },
        saveLogin: { await server.save($0) }, request: { await server.usage($0) })
    #expect(usage.headlinePercent == 70)
    #expect(await server.usageCount == 2)
    #expect(await server.refreshCount == 1)
    #expect(await server.saved?.accessToken == "synthetic-new")
    #expect(await server.saved?.refreshToken == "synthetic-new")
}

@Test func cursorMissingLoginNeverReadsTheLocalAccount() async {
    await #expect(throws: UsageReadError.self) {
        try await CursorUsageReader.fetch(account: CursorAccount(name: "Work"),
            loadLocal: { Issue.record("Must not read Local"); return "wrong" },
            loadLogin: { _ in throw UsageReadError.cursorSignedOut },
            saveLogin: { _ in Issue.record("Must not save") },
            request: { request in Issue.record("Must not request"); return (Data(), response(request, status: 200)) })
    }
}

@Test func cursorExpiredCredentialsAndLogoutResponseRequireRenewal() throws {
    let jwt = "header." + Data(#"{"exp":1}"#.utf8).base64EncodedString() + ".signature"
    #expect(CursorCredentials(accessToken: jwt, refreshToken: "synthetic").needsRefresh())
    #expect(throws: UsageReadError.self) {
        try CursorLogin.refreshedCredentials(data: Data(#"{"shouldLogout":true,"access_token":"synthetic"}"#.utf8))
    }
}

private func response(_ request: URLRequest, status: Int) -> HTTPURLResponse {
    HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
}

private actor CursorTestServer {
    var pollCount = 0
    var usageCount = 0
    var refreshCount = 0
    var saved: CursorCredentials?
    let rejectFirstUsage: Bool
    init(rejectFirstUsage: Bool = false) { self.rejectFirstUsage = rejectFirstUsage }

    func poll(_ request: URLRequest) -> (Data, HTTPURLResponse) {
        pollCount += 1
        return (Data(#"{"accessToken":"synthetic-access","refreshToken":"synthetic-refresh"}"#.utf8),
                response(request, status: pollCount == 1 ? 404 : 200))
    }

    func save(_ credentials: CursorCredentials) { saved = credentials }

    func usage(_ request: URLRequest) -> (Data, HTTPURLResponse) {
        #expect(request.url?.host == "api2.cursor.sh")
        #expect(request.url?.scheme == "https")
        #expect(!request.httpShouldHandleCookies)
        if request.url?.path == "/oauth/token" {
            refreshCount += 1
            #expect(request.httpMethod == "POST")
            let body = request.httpBody.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: String] }
            #expect(body?["grant_type"] == "refresh_token")
            #expect(body?["refresh_token"] == "synthetic-refresh")
            return (Data(#"{"access_token":"synthetic-new"}"#.utf8), response(request, status: 200))
        }
        usageCount += 1
        if rejectFirstUsage {
            #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer synthetic-\(usageCount == 1 ? "old" : "new")")
        }
        return (Data(#"{"planUsage":{"autoPercentUsed":30}}"#.utf8),
                response(request, status: rejectFirstUsage && usageCount == 1 ? 401 : 200))
    }
}

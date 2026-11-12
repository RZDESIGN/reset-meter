import Foundation
import Testing
@testable import UsageMeterCore

@Test func cursorFirstPartyUsageDisplaysRemainingPercentResetAndPlan() throws {
    let data = #"{"billingCycleStart":"1785235728000","billingCycleEnd":"1787914128000","planUsage":{"autoPercentUsed":14.007142857142856,"apiPercentUsed":100}}"#.data(using: .utf8)!
    let now = Date(timeIntervalSince1970: 1_785_500_000)

    let usage = try CursorUsageReader.parse(data: data, now: now, planName: AccountPlan.cursor("pro"))

    #expect(usage.provider == .cursor)
    #expect(usage.headlinePercent == 86)
    #expect(usage.planName == "Pro")
    #expect(usage.limits.first?.label == "Composer + Grok")
    #expect(usage.limits.first?.resetsAt == Date(timeIntervalSince1970: 1_787_914_128))
}

@Test func cursorParsesEnterpriseSpendLimitsIncludedPoolsAndUnlimitedSeats() throws {
    // 1. Enterprise seat with individual + pooled spend limits
    let cappedData = """
    {
      "billingCycleEnd": "1787914128000",
      "spendLimitUsage": {
        "individualUsed": 2500,
        "individualLimit": 10000,
        "pooledUsed": 10000,
        "pooledLimit": 50000
      }
    }
    """.data(using: .utf8)!
    let capped = try CursorUsageReader.parse(
        data: cappedData,
        now: .now,
        planName: AccountPlan.cursor("enterprise")
    )
    #expect(capped.planName == "Enterprise")
    #expect(capped.limits.map(\.label) == ["Spend limit", "Team pool"])
    #expect(capped.headlinePercent == 75)
    #expect(capped.footnote == "$25 / $100 spend cap")

    // 2. Unified dollar planUsage where Protobuf3 omitted `autoPercentUsed` (0% used)
    let dollarPoolData = """
    {
      "billingCycleEnd": "1787914128000",
      "planUsage": {
        "includedSpend": 500,
        "limit": 2000
      }
    }
    """.data(using: .utf8)!
    let dollarPool = try CursorUsageReader.parse(
        data: dollarPoolData,
        now: .now,
        planName: AccountPlan.cursor("pro_plus")
    )
    #expect(dollarPool.planName == "Pro+")
    #expect(dollarPool.headlinePercent == 75)
    #expect(dollarPool.footnote == "$5 / $20 included")

    // 3. Unlimited Enterprise seat with uncapped cycle spend
    let unlimitedData = """
    {
      "billingCycleEnd": "1787914128000",
      "spendLimitUsage": {
        "totalSpend": 4250,
        "individualUsed": 4250,
        "limitType": "team"
      }
    }
    """.data(using: .utf8)!
    let unlimited = try CursorUsageReader.parse(
        data: unlimitedData,
        now: .now,
        planName: "Enterprise"
    )
    #expect(unlimited.headlinePercent == 100)
    #expect(unlimited.footnote == "$42.50 used this cycle · Unlimited")
}

@Test func cursorDetectsEncryptedDesktopStorageAndSupportsCLIAndPKCERefresh() async throws {
    let account = ProviderAccount.defaultAccount(for: .cursor)
    let encryptedState = CursorUsageReader.LocalCursorState(
        databaseExists: true,
        plaintextAccessToken: nil,
        isEncryptedAtRest: true,
        planName: "Enterprise"
    )

    // Without CLI or saved PKCE session, encrypted `cursor-safe-storage:v1:` surfaces explicit setup error.
    await #expect(throws: UsageReadError.cursorEncryptedLocalSession) {
        try await CursorUsageReader.fetchPipeline(
            account: account,
            localState: encryptedState,
            savedCredentials: nil,
            cliToken: nil,
            saveCredentials: { _ in },
            request: { _ in Issue.record("Encrypted ciphertext must never be sent to Cursor API"); throw UsageReadError.cursorSignedOut }
        )
    }

    // With local `cursor-agent` CLI token, usage resolves directly without needing browser login.
    let cliUsage = try await CursorUsageReader.fetchPipeline(
        account: account,
        localState: encryptedState,
        savedCredentials: nil,
        cliToken: "cli-valid-token",
        saveCredentials: { _ in },
        request: { req in
            #expect(req.value(forHTTPHeaderField: "Authorization") == "Bearer cli-valid-token")
            let body = #"{"billingCycleEnd":"1787914128000","planUsage":{"autoPercentUsed":20}}"#.data(using: .utf8)!
            return (body, HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }
    )
    #expect(cliUsage.headlinePercent == 80)
    #expect(cliUsage.planName == "Enterprise")

    // With saved PKCE credentials that return 401 first, CursorUsageReader refreshes via /oauth/token and retries.
    let savedBox = SavedBox()
    let renewedUsage = try await CursorUsageReader.fetchPipeline(
        account: account,
        localState: encryptedState,
        savedCredentials: CursorCredentials(accessToken: "expired-tok", refreshToken: "refresh-tok"),
        cliToken: nil,
        saveCredentials: { savedBox.saved = $0 },
        request: { req in
            if req.url?.path == "/oauth/token" {
                let body = #"{"access_token":"fresh-tok","refresh_token":"fresh-refresh"}"#.data(using: .utf8)!
                return (body, HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
            }
            let auth = req.value(forHTTPHeaderField: "Authorization")
            if auth == "Bearer expired-tok" {
                return (Data(), HTTPURLResponse(url: req.url!, statusCode: 401, httpVersion: nil, headerFields: nil)!)
            }
            #expect(auth == "Bearer fresh-tok")
            let body = #"{"billingCycleEnd":"1787914128000","planUsage":{"autoPercentUsed":10}}"#.data(using: .utf8)!
            return (body, HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }
    )
    #expect(renewedUsage.headlinePercent == 90)
    #expect(savedBox.saved?.accessToken == "fresh-tok")
}

@Test func cursorPKCEChallengeKeepsVerifierOutOfLoginURL() {
    let challenge = CursorLogin.Challenge(id: "uuid-123", verifier: "secret-verifier-value")
    #expect(challenge.loginURL.absoluteString.contains("challenge="))
    #expect(!challenge.loginURL.absoluteString.contains("secret-verifier-value"))
}

@Test func cursorUsageRejectsResponseWithoutFirstPartyPool() {
    let data = #"{"planUsage":{"apiPercentUsed":100}}"#.data(using: .utf8)!

    #expect(throws: UsageReadError.self) {
        try CursorUsageReader.parse(data: data, now: .now)
    }
}

@Test func cursorReadsLocalSQLiteStateAndRoundTripsBase64SecurityStdin() throws {
    let fm = FileManager.default
    let home = fm.temporaryDirectory.appending(path: "ResetMeterCursorSQLite-\(UUID().uuidString)")
    defer { try? fm.removeItem(at: home) }

    let dbDir = home.appending(path: "Library/Application Support/Cursor/User/globalStorage")
    try fm.createDirectory(at: dbDir, withIntermediateDirectories: true)
    let dbFile = dbDir.appending(path: "state.vscdb")

    let setupSQL = """
    CREATE TABLE ItemTable (key TEXT UNIQUE ON CONFLICT REPLACE, value BLOB);
    INSERT INTO ItemTable (key, value) VALUES ('cursorAuth/stripeMembershipType', '"enterprise"');
    INSERT INTO ItemTable (key, value) VALUES ('cursorAuth/accessToken', 'cursor-safe-storage:v1:encryptedpayload');
    """
    let initDB = SubprocessRunner.run(
        executable: URL(fileURLWithPath: "/usr/bin/sqlite3"),
        arguments: [dbFile.path, setupSQL]
    )
    #expect(initDB?.succeeded == true)

    let account = ProviderAccount.defaultAccount(for: .cursor)
    let state = CursorUsageReader.readLocalState(account: account, home: home)
    #expect(state.databaseExists)
    #expect(state.isEncryptedAtRest)
    #expect(state.plaintextAccessToken == nil)
    #expect(state.planName == "Enterprise")

    // Verify CursorCredentials.save writes quote-free Base64 to `security -i` stdin and readSaved decodes both Base64 and legacy JSON.
    let storeDir = fm.temporaryDirectory.appending(path: "ResetMeterCursorSec-\(UUID().uuidString)")
    try fm.createDirectory(at: storeDir, withIntermediateDirectories: true)
    defer { try? fm.removeItem(at: storeDir) }

    let capturedFile = storeDir.appending(path: "stdin.txt")
    let secretFile = storeDir.appending(path: "secret.txt")
    let fakeSec = storeDir.appending(path: "security")
    let script = """
    #!/bin/sh
    if [ "$1" = "-i" ]; then
      IFS= read -r line
      printf '%s' "$line" > '\(capturedFile.path)'
      secret=$(printf '%s' "$line" | sed -n 's/.*-w "\\([^"]*\\)".*/\\1/p')
      printf '%s' "$secret" > '\(secretFile.path)'
      exit 0
    fi
    if [ "$1" = "find-generic-password" ]; then
      [ -f '\(secretFile.path)' ] || exit 44
      cat '\(secretFile.path)'
      exit 0
    fi
    exit 0
    """
    try Data(script.utf8).write(to: fakeSec)
    try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: fakeSec.path)

    let creds = CursorCredentials(accessToken: "jwt-tok-123", refreshToken: "ref-tok-456")
    try CursorCredentials.save(creds, account: account, securityTool: fakeSec)

    let rawStdin = try String(contentsOf: capturedFile, encoding: .utf8)
    #expect(!rawStdin.contains("accessToken"))
    #expect(!rawStdin.contains("\\\""))

    let loaded = try CursorCredentials.readSaved(
        account: account,
        securityTool: fakeSec,
        allowLegacyFrameworkFallback: false
    )
    #expect(loaded == creds)
    #expect(CursorCredentials.decodeStoredCredentials(#"{"accessToken":"a","refreshToken":"b"}"#) == CursorCredentials(accessToken: "a", refreshToken: "b"))
}

private final class SavedBox: @unchecked Sendable {
    var saved: CursorCredentials?
}

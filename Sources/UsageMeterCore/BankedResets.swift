import Foundation

public enum ResetExpiration: Equatable, Sendable {
    case date(Date)
    case never
    case unknown
}

public struct BankedReset: Identifiable, Equatable, Sendable {
    public let id: String
    public let expiration: ResetExpiration

    public init(id: String, expiration: ResetExpiration) {
        self.id = id
        self.expiration = expiration
    }
}

public struct BankedResets: Equatable, Sendable {
    /// The backend count is authoritative: the detail list may be capped.
    public let availableCount: Int
    public let credits: [BankedReset]?

    public init(availableCount: Int, credits: [BankedReset]?) {
        self.availableCount = availableCount
        self.credits = credits
    }

    public var missingDetailCount: Int {
        max(0, availableCount - (credits?.count ?? 0))
    }

    static func parse(_ raw: Any?) -> BankedResets? {
        struct Count: Decodable { let availableCount: Int }
        struct Expiry: Decodable { let expiresAt: Int64 }
        guard let object = raw as? [String: Any],
              let data = try? JSONSerialization.data(withJSONObject: object),
              let count = try? JSONDecoder().decode(Count.self, from: data).availableCount,
              count >= 0 else { return nil }

        var seen = Set<String>()
        let credits = (object["credits"] as? [Any])?.compactMap { raw -> BankedReset? in
            guard let row = raw as? [String: Any],
                  row["status"] as? String == "available",
                  let id = row["id"] as? String, !id.isEmpty,
                  seen.insert(id).inserted else { return nil }
            let expiration: ResetExpiration
            if row["expiresAt"] is NSNull {
                expiration = .never
            } else if let data = try? JSONSerialization.data(withJSONObject: row),
                      let timestamp = try? JSONDecoder().decode(Expiry.self, from: data).expiresAt {
                expiration = .date(Date(timeIntervalSince1970: Double(timestamp)))
            } else {
                expiration = .unknown
            }
            return BankedReset(id: id, expiration: expiration)
        }.sorted { lhs, rhs in
            let left = if case .date(let date) = lhs.expiration { date } else { Date.distantFuture }
            let right = if case .date(let date) = rhs.expiration { date } else { Date.distantFuture }
            return left == right ? lhs.id < rhs.id : left < right
        }
        return BankedResets(availableCount: count, credits: credits.map { Array($0.prefix(count)) })
    }
}

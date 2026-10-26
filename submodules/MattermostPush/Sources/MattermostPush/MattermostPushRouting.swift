import Foundation

/// A signed-in Mattermost account as the notification extension sees it (account record + sync store).
public struct MattermostPushAccount: Equatable, Sendable {
    /// `AccountRecordId` value.
    public var accountId: Int64
    public var serverURL: String
    /// The server's `DiagnosticId` (= `server_id` of its pushes), when known.
    public var serverId: String?
    public var userId: String
    public var username: String?
    /// Position in the account list (lower first).
    public var order: Int

    public init(accountId: Int64, serverURL: String, serverId: String?, userId: String, username: String?, order: Int) {
        self.accountId = accountId
        self.serverURL = serverURL
        self.serverId = serverId
        self.userId = userId
        self.username = username
        self.order = order
    }
}

/// The outcome of `MattermostPushRouter.route`.
public struct MattermostPushRoute: Equatable, Sendable {
    public var account: MattermostPushAccount?
    /// Accounts that could have received the push after every filter, before the tie-break.
    public var candidateIds: [Int64]
    /// How the account was chosen, for the log.
    public var reason: String

    /// More than one account was left, and the tie-break picked one.
    public var isAmbiguous: Bool {
        return self.candidateIds.count > 1
    }
}

/// Picks the account a push belongs to.
///
/// Mattermost pushes name the server (`server_id`) but not the user, because the official apps allow one
/// account per server. Relay allows several, so the router narrows the accounts of that server down:
///
/// 1. same `server_id` (accounts whose server id is unknown stay in only when none matches);
/// 2. not the sender (a user gets no push for their own posts, except a webhook posting as them);
/// 3. members of the channel, as far as the accounts' stores know;
/// 4. mentioned by `@username` in the text;
/// 5. not already notified of this post (`alreadyDelivered`, the extension's delivery log): when two
///    accounts both get a push for one post, each gets one of the notifications;
/// 6. the first in account order.
///
/// Every step that would leave no account is skipped. Ambiguity is only possible when two accounts of one
/// server are members of the same channel, neither is mentioned and only one of them is notified (for
/// example, only one has "all activity" notifications on); the tie-break then can pick the wrong one.
public enum MattermostPushRouter {
    public static func route(_ payload: MattermostPushPayload, accounts: [MattermostPushAccount], isMember: (MattermostPushAccount) -> Bool?, alreadyDelivered: Set<Int64>) -> MattermostPushRoute {
        var reasons: [String] = []
        var candidates = accounts.sorted(by: { lhs, rhs in
            if lhs.order != rhs.order {
                return lhs.order < rhs.order
            }
            return lhs.accountId < rhs.accountId
        })
        if candidates.isEmpty {
            return MattermostPushRoute(account: nil, candidateIds: [], reason: "no accounts")
        }

        if let serverId = payload.serverId {
            let matching = candidates.filter { $0.serverId == serverId }
            if !matching.isEmpty {
                candidates = matching
                reasons.append("server")
            } else {
                let unknown = candidates.filter { $0.serverId == nil }
                if unknown.isEmpty {
                    return MattermostPushRoute(account: nil, candidateIds: [], reason: "no account on server \(serverId)")
                }
                candidates = unknown
                reasons.append("server unknown")
            }
        }

        if let senderId = payload.senderId, !payload.isFromWebhook {
            let others = candidates.filter { $0.userId != senderId }
            if !others.isEmpty && others.count != candidates.count {
                candidates = others
                reasons.append("not sender")
            }
        }

        if candidates.count > 1 {
            var members: [MattermostPushAccount] = []
            var unknown: [MattermostPushAccount] = []
            for account in candidates {
                switch isMember(account) {
                case .some(true):
                    members.append(account)
                case .none:
                    unknown.append(account)
                case .some(false):
                    break
                }
            }
            if !members.isEmpty {
                if members.count != candidates.count {
                    reasons.append("member")
                }
                candidates = members
            } else if !unknown.isEmpty && unknown.count != candidates.count {
                candidates = unknown
                reasons.append("membership unknown")
            }
        }

        if candidates.count > 1, let text = payload.message {
            let mentioned = candidates.filter { account in
                guard let username = account.username, !username.isEmpty else {
                    return false
                }
                return MattermostPushRouter.mentions(text, username: username)
            }
            if !mentioned.isEmpty && mentioned.count != candidates.count {
                candidates = mentioned
                reasons.append("mention")
            }
        }

        let candidateIds = candidates.map { $0.accountId }
        if candidates.count > 1 {
            if let first = candidates.first(where: { !alreadyDelivered.contains($0.accountId) }) {
                reasons.append("first not yet notified")
                return MattermostPushRoute(account: first, candidateIds: candidateIds, reason: reasons.joined(separator: ", "))
            }
            reasons.append("all notified; first")
        }
        return MattermostPushRoute(account: candidates.first, candidateIds: candidateIds, reason: reasons.isEmpty ? "only account" : reasons.joined(separator: ", "))
    }

    /// Whether `text` contains `@username` as a whole mention (case-insensitive; a trailing `.`, `,`, `:`
    /// etc. ends it, as in Mattermost's mention parsing).
    public static func mentions(_ text: String, username: String) -> Bool {
        let lowered = text.lowercased()
        let needle = "@" + username.lowercased()
        var searchRange = lowered.startIndex ..< lowered.endIndex
        while let range = lowered.range(of: needle, range: searchRange) {
            let beforeOK: Bool
            if range.lowerBound == lowered.startIndex {
                beforeOK = true
            } else {
                let before = lowered[lowered.index(before: range.lowerBound)]
                beforeOK = !(before.isLetter || before.isNumber || before == "_" || before == "." || before == "-")
            }
            let afterOK: Bool
            if range.upperBound == lowered.endIndex {
                afterOK = true
            } else {
                let after = lowered[range.upperBound]
                // Usernames may contain `.`, `-` and `_`; a `.` followed by a letter continues the name.
                if after == "." {
                    let next = lowered.index(after: range.upperBound)
                    afterOK = next == lowered.endIndex || !(lowered[next].isLetter || lowered[next].isNumber)
                } else {
                    afterOK = !(after.isLetter || after.isNumber || after == "_" || after == "-")
                }
            }
            if beforeOK && afterOK {
                return true
            }
            searchRange = range.upperBound ..< lowered.endIndex
        }
        return false
    }
}

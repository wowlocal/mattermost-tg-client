import Foundation
import SwiftSignalKit
import Postbox
import TelegramCore
import MattermostKit
import MattermostSyncCore

/// An entry of the composer's `@` suggestions.
public enum MattermostMentionSuggestion: Equatable {
    /// A user; `inChannel` is false for team members outside the channel.
    case user(EnginePeer, inChannel: Bool)
    /// `@channel`, `@here` or `@all` (the name without `@`).
    case special(String)
}

/// An entry of the composer's `/` suggestions (`GET /teams/{id}/commands/autocomplete_suggestions`).
public struct MattermostCommandSuggestion: Equatable {
    /// The command line to insert, without the leading slash (`call start`).
    public var complete: String
    /// The word this entry completes (`start`).
    public var suggestion: String
    /// The arguments it takes (`[text]`).
    public var hint: String
    public var description: String
}

/// The composer's autocomplete for a Mattermost chat: `@` users (channel members first, then the team's other
/// members, plus `@channel`/`@here`/`@all` when the user may use them), `~` channels of the team, `:` emoji
/// (built-in and the server's custom emoji) and `/` commands. Called by TelegramUI's input query handling
/// (`MattermostComposerQueries.swift`); each signal waits briefly before its request, so a query that the next
/// keystroke replaces (and disposes) never reaches the server.
public enum MattermostComposer {
    static let typingDelay: UInt64 = 120_000_000

    /// Special mentions in Mattermost's order.
    public static let specialMentions = ["here", "channel", "all"]

    public static func mentionSuggestions(accountId: AccountRecordId, peerId: PeerId, query: String) -> Signal<[MattermostMentionSuggestion], NoError> {
        return self.signal(accountId: accountId, empty: []) { sync in
            return await sync.mentionSuggestions(peerId: peerId, query: query)
        }
    }

    /// Channels of the chat's team for `~`: peers with the channel name as `addressName` (the text to insert)
    /// and the display name as title; channels the user is in first.
    public static func channelSuggestions(accountId: AccountRecordId, peerId: PeerId, query: String) -> Signal<[EnginePeer], NoError> {
        return self.signal(accountId: accountId, empty: []) { sync in
            return await sync.channelSuggestions(peerId: peerId, query: query)
        }
    }

    /// Emoji for `:query` (two characters or more): `(symbol, file, name)` as Telegram's emoji suggestions take
    /// them. Built-in emoji have their Unicode symbol and no file; custom emoji have the `:name:` reaction image
    /// file, which the composer inserts as `:name:`.
    public static func emojiSuggestions(accountId: AccountRecordId, query: String) -> Signal<[(String, TelegramMediaFile?, String)], NoError> {
        if query.count < 2 {
            return .single([])
        }
        let builtIn = EmojiTable.search(query, limit: 60)
        let local: [(String, TelegramMediaFile?, String)] = builtIn.map { ($0.emoji, nil, $0.name) }
        return .single(local)
        |> then(self.signal(accountId: accountId, empty: nil) { sync -> [(String, TelegramMediaFile?, String)]? in
            let custom = await sync.customEmojiMatches(query)
            if custom.isEmpty {
                return nil
            }
            return MattermostComposer.mergeEmoji(builtIn: builtIn, custom: custom, query: query)
        }
        |> filter { $0 != nil }
        |> map { $0! })
    }

    static func mergeEmoji(builtIn: [(name: String, emoji: String)], custom: [String], query: String) -> [(String, TelegramMediaFile?, String)] {
        let query = query.lowercased()
        func rank(_ name: String) -> Int {
            if name == query {
                return 0
            } else if name.hasPrefix(query) {
                return 1
            } else {
                return 2
            }
        }
        var entries: [(rank: Int, name: String, value: (String, TelegramMediaFile?, String))] = []
        for item in builtIn {
            entries.append((rank(item.name), item.name, (item.emoji, nil, item.name)))
        }
        for name in custom {
            entries.append((rank(name), name, (":\(name):", MattermostReactionImages.file(for: ":\(name):"), name)))
        }
        entries.sort(by: { lhs, rhs in
            if lhs.rank != rhs.rank {
                return lhs.rank < rhs.rank
            }
            return lhs.name < rhs.name
        })
        return entries.prefix(60).map(\.value)
    }

    /// Commands for the composer's first line (`userInput` without the slash, e.g. `call st`).
    public static func commandSuggestions(accountId: AccountRecordId, peerId: PeerId, threadId: Int64?, userInput: String) -> Signal<[MattermostCommandSuggestion], NoError> {
        return self.signal(accountId: accountId, empty: []) { sync in
            return await sync.commandSuggestions(peerId: peerId, threadId: threadId, userInput: userInput)
        }
    }

    /// Runs `body` with the account's running sync after the typing delay; `empty` without a sync.
    static func signal<T>(accountId: AccountRecordId, empty: T, _ body: @escaping (MattermostAccountSync) async -> T) -> Signal<T, NoError> {
        return Signal { subscriber in
            let task = Task {
                try? await Task.sleep(nanoseconds: MattermostComposer.typingDelay)
                if Task.isCancelled {
                    return
                }
                let value: T
                if let sync = MattermostSync.sync(accountId: accountId) {
                    value = await body(sync)
                } else {
                    value = empty
                }
                if !Task.isCancelled {
                    subscriber.putNext(value)
                    subscriber.putCompletion()
                }
            }
            return ActionDisposable {
                task.cancel()
            }
        }
    }
}

extension MattermostPeerIds {
    /// Ids of peers that exist only in the composer's suggestions (special mentions, channels outside the
    /// user's membership): `[2^39, 2^39 + 2^20)`, far above the sequential range and below the own users'
    /// `[2^40, 2^41)`. Never written to Postbox.
    public static func suggestionPeerIdValue(_ index: Int64) -> Int64 {
        return (Int64(1) << 39) + index
    }

    public static func isSuggestionPeerId(_ peerId: PeerId) -> Bool {
        let value = peerId.id._internalGetInt64Value()
        return value >= (Int64(1) << 39) && value < (Int64(1) << 39) + (Int64(1) << 20)
    }
}

extension MattermostAccountSync {
    func mentionSuggestions(peerId: PeerId, query: String) async -> [MattermostMentionSuggestion] {
        await self.waitUntilBootstrapped()
        guard let channelId = self.channelId(forPeerId: peerId), let channelState = self.channelState(channelId) else {
            return []
        }
        let name = query.lowercased()
        let found: UserAutocomplete
        do {
            found = try await self.client.autocompleteUsers(name: name, teamId: self.teamId(for: channelState), channelId: channelId, limit: 25)
        } catch {
            MMLog.log("autocomplete: users \"\(name)\" failed: \(error)")
            return []
        }
        let all = (found.users + found.outOfChannel).filter { $0.deleteAt == 0 }
        await self.postbox.mmTransaction { transaction in
            self.writeUsers(all, transaction: transaction)
        }
        var result: [MattermostMentionSuggestion] = []
        let peers: [String: EnginePeer] = await self.postbox.mmTransaction { transaction in
            var peers: [String: EnginePeer] = [:]
            for user in all {
                if let peerId = self.userPeerId(user.id), let peer = transaction.getPeer(peerId) {
                    peers[user.id] = EnginePeer(peer)
                }
            }
            return peers
        }
        for user in found.users where user.id != self.ownUserId {
            if let peer = peers[user.id] {
                result.append(.user(peer, inChannel: true))
            }
        }
        if channelState.kind == .channel, await self.channelMentionsAllowed(channelState) {
            for special in MattermostComposer.specialMentions where name.isEmpty || special.hasPrefix(name) {
                result.append(.special(special))
            }
        }
        for user in found.outOfChannel where user.id != self.ownUserId {
            if let peer = peers[user.id] {
                result.append(.user(peer, inChannel: false))
            }
        }
        return result
    }

    func channelSuggestions(peerId: PeerId, query: String) async -> [EnginePeer] {
        await self.waitUntilBootstrapped()
        guard let channelId = self.channelId(forPeerId: peerId), let channelState = self.channelState(channelId) else {
            return []
        }
        let teamId = self.teamId(for: channelState)
        if teamId.isEmpty {
            return []
        }
        let name = query.lowercased()
        let channels: [Channel]
        do {
            channels = try await self.client.autocompleteChannels(teamId: teamId, name: name)
        } catch {
            MMLog.log("autocomplete: channels \"\(name)\" failed: \(error)")
            return []
        }
        func matches(_ channel: Channel) -> Bool {
            if name.isEmpty || channel.name.lowercased().hasPrefix(name) {
                return true
            }
            let words = channel.displayName.lowercased().split(whereSeparator: { $0 == " " || $0 == "-" || $0 == "_" })
            return words.contains(where: { $0.hasPrefix(name) }) || channel.displayName.lowercased().hasPrefix(name)
        }
        let candidates = channels.filter { !$0.isArchived && ($0.type == .publicChannel || $0.type == .privateChannel) && matches($0) }
        var mine: [(String, EnginePeer)] = []
        var others: [(String, EnginePeer)] = []
        for (index, channel) in candidates.enumerated() {
            let title = channel.displayName.isEmpty ? channel.name : channel.displayName
            if let state = self.channelState(channel.id) {
                mine.append((title.lowercased(), EnginePeer(PeerConverter.channel(channel, title: title, peerId: state.peerId, username: channel.name))))
            } else {
                let peerId = MattermostPeerIds.channelPeerId(MattermostPeerIds.suggestionPeerIdValue(Int64(index)))
                others.append((title.lowercased(), EnginePeer(PeerConverter.channel(channel, title: title, peerId: peerId, username: channel.name))))
            }
        }
        mine.sort(by: { $0.0 < $1.0 })
        others.sort(by: { $0.0 < $1.0 })
        return (mine + others).prefix(40).map(\.1)
    }

    func customEmojiMatches(_ query: String) async -> [String] {
        do {
            let emoji = try await self.client.autocompleteCustomEmoji(name: query.lowercased())
            return emoji.filter { $0.deleteAt == 0 }.map(\.name)
        } catch {
            MMLog.log("autocomplete: emoji \"\(query)\" failed: \(error)")
            return []
        }
    }

    func commandSuggestions(peerId: PeerId, threadId: Int64?, userInput: String) async -> [MattermostCommandSuggestion] {
        await self.waitUntilBootstrapped()
        guard let channelId = self.channelId(forPeerId: peerId), let channelState = self.channelState(channelId) else {
            return []
        }
        let teamId = self.teamId(for: channelState)
        if teamId.isEmpty {
            return []
        }
        let rootId = threadId.flatMap { self.postReference(for: MessageId(peerId: peerId, namespace: Namespaces.Message.Cloud, id: Int32(clamping: $0)))?.postId }
        do {
            let suggestions = try await self.client.commandAutocompleteSuggestions(teamId: teamId, userInput: "/" + userInput, channelId: channelId, rootId: rootId)
            return suggestions.map { MattermostCommandSuggestion(complete: $0.complete, suggestion: $0.suggestion, hint: $0.hint, description: $0.description) }
        } catch {
            MMLog.log("autocomplete: commands \"/\(userInput)\" failed: \(error)")
            return []
        }
    }

    // MARK: Permissions

    /// Whether the user may notify the whole channel (`use_channel_mentions` in any of the user's system, team
    /// or channel roles; a channel scheme's roles are part of the member's `roles`). Roles are cached for a
    /// minute.
    func channelMentionsAllowed(_ channelState: ChannelState) async -> Bool {
        let systemRoles = self.state.with { $0.me?.roles ?? "" }
        let teamRoles = await self.teamRoles(teamId: channelState.teamId)
        let names = Set((systemRoles + " " + teamRoles + " " + channelState.member.roles).split(separator: " ").map(String.init))
        if names.isEmpty {
            return true
        }
        guard let roles = await self.roles(names: names) else {
            // Unknown (offline): let the server decide when the message is sent.
            return true
        }
        return roles.contains(where: { $0.permissions.contains(PermissionName.useChannelMentions) })
    }

    private func teamRoles(teamId: String) async -> String {
        if teamId.isEmpty {
            return ""
        }
        if let cached = RoleCache.shared.teamRoles(accountId: self.account.id, teamId: teamId) {
            return cached
        }
        guard let members = try? await self.client.teamMembers() else {
            return ""
        }
        RoleCache.shared.setTeamRoles(accountId: self.account.id, members: members)
        return members.first(where: { $0.teamId == teamId })?.roles ?? ""
    }

    private func roles(names: Set<String>) async -> [Role]? {
        if let cached = RoleCache.shared.roles(accountId: self.account.id, names: names) {
            return cached
        }
        guard let roles = try? await self.client.roles(names: Array(names).sorted()) else {
            return nil
        }
        RoleCache.shared.setRoles(accountId: self.account.id, roles: roles)
        return roles
    }
}

/// Roles and team roles per account, kept for a minute (`role_updated` and membership changes take effect
/// within that time).
final class RoleCache {
    static let shared = RoleCache()
    private static let lifetime: Double = 60.0

    private struct Entry<T> {
        var value: T
        var time: Double
    }

    private let roleEntries = MMLocked<[AccountRecordId: [String: Entry<Role>]]>([:])
    private let teamEntries = MMLocked<[AccountRecordId: Entry<[String: String]>]>([:])

    func roles(accountId: AccountRecordId, names: Set<String>) -> [Role]? {
        let now = CFAbsoluteTimeGetCurrent()
        return self.roleEntries.with { entries -> [Role]? in
            var result: [Role] = []
            for name in names {
                guard let entry = entries[accountId]?[name], now - entry.time < RoleCache.lifetime else {
                    return nil
                }
                result.append(entry.value)
            }
            return result
        }
    }

    func setRoles(accountId: AccountRecordId, roles: [Role]) {
        let now = CFAbsoluteTimeGetCurrent()
        self.roleEntries.with { entries in
            for role in roles {
                entries[accountId, default: [:]][role.name] = Entry(value: role, time: now)
            }
        }
    }

    func teamRoles(accountId: AccountRecordId, teamId: String) -> String? {
        let now = CFAbsoluteTimeGetCurrent()
        return self.teamEntries.with { entries -> String? in
            guard let entry = entries[accountId], now - entry.time < RoleCache.lifetime else {
                return nil
            }
            return entry.value[teamId] ?? ""
        }
    }

    func setTeamRoles(accountId: AccountRecordId, members: [TeamMember]) {
        var roles: [String: String] = [:]
        for member in members where member.deleteAt == 0 {
            roles[member.teamId] = member.roles
        }
        self.teamEntries.with { $0[accountId] = Entry(value: roles, time: CFAbsoluteTimeGetCurrent()) }
    }

    func invalidate(accountId: AccountRecordId) {
        self.roleEntries.with { $0[accountId] = nil }
        self.teamEntries.with { $0[accountId] = nil }
    }
}

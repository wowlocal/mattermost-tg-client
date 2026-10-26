import Foundation

// Spike A fixtures: a small, realistic team workspace written into Postbox by `MattermostSpikeSeeder`.
// Plain values only; the mapping to Postbox and TelegramCore types lives in the seeder.

struct SpikeUser {
    enum Presence {
        case online
        case lastSeen(minutesAgo: Int32)
        case recently
        case lastWeek
    }

    let id: Int64
    let firstName: String
    let lastName: String
    let username: String
    let presence: Presence
}

struct SpikeMessage {
    /// How long before the seeding time the message was posted. Messages of a chat are listed oldest first.
    let minutesAgo: Int32
    let authorId: Int64
    let text: String
    /// Index (in the same chat) of the message this one replies to.
    let replyTo: Int?

    init(_ minutesAgo: Int32, _ authorId: Int64, _ text: String, replyTo: Int? = nil) {
        self.minutesAgo = minutesAgo
        self.authorId = authorId
        self.text = text
        self.replyTo = replyTo
    }
}

struct SpikeChat {
    enum Kind {
        /// A Mattermost public or private channel: a `TelegramChannel` with group info.
        case channel(id: Int64, title: String, purpose: String, memberCount: Int32)
        /// A direct message: the chat is the other user's peer.
        case directMessage(userId: Int64)
        /// The DM with yourself: Saved Messages.
        case savedMessages
    }

    /// Name for `RELAY_DEBUG_OPEN_CHAT`.
    let key: String
    let kind: Kind
    let messages: [SpikeMessage]
    /// The newest `unreadCount` messages are unread (they must be incoming).
    let unreadCount: Int
}

enum SpikeFixtures {
    static let ownUserId: Int64 = 1001
    static let priya: Int64 = 1002
    static let jonas: Int64 = 1003
    static let emily: Int64 = 1004
    static let marco: Int64 = 1005

    static let users: [SpikeUser] = [
        SpikeUser(id: ownUserId, firstName: "Sam", lastName: "Rivera", username: "sam.rivera", presence: .online),
        SpikeUser(id: priya, firstName: "Priya", lastName: "Natarajan", username: "priya", presence: .online),
        SpikeUser(id: jonas, firstName: "Jonas", lastName: "Weber", username: "jonas.weber", presence: .recently),
        SpikeUser(id: emily, firstName: "Emily", lastName: "Chen", username: "emily.chen", presence: .lastSeen(minutesAgo: 10)),
        SpikeUser(id: marco, firstName: "Marco", lastName: "Rossi", username: "marco", presence: .lastWeek)
    ]

    /// Ordered as the chat list shows them (newest top message first). The first one is what
    /// `RELAY_DEBUG_OPEN_CHAT=1` opens.
    static let chats: [SpikeChat] = [
        SpikeChat(
            key: "ios-team",
            kind: .channel(id: 2002, title: "iOS Team", purpose: "Everything about the iOS app: builds, reviews, releases.", memberCount: 5),
            messages: [
                SpikeMessage(2000, emily, "Standup notes are in the thread. Main topic today: the share extension crash."),
                SpikeMessage(1990, ownUserId, "I can take the share extension crash, it looks like we hit the memory limit."),
                SpikeMessage(1985, emily, "Perfect, thanks!"),
                SpikeMessage(900, jonas, "TestFlight build 2.4 (512) is up."),
                SpikeMessage(880, priya, "Installing now. Dark mode on the settings screen looks so much better."),
                SpikeMessage(600, ownUserId, "Found it: we were decoding full-size images inside the extension. Fix is in review."),
                SpikeMessage(590, jonas, "Nice catch 👏"),
                SpikeMessage(240, emily, "Who owns the push notification entitlement? Our provisioning profile expired."),
                SpikeMessage(230, ownUserId, "I do, renewing it now.", replyTo: 7),
                SpikeMessage(225, emily, "Thank you!"),
                SpikeMessage(20, jonas, "Merged the image decoding fix, it will be in tomorrow's build.", replyTo: 5),
                SpikeMessage(3, priya, "Can someone review my PR for the new onboarding flow? It's small, I promise.")
            ],
            unreadCount: 2
        ),
        SpikeChat(
            key: "town-square",
            kind: .channel(id: 2001, title: "Town Square", purpose: "Company-wide announcements and work-based matters.", memberCount: 5),
            messages: [
                SpikeMessage(1560, jonas, "Good morning everyone! Reminder: the quarterly all-hands is on Thursday at 15:00 CET."),
                SpikeMessage(1555, emily, "Thanks Jonas. Will there be a recording for the folks in Singapore?"),
                SpikeMessage(1550, jonas, "Yes, it will be posted here afterwards."),
                SpikeMessage(1440, marco, "The office Wi-Fi is being upgraded tonight between 22:00 and 23:00, expect a short outage."),
                SpikeMessage(1300, ownUserId, "Thanks for the heads-up, Marco."),
                SpikeMessage(780, priya, "Welcome to our two new teammates joining Platform this week 🎉"),
                SpikeMessage(775, emily, "Welcome aboard!"),
                SpikeMessage(770, ownUserId, "Welcome! Ping me if you need help getting the dev environment running."),
                SpikeMessage(300, marco, "Lunch & learn on Friday: \"Postgres query plans for mere mortals\". Pizza provided 🍕"),
                SpikeMessage(120, jonas, "Release 2.4 is out. Release notes are pinned in this channel."),
                SpikeMessage(45, emily, "Has anyone else seen build cache misses since this morning?"),
                SpikeMessage(30, marco, "Yes, the CI runners were rotated. They should be warm again within the hour."),
                SpikeMessage(14, priya, "Heads up: the staging database is being migrated at 17:00."),
                SpikeMessage(8, jonas, "Please fill in the offsite survey by Friday, the link is in the channel header.")
            ],
            unreadCount: 4
        ),
        SpikeChat(
            key: "dm",
            kind: .directMessage(userId: priya),
            messages: [
                SpikeMessage(1500, priya, "Hey Sam, do you have a minute to go over the release checklist?"),
                SpikeMessage(1495, ownUserId, "Sure, give me 10 minutes."),
                SpikeMessage(1480, priya, "Great, I'll set up a call."),
                SpikeMessage(70, priya, "Thanks for the help earlier, the checklist is updated."),
                SpikeMessage(45, ownUserId, "Anytime! Let me know if the migration needs another pair of eyes."),
                SpikeMessage(40, ownUserId, "I'll be around until 18:00.")
            ],
            unreadCount: 0
        ),
        SpikeChat(
            key: "off-topic",
            kind: .channel(id: 2003, title: "Off-Topic", purpose: "Non-work banter and water cooler conversation.", memberCount: 5),
            messages: [
                SpikeMessage(2900, marco, "Anyone up for a board game night next week?"),
                SpikeMessage(2890, priya, "Count me in! I'll bring Wingspan."),
                SpikeMessage(2880, emily, "Yes please 🙌"),
                SpikeMessage(2870, ownUserId, "I'm in. Wednesday works best for me."),
                SpikeMessage(400, jonas, "Spotted a heron by the river on my way in this morning."),
                SpikeMessage(190, marco, "Photos or it didn't happen 😄"),
                SpikeMessage(180, jonas, "It flew away before I could get my phone out.")
            ],
            unreadCount: 0
        ),
        SpikeChat(
            key: "saved",
            kind: .savedMessages,
            messages: [
                SpikeMessage(1700, ownUserId, "Ideas for the retro: fewer meetings on Wednesdays, rotate the on-call schedule."),
                SpikeMessage(1690, ownUserId, "Dentist on Tuesday at 9:30."),
                SpikeMessage(1450, ownUserId, "The guest Wi-Fi password is on the whiteboard in room 4.")
            ],
            unreadCount: 0
        )
    ]
}

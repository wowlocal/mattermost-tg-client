import Foundation

/// Schema of `SQLiteMattermostSyncStore`, as forward-only migrations.
///
/// `migrations[n]` upgrades schema version `n` to `n + 1`; version 0 is an empty file. Never edit
/// a migration once it has shipped: append a new one. The version lives in `schema_version`.
enum MattermostSyncStoreSchema {
    static let versionTable = """
    CREATE TABLE IF NOT EXISTS schema_version (
        id INTEGER PRIMARY KEY CHECK (id = 1),
        version INTEGER NOT NULL
    );
    """

    static let migrations: [String] = [version1, version2]

    static var latestVersion: Int {
        return migrations.count
    }

    private static let version1 = """
    -- The account's server and session description (one row).
    CREATE TABLE server (
        id INTEGER PRIMARY KEY CHECK (id = 1),
        url TEXT NOT NULL,
        user_id TEXT NOT NULL,
        site_name TEXT,
        version TEXT,
        capabilities TEXT
    );

    -- Mattermost user/channel/GM id <-> Telegram peer id (PeerId.Id payload) per namespace
    -- (0 = CloudUser, 1 = CloudChannel).
    CREATE TABLE peers (
        mm_id TEXT PRIMARY KEY NOT NULL,
        kind TEXT NOT NULL CHECK (kind IN ('user', 'channel', 'gm')),
        namespace INTEGER NOT NULL CHECK (namespace IN (0, 1)),
        peer_id INTEGER NOT NULL CHECK (peer_id > 0),
        team_id TEXT
    ) WITHOUT ROWID;
    CREATE UNIQUE INDEX peers_by_peer_id ON peers (namespace, peer_id);

    -- DM channel <-> the other user (the own user for the self-DM).
    CREATE TABLE dm_channels (
        channel_id TEXT PRIMARY KEY NOT NULL,
        user_mm_id TEXT NOT NULL
    ) WITHOUT ROWID;
    CREATE INDEX dm_channels_by_user ON dm_channels (user_mm_id);

    -- Next candidate of each sequential allocator ('peer.0', 'peer.1', 'media').
    CREATE TABLE sequences (
        name TEXT PRIMARY KEY NOT NULL,
        next_value INTEGER NOT NULL
    ) WITHOUT ROWID;

    -- Channels known to the message id map, interned to a small integer key.
    CREATE TABLE post_channels (
        channel_key INTEGER PRIMARY KEY,
        channel_id TEXT NOT NULL UNIQUE
    );

    -- The message id map (MessageIdStore). Clustered by the ordering key, so neighbour and range
    -- queries are index scans; post_id and local_id lookups have their own unique indexes.
    CREATE TABLE posts (
        channel_key INTEGER NOT NULL REFERENCES post_channels (channel_key) ON DELETE CASCADE,
        create_at_ms INTEGER NOT NULL,
        post_id TEXT NOT NULL,
        local_id INTEGER NOT NULL,
        tombstone INTEGER NOT NULL DEFAULT 0,
        thread_root_id TEXT,
        PRIMARY KEY (channel_key, create_at_ms, post_id)
    ) WITHOUT ROWID;
    CREATE UNIQUE INDEX posts_by_post_id ON posts (channel_key, post_id);
    CREATE UNIQUE INDEX posts_by_local_id ON posts (channel_key, local_id);
    CREATE INDEX posts_by_thread_root ON posts (channel_key, thread_root_id, create_at_ms, post_id) WHERE thread_root_id IS NOT NULL;

    -- Posts deleted before they were ever mapped.
    CREATE TABLE post_tombstones (
        channel_key INTEGER NOT NULL REFERENCES post_channels (channel_key) ON DELETE CASCADE,
        post_id TEXT NOT NULL,
        PRIMARY KEY (channel_key, post_id)
    ) WITHOUT ROWID;

    -- Loaded stretches of history, by boundary keys, in list order.
    CREATE TABLE islands (
        channel_key INTEGER NOT NULL REFERENCES post_channels (channel_key) ON DELETE CASCADE,
        ordinal INTEGER NOT NULL,
        lower_create_at_ms INTEGER NOT NULL,
        lower_post_id TEXT NOT NULL,
        upper_create_at_ms INTEGER NOT NULL,
        upper_post_id TEXT NOT NULL,
        reaches_start INTEGER NOT NULL,
        reaches_latest INTEGER NOT NULL,
        PRIMARY KEY (channel_key, ordinal)
    ) WITHOUT ROWID;

    -- Outgoing posts awaiting confirmation.
    CREATE TABLE pending (
        pending_post_id TEXT PRIMARY KEY NOT NULL,
        channel_id TEXT NOT NULL,
        globally_unique_id INTEGER NOT NULL UNIQUE,
        local_message_id INTEGER NOT NULL
    );
    CREATE INDEX pending_by_local_message ON pending (channel_id, local_message_id);

    -- Mattermost file id <-> sequential media id.
    CREATE TABLE files (
        file_id TEXT PRIMARY KEY NOT NULL,
        media_id INTEGER NOT NULL UNIQUE
    ) WITHOUT ROWID;

    CREATE TABLE cursors (
        key TEXT PRIMARY KEY NOT NULL,
        value TEXT NOT NULL
    ) WITHOUT ROWID;
    """

    /// 4F: the files an outgoing message already uploaded (`[MattermostPendingUpload]` as JSON), so a restart
    /// between the upload and `POST /posts` doesn't upload them again.
    private static let version2 = """
    ALTER TABLE pending ADD COLUMN uploaded_files TEXT;
    """
}

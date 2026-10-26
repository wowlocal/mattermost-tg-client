import Foundation

/// Realistic Mattermost v4 payloads (shaped after 9.x/10.x server responses).
enum Fixtures {
    static let userId = "9fsrebgu3jdq9xf5t1rf6khtmo"
    static let otherUserId = "kq7xqbs6ofbbpmcs9ycw1mn1yc"
    static let teamId = "ybsmnm8jkjfmdqmtmcrcuxfzbe"
    static let channelId = "3ofz1xexwbdu9fuhm3ihsunhzr"

    static let user = #"""
    {
      "id": "9fsrebgu3jdq9xf5t1rf6khtmo",
      "create_at": 1700000000000,
      "update_at": 1700000500000,
      "delete_at": 0,
      "username": "alice",
      "auth_data": "",
      "auth_service": "",
      "email": "alice@example.com",
      "email_verified": true,
      "nickname": "Al",
      "first_name": "Alice",
      "last_name": "Liddell",
      "position": "Engineer",
      "roles": "system_user system_admin",
      "allow_marketing": false,
      "props": {
        "customStatus": "{\"emoji\":\"calendar\",\"text\":\"In a meeting\",\"duration\":\"one_hour\",\"expires_at\":\"2026-10-26T15:00:00Z\"}"
      },
      "notify_props": {
        "channel": "true",
        "comments": "never",
        "desktop": "mention",
        "desktop_sound": "true",
        "email": "true",
        "first_name": "false",
        "mention_keys": "",
        "push": "mention",
        "push_status": "away"
      },
      "last_password_update": 1700000000000,
      "last_picture_update": 1700000600000,
      "locale": "en",
      "timezone": {
        "automaticTimezone": "Europe/Berlin",
        "manualTimezone": "",
        "useAutomaticTimezone": "true"
      },
      "disable_welcome_email": false,
      "terms_of_service_id": "",
      "terms_of_service_create_at": 0,
      "mfa_active": false,
      "last_activity_at": 1700000700000
    }
    """#

    static let botUser = #"""
    {
      "id": "kq7xqbs6ofbbpmcs9ycw1mn1yc",
      "create_at": 1690000000000,
      "update_at": 1690000000000,
      "delete_at": 0,
      "username": "feedbot",
      "first_name": "Feed",
      "last_name": "",
      "nickname": "",
      "roles": "system_user",
      "locale": "en",
      "is_bot": true,
      "bot_description": "Posts RSS items",
      "bot_last_icon_update": 0,
      "notify_props": null,
      "timezone": {"useAutomaticTimezone": "true", "automaticTimezone": "", "manualTimezone": ""}
    }
    """#

    static let teams = #"""
    [
      {
        "id": "ybsmnm8jkjfmdqmtmcrcuxfzbe",
        "create_at": 1690000000000,
        "update_at": 1690000000000,
        "delete_at": 0,
        "display_name": "Engineering",
        "name": "engineering",
        "description": "",
        "email": "",
        "type": "O",
        "company_name": "",
        "allowed_domains": "",
        "invite_id": "iqf6kt3w5fybuxc86fo8f6xw5h",
        "allow_open_invite": true,
        "scheme_id": null,
        "group_constrained": null,
        "policy_id": null,
        "cloud_limits_archived": false
      }
    ]
    """#

    static let teamMembers = #"""
    [
      {
        "team_id": "ybsmnm8jkjfmdqmtmcrcuxfzbe",
        "user_id": "9fsrebgu3jdq9xf5t1rf6khtmo",
        "roles": "team_user team_admin",
        "delete_at": 0,
        "scheme_guest": false,
        "scheme_user": true,
        "scheme_admin": true,
        "explicit_roles": "",
        "create_at": 1690000000000
      }
    ]
    """#

    static let teamsUnread = #"""
    [
      {
        "team_id": "ybsmnm8jkjfmdqmtmcrcuxfzbe",
        "msg_count": 12,
        "mention_count": 2,
        "mention_count_root": 1,
        "msg_count_root": 9,
        "thread_count": 3,
        "thread_mention_count": 1,
        "thread_urgent_mention_count": 0
      }
    ]
    """#

    static let channels = #"""
    [
      {
        "id": "3ofz1xexwbdu9fuhm3ihsunhzr",
        "create_at": 1690000000000,
        "update_at": 1690000000000,
        "delete_at": 0,
        "team_id": "ybsmnm8jkjfmdqmtmcrcuxfzbe",
        "type": "O",
        "display_name": "Town Square",
        "name": "town-square",
        "header": "Welcome! [Docs](https://docs.example.com)",
        "purpose": "Company-wide announcements",
        "last_post_at": 1700000900000,
        "total_msg_count": 120,
        "extra_update_at": 0,
        "creator_id": "",
        "scheme_id": null,
        "props": null,
        "group_constrained": null,
        "shared": null,
        "total_msg_count_root": 100,
        "policy_id": null,
        "last_root_post_at": 1700000800000
      },
      {
        "id": "h8rygbsp5bgtfehmwdjcjb5hcr",
        "create_at": 1690000000000,
        "update_at": 1690000000000,
        "delete_at": 1695000000000,
        "team_id": "ybsmnm8jkjfmdqmtmcrcuxfzbe",
        "type": "P",
        "display_name": "Secret Project",
        "name": "secret-project",
        "header": "",
        "purpose": "",
        "last_post_at": 1694000000000,
        "total_msg_count": 5,
        "creator_id": "9fsrebgu3jdq9xf5t1rf6khtmo"
      },
      {
        "id": "pb1bt4wqepdj8xg6ymbiec1ydh",
        "create_at": 1690000000000,
        "update_at": 1690000000000,
        "delete_at": 0,
        "team_id": "",
        "type": "D",
        "display_name": "",
        "name": "9fsrebgu3jdq9xf5t1rf6khtmo__kq7xqbs6ofbbpmcs9ycw1mn1yc",
        "header": "",
        "purpose": "",
        "last_post_at": 1700000950000,
        "total_msg_count": 42,
        "total_msg_count_root": 40,
        "creator_id": ""
      },
      {
        "id": "zt3ebwf5p7nexmt5u9q6efkqsy",
        "team_id": "",
        "type": "G",
        "display_name": "alice, bob, carol",
        "name": "1e4f9ef3d6c1a0b5bd4e1d7a6c9f0e2a3b4c5d6e",
        "last_post_at": 1700000000000,
        "total_msg_count": 7
      },
      {
        "id": "b8rbsdw9kpr4ffsz7qepwhgh6r",
        "type": "X",
        "name": "future-type"
      }
    ]
    """#

    static let channelMembers = #"""
    [
      {
        "channel_id": "3ofz1xexwbdu9fuhm3ihsunhzr",
        "user_id": "9fsrebgu3jdq9xf5t1rf6khtmo",
        "roles": "channel_user",
        "last_viewed_at": 1700000850000,
        "msg_count": 110,
        "mention_count": 1,
        "mention_count_root": 1,
        "urgent_mention_count": 0,
        "msg_count_root": 95,
        "notify_props": {
          "desktop": "default",
          "email": "default",
          "ignore_channel_mentions": "default",
          "mark_unread": "mention",
          "push": "default"
        },
        "last_update_at": 1700000850000,
        "scheme_guest": false,
        "scheme_user": true,
        "scheme_admin": false,
        "explicit_roles": ""
      },
      {
        "channel_id": "pb1bt4wqepdj8xg6ymbiec1ydh",
        "user_id": "9fsrebgu3jdq9xf5t1rf6khtmo",
        "last_viewed_at": 1700000950000,
        "msg_count": 42,
        "mention_count": 0
      }
    ]
    """#

    static let sidebarCategories = #"""
    {
      "categories": [
        {
          "id": "favorites_9fsrebgu3jdq9xf5t1rf6khtmo_ybsmnm8jkjfmdqmtmcrcuxfzbe",
          "user_id": "9fsrebgu3jdq9xf5t1rf6khtmo",
          "team_id": "ybsmnm8jkjfmdqmtmcrcuxfzbe",
          "sort_order": 0,
          "sorting": "",
          "type": "favorites",
          "display_name": "Favorites",
          "muted": false,
          "collapsed": false,
          "channel_ids": ["pb1bt4wqepdj8xg6ymbiec1ydh"]
        },
        {
          "id": "channels_9fsrebgu3jdq9xf5t1rf6khtmo_ybsmnm8jkjfmdqmtmcrcuxfzbe",
          "user_id": "9fsrebgu3jdq9xf5t1rf6khtmo",
          "team_id": "ybsmnm8jkjfmdqmtmcrcuxfzbe",
          "sort_order": 10,
          "sorting": "alpha",
          "type": "channels",
          "display_name": "Channels",
          "muted": false,
          "collapsed": false,
          "channel_ids": ["3ofz1xexwbdu9fuhm3ihsunhzr", "h8rygbsp5bgtfehmwdjcjb5hcr"]
        },
        {
          "id": "direct_messages_9fsrebgu3jdq9xf5t1rf6khtmo_ybsmnm8jkjfmdqmtmcrcuxfzbe",
          "user_id": "9fsrebgu3jdq9xf5t1rf6khtmo",
          "team_id": "ybsmnm8jkjfmdqmtmcrcuxfzbe",
          "sort_order": 20,
          "sorting": "recent",
          "type": "direct_messages",
          "display_name": "Direct Messages",
          "muted": false,
          "collapsed": true,
          "channel_ids": null
        }
      ],
      "order": [
        "favorites_9fsrebgu3jdq9xf5t1rf6khtmo_ybsmnm8jkjfmdqmtmcrcuxfzbe",
        "direct_messages_9fsrebgu3jdq9xf5t1rf6khtmo_ybsmnm8jkjfmdqmtmcrcuxfzbe",
        "channels_9fsrebgu3jdq9xf5t1rf6khtmo_ybsmnm8jkjfmdqmtmcrcuxfzbe"
      ]
    }
    """#

    static let post = #"""
    {
      "id": "8d9dmwzmrinfmxsfr4cqnz3d6e",
      "create_at": 1700000900000,
      "update_at": 1700000950000,
      "edit_at": 1700000950000,
      "delete_at": 0,
      "is_pinned": true,
      "user_id": "9fsrebgu3jdq9xf5t1rf6khtmo",
      "channel_id": "3ofz1xexwbdu9fuhm3ihsunhzr",
      "root_id": "",
      "original_id": "",
      "message": "Release notes: https://example.com/release #ship",
      "type": "",
      "props": {
        "disable_group_highlight": true,
        "attachments": [
          {"fallback": "Build passed", "color": "#36a64f", "title": "CI", "fields": [{"title": "Branch", "value": "main", "short": true}]}
        ]
      },
      "hashtags": "#ship",
      "pending_post_id": "9fsrebgu3jdq9xf5t1rf6khtmo:1700000899000",
      "reply_count": 3,
      "last_reply_at": 1700001000000,
      "participants": null,
      "is_following": true,
      "file_ids": ["a1b2c3d4e5f6g7h8i9j0k1l2m3"],
      "has_reactions": true,
      "metadata": {
        "embeds": [
          {
            "type": "opengraph",
            "url": "https://example.com/release",
            "data": {
              "type": "article",
              "url": "https://example.com/release",
              "title": "Release 2.0",
              "description": "What's new",
              "determiner": "",
              "site_name": "Example",
              "locale": "",
              "locales_alternate": null,
              "images": [{"url": "", "secure_url": "https://example.com/og.png", "type": "", "width": 1200, "height": 630}],
              "audios": null,
              "videos": null
            }
          },
          {"type": "message_attachment"}
        ],
        "emojis": [
          {"id": "q7x8y9z0a1b2c3d4e5f6g7h8i9", "create_at": 1690000000000, "update_at": 1690000000000, "delete_at": 0, "creator_id": "9fsrebgu3jdq9xf5t1rf6khtmo", "name": "party_parrot"}
        ],
        "files": [
          {
            "id": "a1b2c3d4e5f6g7h8i9j0k1l2m3",
            "user_id": "9fsrebgu3jdq9xf5t1rf6khtmo",
            "post_id": "8d9dmwzmrinfmxsfr4cqnz3d6e",
            "channel_id": "3ofz1xexwbdu9fuhm3ihsunhzr",
            "create_at": 1700000890000,
            "update_at": 1700000890000,
            "delete_at": 0,
            "name": "screenshot.png",
            "extension": "png",
            "size": 48213,
            "mime_type": "image/png",
            "width": 1280,
            "height": 720,
            "has_preview_image": true,
            "mini_preview": "/9j/2wCEAAMCAgMCAgMDAwMEAwMEBQgFBQQEBQoHBwYIDAoMDAsKCwsNDhIQDQ4RDgsLEBYQERMUFRUVDA8XGBYUGBIUFRQ=",
            "remote_id": "",
            "archived": false
          }
        ],
        "images": {
          "https://example.com/og.png": {"width": 1200, "height": 630, "format": "png", "frame_count": 0}
        },
        "reactions": [
          {"user_id": "kq7xqbs6ofbbpmcs9ycw1mn1yc", "post_id": "8d9dmwzmrinfmxsfr4cqnz3d6e", "emoji_name": "+1", "create_at": 1700000960000, "update_at": 1700000960000, "delete_at": 0, "remote_id": "", "channel_id": "3ofz1xexwbdu9fuhm3ihsunhzr"},
          {"user_id": "9fsrebgu3jdq9xf5t1rf6khtmo", "post_id": "8d9dmwzmrinfmxsfr4cqnz3d6e", "emoji_name": "party_parrot", "create_at": 1700000970000}
        ],
        "priority": {"priority": "important", "requested_ack": true}
      }
    }
    """#

    static let postList = #"""
    {
      "order": ["p3xxxxxxxxxxxxxxxxxxxxxxxx", "p2xxxxxxxxxxxxxxxxxxxxxxxx", "missingxxxxxxxxxxxxxxxxxxx", "p1xxxxxxxxxxxxxxxxxxxxxxxx"],
      "posts": {
        "p1xxxxxxxxxxxxxxxxxxxxxxxx": {"id": "p1xxxxxxxxxxxxxxxxxxxxxxxx", "create_at": 1700000001000, "update_at": 1700000001000, "delete_at": 0, "user_id": "9fsrebgu3jdq9xf5t1rf6khtmo", "channel_id": "3ofz1xexwbdu9fuhm3ihsunhzr", "root_id": "", "message": "first", "type": "", "props": {}, "hashtags": "", "file_ids": null, "pending_post_id": "", "metadata": {}},
        "p2xxxxxxxxxxxxxxxxxxxxxxxx": {"id": "p2xxxxxxxxxxxxxxxxxxxxxxxx", "create_at": 1700000002000, "update_at": 1700000002000, "delete_at": 0, "user_id": "kq7xqbs6ofbbpmcs9ycw1mn1yc", "channel_id": "3ofz1xexwbdu9fuhm3ihsunhzr", "root_id": "p1xxxxxxxxxxxxxxxxxxxxxxxx", "message": "reply", "type": "", "props": {"from_webhook": "true", "override_username": "ci"}},
        "p3xxxxxxxxxxxxxxxxxxxxxxxx": {"id": "p3xxxxxxxxxxxxxxxxxxxxxxxx", "create_at": 1700000003000, "user_id": "9fsrebgu3jdq9xf5t1rf6khtmo", "channel_id": "3ofz1xexwbdu9fuhm3ihsunhzr", "message": "bob joined the channel.", "type": "system_join_channel", "props": {"username": "bob"}},
        "brokenxxxxxxxxxxxxxxxxxxxx": {"message": "post without an id"}
      },
      "next_post_id": "",
      "prev_post_id": "p0xxxxxxxxxxxxxxxxxxxxxxxx",
      "has_next": false,
      "first_inaccessible_post_time": 0
    }
    """#

    static let threads = #"""
    {
      "total": 2,
      "total_unread_threads": 1,
      "total_unread_mentions": 1,
      "total_unread_urgent_mentions": 0,
      "threads": [
        {
          "id": "p1xxxxxxxxxxxxxxxxxxxxxxxx",
          "reply_count": 4,
          "last_reply_at": 1700001000000,
          "last_viewed_at": 1700000500000,
          "participants": [{"id": "9fsrebgu3jdq9xf5t1rf6khtmo", "username": "alice"}, {"id": "kq7xqbs6ofbbpmcs9ycw1mn1yc"}],
          "post": {"id": "p1xxxxxxxxxxxxxxxxxxxxxxxx", "channel_id": "3ofz1xexwbdu9fuhm3ihsunhzr", "message": "first", "create_at": 1700000001000},
          "unread_replies": 2,
          "unread_mentions": 1,
          "is_urgent": false,
          "delete_at": 0
        },
        {
          "id": "p9xxxxxxxxxxxxxxxxxxxxxxxx",
          "reply_count": 1,
          "last_reply_at": 1700000100000,
          "last_viewed_at": 1700000200000,
          "participants": null,
          "post": null
        }
      ]
    }
    """#

    static let clientConfig = #"""
    {
      "AboutLink": "https://mattermost.com/default-about/",
      "BuildNumber": "10234567",
      "CollapsedThreads": "default_on",
      "DiagnosticId": "kxg7eumq3fd1zxmzu6a3fkrmgc",
      "EnableCustomEmoji": "true",
      "EnableLdap": "false",
      "EnableMultifactorAuthentication": "true",
      "EnableSaml": "true",
      "EnableSignInWithEmail": "true",
      "EnableSignInWithUsername": "true",
      "EnableSignUpWithEmail": "true",
      "EnableSignUpWithGitLab": "true",
      "EnableSignUpWithGoogle": "false",
      "EnableSignUpWithOffice365": "false",
      "EnableSignUpWithOpenId": "true",
      "EnforceMultifactorAuthentication": "false",
      "MaxFileSize": "104857600",
      "SiteName": "Example Chat",
      "SiteURL": "https://chat.example.com",
      "TeammateNameDisplay": "full_name",
      "Version": "9.11.1",
      "ExperimentalNumber": 3
    }
    """#

    static let clientLicense = #"""
    {"IsLicensed": "true", "SkuShortName": "professional", "Cloud": "false", "Users": "100"}
    """#

    static let appError = #"""
    {
      "id": "api.user.login.invalid_credentials_email_username",
      "message": "Enter a valid email or username and/or password.",
      "detailed_error": "",
      "request_id": "zq8s8bxfb7gc8b5xzmq9jhqiwy",
      "status_code": 401
    }
    """#

    static let autocompleteSuggestions = #"""
    [
      {"Complete": "giphy", "Suggestion": "/giphy", "Hint": "[text]", "Description": "Post a GIF", "IconData": ""},
      {"complete": "away", "suggestion": "/away", "hint": "", "description": "Set your status away"}
    ]
    """#

    static let openGraph = #"""
    {
      "type": "website",
      "url": "https://mattermost.com/",
      "title": "Mattermost",
      "description": "Secure collaboration",
      "determiner": "",
      "site_name": "Mattermost",
      "locale": "en_US",
      "locales_alternate": null,
      "images": [{"url": "https://mattermost.com/og.png", "secure_url": "", "type": "image/png", "width": 0, "height": 0}],
      "audios": null,
      "videos": null
    }
    """#

    static let statuses = #"""
    [
      {"user_id": "9fsrebgu3jdq9xf5t1rf6khtmo", "status": "online", "manual": false, "last_activity_at": 1700000700000, "dnd_end_time": 0, "prev_status": ""},
      {"user_id": "kq7xqbs6ofbbpmcs9ycw1mn1yc", "status": "dnd", "manual": true, "last_activity_at": 1700000000000, "dnd_end_time": 1700003600},
      {"user_id": "zzzzzzzzzzzzzzzzzzzzzzzzzz", "status": "on_vacation"}
    ]
    """#

    static let preferences = #"""
    [
      {"user_id": "9fsrebgu3jdq9xf5t1rf6khtmo", "category": "display_settings", "name": "collapsed_reply_threads", "value": "on"},
      {"user_id": "9fsrebgu3jdq9xf5t1rf6khtmo", "category": "flagged_post", "name": "8d9dmwzmrinfmxsfr4cqnz3d6e", "value": "true"}
    ]
    """#

    static let fileUploadResponse = #"""
    {
      "file_infos": [
        {"id": "f1xxxxxxxxxxxxxxxxxxxxxxxx", "user_id": "9fsrebgu3jdq9xf5t1rf6khtmo", "post_id": "", "channel_id": "3ofz1xexwbdu9fuhm3ihsunhzr", "create_at": 1700000000000, "update_at": 1700000000000, "delete_at": 0, "name": "notes.txt", "extension": "txt", "size": 11, "mime_type": "text/plain", "width": 0, "height": 0, "has_preview_image": false},
        {"id": "f2xxxxxxxxxxxxxxxxxxxxxxxx", "name": "photo.jpg", "extension": "jpg", "size": 3, "mime_type": "image/jpeg", "width": 1, "height": 1, "has_preview_image": true}
      ],
      "client_ids": ["client-1", "client-2"]
    }
    """#

    // MARK: WebSocket frames

    static func hello(connectionId: String, seq: Int64 = 0) -> String {
        #"{"event":"hello","data":{"connection_id":"\#(connectionId)","server_version":"9.11.1.10234567.f4b4f3a6b0b84d7e.true"},"broadcast":{"omit_users":null,"user_id":"9fsrebgu3jdq9xf5t1rf6khtmo","channel_id":"","team_id":"","connection_id":"","omit_connection_id":""},"seq":\#(seq)}"#
    }

    static func typing(seq: Int64) -> String {
        #"{"event":"typing","data":{"parent_id":"","user_id":"kq7xqbs6ofbbpmcs9ycw1mn1yc"},"broadcast":{"omit_users":{"kq7xqbs6ofbbpmcs9ycw1mn1yc":true},"user_id":"","channel_id":"3ofz1xexwbdu9fuhm3ihsunhzr","team_id":""},"seq":\#(seq)}"#
    }

    static let posted = #"""
    {"event":"posted","data":{"channel_display_name":"Town Square","channel_name":"town-square","channel_type":"O","mentions":"[\"9fsrebgu3jdq9xf5t1rf6khtmo\"]","followers":"[\"kq7xqbs6ofbbpmcs9ycw1mn1yc\"]","post":"{\"id\":\"n3wp0stxxxxxxxxxxxxxxxxxxx\",\"create_at\":1700001100000,\"update_at\":1700001100000,\"edit_at\":0,\"delete_at\":0,\"is_pinned\":false,\"user_id\":\"kq7xqbs6ofbbpmcs9ycw1mn1yc\",\"channel_id\":\"3ofz1xexwbdu9fuhm3ihsunhzr\",\"root_id\":\"\",\"original_id\":\"\",\"message\":\"hello @alice\",\"type\":\"\",\"props\":{},\"hashtags\":\"\",\"pending_post_id\":\"kq7xqbs6ofbbpmcs9ycw1mn1yc:1700001099000\",\"reply_count\":0,\"last_reply_at\":0,\"participants\":null,\"metadata\":{}}","sender_name":"@bob","set_online":true,"team_id":"ybsmnm8jkjfmdqmtmcrcuxfzbe"},"broadcast":{"omit_users":null,"user_id":"","channel_id":"3ofz1xexwbdu9fuhm3ihsunhzr","team_id":"","connection_id":"","omit_connection_id":""},"seq":1}
    """#

    static let postEdited = #"""
    {"event":"post_edited","data":{"post":"{\"id\":\"n3wp0stxxxxxxxxxxxxxxxxxxx\",\"create_at\":1700001100000,\"update_at\":1700001200000,\"edit_at\":1700001200000,\"delete_at\":0,\"user_id\":\"kq7xqbs6ofbbpmcs9ycw1mn1yc\",\"channel_id\":\"3ofz1xexwbdu9fuhm3ihsunhzr\",\"message\":\"hello @alice (edited)\",\"type\":\"\",\"props\":{}}"},"broadcast":{"omit_users":null,"user_id":"","channel_id":"3ofz1xexwbdu9fuhm3ihsunhzr","team_id":""},"seq":2}
    """#

    static let postDeleted = #"""
    {"event":"post_deleted","data":{"delete_by":"kq7xqbs6ofbbpmcs9ycw1mn1yc","post":"{\"id\":\"n3wp0stxxxxxxxxxxxxxxxxxxx\",\"create_at\":1700001100000,\"update_at\":1700001300000,\"delete_at\":1700001300000,\"user_id\":\"kq7xqbs6ofbbpmcs9ycw1mn1yc\",\"channel_id\":\"3ofz1xexwbdu9fuhm3ihsunhzr\",\"message\":\"\",\"type\":\"\"}"},"broadcast":{"omit_users":null,"user_id":"","channel_id":"3ofz1xexwbdu9fuhm3ihsunhzr","team_id":""},"seq":3}
    """#

    static let reactionAdded = #"""
    {"event":"reaction_added","data":{"reaction":"{\"user_id\":\"kq7xqbs6ofbbpmcs9ycw1mn1yc\",\"post_id\":\"n3wp0stxxxxxxxxxxxxxxxxxxx\",\"emoji_name\":\"+1\",\"create_at\":1700001400000,\"update_at\":1700001400000,\"delete_at\":0,\"remote_id\":\"\",\"channel_id\":\"3ofz1xexwbdu9fuhm3ihsunhzr\"}"},"broadcast":{"omit_users":null,"user_id":"","channel_id":"3ofz1xexwbdu9fuhm3ihsunhzr","team_id":""},"seq":4}
    """#

    static let reactionRemoved = #"""
    {"event":"reaction_removed","data":{"reaction":"{\"user_id\":\"kq7xqbs6ofbbpmcs9ycw1mn1yc\",\"post_id\":\"n3wp0stxxxxxxxxxxxxxxxxxxx\",\"emoji_name\":\"+1\",\"create_at\":0}"},"broadcast":{"channel_id":"3ofz1xexwbdu9fuhm3ihsunhzr"},"seq":5}
    """#

    static let channelViewed = #"""
    {"event":"channel_viewed","data":{"channel_id":"3ofz1xexwbdu9fuhm3ihsunhzr"},"broadcast":{"omit_users":null,"user_id":"9fsrebgu3jdq9xf5t1rf6khtmo","channel_id":"","team_id":""},"seq":6}
    """#

    static let multipleChannelsViewed = #"""
    {"event":"multiple_channels_viewed","data":{"channel_times":{"3ofz1xexwbdu9fuhm3ihsunhzr":1700001500000,"pb1bt4wqepdj8xg6ymbiec1ydh":1700001500001}},"broadcast":{"user_id":"9fsrebgu3jdq9xf5t1rf6khtmo"},"seq":7}
    """#

    static let statusChange = #"""
    {"event":"status_change","data":{"status":"away","user_id":"kq7xqbs6ofbbpmcs9ycw1mn1yc"},"broadcast":{"omit_users":null,"user_id":"kq7xqbs6ofbbpmcs9ycw1mn1yc","channel_id":"","team_id":""},"seq":8}
    """#

    static let threadUpdated = #"""
    {"event":"thread_updated","data":{"previous_unread_mentions":0,"previous_unread_replies":1,"thread":"{\"id\":\"p1xxxxxxxxxxxxxxxxxxxxxxxx\",\"reply_count\":5,\"last_reply_at\":1700001600000,\"last_viewed_at\":1700000500000,\"participants\":[{\"id\":\"kq7xqbs6ofbbpmcs9ycw1mn1yc\"}],\"post\":{\"id\":\"p1xxxxxxxxxxxxxxxxxxxxxxxx\",\"message\":\"first\"},\"unread_replies\":2,\"unread_mentions\":0,\"is_urgent\":false}"},"broadcast":{"user_id":"9fsrebgu3jdq9xf5t1rf6khtmo","team_id":"ybsmnm8jkjfmdqmtmcrcuxfzbe"},"seq":9}
    """#

    static let pongReply = #"""
    {"status":"OK","seq_reply":5,"data":{"node_id":"","server_time":1700001700000,"text":"pong","version":"9.11.1"}}
    """#

    static let failedReply = #"""
    {"status":"FAIL","seq_reply":6,"error":{"id":"api.web_socket_router.bad_action.app_error","message":"Invalid action.","detailed_error":"","request_id":"","status_code":400}}
    """#
}

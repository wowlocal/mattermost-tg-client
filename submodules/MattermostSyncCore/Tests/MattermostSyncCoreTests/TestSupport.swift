import Foundation
import MattermostSyncCore

/// SplitMix64: small, fast, deterministic.
struct SeededGenerator: RandomNumberGenerator {
    var state: UInt64

    init(seed: UInt64) {
        self.state = seed
    }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

enum Times {
    /// 2013-01-01T00:00:00Z
    static let year2013: Int64 = 1_356_998_400_000
    /// 2025-01-01T00:00:00Z
    static let year2025: Int64 = 1_735_689_600_000
    /// 2026-01-01T00:00:00Z
    static let year2026: Int64 = 1_767_225_600_000
    static let day: Int64 = 86_400_000
}

private let idAlphabet = Array("abcdefghijklmnopqrstuvwxyz0123456789")

func randomPostId<G: RandomNumberGenerator>(_ rng: inout G) -> String {
    return String((0 ..< 26).map { _ in idAlphabet[Int(rng.next() % UInt64(idAlphabet.count))] })
}

/// An in-memory Mattermost channel answering the history queries the sync engine makes.
struct FakeServer {
    /// All posts ever created, sorted by key. Deleted ones stay here (as in Mattermost's DB).
    private(set) var posts: [PostOrderKey] = []
    private(set) var deleted = Set<String>()
    private var keyById: [String: PostOrderKey] = [:]

    init(posts: [PostOrderKey] = []) {
        for post in posts {
            add(post)
        }
    }

    var livePosts: [PostOrderKey] {
        return posts.filter { !deleted.contains($0.postId) }
    }

    func key(of postId: String) -> PostOrderKey? {
        return keyById[postId]
    }

    mutating func add(_ post: PostOrderKey) {
        let index = lowerIndex(post)
        posts.insert(post, at: index)
        keyById[post.postId] = post
    }

    mutating func delete(_ postId: String) {
        deleted.insert(postId)
    }

    func isDeleted(_ postId: String) -> Bool {
        return deleted.contains(postId)
    }

    private func lowerIndex(_ key: PostOrderKey) -> Int {
        var low = 0
        var high = posts.count
        while low < high {
            let mid = (low + high) / 2
            if posts[mid] < key {
                low = mid + 1
            } else {
                high = mid
            }
        }
        return low
    }

    /// `GET /channels/{id}/posts?page=0&per_page=limit` (returned oldest first).
    func latest(limit: Int) -> (posts: [PostOrderKey], reachedEnd: Bool) {
        var result: [PostOrderKey] = []
        var index = posts.count - 1
        while index >= 0 && result.count < limit {
            if !deleted.contains(posts[index].postId) {
                result.append(posts[index])
            }
            index -= 1
        }
        let reachedEnd = !posts[0 ..< max(0, index + 1)].contains { !deleted.contains($0.postId) }
        return (result.reversed(), reachedEnd)
    }

    /// `before=postId`: the `limit` newest live posts older than the cursor.
    func before(_ postId: String, limit: Int) -> (posts: [PostOrderKey], reachedEnd: Bool) {
        guard let key = keyById[postId] else {
            return ([], true)
        }
        var result: [PostOrderKey] = []
        var index = lowerIndex(key) - 1
        while index >= 0 && result.count < limit {
            if !deleted.contains(posts[index].postId) {
                result.append(posts[index])
            }
            index -= 1
        }
        return (result.reversed(), result.count < limit)
    }

    /// `after=postId`: the `limit` oldest live posts newer than the cursor.
    func after(_ postId: String, limit: Int) -> (posts: [PostOrderKey], reachedEnd: Bool) {
        guard let key = keyById[postId] else {
            return ([], true)
        }
        var result: [PostOrderKey] = []
        var index = lowerIndex(key) + 1
        while index < posts.count && result.count < limit {
            if !deleted.contains(posts[index].postId) {
                result.append(posts[index])
            }
            index += 1
        }
        return (result, result.count < limit)
    }

    /// Live posts with `lower <= key <= upper`.
    func livePosts(in lower: PostOrderKey, _ upper: PostOrderKey) -> [PostOrderKey] {
        var result: [PostOrderKey] = []
        var index = lowerIndex(lower)
        while index < posts.count && !(upper < posts[index]) {
            if !deleted.contains(posts[index].postId) {
                result.append(posts[index])
            }
            index += 1
        }
        return result
    }

    func hasLivePost(olderThan key: PostOrderKey) -> Bool {
        return posts[0 ..< lowerIndex(key)].contains { !deleted.contains($0.postId) }
    }

    func hasLivePost(newerThan key: PostOrderKey) -> Bool {
        var index = lowerIndex(key)
        if index < posts.count && posts[index] == key {
            index += 1
        }
        return posts[index...].contains { !deleted.contains($0.postId) }
    }
}

/// Posts with increasing timestamps: `count` posts starting at `start`, `spacing` ms apart.
func makePosts<G: RandomNumberGenerator>(count: Int, start: Int64, spacing: Int64, rng: inout G) -> [PostOrderKey] {
    return (0 ..< count).map { PostOrderKey(createAt: start + Int64($0) * spacing, postId: randomPostId(&rng)) }.sorted()
}

import Foundation

// MARK: - Own status, custom status, profile (Phase 3F)

extension MattermostClient {
    /// `GET /users/{user_id}/status`.
    public func userStatus(userId: String = MattermostClient.currentUser) async throws -> UserStatus {
        try await send(APIRequest(.get, apiPath("users", userId, "status")))
    }

    /// `PUT /users/{user_id}/status`: sets the user's status by hand. `userId` must be the real id (the server
    /// compares it with the body's `user_id`). `dndEndTime` (Unix seconds) ends a `dnd` status; the server then
    /// restores the previous status and broadcasts `status_change`.
    @discardableResult
    public func updateStatus(_ status: UserStatus.Status, userId: String, dndEndTime: Int64? = nil) async throws -> UserStatus {
        let body = UserStatusUpdate(userId: userId, status: status.rawValue, dndEndTime: status == .dnd ? dndEndTime.flatMap { $0 > 0 ? $0 : nil } : nil)
        return try await send(APIRequest.json(.put, apiPath("users", userId, "status"), body: body))
    }

    /// `PUT /users/{user_id}/status/custom`. The server also adds it to the recent statuses
    /// (`custom_status` / `recent_custom_statuses` preference).
    public func updateCustomStatus(_ status: UserCustomStatus, userId: String = MattermostClient.currentUser) async throws {
        try await sendIgnoringResponse(APIRequest.json(.put, apiPath("users", userId, "status", "custom"), body: status))
    }

    /// `DELETE /users/{user_id}/status/custom`: clears the custom status.
    public func removeCustomStatus(userId: String = MattermostClient.currentUser) async throws {
        try await sendIgnoringResponse(APIRequest(.delete, apiPath("users", userId, "status", "custom")))
    }

    /// `POST /users/{user_id}/status/custom/recent/delete`: removes one entry from the recent statuses.
    public func removeRecentCustomStatus(_ status: UserCustomStatus, userId: String = MattermostClient.currentUser) async throws {
        try await sendIgnoringResponse(APIRequest.json(.post, apiPath("users", userId, "status", "custom", "recent", "delete"), body: status))
    }

    /// The recently used custom statuses (newest first), from the `custom_status` preferences.
    public func recentCustomStatuses(userId: String = MattermostClient.currentUser) async throws -> [UserCustomStatus] {
        do {
            let preferences: [Preference] = try await send(APIRequest(.get, apiPath("users", userId, "preferences", PreferenceCategory.customStatus)))
            return preferences.recentCustomStatuses
        } catch let error as MattermostError where error.statusCode == 404 {
            // No preference in the category yet.
            return []
        }
    }

    /// `PUT /users/{user_id}/patch`: changes the fields set in `patch` and returns the updated user.
    public func patchUser(_ patch: UserPatch, userId: String = MattermostClient.currentUser) async throws -> User {
        try await send(APIRequest.json(.put, apiPath("users", userId, "patch"), body: patch))
    }

    /// `POST /users/{user_id}/image` (multipart field `image`): sets the profile picture. The server bumps
    /// `last_picture_update` and broadcasts `user_updated`.
    public func uploadProfileImage(_ data: Data, fileName: String = "profile.jpg", mimeType: String = "image/jpeg", userId: String = MattermostClient.currentUser) async throws {
        var form = MultipartFormData()
        form.addFile(name: "image", fileName: fileName, mimeType: mimeType, content: .data(data))
        let body = try form.encodedData()
        let request = APIRequest(.post, apiPath("users", userId, "image"), body: body, contentType: form.contentType)
        try await sendIgnoringResponse(request)
    }

    /// `DELETE /users/{user_id}/image`: back to the server's generated picture (`last_picture_update` becomes
    /// negative on 11.x, see `User.hasCustomPicture`).
    public func deleteProfileImage(userId: String = MattermostClient.currentUser) async throws {
        try await sendIgnoringResponse(APIRequest(.delete, apiPath("users", userId, "image")))
    }
}

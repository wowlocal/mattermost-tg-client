import Foundation
import SwiftSignalKit
import TelegramCore
import AccountContext
import TelegramVoip

/// What Telegram's 1:1 call screens (`CallControllerNodeV2`, `VideoChatScreen` for a conference source) need of a
/// `PresentationCall` beyond the protocol: its video frames, the outgoing camera, screen sharing and the speaker
/// route. Adopted by Telegram's `PresentationCallImpl` and Relay's `RelayPresentationCall`, so the screens no longer
/// cast to the MTProto implementation.
public protocol PresentationCallVideoProviding: AnyObject {
    /// The outgoing camera is on.
    var hasVideo: Bool { get }
    /// The screen is being shared.
    var hasScreencast: Bool { get }
    /// The call's audio plays through the receiver (the remote camera tone is played only then).
    var isAudioOutputBuiltin: Bool { get }
    /// Peers to invite once a call becomes a conference (empty when the call cannot become one).
    var pendingInviteToConferencePeerIds: [(id: EnginePeer.Id, isVideo: Bool)] { get }

    /// Frames of the outgoing camera (`isIncoming: false`) or of the other side's video; nil when there is none.
    func video(isIncoming: Bool) -> Signal<OngoingGroupCallContext.VideoFrameData, NoError>?
    /// Starts sending video from a capturer the screen created (the camera preview's).
    func requestVideo(capturer: OngoingCallVideoCapturer)
    func disableScreencast()
    func playRemoteCameraTone()
}

/// What `VideoChatScreen` needs of a `PresentationGroupCall` beyond the protocol: participants' video by endpoint and
/// the camera the screen's preview created. Adopted by Telegram's `PresentationGroupCallImpl` and Relay's
/// `RelayPresentationGroupCall`.
public protocol PresentationGroupCallVideoProviding: AnyObject {
    /// The frames of a participant's video (`GroupCallParticipantsContext.Participant.VideoDescription.endpointId`),
    /// the own camera included.
    func video(endpointId: String) -> Signal<OngoingGroupCallContext.VideoFrameData, NoError>?
    func requestVideo(capturer: OngoingCallVideoCapturer, useFrontCamera: Bool)
}

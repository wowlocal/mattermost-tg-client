import Postbox

// MATTERMOST: only counted DM roots have a receipt that channel membership can prove.
public final class MattermostReadReceiptEligibleAttribute: MessageAttribute {
    public init() {}
    public init(decoder: PostboxDecoder) {}
    public func encode(_ encoder: PostboxEncoder) {}
}

public extension Message {
    var mattermostReadReceiptEligible: Bool {
        return self.attributes.contains { $0 is MattermostReadReceiptEligibleAttribute }
    }

    func outgoingReadState(confirmed: Bool, legacy: Bool? = nil, ownPeerId: PeerId? = nil) -> Bool {
        guard MattermostBackend.isEnabled else { return legacy ?? confirmed }
        if self.id.peerId == ownPeerId { return true }
        return self.mattermostReadReceiptEligible && confirmed
    }
}

public extension EngineMessage {
    var mattermostReadReceiptEligible: Bool {
        return self._asMessage().mattermostReadReceiptEligible
    }

    func outgoingReadState(confirmed: Bool, legacy: Bool? = nil, ownPeerId: PeerId? = nil) -> Bool {
        return self._asMessage().outgoingReadState(confirmed: confirmed, legacy: legacy, ownPeerId: ownPeerId)
    }
}

public extension CombinedPeerReadState {
    func isOutgoingMessageRead(_ message: Message) -> Bool {
        return message.outgoingReadState(confirmed: self.isOutgoingMessageIndexRead(message.index))
    }

    func isOutgoingMessageRead(_ message: EngineMessage) -> Bool {
        return self.isOutgoingMessageRead(message._asMessage())
    }
}

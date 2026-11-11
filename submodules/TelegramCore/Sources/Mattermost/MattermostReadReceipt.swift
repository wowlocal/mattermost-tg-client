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
}

public extension EngineMessage {
    var mattermostReadReceiptEligible: Bool {
        return self._asMessage().mattermostReadReceiptEligible
    }
}

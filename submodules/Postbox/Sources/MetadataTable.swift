import Foundation

private enum MetadataKey: Int32 {
    case UserVersion = 1
    case State = 2
    case TransactionStateVersion = 3
    case MasterClientId = 4
    case RemoteContactCount = 6
    // MATTERMOST: see `chatListTopMessageTag()`.
    case ChatListTopMessageTag = 7
}

final class MetadataTable: Table {
    static func tableSpec(_ id: Int32) -> ValueBoxTable {
        return ValueBoxTable(id: id, keyType: .int64, compactValuesOnCreation: false)
    }
    
    private var cachedState: PostboxCoding?
    private var cachedRemoteContactCount: Int32?
    
    private let sharedBuffer = WriteBuffer()
    
    override init(valueBox: ValueBox, table: ValueBoxTable, useCaches: Bool) {
        super.init(valueBox: valueBox, table: table, useCaches: useCaches)
    }
    
    private func key(_ key: MetadataKey) -> ValueBoxKey {
        let valueBoxKey = ValueBoxKey(length: 8)
        valueBoxKey.setInt64(0, value: Int64(key.rawValue))
        return valueBoxKey
    }
    
    func userVersion() -> Int32? {
        if let value = self.valueBox.get(self.table, key: self.key(.UserVersion)) {
            var version: Int32 = 0
            value.read(&version, offset: 0, length: 4)
            return version
        }
        return nil
    }
    
    func setUserVersion(_ version: Int32) {
        sharedBuffer.reset()
        let buffer = sharedBuffer
        var varVersion: Int32 = version
        buffer.write(&varVersion, offset: 0, length: 4)
        self.valueBox.set(self.table, key: self.key(.UserVersion), value: buffer)
    }
    
    func state() -> PostboxCoding? {
        if let cachedState = self.cachedState {
            return cachedState
        } else {
            if let value = self.valueBox.get(self.table, key: self.key(.State)) {
                if let state = PostboxDecoder(buffer: value).decodeRootObject() {
                    self.cachedState = state
                    return state
                }
            }
            return nil
        }
    }
    
    func setState(_ state: PostboxCoding) {
        self.cachedState = state
        
        let encoder = PostboxEncoder()
        encoder.encodeRootObject(state)
        withExtendedLifetime(encoder, {
            self.valueBox.set(self.table, key: self.key(.State), value: encoder.readBufferNoCopy())
        })
    }
    
    func transactionStateVersion() -> Int64 {
        if let value = self.valueBox.get(self.table, key: self.key(.TransactionStateVersion)) {
            var version: Int64 = 0
            value.read(&version, offset: 0, length: 8)
            return version
        } else {
            return 0
        }
    }
    
    func incrementTransactionStateVersion() -> Int64 {
        var version = self.transactionStateVersion() + 1
        sharedBuffer.reset()
        let buffer = sharedBuffer
        buffer.write(&version, offset: 0, length: 8)
        self.valueBox.set(self.table, key: self.key(.TransactionStateVersion), value: buffer)
        return version
    }
    
    func masterClientId() -> Int64 {
        if let value = self.valueBox.get(self.table, key: self.key(.MasterClientId)) {
            var clientId: Int64 = 0
            value.read(&clientId, offset: 0, length: 8)
            return clientId
        } else {
            return 0
        }
    }
    
    func setMasterClientId(_ id: Int64) {
        sharedBuffer.reset()
        let buffer = sharedBuffer
        var clientId = id
        buffer.write(&clientId, offset: 0, length: 8)
        self.valueBox.set(self.table, key: self.key(.MasterClientId), value: buffer)
    }
    
    func setRemoteContactCount(_ count: Int32) {
        self.cachedRemoteContactCount = count
        var mutableCount: Int32 = count
        self.valueBox.set(self.table, key: self.key(.RemoteContactCount), value: MemoryBuffer(memory: &mutableCount, capacity: 4, length: 4, freeWhenDone: false))
    }
    
    func getRemoteContactCount() -> Int32 {
        if let cachedRemoteContactCount = self.cachedRemoteContactCount {
            return cachedRemoteContactCount
        } else {
            if let value = self.valueBox.get(self.table, key: self.key(.RemoteContactCount)) {
                var count: Int32 = 0
                value.read(&count, offset: 0, length: 4)
                self.cachedRemoteContactCount = count
                return count
            } else {
                self.cachedRemoteContactCount = 0
                return 0
            }
        }
    }
    
    // MATTERMOST: the tag whose newest message is a chat list row's top message (collapsed reply threads: root
    // posts only), for every peer except `exceptPeerId`; nil: the newest message (Telegram's behaviour).
    func chatListTopMessageTag() -> (tag: MessageTags, exceptPeerId: PeerId?)? {
        guard let value = self.valueBox.get(self.table, key: self.key(.ChatListTopMessageTag)), value.length >= 12 else {
            return nil
        }
        var rawTag: UInt32 = 0
        var exceptPeerId: Int64 = 0
        value.read(&rawTag, offset: 0, length: 4)
        value.read(&exceptPeerId, offset: 4, length: 8)
        return (MessageTags(rawValue: rawTag), exceptPeerId == 0 ? nil : PeerId(exceptPeerId))
    }
    
    // MATTERMOST: see `chatListTopMessageTag()`.
    func setChatListTopMessageTag(_ value: (tag: MessageTags, exceptPeerId: PeerId?)?) {
        if let value = value {
            sharedBuffer.reset()
            let buffer = sharedBuffer
            var rawTag: UInt32 = value.tag.rawValue
            var exceptPeerId: Int64 = value.exceptPeerId?.toInt64() ?? 0
            buffer.write(&rawTag, offset: 0, length: 4)
            buffer.write(&exceptPeerId, offset: 4, length: 8)
            self.valueBox.set(self.table, key: self.key(.ChatListTopMessageTag), value: buffer)
        } else {
            self.valueBox.remove(self.table, key: self.key(.ChatListTopMessageTag), secure: false)
        }
    }
    
    override func clearMemoryCache() {
        self.cachedState = nil
        self.cachedRemoteContactCount = nil
    }
}

import Foundation
import CoreMedia
import SwiftSignalKit
import Postbox
import TelegramCore
import MattermostKit
import MattermostSyncCore
import ConvertOpusToAAC
import UniversalMediaPlayer

/// Relay's voice messages (Phase 5A, design: mattermost-sync.md "Voice messages (5A)").
///
/// Mattermost has no voice-message post type, so Telegram's recording (Ogg/Opus, `.Audio(isVoice: true)`) goes
/// out as an ordinary post with one audio file, transcoded on the device to AAC in an `.m4a` (decision V1: every
/// Mattermost client plays it as a file; Telegram's own `convertOpusToAAC`, mono, 48 kHz, 32 kbps), named
/// "Voice message 2026-10-27 14.05.m4a", and marked in the post's props (`VoiceMessageMarker`: duration and
/// waveform) so Relay shows it as a voice bubble (`PostConverter.voiceMarker`). Other audio files stay files.
public enum MattermostVoiceMessages {
    /// The start of an uploaded recording's file name, before its date ("Voice message"): MattermostUI sets the
    /// localized text at launch; the sync has no strings of its own.
    public static var fileNamePrefix: () -> String = { "Voice message" }
}

extension PostSender {
    /// The local file of a recording (Telegram's recorder or a forwarded voice message) and what its marker says.
    struct VoiceRecording {
        var file: TelegramMediaFile
        var duration: Int
        var waveform: Data?

        /// A recording still in Telegram's format (Ogg/Opus): transcoded before the upload. A forwarded voice
        /// message is already the server's file and goes as it is.
        var needsTranscoding: Bool {
            let mimeType = self.file.mimeType.lowercased()
            return mimeType == "audio/ogg" || mimeType == "audio/opus" || mimeType == "audio/ogg; codecs=opus"
        }

        init?(media: Media) {
            guard let file = media as? TelegramMediaFile else {
                return nil
            }
            for attribute in file.attributes {
                if case let .Audio(isVoice, duration, _, _, waveform) = attribute, isVoice {
                    self.file = file
                    self.duration = duration
                    self.waveform = waveform
                    return
                }
            }
            return nil
        }

        var marker: VoiceMessageMarker {
            return VoiceMessageMarker(duration: self.duration, waveform: self.waveform)
        }
    }

    /// The single voice recording of an outgoing message, if it is one.
    static func voiceRecording(of message: Message) -> VoiceRecording? {
        let files = message.media.filter { $0 is TelegramMediaFile || $0 is TelegramMediaImage }
        guard files.count == 1, let recording = VoiceRecording(media: files[0]) else {
            return nil
        }
        return recording
    }

    /// Transcodes a recording to AAC (`.m4a`) in a temporary file; nil when it fails.
    static func transcodeVoiceRecording(sourcePath: String, name: String) async -> String? {
        let directory = NSTemporaryDirectory() + "relay-voice"
        try? FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        let outputPath = directory + "/\(name).\(VoiceMessageFile.fileExtension)"
        // AVAssetWriter refuses an existing file (a run that ended halfway).
        try? FileManager.default.removeItem(atPath: outputPath)
        let started = CFAbsoluteTimeGetCurrent()
        let result: String? = await withCheckedContinuation { (continuation: CheckedContinuation<String?, Never>) in
            let resumed = Atomic<Bool>(value: false)
            let _ = convertOpusToAAC(sourcePath: sourcePath, allocateTempFile: {
                return outputPath
            }).start(next: { path in
                if !resumed.swap(true) {
                    continuation.resume(returning: path)
                }
            }, completed: {
                if !resumed.swap(true) {
                    continuation.resume(returning: nil)
                }
            })
        }
        let sourceSize = (try? FileManager.default.attributesOfItem(atPath: sourcePath)[.size] as? Int64) ?? 0
        guard let path = result, let size = (try? FileManager.default.attributesOfItem(atPath: path)[.size] as? Int64), size > 64 else {
            MMLog.log("voice: transcoding \(name) failed")
            return nil
        }
        MMLog.log("voice: transcoded \(name) (Ogg/Opus \(sourceSize) bytes → AAC \(size) bytes) in \(Int((CFAbsoluteTimeGetCurrent() - started) * 1000)) ms")
        return path
    }
}

extension MattermostAccountSync {
    // MARK: Sending

    /// The props marker of an outgoing message that is a voice recording (`outgoingDraft`).
    func voiceProps(of message: Message) -> [String: JSONValue] {
        guard let recording = PostSender.voiceRecording(of: message), let value = JSONValue(foundationObject: recording.marker.propsValue) else {
            return [:]
        }
        return [VoiceMessageMarker.propsKey: value]
    }

    // MARK: Waveforms computed here

    static let voiceWaveformCursorPrefix = "voice_waveform:"

    /// A waveform computed on this device for a voice message whose marker has none.
    func computedVoiceWaveform(fileId: String) -> Data? {
        return self.store.cursor(MattermostAccountSync.voiceWaveformCursorPrefix + fileId).flatMap { Data(base64Encoded: $0) }
    }

    /// Voice messages just written without a waveform: their files are downloaded (voice messages are small and
    /// Telegram downloads them anyway to show them) and the waveform computed from the audio, one at a time.
    func noteVoiceMessagesWithoutWaveform(_ messages: [StoreMessage], channelId: String) {
        for message in messages {
            guard case let .Id(messageId) = message.id else {
                continue
            }
            for media in message.media {
                guard let file = media as? TelegramMediaFile, let resource = file.resource as? MattermostFileResource else {
                    continue
                }
                var isVoiceWithoutWaveform = false
                for attribute in file.attributes {
                    if case let .Audio(isVoice, _, _, _, waveform) = attribute, isVoice, waveform == nil {
                        isVoiceWithoutWaveform = true
                    }
                }
                if isVoiceWithoutWaveform {
                    self.scheduleVoiceWaveform(fileId: resource.fileId, resource: resource, messageId: messageId)
                }
            }
        }
    }

    private func scheduleVoiceWaveform(fileId: String, resource: MattermostFileResource, messageId: MessageId) {
        let isNew = voiceWaveformWork.with { work -> Bool in
            if work.scheduled.contains(fileId) {
                return false
            }
            work.scheduled.insert(fileId)
            return true
        }
        guard isNew else {
            return
        }
        let previous = voiceWaveformWork.with { $0.tail }
        let task = Task { [weak self] in
            await previous?.value
            guard let self, !self.isStopped else {
                return
            }
            await self.computeVoiceWaveform(fileId: fileId, resource: resource, messageId: messageId)
            voiceWaveformWork.with { _ = $0.scheduled.remove(fileId) }
        }
        voiceWaveformWork.with { $0.tail = task }
    }

    private func computeVoiceWaveform(fileId: String, resource: MattermostFileResource, messageId: MessageId) async {
        guard let path = try? await self.completeResourcePath(resource) else {
            MMLog.log("voice: no data for the waveform of \(fileId)")
            return
        }
        let started = CFAbsoluteTimeGetCurrent()
        guard let pcm = decodeVoicePCM(path: path), !pcm.isEmpty else {
            MMLog.log("voice: could not decode \(fileId) for its waveform")
            return
        }
        let waveform = VoiceWaveform.pack(VoiceWaveform.fromPCM(pcm))
        await self.postbox.mmTransaction { transaction in
            self.store.setCursor(MattermostAccountSync.voiceWaveformCursorPrefix + fileId, waveform.base64EncodedString())
            transaction.updateMessage(messageId, update: { current in
                let media = current.media.map { item -> Media in
                    guard let file = item as? TelegramMediaFile, (file.resource as? MattermostFileResource)?.fileId == fileId else {
                        return item
                    }
                    let attributes = file.attributes.map { attribute -> TelegramMediaFileAttribute in
                        if case let .Audio(isVoice, duration, title, performer, existing) = attribute, isVoice, existing == nil {
                            return .Audio(isVoice: true, duration: duration, title: title, performer: performer, waveform: waveform)
                        }
                        return attribute
                    }
                    return file.withUpdatedAttributes(attributes)
                }
                return .update(StoreMessage.mmCopy(of: current, id: current.id, threadId: current.threadId, attributes: current.attributes, media: media))
            })
        }
        MMLog.log("voice: computed the waveform of \(fileId) (\(pcm.count) samples) in \(Int((CFAbsoluteTimeGetCurrent() - started) * 1000)) ms")
    }
}

/// Voice waveforms being computed (one at a time, across accounts).
private struct VoiceWaveformWork {
    var scheduled = Set<String>()
    var tail: Task<Void, Never>?
}

private let voiceWaveformWork = MMLocked(VoiceWaveformWork())

/// The audio of a file as 48 kHz mono 16-bit samples (FFmpeg: m4a, Ogg/Opus, mp3, wav, …).
private func decodeVoicePCM(path: String) -> [Int16]? {
    let source = SoftwareAudioSource(path: path)
    guard source.hasStream else {
        return nil
    }
    var samples: [Int16] = []
    // At most 30 minutes.
    let limit = 48_000 * 60 * 30
    while samples.count < limit, let sampleBuffer = source.readSampleBuffer() {
        guard let blockBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else {
            continue
        }
        let length = CMBlockBufferGetDataLength(blockBuffer)
        if length < 2 {
            continue
        }
        var bytes = [UInt8](repeating: 0, count: length)
        guard CMBlockBufferCopyDataBytes(blockBuffer, atOffset: 0, dataLength: length, destination: &bytes) == kCMBlockBufferNoErr else {
            continue
        }
        bytes.withUnsafeBytes { raw in
            samples.append(contentsOf: raw.bindMemory(to: Int16.self))
        }
    }
    return samples
}

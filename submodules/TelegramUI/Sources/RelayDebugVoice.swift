import Foundation
import UIKit
import AVFoundation
import Display
import SwiftSignalKit
import Postbox
import TelegramCore
import AccountContext
import ChatPresentationInterfaceState
import ChatControllerInteraction
import TelegramUIPreferences
import MattermostSync
import MattermostUI
import PeerInfoScreen

#if DEBUG // MATTERMOST: debug builds only; release builds compile none of this file (Phase 4A)

// MATTERMOST: debug only (Phase 5A). Voice messages without a microphone, and the debug remote's voice commands.
//
// `RelayDebugFakeMicrophone` replaces the microphone in `ManagedAudioRecorderContext` (debug builds): the recorder
// encodes, measures and previews its audio exactly as it does the microphone's, so hold-to-record, lock, pause,
// resume, preview and send all run Telegram's own code. A recording on the simulator would otherwise open the
// Mac's microphone, which can raise a macOS privacy prompt nobody answers. Set it at launch with
// `RELAY_DEBUG_FAKE_MIC=tone` (a varying 440 Hz tone) or `RELAY_DEBUG_FAKE_MIC=<file>` (any audio AVFoundation reads;
// a relative path is under the app's Documents), or at run time with the remote's `fake-mic`.
//
// Remote commands (`tools/relay-remote.py`, output in `extra`):
// - `fake-mic` (`file=<path>` | `tone=<seconds>` | `off=1`): the fake microphone;
// - `voice` (`do=record|lock|pause|resume|preview|send|cancel|state`): the record button's actions in the visible chat
//   (`beginMediaRecording`, `lockMediaRecording`, `stopMediaRecording`, `resumeMediaRecording`, `finishMediaRecording`,
//   `sendRecordedMedia`, `deleteRecordedMedia`), i.e. what holding, sliding up, the stop/pause, resume, send and
//   delete buttons call;
// - `voice-messages`: the voice messages of the visible chat (post, duration, waveform, played state, file);
// - `voice-play` (`index=<n>`, 0 the newest, or `post=<id>`): a tap on a voice message's play button
//   (`openMessage`);
// - `player` (`rate=1|1.5|2`, `do=pause|play|toggle|next|stop`): the shared media player's state and controls.
final class RelayDebugFakeMicrophone {
    /// The fake microphone in use; nil: the real one.
    static var current: RelayDebugFakeMicrophone? = RelayDebugFakeMicrophone.fromEnvironment()

    let name: String
    /// 48 kHz mono 16-bit samples, played in a loop.
    let samples: [Int16]

    init(name: String, samples: [Int16]) {
        self.name = name
        self.samples = samples.isEmpty ? [0] : samples
    }

    var seconds: Double {
        return Double(self.samples.count) / 48_000.0
    }

    func fill(_ pointer: UnsafeMutablePointer<Int16>, count: Int, offset: Int) {
        for index in 0 ..< count {
            pointer[index] = self.samples[(offset + index) % self.samples.count]
        }
    }

    static func fromEnvironment() -> RelayDebugFakeMicrophone? {
        guard let value = ProcessInfo.processInfo.environment["RELAY_DEBUG_FAKE_MIC"], !value.isEmpty else {
            return nil
        }
        if value == "tone" {
            return .tone(seconds: 20)
        }
        return .file(path: value)
    }

    /// A 440 Hz tone whose loudness rises and falls like speech (so the waveform has shape), with short pauses.
    static func tone(seconds: Double) -> RelayDebugFakeMicrophone {
        let count = Int(max(1, seconds) * 48_000)
        var samples = [Int16](repeating: 0, count: count)
        for index in 0 ..< count {
            let t = Double(index) / 48_000.0
            let syllable = max(0, sin(2 * .pi * 2.3 * t))
            let phrase = 0.5 + 0.5 * sin(2 * .pi * 0.31 * t)
            let pause = (Int(t) % 5 == 4) ? 0.0 : 1.0
            let amplitude = 14_000.0 * syllable * phrase * pause
            samples[index] = Int16(amplitude * sin(2 * .pi * 440 * t))
        }
        return RelayDebugFakeMicrophone(name: "tone \(Int(seconds)) s", samples: samples)
    }

    /// Any audio file AVFoundation reads (wav, aiff, m4a, mp3), converted to 48 kHz mono 16-bit.
    static func file(path: String) -> RelayDebugFakeMicrophone? {
        var resolved = path
        if !path.hasPrefix("/"), let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first {
            resolved = documents.appendingPathComponent(path).path
        }
        guard let file = try? AVAudioFile(forReading: URL(fileURLWithPath: resolved)) else {
            return nil
        }
        guard let target = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 48_000, channels: 1, interleaved: true), let converter = AVAudioConverter(from: file.processingFormat, to: target) else {
            return nil
        }
        let frameCount = AVAudioFrameCount(file.length)
        guard frameCount > 0, let input = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: frameCount), (try? file.read(into: input)) != nil else {
            return nil
        }
        let outputCapacity = AVAudioFrameCount(Double(frameCount) * 48_000 / file.processingFormat.sampleRate) + 4_800
        guard let output = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: outputCapacity) else {
            return nil
        }
        var consumed = false
        var error: NSError?
        let status = converter.convert(to: output, error: &error, withInputFrom: { _, inputStatus in
            if consumed {
                inputStatus.pointee = .endOfStream
                return nil
            }
            consumed = true
            inputStatus.pointee = .haveData
            return input
        })
        guard status != .error, let channel = output.int16ChannelData else {
            return nil
        }
        let samples = Array(UnsafeBufferPointer(start: channel[0], count: Int(output.frameLength)))
        return RelayDebugFakeMicrophone(name: (resolved as NSString).lastPathComponent, samples: samples)
    }
}

extension TelegramRootController {
    func relayDebugInstallVoiceCommands() {
        let previous = MattermostDebugChatCommands.handler
        MattermostDebugChatCommands.handler = { [weak self] action, command, completion in
            if let self, let context = self.chatListController?.context, self.relayDebugRunVoiceCommand(context: context, action: action, command: command, completion: completion) {
                return true
            }
            return previous?(action, command, completion) ?? false
        }
        if let fakeMicrophone = RelayDebugFakeMicrophone.current {
            Logger.shared.log("Relay", "debug: fake microphone \(fakeMicrophone.name)")
        }
    }

    private var relayVoiceTopChat: ChatControllerImpl? {
        return self.viewControllers.last as? ChatControllerImpl
    }

    private func relayDebugVoiceMessages(_ chat: ChatControllerImpl, accountId: AccountRecordId) -> [(message: Message, info: [String: Any])] {
        var result: [(message: Message, info: [String: Any])] = []
        chat.chatDisplayNode.historyNode.forEachVisibleMessageItemNode { itemNode in
            guard let item = itemNode.item else {
                return
            }
            let message = item.message
            guard let file = message.media.first(where: { ($0 as? TelegramMediaFile)?.isVoice ?? false }) as? TelegramMediaFile else {
                return
            }
            var info: [String: Any] = [
                "id": Int(message.id.id),
                "namespace": Int(message.id.namespace),
                "post": MattermostSync.debugPostId(accountId: accountId, messageId: message.id) ?? "",
                "incoming": message.flags.contains(.Incoming),
                "mimeType": file.mimeType,
                "fileName": file.fileName ?? "",
                "size": Int(file.size ?? 0),
                "voiceTag": message.tags.contains(.voiceOrInstantVideo),
                "threadId": message.threadId.map { Int($0) } ?? 0,
            ]
            for attribute in file.attributes {
                if case let .Audio(_, duration, _, _, waveform) = attribute {
                    info["duration"] = duration
                    info["waveformBytes"] = waveform?.count ?? 0
                }
            }
            if let consumable = message.attributes.first(where: { $0 is ConsumableContentMessageAttribute }) as? ConsumableContentMessageAttribute {
                info["played"] = consumable.consumed
            }
            if let path = chat.context.account.postbox.mediaBox.completedResourcePath(file.resource) {
                info["downloaded"] = true
                info["dataBytes"] = (try? FileManager.default.attributesOfItem(atPath: path)[.size] as? Int) ?? 0
            } else {
                info["downloaded"] = false
            }
            result.append((message, info))
        }
        result.sort(by: { $0.message.index > $1.message.index })
        return result
    }

    private func relayDebugRunVoiceCommand(context: AccountContext, action: String, command: [String: Any], completion: @escaping (Bool, String?, [String: Any]) -> Void) -> Bool {
        let accountId = context.account.id
        switch action {
        case "fake-mic":
            if command["off"] != nil {
                RelayDebugFakeMicrophone.current = nil
            } else if let file = command["file"] as? String {
                guard let microphone = RelayDebugFakeMicrophone.file(path: file) else {
                    completion(false, "could not read \(file)", [:])
                    return true
                }
                RelayDebugFakeMicrophone.current = microphone
            } else {
                let seconds = Double((command["tone"] as? String) ?? "") ?? 20
                RelayDebugFakeMicrophone.current = .tone(seconds: seconds)
            }
            let current = RelayDebugFakeMicrophone.current
            completion(true, nil, ["fakeMicrophone": current?.name ?? "off", "seconds": current?.seconds ?? 0])
        case "voice":
            guard let chat = self.relayVoiceTopChat, let interaction = chat.interfaceInteraction else {
                completion(false, "no chat", [:])
                return true
            }
            let step = (command["do"] as? String) ?? "state"
            switch step {
            case "record":
                interaction.beginMediaRecording(false)
            case "lock":
                interaction.lockMediaRecording()
            case "pause":
                interaction.stopMediaRecording()
            case "resume":
                interaction.resumeMediaRecording()
            case "preview":
                interaction.finishMediaRecording(.preview)
            case "send":
                if chat.presentationInterfaceState.interfaceState.mediaDraftState != nil && chat.presentationInterfaceState.inputTextPanelState.mediaRecordingState == nil {
                    interaction.sendRecordedMedia(false, false)
                } else {
                    interaction.finishMediaRecording(.send(viewOnce: false))
                }
            case "cancel":
                if chat.presentationInterfaceState.inputTextPanelState.mediaRecordingState != nil {
                    interaction.finishMediaRecording(.dismiss)
                } else {
                    interaction.deleteRecordedMedia()
                }
            case "state":
                break
            default:
                completion(false, "unknown step \(step)", [:])
                return true
            }
            Queue.mainQueue().after(step == "state" ? 0.0 : 1.0) {
                var info: [String: Any] = ["fakeMicrophone": RelayDebugFakeMicrophone.current?.name ?? "off"]
                switch chat.presentationInterfaceState.inputTextPanelState.mediaRecordingState {
                case let .audio(_, isLocked):
                    info["recording"] = isLocked ? "audio, locked" : "audio"
                case .video:
                    info["recording"] = "video"
                case .waitingForPreview:
                    info["recording"] = "waiting for preview"
                case .none:
                    info["recording"] = "none"
                }
                if case let .audio(audio) = chat.presentationInterfaceState.interfaceState.mediaDraftState {
                    info["draft"] = ["duration": audio.duration, "fileSize": Int(audio.fileSize), "waveformSamples": audio.waveform.samples.count / 2, "resumable": audio.resumeData != nil] as [String: Any]
                }
                info["micButtonMode"] = chat.presentationInterfaceState.interfaceState.mediaRecordingMode == .audio ? "audio" : "video"
                completion(true, nil, info)
            }
        case "voice-messages":
            guard let chat = self.relayVoiceTopChat else {
                completion(false, "no chat", [:])
                return true
            }
            completion(true, nil, ["voiceMessages": self.relayDebugVoiceMessages(chat, accountId: accountId).map { $0.info }])
        case "voice-play":
            guard let chat = self.relayVoiceTopChat else {
                completion(false, "no chat", [:])
                return true
            }
            let voiceMessages = self.relayDebugVoiceMessages(chat, accountId: accountId)
            var target: Message?
            if let postId = command["post"] as? String {
                target = voiceMessages.first(where: { ($0.info["post"] as? String) == postId })?.message
            } else {
                let index = Int((command["index"] as? String) ?? "0") ?? 0
                target = index < voiceMessages.count ? voiceMessages[index].message : nil
            }
            guard let message = target else {
                completion(false, "no such voice message", [:])
                return true
            }
            let opened = chat.controllerInteraction?.openMessage(message, OpenMessageParams(mode: .default)) ?? false
            completion(opened, opened ? nil : "not opened", ["message": Int(message.id.id)])
        case "peerinfo-pane":
            // The chat's profile (as the chat title opens it), switched to a media pane (`pane`, default voice).
            guard let chat = command["chat"] as? String, let peerId = MattermostSync.debugChatPeerId(accountId: accountId, query: chat) else {
                completion(false, "no chat", [:])
                return true
            }
            let pane = (command["pane"] as? String) ?? "voice"
            let _ = (context.engine.data.get(TelegramEngine.EngineData.Item.Peer.Peer(id: peerId))
            |> deliverOnMainQueue).startStandalone(next: { [weak self] peer in
                guard let self, let peer, let controller = context.sharedContext.makePeerInfoController(context: context, updatedPresentationData: nil, peer: peer, mode: .generic, avatarInitiallyExpanded: false, fromChat: false, requestsContext: nil) else {
                    completion(false, "no profile", [:])
                    return
                }
                self.pushViewController(controller)
                Queue.mainQueue().after(2.0) {
                    let panes = (controller as? PeerInfoScreenImpl)?.relayDebugShowPane(pane) ?? []
                    Queue.mainQueue().after(3.0) {
                        completion(true, nil, ["panes": panes])
                    }
                }
            })
        case "player":
            let mediaManager = context.sharedContext.mediaManager
            if let rate = command["rate"] as? String {
                let value: AudioPlaybackRate
                switch rate {
                case "1.5":
                    value = .x1_5
                case "2":
                    value = .x2
                default:
                    value = .x1
                }
                mediaManager.playlistControl(.setBaseRate(value), type: .voice)
            }
            if let step = command["do"] as? String {
                switch step {
                case "pause":
                    mediaManager.playlistControl(.playback(.pause), type: .voice)
                case "play":
                    mediaManager.playlistControl(.playback(.play), type: .voice)
                case "toggle":
                    mediaManager.playlistControl(.playback(.togglePlayPause), type: .voice)
                case "next":
                    mediaManager.playlistControl(.next, type: .voice)
                case "stop":
                    mediaManager.setPlaylist(nil, type: .voice, control: .playback(.pause))
                default:
                    break
                }
            }
            let _ = (mediaManager.globalMediaPlayerState
            |> take(1)
            |> deliverOnMainQueue).startStandalone(next: { value in
                guard let (_, stateOrLoading, type) = value else {
                    completion(true, nil, ["player": "none"])
                    return
                }
                var info: [String: Any] = ["type": type == .voice ? "voice" : "music"]
                switch stateOrLoading {
                case .loading:
                    info["player"] = "loading"
                case let .state(state):
                    info["player"] = "\(state.status.status)"
                    info["timestamp"] = state.status.timestamp
                    info["duration"] = state.status.duration
                    info["baseRate"] = state.status.baseRate
                    if let id = state.item.id as? PeerMessagesMediaPlaylistItemId {
                        info["message"] = Int(id.messageId.id)
                        info["post"] = MattermostSync.debugPostId(accountId: accountId, messageId: id.messageId) ?? ""
                    }
                    if let next = state.nextItem?.id as? PeerMessagesMediaPlaylistItemId {
                        info["nextMessage"] = Int(next.messageId.id)
                    }
                }
                completion(true, nil, info)
            })
        default:
            return false
        }
        return true
    }
}

#endif

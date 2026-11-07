import Foundation
import Combine
import LiveKit
import RelayCallsCore

@MainActor
public final class RelayCallSession: ObservableObject {
    public let client: RelayCallsClient
    public let channelId: String
    public let title: String
    public let room = Room()
    @Published public private(set) var call: RelayCall?
    @Published public private(set) var status = "Ready to join"
    @Published public private(set) var error: String?
    @Published public private(set) var isJoining = false
    @Published public private(set) var isConnected = false
    @Published public private(set) var microphoneEnabled = false
    @Published public private(set) var screenShareEnabled = false
    @Published public private(set) var isChangingMedia = false
    #if os(macOS)
    @Published public private(set) var screenSources: [MacOSScreenCaptureSource] = []
    @Published public var showingScreenSources = false
    #endif
    private var timer: AnyCancellable?
    private var lifecycle = UUID()

    public init(client: RelayCallsClient, channelId: String, title: String) {
        self.client = client
        self.channelId = channelId
        self.title = title
        timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect().sink { [weak self] _ in
            self?.refreshMediaState()
        }
    }

    public var participants: [Participant] {
        let remote: [Participant] = room.remoteParticipants.values.sorted { ($0.name ?? "") < ($1.name ?? "") }
        return isConnected ? [room.localParticipant] + remote : remote
    }

    public var sharedScreens: [(String, VideoTrack)] {
        participants.flatMap { participant in
            participant.videoTracks.compactMap { publication in
                guard publication.source == .screenShareVideo, !publication.isMuted, let track = publication.track as? VideoTrack else { return nil }
                return (participant.name ?? "Screen share", track)
            }
        }
    }

    public func join() async {
        guard !isJoining, !isConnected else { return }
        isJoining = true
        error = nil
        status = "Joining…"
        let attempt = UUID()
        lifecycle = attempt
        do {
            let response = try await client.join(channelId: channelId)
            guard lifecycle == attempt else { return }
            call = response.call
            try await room.connect(url: response.url, token: response.token)
            guard lifecycle == attempt else { await room.disconnect(); return }
            isConnected = true
            status = "Connected"
            do {
                try await room.localParticipant.setMicrophone(enabled: true)
                microphoneEnabled = true
            } catch {
                self.error = "Joined with microphone off. " + error.localizedDescription
            }
        } catch {
            if lifecycle == attempt {
                self.error = error.localizedDescription
                status = "Could not join"
                await room.disconnect()
            }
        }
        if lifecycle == attempt { isJoining = false }
    }

    public func leave() async {
        lifecycle = UUID()
        isJoining = false
        await room.disconnect()
        isConnected = false
        microphoneEnabled = false
        screenShareEnabled = false
        status = "Call left"
    }

    public func endForEveryone() async -> Bool {
        guard let call, call.canEnd else { return false }
        do {
            try await client.end(channelId: channelId, callId: call.id)
            await leave()
            status = "Call ended"
            return true
        } catch { self.error = error.localizedDescription; return false }
    }

    public func toggleMicrophone() async {
        guard isConnected, !isChangingMedia else { return }
        isChangingMedia = true
        defer { isChangingMedia = false }
        do {
            try await room.localParticipant.setMicrophone(enabled: !microphoneEnabled)
            microphoneEnabled.toggle()
        } catch { self.error = error.localizedDescription }
    }

    public func toggleScreenShare() async {
        guard isConnected, !isChangingMedia else { return }
        isChangingMedia = true
        defer { isChangingMedia = false }
        do {
            #if os(macOS)
            if !screenShareEnabled {
                screenSources = try await MacOSScreenCapturer.sources(for: .any)
                showingScreenSources = true
                return
            }
            #endif
            try await room.localParticipant.setScreenShare(enabled: !screenShareEnabled)
            screenShareEnabled.toggle()
        } catch { self.error = error.localizedDescription }
    }

    #if os(macOS)
    public func shareScreen(source: MacOSScreenCaptureSource) async {
        guard isConnected, !isChangingMedia else { return }
        isChangingMedia = true
        showingScreenSources = false
        defer { isChangingMedia = false }
        do {
            let track = await LocalVideoTrack.createMacOSScreenShareTrack(source: source)
            try await room.localParticipant.publish(videoTrack: track)
            screenShareEnabled = true
        } catch { self.error = error.localizedDescription }
    }

    public func screenSourceName(_ source: MacOSScreenCaptureSource) -> String {
        if let window = source as? MacOSWindow {
            return [window.owningApplication?.applicationName, window.title].compactMap { $0 }.joined(separator: " — ")
        }
        if let display = source as? MacOSDisplay { return "Display \(display.displayID)" }
        return "Screen"
    }
    #endif

    private func refreshMediaState() {
        if isConnected {
            microphoneEnabled = room.localParticipant.isMicrophoneEnabled()
            screenShareEnabled = room.localParticipant.isScreenShareEnabled()
            switch room.connectionState {
            case .reconnecting: status = "Reconnecting…"
            case .connected: status = "Connected"
            case .disconnected:
                isConnected = false
                microphoneEnabled = false
                screenShareEnabled = false
                status = "Call disconnected"
            default: break
            }
        }
        objectWillChange.send()
    }
}

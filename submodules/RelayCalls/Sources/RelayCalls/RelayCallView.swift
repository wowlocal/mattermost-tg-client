import SwiftUI
import LiveKit

@MainActor
public struct RelayCallView: View {
    @ObservedObject private var session: RelayCallSession
    private let close: () -> Void
    private let minimize: (() -> Void)?

    public init(session: RelayCallSession, close: @escaping () -> Void, minimize: (() -> Void)? = nil) {
        self.session = session
        self.close = close
        self.minimize = minimize
    }

    public var body: some View {
        VStack(spacing: 20) {
            VStack(spacing: 5) {
                Text(session.title).font(.title2).bold()
                Text(session.status).font(.subheadline).foregroundStyle(.secondary)
            }
            if let minimize { Button("Back to chat", action: minimize).font(.caption) }
            ScrollView {
                VStack(spacing: 16) {
                    ForEach(Array(session.sharedScreens.enumerated()), id: \.offset) { _, screen in
                        VStack(alignment: .leading) {
                            Text(screen.0).font(.caption)
                            SwiftUIVideoView(screen.1, layoutMode: .fit).frame(minHeight: 220).aspectRatio(16 / 9, contentMode: .fit)
                        }
                    }
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 110))], spacing: 16) {
                        ForEach(Array(session.participants.enumerated()), id: \.offset) { _, participant in
                            VStack(spacing: 9) {
                                Image(systemName: participant.isMicrophoneEnabled() ? "person.wave.2.fill" : "mic.slash.fill")
                                    .font(.system(size: 28)).foregroundStyle(participant.isSpeaking ? Color.accentColor : Color.secondary)
                                    .frame(width: 64, height: 64).background(Color.secondary.opacity(0.12)).clipShape(Circle())
                                Text(participant.name ?? "Participant").font(.subheadline).lineLimit(2)
                            }.padding(8)
                        }
                    }
                }
            }
            if let error = session.error {
                Text(error).font(.callout).foregroundStyle(.red).textSelection(.enabled)
            }
            HStack(spacing: 18) {
                if session.isConnected {
                    Button { Task { await session.toggleMicrophone() } } label: {
                        Label(session.microphoneEnabled ? "Mute" : "Unmute", systemImage: session.microphoneEnabled ? "mic.fill" : "mic.slash.fill")
                    }.disabled(session.isChangingMedia)
                    Button { Task { await session.toggleScreenShare() } } label: {
                        Label(session.screenShareEnabled ? "Stop sharing" : "Share screen", systemImage: "rectangle.on.rectangle")
                    }.disabled(session.isChangingMedia)
                } else {
                    Button("Join call") { Task { await session.join() } }.disabled(session.isJoining)
                }
                Button(role: .destructive) {
                    Task { await session.leave(); close() }
                } label: { Label(session.isConnected ? "Leave" : "Close", systemImage: "phone.down.fill") }
            }.buttonStyle(.bordered)
            if session.isConnected, session.call?.canEnd == true {
                Button("End call for everyone", role: .destructive) { Task { if await session.endForEveryone() { close() } } }
                    .font(.caption)
            }
        }
        .padding(24)
        .frame(minWidth: 300, minHeight: 430)
        #if os(macOS)
        .sheet(isPresented: $session.showingScreenSources) {
            VStack(alignment: .leading, spacing: 16) {
                Text("Choose a screen or window").font(.headline)
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        ForEach(Array(session.screenSources.enumerated()), id: \.offset) { _, source in
                            Button(session.screenSourceName(source)) { Task { await session.shareScreen(source: source) } }
                        }
                    }
                }
                Button("Cancel") { session.showingScreenSources = false }
            }.padding(24).frame(width: 480, height: 420)
        }
        #endif
    }
}

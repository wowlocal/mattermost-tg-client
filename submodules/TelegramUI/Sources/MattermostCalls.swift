import Foundation
import UIKit
import SwiftUI
import AccountContext
import Postbox
import MattermostKit
import MattermostSync
import RelayCalls
import RelayCallsCore

@MainActor
private enum MattermostCallPresentation {
    static var controller: UIViewController?
    static var session: RelayCallSession?
}

func mattermostPresentCall(from presenter: UIViewController, context: AccountContext, peerId: PeerId) {
    Task { @MainActor [weak presenter] in
        guard let presenter else { return }
        if let controller = MattermostCallPresentation.controller {
            if controller.presentingViewController == nil { presenter.present(controller, animated: true) }
            return
        }
        do {
            let target = try await MattermostSync.callTarget(accountId: context.account.id, peerId: peerId)
            if MattermostCallPresentation.controller != nil { return }
            let client = RelayCallsClient(serverURL: target.serverURL, token: target.sessionToken, session: MattermostURLSession.current)
            let session = RelayCallSession(client: client, channelId: target.channelId, title: target.title)
            let controller = UIHostingController(rootView: RelayCallView(session: session, close: {
                MattermostCallPresentation.controller?.dismiss(animated: true)
                MattermostCallPresentation.controller = nil
                MattermostCallPresentation.session = nil
            }, minimize: {
                MattermostCallPresentation.controller?.dismiss(animated: true)
            }))
            controller.modalPresentationStyle = .fullScreen
            controller.isModalInPresentation = true
            MattermostCallPresentation.controller = controller
            MattermostCallPresentation.session = session
            presenter.present(controller, animated: true)
            await session.join()
        } catch {
            let alert = UIAlertController(title: "Voice call", message: error.localizedDescription, preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: "OK", style: .default))
            presenter.present(alert, animated: true)
        }
    }
}

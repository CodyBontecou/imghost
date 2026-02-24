import Cocoa
import SwiftUI
import os.log

private let logger = Logger(subsystem: "com.codybontecou.imghost.ShareExtension", category: "ViewController")

class MacShareViewController: NSViewController {

    override func loadView() {
        logger.info("MacShareViewController loadView called")
        logger.info("Extension context: \(String(describing: self.extensionContext))")
        logger.info("Backend URL: \(Config.backendURL)")
        logger.info("Has valid tokens: \(KeychainService.shared.hasValidTokens)")

        let hostingView = NSHostingView(rootView: MacShareView(extensionContext: self.extensionContext))
        hostingView.frame = NSRect(x: 0, y: 0, width: 420, height: 480)
        self.view = hostingView
        self.preferredContentSize = NSSize(width: 420, height: 480)

        logger.info("MacShareViewController loadView completed")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        logger.info("MacShareViewController viewDidLoad")
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        logger.info("MacShareViewController viewDidAppear")
    }
}

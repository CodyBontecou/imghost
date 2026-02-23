import Cocoa
import SwiftUI

class MacShareViewController: NSViewController {

    override func loadView() {
        let hostingView = NSHostingView(rootView: MacShareView(extensionContext: self.extensionContext))
        hostingView.frame = NSRect(x: 0, y: 0, width: 420, height: 480)
        self.view = hostingView
        self.preferredContentSize = NSSize(width: 420, height: 480)
    }

    override func viewDidLoad() {
        super.viewDidLoad()
    }
}

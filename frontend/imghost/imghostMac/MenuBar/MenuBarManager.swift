import SwiftUI
import AppKit

/// Manages the NSStatusItem (menu bar icon) and its popover
@MainActor
final class MenuBarManager: ObservableObject {
    static let shared = MenuBarManager()

    private var statusItem: NSStatusItem?
    private let popover = NSPopover()
    private var eventMonitor: Any?

    private init() {}

    func setup() {
        // Create status item
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)

        if let button = item.button {
            // Use the app icon for the menu bar
            if let image = NSImage(named: "MenuBarIcon") {
                image.size = NSSize(width: 18, height: 18)
                button.image = image
            }
            button.action = #selector(togglePopover(_:))
            button.target = self
        }

        statusItem = item

        // Configure popover
        popover.contentSize = NSSize(width: 320, height: 440)
        popover.behavior = .transient
        popover.animates = true

        let hostingController = NSHostingController(
            rootView: MenuBarPopoverView(
                onDismiss: { [weak self] in self?.closePopover() },
                onShowMainWindow: { [weak self] in
                    self?.closePopover()
                    self?.showMainWindow()
                }
            )
            .environmentObject(AuthState.shared)
        )
        popover.contentViewController = hostingController
    }

    @objc private func togglePopover(_ sender: AnyObject?) {
        if popover.isShown {
            closePopover()
        } else {
            openPopover()
        }
    }

    private func openPopover() {
        guard let button = statusItem?.button else { return }
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)

        // Close popover when clicking outside
        eventMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            self?.closePopover()
        }
    }

    private func closePopover() {
        popover.performClose(nil)
        if let monitor = eventMonitor {
            NSEvent.removeMonitor(monitor)
            eventMonitor = nil
        }
    }

    private func showMainWindow() {
        NSApp.activate(ignoringOtherApps: true)
        // Open/focus the main window
        if let window = NSApp.windows.first(where: { $0.title != "" || $0.contentViewController is NSHostingController<MacContentView> }) {
            window.makeKeyAndOrderFront(nil)
        } else {
            // Fallback: just activate the app which should show the window group
            for window in NSApp.windows {
                if !window.title.contains("Settings") && window.contentView != nil {
                    window.makeKeyAndOrderFront(nil)
                    break
                }
            }
        }
    }
}

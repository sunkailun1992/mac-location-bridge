import AppKit

// Construct the real view hierarchy without showing a window, requesting a
// location, running a CLI child, or changing trust/network configuration.
precondition(Thread.isMainThread)
let application = NSApplication.shared
application.setActivationPolicy(.prohibited)
let controller = MainWindowController()
guard let window = controller.window, let content = window.contentView else {
    fatalError("App construction did not produce a window and content view")
}
content.layoutSubtreeIfNeeded()
precondition(!window.isVisible, "The construction check must never show a window")
precondition(!content.subviews.isEmpty, "The app content hierarchy is missing")
print("App construction passed: hidden window and complete view hierarchy")
withExtendedLifetime(controller) {}

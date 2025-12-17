import SwiftUI
import Quartz

// Global keyboard manager - singleton with single event monitor
class KeyboardManager {
    static let shared = KeyboardManager()

    private var eventMonitor: Any?
    private var activeHandler: (() -> Bool)?

    private init() {
        eventMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self = self,
                  let window = NSApp.keyWindow,
                  window.isKeyWindow,
                  let handler = self.activeHandler else {
                return event
            }

            if handler() {
                return nil // Consume event
            }
            return event
        }
    }

    func setHandler(_ handler: @escaping () -> Bool) {
        activeHandler = handler
    }

    func clearHandler() {
        activeHandler = nil
    }
}

// View modifier for keyboard handling - doesn't wrap the view
struct KeyboardNavigable: ViewModifier {
    let isActive: Bool
    let onUpArrow: () -> Void
    let onDownArrow: () -> Void
    let onLeftArrow: () -> Void
    let onRightArrow: () -> Void
    let onReturn: () -> Void
    let onSpace: () -> Void

    func body(content: Content) -> some View {
        content
            .onAppear {
                if isActive {
                    // Delay registration to ensure window is ready
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                        registerHandler()
                    }
                }
            }
            .onChange(of: isActive) { _, newValue in
                if newValue {
                    registerHandler()
                }
            }
        // No .onDisappear clear - new view's handler will overwrite
    }

    private func registerHandler() {
        KeyboardManager.shared.setHandler { [onUpArrow, onDownArrow, onLeftArrow, onRightArrow, onReturn, onSpace] in
            guard let event = NSApp.currentEvent else { return false }

            switch event.keyCode {
            case 126: // Up arrow
                onUpArrow()
                return true
            case 125: // Down arrow
                onDownArrow()
                return true
            case 123: // Left arrow
                onLeftArrow()
                return true
            case 124: // Right arrow
                onRightArrow()
                return true
            case 36: // Return
                onReturn()
                return true
            case 49: // Space
                onSpace()
                return true
            default:
                return false
            }
        }
    }
}

extension View {
    func keyboardNavigable(
        isActive: Bool = true,
        onUpArrow: @escaping () -> Void = {},
        onDownArrow: @escaping () -> Void = {},
        onLeftArrow: @escaping () -> Void = {},
        onRightArrow: @escaping () -> Void = {},
        onReturn: @escaping () -> Void = {},
        onSpace: @escaping () -> Void = {}
    ) -> some View {
        modifier(KeyboardNavigable(
            isActive: isActive,
            onUpArrow: onUpArrow,
            onDownArrow: onDownArrow,
            onLeftArrow: onLeftArrow,
            onRightArrow: onRightArrow,
            onReturn: onReturn,
            onSpace: onSpace
        ))
    }
}

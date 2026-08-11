import ApplicationServices
import CoreGraphics

/// Thin wrappers over the C Accessibility API.
///
/// Every call can fail — the target application may be busy, sandboxed in a way
/// that hides its window list, or simply gone since the last enumeration — so
/// everything returns an optional rather than trapping.
enum AX {

    // MARK: - Attribute names not exported as constants by the SDK

    static let fullScreenAttribute = "AXFullScreen"
    /// Chromium and Electron applications keep their accessibility tree switched
    /// off until someone asks for it by setting this. Without it their windows
    /// are invisible to us.
    static let manualAccessibilityAttribute = "AXManualAccessibility"

    // MARK: - Reading

    static func copy(_ element: AXUIElement, _ attribute: String) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else {
            return nil
        }
        return value
    }

    static func string(_ element: AXUIElement, _ attribute: String) -> String? {
        copy(element, attribute) as? String
    }

    static func bool(_ element: AXUIElement, _ attribute: String) -> Bool? {
        copy(element, attribute) as? Bool
    }

    static func windows(of application: AXUIElement) -> [AXUIElement]? {
        copy(application, kAXWindowsAttribute as String) as? [AXUIElement]
    }

    /// A conditional cast to a CoreFoundation type always succeeds, so the type
    /// has to be checked explicitly before forcing it.
    private static func axValue(_ element: AXUIElement, _ attribute: String) -> AXValue? {
        guard let raw = copy(element, attribute),
              CFGetTypeID(raw) == AXValueGetTypeID()
        else { return nil }
        return (raw as! AXValue)
    }

    static func position(_ window: AXUIElement) -> CGPoint? {
        guard let value = axValue(window, kAXPositionAttribute as String),
              AXValueGetType(value) == .cgPoint
        else { return nil }
        var point = CGPoint.zero
        guard AXValueGetValue(value, .cgPoint, &point) else { return nil }
        return point
    }

    static func size(_ window: AXUIElement) -> CGSize? {
        guard let value = axValue(window, kAXSizeAttribute as String),
              AXValueGetType(value) == .cgSize
        else { return nil }
        var size = CGSize.zero
        guard AXValueGetValue(value, .cgSize, &size) else { return nil }
        return size
    }

    /// Window bounds in Accessibility space — origin top-left of the primary
    /// display, y growing downwards.
    static func frame(_ window: AXUIElement) -> CGRect? {
        guard let origin = position(window), let size = size(window) else { return nil }
        return CGRect(origin: origin, size: size)
    }

    static func isSettable(_ element: AXUIElement, _ attribute: String) -> Bool {
        var settable: DarwinBoolean = false
        guard AXUIElementIsAttributeSettable(element, attribute as CFString, &settable) == .success else {
            return false
        }
        return settable.boolValue
    }

    // MARK: - Writing

    @discardableResult
    static func setPosition(_ window: AXUIElement, _ point: CGPoint) -> Bool {
        var point = point
        guard let value = AXValueCreate(.cgPoint, &point) else { return false }
        return AXUIElementSetAttributeValue(window, kAXPositionAttribute as CFString, value) == .success
    }

    @discardableResult
    static func setSize(_ window: AXUIElement, _ size: CGSize) -> Bool {
        var size = size
        guard let value = AXValueCreate(.cgSize, &size) else { return false }
        return AXUIElementSetAttributeValue(window, kAXSizeAttribute as CFString, value) == .success
    }

    // MARK: - Applications

    static func application(pid: pid_t, timeout: Float = 0.5) -> AXUIElement {
        let element = AXUIElementCreateApplication(pid)
        // Without a timeout a hung application blocks the caller indefinitely.
        AXUIElementSetMessagingTimeout(element, timeout)
        AXUIElementSetAttributeValue(element,
                                     manualAccessibilityAttribute as CFString,
                                     kCFBooleanTrue)
        return element
    }

    // MARK: - Permission

    static var isTrusted: Bool { AXIsProcessTrusted() }

    /// Shows the system prompt if the app has never been granted access.
    static func requestTrust() {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        _ = AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
    }
}

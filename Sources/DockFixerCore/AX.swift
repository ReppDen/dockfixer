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

    /// Why a read came back empty, for the debug log.
    ///
    /// The read is repeated rather than plumbed through every accessor: this is
    /// only ever called after one has already failed, so the extra round trip
    /// costs nothing on the path that works. `cannotComplete` is the one to
    /// expect — it is what a messaging timeout looks like, and applications go
    /// unresponsive while the window server rebuilds the display layout.
    static func readFailure(_ element: AXUIElement, _ attribute: String) -> String {
        var value: CFTypeRef?
        let error = AXUIElementCopyAttributeValue(element, attribute as CFString, &value)
        return "\(attribute)=\(describe(error))"
    }

    static func describe(_ error: AXError) -> String {
        switch error {
        case .success: return "success (but the value was of an unexpected type)"
        case .failure: return "failure"
        case .illegalArgument: return "illegalArgument"
        case .invalidUIElement: return "invalidUIElement"
        case .invalidUIElementObserver: return "invalidUIElementObserver"
        case .cannotComplete: return "cannotComplete (timed out or the app is not responding)"
        case .attributeUnsupported: return "attributeUnsupported"
        case .actionUnsupported: return "actionUnsupported"
        case .notificationUnsupported: return "notificationUnsupported"
        case .notImplemented: return "notImplemented"
        case .notificationAlreadyRegistered: return "notificationAlreadyRegistered"
        case .notificationNotRegistered: return "notificationNotRegistered"
        case .apiDisabled: return "apiDisabled (Accessibility access is off)"
        case .noValue: return "noValue"
        case .parameterizedAttributeUnsupported: return "parameterizedAttributeUnsupported"
        case .notEnoughPrecision: return "notEnoughPrecision"
        @unknown default: return "AXError(\(error.rawValue))"
        }
    }

    static func isSettable(_ element: AXUIElement, _ attribute: String) -> Bool {
        var settable: DarwinBoolean = false
        guard AXUIElementIsAttributeSettable(element, attribute as CFString, &settable) == .success else {
            return false
        }
        return settable.boolValue
    }

    // MARK: - Writing

    /// The error is returned rather than a flag because a `FAIL` line that
    /// says `cannotComplete` or `illegalArgument` tells which application is
    /// at fault; "the write did not take" on its own does not.
    @discardableResult
    static func setPosition(_ window: AXUIElement, _ point: CGPoint) -> AXError {
        var point = point
        guard let value = AXValueCreate(.cgPoint, &point) else { return .failure }
        return AXUIElementSetAttributeValue(window, kAXPositionAttribute as CFString, value)
    }

    @discardableResult
    static func setSize(_ window: AXUIElement, _ size: CGSize) -> AXError {
        var size = size
        guard let value = AXValueCreate(.cgSize, &size) else { return .failure }
        return AXUIElementSetAttributeValue(window, kAXSizeAttribute as CFString, value)
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

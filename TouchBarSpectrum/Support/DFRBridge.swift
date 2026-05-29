import AppKit

/// Thin wrapper over the two private DFRFoundation C functions that drive
/// control-strip persistence. Resolved at runtime with dlopen/dlsym so the app
/// carries no link-time dependency on the private framework (which the modern
/// linker may refuse for lack of a public `.tbd` stub). If the symbols ever
/// disappear, `isAvailable` reports false and the app degrades gracefully instead
/// of failing to launch.
enum DFRBridge {

    private typealias SetPresenceFn = @convention(c) (NSString, ObjCBool) -> Void
    private typealias ShowCloseBoxFn = @convention(c) (ObjCBool) -> Void

    private static let handle: UnsafeMutableRawPointer? = dlopen(
        "/System/Library/PrivateFrameworks/DFRFoundation.framework/DFRFoundation",
        RTLD_NOW)

    private static let _setPresence: SetPresenceFn? = symbol("DFRElementSetControlStripPresenceForIdentifier")
    private static let _showCloseBox: ShowCloseBoxFn? = symbol("DFRSystemModalShowsCloseBoxWhenFrontMost")

    private static func symbol<T>(_ name: String) -> T? {
        guard let handle, let sym = dlsym(handle, name) else { return nil }
        return unsafeBitCast(sym, to: T.self)
    }

    /// True when the private framework loaded and both symbols resolved.
    static var isAvailable: Bool { _setPresence != nil && _showCloseBox != nil }

    /// Keep (or remove) the item in the control strip even when the app is not
    /// frontmost. Must be re-asserted on every launch — the system does not persist it.
    static func setControlStripPresence(_ identifier: NSTouchBarItem.Identifier, present: Bool) {
        _setPresence?(identifier.rawValue as NSString, ObjCBool(present))
    }

    /// Whether the expanded system-modal bar shows a close box while frontmost.
    static func systemModalShowsCloseBoxWhenFrontMost(_ show: Bool) {
        _showCloseBox?(ObjCBool(show))
    }
}

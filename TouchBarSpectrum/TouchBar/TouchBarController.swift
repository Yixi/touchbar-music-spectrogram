import AppKit

/// Owns the Touch Bar presence. Two surfaces, both fed by the same `VisualizerEngine`:
///
///   1. A persistent control-strip slot (~64pt) holding a live mini KITT scanner.
///      It stays visible even when the app is not frontmost. Tapping it expands.
///   2. A system-modal, ~685pt-wide bar (placement 0, beside the control strip)
///      with the full KITT scanner, shown on tap and dismissed via its close box
///      or by tapping the slot again.
///
/// The wide view only exists while presented — the control strip itself cannot
/// host a 685pt view permanently (a hard platform constraint), so this expand-on-tap
/// model is the canonical Pock/MTMR pattern.
final class TouchBarController: NSObject, NSTouchBarDelegate {

    static let slotItemID = NSTouchBarItem.Identifier("com.yixi.TouchBarSpectrum.slot")
    static let wideItemID = NSTouchBarItem.Identifier("com.yixi.TouchBarSpectrum.wide")

    private let engine: VisualizerEngine

    private var slotItem: NSCustomTouchBarItem?
    private weak var slotView: TouchBarSpectrumView?     // owned by slotItem
    private var wideBar: NSTouchBar?
    private var wideItem: NSCustomTouchBarItem?          // strong: lifetime == presentation
    private var wideView: TouchBarSpectrumView?          // strong: registered view == on-screen view
    private(set) var isExpanded = false

    init(engine: VisualizerEngine) {
        self.engine = engine
        super.init()
    }

    /// True when the private Touch Bar APIs are reachable on this system.
    var isSupported: Bool { DFRBridge.isAvailable }

    // MARK: Control-strip registration (call once on launch; not persisted by the OS)

    func install() {
        guard isSupported else {
            NSLog("[TouchBarSpectrum] DFRFoundation unavailable — control-strip item not installed.")
            return
        }
        let slot = NSCustomTouchBarItem(identifier: Self.slotItemID)

        // The out-of-process control-strip agent only delivers taps through NSControl
        // target/action — never to a bare NSView (mouseDown / gesture recognizers do
        // not fire). So the item's view must be an NSButton; the animating scanner
        // rides inside it as a non-interactive subview (its hitTest returns nil).
        let button = NSButton(title: "", target: self, action: #selector(slotTapped))
        button.isBordered = false
        button.bezelStyle = .inline
        button.imagePosition = .imageOnly
        button.wantsLayer = true
        button.layer?.backgroundColor = CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 1)

        let mini = TouchBarSpectrumView(preferredSize: NSSize(width: 64, height: 30))
        mini.translatesAutoresizingMaskIntoConstraints = false
        button.addSubview(mini)
        NSLayoutConstraint.activate([
            mini.leadingAnchor.constraint(equalTo: button.leadingAnchor),
            mini.trailingAnchor.constraint(equalTo: button.trailingAnchor),
            mini.topAnchor.constraint(equalTo: button.topAnchor),
            mini.bottomAnchor.constraint(equalTo: button.bottomAnchor),
        ])
        slot.view = button
        engine.register(mini)

        slotItem = slot
        slotView = mini

        NSTouchBarItem.addSystemTrayItem(slot)
        DFRBridge.setControlStripPresence(Self.slotItemID, present: true)
    }

    func teardown() {
        dismiss()
        if let v = slotView { engine.unregister(v) }
        if let slot = slotItem {
            DFRBridge.setControlStripPresence(Self.slotItemID, present: false)
            NSTouchBarItem.removeSystemTrayItem(slot)
        }
        slotItem = nil
        slotView = nil
    }

    // MARK: Expand / collapse

    @objc func toggleExpanded() {
        isExpanded ? dismiss() : expand()
    }

    @objc private func slotTapped() { toggleExpanded() }
    @objc private func wideTapped() { dismiss() }

    private func expand() {
        guard isSupported else { return }
        if wideBar != nil { dismiss() }     // clear any stale / OS-dismissed presentation
        let bar = NSTouchBar()
        bar.delegate = self
        bar.defaultItemIdentifiers = [Self.wideItemID]
        wideBar = bar
        // placement 1 == full-width / on-top: collapses the control strip AND the
        // NowPlaying media cluster, so the scanner isn't preempted while music plays.
        // (placement 0 coexists with the control strip and loses the app region.)
        DFRBridge.systemModalShowsCloseBoxWhenFrontMost(false)   // set before presenting
        NSTouchBar.presentSystemModalTouchBar(bar, placement: 1, systemTrayItemIdentifier: Self.slotItemID)
        isExpanded = true
    }

    private func dismiss() {
        if let bar = wideBar {
            // minimize (not dismiss) cleanly returns to the control-strip slot.
            NSTouchBar.minimizeSystemModalTouchBar(bar)
        }
        if let wv = wideView { engine.unregister(wv) }
        wideBar = nil
        wideItem = nil
        wideView = nil
        isExpanded = false
        // Some control-strip builds blank the slot after a modal dismiss; re-assert.
        if isSupported { DFRBridge.setControlStripPresence(Self.slotItemID, present: true) }
    }

    // MARK: NSTouchBarDelegate

    func touchBar(_ touchBar: NSTouchBar,
                  makeItemForIdentifier identifier: NSTouchBarItem.Identifier) -> NSTouchBarItem? {
        guard identifier == Self.wideItemID else { return nil }
        // Drop any previous wide view before creating a replacement (the system can
        // re-request the item) so the engine never animates an orphaned view.
        if let old = wideView { engine.unregister(old) }

        let item = NSCustomTouchBarItem(identifier: identifier)
        // Wrap the scanner in an NSButton so a tap reliably collapses it.
        let wideButton = NSButton(title: "", target: self, action: #selector(wideTapped))
        wideButton.isBordered = false
        wideButton.bezelStyle = .inline
        wideButton.imagePosition = .imageOnly

        // ~1004pt fills the full-width (placement 1) Touch Bar app region; the KITT
        // render scales to whatever width it's given.
        let wide = TouchBarSpectrumView(preferredSize: NSSize(width: 1004, height: 30))
        wide.translatesAutoresizingMaskIntoConstraints = false
        wideButton.addSubview(wide)
        NSLayoutConstraint.activate([
            wide.leadingAnchor.constraint(equalTo: wideButton.leadingAnchor),
            wide.trailingAnchor.constraint(equalTo: wideButton.trailingAnchor),
            wide.topAnchor.constraint(equalTo: wideButton.topAnchor),
            wide.bottomAnchor.constraint(equalTo: wideButton.bottomAnchor),
            wide.widthAnchor.constraint(equalToConstant: 1004),
            wide.heightAnchor.constraint(equalToConstant: 30),
        ])
        item.view = wideButton
        engine.register(wide)
        wideItem = item
        wideView = wide
        return item
    }
}

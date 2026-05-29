import AppKit

/// Background agent that wires the whole pipeline together:
///
///   AudioSource → RingBuffer → SpectrumAnalyzer → VisualizerEngine → Touch Bar
///
/// It owns a status-bar menu (the app has no Dock icon / windows) for switching the
/// capture source, restarting capture, and quitting. The visualizer keeps animating
/// (idle KITT sweep) even when no audio is captured.
final class AppDelegate: NSObject, NSApplicationDelegate {

    enum SourceKind { case processTap, blackHole }

    // Pipeline
    private let ring = RingBuffer(capacity: 16_384)
    private lazy var analyzer = SpectrumAnalyzer(fftSize: 2048, bandCount: 64)
    private lazy var engine = VisualizerEngine(analyzer: analyzer, ring: ring)
    private lazy var touchBar = TouchBarController(engine: engine)

    private var source: AudioSource?
    private var currentKind: SourceKind = .processTap

    // UI
    private var statusItem: NSStatusItem!

    // MARK: Launch

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        setupStatusItem()
        touchBar.install()
        engine.start()                 // idle animation runs regardless of capture
        startCapture(kind: .processTap)
    }

    func applicationWillTerminate(_ notification: Notification) {
        source?.stop()
        engine.stop()
        touchBar.teardown()
    }

    // MARK: Capture management

    private func startCapture(kind: SourceKind) {
        // Detach the old source's callbacks BEFORE stopping it, so a late in-flight
        // IO block from the old pipeline can't write into the shared ring while the
        // new pipeline is also writing (two-producer race on the SPSC buffer).
        source?.onSamples = nil
        source?.stop()
        let newSource: AudioSource = (kind == .processTap) ? AudioTapManager() : BlackHoleSource()
        newSource.onSamples = { [ring] ptr, count in
            ring.write(ptr, count: count)
        }
        newSource.onStalled = { [weak self, weak newSource] in
            // Only act if this exact source is still the active one.
            guard let self, let newSource, self.source === newSource else { return }
            self.handleStall()
        }
        do {
            try newSource.start()
            analyzer.sampleRate = newSource.sampleRate
            source = newSource
            currentKind = kind
            NSLog("[TouchBarSpectrum] Capturing via \(newSource.displayName) @ \(Int(newSource.sampleRate)) Hz")
        } catch {
            NSLog("[TouchBarSpectrum] \(kind) start failed: \(error)")
            if kind == .processTap {
                NSLog("[TouchBarSpectrum] Falling back to BlackHole.")
                startCapture(kind: .blackHole)
            } else {
                source = nil
                presentCaptureProblem(error)
            }
        }
        refreshMenu()
    }

    private func handleStall() {
        guard currentKind == .processTap else { return }
        NSLog("[TouchBarSpectrum] Process tap delivered only silence — switching to BlackHole.")
        startCapture(kind: .blackHole)
    }

    private func presentCaptureProblem(_ error: Error) {
        NSLog("[TouchBarSpectrum] No audio source available: \(error)")
        // Non-fatal: the idle visualizer keeps running. The menu shows the state.
    }

    // MARK: Status bar

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "waveform", accessibilityDescription: "TouchBar Spectrum")
            button.image?.isTemplate = true
        }
        statusItem.menu = buildMenu()
    }

    private func buildMenu() -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        menu.delegate = nil

        let status = NSMenuItem(title: "TouchBar Spectrum", action: nil, keyEquivalent: "")
        status.isEnabled = false
        menu.addItem(status)
        menu.addItem(.separator())

        let toggle = NSMenuItem(title: "Pause", action: #selector(toggleCapture), keyEquivalent: "")
        toggle.target = self
        toggle.tag = MenuTag.toggle.rawValue
        menu.addItem(toggle)

        let restart = NSMenuItem(title: "Restart Capture", action: #selector(restartCapture), keyEquivalent: "")
        restart.target = self
        menu.addItem(restart)

        menu.addItem(.separator())

        let sourceHeader = NSMenuItem(title: "Audio Source", action: nil, keyEquivalent: "")
        sourceHeader.isEnabled = false
        menu.addItem(sourceHeader)

        let tapItem = NSMenuItem(title: "Core Audio Tap (system mix)", action: #selector(selectProcessTap), keyEquivalent: "")
        tapItem.target = self
        tapItem.tag = MenuTag.sourceTap.rawValue
        menu.addItem(tapItem)

        let bhItem = NSMenuItem(title: "BlackHole (fallback)", action: #selector(selectBlackHole), keyEquivalent: "")
        bhItem.target = self
        bhItem.tag = MenuTag.sourceBlackHole.rawValue
        menu.addItem(bhItem)

        menu.addItem(.separator())

        let privacy = NSMenuItem(title: "Open Privacy Settings…", action: #selector(openPrivacySettings), keyEquivalent: "")
        privacy.target = self
        menu.addItem(privacy)

        let quit = NSMenuItem(title: "Quit", action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)

        return menu
    }

    private enum MenuTag: Int { case toggle = 1, sourceTap = 2, sourceBlackHole = 3 }

    private func refreshMenu() {
        guard let menu = statusItem?.menu else { return }
        let running = source?.isRunning ?? false
        menu.item(withTag: MenuTag.toggle.rawValue)?.title = running ? "Pause" : "Resume"
        menu.item(withTag: MenuTag.sourceTap.rawValue)?.state = (currentKind == .processTap) ? .on : .off
        menu.item(withTag: MenuTag.sourceBlackHole.rawValue)?.state = (currentKind == .blackHole) ? .on : .off
    }

    // MARK: Menu actions

    @objc private func toggleCapture() {
        if source?.isRunning == true {
            source?.stop()
        } else {
            startCapture(kind: currentKind)
        }
        refreshMenu()
    }

    @objc private func restartCapture() { startCapture(kind: currentKind) }
    @objc private func selectProcessTap() { startCapture(kind: .processTap) }
    @objc private func selectBlackHole() { startCapture(kind: .blackHole) }

    @objc private func openPrivacySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone") {
            NSWorkspace.shared.open(url)
        }
    }

    @objc private func quit() { NSApp.terminate(nil) }
}

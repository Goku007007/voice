import AppKit
import Foundation

@MainActor
final class FloatingStatusPanelController: NSObject {
    private enum VisualState {
        case listening
        case processing
        case success
        case error
        case idle
    }

    private let pillWidth: CGFloat = 120
    private let pillHeight: CGFloat = 40
    private let loaderDiameter: CGFloat = 40

    private let panel: NSPanel
    private let waveformStack = NSStackView()
    private let loaderView = CircularDotsLoaderView()
    private var barHeightConstraints: [NSLayoutConstraint] = []
    private var barViews: [NSView] = []
    private var animationTick: Int = 0
    private var visualState: VisualState = .idle
    private var latestInputLevel: CGFloat = 0
    private var smoothedInputLevel: CGFloat = 0

    private var pendingHideTask: DispatchWorkItem?
    private var waveformTimer: DispatchSourceTimer?

    override init() {
        panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: pillWidth, height: pillHeight),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        super.init()

        panel.isReleasedWhenClosed = false
        panel.level = .statusBar
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.collectionBehavior = [.canJoinAllSpaces, .transient, .ignoresCycle]
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        panel.animationBehavior = .utilityWindow

        setupContentView()
        applyWaveHeights([0.18, 0.26, 0.35, 0.26, 0.18, 0.22, 0.28, 0.22, 0.18])
        wireAudioLevelUpdates()
    }

    deinit {
        waveformTimer?.cancel()
        waveformTimer = nil
        NotificationCenter.default.removeObserver(self)
    }

    // MARK: - Public API

    func show(status: String, transcript: String?) {
        update(status: status)
        positionOnMainScreen()
        pendingHideTask?.cancel()

        if panel.isVisible {
            panel.orderFrontRegardless()
            return
        }

        panel.alphaValue = 0
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.12
            panel.animator().alphaValue = 1
        }
    }

    func showTemporary(status: String, transcript: String?, hideAfter: TimeInterval) {
        show(status: status, transcript: transcript)

        let hideTask = DispatchWorkItem { [weak self] in
            self?.hide()
        }
        pendingHideTask = hideTask
        DispatchQueue.main.asyncAfter(deadline: .now() + hideAfter, execute: hideTask)
    }

    func hide() {
        pendingHideTask?.cancel()
        pendingHideTask = nil
        stopWaveformAnimation()
        latestInputLevel = 0
        smoothedInputLevel = 0

        guard panel.isVisible else {
            return
        }

        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.15
            panel.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            Task { @MainActor in
                self?.panel.orderOut(nil)
            }
        })
    }

    // MARK: - Content Setup

    private func setupContentView() {
        let effectView = NSVisualEffectView(frame: panel.contentView?.bounds ?? .zero)
        effectView.autoresizingMask = [.width, .height]
        effectView.blendingMode = .behindWindow
        effectView.material = .hudWindow
        effectView.state = .active
        effectView.wantsLayer = true
        effectView.layer?.cornerRadius = pillHeight / 2
        effectView.layer?.masksToBounds = true
        effectView.layer?.borderWidth = 1
        effectView.layer?.borderColor = NSColor.white.withAlphaComponent(0.10).cgColor

        waveformStack.orientation = .horizontal
        waveformStack.alignment = .centerY
        waveformStack.distribution = .fill
        waveformStack.spacing = 3
        waveformStack.translatesAutoresizingMaskIntoConstraints = false

        for _ in 0..<9 {
            let bar = NSView()
            bar.wantsLayer = true
            bar.layer?.cornerRadius = 1.5
            bar.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.9).cgColor
            bar.translatesAutoresizingMaskIntoConstraints = false

            let width = bar.widthAnchor.constraint(equalToConstant: 3)
            let height = bar.heightAnchor.constraint(equalToConstant: 8)
            NSLayoutConstraint.activate([width, height])
            barHeightConstraints.append(height)
            barViews.append(bar)
            waveformStack.addArrangedSubview(bar)
        }

        effectView.addSubview(waveformStack)
        loaderView.translatesAutoresizingMaskIntoConstraints = false
        loaderView.alphaValue = 0
        loaderView.isHidden = true
        effectView.addSubview(loaderView)
        NSLayoutConstraint.activate([
            waveformStack.centerXAnchor.constraint(equalTo: effectView.centerXAnchor),
            waveformStack.centerYAnchor.constraint(equalTo: effectView.centerYAnchor),
            loaderView.centerXAnchor.constraint(equalTo: effectView.centerXAnchor),
            loaderView.centerYAnchor.constraint(equalTo: effectView.centerYAnchor),
            loaderView.widthAnchor.constraint(equalToConstant: 22),
            loaderView.heightAnchor.constraint(equalToConstant: 22),
        ])

        panel.contentView = effectView
    }

    // MARK: - State Updates

    private func update(status: String) {
        let previousState = visualState
        let lowered = status.lowercased()

        if lowered.contains("listening") {
            visualState = .listening
        } else if lowered.contains("processing") || lowered.contains("cleaning") || lowered.contains("inserted") || lowered.contains("copied") {
            visualState = .processing
        } else if lowered.contains("error") || lowered.contains("failed") {
            visualState = .processing
        } else {
            visualState = .idle
        }

        if previousState != visualState {
            applyStateTransition(from: previousState, to: visualState)
        }

        switch visualState {
        case .listening, .processing:
            startWaveformAnimation()
        case .success, .error, .idle:
            stopWaveformAnimation()
            applyWaveHeights([0.18, 0.24, 0.30, 0.24, 0.18, 0.24, 0.30, 0.24, 0.18])
        }
    }

    // MARK: - Audio Level

    private func wireAudioLevelUpdates() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleAudioLevelNotification(_:)),
            name: .voiceAudioLevelDidUpdate,
            object: nil
        )
    }

    @objc
    private func handleAudioLevelNotification(_ notification: Notification) {
        guard let level = notification.userInfo?[VoiceAudioLevelUserInfoKey.level] as? CGFloat else {
            return
        }
        latestInputLevel = max(0, min(1, level))
    }

    // MARK: - Waveform Animation

    private func startWaveformAnimation() {
        if waveformTimer != nil {
            return
        }

        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now(), repeating: .milliseconds(60))
        timer.setEventHandler { [weak self] in
            self?.tickWaveform()
        }
        waveformTimer = timer
        timer.resume()
    }

    private func stopWaveformAnimation() {
        waveformTimer?.cancel()
        waveformTimer = nil
        animationTick = 0
        loaderView.phase = 0
    }

    private func tickWaveform() {
        animationTick += 1

        switch visualState {
        case .listening:
            smoothedInputLevel = (smoothedInputLevel * 0.68) + (latestInputLevel * 0.32)
            let floor: CGFloat = 0.08
            let weights: [CGFloat] = [0.40, 0.55, 0.72, 0.92, 1.0, 0.92, 0.72, 0.55, 0.40]
            var heights: [CGFloat] = []
            for weight in weights {
                let value = floor + (smoothedInputLevel * 0.9 * weight)
                heights.append(max(0.1, min(0.98, value)))
            }
            applyWaveHeights(heights)
        case .processing:
            loaderView.phase = animationTick
        default:
            break
        }
    }

    private func applyWaveHeights(_ ratios: [CGFloat]) {
        guard ratios.count == barHeightConstraints.count else {
            return
        }

        let maxHeight: CGFloat = 24
        let minHeight: CGFloat = 4

        for (index, ratio) in ratios.enumerated() {
            barHeightConstraints[index].constant = minHeight + ((maxHeight - minHeight) * ratio)
        }
        panel.contentView?.layoutSubtreeIfNeeded()
    }

    // MARK: - Positioning

    private func positionOnMainScreen() {
        guard let screen = NSScreen.main else {
            return
        }

        let visibleFrame = screen.visibleFrame
        let x = visibleFrame.midX - (panel.frame.width / 2)
        let y = visibleFrame.minY + 60
        panel.setFrameOrigin(NSPoint(x: x, y: y))
    }

    private func applyStateTransition(from: VisualState, to: VisualState) {
        switch to {
        case .listening:
            transitionToWaveform(animated: panel.isVisible)
            animatePanelWidth(to: pillWidth, duration: 0.18)
        case .processing:
            transitionToLoader(animated: panel.isVisible)
            animatePanelWidth(to: loaderDiameter, duration: 0.20)
        case .success, .error, .idle:
            transitionToWaveform(animated: panel.isVisible)
            animatePanelWidth(to: pillWidth, duration: 0.14)
        }
    }

    private func transitionToLoader(animated: Bool) {
        loaderView.isHidden = false

        let updates = {
            self.waveformStack.alphaValue = 0
            self.loaderView.alphaValue = 1
        }

        if animated {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.14
                updates()
            }
        } else {
            updates()
        }
    }

    private func transitionToWaveform(animated: Bool) {
        let updates = {
            self.waveformStack.alphaValue = 1
            self.loaderView.alphaValue = 0
        }

        if animated {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.12
                updates()
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.13) { [weak self] in
                guard let self else {
                    return
                }
                if self.loaderView.alphaValue == 0 {
                    self.loaderView.isHidden = true
                }
            }
        } else {
            updates()
            loaderView.isHidden = true
        }
    }

    private func animatePanelWidth(to targetWidth: CGFloat, duration: TimeInterval) {
        var frame = panel.frame
        guard abs(frame.width - targetWidth) > 0.5 else {
            return
        }

        if !panel.isVisible {
            frame.size.width = targetWidth
            frame.size.height = pillHeight
            panel.setFrame(frame, display: false)
            return
        }

        let centerX = frame.midX
        frame.size.width = targetWidth
        frame.size.height = pillHeight
        frame.origin.x = centerX - (targetWidth / 2)

        NSAnimationContext.runAnimationGroup { context in
            context.duration = duration
            panel.animator().setFrame(frame, display: true)
        }
    }
}

private final class CircularDotsLoaderView: NSView {
    var phase: Int = 0 {
        didSet {
            needsDisplay = true
        }
    }

    override var isOpaque: Bool {
        false
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)

        let dotCount = 8
        let center = CGPoint(x: bounds.midX, y: bounds.midY)
        let radius = min(bounds.width, bounds.height) * 0.34
        let dotSize = max(3.2, min(bounds.width, bounds.height) * 0.18)

        let head = phase % dotCount
        for index in 0..<dotCount {
            let angle = ((CGFloat(index) / CGFloat(dotCount)) * 2 * .pi) - (.pi / 2)
            let x = center.x + (cos(angle) * radius) - (dotSize / 2)
            let y = center.y + (sin(angle) * radius) - (dotSize / 2)
            let distance = (index - head + dotCount) % dotCount
            let alpha = max(0.22, 1.0 - (CGFloat(distance) * 0.12))

            NSColor.white.withAlphaComponent(alpha).setFill()
            NSBezierPath(ovalIn: NSRect(x: x, y: y, width: dotSize, height: dotSize)).fill()
        }
    }
}

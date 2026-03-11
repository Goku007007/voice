import AppKit
import Foundation

@MainActor
final class SettingsWindowController: NSWindowController {
    private let settingsStore: SettingsStore

    private let transcriptionProfilePopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let recordingModePopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let removeFillerButton = NSButton(checkboxWithTitle: "Remove filler words (um/uh)", target: nil, action: nil)
    private let autoPunctuationButton = NSButton(checkboxWithTitle: "Add ending punctuation", target: nil, action: nil)
    private let capitalizeButton = NSButton(checkboxWithTitle: "Capitalize first letter", target: nil, action: nil)
    private let insertionModePopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let transcriptionDetailLabel = NSTextField(labelWithString: "")

    // LLM cleanup controls
    private let cleanupModePopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let cleanupDetailLabel = NSTextField(labelWithString: "")

    init(settingsStore: SettingsStore) {
        self.settingsStore = settingsStore

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 500, height: 480),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "voice Settings"
        window.center()
        window.isReleasedWhenClosed = false

        super.init(window: window)
        setupUI()
        refreshFromStore()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    func present() {
        refreshFromStore()
        showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    private func setupUI() {
        guard let contentView = window?.contentView else {
            return
        }

        let root = NSStackView()
        root.orientation = .vertical
        root.spacing = 14
        root.translatesAutoresizingMaskIntoConstraints = false
        root.edgeInsets = NSEdgeInsets(top: 20, left: 24, bottom: 20, right: 24)

        // --- Dictation section ---
        let headline = NSTextField(labelWithString: "Dictation behavior")
        headline.font = .systemFont(ofSize: 15, weight: .semibold)

        [removeFillerButton, autoPunctuationButton, capitalizeButton].forEach {
            $0.setButtonType(.switch)
            $0.font = .systemFont(ofSize: 13)
            $0.target = self
            $0.action = #selector(checkboxChanged(_:))
        }

        let transcriptionLabel = NSTextField(labelWithString: "Transcription profile")
        transcriptionLabel.font = .systemFont(ofSize: 13, weight: .medium)

        transcriptionProfilePopup.font = .systemFont(ofSize: 13)
        transcriptionProfilePopup.target = self
        transcriptionProfilePopup.action = #selector(transcriptionProfileChanged(_:))
        transcriptionProfilePopup.addItems(withTitles: TranscriptionProfile.allCases.map(\.title))

        let transcriptionRow = NSStackView(views: [transcriptionLabel, transcriptionProfilePopup])
        transcriptionRow.orientation = .horizontal
        transcriptionRow.alignment = .centerY
        transcriptionRow.spacing = 12
        transcriptionProfilePopup.setContentHuggingPriority(.defaultLow, for: .horizontal)

        transcriptionDetailLabel.font = .systemFont(ofSize: 12)
        transcriptionDetailLabel.textColor = .secondaryLabelColor
        transcriptionDetailLabel.maximumNumberOfLines = 0
        transcriptionDetailLabel.lineBreakMode = .byWordWrapping

        let recordingLabel = NSTextField(labelWithString: "Hotkey behavior")
        recordingLabel.font = .systemFont(ofSize: 13, weight: .medium)

        recordingModePopup.font = .systemFont(ofSize: 13)
        recordingModePopup.target = self
        recordingModePopup.action = #selector(recordingModeChanged(_:))
        recordingModePopup.addItems(withTitles: RecordingMode.allCases.map(\.title))

        let recordingRow = NSStackView(views: [recordingLabel, recordingModePopup])
        recordingRow.orientation = .horizontal
        recordingRow.alignment = .centerY
        recordingRow.spacing = 12
        recordingModePopup.setContentHuggingPriority(.defaultLow, for: .horizontal)

        let insertionLabel = NSTextField(labelWithString: "Insertion mode")
        insertionLabel.font = .systemFont(ofSize: 13, weight: .medium)

        insertionModePopup.font = .systemFont(ofSize: 13)
        insertionModePopup.target = self
        insertionModePopup.action = #selector(insertionModeChanged(_:))
        insertionModePopup.addItems(withTitles: InsertionMode.allCases.map(\.title))

        let insertionRow = NSStackView(views: [insertionLabel, insertionModePopup])
        insertionRow.orientation = .horizontal
        insertionRow.alignment = .centerY
        insertionRow.spacing = 12
        insertionModePopup.setContentHuggingPriority(.defaultLow, for: .horizontal)

        let footnote = NSTextField(labelWithString: "Direct Paste inserts into the active app. Clipboard Only copies text so you can paste manually.")
        footnote.font = .systemFont(ofSize: 12)
        footnote.textColor = .secondaryLabelColor
        footnote.maximumNumberOfLines = 0
        footnote.lineBreakMode = .byWordWrapping

        // --- LLM Cleanup section ---
        let cleanupHeadline = NSTextField(labelWithString: "Text cleanup")
        cleanupHeadline.font = .systemFont(ofSize: 15, weight: .semibold)

        let cleanupLabel = NSTextField(labelWithString: "Cleanup mode")
        cleanupLabel.font = .systemFont(ofSize: 13, weight: .medium)

        cleanupModePopup.font = .systemFont(ofSize: 13)
        cleanupModePopup.target = self
        cleanupModePopup.action = #selector(cleanupModeChanged(_:))
        cleanupModePopup.addItems(withTitles: CleanupMode.allCases.map(\.title))

        let cleanupRow = NSStackView(views: [cleanupLabel, cleanupModePopup])
        cleanupRow.orientation = .horizontal
        cleanupRow.alignment = .centerY
        cleanupRow.spacing = 12
        cleanupModePopup.setContentHuggingPriority(.defaultLow, for: .horizontal)

        cleanupDetailLabel.font = .systemFont(ofSize: 12)
        cleanupDetailLabel.textColor = .secondaryLabelColor
        cleanupDetailLabel.maximumNumberOfLines = 0
        cleanupDetailLabel.lineBreakMode = .byWordWrapping

        // Assemble
        root.addArrangedSubview(headline)
        root.addArrangedSubview(transcriptionRow)
        root.addArrangedSubview(transcriptionDetailLabel)
        root.addArrangedSubview(recordingRow)
        root.addArrangedSubview(removeFillerButton)
        root.addArrangedSubview(autoPunctuationButton)
        root.addArrangedSubview(capitalizeButton)
        root.addArrangedSubview(insertionRow)
        root.addArrangedSubview(footnote)

        let separator = NSBox()
        separator.boxType = .separator
        root.addArrangedSubview(separator)

        root.addArrangedSubview(cleanupHeadline)
        root.addArrangedSubview(cleanupRow)
        root.addArrangedSubview(cleanupDetailLabel)

        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = false
        scrollView.documentView = root
        scrollView.translatesAutoresizingMaskIntoConstraints = false

        contentView.addSubview(scrollView)
        NSLayoutConstraint.activate([
            scrollView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: contentView.topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
            root.widthAnchor.constraint(equalTo: scrollView.widthAnchor)
        ])
    }

    private func makeFieldRow(label: String, field: NSTextField) -> NSStackView {
        let labelView = NSTextField(labelWithString: label)
        labelView.font = .systemFont(ofSize: 12, weight: .medium)
        labelView.setContentHuggingPriority(.required, for: .horizontal)

        let row = NSStackView(views: [labelView, field])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 8
        field.setContentHuggingPriority(.defaultLow, for: .horizontal)
        return row
    }

    private func refreshFromStore() {
        let settings = settingsStore.current
        removeFillerButton.state = settings.removeFillerWords ? .on : .off
        autoPunctuationButton.state = settings.autoPunctuation ? .on : .off
        capitalizeButton.state = settings.capitalizeFirstLetter ? .on : .off
        insertionModePopup.selectItem(at: InsertionMode.allCases.firstIndex(of: settings.insertionMode) ?? 0)
        recordingModePopup.selectItem(at: RecordingMode.allCases.firstIndex(of: settings.recordingMode) ?? 0)
        transcriptionProfilePopup.selectItem(at: TranscriptionProfile.allCases.firstIndex(of: settings.transcriptionProfile) ?? 0)
        transcriptionDetailLabel.stringValue = settings.transcriptionProfile.description

        cleanupModePopup.selectItem(at: CleanupMode.allCases.firstIndex(of: settings.cleanupMode) ?? 0)
        cleanupDetailLabel.stringValue = settings.cleanupMode.description
    }

    // MARK: - Actions

    @objc
    private func checkboxChanged(_ sender: NSButton) {
        settingsStore.update { settings in
            if sender === removeFillerButton {
                settings.removeFillerWords = sender.state == .on
            } else if sender === autoPunctuationButton {
                settings.autoPunctuation = sender.state == .on
            } else if sender === capitalizeButton {
                settings.capitalizeFirstLetter = sender.state == .on
            }
        }
    }

    @objc
    private func insertionModeChanged(_ sender: NSPopUpButton) {
        let index = max(0, sender.indexOfSelectedItem)
        let selectedMode = InsertionMode.allCases[index]
        settingsStore.update { settings in
            settings.insertionMode = selectedMode
        }
    }

    @objc
    private func recordingModeChanged(_ sender: NSPopUpButton) {
        let index = max(0, sender.indexOfSelectedItem)
        let selectedMode = RecordingMode.allCases[index]
        settingsStore.update { settings in
            settings.recordingMode = selectedMode
        }
    }

    @objc
    private func transcriptionProfileChanged(_ sender: NSPopUpButton) {
        let index = max(0, sender.indexOfSelectedItem)
        let selectedProfile = TranscriptionProfile.allCases[index]
        settingsStore.update { settings in
            settings.transcriptionProfile = selectedProfile
        }
        transcriptionDetailLabel.stringValue = selectedProfile.description
    }

    @objc
    private func cleanupModeChanged(_ sender: NSPopUpButton) {
        let index = max(0, sender.indexOfSelectedItem)
        let selectedMode = CleanupMode.allCases[index]
        settingsStore.update { settings in
            settings.cleanupMode = selectedMode
        }
        cleanupDetailLabel.stringValue = selectedMode.description
    }
}

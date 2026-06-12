import AppKit
import VoicelyCore

/// Accessory view for the transcribe-file open panel, styled after the native
/// "Format:" row in macOS save panels: trailing-aligned labels next to compact
/// pop-up buttons, the whole form centered horizontally.
@MainActor
final class TranscribeOptionsAccessoryView: NSView {

    private let contentPopUp = NSPopUpButton(frame: .zero, pullsDown: false)
    private let formatPopUp = NSPopUpButton(frame: .zero, pullsDown: false)
    private let diarizeCheckbox = NSButton(checkboxWithTitle: "Identify speakers", target: nil, action: nil)

    private let contentKey = "FileTranscription.Content"
    private let formatKey = "FileTranscription.Format"
    private let diarizeKey = "FileTranscription.Diarize"

    init() {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false

        contentPopUp.addItems(withTitles: ["Plain", "With Timestamps"])
        formatPopUp.addItems(withTitles: ["Markdown (.md)", "Plain Text (.txt)"])

        let smallFont = NSFont.systemFont(ofSize: NSFont.systemFontSize(for: .small))
        for popUp in [contentPopUp, formatPopUp] {
            popUp.controlSize = .small
            popUp.font = smallFont
        }

        diarizeCheckbox.controlSize = .small
        diarizeCheckbox.font = smallFont

        func makeLabel(_ text: String) -> NSTextField {
            let label = NSTextField(labelWithString: text)
            label.font = smallFont
            label.alignment = .right
            return label
        }

        // Empty leading cell keeps the checkbox aligned under the pop-ups in the
        // value column, matching native "checkbox-under-controls" save panels.
        let grid = NSGridView(views: [
            [makeLabel("Content:"), contentPopUp],
            [makeLabel("Format:"), formatPopUp],
            [makeLabel(""), diarizeCheckbox],
        ])
        grid.translatesAutoresizingMaskIntoConstraints = false
        grid.rowSpacing = 8
        grid.columnSpacing = 8
        grid.rowAlignment = .firstBaseline
        grid.column(at: 0).xPlacement = .trailing
        grid.column(at: 1).xPlacement = .leading

        addSubview(grid)
        NSLayoutConstraint.activate([
            grid.centerXAnchor.constraint(equalTo: centerXAnchor),
            grid.topAnchor.constraint(equalTo: topAnchor, constant: 10),
            grid.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -10),
            grid.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: 20),
            grid.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -20),
        ])

        restoreFromDefaults()
        contentPopUp.target = self
        contentPopUp.action = #selector(contentChanged)
        formatPopUp.target = self
        formatPopUp.action = #selector(formatChanged)
        diarizeCheckbox.target = self
        diarizeCheckbox.action = #selector(diarizeChanged)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    var currentOptions: FileTranscriptionOptions {
        FileTranscriptionOptions(
            content: contentPopUp.indexOfSelectedItem == 0 ? .plain : .timestamps,
            format: formatPopUp.indexOfSelectedItem == 0 ? .markdown : .plainText,
            diarize: diarizeCheckbox.state == .on
        )
    }

    func setContent(_ c: FileTranscriptionOptions.Content) {
        contentPopUp.selectItem(at: (c == .plain) ? 0 : 1)
        persist()
    }

    func setFormat(_ f: FileTranscriptionOptions.Format) {
        formatPopUp.selectItem(at: (f == .markdown) ? 0 : 1)
        persist()
    }

    func setDiarize(_ on: Bool) {
        diarizeCheckbox.state = on ? .on : .off
        persist()
    }

    @objc private func contentChanged() { persist() }
    @objc private func formatChanged() { persist() }
    @objc private func diarizeChanged() { persist() }

    private func restoreFromDefaults() {
        let defaults = UserDefaults.standard
        let contentRaw = defaults.string(forKey: contentKey) ?? "plain"
        let formatRaw = defaults.string(forKey: formatKey) ?? "markdown"
        contentPopUp.selectItem(at: (contentRaw == "timestamps") ? 1 : 0)
        formatPopUp.selectItem(at: (formatRaw == "plainText") ? 1 : 0)
        diarizeCheckbox.state = defaults.bool(forKey: diarizeKey) ? .on : .off
    }

    private func persist() {
        let defaults = UserDefaults.standard
        defaults.set(currentOptions.content.rawValue, forKey: contentKey)
        defaults.set(currentOptions.format.rawValue, forKey: formatKey)
        defaults.set(currentOptions.diarize, forKey: diarizeKey)
    }
}

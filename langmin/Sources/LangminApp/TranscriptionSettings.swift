import Cocoa

// Edit a Settings draft without loading keys, starting recognition, or saving on selection.
final class TranscriptionSettingsControls: NSObject {
    let providerBox = FocusablePopUpButton(frame: .zero, pullsDown: false)
    let languageBox = FocusablePopUpButton(frame: .zero, pullsDown: false)
    let providerNote = NSTextField(wrappingLabelWithString: "")
    let importNote = NSTextField(wrappingLabelWithString: "Drop or paste an M4A, MP3, or WAV file into the input. Review the transcript, then choose a writing mode.")
    private var localeTask: Task<Void, Never>?
    private var locales: [Locale] = []
    private var savedLanguage = "auto"

    var provider: AudioTranscriptionProvider {
        AudioTranscriptionProvider.resolved(providerBox.selectedItem?.representedObject as? String ?? "apple")
    }

    // OpenAI detects the recording's language; preserve the Apple language when switching providers.
    var language: String { savedLanguage }
    var rows: [(String, NSView)] {
        [("Speech Provider", providerBox), ("Audio Language", languageBox), ("", providerNote), ("", importNote)]
    }
    var focusViews: [NSView] { languageBox.isEnabled ? [providerBox, languageBox] : [providerBox] }

    // init(): Build native controls at the same width and type size as the
    // other Settings pages.
    override init() {
        super.init()
        for box in [providerBox, languageBox] {
            box.bezelStyle = .rounded
            box.font = .systemFont(ofSize: 13)
            box.refusesFirstResponder = false
            box.menu?.autoenablesItems = false
            box.target = self
        }
        providerBox.action = #selector(providerChanged(_:))
        languageBox.action = #selector(languageChanged(_:))
        for provider in AudioTranscriptionProvider.allCases {
            // A standalone core build offers only the implementation it actually contains.
            providerBox.addItem(withTitle: provider.title)
            providerBox.lastItem?.representedObject = provider.rawValue
        }
        for note in [providerNote, importNote] {
            note.font = .systemFont(ofSize: 11)
            note.textColor = .secondaryLabelColor
            note.maximumNumberOfLines = 0
            note.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        }
        for view in [providerBox, languageBox, providerNote, importNote] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            view.widthAnchor.constraint(equalToConstant: 330).isActive = true
        }
        populate(provider: "apple", language: "auto")
    }

    // populate(provider, language): Discard unsaved state when opening Settings
    // or choosing Reset Defaults.
    func populate(provider: String, language: String) {
        let selection = AudioTranscriptionProvider.resolved(provider)
        providerBox.selectItem(at: providerBox.itemArray.firstIndex { ($0.representedObject as? String) == selection.rawValue } ?? 0)
        savedLanguage = language.isEmpty ? "auto" : language
        refresh()
        localeTask?.cancel()
        localeTask = Task { @MainActor [weak self] in
            let available = await availableAppleTranscriptionLocales()
            // Ignore a locale response after cancellation or destruction of the settings page.
            guard !Task.isCancelled, let self else { return }
            self.locales = available.sorted { self.languageName($0.identifier).localizedStandardCompare(self.languageName($1.identifier)) == .orderedAscending }
            self.refresh()
        }
    }

    // deinit(): Cancel a pending capability query when its controls go away.
    deinit { localeTask?.cancel() }

    // providerChanged(sender): Refresh the explanation and language choices
    // without purchasing or requesting a key.
    @objc private func providerChanged(_ sender: Any?) { refresh() }

    // languageChanged(sender): Remember only an explicit audio-language choice,
    // independently of the app's UI language.
    @objc private func languageChanged(_ sender: Any?) {
        savedLanguage = languageBox.selectedItem?.representedObject as? String ?? "auto"
    }

    // languageName(identifier): Use macOS locale names so regional language
    // variants remain distinguishable.
    private func languageName(_ identifier: String) -> String {
        Locale.current.localizedString(forIdentifier: identifier) ?? identifier
    }

    // refresh(): Show provider limits next to the choice, including unsupported
    // saved Apple languages.
    private func refresh() {
        languageBox.removeAllItems()
        languageBox.isEnabled = provider == .apple
        languageBox.addItem(withTitle: provider == .apple ? "Mac's language" : "Detect automatically")
        languageBox.lastItem?.representedObject = "auto"
        // Offer explicit supported locales for on-device transcription.
        if provider == .apple {
            for locale in locales {
                languageBox.addItem(withTitle: languageName(locale.identifier))
                languageBox.lastItem?.representedObject = locale.identifier
            }
            // Keep an unavailable saved choice visible instead of silently switching languages.
            if savedLanguage != "auto", !locales.contains(where: { $0.identifier == savedLanguage }) {
                languageBox.addItem(withTitle: languageName(savedLanguage) + " · Unavailable")
                languageBox.lastItem?.representedObject = savedLanguage
            }
            languageBox.selectItem(at: languageBox.itemArray.firstIndex { ($0.representedObject as? String) == savedLanguage } ?? 0)
            providerNote.stringValue = "Free · Transcribes on this Mac. Requires macOS 26 or later and a supported language. Langmin asks before downloading a missing speech model."
        } else {
            // The speech endpoint is fixed and does not inherit a text-model endpoint override.
            providerNote.stringValue = "Pro · Uses GPT-Transcribe and your OpenAI key from Settings → Models. Langmin asks before uploading audio. OpenAI bills transcription separately. File limit: 25 MB."
        }
    }
}

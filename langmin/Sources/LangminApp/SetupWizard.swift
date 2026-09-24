// Set up providers, languages and pronunciation on first launch.
// Use the same preferences as Settings and load existing choices when reopened.

import Cocoa
import ServiceManagement

// Guide first-run choices while keeping in-progress selections across wizard steps.
final class SetupWizardController: NSObject, NSWindowDelegate {
    static let completedKey = "didCompleteSetupWizard"

    // Describe a setup provider's model, availability, and optional credential requirement.
    private struct WizardProvider {
        let id: String
        let title: String
        let account: String?
        let modelID: String
        let detail: String
    }

    private var window: NSWindow?
    private var stepIndex = 0
    private let stepCount = 6

    private var contentContainer: NSView!
    private var progressLabel: NSTextField!
    private var backButton: NSButton!
    private var continueButton: NSButton!
    private var laterButton: NSButton!

    // One row per provider: a checkbox plus (for cloud providers) an inline
    // key field that enables with the checkbox.
    private var providerChecks: [String: NSButton] = [:]
    private var providerKeyFields: [String: NSTextField] = [:]
    private var translationTargetsControl: MultiSelectPreferenceControl!
    private var extraLanguagesControl: MultiSelectPreferenceControl!
    private var pronunciationVoicePopup: NSPopUpButton!
    private var loginItemCheckbox: NSButton!

    private var providers: [WizardProvider] = []
    // Cache each step so navigation preserves entered values.
    private var stepViews: [Int: NSView] = [:]

    // MARK: - Presentation

    var isCompleted: Bool {
        preferencesStore.bool(forKey: Self.completedKey)
    }

    // present(): Start at the welcome step and rebuild stale drafts when
    // reopening a closed wizard.
    func present() {
        stepIndex = 0
        // Create the setup window lazily on its first presentation.
        if window == nil {
            buildWindow()
        } else if window?.isVisible == false {
            // A new setup session reflects settings changed since the previous one.
            stepViews.removeAll()
            buildProviders()
        }
        showStep()
        NSApp.activate(ignoringOtherApps: true)
        window?.center()
        window?.makeKeyAndOrderFront(nil)
    }

    // windowWillClose(notification): Resolve trial access and mark setup
    // complete when the wizard is finished or dismissed.
    func windowWillClose(_ notification: Notification) {
        ProStore.shared.beginAppTrial()
        preferencesStore.set(true, forKey: Self.completedKey)
    }

    // MARK: - Window

    // buildWindow(): Build the setup window with step content and navigation
    // controls.
    private func buildWindow() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 580, height: 480),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = localized("wizard_window", "Langmin Setup")
        window.isReleasedWhenClosed = false
        window.delegate = self
        let contentView = installNativeContent(in: window)
        window.setContentSize(nativeContentSize(NSSize(width: 580, height: 480), in: window))

        contentContainer = NSView()
        contentContainer.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(contentContainer)

        progressLabel = NSTextField(labelWithString: "")
        progressLabel.font = NSFont.systemFont(ofSize: 11)
        progressLabel.textColor = .tertiaryLabelColor
        progressLabel.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(progressLabel)

        laterButton = NSButton(
            title: localized("wizard_later", "Set Up Later"),
            target: self,
            action: #selector(setUpLater(_:))
        )
        laterButton.bezelStyle = .rounded
        laterButton.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(laterButton)

        backButton = NSButton(
            title: localized("wizard_back", "Back"),
            target: self,
            action: #selector(goBack(_:))
        )
        backButton.bezelStyle = .rounded
        backButton.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(backButton)

        continueButton = NSButton(
            title: localized("wizard_continue", "Continue"),
            target: self,
            action: #selector(goForward(_:))
        )
        continueButton.bezelStyle = .rounded
        continueButton.keyEquivalent = "\r"
        continueButton.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(continueButton)

        NSLayoutConstraint.activate([
            contentContainer.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 24),
            contentContainer.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 32),
            contentContainer.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -32),
            contentContainer.bottomAnchor.constraint(equalTo: continueButton.topAnchor, constant: -20),

            progressLabel.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 32),
            progressLabel.centerYAnchor.constraint(equalTo: continueButton.centerYAnchor),
            laterButton.leadingAnchor.constraint(equalTo: progressLabel.trailingAnchor, constant: 16),
            laterButton.centerYAnchor.constraint(equalTo: continueButton.centerYAnchor),

            continueButton.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -24),
            continueButton.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -20),
            backButton.trailingAnchor.constraint(equalTo: continueButton.leadingAnchor, constant: -10),
            backButton.centerYAnchor.constraint(equalTo: continueButton.centerYAnchor)
        ])

        buildProviders()
        self.window = window
    }

    // buildProviders(): Build the available setup providers from the current
    // edition and local model availability.
    private func buildProviders() {
        let appleAvailable = appleIntelligenceIsAvailable()
        providers = [
            WizardProvider(
                id: "apple",
                title: "Apple Intelligence",
                account: nil,
                modelID: appleIntelligenceModelID,
                detail: appleAvailable
                    ? localized(
                        "wizard_apple_available",
                        "Runs on your Mac. Free, with no account needed."
                    )
                    : localized(
                        "wizard_apple_unavailable",
                        "Not available on this Mac (requires Apple Intelligence). Choose a cloud provider below."
                    )
            ),
            WizardProvider(
                id: "openai", title: "OpenAI (GPT)",
                account: keychainOpenAIAPIKeyAccount, modelID: defaultOpenAITextModelID,
                detail: localized(
                    "wizard_provider_openai",
                    "GPT models with web research."
                )
            ),
            WizardProvider(
                id: "anthropic", title: "Anthropic (Claude)",
                account: keychainAnthropicAPIKeyAccount, modelID: defaultAnthropicTextModelID,
                detail: localized(
                    "wizard_provider_anthropic",
                    "Claude models with web research."
                )
            ),
            WizardProvider(
                id: "gemini", title: "Google (Gemini)",
                account: keychainGeminiAPIKeyAccount, modelID: defaultGeminiTextModelID,
                detail: localized(
                    "wizard_provider_gemini",
                    "Gemini models with web research."
                )
            ),
            WizardProvider(
                id: "grok", title: "xAI (Grok)",
                account: keychainGrokAPIKeyAccount, modelID: defaultGrokTextModelID,
                detail: localized(
                    "wizard_provider_grok",
                    "Grok text models and optional voices."
                )
            ),
            WizardProvider(
                id: "deepseek", title: "DeepSeek",
                account: keychainDeepSeekAPIKeyAccount, modelID: defaultDeepSeekTextModelID,
                detail: localized(
                    "wizard_provider_deepseek",
                    "DeepSeek chat and reasoning models."
                )
            )
        ]
    }

    // MARK: - Steps

    // showStep(): Show the current setup step and update its navigation
    // controls.
    private func showStep() {
        contentContainer.subviews.forEach { $0.removeFromSuperview() }
        progressLabel.stringValue = String(
            format: localized("wizard_step_n_of_m", "Step %d of %d"),
            stepIndex + 1,
            stepCount
        )
        backButton.isHidden = stepIndex == 0
        laterButton.isHidden = stepIndex != 0
        continueButton.title = stepIndex == stepCount - 1
            ? localized("wizard_finish", "Finish")
            : localized("wizard_continue", "Continue")

        let step: NSView
        // Reuse this step's controls so navigating back preserves unfinished choices.
        if let cached = stepViews[stepIndex] {
            step = cached
        } else {
            // Build a step only on its first visit in this setup session.
            // Select the content associated with the current position in the wizard.
            switch stepIndex {
            // Introduce the app before asking for configuration choices.
            case 0: step = welcomeStep()
            // Let the user choose available AI providers.
            case 1: step = providerStep()
            // Collect translation and dictionary language choices.
            case 2: step = languageStep()
            // Collect reading and pronunciation preferences.
            case 3: step = audioStep()
            // Configure shortcuts and the optional login item.
            case 4: step = workflowStep()
            // Finish by disclosing the app trial before it begins.
            default: step = readyStep()
            }
            stepViews[stepIndex] = step
        }
        step.translatesAutoresizingMaskIntoConstraints = false
        contentContainer.addSubview(step)
        NSLayoutConstraint.activate([
            step.topAnchor.constraint(equalTo: contentContainer.topAnchor),
            step.leadingAnchor.constraint(equalTo: contentContainer.leadingAnchor),
            step.trailingAnchor.constraint(equalTo: contentContainer.trailingAnchor),
            step.bottomAnchor.constraint(lessThanOrEqualTo: contentContainer.bottomAnchor)
        ])
        fitWindow(to: step)
    }

    // fitWindow(step): Give translated instructions room above the footer
    // without enlarging shorter steps.
    private func fitWindow(to step: NSView) {
        // Skip sizing until the wizard has a window to resize.
        guard let window else { return }
        step.layoutSubtreeIfNeeded()
        let height = max(480, ceil(step.fittingSize.height) + 24 + 20 + continueButton.fittingSize.height + 20)
        let size = nativeContentSize(NSSize(width: 580, height: height), in: window)
        var frame = window.frameRect(forContentRect: NSRect(origin: .zero, size: size))
        frame.origin = NSPoint(x: window.frame.minX, y: window.frame.maxY - frame.height)
        window.setFrame(frame, display: true)
    }

    // stepStack(title, body, [extra = []]): Create a consistently spaced wizard
    // step with a heading, explanation, and optional controls.
    private func stepStack(title: String, body: String, extra: [NSView] = []) -> NSStackView {
        let titleLabel = NSTextField(wrappingLabelWithString: title)
        titleLabel.font = NSFont.systemFont(ofSize: 22, weight: .bold)
        let bodyLabel = NSTextField(wrappingLabelWithString: body)
        bodyLabel.font = NSFont.systemFont(ofSize: 13)
        bodyLabel.textColor = .secondaryLabelColor

        let stack = NSStackView(views: [titleLabel, bodyLabel] + extra)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 14
        stack.setCustomSpacing(10, after: titleLabel)
        // Keep every step component within the shared stack width.
        for view in [titleLabel, bodyLabel] + extra {
            stack.widthAnchor.constraint(greaterThanOrEqualTo: view.widthAnchor).isActive = true
        }
        return stack
    }

    // welcomeStep(): Introduce the app with its icon and a short first-run
    // explanation.
    private func welcomeStep() -> NSView {
        let icon = NSImageView(image: NSApplication.shared.applicationIconImage ?? NSImage())
        icon.translatesAutoresizingMaskIntoConstraints = false
        icon.widthAnchor.constraint(equalToConstant: 76).isActive = true
        icon.heightAnchor.constraint(equalToConstant: 76).isActive = true
        return stepStack(
            title: String(format: localized("wizard_welcome_title", "Welcome to %@"), appName),
            body: localized("wizard_welcome_body_short", "Proofread, rewrite, explain, summarize, translate, and look up words. Listen to results and Dictionary examples.\n\nChoose your settings now or change them later."),
            extra: [icon]
        )
    }

    // providerStep(): Enable each checked provider's balanced model and save
    // entered keys in Keychain.
    private func providerStep() -> NSView {
        let appleAvailable = appleIntelligenceIsAvailable()
        providerChecks = [:]
        providerKeyFields = [:]

        // Load the saved model list. On first launch, select Apple Intelligence if available.
        let hasSavedShortlist = preferencesStore.object(forKey: PreferenceKey.preferredTextModels) != nil
        let enabledProviders = Set(loadAppPreferences().preferredTextModels.map { textProvider(for: $0).provider })

        var rows: [NSView] = []
        // Build a checkbox and any credential field for each available provider.
        for provider in providers {
            let check = NSButton(
                checkboxWithTitle: provider.title,
                target: self,
                action: #selector(providerToggled(_:))
            )
            check.font = NSFont.systemFont(ofSize: 13)
            check.toolTip = provider.detail
            check.identifier = NSUserInterfaceItemIdentifier(provider.id)
            let seededOn = hasSavedShortlist
                ? enabledProviders.contains(textProvider(for: provider.modelID).provider)
                : provider.id == "apple"
            check.state = seededOn ? .on : .off
            // Apple's checkbox depends on the local model's current availability.
            if provider.id == "apple" {
                check.isEnabled = appleAvailable
                // Prevent an unavailable local model from remaining selected in setup.
                if !appleAvailable { check.state = .off }
            }
            providerChecks[provider.id] = check

            // Only providers backed by an account need a key-entry field.
            if provider.account != nil {
                let field = NSTextField(string: "")
                field.placeholderString = localized("wizard_key_optional", "API key (optional, add any time)")
                field.font = NSFont.systemFont(ofSize: 12)
                field.isEnabled = check.state == .on
                field.translatesAutoresizingMaskIntoConstraints = false
                field.widthAnchor.constraint(equalToConstant: 280).isActive = true
                providerKeyFields[provider.id] = field

                let row = NSStackView(views: [check, field])
                row.orientation = .horizontal
                row.alignment = .centerY
                row.spacing = 12
                check.widthAnchor.constraint(equalToConstant: 170).isActive = true
                rows.append(row)
            } else {
                // Describe local Apple availability without asking for a cloud credential.
                check.title = appleAvailable
                    ? localized("wizard_apple_row", "Apple Intelligence (on this Mac, private and free)")
                    : localized("wizard_apple_row_unavailable", "Apple Intelligence (not available on this Mac)")
                rows.append(check)
            }
        }

        let list = NSStackView(views: rows)
        list.orientation = .vertical
        list.alignment = .leading
        list.spacing = 10

        let keyNote = NSTextField(wrappingLabelWithString: localized(
            "wizard_key_note_local",
            "Keys stay in macOS Keychain. Requests go directly to your provider. Add keys or a local model later in Settings → Models."
        ))
        keyNote.font = NSFont.systemFont(ofSize: 11)
        keyNote.textColor = .tertiaryLabelColor

        var extra: [NSView] = [list, keyNote]
        // Explain Pro before asking for keys. Show the paywall when a cloud request starts.
        if !ProStore.shared.isPro {
            let proNote = NSTextField(wrappingLabelWithString: String(format: localized(
                "wizard_pro_note",
                "Your first 30 days include %@ Pro. Apple Intelligence stays free afterward."
            ), appName))
            proNote.font = NSFont.systemFont(ofSize: 12)
            proNote.textColor = .secondaryLabelColor
            extra.append(proNote)
        }

        return stepStack(
            title: localized("wizard_provider_title_multi", "Choose your providers"),
            body: localized(
                "wizard_provider_body_multi",
                "Switch models in the launcher, or open All models to enable more."
            ),
            extra: extra
        )
    }

    // providerToggled(sender): Enable the key field only while its provider is
    // selected.
    @objc private func providerToggled(_ sender: NSButton) {
        // Ignore checkbox events that do not identify a provider.
        guard let id = sender.identifier?.rawValue else { return }
        providerKeyFields[id]?.isEnabled = sender.state == .on
    }

    // fieldCaption(text): Label a setup control using the step's caption style.
    private func fieldCaption(_ text: String) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = NSFont.systemFont(ofSize: 12, weight: .semibold)
        label.textColor = .secondaryLabelColor
        return label
    }

    // languageStep(): Populate translation, dictionary, and reading choices
    // from current preferences.
    private func languageStep() -> NSView {
        let preferences = loadAppPreferences()

        // Use the first target as primary and include the others in the same translation request.
        translationTargetsControl = MultiSelectPreferenceControl(options: translationTargetOptions)
        translationTargetsControl.translatesAutoresizingMaskIntoConstraints = false
        translationTargetsControl.widthAnchor.constraint(equalToConstant: 320).isActive = true
        translationTargetsControl.setSelectedIDs(
            preferences.translationTargets.isEmpty
                ? [defaultTranslationTargetID]
                : preferences.translationTargets
        )

        extraLanguagesControl = MultiSelectPreferenceControl(options: translationTargetOptions)
        extraLanguagesControl.translatesAutoresizingMaskIntoConstraints = false
        extraLanguagesControl.widthAnchor.constraint(equalToConstant: 320).isActive = true
        extraLanguagesControl.setSelectedIDs(preferences.extraLanguages)

        return stepStack(
            title: localized("wizard_language_title", "Your languages"),
            body: localized(
                "wizard_language_body_single_source",
                "Choose translation languages. Extra languages add versions to Dictionary, Explain, and Summarize results. Change either list in the launcher's mode menus."
            ),
            extra: [
                fieldCaption(localized("wizard_translate_to", "Translate to")),
                translationTargetsControl,
                fieldCaption(localized("wizard_extra_languages", "Also answer in")),
                extraLanguagesControl
            ]
        )
    }

    // audioStep(): Choose the pronunciation voice shared by Dictionary and
    // Settings → Reading.
    private func audioStep() -> NSView {
        pronunciationVoicePopup = NSPopUpButton(frame: .zero, pullsDown: false)
        pronunciationVoicePopup.translatesAutoresizingMaskIntoConstraints = false
        pronunciationVoicePopup.menu = makeReaderChoiceMenu()
        pronunciationVoicePopup.widthAnchor.constraint(equalToConstant: 320).isActive = true
        selectReaderChoice(pronunciationVoicePopup, id: loadAppPreferences().dictionaryVoice)

        return stepStack(
            title: localized("wizard_audio_title", "Hear your words"),
            body: localized(
                "wizard_audio_body",
                "Read results aloud or hear Dictionary words and examples. Choose a voice that supports the language.\n\nApple voices run on your Mac for free. OpenAI and Grok voices require Pro and a provider API key."
            ),
            extra: [
                fieldCaption(localized("wizard_pronunciation_voice", "Dictionary pronunciation voice")),
                pronunciationVoicePopup
            ]
        )
    }

    // workflowStep(): Show current workflow shortcuts and the optional
    // launch-at-login control.
    private func workflowStep() -> NSView {
        loginItemCheckbox = NSButton(
            checkboxWithTitle: localized("open_langmin_at_login", "Open Langmin at login"),
            target: nil,
            action: nil
        )
        loginItemCheckbox.state = .on

        // Show the saved bindings, including cleared shortcuts, when Setup is reopened.
        let configuredShortcuts = loadGlobalShortcuts()
        let shortcutPairs: [(String, String)] = [
            ("proofread", localized("proofread", "Proofread")),
            ("rewrite", localized("rewrite", "Rewrite")),
            ("explain", localized("explain", "Explain")),
            ("summarize", localized("summarize", "Summarize")),
            ("translate", localized("translate", "Translate")),
            ("dictionary", localized("dictionary", "Dictionary"))
        ]
        // Keep each shortcut on one line in an indented stack.
        let shortcutList = NSStackView(views: shortcutPairs.map { pair in
            let binding = configuredShortcuts[pair.0]?.displayText ?? "—"
            let label = NSTextField(labelWithString: "\(binding)   \(pair.1)")
            label.font = NSFont.systemFont(ofSize: 13)
            return label
        })
        shortcutList.orientation = .vertical
        shortcutList.alignment = .leading
        shortcutList.spacing = 8
        shortcutList.edgeInsets = NSEdgeInsets(top: 0, left: 18, bottom: 0, right: 0)
        shortcutList.translatesAutoresizingMaskIntoConstraints = false

        let shortcuts = NSTextField(wrappingLabelWithString: localized(
            "wizard_shortcuts_body",
            "Use these shortcuts from another app after copying text.\n\nIn Langmin's main window, these shortcuts select a mode. Press ⌘Return to run it."
        ))
        shortcuts.font = NSFont.systemFont(ofSize: 12)
        shortcuts.textColor = .secondaryLabelColor

        return stepStack(
            title: localized("wizard_workflow_title", "Always at hand"),
            body: localized(
                "wizard_workflow_body",
                "Open Langmin at login to keep its menu-bar actions and shortcuts available."
            ),
            extra: [loginItemCheckbox, shortcutList, shortcuts]
        )
    }

    // readyStep(): Explain the automatic trial, free tier, and optional plans before setup ends.
    private func readyStep() -> NSView {
        let during = trialRow(
            symbol: "clock",
            title: localized("wizard_trial_during_title", "Your first 30 days"),
            detail: localized(
                "wizard_trial_during_langmin",
                "Use every Langmin feature without app limits. Provider charges may still apply."
            )
        )
        let after = trialRow(
            symbol: "apple.intelligence",
            title: localized("wizard_trial_after_title", "After the trial"),
            detail: localized(
                "wizard_trial_after_langmin",
                "Apple Intelligence, Apple voices, Apple transcription, text editing, and the Library stay free. Other Pro features require a purchase."
            )
        )
        let plans = trialRow(
            symbol: "creditcard",
            title: localized("wizard_trial_plans_title", "Keep Pro"),
            detail: localized(
                "wizard_trial_plans_body",
                "Choose a yearly plan or lifetime access at any time."
            )
        )
        return stepStack(
            title: localized("wizard_ready_title", "30 days of full access"),
            body: localized(
                "wizard_ready_body_simple",
                "Langmin includes a free 30-day full-access period. No subscription starts, and you will not be charged."
            ),
            extra: [during, after, plans]
        )
    }

    // trialRow(symbol, title, detail): Present one trial fact with a clear icon and supporting text.
    private func trialRow(symbol: String, title: String, detail: String) -> NSView {
        let icon = NSImageView()
        icon.image = NSImage(systemSymbolName: symbol, accessibilityDescription: title)
        icon.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 18, weight: .medium)
        icon.contentTintColor = .controlAccentColor
        icon.translatesAutoresizingMaskIntoConstraints = false
        icon.widthAnchor.constraint(equalToConstant: 28).isActive = true

        let titleLabel = NSTextField(labelWithString: title)
        titleLabel.font = NSFont.systemFont(ofSize: 13, weight: .semibold)
        let detailLabel = NSTextField(wrappingLabelWithString: detail)
        detailLabel.font = NSFont.systemFont(ofSize: 12)
        detailLabel.textColor = .secondaryLabelColor
        let text = NSStackView(views: [titleLabel, detailLabel])
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = 3

        let row = NSStackView(views: [icon, text])
        row.orientation = .horizontal
        row.alignment = .top
        row.spacing = 12
        return row
    }

    // MARK: - Actions

    // goBack(sender): Return to the previous setup step.
    @objc private func goBack(_ sender: Any?) {
        // Do not navigate before the welcome step.
        guard stepIndex > 0 else { return }
        stepIndex -= 1
        showStep()
    }

    // goForward(sender): Advance through setup, or save the selected choices
    // from the final step.
    @objc private func goForward(_ sender: Any?) {
        // Finishing the disclosure starts the local clock where this build uses one.
        if stepIndex == stepCount - 1 {
            ProStore.shared.beginAppTrial()
        }
        // The final Continue action saves setup instead of advancing past the last page.
        if stepIndex == stepCount - 1 {
            finish()
            return
        }
        stepIndex += 1
        showStep()
    }

    // setUpLater(sender): Mark setup as dismissed without applying unfinished
    // provider and language choices.
    @objc private func setUpLater(_ sender: Any?) {
        preferencesStore.set(true, forKey: Self.completedKey)
        window?.close()
    }

    // finish(): Save the completed setup choices, report failures, and close
    // when setup succeeds.
    private func finish() {
        // Save checked providers and entered keys. If none are checked, keep the existing model
        // settings.
        var models: [String] = []
        // Persist only providers the user left selected.
        for provider in providers where providerChecks[provider.id]?.state == .on {
            // Recheck the on-device model before enabling it.
            if provider.id == "apple" {
                // Do not save an Apple model that became unavailable during setup.
                guard appleIntelligenceIsAvailable() else { continue }
                models.append(appleIntelligenceModelID)
            } else {
                // Use the selected remote provider's configured model ID.
                models.append(provider.modelID)
            }
            // Save an entered key only for a provider that has a credential account.
            if let account = provider.account,
               let key = providerKeyFields[provider.id]?.stringValue
                   .trimmingCharacters(in: .whitespacesAndNewlines),
               !key.isEmpty {
                try? saveAPIKey(key, account: account, providerName: provider.title)
            }
        }
        if !models.isEmpty {
            // Use Apple Intelligence when selected and available; otherwise use a checked provider.
            let defaultModel = models.first { $0 == defaultExplanationModel } ?? models[0]
            preferencesStore.set(
                encodeTextModelList(models),
                forKey: PreferenceKey.preferredTextModels
            )
            preferencesStore.set(defaultModel, forKey: PreferenceKey.explanationModel)
            // A remembered launcher choice must not override the model just chosen in setup.
            preferencesStore.set(defaultModel, forKey: PreferenceKey.launcherExplanationModel)
            (NSApp.delegate as? AppDelegate)?.launcherController.refreshModelOptions(selecting: defaultModel)
        }

        // Save language choices to the preferences used by the launcher menus.
        if let control = translationTargetsControl {
            let targets = control.selectedIDs.isEmpty
                ? [defaultTranslationTargetID]
                : control.selectedIDs
            preferencesStore.set(
                encodeLanguageList(targets),
                forKey: PreferenceKey.translationTarget
            )
        }
        // Persist dictionary languages when their selection control was built.
        if let control = extraLanguagesControl {
            preferencesStore.set(
                encodeLanguageList(control.selectedIDs),
                forKey: PreferenceKey.extraLanguages
            )
        }
        // Persist the selected pronunciation voice when its menu is available.
        if let popup = pronunciationVoicePopup {
            preferencesStore.set(selectedReaderChoiceID(popup), forKey: PreferenceKey.dictionaryVoice)
        }

        // Register login launch only when selected and not already enabled.
        if loginItemCheckbox?.state == .on, SMAppService.mainApp.status != .enabled {
            try? SMAppService.mainApp.register()
        }

        preferencesStore.set(true, forKey: Self.completedKey)
        window?.close()
    }
}

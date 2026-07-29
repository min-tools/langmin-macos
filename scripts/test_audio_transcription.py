#!/usr/bin/env python3
"""Exercise audio import, consent, Settings, and cancellation without accounts or model downloads."""
from pathlib import Path
import argparse
import json
import os
import shutil
import subprocess
import tempfile
from source_files import ROOT, app_path, swift_fixture_args


# block(source, marker): Extract production declarations for the isolated
# fixture.
def block(source, marker):
    start = source.index(marker)
    end = source.index('{', start) + 1
    depth = 1
    while depth:
        depth += (source[end] == '{') - (source[end] == '}')
        end += 1
    return source[start:end]


main = app_path('main.swift').read_text()
source = r'''
import Cocoa
import Vision
import UniformTypeIdentifiers
struct HelperFailure: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}
// Keep all consent and preference storage in memory, away from the user's defaults.
final class MemoryPreferences {
    var values: [String: Any] = [:]
    // bool(key): Read a Boolean fixture preference, defaulting to false.
    func bool(forKey key: String) -> Bool { values[key] as? Bool ?? false }
    // set(value, key): Store a fixture preference in memory.
    func set(_ value: Any, forKey key: String) { values[key] = value }
    // dictionaryRepresentation(): Return the fixture preferences without
    // reading disk.
    func dictionaryRepresentation() -> [String: Any] { values }
    // removeObject(key): Remove the named fixture preference.
    func removeObject(forKey key: String) { values.removeValue(forKey: key) }
}
let memory = MemoryPreferences()
// langminPreferencesStore(): Return the isolated in-memory preference store.
func langminPreferencesStore() -> MemoryPreferences { memory }
let remoteAIConsentPrefix = "remoteAIConsent."
var fixtureTranslations: [String: String] = [:]
// localized(key, text): Use the fixture translation when present, otherwise the
// supplied fallback.
func localized(_ key: String, _ text: String) -> String { fixtureTranslations[key] ?? text }
class FocusablePopUpButton: NSPopUpButton {}
var modalResponse: NSApplication.ModalResponse = .alertFirstButtonReturn
var modalCount = 0
var modalTitle = ""
// runLangminModalAlert(alert, [before = nil]): Record the alert and return the
// configured fixture response.
func runLangminModalAlert(_ alert: NSAlert, before: DispatchTime? = nil) -> NSApplication.ModalResponse {
    modalCount += 1
    modalTitle = alert.messageText
    return modalResponse
}
enum ProFeature { case cloudTranscription }
var proAllowed = true
// ensureProAccess(feature): Return the fixture access decision without showing
// purchase UI.
func ensureProAccess(_ feature: ProFeature) -> Bool { proAllowed }
struct Preferences { var transcriptionProvider = "apple"; var transcriptionLanguage = "auto" }
var preferences = Preferences()
// loadAppPreferences(): Return the fixture preferences without reading user
// settings.
func loadAppPreferences() -> Preferences { preferences }
// transcribeOpenAIAudioFile(url, progress): Simulate cloud latency and
// cancellation while exercising the actual import controller.
func transcribeOpenAIAudioFile(_ url: URL, progress: @escaping @Sendable (AudioTranscriptionProgress) -> Void) async throws -> String {
    progress(.init(message: "Fixture upload", fraction: 0.5))
    try await Task.sleep(nanoseconds: 40_000_000)
    // Keep a fixture import pending long enough to exercise cancellation.
    if url.lastPathComponent == "slow.wav" { try await Task.sleep(nanoseconds: 5_000_000_000) }
    // Simulate a decoding failure without using a damaged recording.
    if url.lastPathComponent == "broken.wav" { throw HelperFailure(message: "Fixture failure") }
    return "Transcribed " + url.lastPathComponent
}
// extractTextFromDroppedFile(url): Read UTF-8 text from the fixture document.
func extractTextFromDroppedFile(_ url: URL) throws -> String { try String(contentsOf: url, encoding: .utf8) }
// recognizeText(image): Return fixed OCR text without invoking image
// recognition.
func recognizeText(in image: CGImage) throws -> String { "Fixture OCR" }
// handleFocusedTextUndoRedoShortcut(event, view): Leave editor shortcuts
// unhandled in this import fixture.
func handleFocusedTextUndoRedoShortcut(_ event: NSEvent, in view: NSTextView) -> Bool { false }
let wordProcessingExtensions: Set<String> = ["doc", "docx"]
'''
source += block(main, 'func resetRemoteAIConsents()') + '\n'
source += block(main, 'func droppedFileSupportsTextExtraction(') + '\n'
source += block(main, 'final class LauncherInputView:').replace('private ', '') + '\n'
# Render the real Settings form and navigation without opening app preferences.
for marker in ['func tintedSymbol(', 'final class SettingsSidebarButton:', 'enum PreferencesSection:',
               'let langminControlBorderColor =', 'final class NativeSeparator:', 'enum SettingsLayout {',
               'final class NativeBackgroundView:', 'func nativeTitlebarHeight(',
               'func nativeContentSize(', 'func installNativeContent(', 'final class PlaceholderTextView:']:
    source += block(main, marker) + '\n'
source += r'''
// configureNativeWindow(window): Use the app's content layout without
// repositioning the title-bar buttons.
func configureNativeWindow(_ window: NSWindow) {
    window.titlebarAppearsTransparent = true
    window.titlebarSeparatorStyle = .none
}
class TooltipInfoLabel: NSTextField {
    var tooltipMessage = ""; var tooltipYOffset: CGFloat = 0
    var tooltipAnchorXOffset: CGFloat = 0; var tooltipExtraXShift: CGFloat = 0
}
final class SettingsLayoutFixture: NSObject, NSTextFieldDelegate {
    var sectionButtons: [PreferencesSection: NSButton] = [:]
    var selectedSection = PreferencesSection.transcription
    var sectionHeading: NSTextField?
    var resetAIConsentButton: NSButton?
    var window: NSWindow?
    var tabView = NSTabView()
    var logicalFocusIndex = 0
    var advancedInstructionsSeparatorRow = NSView()
    var advancedInstructionsSeparator = NSBox()
    var settingsSeparators: [ObjectIdentifier: NSBox] = [:]
    var settingsInfoTooltips: [ObjectIdentifier: String] = [:]
    // updateAPIKeyPlaceholders(): Exercise page selection without reading
    // credentials or moving focus into mock forms.
    func updateAPIKeyPlaceholders() {}
    // preferencesFocusViews(): Provide no extra focus targets for the fixture
    // settings page.
    func preferencesFocusViews() -> [NSView] { [] }

    // modelsPage(): Check the Models form with production field helpers and
    // placeholder values.
    func modelsPage() -> (view: NSView, controls: [NSView]) {
        var rows: [(String, NSView)] = []
        for title in ["OpenAI API Key", "Anthropic API Key", "Gemini API Key", "xAI API Key", "DeepSeek API Key"] {
            let field = secureTextField()
            field.placeholderString = "Saved; type to replace"
            let remove = NSButton(title: "Remove", target: nil, action: nil)
            remove.bezelStyle = .rounded
            rows.append((title, apiKeyControls(field: field, removeButton: remove)))
        }
        for (title, placeholder) in [("Custom Name", "Display name, e.g. Local model"),
                                     ("Custom URL", "http://localhost:1234/v1"),
                                     ("Custom Model", "Model ID from your server")] {
            rows.append((title, plainTextField(placeholder: placeholder)))
        }
        rows.append(("Custom API Key", secureTextField()))
        rows.append(("Keychain", noteLabel("Custom endpoints must support OpenAI chat completions. API keys stay in Keychain; search for tools.min.langmin in Keychain Access to find them.")))
        for (_, control) in rows {
            control.translatesAutoresizingMaskIntoConstraints = false
            control.widthAnchor.constraint(equalToConstant: 330).isActive = true
        }
        return (settingsSectionView(rows: rows), rows.map { $0.1 })
    }

    // shortcutsPage(): Check that fixed-height shortcut buttons fit above the
    // footer.
    func shortcutsPage() -> (view: NSView, controls: [NSView]) {
        var rows: [(String, NSView)] = []
        for (title, text) in [("Menu Bar", "Show Langmin in the menu bar"), ("Login Item", "Open Langmin at login")] {
            let checkbox = NSButton(checkboxWithTitle: text, target: nil, action: nil)
            checkbox.font = .systemFont(ofSize: 13)
            rows.append((title, checkbox))
        }
        for title in ["Library", "Open Clipboard", "Proofread Clipboard", "Rewrite Clipboard", "Explain Clipboard", "Summarize Clipboard", "Translate Clipboard", "Dictionary Clipboard"] {
            let recorder = NSButton(title: "None", target: nil, action: nil)
            recorder.bezelStyle = .rounded
            recorder.font = .monospacedSystemFont(ofSize: 13, weight: .medium)
            recorder.translatesAutoresizingMaskIntoConstraints = false
            recorder.widthAnchor.constraint(equalToConstant: 170).isActive = true
            recorder.heightAnchor.constraint(equalToConstant: 28).isActive = true
            rows.append((title, recorder))
        }
        return (settingsSectionView(rows: rows), rows.map { $0.1 })
    }

    // advancedPage(): Include the Advanced form's text editors to catch sidebar
    // sizing regressions.
    func advancedPage() -> (view: NSView, controls: [NSView]) {
        var rows: [(String, NSView)] = []
        for title in ["OpenAI Endpoint", "Anthropic Endpoint", "Gemini Endpoint", "Anthropic Version", "Anthropic Search Tool"] {
            let field = plainTextField(placeholder: "Use the built-in default")
            field.widthAnchor.constraint(equalToConstant: 330).isActive = true
            rows.append((title, field))
        }
        let models = multilineField(placeholder: "provider:label:model", height: 60).scroll
        let instructions = multilineField(placeholder: "Optional instructions", height: 46, monospaced: false).scroll
        let note = noteLabel("Leave fields blank to use the built-in defaults.")
        for view in [models, instructions, note, advancedInstructionsSeparatorRow] {
            view.translatesAutoresizingMaskIntoConstraints = false
            view.widthAnchor.constraint(equalToConstant: 330).isActive = true
        }
        advancedInstructionsSeparatorRow.heightAnchor.constraint(equalToConstant: 1).isActive = true
        advancedInstructionsSeparator.boxType = .separator
        advancedInstructionsSeparator.translatesAutoresizingMaskIntoConstraints = false
        rows += [("Extra Models", models), ("", note), ("", advancedInstructionsSeparatorRow), ("Custom Instructions", instructions)]
        return (settingsSectionView(rows: rows), rows.map { $0.1 })
    }
'''
for marker in ['    func settingsSidebar()', '    func settingsSectionView(rows:', '    func label(_ title: String)',
               '    @objc func selectPreferencesSection(', '    func syncSectionButtonStates()',
               '    func multilineField(', '    func noteLabel(', '    func secureTextField()',
               '    func plainTextField(', '    func apiKeyControls(']:
    source += block(main, marker) + '\n'
source += '}\n'
source += 'let settingsContentSize = SettingsLayout.contentSize\n'
source += r'''
var checks = 0
// check(condition, message): Stop the fixture with its message when the
// assertion fails.
func check(_ condition: @autoclosure () -> Bool, _ message: String) {
    // Fail immediately with the assertion message.
    guard condition() else { fputs("FAIL: \(message)\n", stderr); exit(1) }
    checks += 1
}
// waitFor(predicate): Wait briefly for UI tasks without blocking the main
// thread.
@MainActor
func waitFor(_ predicate: () -> Bool) async throws {
    for _ in 0..<100 {
        // Stop waiting as soon as the expected UI state appears.
        if predicate() { return }
        try await Task.sleep(nanoseconds: 20_000_000)
    }
    throw HelperFailure(message: "Fixture operation did not finish")
}
let root = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
// snapshot(view, name): Keep screenshots in fixture storage, with optional
// export handled by the Python runner.
func snapshot(_ view: NSView, name: String) throws {
    view.layoutSubtreeIfNeeded()
    let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds)!
    view.cacheDisplay(in: view.bounds, to: bitmap)
    try bitmap.representation(using: .png, properties: [:])!.write(to: root.appendingPathComponent(name + ".png"))
}
_ = NSApplication.shared
Task { @MainActor in
    do {
        for ext in ["m4a", "MP3", "wav"] {
            let file = root.appendingPathComponent("sample." + ext)
            check(droppedFileSupportsAudioTranscription(file), "Audio extension is recognized")
            check(droppedFileSupportsTextExtraction(file), "Audio is accepted by the actual drop filter")
        }
        check(!droppedFileSupportsAudioTranscription(URL(string: "https://example.com/audio.mp3")!), "A remote URL is not a dropped audio file")
        check(!droppedFileSupportsAudioTranscription(root.appendingPathComponent("a.mp3.txt")), "An embedded audio extension is not audio")
        check(droppedFileSupportsTextExtraction(root.appendingPathComponent("a.pdf")), "PDF drops remain supported")
        check(droppedFileSupportsTextExtraction(root.appendingPathComponent("a.png")), "Image drops remain supported")
        let trimmed = try checkedAudioTranscript("  spoken words\n")
        check(trimmed == "spoken words", "Transcript boundaries are trimmed")
        do { _ = try checkedAudioTranscript(" \n"); check(false, "An empty transcript must fail") }
        catch { check(error.localizedDescription.contains("No speech"), "An empty transcript explains that no speech was found") }
        check(AudioTranscriptionProvider.resolved("unknown") == .apple, "Unknown providers default to local recognition")
        check(AudioTranscriptionProvider.resolved("openAI") == .openAI, "The OpenAI provider remains selectable")

        // Existing text approval must not authorize a recording upload.
        memory.set(true, forKey: remoteAIConsentPrefix + "openai.api.openai.com")
        check(!confirmRemoteAudioSharingIfNeeded(), "Text consent does not imply audio consent")
        check(modalTitle == "Send recordings to OpenAI?", "Audio consent names the content and provider")
        modalResponse = .alertSecondButtonReturn
        check(confirmRemoteAudioSharingIfNeeded(), "Allow Once permits this batch")
        modalResponse = .alertFirstButtonReturn
        check(!confirmRemoteAudioSharingIfNeeded(), "Allow Once does not persist")
        modalResponse = .alertThirdButtonReturn
        check(confirmRemoteAudioSharingIfNeeded(), "Always Allow permits this batch")
        let count = modalCount
        check(confirmRemoteAudioSharingIfNeeded() && modalCount == count, "Audio approval is reused")
        memory.set(true, forKey: "unrelated")
        resetRemoteAIConsents()
        modalResponse = .alertFirstButtonReturn
        check(!confirmRemoteAudioSharingIfNeeded(), "Reset revokes audio approval")
        check(memory.bool(forKey: "unrelated"), "Reset leaves other settings alone")

        // A download prompt queued before Cancel must not appear after the import has closed.
        let beforeDownload = modalCount
        let cancelledDownload = Task { @MainActor in confirmSpeechModelDownload(language: "English") }
        cancelledDownload.cancel()
        let downloadApproved = await cancelledDownload.value
        check(!downloadApproved && modalCount == beforeDownload, "Cancelled Apple imports never open a queued download prompt")

        // Settings edits stay in the draft, and a reset returns to Apple and the Mac's language.
        let settings = TranscriptionSettingsControls()
        settings.populate(provider: "openAI", language: "zz-ZZ")
        check(settings.provider == .openAI, "Settings retain the selected provider")
        check(settings.language == "zz-ZZ", "Changing providers preserves the Apple language draft")
        settings.populate(provider: "apple", language: "auto")
        check(settings.provider == .apple && settings.language == "auto", "Reset restores local defaults")
        check(preferences.transcriptionProvider == "apple", "Editing a Settings draft does not save preferences")
        check(settings.focusViews.count == 2, "Apple language control participates in keyboard navigation")

        // Both providers must fit the actual form and all tabs in light and dark appearances.
        for dark in [false, true] {
            for provider in AudioTranscriptionProvider.allCases {
                let controls = TranscriptionSettingsControls()
                controls.populate(provider: provider.rawValue, language: "auto")
                let layout = SettingsLayoutFixture()
                let panel = NSWindow(contentRect: NSRect(origin: .zero, size: settingsContentSize), styleMask: [.titled], backing: .buffered, defer: false)
                panel.isReleasedWhenClosed = false
                panel.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
                let surface = installNativeContent(in: panel)
                // Offscreen snapshots need an opaque base beneath the native window material.
                surface.wantsLayer = true
                panel.effectiveAppearance.performAsCurrentDrawingAppearance {
                    surface.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
                }
                let sidebar = layout.settingsSidebar()
                let page = layout.settingsSectionView(rows: controls.rows)
                let advanced = layout.advancedPage()
                let models = layout.modelsPage()
                let shortcuts = layout.shortcutsPage()
                let densePages: [PreferencesSection: (view: NSView, controls: [NSView])] = [
                    .advanced: advanced, .models: models, .shortcuts: shortcuts
                ]
                let heading = NSTextField(labelWithString: layout.selectedSection.title)
                layout.window = panel
                layout.sectionHeading = heading
                // Use the app's tab container so the test exercises its sizing priorities.
                layout.tabView.tabViewType = .noTabsNoBorder
                SettingsLayout.install(sidebar: sidebar, page: layout.tabView, heading: heading, in: surface)
                // Match the app's first layout before it has added any Settings pages.
                panel.layoutIfNeeded()
                for section in PreferencesSection.allCases {
                    let item = NSTabViewItem(identifier: section.rawValue)
                    item.view = section == .transcription ? page : densePages[section]?.view ?? NSView()
                    layout.tabView.addTabViewItem(item)
                }
                layout.tabView.selectTabViewItem(withIdentifier: layout.selectedSection.rawValue)
                NSLayoutConstraint.activate([
                    surface.widthAnchor.constraint(equalToConstant: settingsContentSize.width),
                    surface.heightAnchor.constraint(equalToConstant: settingsContentSize.height)
                ])
                panel.setContentSize(nativeContentSize(settingsContentSize, in: panel))
                surface.layoutSubtreeIfNeeded()
                check(abs(sidebar.frame.width - SettingsLayout.rowWidth) < 1, "The sidebar stays at its intended width beside NSTabView")
                check(surface.bounds.contains(sidebar.frame) && sidebar.frame.maxX < layout.tabView.frame.minX, "Settings navigation fits beside the form")
                check(page.frame.width >= 531, "The compact Settings window leaves room for the form")
                for button in layout.sectionButtons.values {
                    let titleWidth = (button.title as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: 13, weight: .semibold)]).width
                    check(titleWidth <= button.bounds.width - 56, "Every sidebar label has room for its icon and padding")
                    check(sidebar.bounds.contains(button.frame), "Every Settings row fits inside the sidebar")
                }
                for (_, control) in controls.rows {
                    check(page.bounds.contains(control.convert(control.bounds, to: page)), "Speech controls fit the form")
                    // Check that explanatory labels have enough height for wrapped text.
                    if let note = control as? NSTextField {
                        check(note.frame.height >= note.cell!.cellSize(forBounds: NSRect(x: 0, y: 0, width: note.frame.width, height: 1000)).height, "Speech guidance wraps without clipping")
                    }
                }
                try snapshot(surface, name: "transcription-\(provider.rawValue)-\(dark ? "dark" : "light")")
                // Real button actions must select one page, update its heading, and accept keyboard focus.
                for section in PreferencesSection.allCases {
                    let button = layout.sectionButtons[section] as! SettingsSidebarButton
                    var receivedFocus = false
                    button.focusHandler = { receivedFocus = true }
                    check(panel.makeFirstResponder(button) && receivedFocus, "Sidebar rows report keyboard focus")
                    button.performClick(nil)
                    check(layout.selectedSection == section && layout.tabView.selectedTabViewItem?.identifier as? String == section.rawValue,
                          "A sidebar action selects its matching Settings page")
                    check(heading.stringValue == section.title && layout.sectionButtons.values.filter { $0.state == .on }.count == 1,
                          "The page heading and single selection stay in sync")
                    surface.layoutSubtreeIfNeeded()
                    check(abs(sidebar.frame.width - SettingsLayout.rowWidth) < 1 && layout.tabView.frame.width >= 531,
                          "Switching pages keeps the sidebar fixed and the form visible")
                    // Check content-heavy settings pages as well as the basic page.
                    if let densePage = densePages[section] {
                        for control in densePage.controls {
                            check(densePage.view.bounds.contains(control.convert(control.bounds, to: densePage.view)),
                                  "\(section.title) controls remain inside the compact tab")
                            // Check wrapping labels without applying that rule to single-line controls.
                            if let note = control as? NSTextField, note.maximumNumberOfLines == 0 {
                                check(note.frame.height >= note.cell!.cellSize(forBounds: NSRect(x: 0, y: 0, width: note.frame.width, height: 1000)).height,
                                      "\(section.title) guidance wraps without clipping")
                            }
                        }
                        try snapshot(surface, name: "settings-\(section.rawValue)-\(dark ? "dark" : "light")")
                    }
                }
                panel.close()
            }
        }

        // Long translated reset labels must not collide with the Models footer actions.
        let translations = try JSONDecoder().decode([[String: String]].self,
            from: Data(contentsOf: root.appendingPathComponent("settings-translations.json")))
        for translation in translations {
            fixtureTranslations = translation
            let layout = SettingsLayoutFixture()
            layout.selectedSection = .models
            let size = SettingsLayout.contentSize
            let panel = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.titled], backing: .buffered, defer: false)
            panel.isReleasedWhenClosed = false
            panel.appearance = NSAppearance(named: .aqua)
            let surface = installNativeContent(in: panel)
            surface.wantsLayer = true
            panel.effectiveAppearance.performAsCurrentDrawingAppearance {
                surface.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
            }
            let sidebar = layout.settingsSidebar()
            let heading = NSTextField(labelWithString: layout.selectedSection.title)
            layout.tabView.tabViewType = .noTabsNoBorder
            SettingsLayout.install(sidebar: sidebar, page: layout.tabView, heading: heading, in: surface)
            let item = NSTabViewItem(identifier: PreferencesSection.models.rawValue)
            item.view = layout.modelsPage().view
            layout.tabView.addTabViewItem(item)
            let reset = NSButton(title: localized("reset_defaults", "Reset Defaults"), target: nil, action: nil)
            let permissions = NSButton(title: "Reset AI Permissions", target: nil, action: nil)
            let cancel = NSButton(title: localized("cancel", "Cancel"), target: nil, action: nil)
            let save = NSButton(title: localized("save", "Save"), target: nil, action: nil)
            for button in [reset, permissions, cancel, save] { button.bezelStyle = .rounded }
            save.keyEquivalent = "\r"
            let actions = NSStackView(views: [cancel, save])
            actions.orientation = .horizontal
            actions.alignment = .centerY
            actions.spacing = 10
            for view in [reset, permissions, actions] {
                view.translatesAutoresizingMaskIntoConstraints = false
                surface.addSubview(view)
            }
            SettingsLayout.installFooter(reset: reset, permissions: permissions, actions: actions, page: layout.tabView, in: surface)
            NSLayoutConstraint.activate([
                surface.widthAnchor.constraint(equalToConstant: size.width),
                surface.heightAnchor.constraint(equalToConstant: size.height)
            ])
            panel.setContentSize(nativeContentSize(size, in: panel))
            surface.layoutSubtreeIfNeeded()
            let locale = translation["locale"]!
            check(reset.frame.maxX + 11.5 <= permissions.frame.minX, "\(locale): translated Reset Defaults leaves a clear gap")
            check(permissions.frame.maxX + 11.5 <= actions.frame.minX, "\(locale): permissions do not overlap Cancel or Save")
            for button in [reset, permissions, cancel, save] {
                check(button.frame.width + 0.5 >= button.intrinsicContentSize.width, "\(locale): footer titles are not compressed")
                check(surface.bounds.contains(button.convert(button.bounds, to: surface)), "\(locale): footer actions stay inside the window")
            }
            for button in layout.sectionButtons.values {
                check(button.frame.width >= button.intrinsicContentSize.width, "\(locale): sidebar labels retain their padding")
            }
            // Capture representative footer layouts for short and long translations.
            if ["en", "fr", "hu"].contains(locale) {
                try snapshot(surface, name: "settings-footer-\(locale)")
            }
            panel.close()
        }
        fixtureTranslations = [:]

        let parent = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 650, height: 400), styleMask: [.titled], backing: .buffered, defer: false)
        let input = LauncherInputView(frame: NSRect(x: 20, y: 20, width: 600, height: 350))
        parent.contentView?.addSubview(input)
        input.allowsUndo = true
        input.string = "Existing text"
        input.finishDropInsertion(pieces: ["Speech"], failures: [], at: 0)
        check(input.string == "Speech\n\nExisting text", "Transcript insertion preserves existing text and paragraph separation")
        check(input.undoManager?.canUndo == true, "Imported text participates in undo")
        input.undoManager?.undo()
        check(input.string == "Existing text", "Undo removes the import as one text edit")

        // Check both progress styles and ignore updates after cancellation.
        var completions = 0
        let controller = AudioFileImportController(parent: parent, urls: [], provider: .apple, language: "auto") { _, _ in completions += 1 }
        controller.updateProgress(.init(message: "Uploading", fraction: 0.5))
        check(!controller.progressBar.isIndeterminate && controller.progressBar.doubleValue == 0.5, "Upload progress is determinate")
        controller.fileLabel.stringValue = "1 of 2 · Meeting recording with a longer filename.m4a"
        try snapshot(controller.sheet.contentView!.superview!, name: "audio-import")
        controller.updateProgress(.init(message: "Transcribing"))
        check(controller.progressBar.isIndeterminate, "Recognition without timing uses indeterminate progress")
        controller.cancel(nil)
        controller.cancel(nil)
        controller.updateProgress(.init(message: "Stale result"))
        check(completions == 1 && controller.finished, "Cancellation restores input exactly once")
        check(controller.statusLabel.stringValue == "Transcribing", "Late progress is ignored")

        // Check Pro access before asking for upload permission, even with saved OpenAI preferences.
        proAllowed = false
        let beforeGate = modalCount
        let denied = AudioFileImportController(parent: parent, urls: [root.appendingPathComponent("one.wav")], provider: .openAI, language: "auto") { _, _ in completions += 1 }
        denied.start()
        check(denied.finished && modalCount == beforeGate, "An import without Pro never asks for upload permission")
        proAllowed = true
        modalResponse = .alertSecondButtonReturn
        var imported: [String] = []
        var failures: [String] = []
        let document = root.appendingPathComponent("note.txt")
        try "Document text".write(to: document, atomically: true, encoding: .utf8)
        let mixed = AudioFileImportController(parent: parent, urls: [document, root.appendingPathComponent("one.wav"), root.appendingPathComponent("broken.wav")], provider: .openAI, language: "auto") { imported = $0; failures = $1 }
        mixed.start()
        try await waitFor { mixed.finished }
        check(imported == ["Document text", "Transcribed one.wav"], "Mixed imports preserve drop order and text from successful files")
        check(failures.count == 1 && failures[0].contains("broken.wav"), "A failure identifies the affected recording")
        let slow = AudioFileImportController(parent: parent, urls: [document, root.appendingPathComponent("slow.wav")], provider: .openAI, language: "auto") { imported = $0; failures = $1 }
        slow.start()
        try await Task.sleep(nanoseconds: 100_000_000)
        slow.cancel(nil)
        try await Task.sleep(nanoseconds: 50_000_000)
        check(imported == ["Document text"] && failures.isEmpty, "Cancel keeps completed text and discards the unfinished transcript")

        // Exercise the launcher's real audio branch, including its read-only state and undo insertion.
        do {
            preferences.transcriptionProvider = "openAI"
            input.insertExtractedText(from: [root.appendingPathComponent("one.wav")], at: 0)
            check(input.isImportingFiles && !input.isEditable, "Audio import locks the insertion point until completion")
            try await waitFor { !input.isImportingFiles }
            check(input.isEditable && input.string == "Transcribed one.wav\n\nExisting text", "The launcher restores editing and inserts the completed transcript")
            input.undoManager?.undo()
            check(input.string == "Existing text", "Undo removes a completed audio import in one step")
        }

        // Cancelled Apple work must return before inspecting files or requesting model downloads.
        let cancelled = Task { () -> String in
            try? await Task.sleep(nanoseconds: 1_000_000)
            return try await transcribeAppleAudioFile(root.appendingPathComponent("missing.wav"), language: "auto", progress: { _ in }, approveDownload: { _ in fatalError("Unexpected download") })
        }
        cancelled.cancel()
        do { _ = try await cancelled.value; check(false, "Cancelled recognition must fail") }
        catch is CancellationError { check(true, "Apple cancellation propagates") }
        print("\(checks) audio import checks passed")
        exit(0)
    } catch {
        fputs("FAIL: \(error.localizedDescription)\n", stderr)
        exit(1)
    }
}
RunLoop.main.run()
'''

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--snapshots', type=Path, help='Copy native UI snapshots to this directory')
args = parser.parse_args()
with tempfile.TemporaryDirectory(prefix='langmin-audio-fixture-', dir='/private/tmp') as directory:
    folder = Path(directory)
    translations = []
    for path in sorted((ROOT / 'langmin/Resources').glob('*.lproj/Localizable.strings')):
        values = json.loads(subprocess.check_output(['plutil', '-convert', 'json', '-o', '-', str(path)]))
        translations.append({'locale': path.parent.stem, **{key: value for key, value in values.items()
                            if key.startswith('tab_') or key in ['reset_defaults', 'cancel', 'save']}})
    (folder / 'settings-translations.json').write_text(json.dumps(translations))
    (folder / 'main.swift').write_text(source)
    cache = os.environ.get('LANGMIN_TEST_MODULE_CACHE', str(folder / 'modules'))
    sources = [app_path(name) for name in ['AudioTranscription.swift', 'AudioFileImport.swift', 'TranscriptionSettings.swift']]
    subprocess.run(['swiftc', '-swift-version', '5', '-module-cache-path', cache, *swift_fixture_args(),
                    *map(str, sources), str(folder / 'main.swift'), '-o', str(folder / 'tests')], check=True)
    subprocess.run([str(folder / 'tests'), directory], check=True, timeout=45)
    # Keep rendered settings snapshots only when an output directory was requested.
    if args.snapshots:
        args.snapshots.mkdir(parents=True, exist_ok=True)
        for image in folder.glob('*.png'):
            shutil.copy2(image, args.snapshots / image.name)

// Progress panel for clipboard actions, using public AppKit APIs.

import Cocoa
import QuartzCore
import AVFoundation

// Keep the HUD's geometry and visual constants consistent across its presentation variants.
private enum ClipboardHUDMetrics {
    static let panelWidth: CGFloat = 344
    // Match the vertical button padding to the right inset.
    static let panelHeight: CGFloat = buttonHeight + trailingInset * 2
    static let cardCornerRadius: CGFloat = 18
    static let glassCornerRadius: CGFloat = 16
    static let borderWidth: CGFloat = 1
    // Tint values for a key panel, matched to macOS 26 menu bar menus.
    static let glassDarkTintAlpha: CGFloat = 0.25
    static let glassLightTintAlpha: CGFloat = 0.17
    static let opaqueDarkBlendFraction: CGFloat = 0.15

    static let titleFontSize: CGFloat = 15.4
    static let statusFontSize: CGFloat = 12

    static let progressSize: CGFloat = 13
    static let spinnerRotationDuration: CFTimeInterval = 1.68
    static let spinnerRadiusScale: CGFloat = 0.36
    static let spinnerLineWidth: CGFloat = 3
    static let spinnerTrackAlpha: CGFloat = 0.16
    static let spinnerArcAlpha: CGFloat = 0.85

    static let leadingInset: CGFloat = 18
    static let trailingInset: CGFloat = 10
    static let resultPanelWidth: CGFloat = 480
    static let maximumPanelWidth: CGFloat = 640
    static let resultTextFontSize: CGFloat = 13
    static let resultTextMaxHeight: CGFloat = 240
    static let resultTextTopGap: CGFloat = 10
    static let resultTextBottomInset: CGFloat = 14
    // Leave room for paragraph actions and the overlay scroller.
    static let resultTrailingReserve: CGFloat = 66
    static let statusSpacing: CGFloat = 10
    static let titleDetailSpacing: CGFloat = 8
    static let buttonSpacing: CGFloat = 8
    static let buttonHeight: CGFloat = 26
    static let buttonFontSize: CGFloat = 12.5
    static let buttonHorizontalPadding: CGFloat = 12
    static let topScreenOffset: CGFloat = 28
}

// Adjust text optically without changing the status row's layout.
private final class ClipboardHUDLabel: NSTextField {
    var verticalOffset: CGFloat = 0

    // draw(dirtyRect): Offset label drawing optically without changing its
    // layout or hit area.
    override func draw(_ dirtyRect: NSRect) {
        NSGraphicsContext.saveGraphicsState()
        // Restore the caller's graphics state after drawing this translated symbol.
        defer { NSGraphicsContext.restoreGraphicsState() }
        let offset = NSAffineTransform()
        offset.translateX(by: 0, yBy: isFlipped ? -verticalOffset : verticalOffset)
        offset.concat()
        super.draw(dirtyRect)
    }
}

// Liquid Glass backdrop for macOS 26. The material adapts to the content behind it.
// Live rendering requires a key panel; see ClipboardHUDPanel.
@available(macOS 26.0, *)
private final class ClipboardHUDGlassCardView: NSGlassEffectView {
    let contentContainer = NSView()

    // init(frameRect): Configure native glass with the HUD's corner radius and
    // appearance-aware tint.
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        style = .regular
        cornerRadius = ClipboardHUDMetrics.glassCornerRadius
        tintColor = NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
                ? NSColor.black.withAlphaComponent(ClipboardHUDMetrics.glassDarkTintAlpha)
                : NSColor.white.withAlphaComponent(ClipboardHUDMetrics.glassLightTintAlpha)
        }
        autoresizingMask = [.width, .height]
        // Clip the tint layer to the glass corners so it cannot darken the surrounding rectangle.
        wantsLayer = true
        layer?.cornerRadius = ClipboardHUDMetrics.glassCornerRadius
        layer?.cornerCurve = .continuous
        layer?.masksToBounds = true

        contentContainer.frame = bounds
        contentContainer.autoresizingMask = [.width, .height]
        contentView = contentContainer
    }

    // init?(coder): The HUD glass view is constructed in code with its visual
    // settings.
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}

// Draw the HUD card's border as an overlay that does not intercept interaction.
private final class ClipboardHUDBorderView: NSView {
    override var isOpaque: Bool { false }
    // hitTest(point): Let pointer events pass through the decorative border to
    // the controls underneath.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    // draw(dirtyRect): Draw a rounded outline inset so the full stroke stays
    // inside the card bounds.
    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        let inset = ClipboardHUDMetrics.borderWidth / 2
        let path = NSBezierPath(
            roundedRect: bounds.insetBy(dx: inset, dy: inset),
            xRadius: ClipboardHUDMetrics.cardCornerRadius,
            yRadius: ClipboardHUDMetrics.cardCornerRadius
        )
        path.lineWidth = ClipboardHUDMetrics.borderWidth
        effectiveAppearance.performAsCurrentDrawingAppearance {
            langminControlBorderColor.setStroke()
            path.stroke()
        }
    }

    // viewDidChangeEffectiveAppearance(): Refresh the border when system colors
    // change.
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }
}

// Use active menu vibrancy on older macOS versions, even when the panel is not key.
private final class ClipboardHUDVisualEffectCardView: NSVisualEffectView {
    let contentContainer = NSView()
    private let borderView = ClipboardHUDBorderView()
    private var lastMaskSize: NSSize = .zero

    // init(frameRect): Build a rounded material card with a separate content
    // container and border overlay.
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        material = .menu
        blendingMode = .behindWindow
        state = .active
        autoresizingMask = [.width, .height]

        contentContainer.frame = bounds
        contentContainer.autoresizingMask = [.width, .height]
        borderView.frame = bounds
        borderView.autoresizingMask = [.width, .height]
        addSubview(contentContainer)
        addSubview(borderView)
        updateMaskImage()
    }

    // init?(coder): The material HUD card is constructed in code with its
    // content and mask.
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // layout(): Keep content, border, and rounded material mask aligned after
    // resizing.
    override func layout() {
        super.layout()
        contentContainer.frame = bounds
        borderView.frame = bounds
        updateMaskImage()
    }

    // updateMaskImage(): Regenerate the rounded mask only when the card has a
    // new, nonempty size.
    private func updateMaskImage() {
        // Reuse the previous mask until the card has a different nonempty size.
        guard bounds.size.width > 0, bounds.size.height > 0, bounds.size != lastMaskSize else {
            return
        }
        lastMaskSize = bounds.size
        let image = NSImage(size: bounds.size)
        image.lockFocus()
        NSColor.black.setFill()
        NSBezierPath(
            roundedRect: NSRect(origin: .zero, size: bounds.size),
            xRadius: ClipboardHUDMetrics.cardCornerRadius,
            yRadius: ClipboardHUDMetrics.cardCornerRadius
        ).fill()
        image.unlockFocus()
        image.capInsets = NSEdgeInsets(
            top: ClipboardHUDMetrics.cardCornerRadius,
            left: ClipboardHUDMetrics.cardCornerRadius,
            bottom: ClipboardHUDMetrics.cardCornerRadius,
            right: ClipboardHUDMetrics.cardCornerRadius
        )
        image.resizingMode = .stretch
        maskImage = image
    }
}

// Provide an opaque HUD card when accessibility settings reduce transparency.
private final class ClipboardHUDOpaqueCardView: NSView {
    let contentContainer = NSView()
    private let borderView = ClipboardHUDBorderView()

    // init(frameRect): Create the opaque card's clipped content container and
    // decorative border.
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        autoresizingMask = [.width, .height]
        wantsLayer = true
        layer?.cornerRadius = ClipboardHUDMetrics.cardCornerRadius
        layer?.cornerCurve = .continuous
        layer?.masksToBounds = true
        updateBackgroundColor()
        contentContainer.frame = bounds
        contentContainer.autoresizingMask = [.width, .height]
        borderView.frame = bounds
        borderView.autoresizingMask = [.width, .height]
        addSubview(contentContainer)
        addSubview(borderView)
    }

    // init?(coder): The opaque HUD card is constructed in code with its content
    // layers.
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // viewDidChangeEffectiveAppearance(): Refresh the opaque card's background
    // after an appearance change.
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateBackgroundColor()
    }

    // updateBackgroundColor(): Resolve an opaque background that remains
    // readable in light and dark appearances.
    private func updateBackgroundColor() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            let isDark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            let color = isDark
                ? NSColor.windowBackgroundColor.blended(
                    withFraction: ClipboardHUDMetrics.opaqueDarkBlendFraction,
                    of: .black
                ) ?? NSColor.windowBackgroundColor
                : NSColor.windowBackgroundColor
            layer?.backgroundColor = color.cgColor
        }
    }
}

// Mark body paragraphs as copy targets; exclude language headings.
private extension NSAttributedString.Key {
    static let hudCopyableParagraph = NSAttributedString.Key("langminHUDCopyableParagraph")
}

// The receiving window owns this directory and saves a separate copy in the Library.
struct ClipboardHUDNarration {
    let directory: URL
    let audioURL: URL
    let timings: [NarrationChunkTiming]
    let voice: String?
    let model: String?
}

// Retain completed clips until the HUD is dismissed or ownership moves to a result window.
// Mutable state stays on the main thread; export uses a snapshot of the clips.
final class ClipboardHUDPlayback: NSObject, AVAudioPlayerDelegate, @unchecked Sendable {
    // Retain a completed paragraph's audio and generation details for replay or window transfer.
    private struct Clip: Sendable {
        let text: String
        let voice: String
        let model: String
        let audioURL: URL
    }

    var onFinish: ((Error?) -> Void)?
    private var runID: UUID?
    private var request: NarrationRequestTask?
    private var player: AVAudioPlayer?
    private var temporaryDirectory: URL?
    private var clips: [Int: Clip] = [:]
    private var isPreparing = false
    private var allowsPlayback = true
    private var transferCompletion: ((ClipboardHUDNarration?, Error?) -> Void)?
    private var transferID: UUID?
    private var transferTask: Task<Void, Never>?
    private var transferDirectory: URL?

    var hasNarration: Bool { isPreparing || !clips.isEmpty }

    // deinit(): Cancel pending work and discard cached audio when the playback
    // owner is released.
    deinit { clear() }

    // stop(): Stop the current request or playback without discarding completed
    // clips.
    func stop() {
        runID = nil
        isPreparing = false
        request?.cancel()
        request = nil
        player?.stop()
        player = nil
        // Remove the active request's temporary directory when one was created.
        if let temporaryDirectory {
            try? FileManager.default.removeItem(at: temporaryDirectory)
        }
        temporaryDirectory = nil
    }

    // clear(): Cancel transfer work, stop playback, and discard all retained
    // paragraph audio.
    func clear() {
        transferCompletion = nil
        transferID = nil
        transferTask?.cancel()
        transferTask = nil
        // Discard temporary window-transfer files when clearing narration.
        if let transferDirectory { try? FileManager.default.removeItem(at: transferDirectory) }
        transferDirectory = nil
        stop()
        removeClips()
    }

    // removeClips(): Remove the temporary directories containing cached
    // narration clips.
    private func removeClips() {
        // Remove each cached clip's owned temporary directory.
        for clip in clips.values {
            try? FileManager.default.removeItem(at: clip.audioURL.deletingLastPathComponent())
        }
        clips = [:]
    }

    // play(text, [paragraphLocation = 0]): Play a paragraph on the main thread,
    // reusing available audio or requesting new narration.
    func play(_ text: String, at paragraphLocation: Int = 0) {
        precondition(Thread.isMainThread)
        // Ignore playback actions after narration ownership has left the HUD.
        guard allowsPlayback else { return }
        stop()
        let id = UUID()
        runID = id
        let preferences = loadAppPreferences()
        let voice = preferences.ttsVoice
        let provider = narrationProvider(for: voice)
        let model = ttsModel(forVoice: voice, requestedModel: preferences.ttsModel)
        // Reuse a clip only when paragraph text, voice, and narration model still match.
        if let clip = clips[paragraphLocation], clip.text == text, clip.voice == voice,
           clip.model == narrationModelLabel(provider: provider, model: model) {
            // Try replaying cached audio before considering a new speech request.
            do {
                try playAudio(at: clip.audioURL)
            } catch {
                // Report failure to replay a cached clip through the normal completion path.
                finish(error)
            }
            return
        }
        isPreparing = true
        let allowed = confirmRemoteNarrationSharingIfNeeded(provider: provider)
        // A consent sheet can run the event loop while this HUD is dismissed or replaced.
        guard runID == id else { return }
        // Stop before generation when the user declines required provider access or sharing.
        guard allowed else { finish(); return }

        let apiKey: String
        // Load a credential only for the selected remote speech provider.
        switch provider {
        // Apple speech does not require an API key.
        case .apple: apiKey = ""
        // Use the xAI credential for Grok speech.
        case .grok: apiKey = loadGrokAPIKey()
        // Use the OpenAI credential for OpenAI speech.
        case .openAI: apiKey = loadOpenAIAPIKey()
        }
        // Report a missing remote-provider key before creating a narration request.
        guard provider == .apple || !apiKey.isEmpty else {
            finish(HelperFailure(message: String(
                format: localized("hud_voice_api_key", "Add your %@ API key in Settings to use this voice."),
                provider == .grok ? "xAI" : "OpenAI"
            )))
            return
        }

        // Prepare request-owned temporary output before starting HUD speech generation.
        do {
            let directory = try createLangminTemporaryDirectory(prefix: "hud-playback")
            temporaryDirectory = directory
            let output = directory.appendingPathComponent(provider == .apple ? "speech.caf" : "speech.mp3")
            let completion: (Result<Void, Error>) -> Void = { [weak self] result in
                DispatchQueue.main.async {
                    // Clean up even if cancellation raced with the provider writing its output.
                    guard let self, self.runID == id else {
                        try? FileManager.default.removeItem(at: directory)
                        return
                    }
                    self.request = nil
                    self.isPreparing = false
                    // Validate the completed request before opening its audio for playback.
                    do {
                        try result.get()
                        // Validate the clip before replacing a previous recording of this paragraph.
                        let audio = try AVAudioPlayer(contentsOf: output)
                        // Start playback only while this narration still belongs to the HUD.
                        if self.allowsPlayback {
                            try self.playAudio(audio)
                        }
                        // Remove an older cached clip before replacing the paragraph's audio.
                        if let previous = self.clips[paragraphLocation] {
                            try? FileManager.default.removeItem(at: previous.audioURL.deletingLastPathComponent())
                        }
                        self.clips[paragraphLocation] = Clip(
                            text: text, voice: voice,
                            model: narrationModelLabel(provider: provider, model: model), audioURL: output
                        )
                        self.temporaryDirectory = nil
                        // Complete a pending window transfer as soon as its requested audio becomes available.
                        if self.transferCompletion != nil { self.exportNarration() }
                    } catch {
                        // Report audio preparation or playback failures from the completed request.
                        self.finish(error)
                    }
                }
            }
            // Create a narration task for the selected provider.
            switch provider {
            // Synthesize Apple narration locally.
            case .apple:
                request = try startAppleSpeechRequest(
                    text: text, voiceIdentifier: appleVoiceIdentifier(from: voice),
                    outputURL: output, completion: completion
                )
            // Request Grok speech with its catalog voice ID.
            case .grok:
                request = try startGrokSpeechRequest(
                    apiKey: apiKey, text: text, voiceID: grokVoiceID(from: voice),
                    outputURL: output, completion: completion
                )
            // Request OpenAI speech with the selected model and voice.
            case .openAI:
                request = try startSpeechRequest(
                    apiKey: apiKey, text: text,
                    model: model, voice: voice,
                    outputURL: output, completion: completion
                )
            }
            request?.resume()
        } catch {
            // Report failures that occur before the narration task starts.
            finish(error)
        }
    }

    // finish([error = nil]): Finish playback and either complete a pending
    // window transfer or notify the HUD.
    private func finish(_ error: Error? = nil) {
        stop()
        // A pending window transfer receives completion instead of the HUD playback callback.
        if transferCompletion != nil {
            exportNarration(error: error)
        } else {
            // Notify the HUD when no transfer is waiting for this narration.
            onFinish?(error)
        }
    }

    // playAudio(url): Create an audio player for a completed clip and use the
    // shared playback setup.
    private func playAudio(at url: URL) throws {
        try playAudio(AVAudioPlayer(contentsOf: url))
    }

    // playAudio(audio): Retain and start the player, reporting failure if
    // playback cannot begin.
    private func playAudio(_ audio: AVAudioPlayer) throws {
        audio.delegate = self
        player = audio
        // Treat a player that refuses to start as a playback failure.
        guard audio.play() else {
            throw HelperFailure(message: localized("hud_playback_failed", "Could not play this text"))
        }
    }

    // detachFromHUD(): Open transfers an in-flight request too. It can finish
    // in the window without autoplaying.
    func detachFromHUD() {
        allowsPlayback = false
        onFinish = nil
        player?.stop()
        player = nil
    }

    // prepareForWindow(completion): Detach narration from HUD interaction and
    // prepare completed clips for a result window.
    func prepareForWindow(completion: @escaping (ClipboardHUDNarration?, Error?) -> Void) {
        precondition(Thread.isMainThread)
        detachFromHUD()
        transferCompletion = completion
        // Export immediately when there is no outstanding clip-generation request.
        if !isPreparing { exportNarration() }
    }

    // exportNarration([error = nil]): Export ordered paragraph clips for window
    // transfer, handling empty or failed narration.
    private func exportNarration(error: Error? = nil) {
        // Start at most one export for a pending transfer callback.
        guard let completion = transferCompletion, transferID == nil else { return }
        let orderedClips = clips.sorted { $0.key < $1.key }.map(\.value)
        // Complete without narration when no finished paragraph clips exist.
        guard !orderedClips.isEmpty else {
            transferCompletion = nil
            completion(nil, error)
            return
        }
        let directory: URL
        // Allocate a separate directory for the detached window's narration handoff.
        do {
            directory = try createLangminTemporaryDirectory(prefix: "hud-narration")
        } catch {
            // Report failure to create the transfer directory and clear its pending completion state.
            transferCompletion = nil
            completion(nil, error)
            return
        }
        let id = UUID()
        transferID = id
        transferDirectory = directory
        // A single clip needs no conversion. Several clips become one recording in reading order.
        let audioURL = directory.appendingPathComponent(orderedClips.count == 1
            ? "narration.\(orderedClips[0].audioURL.pathExtension)" : "narration.m4a")
        transferTask = Task { [weak self] in
            // Prepare transferable narration while honoring cancellation during export.
            do {
                try Task.checkCancellation()
                let offsets: [TimeInterval]
                // Copy a single clip directly instead of re-encoding it through a merge.
                if orderedClips.count == 1 {
                    try FileManager.default.copyItem(at: orderedClips[0].audioURL, to: audioURL)
                    offsets = [0]
                } else {
                    // Merge multiple clips and retain their paragraph offsets for window playback.
                    offsets = try await mergeNarrationChunks(orderedClips.map(\.audioURL), to: audioURL)
                }
                try Task.checkCancellation()
                let narration = ClipboardHUDNarration(
                    directory: directory, audioURL: audioURL,
                    timings: zip(offsets, orderedClips).map { NarrationChunkTiming(start: $0, text: $1.text) },
                    voice: Set(orderedClips.map(\.voice)).count == 1 ? orderedClips[0].voice : nil,
                    model: Set(orderedClips.map(\.model)).count == 1 ? orderedClips[0].model : nil
                )
                DispatchQueue.main.async {
                    // Clean up exported files if the transfer was replaced or its owner was released.
                    guard let self, self.transferID == id else {
                        try? FileManager.default.removeItem(at: directory)
                        return
                    }
                    self.transferID = nil
                    self.transferTask = nil
                    self.transferDirectory = nil
                    self.transferCompletion = nil
                    self.removeClips()
                    completion(narration, error)
                }
            } catch {
                // Remove partial transfer files after an export failure.
                try? FileManager.default.removeItem(at: directory)
                DispatchQueue.main.async {
                    // Deliver the failure only to the transfer that is still current.
                    guard let self, self.transferID == id else { return }
                    self.transferID = nil
                    self.transferTask = nil
                    self.transferDirectory = nil
                    self.transferCompletion = nil
                    completion(nil, error)
                }
            }
        }
    }

    // audioPlayerDidFinishPlaying(player, flag): Finish only the current
    // player's playback, ignoring callbacks from replaced players.
    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        // Ignore playback completion from a player that has already been replaced.
        guard self.player === player else { return }
        finish(flag ? nil : HelperFailure(message: localized("hud_playback_failed", "Could not play this text")))
    }

    // audioPlayerDecodeErrorDidOccur(player, error): Report a decoding failure
    // only if it belongs to the current player.
    func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: Error?) {
        // Ignore decode errors from a player that is no longer active.
        guard self.player === player else { return }
        finish(error ?? HelperFailure(message: localized("hud_playback_failed", "Could not play this text")))
    }
}

// Keep Stop beside the playing paragraph even when the pointer moves elsewhere.
private final class ClipboardHUDResultTextView: NSTextView {
    private let copyButton = NSButton()
    private let playButton = NSButton()
    private let stopButton = NSButton()
    private var hoverArea: NSTrackingArea?
    private var hoveredRange: NSRange?
    private var playingRange: NSRange?
    private var restoreWorkItem: DispatchWorkItem?
    var onPlay: ((String, Int) -> Void)?
    var onStop: (() -> Void)?

    // configureParagraphActions(): Configure paragraph copy and playback
    // controls with consistent symbols and actions.
    func configureParagraphActions() {
        copyButton.isBordered = false
        copyButton.bezelStyle = .regularSquare
        copyButton.imagePosition = .imageOnly
        copyButton.image = copyImage(checkmark: false)
        copyButton.contentTintColor = .secondaryLabelColor
        copyButton.target = self
        copyButton.action = #selector(copyHoveredParagraph(_:))
        copyButton.isHidden = true
        copyButton.frame = NSRect(x: 0, y: 0, width: 22, height: 22)
        copyButton.toolTip = localized("copy_paragraph", "Copy this paragraph")
        copyButton.setAccessibilityLabel(localized("copy_paragraph", "Copy this paragraph"))
        addSubview(copyButton)
        // Configure Play and Stop with matching geometry and accessible descriptions.
        for (button, symbol, label, action) in [
            (playButton, "speaker.wave.2", localized("hud_read_paragraph", "Read this paragraph aloud"), #selector(playHoveredParagraph(_:))),
            (stopButton, "stop.fill", localized("hud_stop_playback", "Stop reading"), #selector(stopPlayback(_:)))
        ] {
            button.isBordered = false
            button.bezelStyle = .regularSquare
            button.imagePosition = .imageOnly
            button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)?
                .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 10.5, weight: .medium))
            button.contentTintColor = button === stopButton ? .systemBlue : .secondaryLabelColor
            button.target = self
            button.action = action
            button.isHidden = true
            button.frame = NSRect(x: 0, y: 0, width: 22, height: 22)
            button.toolTip = label
            button.setAccessibilityLabel(label)
            addSubview(button)
        }
    }

    // resetParagraphActions(): Clear hover, copy feedback, and playback
    // controls when the displayed result changes.
    func resetParagraphActions() {
        cancelRestore()
        hoveredRange = nil
        copyButton.isHidden = true
        finishPlayback()
    }

    // finishPlayback(): Reset paragraph playback controls while retaining any
    // current hover selection.
    func finishPlayback() {
        playingRange = nil
        stopButton.isHidden = true
        playButton.isHidden = hoveredRange == nil
    }

    // playHoveredParagraph(sender): Start narration for the hovered paragraph
    // and replace Play with Stop in place.
    @objc private func playHoveredParagraph(_ sender: Any?) {
        // Require a valid hovered paragraph and playback callback before starting speech.
        guard let range = hoveredRange, let text = paragraphText(in: range), let onPlay else { return }
        playingRange = range
        stopButton.frame = playButton.frame
        stopButton.isHidden = false
        playButton.isHidden = true
        onPlay(text, range.location)
    }

    // stopPlayback(sender): Stop the paragraph's narration and restore its idle
    // controls.
    @objc private func stopPlayback(_ sender: Any?) {
        onStop?()
        finishPlayback()
    }

    // paragraphText(range): Read a nonempty paragraph only when its remembered
    // range is still valid.
    private func paragraphText(in range: NSRange) -> String? {
        // Reject stale or empty paragraph ranges before reading text storage.
        guard let storage = textStorage, range.location >= 0, range.length > 0,
              range.location <= storage.length, range.length <= storage.length - range.location else { return nil }
        let text = (storage.string as NSString).substring(with: range)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }

    // copyImage(checkmark): Use matching-sized symbols for the paragraph's Copy
    // and Copied states.
    private func copyImage(checkmark: Bool) -> NSImage? {
        let name = checkmark ? "checkmark" : "doc.on.doc"
        // Leave the icon unset if the requested system symbol is unavailable.
        guard let image = NSImage(
            systemSymbolName: name,
            accessibilityDescription: checkmark ? "Copied" : "Copy paragraph"
        ) else { return nil }
        return image.withSymbolConfiguration(
            NSImage.SymbolConfiguration(pointSize: 10.5, weight: .medium)
        ) ?? image
    }

    // updateTrackingAreas(): Refresh paragraph-action hover tracking for the
    // text view's current bounds.
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        // Replace the prior hover area before tracking the current text-view bounds.
        if let hoverArea { removeTrackingArea(hoverArea) }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        hoverArea = area
    }

    // mouseMoved(event): Keep a hand cursor over paragraph controls and update
    // hover elsewhere in the text.
    override func mouseMoved(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        // Reset the hand cursor here because NSTextView replaces it with an I-beam on mouse movement.
        if [copyButton, playButton, stopButton].contains(where: { !$0.isHidden && $0.frame.contains(point) }) {
            NSCursor.pointingHand.set()
            return
        }
        super.mouseMoved(with: event)
        updateHover(at: point)
    }

    // mouseExited(event): Hide idle paragraph controls when the pointer leaves
    // the result.
    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        hideIfIdle()
    }

    // updateHover(point): Locate the paragraph under the pointer and position
    // its available hover actions.
    private func updateHover(at point: NSPoint) {
        // Require layout and nonempty text before locating paragraph actions.
        guard
            let layoutManager,
            let textContainer,
            let storage = textStorage,
            storage.length > 0
        // Hide idle actions when the text view cannot resolve a paragraph.
        else { hideIfIdle(); return }
        let containerPoint = NSPoint(
            x: point.x - textContainerOrigin.x,
            y: point.y - textContainerOrigin.y
        )
        layoutManager.ensureLayout(for: textContainer)
        let glyphIndex = layoutManager.glyphIndex(for: containerPoint, in: textContainer)
        // Hide actions when the pointer falls beyond the laid-out glyphs.
        guard glyphIndex < layoutManager.numberOfGlyphs else {
            hideIfIdle()
            return
        }
        let charIndex = layoutManager.characterIndexForGlyph(at: glyphIndex)
        // Require a real character whose attributes allow paragraph actions.
        guard
            charIndex < storage.length,
            storage.attribute(.hudCopyableParagraph, at: charIndex, effectiveRange: nil) != nil
        // Hide controls rather than attaching them to invalid or excluded text.
        else {
            hideIfIdle()
            return
        }
        let paragraph = (storage.string as NSString)
            .paragraphRange(for: NSRange(location: charIndex, length: 0))
        // Do not offer copy or speech for an empty paragraph.
        guard paragraphText(in: paragraph) != nil else {
            hideIfIdle()
            return
        }
        let glyphRange = layoutManager.glyphRange(forCharacterRange: paragraph, actualCharacterRange: nil)
        let rect = layoutManager.boundingRect(forGlyphRange: glyphRange, in: textContainer)
            .offsetBy(dx: textContainerOrigin.x, dy: textContainerOrigin.y)
        // Require the pointer to lie within the paragraph's actual vertical bounds.
        guard point.y >= rect.minY, point.y <= rect.maxY else {
            hideIfIdle()
            return
        }
        // Keep existing action positions when the same paragraph is already active.
        if hoveredRange == paragraph, !copyButton.isHidden { return }
        hoveredRange = paragraph
        cancelRestore()
        copyButton.image = copyImage(checkmark: false)
        copyButton.contentTintColor = .secondaryLabelColor
        // Center actions on the first line, including taller fallback fonts for non-Latin text.
        let firstLine = layoutManager.lineFragmentUsedRect(forGlyphAt: glyphRange.location, effectiveRange: nil)
        let actionY = textContainerOrigin.y + firstLine.midY - copyButton.frame.height / 2
        copyButton.setFrameOrigin(NSPoint(x: bounds.width - 34, y: actionY))
        copyButton.isHidden = false
        playButton.setFrameOrigin(NSPoint(x: bounds.width - 60, y: actionY))
        playButton.isHidden = playingRange == paragraph
    }

    // hideIfIdle(): Clear hover-only actions while allowing brief copied
    // feedback to remain visible.
    private func hideIfIdle() {
        hoveredRange = nil
        playButton.isHidden = true
        // Allow copied feedback to finish before hiding its button.
        if restoreWorkItem == nil {
            copyButton.isHidden = true
        }
    }

    // cancelRestore(): Cancel the delayed restoration of the paragraph's Copy
    // icon.
    private func cancelRestore() {
        restoreWorkItem?.cancel()
        restoreWorkItem = nil
    }

    // copyHoveredParagraph(sender): Copy the hovered paragraph and briefly show
    // a confirmation checkmark.
    @objc private func copyHoveredParagraph(_ sender: Any?) {
        // Copy only a still-valid, nonempty hovered paragraph.
        guard let range = hoveredRange, let text = paragraphText(in: range) else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        // Brief checkmark feedback, then back to the copy glyph.
        copyButton.image = copyImage(checkmark: true)
        copyButton.contentTintColor = .systemGreen
        cancelRestore()
        let work = DispatchWorkItem { [weak self] in
            // Ignore the delayed icon reset after the text view is released.
            guard let self else { return }
            self.restoreWorkItem = nil
            self.copyButton.image = self.copyImage(checkmark: false)
            self.copyButton.contentTintColor = .secondaryLabelColor
            // Hide the restored Copy button if the pointer no longer hovers a paragraph.
            if self.hoveredRange == nil {
                self.copyButton.isHidden = true
            }
        }
        restoreWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0, execute: work)
    }
}

// Bordered Cancel/Dismiss buttons and an accent-filled Retry button.
private final class ClipboardHUDCapsuleButton: NSButton {
    // Distinguish a secondary outlined action from the HUD's prominent action.
    enum Style {
        // Use an outlined capsule for secondary HUD actions.
        case bordered
        // Use an accent-filled capsule for the primary HUD action.
        case prominent
    }

    private let style: Style
    private var isHovered = false
    private var capsuleTrackingArea: NSTrackingArea?

    // init(title, style, target, action): Create a custom capsule action using
    // the shared HUD sizing and typography.
    init(title: String, style: Style, target: AnyObject?, action: Selector?) {
        self.style = style
        super.init(frame: .zero)
        self.title = title
        self.target = target
        self.action = action
        isBordered = false
        focusRingType = .none
        translatesAutoresizingMaskIntoConstraints = false
        setAccessibilityLabel(title)
    }

    // init?(coder): HUD capsule buttons require a style and action supplied in
    // code.
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // viewDidChangeEffectiveAppearance(): Refresh outlined actions in an
    // already-visible HUD after an appearance change.
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    private var titleAttributes: [NSAttributedString.Key: Any] {
        let color: NSColor
        // Choose text color according to capsule style and interaction state.
        switch style {
        // Use adaptive label colors for the outlined action, including its disabled state.
        case .bordered:
            color = isEnabled ? (isHovered ? .labelColor : .secondaryLabelColor) : .tertiaryLabelColor
        // Keep text white on the prominent capsule's colored background.
        case .prominent:
            color = .white
        }
        return [
            .font: NSFont.systemFont(ofSize: ClipboardHUDMetrics.buttonFontSize, weight: .medium),
            .foregroundColor: color
        ]
    }

    override var intrinsicContentSize: NSSize {
        let width = ceil((title as NSString).size(withAttributes: titleAttributes).width)
            + ClipboardHUDMetrics.buttonHorizontalPadding * 2
        return NSSize(width: width, height: ClipboardHUDMetrics.buttonHeight)
    }

    // updateTrackingAreas(): Keep capsule hover and cursor tracking aligned
    // with the button's current bounds.
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        // Replace the old capsule hover region after layout changes.
        if let capsuleTrackingArea { removeTrackingArea(capsuleTrackingArea) }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect, .cursorUpdate],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        capsuleTrackingArea = area
    }

    // mouseEntered(event): Show capsule hover feedback and an actionable hand
    // cursor.
    override func mouseEntered(with event: NSEvent) {
        isHovered = true
        needsDisplay = true
        NSCursor.pointingHand.set()
    }

    // cursorUpdate(event): Keep a hand cursor over the capsule action.
    override func cursorUpdate(with event: NSEvent) { NSCursor.pointingHand.set() }

    // mouseExited(event): Remove capsule hover feedback and restore the normal
    // cursor.
    override func mouseExited(with event: NSEvent) {
        isHovered = false
        needsDisplay = true
        NSCursor.arrow.set()
    }

    // draw(dirtyRect): Draw the requested capsule style, pressed state, and
    // centered title.
    override func draw(_ dirtyRect: NSRect) {
        let radius = bounds.height / 2
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: radius, yRadius: radius)
        // Draw the background appropriate to the capsule style.
        switch style {
        // Draw a border and optional hover fill for secondary actions.
        case .bordered:
            // Add hover fill only while the action is enabled.
            if isHovered, isEnabled {
                NSColor.labelColor.withAlphaComponent(0.06).setFill()
                path.fill()
            }
            langminControlBorderColor.setStroke()
            path.lineWidth = 1
            path.stroke()
        // Fill prominent actions with an accent color adjusted for hover and disabled state.
        case .prominent:
            NSColor.controlAccentColor.withAlphaComponent(isEnabled ? (isHovered ? 0.85 : 1) : 0.45).setFill()
            path.fill()
        }
        let text = title as NSString
        let size = text.size(withAttributes: titleAttributes)
        // Center the capital letters in the capsule. In flipped coordinates, the baseline
        // is one ascender below the line's drawing origin.
        let font = titleAttributes[.font] as? NSFont
            ?? NSFont.systemFont(ofSize: ClipboardHUDMetrics.buttonFontSize, weight: .medium)
        let baselineY = (bounds.height + font.capHeight) / 2
        text.draw(
            at: NSPoint(x: (bounds.width - size.width) / 2, y: baselineY - font.ascender),
            withAttributes: titleAttributes
        )
    }
}

// Draw and animate the HUD's circular progress indicator with shape layers.
private final class ClipboardHUDSpinnerView: NSView {
    private let trackLayer = CAShapeLayer()
    private let arcLayer = CAShapeLayer()

    // init(frameRect): Create the spinner's track and arc layers using the
    // shared HUD metrics.
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer = CALayer()
        [trackLayer, arcLayer].forEach { shape in
            shape.fillColor = NSColor.clear.cgColor
            shape.lineWidth = ClipboardHUDMetrics.spinnerLineWidth
            shape.lineCap = .round
            layer?.addSublayer(shape)
        }
        updateColors()
    }

    // init?(coder): The HUD spinner is constructed in code with its shape
    // layers.
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // startAnimation(): Start a fresh rotation unless accessibility preferences
    // request reduced motion.
    func startAnimation() {
        arcLayer.removeAnimation(forKey: "rotation")
        // Leave the spinner static when reduced motion is enabled.
        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { return }
        let animation = CABasicAnimation(keyPath: "transform.rotation.z")
        animation.fromValue = 0
        animation.toValue = CGFloat.pi * 2
        animation.duration = ClipboardHUDMetrics.spinnerRotationDuration
        animation.repeatCount = .infinity
        animation.timingFunction = CAMediaTimingFunction(name: .linear)
        animation.isRemovedOnCompletion = false
        arcLayer.add(animation, forKey: "rotation")
    }

    // stopAnimation(): Remove the active rotation without discarding the
    // spinner layers.
    func stopAnimation() {
        arcLayer.removeAnimation(forKey: "rotation")
    }

    // layout(): Update spinner geometry without animating layout changes.
    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        trackLayer.frame = bounds
        arcLayer.frame = bounds
        let center = CGPoint(x: bounds.midX, y: bounds.midY)
        let radius = min(bounds.width, bounds.height) * ClipboardHUDMetrics.spinnerRadiusScale
        let track = CGMutablePath()
        track.addArc(center: center, radius: radius, startAngle: 0, endAngle: .pi * 2, clockwise: false)
        let arc = CGMutablePath()
        arc.addArc(center: center, radius: radius, startAngle: -.pi / 2, endAngle: .pi * 1.08, clockwise: false)
        trackLayer.path = track
        arcLayer.path = arc
        CATransaction.commit()
    }

    // viewDidChangeEffectiveAppearance(): Refresh spinner colors after a system
    // appearance change.
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateColors()
    }

    // updateColors(): Resolve spinner stroke colors in the view's effective
    // appearance.
    private func updateColors() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            trackLayer.strokeColor = NSColor.labelColor
                .withAlphaComponent(ClipboardHUDMetrics.spinnerTrackAlpha).cgColor
            arcLayer.strokeColor = NSColor.labelColor
                .withAlphaComponent(ClipboardHUDMetrics.spinnerArcAlpha).cgColor
        }
    }
}

// Describe the completed HUD state used to choose its visual feedback.
enum ClipboardHUDCompletionStyle {
    // Show a successful completion state.
    case success
    // Show a neutral informational completion state.
    case neutral
    // Show that the user cancelled the request.
    case cancelled
    // Show a failure that can expose details or retry.
    case failure
}

// A key, nonactivating panel gives NSGlassEffectView its active appearance
// without bringing Langmin to the foreground.
private final class ClipboardHUDPanel: NSPanel {
    // The key panel receives Escape to cancel a request or dismiss an error.
    var onEscape: (() -> Void)?

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    // keyDown(event): Forward Escape to the HUD's current cancellation or
    // dismissal action.
    override func keyDown(with event: NSEvent) {
        // Use the current Escape callback only for an actual Escape key event.
        if event.keyCode == 53, let onEscape {
            onEscape()
            return
        }
        super.keyDown(with: event)
    }

    // cancelOperation(sender): Handle the standard cancel command through the
    // same Escape callback.
    override func cancelOperation(_ sender: Any?) {
        onEscape?()
    }
}

// Own one token-scoped HUD request, including progress, result actions, playback, and dismissal.
final class ClipboardProgressHUDController: NSObject {
    private var panel: NSPanel?
    private var titleLabel: NSTextField?
    private var statusLabel: NSTextField?
    private var spinner: ClipboardHUDSpinnerView?
    private var stateIcon: NSImageView?
    private var cancelButton: ClipboardHUDCapsuleButton?
    private var dismissButton: ClipboardHUDCapsuleButton?
    private var retryButton: ClipboardHUDCapsuleButton?
    private var resultSeparator: NSBox?
    private var resultScroll: NSScrollView?
    private var resultTextView: ClipboardHUDResultTextView?
    // Keep Markdown so rebuilding the card does not discard link destinations or emphasis.
    private var resultMarkdown: String?
    private var playback = ClipboardHUDPlayback()
    private var resultHeightConstraint: NSLayoutConstraint?
    private var cancelAction: (() -> Void)?
    private var retryAction: (() -> Void)?
    private var openAction: ((ClipboardHUDPlayback) -> Void)?
    private var openButton: ClipboardHUDCapsuleButton?
    private var dismissalWorkItem: DispatchWorkItem?
    private var activeToken: UUID?
    private var failureMessage: String?
    private var builtForReducedTransparency: Bool?
    private weak var activeScreen: NSScreen?

    var onBecameInactive: (() -> Void)?
    var isActive: Bool { activeToken != nil }

    // isCurrent(token): Reject absent or superseded request tokens before
    // updating shared HUD state.
    func isCurrent(token: UUID?) -> Bool {
        // An absent token cannot identify the active request.
        guard let token else { return false }
        return activeToken == token
    }

    // init(): Observe accessibility and display changes that can affect an
    // active HUD.
    override init() {
        super.init()
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(accessibilityDisplayOptionsChanged(_:)),
            name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(screenParametersChanged(_:)),
            name: NSApplication.didChangeScreenParametersNotification,
            object: nil
        )
    }

    // deinit(): Remove workspace and application notifications before releasing
    // the HUD controller.
    deinit {
        NSWorkspace.shared.notificationCenter.removeObserver(self)
        NotificationCenter.default.removeObserver(self)
    }

    @discardableResult
    // begin(title, modelName, status, screen, cancel): Replace previous HUD
    // state and begin a new request on the selected screen.
    func begin(
        title: String,
        modelName: String,
        status: String,
        screen: NSScreen?,
        cancel: @escaping () -> Void
    ) -> UUID {
        precondition(Thread.isMainThread)
        ensurePanel()
        dismissalWorkItem?.cancel()
        dismissalWorkItem = nil

        let token = UUID()
        activeToken = token
        cancelAction = cancel
        retryAction = nil
        failureMessage = nil
        // Describe the active mode and model, including their accessible
        // labels.
        titleLabel?.stringValue = title
        titleLabel?.toolTip = title
        statusLabel?.stringValue = modelName
        statusLabel?.isHidden = modelName.isEmpty
        statusLabel?.toolTip = modelName
        statusLabel?.setAccessibilityLabel("Model")
        statusLabel?.setAccessibilityValue(modelName)
        statusLabel?.setAccessibilityHelp(status)
        // Replace any completion state with progress and cancellation controls.
        stateIcon?.isHidden = true
        stateIcon?.toolTip = nil
        stateIcon?.setAccessibilityLabel(nil)
        spinner?.isHidden = false
        spinner?.startAnimation()
        cancelButton?.isHidden = false
        cancelButton?.isEnabled = true
        dismissButton?.isHidden = true
        retryButton?.isHidden = true
        openButton?.isHidden = true
        // Clear the previous result before presenting this request.
        openAction = nil
        setResult(nil)
        positionPanel(on: screen)
        showPanel()
        announce("\(title). \(modelName). \(status)")
        return token
    }

    // playParagraph(text, location): Start paragraph playback with callbacks
    // scoped to the currently displayed result token.
    private func playParagraph(_ text: String, at location: Int) {
        // Do not begin paragraph playback without an active HUD result.
        guard let token = activeToken else { return }
        playback.onFinish = { [weak self] error in
            // Ignore playback callbacks after another request replaces this HUD.
            guard let self, self.activeToken == token else { return }
            self.resultTextView?.finishPlayback()
            // Show playback errors only while the related result panel remains visible.
            guard let error, let panel = self.panel, panel.isVisible else { return }
            let alert = NSAlert()
            alert.messageText = localized("hud_playback_failed", "Could not play this text")
            alert.informativeText = error.localizedDescription
            alert.beginSheetModal(for: panel)
        }
        playback.play(text, at: location)
    }

    // stopPlayback(): Stop narration and restore the result's paragraph
    // playback controls.
    private func stopPlayback() {
        playback.stop()
        resultTextView?.finishPlayback()
    }

    // contentWidth(expanded): Fit the visible header before wrapping the body,
    // including long model names and translations.
    private func contentWidth(expanded: Bool) -> CGFloat {
        var widths: [CGFloat] = []
        // Reserve width for the progress indicator or completion icon only while visible.
        if spinner?.isHidden == false || stateIcon?.isHidden == false {
            widths.append(ClipboardHUDMetrics.progressSize)
        }
        // Measure visible, nonempty labels for the HUD's required width.
        for label in [titleLabel, statusLabel].compactMap({ $0 }) where !label.isHidden && !label.stringValue.isEmpty {
            widths.append(ceil((label.stringValue as NSString).size(withAttributes: [.font: label.font ?? NSFont.systemFont(ofSize: 13)]).width))
        }
        // Include only visible action buttons in the width calculation.
        for button in [cancelButton, openButton, dismissButton, retryButton].compactMap({ $0 }) where !button.isHidden {
            widths.append(button.intrinsicContentSize.width)
        }
        // Include the flexible spacer and the icon's slightly wider spacing.
        let needed = widths.reduce(0, +) + CGFloat(widths.count) * ClipboardHUDMetrics.buttonSpacing
            + ClipboardHUDMetrics.leadingInset + ClipboardHUDMetrics.trailingInset + 4
        let minimum = expanded ? ClipboardHUDMetrics.resultPanelWidth : ClipboardHUDMetrics.panelWidth
        let screenWidth = (activeScreen ?? NSScreen.main)?.visibleFrame.width ?? ClipboardHUDMetrics.maximumPanelWidth + 32
        return min(max(minimum, needed), ClipboardHUDMetrics.maximumPanelWidth, max(1, screenWidth - 32))
    }

    // setResult(text, [preservingNarration = false]): Resize for the result or
    // plain error text while keeping the panel at the screen's top center.
    private func setResult(_ text: String?, preservingNarration: Bool = false) {
        resultMarkdown = text
        stopPlayback()
        // Clear old narration unless the caller is preserving it during a panel rebuild.
        if !preservingNarration { playback.clear() }
        resultTextView?.resetParagraphActions()
        let content = failureMessage ?? text
        let hasContent = !(content ?? "").isEmpty
        resultSeparator?.isHidden = !hasContent
        resultScroll?.isHidden = !hasContent
        let width = contentWidth(expanded: hasContent)
        var height = ClipboardHUDMetrics.panelHeight
        // Lay out a result body only when nonempty content was supplied.
        if let content, hasContent {
            let textWidth = width - ClipboardHUDMetrics.leadingInset * 2
            // Reserve the same width when measuring and drawing, so the scroller
            // and paragraph actions do not cover text.
            let scrollerReserve = failureMessage == nil ? ClipboardHUDMetrics.resultTrailingReserve : 12
            resultTextView?.textContainer?.exclusionPaths = [
                NSBezierPath(rect: NSRect(
                    x: textWidth - scrollerReserve,
                    y: 0,
                    width: scrollerReserve,
                    height: CGFloat.greatestFiniteMagnitude
                ))
            ]
            // Errors are selectable plain text, without Markdown or narration actions.
            let rendered: NSAttributedString
            // Render failure details as readable text instead of interpreting them as a generated result.
            if failureMessage != nil {
                let paragraph = NSMutableParagraphStyle()
                paragraph.lineSpacing = 2
                rendered = NSAttributedString(string: content, attributes: [
                    .font: NSFont.systemFont(ofSize: ClipboardHUDMetrics.resultTextFontSize),
                    .foregroundColor: NSColor.labelColor, .paragraphStyle: paragraph
                ])
            } else {
                // Use result formatting for successful content.
                rendered = renderedResult(content)
            }
            // Measure with the same text layout engine and padding as the displayed body.
            let storage = NSTextStorage(attributedString: rendered)
            let layout = NSLayoutManager()
            let container = NSTextContainer(size: NSSize(width: textWidth - scrollerReserve, height: .greatestFiniteMagnitude))
            container.lineFragmentPadding = 0
            storage.addLayoutManager(layout)
            layout.addTextContainer(container)
            layout.ensureLayout(for: container)
            let measured = layout.usedRect(for: container).height
            let textHeight = min(ceil(measured) + 4, ClipboardHUDMetrics.resultTextMaxHeight)
            resultHeightConstraint?.constant = textHeight
            resultTextView?.textStorage?.setAttributedString(rendered)
            height += 1 + ClipboardHUDMetrics.resultTextTopGap + textHeight
                + ClipboardHUDMetrics.resultTextBottomInset
        } else {
            // Collapse the body area when the HUD has no result content.
            resultHeightConstraint?.constant = 0
            resultTextView?.string = ""
        }
        panel?.setContentSize(NSSize(width: width, height: height))
        positionPanel(on: activeScreen)
    }

    // renderedResult(raw): Render compact result blocks with clickable links
    // and aligned list continuations.
    private func renderedResult(_ raw: String) -> NSAttributedString {
        let cleaned = normalizedGeneratedMarkdown(raw)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let out = NSMutableAttributedString()
        let bodyFont = NSFont.systemFont(ofSize: ClipboardHUDMetrics.resultTextFontSize)
        let bodyStyle = NSMutableParagraphStyle()
        bodyStyle.paragraphSpacing = 8
        bodyStyle.lineSpacing = 2
        let headingStyle = NSMutableParagraphStyle()
        headingStyle.paragraphSpacingBefore = 9
        headingStyle.paragraphSpacing = 4

        // Render the compact HUD Markdown one source line at a time.
        for line in cleaned.components(separatedBy: "\n") {
            var trimmed = line.trimmingCharacters(in: .whitespaces)
            // Skip empty lines before appending compact result blocks.
            guard !trimmed.isEmpty else { continue }

            // Recognize hash-prefixed headings for the HUD's compact typography.
            let headingMarks = trimmed.prefix { $0 == "#" }.count
            // Render recognized headings separately from ordinary paragraphs.
            if (1...6).contains(headingMarks), trimmed.dropFirst(headingMarks).first == " " {
                let heading = trimmed.dropFirst(headingMarks).trimmingCharacters(in: .whitespaces)
                out.append(inlineResult(heading, attributes: [
                        .font: NSFont.monospacedSystemFont(ofSize: 10.5, weight: .semibold),
                        .foregroundColor: NSColor.secondaryLabelColor,
                        .kern: 1.1,
                        .paragraphStyle: out.length == 0 ? bodyStyle : headingStyle
                    ], uppercase: true))
                continue
            }

            let paragraphStyle = bodyStyle.mutableCopy() as! NSMutableParagraphStyle
            var prefix = ""
            // Hang wrapped bullets, numbered items, and source entries beneath their text.
            if let markerRange = trimmed.range(of: #"^(?:[-*+]|[0-9]+[.)]|\[[0-9]{1,3}\])\s+"#, options: .regularExpression) {
                let marker = trimmed[markerRange].trimmingCharacters(in: .whitespaces)
                prefix = (["-", "*", "+"].contains(marker) ? "•" : marker) + "\t"
                trimmed.removeSubrange(markerRange)
                paragraphStyle.headIndent = (String(prefix.dropLast()) as NSString).size(withAttributes: [.font: bodyFont]).width + 7
                paragraphStyle.tabStops = [NSTextTab(textAlignment: .left, location: paragraphStyle.headIndent)]
            } else if trimmed.hasPrefix("> ") {
                // Indent quotations without displaying Markdown's marker as body text.
                trimmed = String(trimmed.dropFirst(2))
                paragraphStyle.firstLineHeadIndent = 12
                paragraphStyle.headIndent = 12
            }
            let attributes: [NSAttributedString.Key: Any] = [
                .font: bodyFont, .foregroundColor: NSColor.labelColor,
                .paragraphStyle: paragraphStyle, .hudCopyableParagraph: true
            ]
            out.append(NSAttributedString(string: prefix, attributes: attributes))
            out.append(inlineResult(trimmed, attributes: attributes))
        }
        return out
    }

    // inlineResult(text, attributes, [uppercase = false]): Let Foundation parse
    // escaped labels, balanced link URLs, emphasis, and inline code.
    private func inlineResult(_ text: String, attributes: [NSAttributedString.Key: Any], uppercase: Bool = false) -> NSAttributedString {
        let parsed = (try? AttributedString(markdown: text, options: .init(
            interpretedSyntax: .inlineOnlyPreservingWhitespace,
            failurePolicy: .returnPartiallyParsedIfPossible
        ))) ?? AttributedString(text)
        let result = NSMutableAttributedString()
        let baseFont = attributes[.font] as! NSFont
        for run in parsed.runs {
            var style = attributes
            let intent = run.inlinePresentationIntent ?? []
            var font = baseFont
            // Compose font traits without losing nested bold/italic or literal code spans.
            if intent.contains(.code) {
                font = NSFont.monospacedSystemFont(ofSize: baseFont.pointSize, weight: .regular)
                style[.backgroundColor] = NSColor.quaternaryLabelColor
            } else if intent.contains(.stronglyEmphasized) {
                // Use a heavier font for bold spans that are not literal code.
                font = NSFont.systemFont(ofSize: baseFont.pointSize, weight: .semibold)
            }
            // Add italic styling while preserving the selected font weight.
            if intent.contains(.emphasized) { font = NSFontManager.shared.convert(font, toHaveTrait: .italicFontMask) }
            style[.font] = font
            // Preserve Markdown strikethrough in the compact result.
            if intent.contains(.strikethrough) { style[.strikethroughStyle] = NSUnderlineStyle.single.rawValue }
            // Generated text may link to web pages or email, never executable or app-internal URLs.
            if let url = run.link, let scheme = url.scheme?.lowercased(),
               ["https", "http", "mailto"].contains(scheme), scheme == "mailto" || url.host?.isEmpty == false {
                style[.link] = url
                style[.foregroundColor] = NSColor.linkColor
                style[.underlineStyle] = NSUnderlineStyle.single.rawValue
            }
            let value = String(parsed[run.range].characters)
            result.append(NSAttributedString(string: uppercase ? value.uppercased() : value, attributes: style))
        }
        result.append(NSAttributedString(string: "\n", attributes: attributes))
        return result
    }

    // update(token, status): Update accessible progress information only for
    // the active request token.
    func update(token: UUID?, status: String) {
        precondition(Thread.isMainThread)
        // Update only the progress token currently owned by this HUD.
        guard let token, activeToken == token else { return }
        // Keep the model visible; expose changing progress to assistive technology.
        statusLabel?.setAccessibilityHelp(status)
    }

    // setCancellationAvailable(token, available): Show and enable cancellation
    // only when the current request still supports it.
    func setCancellationAvailable(token: UUID?, _ available: Bool) {
        precondition(Thread.isMainThread)
        // Change cancellation controls only for the current request.
        guard let token, activeToken == token else { return }
        cancelButton?.isHidden = !available
        cancelButton?.isEnabled = available
        // Discard the cancel callback when cancellation is no longer available.
        if !available { cancelAction = nil }
    }

    // suspend(token): Stop playback and temporarily hide the current HUD
    // without ending its request.
    func suspend(token: UUID?) {
        precondition(Thread.isMainThread)
        // Suspend only the request currently represented by the HUD.
        guard let token, activeToken == token else { return }
        stopPlayback()
        panel?.orderOut(nil)
    }

    // resume(token, status): Refresh and redisplay a suspended HUD only if its
    // request token is still current.
    func resume(token: UUID?, status: String) {
        precondition(Thread.isMainThread)
        // Resume only a request that has not been superseded.
        guard let token, activeToken == token else { return }
        update(token: token, status: status)
        positionPanel(on: activeScreen)
        showPanel()
    }

    // complete(token, message, [detail = nil], style, delay, [retry = nil],
    // [resultText = nil], [open = nil]): Replace progress with a completion
    // state and its available dismissal, retry, or open actions.
    func complete(
        token: UUID?,
        message: String,
        detail: String? = nil,
        style: ClipboardHUDCompletionStyle,
        dismissAfter delay: TimeInterval,
        retry: (() -> Void)? = nil,
        resultText: String? = nil,
        open: ((ClipboardHUDPlayback) -> Void)? = nil
    ) {
        precondition(Thread.isMainThread)
        // Ignore completion for an absent or obsolete HUD token.
        guard let token, activeToken == token else { return }
        spinner?.stopAnimation()
        spinner?.isHidden = true
        let isFailure = style == .failure
        let failureDetail = detail.map { "\(message)\n\n\($0)" } ?? message
        failureMessage = isFailure ? failureDetail : nil
        stateIcon?.image = completionImage(for: style)
        stateIcon?.contentTintColor = completionTint(for: style)
        stateIcon?.isHidden = false
        stateIcon?.toolTip = isFailure ? failureDetail : message
        stateIcon?.setAccessibilityLabel(isFailure ? failureDetail : message)
        titleLabel?.stringValue = isFailure ? localized("request_failed", "Request failed") : message
        titleLabel?.toolTip = message
        statusLabel?.stringValue = isFailure ? "" : detail ?? ""
        statusLabel?.isHidden = isFailure || (detail ?? "").isEmpty
        statusLabel?.toolTip = detail
        statusLabel?.setAccessibilityLabel("Status")
        statusLabel?.setAccessibilityValue(detail ?? message)
        statusLabel?.setAccessibilityHelp(nil)
        cancelButton?.isHidden = true
        cancelAction = nil
        // Errors and inline results stay open until dismissed. Other completion states close
        // automatically.
        retryAction = retry
        let hasResult = !(resultText ?? "").isEmpty
        openAction = hasResult ? open : nil
        openButton?.isHidden = !(hasResult && open != nil)
        dismissButton?.isHidden = !(isFailure || hasResult)
        retryButton?.isHidden = !(isFailure && retry != nil)
        setResult(hasResult ? resultText : nil)
        announce(detail.map { "\(message). \($0)" } ?? message)
        // Keep failures and readable results visible until the user acts.
        if isFailure || hasResult {
            dismissalWorkItem?.cancel()
            dismissalWorkItem = nil
        } else {
            // Automatically dismiss short completion notices after their configured delay.
            scheduleDismissal(token: token, after: delay)
        }
        // Return focus immediately after copying so Command-V works while the notice is visible.
        // Errors and inline results keep focus so Escape can dismiss them.
        if !isFailure, !hasResult {
            releaseKeyStatus()
        } else if hasResult {
            // Keep a completed result key so its text and actions remain keyboard-accessible.
            panel?.makeKeyAndOrderFront(nil)
        }
    }

    // releaseKeyStatus(): Hide and reshow the panel without making it key,
    // returning keyboard focus to the source app.
    private func releaseKeyStatus() {
        // Release keyboard focus only when this HUD panel currently owns it.
        guard let panel, panel.isKeyWindow else { return }
        let frame = panel.frame
        let alpha = panel.alphaValue
        panel.orderOut(nil)
        panel.setFrame(frame, display: false)
        panel.alphaValue = alpha
        panel.orderFrontRegardless()
    }

    // dismiss(token, [animated = true]): Stop playback, clear retained clips,
    // and dismiss only the current HUD request.
    func dismiss(token: UUID?, animated: Bool = true) {
        precondition(Thread.isMainThread)
        // Dismiss only the current request, leaving a newer HUD untouched.
        guard let token, activeToken == token else { return }
        stopPlayback()
        playback.clear()
        dismissalWorkItem?.cancel()
        dismissalWorkItem = nil
        activeToken = nil
        activeScreen = nil
        cancelAction = nil
        retryAction = nil
        openAction = nil
        resultMarkdown = nil
        spinner?.stopAnimation()

        // Hide immediately when animation is disabled or reduced motion is requested.
        guard animated, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else {
            panel?.orderOut(nil)
            panel?.alphaValue = 1
            notifyBecameInactive()
            return
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.14
            panel?.animator().alphaValue = 0
        } completionHandler: { [weak self] in
            DispatchQueue.main.async {
                // Skip delayed dismissal work after the HUD controller has been released.
                guard let self else { return }
                // Do not let a fading completion hide a newer request's panel.
                guard self.activeToken == nil else {
                    self.panel?.alphaValue = 1
                    return
                }
                self.panel?.orderOut(nil)
                self.panel?.alphaValue = 1
                self.notifyBecameInactive()
            }
        }
    }

    // accessibilityDisplayOptionsChanged(notification): Adapt an active HUD to
    // changed transparency or motion preferences.
    @objc private func accessibilityDisplayOptionsChanged(_ notification: Notification) {
        precondition(Thread.isMainThread)
        // Accessibility changes require no HUD work while the controller is idle.
        guard activeToken != nil else { return }

        let reduceTransparency = NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency
        // Rebuild the card when the transparency preference changes its required material.
        if builtForReducedTransparency != reduceTransparency {
            let title = titleLabel?.stringValue ?? ""
            let titleToolTip = titleLabel?.toolTip
            let status = statusLabel?.stringValue ?? ""
            let statusHidden = statusLabel?.isHidden ?? false
            let detailLabel = statusLabel?.accessibilityLabel()
            let detailHelp = statusLabel?.accessibilityHelp()
            let detailToolTip = statusLabel?.toolTip
            // Capture the activity indicator and action states before
            // rebuilding the panel.
            let spinnerHidden = spinner?.isHidden ?? false
            let stateImage = stateIcon?.image
            let stateTint = stateIcon?.contentTintColor
            let stateHidden = stateIcon?.isHidden ?? true
            let stateToolTip = stateIcon?.toolTip
            let stateAccessibilityLabel = stateIcon?.accessibilityLabel()
            let cancelHidden = cancelButton?.isHidden ?? false
            let cancelEnabled = cancelButton?.isEnabled ?? true
            let dismissHidden = dismissButton?.isHidden ?? true
            let retryHidden = retryButton?.isHidden ?? true
            let openHidden = openButton?.isHidden ?? true
            let resultText = resultScroll?.isHidden == false ? resultMarkdown : nil
            let wasVisible = panel?.isVisible ?? false
            let screen = activeScreen

            // Restore the visible request and accessibility text in the rebuilt
            // panel.
            ensurePanel()
            titleLabel?.stringValue = title
            titleLabel?.toolTip = titleToolTip
            statusLabel?.stringValue = status
            statusLabel?.isHidden = statusHidden
            statusLabel?.toolTip = detailToolTip
            statusLabel?.setAccessibilityLabel(detailLabel)
            statusLabel?.setAccessibilityValue(status)
            statusLabel?.setAccessibilityHelp(detailHelp)
            // Restore progress and actions without interrupting retained
            // narration.
            spinner?.isHidden = spinnerHidden
            stateIcon?.image = stateImage
            stateIcon?.contentTintColor = stateTint
            stateIcon?.isHidden = stateHidden
            stateIcon?.toolTip = stateToolTip
            stateIcon?.setAccessibilityLabel(stateAccessibilityLabel)
            cancelButton?.isHidden = cancelHidden
            cancelButton?.isEnabled = cancelEnabled
            dismissButton?.isHidden = dismissHidden
            retryButton?.isHidden = retryHidden
            openButton?.isHidden = openHidden
            setResult(resultText, preservingNarration: true)
            positionPanel(on: screen)
            // Redisplay a rebuilt panel only if the previous one was visible.
            if wasVisible { showPanel() }
        }

        // Restart progress animation only when the spinner is currently shown.
        if spinner?.isHidden == false {
            spinner?.startAnimation()
        }
        // Remove any intermediate animation opacity when reduced motion becomes enabled.
        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            panel?.alphaValue = 1
        }
    }

    // screenParametersChanged(notification): Reposition an active HUD when the
    // connected display arrangement changes.
    @objc private func screenParametersChanged(_ notification: Notification) {
        precondition(Thread.isMainThread)
        // Reposition only an active HUD after display changes.
        guard activeToken != nil else { return }
        positionPanel(on: activeScreen)
    }

    // cancelPressed(sender): Disable repeated cancellation clicks and show that
    // cancellation is underway.
    @objc private func cancelPressed(_ sender: Any?) {
        // Ignore cancellation clicks after the request has already ended.
        guard activeToken != nil else { return }
        cancelButton?.isEnabled = false
        titleLabel?.stringValue = localized("cancelling", "Cancelling…")
        statusLabel?.setAccessibilityHelp(localized("cancelling_a11y", "Cancelling"))
        cancelAction?()
    }

    // dismissPressed(sender): Dismiss the HUD through its current request
    // token.
    @objc private func dismissPressed(_ sender: Any?) {
        dismiss(token: activeToken)
    }

    // retryPressed(sender): Consume the stored retry action once and dismiss
    // the old HUD before starting it.
    @objc private func retryPressed(_ sender: Any?) {
        // Retry only when an active completion still owns a retry action.
        guard activeToken != nil, let retry = retryAction else { return }
        retryAction = nil
        dismiss(token: activeToken, animated: false)
        retry()
    }

    // openPressed(sender): Transfer narration ownership before opening the
    // result in its own window.
    @objc private func openPressed(_ sender: Any?) {
        // Open only when the active completion still owns its result action.
        guard activeToken != nil, let open = openAction else { return }
        openAction = nil
        let narration = playback
        narration.detachFromHUD()
        playback = ClipboardHUDPlayback()
        dismiss(token: activeToken, animated: false)
        open(narration)
    }

    // ensurePanel(): Reuse the existing panel only when its transparency mode
    // matches current accessibility settings.
    private func ensurePanel() {
        let reduceTransparency = NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency
        // Reuse a panel already built for the current transparency preference.
        if panel != nil, builtForReducedTransparency == reduceTransparency { return }
        stopPlayback()
        panel?.orderOut(nil)
        panel = nil
        builtForReducedTransparency = reduceTransparency
        buildPanel(reduceTransparency: reduceTransparency)
    }

    // buildPanel(reduceTransparency): Construct the HUD panel, its
    // accessibility-appropriate card, and its result controls.
    private func buildPanel(reduceTransparency: Bool) {
        let frame = NSRect(
            x: 0,
            y: 0,
            width: ClipboardHUDMetrics.panelWidth,
            height: ClipboardHUDMetrics.panelHeight
        )
        let panel = ClipboardHUDPanel(
            contentRect: frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.backgroundColor = .clear
        panel.collectionBehavior = [
            .canJoinAllSpaces,
            .canJoinAllApplications,
            .fullScreenAuxiliary,
            .transient,
            .ignoresCycle
        ]
        panel.becomesKeyOnlyIfNeeded = true
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.ignoresMouseEvents = false
        panel.isFloatingPanel = true
        panel.isOpaque = false
        panel.level = .floating
        panel.isReleasedWhenClosed = false
        panel.acceptsMouseMovedEvents = true
        panel.animationBehavior = .none
        panel.setAccessibilityLabel("Langmin progress")

        let card: NSView
        let container: NSView
        // Use an opaque card when the user requests reduced transparency.
        if reduceTransparency {
            let opaque = ClipboardHUDOpaqueCardView(frame: frame)
            card = opaque
            container = opaque.contentContainer
        } else if #available(macOS 26.0, *) {
            // Use native glass on macOS versions that provide it.
            let glass = ClipboardHUDGlassCardView(frame: frame)
            card = glass
            container = glass.contentContainer
        } else {
            // Use the visual-effect material on older supported macOS versions.
            let visualEffect = ClipboardHUDVisualEffectCardView(frame: frame)
            card = visualEffect
            container = visualEffect.contentContainer
        }
        panel.onEscape = { [weak self] in
            self?.escapePressed()
        }
        panel.contentView = card
        buildContent(in: container)
        self.panel = panel
    }

    // escapePressed(): Escape cancels the request or dismisses the result or
    // error, matching the visible buttons.
    private func escapePressed() {
        // Ignore Escape after the HUD request has ended.
        guard activeToken != nil else { return }
        // Escape cancels a running request while its Cancel action remains enabled.
        if cancelButton?.isHidden == false, cancelButton?.isEnabled == true {
            cancelPressed(nil)
        } else if dismissButton?.isHidden == false {
            // Otherwise Escape dismisses a completed result when Dismiss is available.
            dismissPressed(nil)
        }
    }

    // buildContent(container): Build the status row: progress icon, title,
    // detail and action buttons.
    private func buildContent(in container: NSView) {
        let titleLabel = label("", size: ClipboardHUDMetrics.titleFontSize, weight: .semibold)
        titleLabel.verticalOffset = 0.5
        titleLabel.textColor = NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? .white : .labelColor
        }
        titleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        titleLabel.setContentHuggingPriority(.defaultHigh, for: .horizontal)

        let statusLabel = label("", size: ClipboardHUDMetrics.statusFontSize, weight: .regular)
        statusLabel.verticalOffset = -0.25
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.setAccessibilityLabel("Status")

        let spinner = ClipboardHUDSpinnerView(frame: NSRect(
            x: 0,
            y: 0,
            width: ClipboardHUDMetrics.progressSize,
            height: ClipboardHUDMetrics.progressSize
        ))
        let stateIcon = NSImageView()
        stateIcon.translatesAutoresizingMaskIntoConstraints = false
        stateIcon.imageScaling = .scaleProportionallyDown
        stateIcon.contentTintColor = .secondaryLabelColor
        stateIcon.isHidden = true

        let cancelButton = ClipboardHUDCapsuleButton(
            title: localized("cancel", "Cancel"),
            style: .bordered,
            target: self,
            action: #selector(cancelPressed(_:))
        )
        cancelButton.toolTip = localized("cancel_this_request_esc", "Cancel this request (Esc)")
        cancelButton.setAccessibilityHelp("Stops the current Langmin clipboard action")

        // Detaches an inline result into a full result window.
        let openButton = ClipboardHUDCapsuleButton(
            title: localized("open_in_window", "Open"),
            style: .bordered,
            target: self,
            action: #selector(openPressed(_:))
        )
        openButton.toolTip = localized("open_result_window", "Open in a result window")
        openButton.isHidden = true

        let dismissButton = ClipboardHUDCapsuleButton(
            title: localized("dismiss", "Dismiss"),
            style: .bordered,
            target: self,
            action: #selector(dismissPressed(_:))
        )
        dismissButton.isHidden = true

        let retryButton = ClipboardHUDCapsuleButton(
            title: localized("retry", "Retry"),
            style: .prominent,
            target: self,
            action: #selector(retryPressed(_:))
        )
        retryButton.isHidden = true

        let row = NSStackView(views: [
            spinner,
            stateIcon,
            titleLabel,
            statusLabel,
            NSView(),
            cancelButton,
            openButton,
            dismissButton,
            retryButton
        ])
        row.alignment = .centerY
        row.orientation = .horizontal
        row.spacing = ClipboardHUDMetrics.buttonSpacing
        row.setCustomSpacing(ClipboardHUDMetrics.statusSpacing, after: spinner)
        row.setCustomSpacing(ClipboardHUDMetrics.statusSpacing, after: stateIcon)
        row.setCustomSpacing(ClipboardHUDMetrics.titleDetailSpacing, after: titleLabel)
        row.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(row)

        // Place reading results and full error messages below the status row.
        let resultSeparator = NativeSeparator()
        resultSeparator.boxType = .separator
        resultSeparator.isHidden = true
        resultSeparator.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(resultSeparator)

        let resultTextView = ClipboardHUDResultTextView()
        resultTextView.configureParagraphActions()
        resultTextView.onPlay = { [weak self] text, location in self?.playParagraph(text, at: location) }
        resultTextView.onStop = { [weak self] in self?.stopPlayback() }
        resultTextView.isEditable = false
        resultTextView.isSelectable = true
        resultTextView.drawsBackground = false
        resultTextView.font = NSFont.systemFont(ofSize: ClipboardHUDMetrics.resultTextFontSize)
        resultTextView.textColor = .labelColor
        resultTextView.linkTextAttributes = [.foregroundColor: NSColor.linkColor, .underlineStyle: NSUnderlineStyle.single.rawValue]
        resultTextView.textContainerInset = NSSize(width: 0, height: 0)
        resultTextView.textContainer?.lineFragmentPadding = 0
        resultTextView.textContainer?.widthTracksTextView = true
        resultTextView.isHorizontallyResizable = false
        resultTextView.isVerticallyResizable = true
        resultTextView.minSize = .zero
        resultTextView.maxSize = NSSize(
            width: CGFloat.greatestFiniteMagnitude,
            height: CGFloat.greatestFiniteMagnitude
        )
        resultTextView.autoresizingMask = [.width]

        let resultScroll = NSScrollView()
        resultScroll.borderType = .noBorder
        resultScroll.drawsBackground = false
        resultScroll.hasVerticalScroller = true
        resultScroll.autohidesScrollers = true
        resultScroll.documentView = resultTextView
        resultScroll.isHidden = true
        resultScroll.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(resultScroll)

        let resultHeight = resultScroll.heightAnchor.constraint(equalToConstant: 0)

        NSLayoutConstraint.activate([
            spinner.widthAnchor.constraint(equalToConstant: ClipboardHUDMetrics.progressSize),
            spinner.heightAnchor.constraint(equalToConstant: ClipboardHUDMetrics.progressSize),
            stateIcon.widthAnchor.constraint(equalToConstant: ClipboardHUDMetrics.progressSize),
            stateIcon.heightAnchor.constraint(equalToConstant: ClipboardHUDMetrics.progressSize),
            row.leadingAnchor.constraint(
                equalTo: container.leadingAnchor,
                constant: ClipboardHUDMetrics.leadingInset
            ),
            row.trailingAnchor.constraint(
                equalTo: container.trailingAnchor,
                constant: -ClipboardHUDMetrics.trailingInset
            ),
            // Keep the status row in place as the panel grows downward to show a result.
            row.centerYAnchor.constraint(
                equalTo: container.topAnchor,
                constant: ClipboardHUDMetrics.panelHeight / 2
            ),
            resultSeparator.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            resultSeparator.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            resultSeparator.topAnchor.constraint(
                equalTo: container.topAnchor,
                constant: ClipboardHUDMetrics.panelHeight
            ),
            resultScroll.leadingAnchor.constraint(
                equalTo: container.leadingAnchor,
                constant: ClipboardHUDMetrics.leadingInset
            ),
            resultScroll.trailingAnchor.constraint(
                equalTo: container.trailingAnchor,
                constant: -ClipboardHUDMetrics.leadingInset
            ),
            resultScroll.topAnchor.constraint(
                equalTo: resultSeparator.bottomAnchor,
                constant: ClipboardHUDMetrics.resultTextTopGap
            ),
            resultHeight
        ])

        self.resultSeparator = resultSeparator
        self.resultScroll = resultScroll
        self.resultTextView = resultTextView
        self.resultHeightConstraint = resultHeight

        self.titleLabel = titleLabel
        self.statusLabel = statusLabel
        self.spinner = spinner
        self.stateIcon = stateIcon
        self.cancelButton = cancelButton
        self.openButton = openButton
        self.dismissButton = dismissButton
        self.retryButton = retryButton
    }

    // label(text, size, weight): Create a HUD label that can truncate within a
    // constrained horizontal layout.
    private func label(_ text: String, size: CGFloat, weight: NSFont.Weight) -> ClipboardHUDLabel {
        let label = ClipboardHUDLabel(labelWithString: text)
        label.font = NSFont.systemFont(ofSize: size, weight: weight)
        label.lineBreakMode = .byTruncatingTail
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        label.setContentHuggingPriority(.defaultLow, for: .horizontal)
        return label
    }

    // completionImage(style): Choose the completion symbol appropriate to
    // success, cancellation, neutrality, or failure.
    private func completionImage(for style: ClipboardHUDCompletionStyle) -> NSImage? {
        let symbol: String
        // Map completion state to its visual symbol.
        switch style {
        // Use a checkmark for successful completion.
        case .success: symbol = "checkmark"
        // Use a neutral dash for informational completion.
        case .neutral: symbol = "minus"
        // Use a close mark for cancellation.
        case .cancelled: symbol = "xmark"
        // Use a warning triangle for failure.
        case .failure: symbol = "exclamationmark.triangle"
        }
        // Leave the state icon empty if the system symbol cannot be loaded.
        guard let image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil) else {
            return nil
        }
        return image.withSymbolConfiguration(NSImage.SymbolConfiguration(
            pointSize: ClipboardHUDMetrics.progressSize,
            weight: .semibold
        )) ?? image
    }

    // completionTint(style): Color the completion icon by status; keep the rest
    // of the panel's colors unchanged.
    private func completionTint(for style: ClipboardHUDCompletionStyle) -> NSColor {
        // Choose an accent appropriate to the completion meaning.
        switch style {
        // Use green for successful completion.
        case .success: return .systemGreen
        // Use orange for errors that need attention.
        case .failure: return .systemOrange
        // Use a subdued label color for neutral or cancelled completion.
        case .neutral, .cancelled: return .secondaryLabelColor
        }
    }

    // positionPanel(preferredScreen): Position the HUD on a currently connected
    // preferred screen or an available fallback.
    private func positionPanel(on preferredScreen: NSScreen?) {
        let connectedPreferredScreen = preferredScreen.flatMap { preferred in
            NSScreen.screens.first { $0 === preferred }
        }
        // Require a panel and a connected screen before calculating HUD placement.
        guard
            let panel,
            let screen = connectedPreferredScreen ?? screenAtMouseLocation() ?? NSScreen.main ?? NSScreen.screens.first
        // Leave placement unchanged when no usable panel or screen exists.
        else {
            return
        }
        activeScreen = screen
        let visible = screen.visibleFrame
        panel.setFrameOrigin(NSPoint(
            x: visible.midX - panel.frame.width / 2,
            y: visible.maxY - panel.frame.height - ClipboardHUDMetrics.topScreenOffset
        ))
    }

    // screenAtMouseLocation(): Find the connected display currently containing
    // the pointer.
    private func screenAtMouseLocation() -> NSScreen? {
        let location = NSEvent.mouseLocation
        return NSScreen.screens.first { NSMouseInRect(location, $0.frame, false) }
    }

    // showPanel(): Show the HUD with reduced-motion handling without activating
    // the whole application.
    private func showPanel() {
        // Panel presentation requires the HUD's native window.
        guard let panel else { return }
        // Make the panel key for live glass rendering without bringing Langmin to the foreground.
        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            panel.alphaValue = 1
            panel.makeKeyAndOrderFront(nil)
            return
        }
        panel.alphaValue = panel.isVisible ? 1 : 0
        panel.makeKeyAndOrderFront(nil)
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.14
            panel.animator().alphaValue = 1
        }
    }

    // scheduleDismissal(token, delay): Replace any pending dismissal timer with
    // one tied to this request token.
    private func scheduleDismissal(token: UUID, after delay: TimeInterval) {
        dismissalWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            self?.dismiss(token: token)
        }
        dismissalWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: workItem)
    }

    // announce(message): Announce a HUD status message through macOS
    // accessibility notifications.
    private func announce(_ message: String) {
        NSAccessibility.post(
            element: NSApp as Any,
            notification: .announcementRequested,
            userInfo: [
                .announcement: message,
                .priority: NSAccessibilityPriorityLevel.medium.rawValue
            ]
        )
    }

    // notifyBecameInactive(): Notify the owner asynchronously that the HUD is
    // no longer active.
    private func notifyBecameInactive() {
        DispatchQueue.main.async { [weak self] in
            self?.onBecameInactive?()
        }
    }
}

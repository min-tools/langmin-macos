import AppKit

// Compiled with the app's declarations, which the driver splits off main.swift above its
// top-level launch code, so this file supplies the entry point instead.

/// Renders the README hero images and the Mac App Store screenshots: the real launcher window
/// with staged results, drawn offscreen at 2x with the real title bar, active traffic lights,
/// and a window shadow. No model runs; the results are fictional text.
///
/// Usage: render-hero <scratch directory> [--readme <directory>] [--app-store <directory>]
@main
enum RenderHero {
    // The launcher's content size for the captures, the canvas margin that holds the README
    // shadow, and its corner radius.
    static let windowSize = NSSize(width: 1120, height: 680)
    static let margin: CGFloat = 56
    static let cornerRadius: CGFloat = 10

    /// One staged result: the mode, the text typed into the launcher, the result shown beside
    /// it, the original text when the result is a proofread diff, and a dictionary headword.
    struct Scene {
        let name: String
        let mode: String
        let input: String
        let result: String
        let original: String?
        let headword: String?
    }

    /// A Mac App Store screenshot: a scene in one appearance, with its caption.
    struct Screenshot {
        let file: String
        let scene: Scene
        let dark: Bool
        let caption: HeroCanvas.Caption
    }

    static let explain = Scene(
        name: "explain", mode: "explain",
        input: "The committee tabled the motion until the next quarter.",
        result: """
        To table a motion means to set it aside and stop discussing it for now. Here the \
        committee decided not to deal with the proposal until the next quarter, so nothing \
        happens with it for about three months.

        Watch the context: in British English, tabling a motion can mean the opposite, putting \
        it forward for discussion. The surrounding sentences usually make clear which one the \
        writer means.
        """,
        original: nil, headword: nil
    )

    static let proofread = Scene(
        name: "proofread", mode: "proofread",
        input: "Thanks for you're feedback on the draft, I will adress the comments tomorow and send a updated version by friday.",
        result: "Thanks for your feedback on the draft. I will address the comments tomorrow and send an updated version by Friday.",
        original: "Thanks for you're feedback on the draft, I will adress the comments tomorow and send a updated version by friday.",
        headword: nil
    )

    static let translate = Scene(
        name: "translate", mode: "translate",
        input: "Our office will be closed on Monday for the public holiday. We will answer your message on Tuesday.",
        result: "Unser Büro bleibt am Montag wegen des Feiertags geschlossen. Wir beantworten Ihre Nachricht am Dienstag.",
        original: nil, headword: nil
    )

    static let dictionary = Scene(
        name: "dictionary", mode: "dictionary",
        input: "serendipity",
        result: """
        serendipity (noun) · /ˌsɛrənˈdɪpɪti/

        The occurrence of events by chance in a happy or beneficial way.

        "Finding the café was pure serendipity."

        Origin: coined by Horace Walpole in 1754 after The Three Princes of Serendip, a tale \
        whose heroes keep making discoveries by accident.
        """,
        original: nil, headword: "serendipity"
    )

    // The App Store set, in listing order: explain, proofread, translate, and dictionary.
    static let screenshots = [
        Screenshot(
            file: "langmin-1-explain-light.png", scene: explain, dark: false,
            caption: HeroCanvas.Caption(
                headline: "Explain anything, in plain words.",
                subtitle: "Select text in any app, press a shortcut, and read it explained at your level."
            )
        ),
        Screenshot(
            file: "langmin-2-proofread-dark.png", scene: proofread, dark: true,
            caption: HeroCanvas.Caption(
                headline: "Proofread with every change shown.",
                subtitle: "Corrections appear as tracked changes you can copy or paste straight back."
            )
        ),
        Screenshot(
            file: "langmin-3-translate-light.png", scene: translate, dark: false,
            caption: HeroCanvas.Caption(
                headline: "Translate without leaving your app.",
                subtitle: "Thirty languages, with Apple Intelligence on device or your own API key."
            )
        ),
        Screenshot(
            file: "langmin-4-dictionary-dark.png", scene: dictionary, dark: true,
            caption: HeroCanvas.Caption(
                headline: "Look a word up without losing your place.",
                subtitle: "Definitions, pronunciation, and origin, saved to your Library."
            )
        ),
    ]

    // main(): Parse the output directories, build the launcher as the app would, and write every
    // requested image.
    @MainActor static func main() {
        setvbuf(stdout, nil, _IONBF, 0)
        var arguments = Array(CommandLine.arguments.dropFirst())
        let usage = "usage: render-hero <scratch directory> [--readme <directory>] [--app-store <directory>]"
        guard !arguments.isEmpty else {
            print(usage)
            exit(2)
        }
        let scratch = URL(fileURLWithPath: arguments.removeFirst(), isDirectory: true)
        var readme: URL?
        var appStore: URL?
        while !arguments.isEmpty {
            let flag = arguments.removeFirst()
            guard !arguments.isEmpty else {
                print(usage)
                exit(2)
            }
            let directory = URL(fileURLWithPath: arguments.removeFirst(), isDirectory: true)
            switch flag {
            case "--readme": readme = directory
            case "--app-store": appStore = directory
            default:
                print(usage)
                exit(2)
            }
        }
        NSApplication.shared.setActivationPolicy(.prohibited)

        // The translate chip names the target language; German matches the staged translation.
        preferencesStore.set(encodeLanguageList(["de"]), forKey: PreferenceKey.translationTarget)
        preferencesStore.set("de", forKey: PreferenceKey.launcherTranslationTarget)

        // The app delegate owns result sessions; the launcher controller owns the window. Both
        // are created as the app does, without finishing the launch sequence.
        let delegate = AppDelegate()
        NSApp.delegate = delegate
        // The window is prepared but never ordered front: this process has no screen, and a
        // window shown without one keeps its minimum frame whatever size it is given later.
        let launcher = LauncherController()
        launcher.appDelegate = delegate
        launcher.prepareForLaunch()
        launcher.populateRunDefaults()
        launcher.updateLibraryButtonCount()
        guard let window = launcher.window else {
            print("the launcher did not create its window")
            exit(1)
        }
        window.setContentSize(windowSize)
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 1.0))

        for directory in [readme, appStore].compactMap({ $0 }) {
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        // The README heroes show the explain result.
        if let readme {
            stage(explain, in: launcher, delegate: delegate, scratch: scratch)
            for dark in [false, true] {
                let name = dark ? "hero-dark.png" : "hero-light.png"
                let image = capture(window, dark: dark)
                HeroCanvas.write(render(image, dark: dark), to: readme.appendingPathComponent(name))
            }
        }
        // The App Store set at 2880x1800, each scene over the wallpaper with its caption.
        if let appStore {
            for screenshot in screenshots {
                stage(screenshot.scene, in: launcher, delegate: delegate, scratch: scratch)
                let image = capture(window, dark: screenshot.dark)
                let canvas = HeroCanvas.appStoreScreenshot(
                    window: image, windowSize: image.size, caption: screenshot.caption, dark: screenshot.dark
                )
                HeroCanvas.write(HeroCanvas.png(canvas), to: appStore.appendingPathComponent(screenshot.file))
            }
        }
    }

    // stage(scene, in launcher, delegate, scratch): Type the scene's text into the launcher,
    // select its mode, and show its result beside the input through the app's own session.
    @MainActor static func stage(_ scene: Scene, in launcher: LauncherController, delegate: AppDelegate, scratch: URL) {
        let folder = scratch.appendingPathComponent("results/\(scene.name)", isDirectory: true)
        let result = folder.appendingPathComponent("result.txt")
        let original = folder.appendingPathComponent("original.txt")
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try Data(scene.result.utf8).write(to: result, options: [])
            if let text = scene.original {
                try Data(text.utf8).write(to: original, options: [])
            }
        } catch {
            print("could not stage the \(scene.name) result: \(error)")
            exit(1)
        }
        launcher.inputView.string = scene.input
        launcher.applySelectedMode(scene.mode)
        let session = delegate.resultSession(
            textPath: result.path,
            audioPath: "",
            title: scene.mode.capitalized,
            cleanupDir: folder.path,
            diffOriginalPath: scene.original == nil ? nil : original.path,
            diffRevisedPath: scene.original == nil ? nil : result.path,
            textModel: "Apple Intelligence",
            dictionaryHeadword: scene.headword,
            mode: scene.mode
        )
        launcher.showInlineResult(session)
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.8))
        // A proofread result opens on its Diff view, the way the caption describes it.
        if scene.original != nil {
            let diffButton = NSButton()
            diffButton.tag = 1
            session.changeDisplayedText(diffButton)
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.3))
        }
    }

    // capture(window, dark): Draw the window's frame view, title bar included, into a 2x bitmap
    // in the requested appearance.
    @MainActor static func capture(_ window: NSWindow, dark: Bool) -> NSBitmapImageRep {
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        window.setContentSize(windowSize)
        window.layoutIfNeeded()
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.6))
        guard let frameView = window.contentView?.superview else { fatalError("no window frame view") }
        let frameRect = frameView.bounds
        let frameImage = HeroCanvas.bitmap(size: frameRect.size)
        frameView.cacheDisplay(in: frameRect, to: frameImage)
        overdrawTrafficLights(of: window, in: frameView, onto: frameImage)
        return frameImage
    }

    // render(image, dark): Compose a captured window with a shadow and hairline on a transparent
    // canvas and return the PNG data.
    static func render(_ image: NSBitmapImageRep, dark: Bool) -> Data {
        let canvasSize = NSSize(width: image.size.width + margin * 2, height: image.size.height + margin * 2)
        let canvas = HeroCanvas.bitmap(size: canvasSize)
        HeroCanvas.draw(into: canvas) { cg in
            HeroCanvas.drawWindow(
                in: cg, image: image, at: NSPoint(x: margin, y: margin), size: image.size,
                cornerRadius: cornerRadius, dark: dark
            )
        }
        return HeroCanvas.png(canvas)
    }

    // overdrawTrafficLights(of window, in frameView, onto image): Paint active button colors
    // onto the bitmap; AppKit draws this offscreen window's buttons gray.
    @MainActor static func overdrawTrafficLights(of window: NSWindow, in frameView: NSView, onto image: NSBitmapImageRep) {
        // Fill and edge colors of the close, minimize, and zoom buttons of a key window.
        let buttons: [(NSWindow.ButtonType, NSColor, NSColor)] = [
            (.closeButton, NSColor(srgbRed: 1.0, green: 0.37, blue: 0.34, alpha: 1), NSColor(srgbRed: 0.88, green: 0.28, blue: 0.25, alpha: 1)),
            (.miniaturizeButton, NSColor(srgbRed: 1.0, green: 0.74, blue: 0.18, alpha: 1), NSColor(srgbRed: 0.87, green: 0.62, blue: 0.11, alpha: 1)),
            (.zoomButton, NSColor(srgbRed: 0.16, green: 0.78, blue: 0.25, alpha: 1), NSColor(srgbRed: 0.11, green: 0.65, blue: 0.19, alpha: 1)),
        ]
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        guard let context = NSGraphicsContext(bitmapImageRep: image) else { return }
        NSGraphicsContext.current = context
        // Each button's frame is converted into the frame view, which the bitmap was drawn from.
        for (type, fill, stroke) in buttons {
            guard let button = window.standardWindowButton(type), let superview = button.superview else { continue }
            let frame = superview.convert(button.frame, to: frameView)
            let diameter: CGFloat = 12
            let circle = NSBezierPath(ovalIn: NSRect(x: frame.midX - diameter / 2, y: frame.midY - diameter / 2, width: diameter, height: diameter))
            fill.setFill()
            circle.fill()
            stroke.setStroke()
            circle.lineWidth = 0.5
            circle.stroke()
        }
    }
}

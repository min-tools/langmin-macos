#!/usr/bin/env python3
"""Check the launcher invitation, editor handoff, and layout without user data or model requests."""
from pathlib import Path
import argparse
import json
import os
import shutil
import subprocess
import tempfile

from source_files import ROOT, app_path, swift_fixture_args

# Reuse the isolated import dependencies so these checks exercise the real NSTextView subclass.
builder = (ROOT / 'scripts/test_audio_transcription.py').read_text().split("source += r'''\nvar checks = 0")[0]
namespace = {'__file__': str(ROOT / 'scripts/test_audio_transcription.py')}
exec(compile(builder, 'audio-import-fixture', 'exec'), namespace)
source = namespace['source'].replace('private(set) var isReceivingFileDrop', 'var isReceivingFileDrop')
source += namespace['block'](namespace['main'], 'let langminFieldFillColor =') + '\n'
source += namespace['block'](namespace['main'], 'final class LauncherFieldContainer:') + '\n'
source += r'''
var checks = 0
// check(condition, message): Report a named UI failure without saving any
// application preferences.
func check(_ condition: @autoclosure () -> Bool, _ message: String) {
    // Fail immediately with the assertion message.
    guard condition() else { fputs("FAIL: \(message)\n", stderr); exit(1) }
    checks += 1
}
// descendants(view): Include nested labels and icons when checking bounds and
// translated text.
func descendants(_ view: NSView) -> [NSView] { view.subviews.flatMap { [$0] + descendants($0) } }
let root = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
let translations = try JSONDecoder().decode([[String: String]].self, from: Data(contentsOf: root.appendingPathComponent("translations.json")))
_ = NSApplication.shared
Task { @MainActor in
    do {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 524, height: 580), styleMask: [], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let field = LauncherFieldContainer(frame: NSRect(x: 0, y: 0, width: 524, height: 580))
        window.contentView = field
        field.isFocused = true
        let input = LauncherInputView(frame: NSRect(x: 0, y: 0, width: 522, height: 532))
        input.font = .systemFont(ofSize: 16)
        input.textContainerInset = NSSize(width: 18, height: 18)
        input.textContainer?.lineFragmentPadding = 0
        input.drawsBackground = false
        input.allowsUndo = true
        input.isRichText = false
        input.insertionPointColor = .controlAccentColor
        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.documentView = input
        scroll.translatesAutoresizingMaskIntoConstraints = false
        field.addSubview(scroll)
        let hint = NSTextField(labelWithString: "Drop or paste documents, images, or audio")
        field.addSubview(hint)
        NSLayoutConstraint.activate([
            scroll.leadingAnchor.constraint(equalTo: field.leadingAnchor, constant: 1),
            scroll.trailingAnchor.constraint(equalTo: field.trailingAnchor, constant: -1),
            scroll.topAnchor.constraint(equalTo: field.topAnchor, constant: 1),
            scroll.bottomAnchor.constraint(equalTo: field.bottomAnchor, constant: -48)
        ])
        let welcome = installLauncherInputPlaceholder(in: field, input: input, scrollView: scroll, dropHint: hint)
        input.placeholderString = "What would you like proofread?"
        field.layoutSubtreeIfNeeded()
        check(!welcome.isHidden && hint.isHidden, "Empty input shows one invitation without the old footer hint")
        check(welcome.titleLabel.stringValue == input.placeholderString, "The invitation follows the selected mode")
        check(welcome.hitTest(welcome.bounds.center) == nil, "The invitation never intercepts clicks or file drops")
        check(field.hitTest(NSPoint(x: 250, y: 250)) === input, "Clicking the invitation reaches the actual editor")
        input.insertText("My draft", replacementRange: NSRange(location: 0, length: 0))
        check(welcome.isHidden && !hint.isHidden, "Typing immediately reveals the normal editor")
        // Isolate Clear from the earlier typing, which this fixture performs in the same event.
        input.undoManager?.removeAllActions()
        input.clearUndoably()
        check(!welcome.isHidden, "Clearing text restores the invitation")
        input.undoManager?.undo()
        check(welcome.isHidden && input.string == "My draft", "Undo restores the draft and hides the invitation")
        input.string = ""
        check(!welcome.isHidden, "Programmatic resets restore the invitation")
        input.string = "Prefilled by a Service"
        check(welcome.isHidden, "Programmatic prefills hide the invitation")
        input.string = ""
        input.isReceivingFileDrop = true
        check(field.isDropTarget && welcome.titleLabel.stringValue == "Drop to add text", "Accepted file drags highlight the input")
        input.draggingExited(nil)
        check(!field.isDropTarget && welcome.titleLabel.stringValue == input.placeholderString, "Leaving the pane clears drag feedback")

        // The overlay must disappear during extraction and return after an empty import finishes.
        input.runTextExtraction(progressText: "Reading fixture…", at: 0) { ([], []) }
        check(welcome.isHidden && input.isImportingFiles, "Extraction shows progress instead of the invitation")
        for _ in 0..<50 {
            // Stop polling when the import has completed.
            if !input.isImportingFiles { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        check(!welcome.isHidden && !input.isImportingFiles, "An empty completed import restores the invitation")

        // Check every translation at both pane sizes and in both system appearances.
        for dark in [false, true] {
            window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
            for size in [NSSize(width: 440, height: 230), NSSize(width: 524, height: 580)] {
                window.setContentSize(size)
                for translation in translations {
                    input.placeholderString = translation["placeholder_proofread"]!
                    welcome.hintLabel.stringValue = translation["input_start_hint"]!
                    let typeLabels = descendants(welcome).compactMap { $0 as? NSTextField }.filter { $0 !== welcome.titleLabel && $0 !== welcome.hintLabel }
                    for (index, key) in ["input_documents", "input_images", "input_audio"].enumerated() {
                        typeLabels[index * 2].stringValue = translation[key]!
                    }
                    welcome.needsLayout = true
                    field.layoutSubtreeIfNeeded()
                    for view in descendants(welcome) where !view.isHiddenOrHasHiddenAncestor {
                        let frame = view.convert(view.bounds, to: welcome)
                        check(welcome.bounds.insetBy(dx: -1, dy: -1).contains(frame), "Welcome content fits \(translation["locale"]!) at \(Int(size.height)) points")
                        check(view.superview!.bounds.insetBy(dx: -1, dy: -1).contains(view.frame), "Card contents stay inside their parent")
                        // Check rendered label bounds for each placeholder layout.
                        if let label = view as? NSTextField {
                            let required = label.cell!.cellSize(forBounds: NSRect(x: 0, y: 0, width: label.bounds.width, height: 1000)).height
                            check(label.bounds.height + 1 >= required, "Translated labels fit without vertical clipping")
                            // Require unwrapped labels to fit without clipping.
                            if !label.cell!.wraps {
                                check(label.bounds.width + 1 >= label.cell!.cellSize.width, "Single-line label \(label.stringValue) needs \(label.cell!.cellSize.width) points, has \(label.bounds.width)")
                            }
                        }
                    }
                    // Save representative English and Greek placeholder snapshots.
                    if translation["locale"] == "en" || translation["locale"] == "el" {
                        let bitmap = field.bitmapImageRepForCachingDisplay(in: field.bounds)!
                        field.cacheDisplay(in: field.bounds, to: bitmap)
                        let name = "input-\(translation["locale"]!)-\(dark ? "dark" : "light")-\(Int(size.height)).png"
                        try bitmap.representation(using: .png, properties: [:])!.write(to: root.appendingPathComponent(name))
                    }
                }
            }
        }
        print("\(checks) launcher invitation checks passed")
        exit(0)
    } catch {
        fputs("FAIL: \(error.localizedDescription)\n", stderr)
        exit(1)
    }
}
RunLoop.main.run()
'''.replace('welcome.bounds.center', 'NSPoint(x: welcome.bounds.midX, y: welcome.bounds.midY)')

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--snapshots', type=Path)
args = parser.parse_args()
with tempfile.TemporaryDirectory(prefix='langmin-input-welcome-', dir='/private/tmp') as directory:
    folder = Path(directory)
    keys = ['placeholder_proofread', 'input_start_hint', 'input_documents', 'input_images', 'input_audio']
    translations = [dict(zip(['locale', *keys], ['en', 'What would you like proofread?', 'Type or paste here, or drop a file', 'Documents', 'Images', 'Audio']))]
    for path in sorted((ROOT / 'langmin/Resources').glob('*.lproj/Localizable.strings')):
        values = json.loads(subprocess.check_output(['plutil', '-convert', 'json', '-o', '-', str(path)]))
        # Exercise only locales that provide every placeholder label.
        if all(key in values for key in keys):
            translations.append({'locale': path.parent.stem, **{key: values[key] for key in keys}})
    (folder / 'translations.json').write_text(json.dumps(translations))
    (folder / 'main.swift').write_text(source)
    cache = os.environ.get('LANGMIN_TEST_MODULE_CACHE', str(folder / 'modules'))
    files = ['AudioTranscription.swift', 'AudioFileImport.swift', 'TranscriptionSettings.swift', 'LauncherInputPlaceholder.swift']
    subprocess.run(['swiftc', '-swift-version', '5', '-module-cache-path', cache, *swift_fixture_args(),
                    *map(str, map(app_path, files)), str(folder / 'main.swift'), '-o', str(folder / 'tests')], check=True)
    subprocess.run([str(folder / 'tests'), directory], check=True, timeout=45)
    # Keep placeholder snapshots only when an output directory was requested.
    if args.snapshots:
        args.snapshots.mkdir(parents=True, exist_ok=True)
        for image in folder.glob('*.png'):
            shutil.copy2(image, args.snapshots / image.name)

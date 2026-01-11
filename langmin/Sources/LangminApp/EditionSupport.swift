import Cocoa

// Features that require Pro. The paywall names the feature being requested.
enum ProFeature {
    // Gate remote text-generation providers behind Pro access.
    case cloudModels
    // Gate Library folder management behind Pro access.
    case libraryFolders
    // Gate cross-device Library synchronization behind Pro access.
    case librarySync
    // Gate remote narration providers behind Pro access.
    case cloudVoices
    // Require Pro for OpenAI audio transcription.
    case cloudTranscription
}

// presentProAlert(title, body, [style = .informational]): Allow informational
// alerts while the Pro panel is open.
func presentProAlert(title: String, body: String, style: NSAlert.Style = .informational) {
    let alert = NSAlert()
    alert.alertStyle = style
    alert.messageText = title
    alert.informativeText = body
    alert.addButton(withTitle: localized("ok", "OK"))
    alert.runModal()
}

// presentNothingToRestoreAlert(): Explain that Restore found no Pro purchase
// for the current Apple Account.
func presentNothingToRestoreAlert() {
    presentProAlert(
        title: localized("pro_restore_none_title", "Nothing to restore"),
        body: String(format: localized("pro_restore_none_body", "No %@ Pro purchase was found for this Apple Account."), appName)
    )
}

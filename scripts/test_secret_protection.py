#!/usr/bin/env python3
"""Exercise mandatory outgoing-text warnings with fake secrets and modal responses."""
from pathlib import Path
import os
import subprocess
import tempfile

from source_files import ROOT, app_source

MAIN = app_source('main.swift')
SHARED = (ROOT / 'langmin/Sources/LangminShared/LangminStorage.swift').read_text()


# block(source, marker): Extract a production declaration for the isolated fixture.
def block(source, marker):
    start = source.index(marker)
    end = source.index('{', start) + 1
    depth = 1
    while depth:
        depth += (source[end] == '{') - (source[end] == '}')
        end += 1
    return source[start:end] + '\n'


source = r'''
import Foundation
func localized(_ key: String, _ english: String) -> String { english }
// Trap any attempt to reintroduce a preference-based warning bypass.
func loadAppPreferences() -> Never { fatalError("Secret scanning must not depend on a saved opt-out") }
enum Response { case alertFirstButtonReturn, alertSecondButtonReturn }
final class NSAlert {
 enum Style { case warning }
 var alertStyle = Style.warning, messageText = "", informativeText = ""
 var buttons: [String] = []
 func addButton(withTitle title: String) { buttons.append(title) }
}
var alerts: [NSAlert] = [], response = Response.alertFirstButtonReturn
var receivedDeadline: DispatchTime?
// runLangminModalAlert(alert, before): Capture the warning without showing a window.
func runLangminModalAlert(_ alert: NSAlert, before deadline: DispatchTime?) -> Response {
 alerts.append(alert); receivedDeadline = deadline; return response
}
'''
source += SHARED[SHARED.index('struct LangminSecretFinding {'):SHARED.index('// MARK: - Response language level')]
source += block(SHARED, 'func langminSecretSummary(')
for marker in ['func remoteSecretWarningMessage(', 'func confirmRemoteSecretWarningIfNeeded(']:
    source += block(MAIN, marker)
source += r'''
var checks = 0
func check(_ value: @autoclosure () -> Bool, _ message: String) {
 guard value() else { fatalError(message) }; checks += 1
}
// Fake patterns exercise the real scanner without reading any credentials.
let samples = ["password = fixture-value-only", "sk-" + String(repeating: "x", count: 24),
               "-----BEGIN PRIVATE KEY-----\nfixture-only"]
for sample in samples {
 alerts = []
 check(confirmRemoteSecretWarningIfNeeded(input: sample, provider: nil), "Local requests do not expose secrets remotely")
 check(alerts.isEmpty, "Local requests need no remote warning")
 for provider in ["OpenAI", "Anthropic", "Grok", "DeepSeek", "Custom endpoint"] {
  response = .alertFirstButtonReturn
  let deadline = DispatchTime.now() + 1
  check(!confirmRemoteSecretWarningIfNeeded(input: sample, provider: provider, deadline: deadline), "Cancel blocks remote sharing")
  check(receivedDeadline == deadline, "Service deadlines reach the modal warning")
  check(alerts.last!.buttons == ["Cancel", "Send Anyway"], "Warnings always require an explicit per-request choice")
  check(alerts.last!.informativeText.contains(provider) && !alerts.last!.informativeText.contains(sample), "Warnings identify the recipient without repeating the secret")
  response = .alertSecondButtonReturn
  check(confirmRemoteSecretWarningIfNeeded(input: sample, provider: provider), "Send Anyway authorizes this request")
  let count = alerts.count
  response = .alertFirstButtonReturn
  check(!confirmRemoteSecretWarningIfNeeded(input: sample, provider: provider) && alerts.count == count + 1, "A previous approval cannot disable future secret warnings")
 }
}
alerts = []
check(confirmRemoteSecretWarningIfNeeded(input: "Please proofread this public sentence.", provider: "OpenAI"), "Ordinary text proceeds normally")
check(alerts.isEmpty, "No warning appears without a detected secret")
print("\(checks) mandatory secret-protection checks passed; no preferences, credentials or providers accessed")
'''

with tempfile.TemporaryDirectory(prefix='langmin-secret-checks-', dir='/private/tmp') as directory:
    folder = Path(directory)
    (folder / 'main.swift').write_text(source)
    cache = os.environ.get('LANGMIN_TEST_MODULE_CACHE', str(folder / 'modules'))
    subprocess.run(['swiftc', '-module-cache-path', cache, str(folder / 'main.swift'), '-o', str(folder / 'tests')], check=True)
    subprocess.run([str(folder / 'tests')], check=True, timeout=30)

"""Locate app sources for isolated fixtures without a sibling checkout."""
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
APP = ROOT / 'langmin/Sources/LangminApp'
FEATURE_SOURCES = ('CloudIllustrations.swift', 'CloudText.swift', 'CloudTranscription.swift', 'CloudTransport.swift', 'CloudVoices.swift', 'LibraryCloudSync.swift', 'LibraryCloudTransport.swift', 'LibraryFolderActions.swift', 'LibraryFolderViews.swift', 'LibraryFolders.swift', 'LibrarySyncArchive.swift', 'LibrarySyncLifecycle.swift', 'LibrarySyncSettings.swift', 'ProEntitlementLogic.swift', 'ProStore.swift', 'ProviderCredentials.swift')


# app_path(name): Resolve every feature from the same app source directory.
def app_path(name):
    return APP / name


# app_source(name): Include declarations split across feature files for
# extraction-based fixtures.
def app_source(name):
    text = app_path(name).read_text()
    # Combine feature declarations with the main source for isolated fixtures.
    if name == 'main.swift':
        text += '\n' + '\n'.join(app_path(item).read_text() for item in FEATURE_SOURCES)
    # Include cloud illustration helpers in dictionary fixtures.
    if name == 'DictionaryIllustration.swift':
        text += '\n' + app_path('CloudIllustrations.swift').read_text()
    return text


# swift_fixture_args(): Compile identity and distribution settings alongside
# each isolated fixture.
def swift_fixture_args():
    return [str(app_path('BuildEdition.swift'))]

#!/usr/bin/env python3
"""Exercise native sync settings against fake purchase and sync state, never the user's app."""
from pathlib import Path
import os
import subprocess
import tempfile

from source_files import ROOT, app_path, app_source, swift_fixture_args
source = app_source('LibrarySyncSettings.swift').replace('private ', '')
with tempfile.TemporaryDirectory(prefix='langmin-sync-settings-', dir='/private/tmp') as directory:
    folder = Path(directory)
    extracted = folder / 'LibrarySyncSettings.swift'
    extracted.write_text(source)
    executable = folder / 'tests'
    snapshots = Path(os.environ.get('LANGMIN_TEST_SNAPSHOTS', directory))
    cache = os.environ.get('LANGMIN_TEST_MODULE_CACHE', str(folder / 'modules'))
    subprocess.run(['swiftc', *swift_fixture_args(), '-parse-as-library', '-module-cache-path', cache, str(extracted),
                    str(ROOT / 'scripts/test_library_sync_settings.swift'), '-o', str(executable)], check=True)
    subprocess.run([str(executable), str(snapshots)], check=True, timeout=30)

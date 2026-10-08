#!/usr/bin/env python3
"""Test the real Pro store with in-memory StoreKit stand-ins, without receipts or purchases."""
from pathlib import Path
import os
import subprocess
import tempfile

from source_files import ROOT, app_path, app_source, swift_fixture_args
source = app_source('ProStore.swift')
source = source.split('// MARK: - Gate')[0].replace('import StoreKit', '').replace('import OSLog', '').replace('private ', '')
# Capture only the logging boundary; production message construction stays intact.
source = source.replace(', privacy: .public', '')
# Keep first-launch preferences isolated from the workstation and previous test runs.
source = source.replace('UserDefaults.standard', 'TrialPreferences.shared')
source = source.replace('private(set)', '')
fixture = (ROOT / 'scripts/test_pro_store.swift').read_text().replace('UserDefaults.standard', 'TrialPreferences.shared')
with tempfile.TemporaryDirectory(prefix='langmin-pro-store-', dir='/private/tmp') as directory:
    folder = Path(directory)
    extracted = folder / 'ProStore.swift'
    extracted.write_text(source)
    tests = folder / 'Tests.swift'
    tests.write_text(fixture)
    footer = folder / 'SourcePurchaseFooter.swift'
    footer.write_text(app_source('SourcePurchaseFooter.swift').replace('UserDefaults.standard', 'TrialPreferences.shared'))
    cache = os.environ.get('LANGMIN_TEST_MODULE_CACHE', str(folder / 'modules'))
    # Exercise both App Store and source-build configurations.
    for name, flags in [('store', ['-D', 'LANGMIN_APP_STORE']), ('source', [])]:
        executable = folder / name
        subprocess.run(['swiftc', *swift_fixture_args(), *flags, '-parse-as-library', '-module-cache-path', cache,
                        str(app_path('ProEntitlementLogic.swift')), str(extracted),
                        str(footer), str(tests), '-o', str(executable)], check=True)
        subprocess.run([str(executable)], check=True, timeout=30)

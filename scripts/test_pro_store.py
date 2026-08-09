#!/usr/bin/env python3
"""Test the real Pro store with in-memory StoreKit stand-ins, without receipts or purchases."""
from pathlib import Path
import os
import subprocess
import tempfile

from source_files import ROOT, app_path, app_source, swift_fixture_args
source = app_source('ProStore.swift')
source = source.split('// MARK: - Gate')[0].replace('import StoreKit', '').replace('private ', '')
with tempfile.TemporaryDirectory(prefix='langmin-pro-store-', dir='/private/tmp') as directory:
    folder = Path(directory)
    extracted = folder / 'ProStore.swift'
    extracted.write_text(source)
    cache = os.environ.get('LANGMIN_TEST_MODULE_CACHE', str(folder / 'modules'))
    # Exercise both App Store and source-build configurations.
    for name, flags in [('store', ['-D', 'LANGMIN_APP_STORE']), ('source', [])]:
        executable = folder / name
        subprocess.run(['swiftc', *swift_fixture_args(), *flags, '-parse-as-library', '-module-cache-path', cache,
                        str(app_path('ProEntitlementLogic.swift')), str(extracted),
                        str(ROOT / 'scripts/test_pro_store.swift'), '-o', str(executable)], check=True)
        subprocess.run([str(executable)], check=True, timeout=30)

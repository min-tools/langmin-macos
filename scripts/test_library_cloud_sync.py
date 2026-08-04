#!/usr/bin/env python3
"""Exercise two offline Library replicas through a fake CloudKit transport, never a real account."""
from pathlib import Path
import os
import subprocess
import tempfile

from source_files import ROOT, app_path, app_source, swift_fixture_args
with tempfile.TemporaryDirectory(prefix='langmin-cloud-tests-', dir='/private/tmp') as directory:
    target = Path(directory) / 'tests'
    cache = os.environ.get('LANGMIN_TEST_MODULE_CACHE', str(Path(directory) / 'modules'))
    sources = [app_path(name) for name in (
        'LibrarySyncArchive.swift', 'LibraryCloudTransport.swift', 'LibraryCloudSync.swift')]
    subprocess.run(['swiftc', *swift_fixture_args(), '-parse-as-library', '-module-cache-path', cache, *map(str, sources),
                    str(ROOT / 'scripts/test_library_cloud_sync.swift'), '-o', str(target)], check=True)
    subprocess.run([str(target), directory], check=True, timeout=120)

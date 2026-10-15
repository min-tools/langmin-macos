#!/usr/bin/env python3
"""Render the README hero images and the Mac App Store screenshots from the real launcher with
fictional results, without launching the app or any model."""
from pathlib import Path
import argparse
import os
import shutil
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parent.parent
APP = ROOT / 'langmin/Sources/LangminApp'
SHARED = ROOT / 'langmin/Sources/LangminShared'
RESOURCES = ROOT / 'langmin/Resources'

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument(
    '--readme', type=Path, default=ROOT / 'docs/images',
    help='directory for hero-light.png and hero-dark.png (default: docs/images)',
)
parser.add_argument('--no-readme', action='store_true', help='skip the README heroes')
parser.add_argument(
    '--app-store', type=Path, default=ROOT / 'private/app-store/screenshots',
    help='directory for the 2880x1800 App Store set (default: private/app-store/screenshots)',
)
parser.add_argument('--no-app-store', action='store_true', help='skip the App Store set')
args = parser.parse_args()

with tempfile.TemporaryDirectory(prefix='langmin-hero-', dir='/private/tmp') as directory:
    folder = Path(directory)
    # main.swift ends with the top-level code that starts the app; everything above it is the
    # declarations the renderer drives, compiled as a library with the renderer's own entry point.
    lines = (APP / 'main.swift').read_text().split('\n')
    launch = next(index for index, line in enumerate(lines) if line.startswith('let app = NSApplication.shared'))
    declarations = folder / 'LangminDeclarations.swift'
    declarations.write_text('\n'.join(lines[:launch]) + '\n')
    sources = [path for path in sorted(APP.glob('*.swift')) if path.name != 'main.swift']
    sources += sorted(SHARED.glob('*.swift'))
    sources += [declarations, ROOT / 'scripts/hero_canvas.swift', ROOT / 'scripts/render_hero.swift']

    executable = folder / 'render-hero'
    command = [
        'xcrun', 'swiftc', '-swift-version', '5', '-parse-as-library', '-module-name', 'LangminHero',
        '-module-cache-path', str(folder / 'modules'), '-target', 'arm64-apple-macos14.0',
        *map(str, sources), '-o', str(executable),
    ]
    subprocess.run(command, check=True)
    # A bare executable's main bundle is its folder; the localizations must sit beside it.
    for item in RESOURCES.iterdir():
        target = folder / item.name
        shutil.copytree(item, target) if item.is_dir() else shutil.copy2(item, target)
    # A throwaway home keeps the app's preferences and support files out of the real ones.
    home = folder / 'home'
    home.mkdir()
    environment = {**os.environ, 'HOME': str(home)}
    arguments = [str(executable), str(folder)]
    if not args.no_readme:
        arguments += ['--readme', str(args.readme.resolve())]
    if not args.no_app_store:
        arguments += ['--app-store', str(args.app_store.resolve())]
    subprocess.run(arguments, check=True, timeout=600, env=environment)

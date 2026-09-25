#!/usr/bin/env python3
"""Sign an AppStore archive and verify its entitlements before packaging it."""
from pathlib import Path
import argparse
import datetime
import hashlib
import json
import os
import plistlib
import re
import shutil
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parent.parent
ENVIRONMENT = 'com.apple.developer.icloud-container-environment'
IDENTITY_KEYS = ('com.apple.application-identifier',
                 'com.apple.developer.team-identifier', 'keychain-access-groups')


# require_production(entitlements): Reject ambiguous or missing release environments.
def require_production(entitlements):
    if entitlements.get(ENVIRONMENT) != 'Production':
        raise ValueError('The signed iCloud environment must be the string Production.')


# resolve_entitlements(source, allowed, settings): Expand Xcode settings, using
# profile values only to authorize the selected environment and signing identity.
def resolve_entitlements(source, allowed, settings):
    requested = plistlib.loads(Path(source).read_bytes())

    # expand(value): Resolve nested build placeholders without profile fallbacks.
    def expand(value):
        if isinstance(value, str):
            # substitute(match): Require an explicit string-valued build setting.
            def substitute(match):
                name = match.group(1) or match.group(2)
                setting = settings.get(name)
                if not isinstance(setting, str):
                    raise ValueError(f'Missing string build setting: {name}.')
                return setting
            value = re.sub(r'\$\(([^)]+)\)|\$\{([^}]+)\}', substitute, value)
            if '$(' in value or '${' in value:
                raise ValueError('Unresolved entitlement build setting.')
        elif isinstance(value, list):
            value = [expand(item) for item in value]
        elif isinstance(value, dict):
            value = {key: expand(item) for key, item in value.items()}
        return value

    resolved = expand(requested)
    require_production(resolved)
    permitted = allowed.get(ENVIRONMENT)
    if permitted != 'Production' and not (
            isinstance(permitted, list) and 'Production' in permitted):
        raise ValueError('The provisioning profile does not permit Production iCloud.')
    # Profiles supply the concrete signing identity, not application build settings.
    for key in IDENTITY_KEYS:
        if key in allowed:
            resolved[key] = allowed[key]
    return resolved


# verify_entitlements(actual, expected): Check the release contract independently
# before comparing the signature with the values requested from codesign.
def verify_entitlements(actual, expected):
    require_production(actual)
    if actual != expected:
        raise ValueError('Signed entitlements do not match the requested entitlements.')


# app_store_settings(): Read effective settings for the actual AppStore target.
def app_store_settings():
    # Match the fixture and private builders without changing xcode-select globally.
    environment = os.environ.copy()
    environment.setdefault('DEVELOPER_DIR', '/Applications/Xcode.app/Contents/Developer')
    output = subprocess.check_output([
        'xcodebuild', '-project', str(ROOT / 'langmin/Langmin.xcodeproj'),
        '-scheme', 'Langmin', '-configuration', 'AppStore',
        '-showBuildSettings', '-json', 'CODE_SIGNING_ALLOWED=NO',
    ], env=environment)
    targets = [item['buildSettings'] for item in json.loads(output)
               if item.get('target') == 'Langmin']
    if len(targets) != 1:
        raise ValueError('Expected one Langmin AppStore target.')
    return targets[0]


# verify_bundle(info, settings): Reject stale or differently identified archives.
def verify_bundle(info, settings):
    for key, setting in (('CFBundleIdentifier', 'PRODUCT_BUNDLE_IDENTIFIER'),
                         ('CFBundleShortVersionString', 'MARKETING_VERSION'),
                         ('CFBundleVersion', 'CURRENT_PROJECT_VERSION')):
        if info.get(key) != settings.get(setting) or not info.get(key):
            raise ValueError(f'Archived {key} does not match AppStore build settings.')


# profile_entitlements(profile, bundle_id, certificate): Validate distribution
# permission and the selected public signing certificate before using the profile.
def profile_entitlements(profile, bundle_id, certificate):
    allowed = profile.get('Entitlements', {})
    team = allowed.get('com.apple.developer.team-identifier')
    if not team or allowed.get('com.apple.application-identifier') != f'{team}.{bundle_id}':
        raise ValueError('Provisioning profile does not match the app identity.')
    expiry = profile.get('ExpirationDate')
    if not isinstance(expiry, datetime.datetime) or expiry.replace(
            tzinfo=datetime.timezone.utc) <= datetime.datetime.now(datetime.timezone.utc):
        raise ValueError('Provisioning profile has expired or has no expiry date.')
    if (profile.get('ProvisionedDevices') or profile.get('ProvisionsAllDevices')
            or allowed.get('get-task-allow') or allowed.get('com.apple.security.get-task-allow')):
        raise ValueError('An App Store distribution profile is required.')
    hashes = {hashlib.sha256(item).digest() for item in profile.get('DeveloperCertificates', [])}
    if hashlib.sha256(Path(certificate).read_bytes()).digest() not in hashes:
        raise ValueError('Profile does not authorize the selected signing certificate.')
    return allowed


# verify_app(app, expected, settings, certificate): Verify the actual signer,
# entitlements and bundle version before accepting a release artifact.
def verify_app(app, expected, settings, certificate):
    # The identity argument must resolve to the certificate authorized by the profile.
    # Apple's requirement language identifies certificates by their SHA-1 fingerprint.
    fingerprint = hashlib.sha1(Path(certificate).read_bytes()).hexdigest()
    requirement = f'-R=certificate leaf = H"{fingerprint}"'
    subprocess.run(['codesign', '--verify', '--deep', '--strict', requirement, str(app)], check=True)
    actual = plistlib.loads(subprocess.check_output([
        'codesign', '-d', '--xml', '--entitlements', '-', str(app)
    ], stderr=subprocess.DEVNULL))
    verify_entitlements(actual, expected)
    verify_bundle(plistlib.loads((app / 'Contents/Info.plist').read_bytes()), settings)


# package_app(args): Preserve the previous installer until the new signed app
# and the app extracted from its installer both pass release verification.
def package_app(args):
    settings = app_store_settings()
    app = args.app.resolve()
    info = plistlib.loads((app / 'Contents/Info.plist').read_bytes())
    verify_bundle(info, settings)
    profile = plistlib.loads(subprocess.check_output([
        'security', 'cms', '-D', '-i', str(args.profile)
    ]))
    allowed = profile_entitlements(profile, info['CFBundleIdentifier'], args.certificate)
    source = Path(settings['SRCROOT']) / settings['CODE_SIGN_ENTITLEMENTS']
    expected = resolve_entitlements(source, allowed, settings)
    output = args.output.absolute()
    if output.suffix != '.pkg' or output.is_symlink() or (output.exists() and not output.is_file()):
        raise ValueError('The output must be a regular .pkg file.')
    output.parent.mkdir(parents=True, exist_ok=True)
    keychain = ['--keychain', str(args.keychain)] if args.keychain else []
    with tempfile.TemporaryDirectory(prefix='langmin-store-', dir=output.parent) as directory:
        work = Path(directory)
        signed_app = work / 'Langmin.app'
        shutil.copytree(app, signed_app)
        shutil.copy2(args.profile, signed_app / 'Contents/embedded.provisionprofile')
        entitlements = work / 'Distribution.entitlements'
        entitlements.write_bytes(plistlib.dumps(expected, sort_keys=True))
        subprocess.run([
            'codesign', '--force', '--timestamp', '--options', 'runtime', *keychain,
            '--sign', args.application_identity, '--entitlements', str(entitlements), str(signed_app),
        ], check=True)
        verify_app(signed_app, expected, settings, args.certificate)
        candidate = work / 'Langmin.pkg'
        subprocess.run([
            'productbuild', '--component', str(signed_app), '/Applications', *keychain,
            '--sign', args.installer_identity, str(candidate),
        ], check=True)
        subprocess.run(['pkgutil', '--check-signature', str(candidate)], check=True)
        extracted = work / 'expanded'
        subprocess.run(['pkgutil', '--expand-full', str(candidate), str(extracted)], check=True)
        packaged_apps = list(extracted.rglob('Langmin.app'))
        if len(packaged_apps) != 1:
            raise ValueError('Expected one Langmin app in the installer.')
        verify_app(packaged_apps[0], expected, settings, args.certificate)
        candidate.replace(output)
    print(f'Verified {output}: iCloud environment is Production', flush=True)


# main(): Package an existing AppStore archive with explicit signing inputs.
def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--app', type=Path, required=True)
    parser.add_argument('--application-identity', required=True)
    parser.add_argument('--installer-identity', required=True)
    parser.add_argument('--profile', type=Path, required=True)
    parser.add_argument('--certificate', type=Path, required=True)
    parser.add_argument('--keychain', type=Path)
    parser.add_argument('--output', type=Path, default=ROOT / 'build/app-store/Langmin.pkg')
    package_app(parser.parse_args())


if __name__ == '__main__':
    main()

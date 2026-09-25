#!/usr/bin/env python3
"""Exercise release entitlement resolution without Apple services or credentials."""
from pathlib import Path
import copy
import datetime
import json
import hashlib
import plistlib
import shutil
import subprocess
import sys
import tempfile
import unittest
from unittest import mock

from package_app_store import (ENVIRONMENT, app_store_settings, profile_entitlements,
                               resolve_entitlements, verify_app, verify_bundle, verify_entitlements)

ROOT = Path(__file__).resolve().parent.parent


class AppStorePackageTests(unittest.TestCase):
    # setUp(): Give each test isolated inputs and an explicit release environment.
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.root = Path(self.directory.name)
        self.source = self.root / 'Requested.entitlements'
        self.source.write_bytes((ROOT / 'langmin/LangminCloud.entitlements').read_bytes())
        self.allowed = {ENVIRONMENT: ['Production', 'Development']}
        self.settings = {'LANGMIN_ICLOUD_ENVIRONMENT': 'Production'}

    # test_resolves_selected_environment(): Reproduce the profile-array bug with
    # the actual application entitlement file and require a scalar result.
    def test_resolves_selected_environment(self):
        actual = resolve_entitlements(self.source, self.allowed, self.settings)
        self.assertEqual(actual[ENVIRONMENT], 'Production')
        self.assertIsInstance(actual[ENVIRONMENT], str)
        self.assertEqual(actual['com.apple.developer.icloud-services'], ['CloudKit'])
        self.assertEqual(actual['com.apple.developer.icloud-container-identifiers'], ['iCloud.tools.min.langmin'])
        self.assertIs(actual['com.apple.security.app-sandbox'], True)

    # test_profile_order_does_not_select_environment(): Profile permission order
    # must never override the build configuration.
    def test_profile_order_does_not_select_environment(self):
        self.allowed[ENVIRONMENT].reverse()
        actual = resolve_entitlements(self.source, self.allowed, self.settings)
        self.assertEqual(actual[ENVIRONMENT], 'Production')

    # test_missing_or_invalid_settings_fail(): Missing, development, nested, and
    # non-string values cannot fall back to the profile's permitted environments.
    def test_missing_or_invalid_settings_fail(self):
        for settings in ({}, {'LANGMIN_ICLOUD_ENVIRONMENT': 'Development'},
                         {'LANGMIN_ICLOUD_ENVIRONMENT': ['Production']},
                         {'LANGMIN_ICLOUD_ENVIRONMENT': '$(OTHER_SETTING)'},
                         {'LANGMIN_ICLOUD_ENVIRONMENT': ''}):
            with self.subTest(settings=settings), self.assertRaises(ValueError):
                resolve_entitlements(self.source, self.allowed, settings)

    # test_profile_must_permit_production(): Reject absent or development-only
    # permissions even when the project requests the right environment.
    def test_profile_must_permit_production(self):
        for permitted in (None, [], ['Development'], 'Development', {'Production': True}):
            with self.subTest(permitted=permitted), self.assertRaises(ValueError):
                resolve_entitlements(self.source, {ENVIRONMENT: permitted}, self.settings)

    # test_scalar_profile_permission(): Accept profiles that authorize Production
    # directly instead of listing permitted values.
    def test_scalar_profile_permission(self):
        actual = resolve_entitlements(self.source, {ENVIRONMENT: 'Production'}, self.settings)
        self.assertEqual(actual[ENVIRONMENT], 'Production')

    # test_malformed_source_environment(): Reject arrays at the source, not only
    # arrays accidentally copied from provisioning profiles.
    def test_malformed_source_environment(self):
        self.source.write_bytes(plistlib.dumps({ENVIRONMENT: ['Production', 'Development']}))
        with self.assertRaises(ValueError):
            resolve_entitlements(self.source, self.allowed, self.settings)

    # test_final_signature_is_checked_independently(): A matching malformed
    # expected value cannot make a broken final signature pass verification.
    def test_final_signature_is_checked_independently(self):
        for environment in (['Production', 'Development'], ['Production'], 'Development', None):
            actual = {ENVIRONMENT: environment}
            with self.subTest(environment=environment), self.assertRaises(ValueError):
                verify_entitlements(actual, copy.deepcopy(actual))

    # test_other_signature_changes_fail(): Missing or unexpected entitlements
    # must be detected even when the release environment is correct.
    def test_other_signature_changes_fail(self):
        expected = resolve_entitlements(self.source, self.allowed, self.settings)
        verify_entitlements(copy.deepcopy(expected), expected)
        for changed in ({ENVIRONMENT: 'Production'}, expected | {'get-task-allow': True}):
            with self.subTest(changed=changed), self.assertRaises(ValueError):
                verify_entitlements(changed, expected)

    # test_profile_identity_is_added(): Preserve concrete signing identifiers
    # without confusing them with application build settings.
    def test_profile_identity_is_added(self):
        identities = {'com.apple.application-identifier': 'TEAM.tools.min.langmin',
                      'com.apple.developer.team-identifier': 'TEAM',
                      'keychain-access-groups': ['TEAM.tools.min.langmin']}
        actual = resolve_entitlements(self.source, self.allowed | identities, self.settings)
        for key, value in identities.items():
            self.assertEqual(actual[key], value)

    # test_xcode_selection(): Use full Xcode when command-line tools are selected,
    # while respecting a caller's explicitly selected Xcode installation.
    def test_xcode_selection(self):
        output = json.dumps([{'target': 'Langmin', 'buildSettings': self.settings}]).encode()
        for configured in (None, '/Applications/OtherXcode.app/Contents/Developer'):
            environment = {} if configured is None else {'DEVELOPER_DIR': configured}
            with self.subTest(configured=configured), mock.patch.dict('os.environ', environment, clear=True), mock.patch('package_app_store.subprocess.check_output', return_value=output) as command:
                self.assertEqual(app_store_settings(), self.settings)
                expected = configured or '/Applications/Xcode.app/Contents/Developer'
                self.assertEqual(command.call_args.kwargs['env']['DEVELOPER_DIR'], expected)

    # test_stale_archive_is_rejected(): A new package cannot silently retain the
    # previous build number or package a different app.
    def test_stale_archive_is_rejected(self):
        settings = {'PRODUCT_BUNDLE_IDENTIFIER': 'tools.min.langmin',
                    'MARKETING_VERSION': '2026.09.25', 'CURRENT_PROJECT_VERSION': '2026092501'}
        info = {'CFBundleIdentifier': 'tools.min.langmin',
                'CFBundleShortVersionString': '2026.09.25', 'CFBundleVersion': '2026092501'}
        verify_bundle(info, settings)
        for key in info:
            with self.subTest(key=key), self.assertRaises(ValueError):
                verify_bundle(info | {key: 'stale'}, settings)

    # signing_fixture(): Create isolated bundle metadata and a public certificate fixture.
    def signing_fixture(self):
        app = self.root / 'Fixture.app'
        (app / 'Contents/MacOS').mkdir(parents=True)
        info = {'CFBundleIdentifier': 'test.signer.fixture', 'CFBundleExecutable': 'Fixture',
                'CFBundlePackageType': 'APPL', 'CFBundleShortVersionString': '1.0', 'CFBundleVersion': '1'}
        (app / 'Contents/Info.plist').write_bytes(plistlib.dumps(info))
        settings = {'PRODUCT_BUNDLE_IDENTIFIER': 'test.signer.fixture',
                    'MARKETING_VERSION': '1.0', 'CURRENT_PROJECT_VERSION': '1'}
        certificate = self.root / 'certificate.cer'
        certificate.write_bytes(b'public test certificate')
        return app, settings, certificate

    # test_actual_signer_is_required(): The validated profile certificate must
    # constrain both signed-app and extracted-package verification.
    def test_actual_signer_is_required(self):
        app, settings, certificate = self.signing_fixture()
        expected = {ENVIRONMENT: 'Production'}
        with mock.patch('package_app_store.subprocess.run') as command, mock.patch(
                'package_app_store.subprocess.check_output', return_value=plistlib.dumps(expected)):
            verify_app(app, expected, settings, certificate)
        fingerprint = hashlib.sha1(certificate.read_bytes()).hexdigest()
        command.assert_called_once_with([
            'codesign', '--verify', '--deep', '--strict',
            f'-R=certificate leaf = H"{fingerprint}"', str(app)
        ], check=True)

    # test_signer_failure_stops_verification(): A wrong certificate cannot pass
    # merely because the bundle metadata and entitlements match.
    def test_signer_failure_stops_verification(self):
        app, settings, certificate = self.signing_fixture()
        with mock.patch('package_app_store.subprocess.run', side_effect=subprocess.CalledProcessError(3, 'codesign')), mock.patch(
                'package_app_store.subprocess.check_output') as entitlements:
            with self.assertRaises(subprocess.CalledProcessError):
                verify_app(app, {ENVIRONMENT: 'Production'}, settings, certificate)
        entitlements.assert_not_called()

    # test_adhoc_signature_is_rejected(): Exercise real codesign with a temporary
    # executable, without reading a Keychain or accessing distribution credentials.
    @unittest.skipUnless(sys.platform == 'darwin' and shutil.which('codesign') and shutil.which('xcrun'),
                         'Native signature verification requires macOS developer tools')
    def test_adhoc_signature_is_rejected(self):
        app, settings, certificate = self.signing_fixture()
        expected = {ENVIRONMENT: 'Production'}
        entitlements = self.root / 'entitlements.plist'
        entitlements.write_bytes(plistlib.dumps(expected))
        subprocess.run(['xcrun', 'clang', '-x', 'c', '-o', str(app / 'Contents/MacOS/Fixture'), '-'],
                       input=b'int main(void) { return 0; }\n', check=True)
        subprocess.run(['codesign', '--force', '--sign', '-', '--entitlements', str(entitlements), str(app)], check=True)
        # Establish that this is a valid signature before checking its release signer.
        subprocess.run(['codesign', '--verify', '--deep', '--strict', str(app)], check=True)
        with self.assertRaises(subprocess.CalledProcessError):
            verify_app(app, expected, settings, certificate)

    # test_distribution_profile_validation(): Reject expired, development,
    # mismatched, and unauthorized profiles using synthetic certificate bytes.
    def test_distribution_profile_validation(self):
        certificate = self.root / 'certificate.cer'
        certificate.write_bytes(b'public test certificate')
        profile = {'Entitlements': {'com.apple.application-identifier': 'TEAM.tools.min.langmin',
                                   'com.apple.developer.team-identifier': 'TEAM'},
                   'ExpirationDate': datetime.datetime.now(datetime.timezone.utc) + datetime.timedelta(days=1),
                   'DeveloperCertificates': [certificate.read_bytes()]}
        self.assertEqual(profile_entitlements(profile, 'tools.min.langmin', certificate), profile['Entitlements'])
        invalid = [profile | {'ExpirationDate': datetime.datetime(2000, 1, 1)},
                   profile | {'DeveloperCertificates': [b'different certificate']},
                   profile | {'ProvisionedDevices': ['device']},
                   profile | {'ProvisionsAllDevices': True},
                   profile | {'Entitlements': profile['Entitlements'] | {'get-task-allow': True}},
                   profile | {'Entitlements': profile['Entitlements'] | {'com.apple.security.get-task-allow': True}},
                   profile | {'Entitlements': profile['Entitlements'] | {'com.apple.application-identifier': 'TEAM.other'}}]
        for value in invalid:
            with self.subTest(value=value), self.assertRaises(ValueError):
                profile_entitlements(value, 'tools.min.langmin', certificate)


if __name__ == '__main__':
    unittest.main(verbosity=2)

#!/usr/bin/env python3
"""Check that archives use purchases and both configurations include the complete app."""
from pathlib import Path
import json
import plistlib
import subprocess
import unittest
import xml.etree.ElementTree as ET

ROOT = Path(__file__).resolve().parent.parent
PROJECT = ROOT / 'langmin/Langmin.xcodeproj'


# Validate build metadata without signing, opening the app, or contacting Apple.
class DistributionTests(unittest.TestCase):
    # setUpClass(cls): Read Xcode's project format through the system plist
    # parser.
    @classmethod
    def setUpClass(cls):
        cls.objects = json.loads(subprocess.check_output([
            'plutil', '-convert', 'json', '-o', '-', str(PROJECT / 'project.pbxproj')
        ]))['objects']
        cls.target = next(v for v in cls.objects.values() if v['isa'] == 'PBXNativeTarget')
        cls.project = next(v for v in cls.objects.values() if v['isa'] == 'PBXProject')

    # configurations(self, owner): Resolve named configurations for either the
    # project or its app target.
    def configurations(self, owner):
        identifiers = self.objects[owner['buildConfigurationList']]['buildConfigurations']
        return {self.objects[key]['name']: self.objects[key]['buildSettings'] for key in identifiers}

    # test_archive_requires_store_configuration(self): Archives must never
    # include the private local purchase override.
    def test_archive_requires_store_configuration(self):
        scheme = ET.parse(PROJECT / 'xcshareddata/xcschemes/Langmin.xcscheme').getroot()
        self.assertEqual(scheme.find('ArchiveAction').get('buildConfiguration'), 'AppStore')
        project = self.configurations(self.project)
        target = self.configurations(self.target)
        self.assertEqual(set(project), {'Debug', 'Release', 'AppStore'})
        self.assertEqual(set(target), set(project))
        for name, settings in target.items():
            with self.subTest(configuration=name):
                effective = project[name] | settings
                self.assertEqual(effective['PRODUCT_BUNDLE_IDENTIFIER'], 'tools.min.langmin')
                version = effective['MARKETING_VERSION']
                build = effective['CURRENT_PROJECT_VERSION']
                self.assertRegex(version, r'^\d{4}\.\d{2}\.\d{2}$')
                self.assertRegex(build, r'^\d{10}$')
                self.assertEqual(build[:8], version.replace('.', ''))
                self.assertEqual(effective['LANGMIN_URL_SCHEME'], 'langmin')
                self.assertEqual(effective['ARCHS'], 'arm64')
                self.assertNotIn('LANGMIN_LOCAL_BUILD', effective.get('SWIFT_ACTIVE_COMPILATION_CONDITIONS', ''))
                self.assertNotIn('LANGMIN_LOCAL_BUILD', effective.get('OTHER_SWIFT_FLAGS', ''))
                self.assertEqual('LANGMIN_APP_STORE' in effective.get('SWIFT_ACTIVE_COMPILATION_CONDITIONS', ''), name == 'AppStore')
                self.assertEqual(effective['CODE_SIGN_ENTITLEMENTS'], 'LangminCloud.entitlements' if name == 'AppStore' else 'LangminApp.entitlements')

    # test_xcode_includes_every_swift_file_once(self): The Xcode source list
    # must match the standalone builder, including every cloud feature.
    def test_xcode_includes_every_swift_file_once(self):
        phase = next(self.objects[key] for key in self.target['buildPhases']
                     if self.objects[key]['isa'] == 'PBXSourcesBuildPhase')
        paths = [self.objects[self.objects[key]['fileRef']]['path'] for key in phase['files']]
        expected = {str(p.relative_to(ROOT / 'langmin')) for p in (ROOT / 'langmin/Sources').rglob('*.swift')}
        self.assertEqual(set(paths), expected)
        self.assertEqual(len(paths), len(expected))
        for value in self.objects.values():
            # Check only project-relative file references against the checkout.
            if value['isa'] == 'PBXFileReference' and value.get('sourceTree') == '<group>':
                self.assertTrue((ROOT / 'langmin' / value['path']).exists(), value['path'])

    # test_entitlements_and_privacy(self): CloudKit provisioning and the shared
    # privacy manifest must match shipped capabilities.
    def test_entitlements_and_privacy(self):
        cloud = plistlib.loads((ROOT / 'langmin/LangminCloud.entitlements').read_bytes())
        local = plistlib.loads((ROOT / 'langmin/LangminApp.entitlements').read_bytes())
        self.assertEqual(cloud['com.apple.developer.icloud-container-identifiers'], ['iCloud.tools.min.langmin'])
        self.assertNotIn('com.apple.developer.icloud-services', local)
        manifest = plistlib.loads((ROOT / 'langmin/Resources/PrivacyInfo.xcprivacy').read_bytes())
        data_types = {x['NSPrivacyCollectedDataType'] for x in manifest['NSPrivacyCollectedDataTypes']}
        self.assertIn('NSPrivacyCollectedDataTypeAudioData', data_types)
        self.assertIn('NSPrivacyCollectedDataTypeOtherUserContent', data_types)
        self.assertEqual((ROOT / 'PRIVACY.md').read_bytes(), (ROOT / 'langmin/Resources/PRIVACY.md').read_bytes())

        info = plistlib.loads((ROOT / 'langmin/LangminInfo.plist').read_bytes())
        self.assertEqual(info['NSHumanReadableCopyright'], '© 2026 Ilia Ross')
        app = (ROOT / 'langmin/Sources/LangminApp/main.swift').read_text()
        self.assertIn('string: "GitHub.com/iliaross"', app)
        self.assertIn('URL(string: "https://github.com/iliaross")', app)
        self.assertIn('iconView,\n            nameLabel,\n            versionLabel,\n            copyrightLabel,\n            profileButton', app)
        self.assertIn('MinToolsAboutPanelController.shared.show(applicationName: appName)', app)
        self.assertIn('let size = NSSize(width: 280, height: 174)', app)
        self.assertIn('stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 10)', app)


# Run the distribution checks when invoked directly.
if __name__ == '__main__':
    unittest.main()

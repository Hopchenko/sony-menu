"""Keep Finder-icon metadata support from masking damaged signed resources."""
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / 'Tools'))
from bundle_signature import verify_bundle_signature


class BundleSignatureTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix='sony-menu-signature-check-')
        self.addCleanup(self.temporary.cleanup)
        self.app = Path(self.temporary.name) / 'Sony Headphone Control.app'
        subprocess.run(['/usr/bin/ditto', str(ROOT / 'build/Applications.noindex/Sony Headphone Control.app'), str(self.app)], check=True)
        subprocess.run(['/usr/bin/codesign', '--force', '--sign', '-', '--timestamp=none', str(self.app)], capture_output=True, check=True)

    def custom_icon(self):
        (self.app / 'Icon\r').write_bytes(b'')
        info = bytes(8) + b'\x04\x00' + bytes(22)
        subprocess.run(['/usr/bin/xattr', '-wx', 'com.apple.FinderInfo', info.hex(), str(self.app)], check=True)

    def test_clean_bundle_uses_strict_verification(self):
        self.assertEqual(verify_bundle_signature(self.app), 'strict signature')

    def test_custom_icon_verifies_without_modifying_original(self):
        self.custom_icon()
        original = (self.app / 'Contents/_CodeSignature/CodeResources').read_bytes()
        self.assertIn('original code validity confirmed', verify_bundle_signature(self.app))
        self.assertTrue((self.app / 'Icon\r').exists())
        self.assertEqual(original, (self.app / 'Contents/_CodeSignature/CodeResources').read_bytes())
        subprocess.run(['/usr/bin/xattr', '-p', 'com.apple.FinderInfo', str(self.app)], capture_output=True, check=True)

    def test_sealed_resource_tampering_is_rejected(self):
        self.custom_icon()
        resource = self.app / 'Contents/Resources/HeadphonesSilver.png'
        resource.write_bytes(resource.read_bytes() + b'tampered')
        with self.assertRaises(RuntimeError):
            verify_bundle_signature(self.app)

    def test_custom_flag_is_required(self):
        (self.app / 'Icon\r').write_bytes(b'')
        subprocess.run(['/usr/bin/xattr', '-wx', 'com.apple.FinderInfo', (b'META' + bytes(28)).hex(), str(self.app)], check=True)
        with self.assertRaises(RuntimeError):
            verify_bundle_signature(self.app)

    def test_metadata_inside_sealed_resources_is_rejected(self):
        self.custom_icon()
        resource = self.app / 'Contents/Resources/HeadphonesSilver.png'
        subprocess.run(['/usr/bin/xattr', '-wx', 'com.apple.FinderInfo', (b'META' + bytes(28)).hex(), str(resource)], check=True)
        with self.assertRaises(RuntimeError):
            verify_bundle_signature(self.app)

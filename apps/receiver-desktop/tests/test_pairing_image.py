import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import time
import unittest

from thumble_receiver.pairing import Invitation
from thumble_receiver.pairing_image import PairingImage, pairing_png


class PairingImageTests(unittest.TestCase):
    def test_png_private_file_heartbeat_and_immediate_clear(self):
        with tempfile.TemporaryDirectory() as temporary:
            export = PairingImage(temporary)
            invitation = Invitation('192.168.1.2', 1234, '0' * 64)
            link = invitation.renew()
            export.publish(link, invitation.expires)
            value = json.loads(export.path.read_bytes())
            self.assertEqual(value['version'], 1)
            self.assertNotIn(invitation.token, export.path.read_text())
            self.assertEqual(pairing_png(link)[:8], b'\x89PNG\r\n\x1a\n')
            if os.name != 'nt':
                self.assertEqual(export.path.stat().st_mode & 0o777, 0o600)
            export.publish('', invitation.expires)
            self.assertFalse(export.path.exists())

    def test_actual_node_mcp_reader_accepts_the_published_private_image(self):
        if not shutil.which('node'):
            self.skipTest('Node is required for cross-runtime MCP verification')
        with tempfile.TemporaryDirectory() as temporary:
            export = PairingImage(temporary)
            invitation = Invitation('192.168.1.2', 1234, '0' * 64)
            export.publish(invitation.renew(), invitation.expires)
            module = Path(__file__).resolve().parents[3] / 'packages/profile-tools/src/pairing-code.js'
            script = "const {showPairingCode}=await import(process.env.THUMBLE_QA_MODULE); if(process.platform==='win32'){const {checkWindowsPairingFile}=await import(new URL('./pairing-permissions.js',process.env.THUMBLE_QA_MODULE));try{await checkWindowsPairingFile(process.env.THUMBLE_QA_DIR+'/pairing-code.json')}catch(e){console.error(JSON.stringify({message:e.message,acl:e.acl,stderr:e.stderr}));throw e}} const result=await showPairingCode({directory:process.env.THUMBLE_QA_DIR}); if(result.content[1].mimeType!=='image/png')process.exit(1); console.log('PASS private MCP PNG');"
            result = subprocess.run(['node', '--input-type=module', '-e', script],
                capture_output=True, text=True, timeout=10,
                env={**os.environ, 'THUMBLE_QA_MODULE': module.as_uri(), 'THUMBLE_QA_DIR': temporary})
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertIn('PASS private MCP PNG', result.stdout)
            export.clear()


if __name__ == '__main__':
    unittest.main()

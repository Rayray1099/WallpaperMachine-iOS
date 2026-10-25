#!/usr/bin/env python3
"""Official client import: never the CLI, never homemade crypto, never token contents."""
from __future__ import annotations

import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

QA_DIR = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(QA_DIR))

import official_client  # noqa: E402


FAKE_CLIENT = '''"""iCTRL client — pairing + encrypted-envelope JSON-RPC (protocol v1)."""

STORE = "/tmp/token.json"
LABEL_MAC = b"mac"
LABEL_ENC_REQ = b"enc"
LABEL_ENC_RESP = b"resp"
LABEL_PAIR = b"pair"
LABEL_WRAP = b"wrap"


def call(host, method, params=None, timeout=60.0, rpc_id=1):
    return {"result": {"message": "ok"}}


def load_token(host):
    return None


def save_token(host, record):
    pass


def _keystream_xor(key, nonce, data):
    return data
'''


class LoadOfficialClient(unittest.TestCase):
    def setUp(self):
        self.directory = Path(tempfile.mkdtemp())
        self.addCleanup(shutil.rmtree, self.directory, ignore_errors=True)

    def test_repository_parent_client_loads_when_present(self):
        try:
            client = official_client.load_official_client()
        except official_client.OfficialClientError as error:
            self.skipTest(str(error))
        self.assertTrue(client.path.is_file())
        self.assertEqual(len(client.sha256), 64)
        self.assertTrue(callable(client.call))
        self.assertTrue(str(client.token_store).endswith("token.json"))
        # Metadata only: the harness must never read credential contents.
        self.assertTrue(client.token_store_exists() in (True, False))

    def test_fake_module_with_protocol_surface_loads(self):
        path = self.directory / "fake_client.py"
        path.write_text(FAKE_CLIENT, encoding="utf-8")
        client = official_client.load_official_client(path)
        self.assertEqual(client.module.call("host", "device_info"), {"result": {"message": "ok"}})

    def test_module_without_crypto_surface_is_rejected(self):
        path = self.directory / "not_official.py"
        path.write_text('"""iCTRL client — encrypted-envelope JSON-RPC"""\n', encoding="utf-8")
        with self.assertRaises(official_client.OfficialClientError) as raised:
            official_client.load_official_client(path)
        self.assertIn("missing", str(raised.exception))

    def test_unrelated_module_is_rejected(self):
        path = self.directory / "other.py"
        path.write_text('"""Some helper."""\n', encoding="utf-8")
        with self.assertRaises(official_client.OfficialClientError):
            official_client.load_official_client(path)

    def test_missing_explicit_path_is_rejected(self):
        with self.assertRaises(official_client.OfficialClientError):
            official_client.load_official_client(self.directory / "absent.py")

    def test_environment_override_points_at_client(self):
        path = self.directory / "fake_client.py"
        path.write_text(FAKE_CLIENT, encoding="utf-8")
        with patch.dict(os.environ, {official_client.qa_paths.CLIENT_ENV: str(path)}):
            client = official_client.load_official_client()
        self.assertEqual(client.path, path.resolve())

    @unittest.skipUnless(sys.platform == "win32", "the os.uname defect is Windows-specific")
    def test_official_cli_is_broken_on_windows_which_is_why_we_import(self):
        try:
            client = official_client.load_official_client()
        except official_client.OfficialClientError as error:
            self.skipTest(str(error))
        completed = subprocess.run([sys.executable, str(client.path), "--help"],
                                   capture_output=True, text=True, timeout=30)
        combined = completed.stdout + completed.stderr
        self.assertNotEqual(completed.returncode, 0)
        self.assertIn("uname", combined)


if __name__ == "__main__":
    unittest.main()

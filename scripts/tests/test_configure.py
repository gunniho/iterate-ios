import contextlib
import io
import json
import re
import sys
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import configure


class SetupTests(unittest.TestCase):
    def setUp(self):
        workspace = tempfile.TemporaryDirectory()
        self.addCleanup(workspace.cleanup)
        root = Path(workspace.name)
        self.app = root / "app"
        self.mind = root / "mind"
        self.mind.mkdir()
        self.package = self.mind / "package.json"
        self.package.write_text('{"name":"example-config","dependencies":{}}\n')
        modules = self.app / "Server" / "mind"
        modules.mkdir(parents=True)
        for name in configure.MODULES:
            (modules / name).write_text((configure.REPO / "Server" / "mind" / name).read_text())
        self.local = self.app / "Configuration" / "Local.xcconfig"
        self.installed = self.mind / "apps" / "iterate-ios"
        self.pin = "1a" * 32
        self.args = ["--domain", "field.example", "--control-host", "api.field.example",
                     "--dash-host", "web.field.example", "--bundle-id", "net.example.field",
                     "--team-id", "DEMO123456", "--mind-id", self.pin, "--mind-config", str(self.mind)]

    def run_setup(self, args):
        with patch.object(configure, "REPO", self.app), contextlib.redirect_stdout(io.StringIO()):
            configure.main(args)

    def test_phone_and_backend_use_the_same_deployment(self):
        self.run_setup(self.args)
        config = self.local.read_text()
        self.assertIn("ITERATE_CONTROL_HOST = api.field.example", config)
        self.assertIn("ITERATE_MIND_ID = " + self.pin, config)
        self.assertIn("ITERATE_BUNDLE_ID = net.example.field", config)
        settings = json.loads((self.installed / "settings.js").read_text().removeprefix("export const deployment = ").rstrip(";\n"))
        self.assertEqual(settings, {"apexHost": "field.example", "controlHost": "api.field.example",
                                   "dashHost": "web.field.example", "bundleID": "net.example.field",
                                   "teamID": "DEMO123456"})
        self.assertEqual(json.loads(self.package.read_text())["dependencies"]["@iterate-com/voice"], configure.VOICE_VERSION)
        self.assertEqual((self.mind / "voice.ts").read_text(), configure.VOICE_SHIM)
        installed_at = (self.installed / "backend.ts").stat().st_mtime_ns
        self.run_setup(self.args)
        self.assertEqual((self.installed / "backend.ts").stat().st_mtime_ns, installed_at)

    def test_every_installed_module_finds_its_imports(self):
        self.run_setup(self.args)
        present = {path.name for path in self.installed.iterdir()}
        for name in configure.MODULES:
            for target in re.findall(r'from\s+"\./([^"]+)"', (self.installed / name).read_text()):
                self.assertIn(target, present, f"{name} imports {target}")

    def test_configuring_a_fork_respects_existing_worker_and_local_edits(self):
        (self.mind / "worker.ts").write_text("// Existing worker\n")
        (self.mind / "voice.ts").write_text("// Existing voice entrypoint\n")
        self.package.write_text('{"dependencies":{"@iterate-com/voice":"custom"}}\n')
        self.run_setup(self.args)
        (self.installed / "memory.js").write_text("// Local override\n")
        original = self.local.read_text()
        modified = [*self.args, "--domain", "other.example"]
        with self.assertRaisesRegex(ValueError, "memory.js"):
            self.run_setup(modified)
        self.assertEqual(self.local.read_text(), original)
        self.run_setup([*modified, "--replace-backend"])
        self.assertIn("ITERATE_APEX_HOST = other.example", self.local.read_text())
        self.assertEqual((self.mind / "worker.ts").read_text(), "// Existing worker\n")
        self.assertEqual((self.mind / "voice.ts").read_text(), "// Existing voice entrypoint\n")
        self.assertEqual(json.loads(self.package.read_text())["dependencies"]["@iterate-com/voice"], "custom")

    def test_domain_only_setup_discovers_identity_once(self):
        with patch.object(configure, "discover_mind", return_value=self.pin) as discover:
            self.run_setup(["--domain", "https://Field.Example/"])
        discover.assert_called_once_with("iterate.field.example")
        self.assertIn("ITERATE_DASH_HOST = dash.field.example", self.local.read_text())
        self.assertFalse(self.installed.exists())

    def test_public_identity_document_request_identifies_the_setup_client(self):
        payload = json.dumps({"mind": self.pin}).encode()
        with patch.object(configure, "build_opener") as opener:
            opener.return_value.open.return_value = io.BytesIO(payload)
            self.assertEqual(configure.discover_mind("api.field.example"), self.pin)
        request = opener.return_value.open.call_args.args[0]
        self.assertEqual(request.full_url, "https://api.field.example/.well-known/iterate")
        self.assertEqual(request.get_header("Accept"), "application/json")
        self.assertTrue(request.get_header("User-agent").startswith("Iterate-iOS-Setup/"))

    def test_invalid_origins_and_placeholder_id_fail_before_writing(self):
        for hostname in ("api", "http://api.field.example", "field.example/path",
                         "https://me@api.field.example", "api.field.example:8000"):
            with self.subTest(hostname=hostname), self.assertRaises(ValueError):
                self.run_setup([*self.args, "--control-host", hostname])
        with self.assertRaises(ValueError):
            self.run_setup([*self.args, "--mind-id", "0" * 64])
        self.assertFalse(self.local.exists())
        self.assertFalse(self.installed.exists())

"""scripts/variant, run on bundles signed in the test with the entitlements each case names.

Signed for real, ad hoc, so the read make-pkg relies on is the one under test: codesign's
answer for each signature, not a plist handed to the judgement beside it.
"""
import plistlib
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path

reader = Path(__file__).resolve().parent.parent / "variant"

SANDBOX = {"com.apple.security.app-sandbox": True}
# What every app build signs in, the offline build's whole set.
APP = {
    **SANDBOX,
    "com.apple.security.device.audio-input": True,
    "com.apple.security.temporary-exception.mach-register.global-name": ["ai.promptctl.low-talker.hotkey"],
    "com.apple.security.temporary-exception.mach-lookup.global-name": ["ai.promptctl.low-talker.inputmethod.dictation.insert"],
}
INPUT_METHOD = {
    **SANDBOX,
    "com.apple.security.temporary-exception.mach-lookup.global-name": ["ai.promptctl.low-talker.hotkey"],
}
SERVER = {"com.apple.security.network.server": True}
CLIENT = {"com.apple.security.network.client": True}


class VariantTests(unittest.TestCase):
    def setUp(self):
        self.directory = Path(tempfile.mkdtemp())
        self.addCleanup(shutil.rmtree, self.directory)

    def signed(self, name, entitlements):
        """A copy of a real executable, signed ad hoc with `entitlements`, or with none for None."""
        binary = self.directory / name
        shutil.copy("/usr/bin/true", binary)
        command = ["codesign", "--force", "--sign", "-"]
        if entitlements is not None:
            plist = self.directory / f"{name}.entitlements"
            plist.write_bytes(plistlib.dumps(entitlements))
            command += ["--entitlements", str(plist)]
        subprocess.run([*command, str(binary)], check=True, capture_output=True)
        return binary

    def read(self, app, input_method):
        return subprocess.run([str(reader), str(app), str(input_method)], capture_output=True)

    def assertVariant(self, app, variant, input_method=INPUT_METHOD):
        result = self.read(self.signed("app", app), self.signed("input-method", input_method))
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.decode(), variant + "\n")

    def assertRefused(self, app, input_method, saying):
        result = self.read(app, input_method)
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(result.stdout, b"")
        self.assertIn(saying.encode(), result.stderr)

    def assertAppRefused(self, app):
        self.assertRefused(self.signed("app", app), self.signed("input-method", INPUT_METHOD),
                           "neither the offline nor the network build")

    def assertInputMethodRefused(self, input_method):
        self.assertRefused(self.signed("app", APP), self.signed("input-method", input_method),
                           "in either build it is sandboxed with no network key")

    def test_no_network_key_is_offline(self):
        self.assertVariant(APP, "offline")

    def test_the_server_key_alone_is_network(self):
        self.assertVariant({**APP, **SERVER}, "network")

    def test_an_app_with_a_client_key_is_refused(self):
        self.assertAppRefused({**APP, **CLIENT})
        self.assertAppRefused({**APP, **SERVER, **CLIENT})

    def test_an_app_with_the_server_key_set_false_is_refused(self):
        self.assertAppRefused({**APP, "com.apple.security.network.server": False})

    def test_an_app_outside_the_sandbox_is_refused(self):
        self.assertAppRefused({k: v for k, v in APP.items() if k != "com.apple.security.app-sandbox"})
        self.assertAppRefused({**APP, "com.apple.security.app-sandbox": False})

    def test_an_input_method_outside_the_sandbox_is_refused(self):
        self.assertInputMethodRefused({k: v for k, v in INPUT_METHOD.items() if k != "com.apple.security.app-sandbox"})
        self.assertInputMethodRefused({**INPUT_METHOD, "com.apple.security.app-sandbox": False})

    def test_an_input_method_with_any_network_key_is_refused(self):
        self.assertInputMethodRefused({**INPUT_METHOD, **CLIENT})
        self.assertInputMethodRefused({**INPUT_METHOD, **SERVER})

    def test_a_bundle_signed_with_no_entitlements_is_refused(self):
        self.assertRefused(self.signed("app", APP), self.signed("input-method", None), "signed with no entitlements")
        self.assertRefused(self.signed("app", None), self.signed("input-method", INPUT_METHOD), "signed with no entitlements")

    def test_a_bundle_that_is_not_signed_is_refused(self):
        unsigned = self.directory / "unsigned"
        unsigned.write_bytes(b"")
        self.assertRefused(self.signed("app", APP), unsigned, "is not signed")
        self.assertRefused(unsigned, self.signed("input-method", INPUT_METHOD), "is not signed")


if __name__ == "__main__":
    unittest.main()

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
# The keys every app build signs in, the offline build's whole set. The Mach services are named
# under the test app's identifier, as the product's own are under the app's.
APP = {
    **SANDBOX,
    "com.apple.security.device.audio-input": True,
    "com.apple.security.files.user-selected.read-only": True,
    "com.apple.security.temporary-exception.mach-register.global-name": ["example.app.hotkey"],
    "com.apple.security.temporary-exception.mach-lookup.global-name": ["example.app.insert"],
}
INPUT_METHOD = {
    **SANDBOX,
    "com.apple.security.temporary-exception.mach-register.global-name": ["example.app.insert"],
    "com.apple.security.temporary-exception.mach-lookup.global-name": ["example.app.hotkey"],
}
SERVER = {"com.apple.security.network.server": True}
CLIENT = {"com.apple.security.network.client": True}
# A sandbox rule of the bundle's own, which needs no network key to let it connect out.
SBPL = {"com.apple.security.temporary-exception.sbpl": ["(allow network-outbound)"]}


class VariantTests(unittest.TestCase):
    def setUp(self):
        self.directory = Path(tempfile.mkdtemp())
        self.addCleanup(shutil.rmtree, self.directory)

    def bundle(self, name, programs={}):
        """A bundle whose executable is a copy of a real one, holding each of `programs`, a path
        in it mapped to the file copied there."""
        bundle = Path(tempfile.mkdtemp(dir=self.directory)) / f"{name}.app"
        (bundle / "Contents").mkdir(parents=True)
        (bundle / "Contents/Info.plist").write_bytes(
            plistlib.dumps({"CFBundleExecutable": name, "CFBundleIdentifier": f"example.{name}"}))
        for program, source in {f"Contents/MacOS/{name}": "/usr/bin/true", **programs}.items():
            (bundle / program).parent.mkdir(parents=True, exist_ok=True)
            shutil.copy(source, bundle / program)
        return bundle

    def signed(self, name, entitlements, programs={}):
        """A bundle signed ad hoc with `entitlements`, or with none for None."""
        bundle = self.bundle(name, programs)
        command = ["codesign", "--force", "--sign", "-"]
        if entitlements is not None:
            plist = bundle.parent / f"{name}.entitlements"
            plist.write_bytes(plistlib.dumps(entitlements))
            command += ["--entitlements", str(plist)]
        subprocess.run([*command, str(bundle)], check=True, capture_output=True)
        return bundle

    def unsigned(self, name):
        """A bundle with no signature at all, its executable's own removed."""
        bundle = self.bundle(name)
        subprocess.run(["codesign", "--remove-signature", str(bundle / "Contents/MacOS" / name)],
                       check=True, capture_output=True)
        return bundle

    def read(self, app, input_method):
        return subprocess.run([str(reader), str(app), str(input_method)], capture_output=True)

    def assertVariant(self, app, variant):
        result = self.read(self.signed("app", app), self.signed("input-method", INPUT_METHOD))
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
                           "in either build it is sandboxed and carries nothing else that could reach the network")

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

    def test_a_sandbox_rule_of_its_own_is_refused(self):
        self.assertAppRefused({**APP, **SBPL})
        self.assertInputMethodRefused({**INPUT_METHOD, **SBPL})

    def test_a_mach_service_not_the_products_own_is_refused(self):
        foreign = ["example.app.insert", "com.example.fetcher"]
        self.assertAppRefused({**APP, "com.apple.security.temporary-exception.mach-lookup.global-name": foreign})
        self.assertInputMethodRefused(
            {**INPUT_METHOD, "com.apple.security.temporary-exception.mach-register.global-name": foreign})
        # A name that only begins with the identifier is another product's.
        self.assertAppRefused(
            {**APP, "com.apple.security.temporary-exception.mach-lookup.global-name": "example.apple.insert"})

    def test_a_bundle_carrying_a_program_besides_its_own_is_refused(self):
        script = self.directory / "helper"
        script.write_text("#!/bin/sh\n")
        script.chmod(0o755)
        for programs in ({"Contents/XPCServices/Service.xpc/Contents/MacOS/Service": "/usr/bin/true"},
                         {"Contents/Resources/helper": script}):
            self.assertRefused(self.signed("app", APP, programs), self.signed("input-method", INPUT_METHOD),
                               "its one program is Contents/MacOS/app")
            self.assertRefused(self.signed("app", APP), self.signed("input-method", INPUT_METHOD, programs),
                               "its one program is Contents/MacOS/input-method")

    def test_a_bundle_signed_with_no_entitlements_is_refused(self):
        self.assertRefused(self.signed("app", APP), self.signed("input-method", None), "signed with no entitlements")
        self.assertRefused(self.signed("app", None), self.signed("input-method", INPUT_METHOD), "signed with no entitlements")

    def test_a_bundle_that_is_not_signed_is_refused(self):
        self.assertRefused(self.signed("app", APP), self.unsigned("input-method"), "cannot read the signature")
        self.assertRefused(self.unsigned("app"), self.signed("input-method", INPUT_METHOD), "cannot read the signature")

if __name__ == "__main__":
    unittest.main()

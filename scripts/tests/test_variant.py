"""scripts/variant, run on bundles signed in the test with the entitlements each case names.

Signed for real, ad hoc, so the read make-pkg relies on is the one under test: codesign's
answer for each signature, not a plist handed to the judgement beside it. Each case signs the
sets xcodegen writes for the two bundles, or one of them changed, so a declared set variant
would refuse fails here rather than at the first package.
"""
import os
import plistlib
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path

scripts = Path(__file__).resolve().parent.parent
reader = scripts / "variant"
generated = scripts.parent / "App/Generated"
APP_DECLARED = generated / "LowTalker.entitlements"
INPUT_METHOD_DECLARED = generated / "LowTalker-InputMethod.entitlements"

TRUE = Path("/usr/bin/true")
SANDBOX = "com.apple.security.app-sandbox"
SERVER = {"com.apple.security.network.server": True}
LOOKUP = "com.apple.security.temporary-exception.mach-lookup.global-name"

# Every way one bundle's set may differ from its declared one, each a set either bundle must be
# refused for.
def without(key):
    return lambda declared: {k: v for k, v in declared.items() if k != key}

def adding(entitlements):
    return lambda declared: {**declared, **entitlements}

ANY_BUNDLE = {
    "with the client key": adding({"com.apple.security.network.client": True}),
    "outside the sandbox": without(SANDBOX),
    "with the sandbox off": adding({SANDBOX: False}),
    "with a sandbox rule of its own": adding({"com.apple.security.temporary-exception.sbpl": ["(allow network-outbound)"]}),
    "debuggable": adding({"com.apple.security.get-task-allow": True}),
    "looking up a service not declared": lambda declared: {**declared, LOOKUP: [*declared.get(LOOKUP, []), "com.example.fetcher"]},
}
APP_ONLY = {
    "with the server key set false": adding({"com.apple.security.network.server": False}),
    "with the server and client keys": adding({**SERVER, "com.apple.security.network.client": True}),
    "without a declared key": without("com.apple.security.device.audio-input"),
}
INPUT_METHOD_ONLY = {
    "with the server key": adding(SERVER),
}


class VariantTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        for path in (APP_DECLARED, INPUT_METHOD_DECLARED):
            if not path.exists():
                raise FileNotFoundError(f"{path} has not been generated; run `make test`, which runs xcodegen")
        cls.app = plistlib.loads(APP_DECLARED.read_bytes())
        cls.input_method = plistlib.loads(INPUT_METHOD_DECLARED.read_bytes())

    def setUp(self):
        self.directory = Path(tempfile.mkdtemp())
        self.addCleanup(shutil.rmtree, self.directory)

    def bundle(self, name, programs={}):
        """A bundle whose executable is a copy of a real one, holding each of `programs`, a path
        in it mapped to the file copied there, or to the text of a link there."""
        bundle = Path(tempfile.mkdtemp(dir=self.directory)) / f"{name}.app"
        (bundle / "Contents").mkdir(parents=True)
        (bundle / "Contents/Info.plist").write_bytes(
            plistlib.dumps({"CFBundleExecutable": name, "CFBundleIdentifier": f"example.{name}"}))
        for program, source in {f"Contents/MacOS/{name}": TRUE, **programs}.items():
            (bundle / program).parent.mkdir(parents=True, exist_ok=True)
            if isinstance(source, Path):
                shutil.copy(source, bundle / program)
            else:
                os.symlink(source, bundle / program)
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
        return subprocess.run([str(reader), str(app), str(APP_DECLARED), str(input_method), str(INPUT_METHOD_DECLARED)],
                              capture_output=True)

    def assertVariant(self, app, variant):
        result = self.read(self.signed("app", app), self.signed("input-method", self.input_method))
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.decode(), variant + "\n")

    def assertRefused(self, app, input_method, saying):
        result = self.read(app, input_method)
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(result.stdout, b"")
        self.assertIn(saying.encode(), result.stderr)

    def test_an_app_signed_as_declared_is_offline(self):
        self.assertVariant(self.app, "offline")

    def test_an_app_signed_as_declared_and_with_the_server_key_is_network(self):
        self.assertVariant({**self.app, **SERVER}, "network")

    def test_an_app_signed_with_any_other_set_is_refused(self):
        for case, change in {**ANY_BUNDLE, **APP_ONLY}.items():
            with self.subTest(case):
                self.assertRefused(self.signed("app", change(self.app)), self.signed("input-method", self.input_method),
                                   "which is neither the offline build's")

    def test_an_input_method_signed_with_any_other_set_is_refused(self):
        for case, change in {**ANY_BUNDLE, **INPUT_METHOD_ONLY}.items():
            with self.subTest(case):
                self.assertRefused(self.signed("app", self.app), self.signed("input-method", change(self.input_method)),
                                   "and in either build with")

    def test_a_bundle_carrying_a_program_besides_its_own_is_refused(self):
        script = self.directory / "helper"
        script.write_text("#!/bin/sh\n")
        script.chmod(0o755)
        for case, programs in {
            "an XPC service": {"Contents/XPCServices/Service.xpc/Contents/MacOS/Service": TRUE},
            "a script": {"Contents/Resources/helper": script},
            "a link": {"Contents/Resources/helper": "../Info.plist"},
        }.items():
            with self.subTest(case):
                self.assertRefused(self.signed("app", self.app, programs), self.signed("input-method", self.input_method),
                                   "its one program is Contents/MacOS/app")
                self.assertRefused(self.signed("app", self.app), self.signed("input-method", self.input_method, programs),
                                   "its one program is Contents/MacOS/input-method")

    def test_a_bundle_signed_with_no_entitlements_is_refused(self):
        self.assertRefused(self.signed("app", self.app), self.signed("input-method", None), "signed with no entitlements")
        self.assertRefused(self.signed("app", None), self.signed("input-method", self.input_method), "signed with no entitlements")

    def test_a_bundle_that_is_not_signed_is_refused(self):
        self.assertRefused(self.signed("app", self.app), self.unsigned("input-method"), "cannot read the signature")
        self.assertRefused(self.unsigned("app"), self.signed("input-method", self.input_method), "cannot read the signature")

    def test_a_path_that_is_not_a_bundle_is_refused(self):
        self.assertRefused(self.signed("app", self.app), self.directory, "has no Contents/Info.plist")
        self.assertRefused(self.directory, self.signed("input-method", self.input_method), "has no Contents/Info.plist")


if __name__ == "__main__":
    unittest.main()

"""scripts/check-licenses, run as `make test` runs it, against SBOMs built here."""
import json
import subprocess
import tempfile
import unittest
from pathlib import Path

gate = Path(__file__).resolve().parent.parent / "check-licenses"


def library(name, version, *licenses, vendored=()):
    component = {"type": "library", "name": name, "version": version, "licenses": list(licenses)}
    if vendored:
        component["components"] = list(vendored)
    return component


def spdx(id):
    return {"license": {"id": id}}


class CheckLicensesTests(unittest.TestCase):
    def check(self, *components):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "bom.cdx.json"
            path.write_text(json.dumps({"bomFormat": "CycloneDX", "components": list(components)}))
            return subprocess.run([str(gate), str(path)], capture_output=True, text=True)

    def assertRefused(self, result, line):
        self.assertEqual(result.returncode, 1, result.stdout)
        self.assertIn(line, result.stderr.splitlines())

    def test_accepted_licenses_pass(self):
        result = self.check(library("a", "1.0", spdx("MIT"), vendored=[library("b", "2.0", spdx("Apache-2.0"))]))
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_gpl_fails_naming_component_version_and_license(self):
        self.assertRefused(self.check(library("readline", "8.2", spdx("GPL-3.0-only"))),
                           "check-licenses: readline 8.2 is under GPL-3.0-only, which is not an accepted license")

    def test_gpl_vendored_inside_a_permissive_package_fails(self):
        result = self.check(library("host", "1.0", spdx("MIT"), vendored=[library("inner", "0.3", spdx("GPL-3.0-or-later"))]))
        self.assertRefused(result, "check-licenses: host 1.0 vendors inner 0.3 is under GPL-3.0-or-later, which is not an accepted license")

    def test_one_refused_license_among_accepted_ones_fails(self):
        self.assertRefused(self.check(library("dual", "1.0", spdx("MIT"), spdx("LGPL-2.1-only"))),
                           "check-licenses: dual 1.0 is under LGPL-2.1-only, which is not an accepted license")

    def test_no_license_fails_the_same_way(self):
        self.assertRefused(self.check(library("mystery", "0.1")),
                           "check-licenses: mystery 0.1 is under no license the generator identified, which is not an accepted license")

    def test_a_name_without_an_spdx_id_fails(self):
        self.assertRefused(self.check(library("custom", "1.0", {"license": {"name": "Our Own License"}})),
                           "check-licenses: custom 1.0 is under a license named 'Our Own License' with no SPDX id, which is not an accepted license")

    def test_an_expression_fails(self):
        self.assertRefused(self.check(library("either", "1.0", {"expression": "MIT OR GPL-3.0-only"})),
                           "check-licenses: either 1.0 is under the expression `MIT OR GPL-3.0-only`, which is not an accepted license")

    def test_ids_match_without_regard_to_case(self):
        self.assertEqual(self.check(library("a", "1.0", spdx("apache-2.0"))).returncode, 0)

    def test_a_model_is_named_by_its_repo(self):
        model = {"type": "data", "group": "openai", "name": "whisper", "licenses": [spdx("CC-BY-NC-4.0")]}
        self.assertRefused(self.check(model),
                           "check-licenses: openai/whisper is under CC-BY-NC-4.0, which is not an accepted license")

    def test_every_refusal_is_named(self):
        result = self.check(library("one", "1", spdx("GPL-2.0-only")), library("two", "2"))
        self.assertRefused(result, "check-licenses: one 1 is under GPL-2.0-only, which is not an accepted license")
        self.assertRefused(result, "check-licenses: two 2 is under no license the generator identified, which is not an accepted license")

    def test_an_sbom_with_no_components_fails(self):
        self.assertEqual(self.check().returncode, 1)


if __name__ == "__main__":
    unittest.main()

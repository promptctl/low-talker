"""scripts/sbom's hold of a rule's license id to the text it carries, run as `make test` runs it."""
import contextlib
import importlib.machinery
import importlib.util
import io
import re
import tempfile
import unittest
from pathlib import Path

scripts = Path(__file__).resolve().parent.parent


def load(name):
    loader = importlib.machinery.SourceFileLoader(name.replace("-", "_"), str(scripts / name))
    module = importlib.util.module_from_spec(importlib.util.spec_from_loader(loader.name, loader))
    loader.exec_module(module)
    return module


sbom = load("sbom")
check_licenses = load("check-licenses")

MIT = """MIT License

Copyright (c) 2024 Someone

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
"""

GPL_NOTICE = """This program is free software: you can redistribute it and/or modify
it under the terms of the GNU General Public License as published by
the Free Software Foundation, either version 3 of the License, or
(at your option) any later version.
"""


def rendered(template, optional):
    """A template's own text: each var as its `original`, each optional part kept or dropped."""
    out, dropped, position = [], 0, 0
    for mark in sbom.TEMPLATE_MARKUP.finditer(template):
        if not dropped:
            out.append(template[position:mark.start()])
        tag = mark.group(1)
        if tag == "beginOptional":
            dropped += 1 if dropped or not optional else 0
        elif tag == "endOptional":
            dropped -= 1 if dropped else 0
        elif not dropped:
            original = re.search(r'original="((?:[^"\\]|\\.)*)"', tag)
            out.append(original.group(1) if original else "")
        position = mark.end()
    return "".join(out + [template[position:]])


class LicenseTextTests(unittest.TestCase):
    def entry(self, spdx, text, **rule):
        with tempfile.TemporaryDirectory() as directory:
            (Path(directory) / "LICENSE").write_text(text)
            return sbom.license_entry("somepkg", Path(directory), {"license": spdx, "licenseFile": "LICENSE", **rule})

    def assertHeld(self, spdx, text, **rule):
        _, properties = self.entry(spdx, text, **rule)
        self.assertIn({"name": "low-talker:license-text", "value": f"SPDX License List 3.29.0 {spdx} template"}, properties)

    def assertRefused(self, spdx, text):
        stderr = io.StringIO()
        with contextlib.redirect_stderr(stderr), self.assertRaises(SystemExit) as exit:
            self.entry(spdx, text)
        self.assertEqual(exit.exception.code, 1)
        self.assertEqual(stderr.getvalue(),
                         f"sbom: somepkg: LICENSE does not carry the text of {spdx} as the SPDX License List 3.29.0 "
                         "template reads it, so the rule names a license the file does not state\n")

    def test_every_template_holds_its_own_text(self):
        for path in sorted((scripts.parent / "sbom" / "spdx").glob("*.template.txt")):
            template = path.read_text()
            for optional in (True, False):
                with self.subTest(template=path.name, optional=optional):
                    self.assertIsNotNone(sbom.template_pattern(template).search(sbom.comparable(rendered(template, optional))))

    def test_every_accepted_license_has_a_template(self):
        self.assertEqual({spdx.casefold() for spdx in check_licenses.ACCEPTED}, set(sbom.license_templates))

    def test_gpl_ruled_mit_stops_naming_the_component(self):
        self.assertRefused("MIT", GPL_NOTICE)

    def test_one_accepted_license_ruled_another_stops(self):
        self.assertRefused("Apache-2.0", MIT)

    def test_mit_holds(self):
        self.assertHeld("MIT", MIT)

    def test_text_around_the_license_does_not_stop_it(self):
        self.assertHeld("MIT", "These files are carried from upstream.\n\n" + MIT + "\nThat ends the license.\n")

    def test_a_license_in_line_comments_holds(self):
        self.assertHeld("MIT", "".join(f"// {line}\n" if line else "//\n" for line in MIT.splitlines()))

    def test_the_copyright_symbol_is_any_of_its_forms(self):
        self.assertHeld("MIT", MIT.replace("(c)", "©"))
        self.assertHeld("MIT", MIT.replace("(c) ", ""))

    def test_ids_find_their_template_without_regard_to_case(self):
        self.assertHeld("mit", MIT)

    def test_the_license_match_part_is_what_is_held(self):
        self.assertHeld("MIT", GPL_NOTICE + "---\n" + MIT, licenseMatch=r"---\n(.*)")
        stderr = io.StringIO()
        with contextlib.redirect_stderr(stderr), self.assertRaises(SystemExit):
            self.entry("MIT", MIT + "---\n" + GPL_NOTICE, licenseMatch=r"---\n(.*)")

    def test_an_id_with_no_template_is_left_to_check_licenses(self):
        _, properties = self.entry("GPL-3.0-or-later", GPL_NOTICE)
        self.assertNotIn("low-talker:license-text", [p["name"] for p in properties])


if __name__ == "__main__":
    unittest.main()

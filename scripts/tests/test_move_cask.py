"""scripts/move-cask, run with gh faked on PATH. Nothing reaches GitHub.

The fake answers only the calls move-cask makes, each with the token it must be made with, and
fails loudly on any other. The tap's cask reads as the next of $CASKS at each read, the last one
standing once they run out, so a cask can be made to move partway through the wait."""
import os
import subprocess
import tempfile
import unittest
from pathlib import Path

scripts = Path(__file__).resolve().parent.parent
RUN = "4242"
NEWEST = "v0.1.0-alpha.12"

FAKE_GH = """#!/bin/bash
set -euo pipefail
token() { [ "$GH_TOKEN" = "$1" ] || { echo "fake gh: $call with the wrong token" >&2; exit 2; }; }
call="$*"
case "$call" in
  "api --method POST repos/promptctl/homebrew-tap/actions/workflows/low-talker.yaml/dispatches -f ref=main -F return_run_details=true --jq "*)
    token tap; echo %(run)s ;;
  "release list --repo promptctl/low-talker --exclude-drafts --limit 1 --json tagName --jq "*)
    token read; echo %(newest)s ;;
  "api -H Accept: application/vnd.github.raw repos/promptctl/homebrew-tap/contents/Casks/low-talker.rb")
    token read
    [ "$CASKS" != fail ] || { echo "gh: Server Error (HTTP 502)" >&2; exit 1; }
    reads=$(($(cat "$RECORD/reads" 2>/dev/null || echo 0) + 1)); echo "$reads" > "$RECORD/reads"
    casks=($CASKS); version=${casks[$((reads <= ${#casks[@]} ? reads - 1 : ${#casks[@]} - 1))]}
    echo 'cask "low-talker" do'
    [ "$version" = none ] || echo "  version \\"$version\\""
    echo '  sha256 "0000"'
    echo 'end' ;;
  "run view %(run)s --repo promptctl/homebrew-tap")
    token tap; touch "$RECORD/run-read"; echo "the tap's run: completed failure" ;;
  *) echo "fake gh: unmodelled call: $call" >&2; exit 2 ;;
esac
""" % {"run": RUN, "newest": NEWEST}


class MoveCaskTests(unittest.TestCase):
    def setUp(self):
        directory = tempfile.TemporaryDirectory()
        self.addCleanup(directory.cleanup)
        top = Path(directory.name)
        self.record, binaries = top / "record", top / "bin"
        self.record.mkdir()
        binaries.mkdir()
        (binaries / "gh").write_text(FAKE_GH)
        (binaries / "gh").chmod(0o755)
        self.env = {"PATH": f"{binaries}:{os.environ['PATH']}", "GH_TOKEN": "tap",
                    "READ_TOKEN": "read", "RECORD": str(self.record)}

    def move(self, casks, bound):
        return subprocess.run([str(scripts / "move-cask"), str(bound), "0"],
                              env={**self.env, "CASKS": casks}, capture_output=True, text=True)

    def test_the_wait_ends_when_the_cask_names_the_newest_release(self):
        result = self.move("0.1.0-alpha.11 0.1.0-alpha.11 0.1.0-alpha.12", 60)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.splitlines()[-1],
                         f"move-cask: the tap's cask is low-talker 0.1.0-alpha.12; "
                         f"run https://github.com/promptctl/homebrew-tap/actions/runs/{RUN}")
        self.assertEqual((self.record / "reads").read_text().strip(), "3")
        # The run is never read while the cask can still move, so a run not yet readable
        # cannot fail a release whose cask it moves.
        self.assertFalse((self.record / "run-read").exists())

    def test_a_cask_that_never_moves_fails_and_says_what_the_run_did(self):
        result = self.move("0.1.0-alpha.11", 0)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("the cask is at 0.1.0-alpha.11, not 0.1.0-alpha.12", result.stderr)
        self.assertIn("the tap's run: completed failure", result.stderr)

    def test_a_cask_with_no_version_line_fails_without_waiting(self):
        result = self.move("none", 60)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("no one version line", result.stderr)
        self.assertEqual((self.record / "reads").read_text().strip(), "1")

    def test_a_cask_that_cannot_be_read_fails_without_waiting(self):
        result = self.move("fail", 60)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("HTTP 502", result.stderr)


if __name__ == "__main__":
    unittest.main()

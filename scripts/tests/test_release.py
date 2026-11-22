"""scripts/release, run whole in a throwaway repository whose origin is a local bare one, from a
directory outside it, with make, xcrun and xcodegen faked on PATH and its two steps, sign-release
and notarize, faked beside it. Nothing reaches GitHub or Apple, and nothing is built.

Each fake answers only the call it models and fails loudly on any other. The fake make takes only
`-C <the repository> test-watchdog`, which is also what keeps a release's own suite, which runs
this test, from running the real suite again inside it."""
import os
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path

scripts = Path(__file__).resolve().parent.parent
TAG = "v0.1.0-alpha.1"
FAILURE = "LowTalkerTests.testSomething failed"

FAKE_XCRUN = """#!/bin/bash
[ "$1 $2" = "notarytool history" ] || { echo "fake xcrun: unmodelled call: $*" >&2; exit 2; }
"""

FAKE_XCODEGEN = """#!/bin/bash
[ "$1 $2 $3 $4" = "dump --type json --spec" ] || { echo "fake xcodegen: unmodelled call: $*" >&2; exit 2; }
echo '{"settings":{"base":{"MARKETING_VERSION":"0.1.0","CURRENT_PROJECT_VERSION":"1"}}}'
"""

# The suite, as $SUITE says it goes: passing, failing with a test's failure on stdout as swift test
# prints it, or passing having left a file behind in the tree.
FAKE_MAKE = """#!/bin/bash
set -euo pipefail
[ "$#" = 3 ] && [ "$1" = -C ] && [ "$3" = test-watchdog ] \\
  || { echo "fake make: unmodelled call: $*" >&2; exit 2; }
cd "$2"
[ "$(pwd -P)" = "$(git rev-parse --show-toplevel)" ] \\
  || { echo "fake make: the suite ran outside the repository's root" >&2; exit 2; }
echo ran >> "$RECORD/suite"
echo "Building for debugging..."
case "$SUITE" in
  pass) ;;
  fail) echo "%s"; exit 2 ;;
  leaves-a-file) echo "written by a test" > left-behind.txt ;;
  *) echo "fake make: unmodelled suite '$SUITE'" >&2; exit 2 ;;
esac
""" % FAILURE

# Records the revision the build would stamp, read as the real build reads it.
FAKE_SIGN_RELEASE = """#!/bin/bash
set -euo pipefail
out=$1
cd "$(dirname "$0")/.."
scripts/source-revision > "$RECORD/revision"
echo "$out/LowTalker-offline.pkg"
echo "$out/LowTalker-network.pkg"
"""

# Prints the package it notarized, as the real one does: those lines are the release's stdout.
FAKE_NOTARIZE = """#!/bin/bash
echo "$1" >> "$RECORD/notarized"
echo "$1"
"""


def executable(path, text):
    path.write_text(text)
    path.chmod(0o755)


class ReleaseTests(unittest.TestCase):
    def setUp(self):
        directory = tempfile.TemporaryDirectory()
        self.addCleanup(directory.cleanup)
        top = Path(directory.name)
        self.repo, self.record, self.out = top / "repo", top / "record", top / "out"
        self.elsewhere, binaries = top / "elsewhere", top / "bin"
        for folder in (self.repo / "scripts", self.record, self.elsewhere, binaries):
            folder.mkdir(parents=True)
        executable(binaries / "xcrun", FAKE_XCRUN)
        executable(binaries / "xcodegen", FAKE_XCODEGEN)
        executable(binaries / "make", FAKE_MAKE)

        # The real scripts under test, beside fakes of the steps they order.
        for name in ("release", "notary-credentials", "source-revision"):
            shutil.copy2(scripts / name, self.repo / "scripts" / name)
        executable(self.repo / "scripts" / "sign-release", FAKE_SIGN_RELEASE)
        executable(self.repo / "scripts" / "notarize", FAKE_NOTARIZE)
        (self.repo / "project.yml").write_text("name: LowTalker\n")

        # Whatever this runs inside, a release's own suite included, its git and notary settings
        # are not the throwaway repository's.
        self.env = {key: value for key, value in os.environ.items()
                    if not key.startswith(("GIT_", "NOTARY_"))}
        self.env.update({
            "PATH": f"{binaries}:{os.environ['PATH']}",
            "GIT_CONFIG_GLOBAL": "/dev/null", "GIT_CONFIG_NOSYSTEM": "1",
            "GIT_AUTHOR_NAME": "test", "GIT_AUTHOR_EMAIL": "test@example.invalid",
            "GIT_COMMITTER_NAME": "test", "GIT_COMMITTER_EMAIL": "test@example.invalid",
            "NOTARY_PROFILE": "test", "RECORD": str(self.record),
        })
        self.git("init", "--quiet", "--bare", str(top / "origin.git"))
        self.git("init", "--quiet", "-b", "master")
        self.git("add", "-A")
        self.git("commit", "--quiet", "-m", "release")
        self.git("tag", TAG)
        self.git("remote", "add", "origin", str(top / "origin.git"))
        self.git("push", "--quiet", "origin", "master", TAG)

    def git(self, *arguments):
        return subprocess.run(["git", "-C", str(self.repo), *arguments], env=self.env,
                              check=True, capture_output=True, text=True).stdout.strip()

    def release(self, suite):
        return subprocess.run([str(self.repo / "scripts" / "release"), str(self.out)],
                              cwd=self.elsewhere, env={**self.env, "SUITE": suite},
                              capture_output=True, text=True)

    def recorded(self, name):
        return (self.record / name).read_text() if (self.record / name).exists() else None

    def test_a_commit_whose_suite_fails_is_not_signed(self):
        result = self.release("fail")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn(FAILURE, result.stderr)
        self.assertEqual(result.stdout, "")
        self.assertIsNone(self.recorded("revision"))
        self.assertIsNone(self.recorded("notarized"))

    def test_a_passing_suite_releases_the_commit_as_committed(self):
        result = self.release("pass")
        self.assertEqual(result.returncode, 0, result.stderr)
        packages = [f"{self.out}/LowTalker-offline.pkg", f"{self.out}/LowTalker-network.pkg"]
        self.assertEqual(result.stdout, "".join(f"{package}\n" for package in packages))
        self.assertEqual(self.recorded("suite"), "ran\n")
        self.assertEqual(self.recorded("revision").strip(), self.git("rev-parse", "--short=12", "HEAD"))
        self.assertEqual(self.recorded("notarized").splitlines(), packages)

    def test_a_suite_that_leaves_the_tree_changed_is_not_signed(self):
        result = self.release("leaves-a-file")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("left-behind.txt", result.stderr)
        self.assertIsNone(self.recorded("revision"))

    def test_a_tree_that_differs_from_the_commit_is_refused_before_the_suite(self):
        (self.repo / "uncommitted.txt").write_text("an edit nobody committed\n")
        result = self.release("pass")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("uncommitted.txt", result.stderr)
        self.assertIsNone(self.recorded("suite"))
        self.assertIsNone(self.recorded("revision"))


if __name__ == "__main__":
    unittest.main()

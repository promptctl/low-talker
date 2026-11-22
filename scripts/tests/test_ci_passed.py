"""scripts/ci-passed, run against a fake gh on PATH that answers as GitHub does for one commit's
CI run: none, or one that is still going until it is watched to its end, with the conclusion
the case names."""
import os
import subprocess
import tempfile
import unittest
from pathlib import Path

script = Path(__file__).resolve().parent.parent / "ci-passed"
COMMIT = "5cb15380c0ffee"
RUN = "45055725007"
URL = f"https://github.com/promptctl/low-talker/actions/runs/{RUN}"

# A run's conclusion is empty while it is going, as GitHub's is; `run watch` returns once the
# run has ended, which here is when it writes the conclusion. Asked for any other commit,
# workflow, branch or event, it has no run.
fake_gh = f"""#!/usr/bin/env bash
set -euo pipefail
case "$1 $2" in
  "run list")
    [ "$*" = "run list --workflow ci.yml --branch master --event push --commit {COMMIT} --limit 1 --json databaseId --jq .[0].databaseId // empty" ] \\
      && [ "$FAKE_RUN" = yes ] && echo {RUN}
    true ;;
  "run watch")
    [ "$3" = {RUN} ] || exit 1
    echo "watching {RUN}"
    echo "$FAKE_CONCLUSION" > "$FAKE_STATE" ;;
  "run view")
    [ "$3" = {RUN} ] || exit 1
    echo "$(cat "$FAKE_STATE") {URL}" ;;
  *) exit 1 ;;
esac
"""


class CiPassedTests(unittest.TestCase):
    def setUp(self):
        directory = tempfile.TemporaryDirectory()
        self.addCleanup(directory.cleanup)
        self.bin = Path(directory.name) / "bin"
        self.bin.mkdir()
        gh = self.bin / "gh"
        gh.write_text(fake_gh)
        gh.chmod(0o755)
        self.state = Path(directory.name) / "conclusion"
        self.state.write_text("\n")

    def run_for(self, commit, *, run, conclusion=""):
        env = {**os.environ, "PATH": f"{self.bin}:{os.environ['PATH']}",
               "FAKE_RUN": "yes" if run else "no", "FAKE_CONCLUSION": conclusion,
               "FAKE_STATE": str(self.state)}
        return subprocess.run([script, commit], env=env, capture_output=True, text=True)

    def test_a_run_that_ends_in_success_passes_once_it_has_ended(self):
        result = self.run_for(COMMIT, run=True, conclusion="success")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout, "")
        self.assertIn(f"watching {RUN}", result.stderr)

    def test_a_run_that_ends_any_other_way_fails_naming_how_and_where(self):
        for conclusion in ("failure", "cancelled", "timed_out", "skipped"):
            with self.subTest(conclusion):
                result = self.run_for(COMMIT, run=True, conclusion=conclusion)
                self.assertEqual(result.returncode, 1)
                self.assertIn(f"concluded '{conclusion}': {URL}", result.stderr)

    def test_a_commit_with_no_run_on_master_fails_naming_it(self):
        result = self.run_for(COMMIT, run=False)
        self.assertEqual(result.returncode, 1)
        self.assertIn(f"ci.yml has no run for {COMMIT}'s push to master", result.stderr)

    def test_only_the_commit_asked_about_is_looked_up(self):
        result = self.run_for("0123456789ab", run=True, conclusion="success")
        self.assertEqual(result.returncode, 1)
        self.assertIn("ci.yml has no run for 0123456789ab", result.stderr)


if __name__ == "__main__":
    unittest.main()

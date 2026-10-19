"""scripts/gate-replay/fetch-esc50, with a curl on PATH that fails."""
import os
import subprocess
import tempfile
import unittest
from pathlib import Path

fetcher = Path(__file__).resolve().parent.parent / "gate-replay" / "fetch-esc50"


class FetchTests(unittest.TestCase):
    def test_a_clip_that_fails_to_fetch_stops_the_run(self):
        with tempfile.TemporaryDirectory() as folder:
            folder = Path(folder)
            (folder / "bin").mkdir()
            curl = folder / "bin" / "curl"
            curl.write_text("#!/bin/sh\necho 'curl: (22) 404' >&2\nexit 22\n")
            curl.chmod(0o755)
            clips = folder / "esc50"
            clips.mkdir()
            (clips / "esc50.csv").write_text("filename,fold,target,category\n1-19111-A-24.wav,1,24,coughing\n")
            result = subprocess.run([str(fetcher), str(clips)], capture_output=True, text=True,
                                    env={**os.environ, "PATH": f"{folder / 'bin'}:{os.environ['PATH']}"})
        self.assertEqual(result.returncode, 22, result.stderr)
        self.assertNotIn("clips of", result.stderr)


if __name__ == "__main__":
    unittest.main()

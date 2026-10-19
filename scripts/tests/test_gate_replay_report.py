"""scripts/gate-replay/report, over rows written the way the gate replay writes them."""
import subprocess
import tempfile
import unittest
from pathlib import Path

reporter = Path(__file__).resolve().parent.parent / "gate-replay" / "report"

READER = "fixture=librispeech/a shape=whole room=-51"
INSERT = f"{READER} at=8000 runs=1 length=8000"
# A reader handing a pass windows 0-99 alone; with a cough inserted it hands 0-49, and with as
# much silence 0-89, so the cough loses 0.40 s beyond the silence control.
MASTER = {
    f"family=transient {READER} source=none": "0-99",
    f"family=transient {INSERT} source=coughing/1-19111-A-24": "0-99",
    f"family=transient {INSERT} source=silence": "0-89",
    "family=talk press=short fixture=say/yes under=librispeech/a db=-30": "0-40",
    "family=bench fixture=say/yes level=0 trim=whole room=clean": "0-48",
    "family=tap fixture=say/yes room=-35": "0-48",
}


def rows(cases, digests={}):
    return "".join(f"{case}\t100\t{digests.get(case, 'f00d')}\t{runs}\n" for case, runs in cases.items())


class ReportTests(unittest.TestCase):
    def report(self, baseline, measured):
        with tempfile.TemporaryDirectory() as folder:
            paths = [Path(folder) / "baseline.tsv", Path(folder) / "measured.tsv"]
            for path, text in zip(paths, [baseline, measured]):
                path.write_text(text)
            return subprocess.run([str(reporter), *map(str, paths)], capture_output=True, text=True)

    def test_master_against_its_own_baseline_reports_nothing_beyond_it(self):
        result = self.report(rows(MASTER), rows(MASTER))
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("cases losing more than on master: none", result.stdout)
        self.assertEqual(result.stdout.count("changed: none"), 3)

    def test_loss_after_a_transient_is_counted_beyond_the_silence_control(self):
        fixed = {**MASTER, f"family=transient {INSERT} source=coughing/1-19111-A-24": "0-99"}
        lost = {**MASTER, f"family=transient {INSERT} source=coughing/1-19111-A-24": "0-49"}
        result = self.report(rows(fixed), rows(lost))
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("cases losing more than on master: 1", result.stdout)
        self.assertIn(f"{INSERT} source=coughing/1-19111-A-24: 0.00 s on master, 0.40 s", result.stdout)
        self.assertRegex(result.stdout, r"coughing\s+1\s+1\s+1\s+0.40 s\s+0\s+0.00 s")

    def test_talk_let_in_is_what_master_does_not_hand_a_pass(self):
        case = "family=talk press=short fixture=say/yes under=librispeech/a db=-30"
        result = self.report(rows(MASTER), rows({**MASTER, case: "0-40,60-79"}, {case: "beef"}))
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertRegex(result.stdout, r"short\s+-30\s+1\s+1\s+0.20 s\s+0\s+0.00 s")
        self.assertIn("press=short fixture=say/yes under=librispeech/a db=-30: let in 0.20 s, lost 0.00 s", result.stdout)

    def test_a_bench_variant_handed_other_samples_is_listed(self):
        case = "family=bench fixture=say/yes level=0 trim=whole room=clean"
        result = self.report(rows(MASTER), rows({**MASTER, case: "0-38"}, {case: "beef"}))
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("fixture=say/yes level=0 trim=whole room=clean: let in 0.00 s, lost 0.10 s", result.stdout)

    def test_files_holding_different_cases_are_no_comparison(self):
        case = "family=tap fixture=say/yes room=-35"
        result = self.report(rows(MASTER), rows({k: v for k, v in MASTER.items() if k != case}))
        self.assertEqual(result.returncode, 1)
        self.assertEqual(result.stdout, "")
        self.assertIn(f"only in the baseline: {case}", result.stderr)


if __name__ == "__main__":
    unittest.main()

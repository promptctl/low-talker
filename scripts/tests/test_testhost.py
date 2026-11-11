"""scripts/testhost.py, the test host's one client, against a stand-in host: a script laid out as
the bundle's executable that speaks the host's protocol (Tests/TestHost/main.swift) and does
whatever each test needs it to do wrong."""
import os
import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))
from testhost import Host, HostError, NoAnswer  # noqa: E402

READY = """{"event": "ready", "fields": ["text-view", "textarea", "input"], "keepsMaxLength": ["textarea", "input"]}"""

# Answers each command as the host does, except that a pushed reading of the same field, holding
# something else, comes first: what a change landing while a command runs looks like.
answers_after_a_push = f"""
import json, sys
def say(event): print(json.dumps(event), flush=True)
say({READY})
for line in sys.stdin:
    command = json.loads(line)
    field = command.get("hold") or command["read"]
    reading = {{"event": "field", "name": field, "selection": command.get("selection", [0, 0]), "maxLength": command.get("maxLength"),
               "focused": True, "active": True}}
    say({{**reading, "answers": None, "text": "pushed " + str(command["id"])}})
    say({{**reading, "answers": command["id"], "text": command.get("text", "answered")}})
    say({{**reading, "answers": None, "text": "after " + str(command["id"])}})
"""

# Answers a hold as a page that would not take the maxLength it was given.
ignores_max_length = f"""
import json, sys
print(json.dumps({READY}), flush=True)
command = json.loads(sys.stdin.readline())
print(json.dumps({{"event": "field", "answers": command["id"], "name": "textarea", "text": command["text"],
                  "selection": command["selection"], "maxLength": None, "focused": True, "active": True}}), flush=True)
sys.stdin.readline()
"""

says_error = f"""
import json, sys
print(json.dumps({READY}), flush=True)
sys.stdin.readline()
print(json.dumps({{"event": "error", "message": "names no field: {{}}"}}), flush=True)
sys.exit(2)
"""

quits = f"""
import json, sys
print(json.dumps({READY}), flush=True)
sys.stdin.readline()
sys.exit(3)
"""

says_a_line_that_is_no_event = f"""
import json, sys
print(json.dumps({READY}), flush=True)
sys.stdin.readline()
print("loaded the pages", flush=True)
sys.stdin.readline()
"""

# Says where it is, then never says it is ready and never reads its input: a page that never loads.
never_ready = """
import os, sys, time
from pathlib import Path
Path(sys.argv[0]).with_name("pid").write_text(str(os.getpid()))
time.sleep(3600)
"""

# A host of an older protocol, whose ready names no fields that keep a maxLength.
says_too_little_when_ready = """
import json, os, sys
from pathlib import Path
Path(sys.argv[0]).with_name("pid").write_text(str(os.getpid()))
print(json.dumps({"event": "ready", "fields": ["input"]}), flush=True)
sys.stdin.readline()
sys.stdin.readline()
"""


class HostTests(unittest.TestCase):
    def bundle(self, script: str) -> Path:
        folder = tempfile.TemporaryDirectory()
        self.addCleanup(folder.cleanup)
        executable = Path(folder.name) / "TestHost.app" / "Contents" / "MacOS" / "test-host"
        executable.parent.mkdir(parents=True)
        executable.write_text(f"#!{sys.executable}\n{script}")
        os.chmod(executable, 0o755)
        return Path(folder.name) / "TestHost.app"

    def test_the_host_names_its_fields_once_ready(self):
        with Host(self.bundle(answers_after_a_push)) as host:
            self.assertEqual(host.fields, ["text-view", "textarea", "input"])
            self.assertEqual(host.keeps_max_length, ["textarea", "input"])

    def test_a_command_is_answered_by_its_number_and_never_by_a_push(self):
        with Host(self.bundle(answers_after_a_push)) as host:
            self.assertEqual(host.hold("textarea", "alpha", (5, 0), max_length=10)["text"], "alpha")
            self.assertEqual(host.read("textarea")["text"], "answered")
            # What was pushed in between is kept, for a failure to show.
            self.assertIn("pushed 2", [event.get("text") for event in host.said])

    def test_a_change_heard_while_another_command_waited_is_still_found(self):
        with Host(self.bundle(answers_after_a_push)) as host:
            host.read("input")
            # The second read's wait hears the push the first one made after its answer.
            host.read("input")
            self.assertEqual(host.change("input", lambda event: event["text"] == "after 1", within=1)["text"], "after 1")

    def test_a_change_is_taken_once(self):
        with Host(self.bundle(answers_after_a_push)) as host:
            host.read("input")
            host.read("input")
            self.assertEqual(host.change("input", lambda event: event["text"].startswith("after"), within=1)["text"], "after 1")
            self.assertEqual(host.change("input", lambda event: event["text"].startswith("after"), within=1)["text"], "after 2")

    def test_what_a_field_pushed_before_it_was_set_up_is_no_change(self):
        with Host(self.bundle(answers_after_a_push)) as host:
            host.read("input")
            host.hold("input", "", (0, 0))
            with self.assertRaises(NoAnswer):
                host.change("input", lambda event: event["text"] in ("pushed 1", "after 1", "pushed 2"), within=0.2)

    def test_a_hold_that_reads_back_otherwise_is_no_setup(self):
        with Host(self.bundle(ignores_max_length)) as host:
            with self.assertRaisesRegex(HostError, "reads back"):
                host.hold("textarea", "", (0, 0), max_length=10)

    def test_a_host_that_says_it_is_wrong_raises_what_it_said_from_then_on(self):
        with Host(self.bundle(says_error)) as host:
            with self.assertRaisesRegex(HostError, "names no field"):
                host.read("input")
            with self.assertRaisesRegex(HostError, "names no field"):
                host.read("input")

    def test_a_host_that_quits_raises_its_status_from_then_on(self):
        with Host(self.bundle(quits)) as host:
            with self.assertRaisesRegex(HostError, "status 3"):
                host.read("input")
            # Written to a host that is gone: the end it gave, and no broken pipe.
            with self.assertRaisesRegex(HostError, "status 3"):
                host.read("input")

    def test_a_line_that_is_no_event_ends_the_host(self):
        with Host(self.bundle(says_a_line_that_is_no_event)) as host:
            with self.assertRaisesRegex(HostError, "loaded the pages"):
                host.read("input")
            with self.assertRaisesRegex(HostError, "loaded the pages"):
                host.read("input")
            # Nothing reads it any more, so it is ended rather than left to fill its output.
            self.assertIsNotNone(host.process.wait(timeout=5))

    def test_a_host_that_never_says_it_is_ready_is_ended(self):
        bundle = self.bundle(never_ready)
        with self.assertRaises(NoAnswer):
            Host(bundle, within=1)
        self.assertEnded(bundle)

    def test_a_host_whose_ready_names_too_little_is_ended(self):
        bundle = self.bundle(says_too_little_when_ready)
        with self.assertRaises(KeyError):
            Host(bundle)
        self.assertEnded(bundle)

    def assertEnded(self, bundle: Path):
        pid = int((bundle / "Contents" / "MacOS" / "pid").read_text())
        with self.assertRaises(ProcessLookupError):
            os.kill(pid, 0)

    def test_closing_quits_the_host(self):
        host = Host(self.bundle(answers_after_a_push))
        host.close()
        self.assertEqual(host.process.returncode, 0)

    def test_a_bundle_with_no_host_in_it_says_how_to_build_one(self):
        with self.assertRaisesRegex(HostError, "make test-host"):
            Host(Path(tempfile.gettempdir()) / "NoSuch.app")


if __name__ == "__main__":
    unittest.main()

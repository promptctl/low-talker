"""scripts/testhost.py, the test host's one client, against a stand-in host: a script laid out as
the bundle's executable that speaks the host's protocol (Tests/TestHost/main.swift) and does
whatever each test needs it to do wrong."""
import os
import sys
import tempfile
import time
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))
from testhost import Host, HostError  # noqa: E402

# Answers each command as the host does, except that a pushed reading of the same field, holding
# something else, comes first: what a change landing while a command runs looks like.
answers_after_a_push = """
import json, sys
def say(event): print(json.dumps(event), flush=True)
say({"event": "ready", "fields": ["text-view", "textarea", "input"]})
for line in sys.stdin:
    command = json.loads(line)
    field = command.get("hold") or command["read"]
    reading = {"event": "field", "name": field, "selection": command.get("selection", [0, 0]), "maxLength": command.get("maxLength"),
               "focused": True, "active": True}
    say({**reading, "answers": None, "text": "pushed"})
    say({**reading, "answers": command["id"], "text": command.get("text", "answered")})
    say({**reading, "answers": None, "text": "after"})
"""

# Answers a hold as a page that would not take the maxLength it was given.
ignores_max_length = """
import json, sys
print(json.dumps({"event": "ready", "fields": ["textarea"]}), flush=True)
command = json.loads(sys.stdin.readline())
print(json.dumps({"event": "field", "answers": command["id"], "name": "textarea", "text": command["text"],
                  "selection": command["selection"], "maxLength": None, "focused": True, "active": True}), flush=True)
sys.stdin.readline()
"""

says_error = """
import json, sys
print(json.dumps({"event": "ready", "fields": ["input"]}), flush=True)
sys.stdin.readline()
print(json.dumps({"event": "error", "message": "names no field: {}"}), flush=True)
sys.exit(2)
"""

quits = """
import json, sys
print(json.dumps({"event": "ready", "fields": ["input"]}), flush=True)
sys.stdin.readline()
sys.exit(3)
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

    def test_a_command_is_answered_by_its_number_and_never_by_a_push(self):
        with Host(self.bundle(answers_after_a_push)) as host:
            self.assertEqual(host.hold("textarea", "alpha", (5, 0), max_length=10)["text"], "alpha")
            self.assertEqual(host.read("textarea")["text"], "answered")
            # What was pushed in between is kept, for a failure to show.
            self.assertIn("pushed", [event.get("text") for event in host.said])

    def test_a_change_pushed_before_it_is_waited_for_is_still_found(self):
        with Host(self.bundle(answers_after_a_push)) as host:
            host.read("input")
            # Keys typed land while nobody waits: the push is already in by the time this asks.
            time.sleep(0.2)
            self.assertEqual(host.change("input", lambda event: event["text"] == "after", within=1)["text"], "after")

    def test_a_hold_that_reads_back_otherwise_is_no_setup(self):
        with Host(self.bundle(ignores_max_length)) as host:
            with self.assertRaisesRegex(HostError, "reads back"):
                host.hold("textarea", "", (0, 0), max_length=10)

    def test_a_host_that_says_it_is_wrong_raises_what_it_said(self):
        with Host(self.bundle(says_error)) as host:
            with self.assertRaisesRegex(HostError, "names no field"):
                host.read("input")

    def test_a_host_that_quits_raises_its_status(self):
        with Host(self.bundle(quits)) as host:
            with self.assertRaisesRegex(HostError, "status 3"):
                host.read("input")

    def test_closing_quits_the_host(self):
        host = Host(self.bundle(answers_after_a_push))
        host.close()
        self.assertEqual(host.process.returncode, 0)

    def test_a_bundle_with_no_host_in_it_says_how_to_build_one(self):
        with self.assertRaisesRegex(HostError, "make test-host"):
            Host(Path(tempfile.gettempdir()) / "NoSuch.app")


if __name__ == "__main__":
    unittest.main()

"""scripts/pkg/functions' `stop`, sourced whole by /bin/bash under the package scripts' options,
against children that end only when the test lets them. Nothing here waits on a clock for
`stop` to act: the bound on each read is there so a regression fails rather than hangs."""
import os
import re
import select
import signal
import subprocess
import tempfile
import time
import unittest
from pathlib import Path

functions = Path(__file__).resolve().parent.parent / "pkg" / "functions"
bound = 30

# Answers TERM by saying so, then waiting on its stdin for the test to let it go, then
# writing its marker: what a KILL would never let it write.
child = """
trap 'kill $sleeper; echo asked; read -r _; echo quit > "$1"; exit 0' TERM
sleep 1000 & sleeper=$!
echo ready
wait $sleeper
"""


def end_group(leader):
    try:
        os.killpg(leader, signal.SIGKILL)
    except ProcessLookupError:
        pass  # A child that was let go took its group with it.


class Lines:
    """The lines a process writes, read one at a time with a bound."""

    def __init__(self, stream):
        self.fd, self.buffer = stream.fileno(), b""

    def next(self):
        deadline = time.monotonic() + bound
        while b"\n" not in self.buffer:
            left = deadline - time.monotonic()
            if left <= 0 or not select.select([self.fd], [], [], left)[0]:
                raise AssertionError(f"no line within {bound} s; read so far: {self.buffer!r}")
            chunk = os.read(self.fd, 4096)
            if not chunk:
                raise AssertionError(f"ended without a line; read so far: {self.buffer!r}")
            self.buffer += chunk
        line, self.buffer = self.buffer.split(b"\n", 1)
        return line.decode()


class StopTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)

    def own(self, process):
        # Cleanups run last first: one still running is ended, then its pipes are closed and it is reaped.
        self.addCleanup(process.__exit__, None, None, None)
        self.addCleanup(lambda: process.poll() is None and process.kill())

    def spawn(self, name):
        marker = Path(self.directory.name) / name
        process = subprocess.Popen(["/bin/bash", "-c", child, "child", str(marker)],
                                   stdin=subprocess.PIPE, stdout=subprocess.PIPE, start_new_session=True)
        self.own(process)
        # Its sleep outlives a KILL of the shell, so a test that fails first ends the whole group.
        self.addCleanup(end_group, process.pid)
        out = Lines(process.stdout)
        self.assertEqual(out.next(), "ready")
        return process, out, marker

    def stop(self, *pids):
        process = subprocess.Popen(
            # Run as the preinstall, the script that stops the app, so its lines carry that name.
            ["/bin/bash", "-c", 'set -euo pipefail; . "$1"; shift; stop_every=1; stop "$@"', "preinstall", str(functions), *map(str, pids)],
            stdout=subprocess.PIPE)
        self.own(process)
        return process, Lines(process.stdout)

    def release(self, process, marker):
        process.stdin.write(b"\n")
        process.stdin.flush()
        self.assertEqual(process.wait(timeout=bound), 0)
        self.assertEqual(marker.read_text(), "quit\n")

    def ended(self, out, pid):
        line = out.next()
        while line.startswith("preinstall: still waiting on "):
            line = out.next()
        self.assertRegex(line, rf"^preinstall: {pid} ended \d+ s after it was asked to quit$")

    def test_waits_for_a_process_however_long_its_quit_takes(self):
        process, out, marker = self.spawn("quit")
        stopping, said = self.stop(process.pid)
        self.assertEqual(out.next(), "asked")
        self.assertRegex(said.next(), rf"^preinstall: still waiting on {process.pid}, \d+ s in$")
        self.assertIsNone(stopping.poll())
        self.assertIsNone(process.poll())
        self.release(process, marker)
        self.ended(said, process.pid)
        self.assertEqual(stopping.wait(timeout=bound), 0)

    def test_asks_every_process_before_waiting_on_any(self):
        first, second = self.spawn("first"), self.spawn("second")
        stopping, said = self.stop(first[0].pid, second[0].pid)
        # The second is asked while the first is still quitting.
        self.assertEqual(first[1].next(), "asked")
        self.assertEqual(second[1].next(), "asked")
        self.release(first[0], first[2])
        self.release(second[0], second[2])
        self.ended(said, first[0].pid)
        self.ended(said, second[0].pid)
        self.assertEqual(stopping.wait(timeout=bound), 0)

    def test_a_process_already_gone_is_said(self):
        gone = subprocess.Popen(["/usr/bin/true"])
        gone.wait()
        stopping, said = self.stop(gone.pid)
        self.assertEqual(said.next(), f"preinstall: {gone.pid} had already ended")
        self.assertEqual(stopping.wait(timeout=bound), 0)

    # As root this would end launchd, which is why it runs only as someone else.
    @unittest.skipIf(os.geteuid() == 0, "signalling launchd is refused only to someone who is not root")
    def test_a_process_it_cannot_ask_is_said_and_fails_the_call_after_the_rest_end(self):
        process, out, marker = self.spawn("quit")
        stopping, said = self.stop(1, process.pid)
        self.assertRegex(said.next(), r"^preinstall: could not ask 1 to quit: .*Operation not permitted$")
        self.assertEqual(out.next(), "asked")
        self.release(process, marker)
        self.ended(said, process.pid)
        self.assertEqual(stopping.wait(timeout=bound), 1)


if __name__ == "__main__":
    unittest.main()

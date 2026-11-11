"""The one client of the test host (Tests/TestHost), the app whose fields the client contract
runs against on a Mac: it launches the host out of its bundle, sends it commands, and reads
what its fields hold from what the host says, never from the screen.

    with Host(".build/TestHost.app") as host:
        host.hold("textarea", "", (0, 0), max_length=10)
        host.front()
        ...                                # keys typed, or the input method's insert
        host.read("textarea")["text"]

The host's protocol is described where it is defined, Tests/TestHost/main.swift. Standard
library only, as scripts/conformance is.
"""
from __future__ import annotations

import itertools
import json
import queue
import subprocess
import threading
import time
from pathlib import Path
from typing import Callable


class HostError(Exception):
    """The host could not be run, said it was wrong, quit, or did not answer in time."""


class NoAnswer(HostError):
    """The host is still there and did not say what was waited for in time."""


# The keys each kind of event carries, as Tests/TestHost/Events.swift writes them.
KEYS = {
    "ready": {"fields", "keepsMaxLength"},
    "field": {"answers", "name", "text", "selection", "maxLength", "focused", "active"},
    "active": {"active"},
    "error": {"message"},
}


def parse_event(line: str) -> dict:
    """One line the host said, as the event it is: raises unless it is an event of a kind the host
    says, carrying every key of that kind. [LAW:parse-dont-validate]"""
    try:
        event = json.loads(line)
    except json.JSONDecodeError:
        event = None
    if not isinstance(event, dict) or event.get("event") not in KEYS or not KEYS[event["event"]] <= event.keys():
        raise HostError(f"the host said a line that is no event: {line!r}")
    return event


class Host:
    def __init__(self, bundle: str | Path, within: float = 20.0):
        self.bundle = Path(bundle)
        executable = self.bundle / "Contents" / "MacOS" / "test-host"
        if not executable.is_file():
            raise HostError(f"{executable} is not there: build it with `make test-host`")
        # Exec'd directly, not opened, so its standard input and output are these pipes.
        self.process = subprocess.Popen([str(executable)], stdin=subprocess.PIPE, stdout=subprocess.PIPE, text=True, bufsize=1)
        # Every event the host has said, in order: what every wait looks through, and what a
        # failure shows. [LAW:one-source-of-truth]
        self.said: list[dict] = []
        # Where in `said` each field's changes start: past its last setup, and past the last
        # change taken from it.
        self._changes_from: dict[str, int] = {}
        # Why the host can say nothing more, once it can't: every later wait raises it.
        self._end: HostError | None = None
        self._events: queue.Queue[dict | HostError] = queue.Queue()
        self._numbers = itertools.count(1)
        self._reader = threading.Thread(target=self._read, daemon=True)
        self._reader.start()
        try:
            _, ready = self._wait(lambda event: event["event"] == "ready", within)
            self.fields: list[str] = ready["fields"]
            self.keeps_max_length: list[str] = ready["keepsMaxLength"]
        except BaseException:
            # The host's loop over its input, which quits at the input's end, starts only once it
            # is ready, so ending its input would not quit it.
            self.process.kill()
            self.close()
            raise

    def __enter__(self) -> Host:
        return self

    def __exit__(self, *_) -> None:
        self.close()

    def _read(self) -> None:
        for line in self.process.stdout:
            try:
                self._events.put(parse_event(line))
            except HostError as error:
                self._events.put(error)
                # Nothing reads the host from here on, and a host that cannot write would never quit.
                self.process.kill()
                return
        self._events.put(HostError(f"the host quit with status {self.process.wait()}"))

    def _wait(self, matches: Callable[[dict], bool], within: float = 10.0, start: int | None = None) -> tuple[int, dict]:
        """The first event in `said` from `start` on that `matches`, and where it is, waiting at
        most `within` seconds for the host to say it. With no `start`, the first said from now on."""
        index = len(self.said) if start is None else start
        deadline = time.monotonic() + within
        while True:
            while index < len(self.said):
                if matches(self.said[index]):
                    return index, self.said[index]
                index += 1
            self._hear(deadline, within)

    def _hear(self, deadline: float, within: float) -> None:
        """Takes the host's next event into `said`, or raises why there is none."""
        if self._end is not None:
            raise self._end
        try:
            event = self._events.get(timeout=max(0.0, deadline - time.monotonic()))
        except queue.Empty:
            raise NoAnswer(f"no answer from the host in {within} s") from None
        if isinstance(event, HostError):
            self._end = event
            raise event
        self.said.append(event)
        if event["event"] == "error":
            self._end = HostError(f"the host said: {event['message']}")
            raise self._end

    def _command(self, verb: str, field: str, **rest) -> tuple[int, dict]:
        """Sends one command under a number of its own and returns the one answer carrying it, and
        where it is in `said`."""
        number = next(self._numbers)
        try:
            self.process.stdin.write(json.dumps({"id": number, verb: field, **rest}) + "\n")
            self.process.stdin.flush()
        except BrokenPipeError:
            # The host has quit, and why is on its way to the wait below. [LAW:no-silent-failure]
            pass
        return self._wait(lambda event: event["event"] == "field" and event["answers"] == number)

    def hold(self, field: str, text: str, selection: tuple[int, int], max_length: int | None = None) -> dict:
        """Gives `field` keyboard focus, has it keep at most `max_length` UTF-16 units of what goes
        into it (any amount, with None), and sets what it holds, the selection in UTF-16 units.
        Raises unless the field reads back exactly that, focused: a setup that did not happen must
        never be judged as a client's answer."""
        index, held = self._command("hold", field, text=text, selection=list(selection), maxLength=max_length)
        # What the field pushed before it was set up is no change to the field it now is.
        self._changes_from[field] = index + 1
        meant = {"text": text, "selection": list(selection), "maxLength": max_length, "focused": True}
        if {key: held[key] for key in meant} != meant:
            raise HostError(f"{field} was set up as {meant} and reads back {held}")
        return held

    def read(self, field: str) -> dict:
        """What `field` holds now: the reading a case is judged on."""
        return self._command("read", field)[1]

    def change(self, field: str, matches: Callable[[dict], bool], within: float = 10.0) -> dict:
        """The first reading `field` pushed on a change that `matches`, past its last hold's answer
        and past the last change taken from it: keys typed, an insert, whether it landed before this
        asks or after. A page pushes its own setup after the hold's answer (WebKit fires
        `selectionchange` as a task of its own), so `matches` names a state the setup does not make."""
        index, pushed = self._wait(
            lambda event: event["event"] == "field" and event["answers"] is None and event["name"] == field and matches(event),
            within, start=self._changes_from.get(field, 0))
        self._changes_from[field] = index + 1
        return pushed

    def front(self) -> None:
        """Brings the host to the front, which it cannot do itself: macOS refuses the activation a
        process launched behind another app asks for. `open` on a running app's bundle activates it."""
        subprocess.run(["open", str(self.bundle)], check=True)
        # A reading says whether the host is active as it answers: on a host already in front,
        # `open` changes nothing and no event comes, and on one that is not yet, its `active` event
        # follows the answer. [LAW:no-ambient-temporal-coupling]
        index, answer = self._command("read", self.fields[0])
        if not answer["active"]:
            self._wait(lambda event: event["event"] == "active" and event["active"], start=index + 1)

    def close(self) -> None:
        """Ends the host's standard input, which quits it, and waits for it to quit."""
        try:
            self.process.stdin.close()
        except BrokenPipeError:
            # The host quit with a command unread, and the wait for its answer raised why.
            pass
        try:
            self.process.wait(timeout=10)
        except subprocess.TimeoutExpired:
            self.process.kill()
            self.process.wait()
            raise HostError("the host did not quit in 10 s once its standard input ended") from None
        finally:
            # Its output ends with it, and the reader stops there.
            self._reader.join()
            self.process.stdout.close()

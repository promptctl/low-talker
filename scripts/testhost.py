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


class Host:
    def __init__(self, bundle: str | Path, within: float = 20.0):
        self.bundle = Path(bundle)
        executable = self.bundle / "Contents" / "MacOS" / "test-host"
        if not executable.is_file():
            raise HostError(f"{executable} is not there: build it with `make test-host`")
        # Exec'd directly, not opened, so its standard input and output are these pipes.
        self.process = subprocess.Popen([str(executable)], stdin=subprocess.PIPE, stdout=subprocess.PIPE, text=True, bufsize=1)
        # Every event the host has said, in order, for a failure to show.
        self.said: list[dict] = []
        self.active = False
        self._events: queue.Queue[dict | None] = queue.Queue()
        self._numbers = itertools.count(1)
        threading.Thread(target=self._read, daemon=True).start()
        self.fields: list[str] = self.next(lambda event: event["event"] == "ready", within)["fields"]

    def __enter__(self) -> Host:
        return self

    def __exit__(self, *_) -> None:
        self.close()

    def _read(self) -> None:
        for line in self.process.stdout:
            self._events.put(json.loads(line))
        self._events.put(None)

    def next(self, matches: Callable[[dict], bool], within: float = 10.0) -> dict:
        """The next event that `matches`, waiting at most `within` seconds for it."""
        deadline = time.monotonic() + within
        while True:
            try:
                event = self._events.get(timeout=max(0.0, deadline - time.monotonic()))
            except queue.Empty:
                raise HostError(f"no answer from the host in {within} s") from None
            if event is None:
                raise HostError(f"the host quit with status {self.process.wait()}")
            self.said.append(event)
            if event["event"] == "error":
                raise HostError(f"the host said: {event['message']}")
            if event["event"] in ("active", "field"):
                self.active = event["active"]
            if matches(event):
                return event

    def _command(self, verb: str, field: str, **rest) -> dict:
        """Sends one command under a number of its own and returns the one answer carrying it."""
        number = next(self._numbers)
        self.process.stdin.write(json.dumps({"id": number, verb: field, **rest}) + "\n")
        self.process.stdin.flush()
        return self.next(lambda event: event["event"] == "field" and event["answers"] == number)

    def hold(self, field: str, text: str, selection: tuple[int, int], max_length: int | None = None) -> dict:
        """Gives `field` keyboard focus, has it keep at most `max_length` UTF-16 units of what goes
        into it (any amount, with None), and sets what it holds, the selection in UTF-16 units.
        Raises unless the field reads back exactly that, focused: a setup that did not happen must
        never be judged as a client's answer."""
        held = self._command("hold", field, text=text, selection=list(selection), maxLength=max_length)
        meant = {"text": text, "selection": list(selection), "maxLength": max_length, "focused": True}
        if {key: held[key] for key in meant} != meant:
            raise HostError(f"{field} was set up as {meant} and reads back {held}")
        return held

    def read(self, field: str) -> dict:
        """What `field` holds now: the reading a case is judged on."""
        return self._command("read", field)

    def change(self, field: str, matches: Callable[[dict], bool], within: float = 10.0) -> dict:
        """The next reading `field` pushed on a change that `matches`: keys typed, an insert."""
        return self.next(lambda event: event["event"] == "field" and event["answers"] is None and event["name"] == field and matches(event), within)

    def front(self) -> None:
        """Brings the host to the front, which it cannot do itself: macOS refuses the activation a
        process launched behind another app asks for. `open` on a running app's bundle activates it."""
        subprocess.run(["open", str(self.bundle)], check=True)
        # The last state the host gave, from an `active` event or a reading: on a host already in
        # front, `open` changes nothing and no event comes.
        if not self.active:
            self.next(lambda event: event["event"] == "active" and event["active"])

    def close(self) -> None:
        """Ends the host's standard input, which quits it."""
        if self.process.poll() is None:
            self.process.stdin.close()
            self.process.wait(timeout=10)

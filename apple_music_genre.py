"""Read the genre of the currently playing Apple Music track on macOS.

Default: print the current track's genre once via AppleScript.
With --watch: subscribe to Music.app's distributed notifications and
print each track change in real time (event-driven, no polling).
"""

from __future__ import annotations

import argparse
import subprocess
import sys

APPLESCRIPT = '''
tell application "System Events"
    if not (exists process "Music") then
        return "NOT_RUNNING"
    end if
end tell
tell application "Music"
    if player state is stopped then
        return "STOPPED"
    end if
    set t to current track
    return (name of t) & "\t" & (artist of t) & "\t" & (album of t) & "\t" & (genre of t) & "\t" & (player state as text)
end tell
'''

NOTIFICATION_NAME = "com.apple.Music.playerInfo"


class TrackInfo:
    def __init__(self, name: str, artist: str, album: str, genre: str, state: str):
        self.name = name
        self.artist = artist
        self.album = album
        self.genre = genre
        self.state = state

    def __str__(self) -> str:
        genre = self.genre or "(no genre set)"
        return f'"{self.name}" by {self.artist} — genre: {genre}'


def get_current_track() -> TrackInfo | str:
    if sys.platform != "darwin":
        return "Apple Music is only available on macOS."
    result = subprocess.run(
        ["osascript", "-e", APPLESCRIPT],
        capture_output=True,
        text=True,
        check=False,
    )
    if result.returncode != 0:
        return f"AppleScript error: {result.stderr.strip()}"
    out = result.stdout.strip()
    if out == "NOT_RUNNING":
        return "Music app is not running."
    if out == "STOPPED":
        return "Nothing is playing."
    parts = out.split("\t")
    if len(parts) < 5:
        return f"Unexpected response: {out!r}"
    return TrackInfo(*parts[:5])


def watch() -> int:
    if sys.platform != "darwin":
        print("Apple Music is only available on macOS.", file=sys.stderr)
        return 1
    try:
        from Foundation import (
            NSDate,
            NSDistributedNotificationCenter,
            NSObject,
            NSRunLoop,
        )
    except ImportError:
        print(
            "PyObjC is required for --watch mode. Install with:\n"
            "    pip install pyobjc-core pyobjc-framework-Cocoa",
            file=sys.stderr,
        )
        return 1

    class Listener(NSObject):
        def handlePlayerInfo_(self, notification):
            info = notification.userInfo()
            if info is None:
                return
            if info.get("Player State", "") != "Playing":
                return
            name = info.get("Name", "")
            artist = info.get("Artist", "")
            genre = info.get("Genre", "") or "(no genre set)"
            print(f'"{name}" by {artist} — genre: {genre}', flush=True)

    listener = Listener.alloc().init()
    center = NSDistributedNotificationCenter.defaultCenter()
    center.addObserver_selector_name_object_(
        listener,
        "handlePlayerInfo:",
        NOTIFICATION_NAME,
        None,
    )

    current = get_current_track()
    if isinstance(current, TrackInfo) and current.state.lower() == "playing":
        print(current, flush=True)

    try:
        loop = NSRunLoop.currentRunLoop()
        while True:
            loop.runUntilDate_(NSDate.dateWithTimeIntervalSinceNow_(1.0))
    except KeyboardInterrupt:
        pass
    finally:
        center.removeObserver_(listener)
    return 0


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--watch",
        action="store_true",
        help="Listen for track changes in real time (requires PyObjC).",
    )
    args = parser.parse_args()

    if args.watch:
        return watch()

    info = get_current_track()
    print(info)
    return 0 if isinstance(info, TrackInfo) else 1


if __name__ == "__main__":
    raise SystemExit(main())

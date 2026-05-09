"""Read the genre of the currently playing Apple Music track on macOS.

Uses AppleScript via `osascript` to query the Music.app process. Run with
`--watch` to print whenever the track changes.
"""

from __future__ import annotations

import argparse
import subprocess
import sys
import time

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


class TrackInfo:
    def __init__(self, name: str, artist: str, album: str, genre: str, state: str):
        self.name = name
        self.artist = artist
        self.album = album
        self.genre = genre
        self.state = state

    @property
    def key(self) -> tuple[str, str, str]:
        return (self.name, self.artist, self.album)

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


def watch(interval: float) -> None:
    last_key: tuple[str, str, str] | None = None
    while True:
        info = get_current_track()
        if isinstance(info, TrackInfo):
            if info.key != last_key and info.state == "playing":
                print(info, flush=True)
                last_key = info.key
        else:
            if last_key is not None:
                print(info, flush=True)
                last_key = None
        time.sleep(interval)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--watch",
        action="store_true",
        help="Poll continuously and print whenever the track changes.",
    )
    parser.add_argument(
        "--interval",
        type=float,
        default=2.0,
        help="Polling interval in seconds for --watch (default: 2).",
    )
    args = parser.parse_args()

    if args.watch:
        try:
            watch(args.interval)
        except KeyboardInterrupt:
            return 0
        return 0

    info = get_current_track()
    print(info)
    return 0 if isinstance(info, TrackInfo) else 1


if __name__ == "__main__":
    raise SystemExit(main())

"""Per-stem WAV recorder. Writes each stem (and the post-mixer mix) to its own
PCM_16 WAV file in a timestamped session folder. Toggle from the UI."""
from __future__ import annotations

import threading
from datetime import datetime
from pathlib import Path

import numpy as np
import soundfile as sf


class StemRecorder:
    def __init__(self, sample_rate: int, channels: int, root: Path | str = "recordings"):
        self.sample_rate = sample_rate
        self.channels = channels
        self.root = Path(root)
        self._files: dict[str, sf.SoundFile] = {}
        self._lock = threading.Lock()
        self._active = False
        self._session_dir: Path | None = None

    @property
    def active(self) -> bool:
        return self._active

    @property
    def session_dir(self) -> Path | None:
        return self._session_dir

    def start(self) -> Path:
        with self._lock:
            if self._active:
                return self._session_dir  # type: ignore[return-value]
            ts = datetime.now().strftime("%Y%m%d-%H%M%S")
            self._session_dir = self.root / f"session-{ts}"
            self._session_dir.mkdir(parents=True, exist_ok=True)
            self._files = {}
            self._active = True
            return self._session_dir

    def _open(self, name: str) -> sf.SoundFile:
        assert self._session_dir is not None
        path = self._session_dir / f"{name}.wav"
        return sf.SoundFile(
            str(path),
            mode="w",
            samplerate=self.sample_rate,
            channels=self.channels,
            subtype="PCM_16",
        )

    def write_stems(self, stems: dict[str, np.ndarray], mix: np.ndarray | None = None) -> None:
        with self._lock:
            if not self._active:
                return
            for name, audio in stems.items():
                f = self._files.get(name)
                if f is None:
                    f = self._open(name)
                    self._files[name] = f
                f.write(audio.astype(np.float32, copy=False))
            if mix is not None:
                f = self._files.get("_mix")
                if f is None:
                    f = self._open("_mix")
                    self._files["_mix"] = f
                f.write(mix.astype(np.float32, copy=False))

    def stop(self) -> Path | None:
        with self._lock:
            if not self._active:
                return None
            for f in self._files.values():
                try:
                    f.close()
                except Exception:
                    pass
            self._files.clear()
            self._active = False
            session = self._session_dir
            self._session_dir = None
            return session

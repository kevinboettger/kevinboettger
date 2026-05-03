"""Per-stem mixer with gain, mute, solo, and level metering."""
from __future__ import annotations

import threading
from dataclasses import dataclass

import numpy as np


@dataclass
class StemState:
    gain: float = 1.0
    mute: bool = False
    solo: bool = False
    last_rms: float = 0.0


class StemMixer:
    def __init__(self, stems: list[str]):
        self.stems = list(stems)
        self.states: dict[str, StemState] = {s: StemState() for s in stems}
        self._lock = threading.Lock()

    def set_gain(self, stem: str, gain: float) -> None:
        with self._lock:
            self.states[stem].gain = max(0.0, float(gain))

    def toggle_mute(self, stem: str) -> bool:
        with self._lock:
            self.states[stem].mute = not self.states[stem].mute
            return self.states[stem].mute

    def toggle_solo(self, stem: str) -> bool:
        with self._lock:
            self.states[stem].solo = not self.states[stem].solo
            return self.states[stem].solo

    def mix(self, stem_chunks: dict[str, np.ndarray]) -> np.ndarray:
        with self._lock:
            any_solo = any(s.solo for s in self.states.values())
            mixed: np.ndarray | None = None
            for stem, audio in stem_chunks.items():
                state = self.states.get(stem)
                if state is None:
                    continue
                # RMS metering on the raw stem (pre-mute), so meters keep moving
                # even when a track is muted.
                rms = float(np.sqrt(np.mean(audio.astype(np.float64) ** 2) + 1e-12))
                state.last_rms = rms
                active = state.solo if any_solo else not state.mute
                if not active:
                    continue
                contribution = audio * state.gain
                mixed = contribution if mixed is None else mixed + contribution
            if mixed is None:
                any_audio = next(iter(stem_chunks.values()))
                mixed = np.zeros_like(any_audio)
            np.clip(mixed, -1.0, 1.0, out=mixed)
            return mixed

    def levels(self) -> dict[str, float]:
        with self._lock:
            return {s: st.last_rms for s, st in self.states.items()}

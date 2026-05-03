"""Synthetic mixing dataset.

For each yielded sample: pick one random clip per category, apply random gain
(and pan for SFX), sum into a mixture, and emit (mix, stems). Mixes are
generated on the fly so every epoch is unique.
"""
from __future__ import annotations

import csv
import random
from math import gcd
from pathlib import Path

import numpy as np
import soundfile as sf
import torch
from scipy.signal import resample_poly
from torch.utils.data import IterableDataset

from .config import TrainConfig


def _db_to_lin(db: float) -> float:
    return 10.0 ** (db / 20.0)


def _resample(x: np.ndarray, src_sr: int, dst_sr: int) -> np.ndarray:
    if src_sr == dst_sr:
        return x
    g = gcd(src_sr, dst_sr)
    return resample_poly(x, dst_sr // g, src_sr // g, axis=0).astype(np.float32)


def _load_window(path: str, target_sr: int, frames: int, rng: random.Random) -> np.ndarray:
    """Load a random window of `frames` samples at `target_sr`. Returns (frames, 2)."""
    info = sf.info(path)
    src_sr = info.samplerate
    src_frames = int(frames * src_sr / target_sr) + 16

    if info.frames <= src_frames:
        start, stop = 0, info.frames
    else:
        start = rng.randint(0, info.frames - src_frames)
        stop = start + src_frames

    data, sr = sf.read(path, start=start, stop=stop, dtype="float32", always_2d=True)
    data = _resample(data, sr, target_sr)

    if data.shape[1] == 1:
        data = np.repeat(data, 2, axis=1)
    elif data.shape[1] > 2:
        data = data[:, :2]

    if data.shape[0] >= frames:
        offset = rng.randint(0, data.shape[0] - frames)
        data = data[offset : offset + frames]
    else:
        pad = np.zeros((frames - data.shape[0], 2), dtype=np.float32)
        data = np.concatenate([data, pad], axis=0)
    return data


def _gain_pan(audio: np.ndarray, gain_db: float, pan: float) -> np.ndarray:
    g = _db_to_lin(gain_db)
    angle = (pan + 1.0) * (np.pi / 4.0)  # equal-power: pan ∈ [-1, 1]
    left = np.cos(angle) * g
    right = np.sin(angle) * g
    out = audio.copy()
    out[:, 0] *= left
    out[:, 1] *= right
    return out


class SynthMixDataset(IterableDataset):
    """Yields (mix, stems) where mix is (2, T) and stems is (S, 2, T)."""

    def __init__(self, cfg: TrainConfig, manifest_path: Path, seed: int = 0):
        super().__init__()
        self.cfg = cfg
        self.frames = int(cfg.sample_rate * cfg.segment_seconds)
        self._seed = seed
        self._index: dict[str, list[str]] = {c: [] for c in cfg.categories}
        with manifest_path.open() as f:
            for row in csv.DictReader(f):
                cat = row["category"]
                if cat in self._index:
                    self._index[cat].append(row["path"])
        for cat, lst in self._index.items():
            if not lst:
                raise RuntimeError(f"No clips for category {cat!r} in {manifest_path}")
            print(f"[dataset] {cat}: {len(lst)} clips")

    def _make_sample(self, rng: random.Random) -> tuple[torch.Tensor, torch.Tensor]:
        stems = []
        for cat in self.cfg.categories:
            if rng.random() > self.cfg.include_prob.get(cat, 1.0):
                stems.append(np.zeros((self.frames, 2), dtype=np.float32))
                continue
            path = rng.choice(self._index[cat])
            clip = _load_window(path, self.cfg.sample_rate, self.frames, rng)
            gain_db = rng.uniform(*self.cfg.gain_db[cat])
            pan = rng.uniform(-self.cfg.pan_max, self.cfg.pan_max) if cat == "sfx" else 0.0
            stems.append(_gain_pan(clip, gain_db, pan))

        stems_np = np.stack(stems, axis=0)            # (S, T, 2)
        mix = stems_np.sum(axis=0)                    # (T, 2)

        peak = float(np.max(np.abs(mix)))
        if peak > 0.99:
            scale = 0.99 / peak
            mix *= scale
            stems_np *= scale

        mix_t = torch.from_numpy(np.ascontiguousarray(mix.T))            # (2, T)
        stems_t = torch.from_numpy(np.ascontiguousarray(stems_np.transpose(0, 2, 1)))  # (S, 2, T)
        return mix_t, stems_t

    def __iter__(self):
        worker = torch.utils.data.get_worker_info()
        wid = worker.id if worker is not None else 0
        rng = random.Random(self._seed * 1_000_003 + wid * 991 + 7919)
        while True:
            yield self._make_sample(rng)

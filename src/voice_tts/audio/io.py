"""Minimal 16-bit PCM WAV read/write via the standard library.

Avoids a libsndfile/soundfile dependency for the foundation. Sufficient for
LJSpeech-style mono PCM corpora and for writing synthesis output.
"""

from __future__ import annotations

import wave
from pathlib import Path

import numpy as np
import torch
from torch import Tensor


def save_wav(path: str | Path, waveform: Tensor, sample_rate: int) -> None:
    samples = waveform.detach().to(torch.float32).cpu().numpy().reshape(-1)
    peak = float(np.max(np.abs(samples))) if samples.size else 0.0
    if peak > 1.0:
        samples = samples / peak
    pcm = (np.clip(samples, -1.0, 1.0) * 32767.0).astype("<i2")
    with wave.open(str(path), "wb") as wf:
        wf.setnchannels(1)
        wf.setsampwidth(2)
        wf.setframerate(sample_rate)
        wf.writeframes(pcm.tobytes())


def load_wav(path: str | Path) -> tuple[Tensor, int]:
    with wave.open(str(path), "rb") as wf:
        sample_rate = wf.getframerate()
        n_channels = wf.getnchannels()
        frames = wf.readframes(wf.getnframes())
    pcm = np.frombuffer(frames, dtype="<i2").astype(np.float32) / 32768.0
    if n_channels > 1:
        pcm = pcm.reshape(-1, n_channels).mean(axis=1)
    return torch.from_numpy(pcm.copy()), sample_rate

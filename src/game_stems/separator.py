"""Streaming Demucs separator.

Buffers input at the device sample rate, resamples to the model's 44.1 kHz,
runs Demucs over a sliding window with crossfade-on-overlap, then resamples
each stem back to the device sample rate. Effective latency = window - hop.
"""
from __future__ import annotations

import threading
from math import gcd

import numpy as np
import torch
from demucs.apply import apply_model
from demucs.pretrained import get_model
from scipy.signal import resample_poly

# Map Demucs htdemucs sources to user-facing labels. Demucs is trained on music,
# so for game audio: vocals catches dialog well; drums/bass/other split music
# but also absorb percussive/tonal SFX. Honest labels reflect that.
STEM_LABELS: dict[str, str] = {
    "vocals": "Dialog",
    "drums": "Music (drums)",
    "bass": "Music (bass)",
    "other": "SFX / Music",
}


class StreamingSeparator:
    MODEL_SR = 44100

    def __init__(
        self,
        input_sr: int,
        input_channels: int,
        model_name: str = "htdemucs",
        window_seconds: float = 2.0,
        hop_seconds: float = 1.0,
        device: str | None = None,
    ):
        if hop_seconds >= window_seconds:
            raise ValueError("hop_seconds must be < window_seconds")
        self.input_sr = input_sr
        self.input_channels = input_channels
        self.window_samples = int(self.MODEL_SR * window_seconds)
        self.hop_samples = int(self.MODEL_SR * hop_seconds)
        self.crossfade_samples = self.window_samples - self.hop_samples

        self.device = device or ("cuda" if torch.cuda.is_available() else "cpu")
        self._model = get_model(model_name)
        self._model.to(self.device).eval()
        self.stems: list[str] = list(self._model.sources)

        self._in_buf = np.zeros((2, 0), dtype=np.float32)
        self._tails: dict[str, np.ndarray] = {
            s: np.zeros((2, self.crossfade_samples), dtype=np.float32) for s in self.stems
        }
        n = self.crossfade_samples
        ramp = np.linspace(0.0, 1.0, n, dtype=np.float32)
        self._fade_in = ramp.reshape(1, n)
        self._fade_out = (1.0 - ramp).reshape(1, n)
        self._first_window = True
        self._lock = threading.Lock()

        if self.input_sr != self.MODEL_SR:
            g = gcd(self.input_sr, self.MODEL_SR)
            self._up_in = self.MODEL_SR // g
            self._down_in = self.input_sr // g
        else:
            self._up_in = self._down_in = 1

    def _to_stereo_44k(self, x: np.ndarray) -> np.ndarray:
        # x: (frames, input_channels) -> (2, frames_at_44k)
        if x.shape[1] == 1:
            x = np.repeat(x, 2, axis=1)
        elif x.shape[1] >= 2:
            x = x[:, :2]
        if self._up_in != 1 or self._down_in != 1:
            x = resample_poly(x, self._up_in, self._down_in, axis=0)
        return np.ascontiguousarray(x.T, dtype=np.float32)

    def _from_44k(self, x: np.ndarray) -> np.ndarray:
        # x: (2, frames_at_44k) -> (frames_at_input_sr, input_channels)
        if self._up_in != 1 or self._down_in != 1:
            x = resample_poly(x, self._down_in, self._up_in, axis=1)
        x = x.T
        if self.input_channels == 1:
            x = x.mean(axis=1, keepdims=True)
        elif self.input_channels > 2:
            pad = np.zeros((x.shape[0], self.input_channels - 2), dtype=np.float32)
            x = np.concatenate([x, pad], axis=1)
        return np.ascontiguousarray(x, dtype=np.float32)

    def push(self, audio: np.ndarray) -> dict[str, np.ndarray] | None:
        """Push input audio (frames, channels). Returns stems for one hop, or None."""
        with self._lock:
            stereo = self._to_stereo_44k(audio)
            self._in_buf = np.concatenate([self._in_buf, stereo], axis=1)
            if self._in_buf.shape[1] < self.window_samples:
                return None
            window = self._in_buf[:, : self.window_samples].copy()
            self._in_buf = self._in_buf[:, self.hop_samples :]
            first = self._first_window
            self._first_window = False
            tails = {k: v.copy() for k, v in self._tails.items()}

        wav = torch.from_numpy(window).to(self.device).unsqueeze(0)  # (1, 2, W)
        with torch.no_grad():
            sources = apply_model(self._model, wav, device=self.device)[0]
        sources_np = sources.detach().cpu().numpy().astype(np.float32)  # (S, 2, W)

        H, C = self.hop_samples, self.crossfade_samples
        emitted: dict[str, np.ndarray] = {}
        new_tails: dict[str, np.ndarray] = {}
        for i, stem in enumerate(self.stems):
            seg = sources_np[i]  # (2, W)
            if first:
                chunk = seg[:, :H]
            else:
                head = tails[stem] * self._fade_out + seg[:, :C] * self._fade_in
                mid = seg[:, C:H]
                chunk = np.concatenate([head, mid], axis=1)
            new_tails[stem] = seg[:, H:].copy()
            emitted[stem] = self._from_44k(chunk)

        with self._lock:
            self._tails = new_tails
        return emitted

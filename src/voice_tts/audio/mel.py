"""Mel-spectrogram extraction and waveform reconstruction.

The acoustic model regresses log-mel spectrograms. For the foundation we invert
mels back to audio with Griffin-Lim (no trained vocoder required), which is fully
deterministic and dependency-light. A neural vocoder (e.g. HiFi-GAN) can replace
``MelInverter`` later behind the same interface.
"""

from __future__ import annotations

import torch
import torchaudio
from torch import Tensor

from voice_tts.config import AudioConfig


class MelExtractor:
    """Waveform -> normalised log-mel spectrogram ``(n_mels, time)``."""

    def __init__(self, cfg: AudioConfig) -> None:
        self.cfg = cfg
        self._mel = torchaudio.transforms.MelSpectrogram(
            sample_rate=cfg.sample_rate,
            n_fft=cfg.n_fft,
            win_length=cfg.win_length,
            hop_length=cfg.hop_length,
            n_mels=cfg.n_mels,
            f_min=cfg.f_min,
            f_max=cfg.f_max,
            power=2.0,
        )

    def __call__(self, waveform: Tensor) -> Tensor:
        if waveform.dim() == 1:
            waveform = waveform.unsqueeze(0)
        mel = self._mel(waveform).squeeze(0)
        return _normalize(_amplitude_to_db(mel), self.cfg)


class MelInverter:
    """Normalised log-mel spectrogram -> waveform via Griffin-Lim."""

    def __init__(self, cfg: AudioConfig, n_iter: int = 60) -> None:
        self.cfg = cfg
        self._inv_mel = torchaudio.transforms.InverseMelScale(
            n_stft=cfg.n_fft // 2 + 1,
            n_mels=cfg.n_mels,
            sample_rate=cfg.sample_rate,
            f_min=cfg.f_min,
            f_max=cfg.f_max,
        )
        self._griffin_lim = torchaudio.transforms.GriffinLim(
            n_fft=cfg.n_fft,
            win_length=cfg.win_length,
            hop_length=cfg.hop_length,
            power=2.0,
            n_iter=n_iter,
        )

    def __call__(self, mel: Tensor) -> Tensor:
        power_mel = _db_to_amplitude(_denormalize(mel, self.cfg))
        spec = self._inv_mel(power_mel)
        return self._griffin_lim(spec)


def _amplitude_to_db(mel: Tensor) -> Tensor:
    return 10.0 * torch.log10(torch.clamp(mel, min=1e-5))


def _db_to_amplitude(mel_db: Tensor) -> Tensor:
    return torch.pow(10.0, mel_db / 10.0)


def _normalize(mel_db: Tensor, cfg: AudioConfig) -> Tensor:
    mel_db = mel_db - cfg.ref_level_db
    return torch.clamp((mel_db - cfg.min_level_db) / -cfg.min_level_db, 0.0, 1.0)


def _denormalize(mel: Tensor, cfg: AudioConfig) -> Tensor:
    mel_db = torch.clamp(mel, 0.0, 1.0) * -cfg.min_level_db + cfg.min_level_db
    return mel_db + cfg.ref_level_db

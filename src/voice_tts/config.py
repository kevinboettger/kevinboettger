"""Configuration for audio feature extraction and the acoustic model.

These defaults follow common 22.05 kHz / 80-mel conventions (LJSpeech-style)
so public single-speaker datasets work without changes.
"""

from __future__ import annotations

from dataclasses import dataclass


@dataclass(frozen=True)
class AudioConfig:
    sample_rate: int = 22050
    n_fft: int = 1024
    hop_length: int = 256
    win_length: int = 1024
    n_mels: int = 80
    f_min: float = 0.0
    f_max: float = 8000.0
    # Mel values are compressed with log and normalised by these bounds so the
    # model regresses onto a roughly [0, 1] range.
    ref_level_db: float = 20.0
    min_level_db: float = -100.0

    @property
    def frames_per_second(self) -> float:
        return self.sample_rate / self.hop_length


@dataclass(frozen=True)
class ModelConfig:
    d_model: int = 256
    n_heads: int = 2
    ff_dim: int = 1024
    encoder_layers: int = 4
    decoder_layers: int = 4
    dropout: float = 0.1
    # Duration predictor clamps, in mel frames per token.
    max_token_duration: int = 75

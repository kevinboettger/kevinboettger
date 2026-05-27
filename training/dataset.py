"""Datasets and batching for acoustic-model training.

``TTSDataset`` reads an LJSpeech-style manifest: one ``audio_path|transcript``
pair per line (``|`` separated). Audio is resampled to the model rate and turned
into a log-mel target; transcripts are tokenised.

Token->frame durations use a proportional alignment (each token gets an equal
share of the frames, summing exactly to the clip length). This is a deliberate
placeholder so training is self-contained; replace ``proportional_durations``
with a forced aligner (e.g. MFA) or attention-derived durations for quality.
"""

from __future__ import annotations

from dataclasses import dataclass
from pathlib import Path

import torch
import torchaudio
from torch import Tensor
from torch.utils.data import Dataset

from voice_tts.audio import MelExtractor, load_wav
from voice_tts.config import AudioConfig
from voice_tts.text import Tokenizer


def proportional_durations(n_tokens: int, mel_len: int) -> list[int]:
    if n_tokens <= 0:
        return []
    base = mel_len // n_tokens
    remainder = mel_len - base * n_tokens
    return [base + (1 if i < remainder else 0) for i in range(n_tokens)]


@dataclass
class Sample:
    tokens: Tensor  # (T_tok,) long
    mel: Tensor  # (n_mels, T_mel)
    durations: Tensor  # (T_tok,) long, sums to T_mel


class TTSDataset(Dataset):
    def __init__(self, manifest: str | Path, audio_cfg: AudioConfig, data_root: str | Path | None = None) -> None:
        self.audio_cfg = audio_cfg
        self.tokenizer = Tokenizer()
        self.mel = MelExtractor(audio_cfg)
        self.root = Path(data_root) if data_root else Path(manifest).parent
        self.entries: list[tuple[str, str]] = []
        for line in Path(manifest).read_text(encoding="utf-8").splitlines():
            line = line.strip()
            if not line or "|" not in line:
                continue
            path, transcript = line.split("|", 1)
            self.entries.append((path.strip(), transcript.strip()))

    def __len__(self) -> int:
        return len(self.entries)

    def __getitem__(self, idx: int) -> Sample:
        path, transcript = self.entries[idx]
        wav_path = self.root / path
        try:
            waveform, sr = torchaudio.load(str(wav_path))
            waveform = waveform.mean(dim=0)
        except Exception:
            waveform, sr = load_wav(wav_path)
        if sr != self.audio_cfg.sample_rate:
            waveform = torchaudio.functional.resample(waveform, sr, self.audio_cfg.sample_rate)

        mel = self.mel(waveform)
        tokens = self.tokenizer.encode(transcript)
        durations = proportional_durations(len(tokens), mel.size(1))
        return Sample(
            tokens=torch.tensor(tokens, dtype=torch.long),
            mel=mel,
            durations=torch.tensor(durations, dtype=torch.long),
        )


class SyntheticDataset(Dataset):
    """In-memory random samples for smoke-testing the training loop.

    Produces tokenised nonsense text and a tone-based waveform so the pipeline
    runs end-to-end without a corpus. Not useful for learning real speech.
    """

    def __init__(self, audio_cfg: AudioConfig, size: int = 64, seed: int = 0) -> None:
        self.audio_cfg = audio_cfg
        self.tokenizer = Tokenizer()
        self.mel = MelExtractor(audio_cfg)
        self.size = size
        self._gen = torch.Generator().manual_seed(seed)
        words = ["hello world", "the quick brown fox", "voice synthesis", "good morning"]
        self.texts = [words[i % len(words)] for i in range(size)]

    def __len__(self) -> int:
        return self.size

    def __getitem__(self, idx: int) -> Sample:
        sr = self.audio_cfg.sample_rate
        duration_s = 1.0 + (idx % 3) * 0.5
        t = torch.linspace(0, duration_s, int(sr * duration_s))
        freq = 110.0 + (idx % 8) * 20.0
        waveform = 0.3 * torch.sin(2 * torch.pi * freq * t)
        mel = self.mel(waveform)
        tokens = self.tokenizer.encode(self.texts[idx])
        durations = proportional_durations(len(tokens), mel.size(1))
        return Sample(
            tokens=torch.tensor(tokens, dtype=torch.long),
            mel=mel,
            durations=torch.tensor(durations, dtype=torch.long),
        )


@dataclass
class Batch:
    tokens: Tensor  # (B, T_tok)
    durations: Tensor  # (B, T_tok)
    mels: Tensor  # (B, n_mels, T_mel)
    mel_lengths: Tensor  # (B,)


def make_collate(pad_id: int):
    def collate(samples: list[Sample]) -> Batch:
        max_tok = max(s.tokens.size(0) for s in samples)
        max_mel = max(s.mel.size(1) for s in samples)
        n_mels = samples[0].mel.size(0)
        b = len(samples)

        tokens = torch.full((b, max_tok), pad_id, dtype=torch.long)
        durations = torch.zeros((b, max_tok), dtype=torch.long)
        mels = torch.zeros((b, n_mels, max_mel), dtype=torch.float32)
        mel_lengths = torch.zeros(b, dtype=torch.long)

        for i, s in enumerate(samples):
            tokens[i, : s.tokens.size(0)] = s.tokens
            durations[i, : s.durations.size(0)] = s.durations
            mels[i, :, : s.mel.size(1)] = s.mel
            mel_lengths[i] = s.mel.size(1)
        return Batch(tokens=tokens, durations=durations, mels=mels, mel_lengths=mel_lengths)

    return collate

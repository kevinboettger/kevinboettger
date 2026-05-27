"""Non-autoregressive acoustic model: token ids -> log-mel spectrogram.

A compact FastSpeech-style network built from scratch:

    embedding -> Transformer encoder -> duration predictor
              -> length regulator -> Transformer decoder -> mel + postnet

Durations align text tokens to mel frames. During training they are supplied by
the dataset; at inference they are predicted. The foundation uses a proportional
alignment (see ``training.dataset``); a learned aligner can be dropped in later
without changing this module's interface.
"""

from __future__ import annotations

import math
from dataclasses import dataclass

import torch
from torch import Tensor, nn

from voice_tts.config import AudioConfig, ModelConfig


@dataclass
class AcousticOutput:
    mel: Tensor  # (B, n_mels, T_mel) after postnet
    mel_pre: Tensor  # (B, n_mels, T_mel) before postnet
    log_duration: Tensor  # (B, T_tok)
    mel_mask: Tensor  # (B, T_mel) True = padding


class PositionalEncoding(nn.Module):
    def __init__(self, d_model: int, max_len: int = 4096) -> None:
        super().__init__()
        pe = torch.zeros(max_len, d_model)
        pos = torch.arange(max_len).unsqueeze(1).float()
        div = torch.exp(torch.arange(0, d_model, 2).float() * (-math.log(10000.0) / d_model))
        pe[:, 0::2] = torch.sin(pos * div)
        pe[:, 1::2] = torch.cos(pos * div)
        self.register_buffer("pe", pe.unsqueeze(0), persistent=False)

    def forward(self, x: Tensor) -> Tensor:
        return x + self.pe[:, : x.size(1)]


class DurationPredictor(nn.Module):
    def __init__(self, d_model: int, dropout: float) -> None:
        super().__init__()
        self.conv1 = nn.Conv1d(d_model, d_model, kernel_size=3, padding=1)
        self.norm1 = nn.LayerNorm(d_model)
        self.conv2 = nn.Conv1d(d_model, d_model, kernel_size=3, padding=1)
        self.norm2 = nn.LayerNorm(d_model)
        self.drop = nn.Dropout(dropout)
        self.proj = nn.Linear(d_model, 1)

    def forward(self, x: Tensor, pad_mask: Tensor) -> Tensor:
        # x: (B, T, D); pad_mask: (B, T) True = padding
        h = self.conv1(x.transpose(1, 2)).transpose(1, 2)
        h = self.drop(torch.relu(self.norm1(h)))
        h = self.conv2(h.transpose(1, 2)).transpose(1, 2)
        h = self.drop(torch.relu(self.norm2(h)))
        log_dur = self.proj(h).squeeze(-1)
        return log_dur.masked_fill(pad_mask, 0.0)


class Postnet(nn.Module):
    """Tacotron2-style 5-layer conv postnet predicting a mel residual."""

    def __init__(self, n_mels: int, channels: int = 512, n_layers: int = 5) -> None:
        super().__init__()
        layers: list[nn.Module] = []
        for i in range(n_layers):
            in_ch = n_mels if i == 0 else channels
            out_ch = n_mels if i == n_layers - 1 else channels
            layers.append(nn.Conv1d(in_ch, out_ch, kernel_size=5, padding=2))
            layers.append(nn.BatchNorm1d(out_ch))
            if i < n_layers - 1:
                layers.append(nn.Tanh())
            layers.append(nn.Dropout(0.1))
        self.net = nn.Sequential(*layers)

    def forward(self, mel: Tensor) -> Tensor:
        return self.net(mel)


def _transformer(cfg: ModelConfig, n_layers: int) -> nn.TransformerEncoder:
    layer = nn.TransformerEncoderLayer(
        d_model=cfg.d_model,
        nhead=cfg.n_heads,
        dim_feedforward=cfg.ff_dim,
        dropout=cfg.dropout,
        activation="gelu",
        batch_first=True,
        norm_first=True,
    )
    return nn.TransformerEncoder(layer, num_layers=n_layers)


class AcousticModel(nn.Module):
    def __init__(self, vocab_size: int, pad_id: int, audio: AudioConfig, model: ModelConfig) -> None:
        super().__init__()
        self.pad_id = pad_id
        self.cfg = model
        self.audio = audio
        self.embed = nn.Embedding(vocab_size, model.d_model, padding_idx=pad_id)
        self.pos = PositionalEncoding(model.d_model)
        self.encoder = _transformer(model, model.encoder_layers)
        self.duration_predictor = DurationPredictor(model.d_model, model.dropout)
        self.decoder = _transformer(model, model.decoder_layers)
        self.mel_linear = nn.Linear(model.d_model, audio.n_mels)
        self.postnet = Postnet(audio.n_mels)
        self._scale = math.sqrt(model.d_model)

    def forward(
        self,
        tokens: Tensor,
        durations: Tensor | None = None,
        max_mel_len: int | None = None,
    ) -> AcousticOutput:
        pad_mask = tokens.eq(self.pad_id)
        x = self.pos(self.embed(tokens) * self._scale)
        x = self.encoder(x, src_key_padding_mask=pad_mask)
        log_dur = self.duration_predictor(x, pad_mask)

        if durations is None:
            durations = self._infer_durations(log_dur, pad_mask)
        expanded, mel_mask = self._length_regulate(x, durations, max_mel_len)

        y = self.decoder(expanded, src_key_padding_mask=mel_mask)
        mel_pre = self.mel_linear(y).transpose(1, 2)  # (B, n_mels, T_mel)
        mel = mel_pre + self.postnet(mel_pre)
        # Silence padded frames so they do not pollute reconstruction.
        keep = (~mel_mask).unsqueeze(1)
        return AcousticOutput(mel * keep, mel_pre * keep, log_dur, mel_mask)

    def _infer_durations(self, log_dur: Tensor, pad_mask: Tensor) -> Tensor:
        dur = torch.round(torch.exp(log_dur)).clamp(1, self.cfg.max_token_duration)
        return dur.long().masked_fill(pad_mask, 0)

    def _length_regulate(
        self, x: Tensor, durations: Tensor, max_len: int | None
    ) -> tuple[Tensor, Tensor]:
        B, _, D = x.shape
        durations = durations.clamp(min=0).long()
        expanded = [torch.repeat_interleave(x[b], durations[b], dim=0) for b in range(B)]
        lengths = [e.size(0) for e in expanded]
        target = max_len or max(lengths)
        target = max(int(target), 1)
        out = x.new_zeros(B, target, D)
        mask = torch.ones(B, target, dtype=torch.bool, device=x.device)
        for b, e in enumerate(expanded):
            n = min(e.size(0), target)
            if n > 0:
                out[b, :n] = e[:n]
                mask[b, :n] = False
        return out, mask


def build_model(vocab_size: int, pad_id: int, audio: AudioConfig, model: ModelConfig) -> AcousticModel:
    return AcousticModel(vocab_size, pad_id, audio, model)

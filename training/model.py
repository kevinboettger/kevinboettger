"""HTDemucs with a custom 3-source taxonomy (dialog/music/sfx).

We construct an HTDemucs from scratch. Warm-starting the encoder from the
pretrained htdemucs is straightforward (load state_dict with strict=False)
and worth doing once you have data — the encoder transfers, the source-
specific output paths reinitialize. See `warm_start_from_pretrained`.
"""
from __future__ import annotations

from typing import Iterable

import torch
from demucs.htdemucs import HTDemucs
from demucs.pretrained import get_model


def build_model(sources: Iterable[str], samplerate: int = 44100,
                segment_seconds: float = 6.0) -> HTDemucs:
    return HTDemucs(
        sources=list(sources),
        samplerate=samplerate,
        segment=segment_seconds,
    )


def warm_start_from_pretrained(model: HTDemucs, pretrained_name: str = "htdemucs") -> int:
    """Copy compatible weights from a pretrained Demucs model. Returns # tensors copied."""
    src = get_model(pretrained_name)
    src_sd = src.state_dict()
    dst_sd = model.state_dict()
    copied = 0
    for k, v in src_sd.items():
        if k in dst_sd and dst_sd[k].shape == v.shape:
            dst_sd[k] = v
            copied += 1
    model.load_state_dict(dst_sd)
    return copied


def count_params(model: torch.nn.Module) -> int:
    return sum(p.numel() for p in model.parameters() if p.requires_grad)

"""Training hyperparameters. Defaults are tuned for a 16 GB laptop 4090."""
from __future__ import annotations

from dataclasses import dataclass, field
from pathlib import Path


@dataclass
class TrainConfig:
    # ---- Data ----
    data_root: Path = Path("training/data/raw")
    manifest_path: Path = Path("training/data/manifest.csv")
    sample_rate: int = 44100
    segment_seconds: float = 6.0
    categories: tuple[str, ...] = ("dialog", "music", "sfx")

    # ---- Mix synthesis ----
    # Per-category gain (dBFS-ish) applied before summing. Loose ranges that mimic
    # typical game mixes; tune later from real-world captures.
    gain_db: dict[str, tuple[float, float]] = field(default_factory=lambda: {
        "dialog": (-15.0, -3.0),
        "music":  (-22.0, -8.0),
        "sfx":    (-20.0, -5.0),
    })
    # Probability that each category is present in any given mix.
    include_prob: dict[str, float] = field(default_factory=lambda: {
        "dialog": 0.85,
        "music":  0.95,
        "sfx":    0.95,
    })
    # Equal-power pan ∈ [-pan_max, +pan_max] for SFX. Dialog/music stay centered.
    pan_max: float = 0.6

    # ---- Optimization ----
    batch_size: int = 2
    grad_accum: int = 8           # effective batch = 16
    lr: float = 3e-4
    grad_clip: float = 5.0
    max_steps: int = 200_000
    amp_dtype: str = "bf16"        # "bf16" or "fp16"

    # ---- Logging / checkpoints ----
    log_every: int = 50
    val_every: int = 2_000
    val_batches: int = 32
    checkpoint_every: int = 5_000
    checkpoint_dir: Path = Path("training/checkpoints")

    # ---- DataLoader ----
    num_workers: int = 4
    pin_memory: bool = True

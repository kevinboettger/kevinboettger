"""Training hyperparameters."""

from __future__ import annotations

from dataclasses import dataclass


@dataclass
class TrainConfig:
    batch_size: int = 16
    learning_rate: float = 3e-4
    weight_decay: float = 1e-6
    grad_clip: float = 1.0
    max_steps: int = 100_000
    # Weight on the duration-predictor loss relative to mel reconstruction.
    duration_loss_weight: float = 0.1
    log_every: int = 50
    checkpoint_every: int = 1000
    num_workers: int = 2
    seed: int = 1234

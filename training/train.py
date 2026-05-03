"""Training loop for the 3-stem game-audio separator.

Pipeline: SynthMixDataset → HTDemucs → L1 stem loss with AMP + grad accum.
Periodically computes SI-SDR per source on a held-out random seed.

Run after manifest.py:
    python -m training.train

Resume:
    python -m training.train --resume training/checkpoints/latest.pt

Warm-start encoder from stock htdemucs (recommended):
    python -m training.train --warm-start
"""
from __future__ import annotations

import argparse
import time
from pathlib import Path

import torch
import torch.nn.functional as F
from torch.utils.data import DataLoader

from .config import TrainConfig
from .model import build_model, count_params, warm_start_from_pretrained
from .synth_dataset import SynthMixDataset


def si_sdr(estimate: torch.Tensor, target: torch.Tensor, eps: float = 1e-8) -> torch.Tensor:
    """SI-SDR per (batch, source), in dB. Inputs: (B, S, C, T) → (B, S)."""
    est = estimate - estimate.mean(dim=-1, keepdim=True)
    tgt = target - target.mean(dim=-1, keepdim=True)
    dot = (est * tgt).sum(dim=-1, keepdim=True)
    proj = dot / (tgt.pow(2).sum(dim=-1, keepdim=True) + eps) * tgt
    noise = est - proj
    num = proj.pow(2).sum(dim=-1).sum(dim=-1)
    den = noise.pow(2).sum(dim=-1).sum(dim=-1) + eps
    return 10.0 * torch.log10(num / den + eps)


@torch.no_grad()
def validate(model, loader, device, n_batches: int, sources: list[str]) -> dict[str, float]:
    model.eval()
    sdrs = []
    for i, (mix, stems) in enumerate(loader):
        if i >= n_batches:
            break
        mix = mix.to(device, non_blocking=True)
        stems = stems.to(device, non_blocking=True)
        est = model(mix)
        sdrs.append(si_sdr(est, stems).cpu())
    model.train()
    if not sdrs:
        return {}
    mean = torch.cat(sdrs, dim=0).mean(dim=0)
    return {f"sdr/{name}": float(mean[i]) for i, name in enumerate(sources)}


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--manifest", type=Path, default=Path("training/data/manifest.csv"))
    ap.add_argument("--checkpoint-dir", type=Path, default=None)
    ap.add_argument("--resume", type=Path, default=None)
    ap.add_argument("--warm-start", action="store_true",
                    help="Initialize from pretrained htdemucs (encoder transfers).")
    ap.add_argument("--batch-size", type=int, default=None)
    ap.add_argument("--grad-accum", type=int, default=None)
    ap.add_argument("--max-steps", type=int, default=None)
    ap.add_argument("--lr", type=float, default=None)
    ap.add_argument("--segment-seconds", type=float, default=None)
    ap.add_argument("--num-workers", type=int, default=None)
    ap.add_argument("--device", default="cuda" if torch.cuda.is_available() else "cpu")
    args = ap.parse_args()

    cfg = TrainConfig()
    if args.batch_size is not None: cfg.batch_size = args.batch_size
    if args.grad_accum is not None: cfg.grad_accum = args.grad_accum
    if args.max_steps is not None:  cfg.max_steps = args.max_steps
    if args.lr is not None:         cfg.lr = args.lr
    if args.segment_seconds is not None: cfg.segment_seconds = args.segment_seconds
    if args.num_workers is not None: cfg.num_workers = args.num_workers
    if args.checkpoint_dir is not None: cfg.checkpoint_dir = args.checkpoint_dir
    cfg.checkpoint_dir.mkdir(parents=True, exist_ok=True)

    device = torch.device(args.device)
    print(f"Device:  {device}")
    print(f"Sources: {list(cfg.categories)}")

    train_ds = SynthMixDataset(cfg, args.manifest, seed=42)
    val_ds   = SynthMixDataset(cfg, args.manifest, seed=20240501)
    train_loader = DataLoader(
        train_ds, batch_size=cfg.batch_size,
        num_workers=cfg.num_workers, pin_memory=cfg.pin_memory,
    )
    val_loader = DataLoader(
        val_ds, batch_size=cfg.batch_size,
        num_workers=max(1, cfg.num_workers // 2), pin_memory=cfg.pin_memory,
    )

    model = build_model(cfg.categories, samplerate=cfg.sample_rate,
                        segment_seconds=cfg.segment_seconds).to(device)
    print(f"Model:   HTDemucs params={count_params(model):,}")

    if args.warm_start and args.resume is None:
        n = warm_start_from_pretrained(model)
        print(f"Warm-start: copied {n} compatible tensors from pretrained htdemucs")

    optimizer = torch.optim.AdamW(model.parameters(), lr=cfg.lr, betas=(0.9, 0.99))

    use_fp16 = (cfg.amp_dtype == "fp16" and device.type == "cuda")
    amp_dtype = torch.float16 if cfg.amp_dtype == "fp16" else torch.bfloat16
    scaler = torch.cuda.amp.GradScaler(enabled=use_fp16)

    step = 0
    if args.resume is not None:
        ckpt = torch.load(args.resume, map_location=device)
        model.load_state_dict(ckpt["model"])
        if "optimizer" in ckpt:
            optimizer.load_state_dict(ckpt["optimizer"])
        step = int(ckpt.get("step", 0))
        print(f"Resumed: {args.resume} @ step {step}")

    train_iter = iter(train_loader)
    optimizer.zero_grad(set_to_none=True)
    accum = 0
    losses_window: list[float] = []
    t_log = time.time()

    while step < cfg.max_steps:
        try:
            mix, stems = next(train_iter)
        except StopIteration:
            train_iter = iter(train_loader)
            mix, stems = next(train_iter)

        mix = mix.to(device, non_blocking=True)
        stems = stems.to(device, non_blocking=True)

        with torch.autocast(device_type=device.type, dtype=amp_dtype,
                            enabled=device.type == "cuda"):
            est = model(mix)
            loss = F.l1_loss(est, stems) / cfg.grad_accum

        if use_fp16:
            scaler.scale(loss).backward()
        else:
            loss.backward()

        accum += 1
        losses_window.append(float(loss.detach()) * cfg.grad_accum)

        if accum >= cfg.grad_accum:
            if use_fp16:
                scaler.unscale_(optimizer)
            torch.nn.utils.clip_grad_norm_(model.parameters(), cfg.grad_clip)
            if use_fp16:
                scaler.step(optimizer)
                scaler.update()
            else:
                optimizer.step()
            optimizer.zero_grad(set_to_none=True)
            accum = 0
            step += 1

            if step % cfg.log_every == 0:
                avg = sum(losses_window) / len(losses_window)
                losses_window.clear()
                dt = time.time() - t_log
                t_log = time.time()
                rate = cfg.log_every / dt if dt > 0 else 0.0
                print(f"step {step:>7d}  loss {avg:.4f}  ({rate:.2f} step/s)")

            if step % cfg.val_every == 0:
                metrics = validate(model, val_loader, device, cfg.val_batches,
                                   list(cfg.categories))
                summary = "  ".join(f"{k}={v:+.2f}dB" for k, v in metrics.items())
                print(f"  [val step {step}] {summary}")

            if step % cfg.checkpoint_every == 0 or step == cfg.max_steps:
                ckpt_path = cfg.checkpoint_dir / f"step_{step:08d}.pt"
                payload = {
                    "model": model.state_dict(),
                    "optimizer": optimizer.state_dict(),
                    "step": step,
                    "sources": list(cfg.categories),
                    "sample_rate": cfg.sample_rate,
                    "segment_seconds": cfg.segment_seconds,
                }
                torch.save(payload, ckpt_path)
                latest = cfg.checkpoint_dir / "latest.pt"
                torch.save({k: v for k, v in payload.items() if k != "optimizer"}, latest)
                print(f"  saved {ckpt_path.name}")


if __name__ == "__main__":
    main()

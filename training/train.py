"""Train the acoustic model.

Examples:
    # Smoke-test the loop with no data (synthetic tones):
    voice-tts-train --synthetic 64 --steps 20 --batch-size 4

    # Real training from an LJSpeech-style manifest:
    voice-tts-train --manifest data/metadata.txt --data-root data/wavs
"""

from __future__ import annotations

import argparse
from dataclasses import asdict
from pathlib import Path

import torch
import torch.nn.functional as F
from torch.utils.data import DataLoader

from training.config import TrainConfig
from training.dataset import SyntheticDataset, TTSDataset, make_collate
from voice_tts.config import AudioConfig, ModelConfig
from voice_tts.models import build_model
from voice_tts.text import Tokenizer


def compute_loss(model, batch, cfg: TrainConfig, pad_id: int):
    out = model(batch.tokens, durations=batch.durations, max_mel_len=batch.mels.size(-1))

    keep = (~out.mel_mask).unsqueeze(1).float()  # (B, 1, T_mel)
    denom = keep.sum().clamp(min=1.0) * batch.mels.size(1)
    mel_l1 = ((out.mel - batch.mels).abs() + (out.mel_pre - batch.mels).abs()) * keep
    mel_loss = mel_l1.sum() / denom

    tok_mask = (~batch.tokens.eq(pad_id)).float()
    target_log = torch.log(batch.durations.clamp(min=1).float())
    dur_loss = (F.mse_loss(out.log_duration, target_log, reduction="none") * tok_mask).sum()
    dur_loss = dur_loss / tok_mask.sum().clamp(min=1.0)

    return mel_loss + cfg.duration_loss_weight * dur_loss, mel_loss, dur_loss


def build_dataset(args, audio_cfg: AudioConfig):
    if args.synthetic:
        return SyntheticDataset(audio_cfg, size=args.synthetic)
    if not args.manifest:
        raise SystemExit("Provide --manifest <file> or --synthetic <N>.")
    return TTSDataset(args.manifest, audio_cfg, data_root=args.data_root)


def main(argv: list[str] | None = None) -> None:
    parser = argparse.ArgumentParser(description="Train the voice_tts acoustic model.")
    parser.add_argument("--manifest", default=None, help="LJSpeech-style 'path|transcript' manifest.")
    parser.add_argument("--data-root", default=None, help="Root dir for relative audio paths.")
    parser.add_argument("--synthetic", type=int, default=0, help="Use N synthetic samples (smoke test).")
    parser.add_argument("--steps", type=int, default=None, help="Override max training steps.")
    parser.add_argument("--batch-size", type=int, default=None)
    parser.add_argument("--lr", type=float, default=None)
    parser.add_argument("--checkpoint-dir", default="checkpoints")
    parser.add_argument("--resume", default=None, help="Checkpoint to resume from.")
    parser.add_argument("--log-dir", default=None, help="TensorBoard log dir (optional).")
    parser.add_argument("--device", default="cuda" if torch.cuda.is_available() else "cpu")
    args = parser.parse_args(argv)

    cfg = TrainConfig()
    if args.steps is not None:
        cfg.max_steps = args.steps
    if args.batch_size is not None:
        cfg.batch_size = args.batch_size
    if args.lr is not None:
        cfg.learning_rate = args.lr
    torch.manual_seed(cfg.seed)

    audio_cfg = AudioConfig()
    model_cfg = ModelConfig()
    tokenizer = Tokenizer()

    dataset = build_dataset(args, audio_cfg)
    loader = DataLoader(
        dataset,
        batch_size=cfg.batch_size,
        shuffle=True,
        num_workers=cfg.num_workers,
        collate_fn=make_collate(tokenizer.pad_id),
        drop_last=True,
    )

    device = torch.device(args.device)
    model = build_model(tokenizer.vocab_size, tokenizer.pad_id, audio_cfg, model_cfg).to(device)
    optimizer = torch.optim.AdamW(model.parameters(), lr=cfg.learning_rate, weight_decay=cfg.weight_decay)

    step = 0
    if args.resume:
        ckpt = torch.load(args.resume, map_location=device)
        model.load_state_dict(ckpt["model"])
        if "optimizer" in ckpt:
            optimizer.load_state_dict(ckpt["optimizer"])
        step = ckpt.get("step", 0)
        print(f"Resumed from {args.resume} at step {step}")

    writer = None
    if args.log_dir:
        try:
            from torch.utils.tensorboard import SummaryWriter

            writer = SummaryWriter(args.log_dir)
        except ImportError:
            print("tensorboard not installed; install voice-tts[train] for logging.")

    ckpt_dir = Path(args.checkpoint_dir)
    ckpt_dir.mkdir(parents=True, exist_ok=True)

    def save(tag: str) -> None:
        path = ckpt_dir / f"acoustic_{tag}.pt"
        torch.save(
            {
                "model": model.state_dict(),
                "optimizer": optimizer.state_dict(),
                "step": step,
                "audio_config": asdict(audio_cfg),
                "model_config": asdict(model_cfg),
            },
            path,
        )
        print(f"Saved checkpoint to {path}")

    model.train()
    done = False
    while not done:
        for batch in loader:
            batch.tokens = batch.tokens.to(device)
            batch.durations = batch.durations.to(device)
            batch.mels = batch.mels.to(device)

            loss, mel_loss, dur_loss = compute_loss(model, batch, cfg, tokenizer.pad_id)
            optimizer.zero_grad()
            loss.backward()
            torch.nn.utils.clip_grad_norm_(model.parameters(), cfg.grad_clip)
            optimizer.step()
            step += 1

            if step % cfg.log_every == 0:
                print(
                    f"step {step:>7} | loss {loss.item():.4f} "
                    f"| mel {mel_loss.item():.4f} | dur {dur_loss.item():.4f}"
                )
                if writer is not None:
                    writer.add_scalar("loss/total", loss.item(), step)
                    writer.add_scalar("loss/mel", mel_loss.item(), step)
                    writer.add_scalar("loss/duration", dur_loss.item(), step)

            if step % cfg.checkpoint_every == 0:
                save(f"step{step}")
            if step >= cfg.max_steps:
                done = True
                break

    save("final")
    if writer is not None:
        writer.close()


if __name__ == "__main__":
    main()

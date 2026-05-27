"""End-to-end synthesis: text -> tokens -> mel -> waveform -> WAV file.

Runs out of the box with a randomly initialised model (the audio is noise until
the model is trained) so the full pipeline is verifiable from day one. Pass a
trained checkpoint with ``--checkpoint`` for real speech.
"""

from __future__ import annotations

import argparse
from pathlib import Path

import torch

from voice_tts.audio import MelInverter, save_wav
from voice_tts.config import AudioConfig, ModelConfig
from voice_tts.models import build_model
from voice_tts.text import Tokenizer


def load_synthesizer(
    checkpoint: str | Path | None = None, device: str = "cpu"
) -> tuple[torch.nn.Module, Tokenizer, AudioConfig]:
    tokenizer = Tokenizer()
    audio_cfg = AudioConfig()
    model_cfg = ModelConfig()
    state = None
    if checkpoint is not None:
        ckpt = torch.load(checkpoint, map_location=device)
        if ckpt.get("audio_config"):
            audio_cfg = AudioConfig(**ckpt["audio_config"])
        if ckpt.get("model_config"):
            model_cfg = ModelConfig(**ckpt["model_config"])
        state = ckpt["model"]
    model = build_model(tokenizer.vocab_size, tokenizer.pad_id, audio_cfg, model_cfg)
    if state is not None:
        model.load_state_dict(state)
    model.to(device).eval()
    return model, tokenizer, audio_cfg


@torch.no_grad()
def synthesize(
    text: str,
    model: torch.nn.Module,
    tokenizer: Tokenizer,
    audio_cfg: AudioConfig,
    device: str = "cpu",
) -> torch.Tensor:
    tokens = torch.tensor([tokenizer.encode(text)], dtype=torch.long, device=device)
    out = model(tokens)
    waveform = MelInverter(audio_cfg)(out.mel[0].cpu())
    return waveform


def main(argv: list[str] | None = None) -> None:
    parser = argparse.ArgumentParser(description="Synthesize speech from text.")
    parser.add_argument("text", help="Text to speak.")
    parser.add_argument("-o", "--output", default="outputs/speech.wav", help="Output WAV path.")
    parser.add_argument("-c", "--checkpoint", default=None, help="Trained model checkpoint (.pt).")
    parser.add_argument("--device", default="cpu", help="Torch device.")
    args = parser.parse_args(argv)

    model, tokenizer, audio_cfg = load_synthesizer(args.checkpoint, args.device)
    waveform = synthesize(args.text, model, tokenizer, audio_cfg, args.device)

    out_path = Path(args.output)
    out_path.parent.mkdir(parents=True, exist_ok=True)
    save_wav(out_path, waveform, audio_cfg.sample_rate)

    seconds = waveform.numel() / audio_cfg.sample_rate
    tag = "untrained" if args.checkpoint is None else "trained"
    print(f"Wrote {seconds:.2f}s of audio ({tag} model) to {out_path}")


if __name__ == "__main__":
    main()

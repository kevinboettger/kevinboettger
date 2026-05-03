"""Entry point: capture → separate → mix → playback (+ optional record), with UI."""
from __future__ import annotations

import argparse
import threading
import traceback

from .capture import LoopbackCapture
from .mixer import StemMixer
from .playback import Playback
from .recorder import StemRecorder
from .separator import StreamingSeparator
from .ui import App


def _pipeline(
    capture: LoopbackCapture,
    separator: StreamingSeparator,
    mixer: StemMixer,
    playback: Playback,
    recorder: StemRecorder,
    stop: threading.Event,
) -> None:
    while not stop.is_set():
        try:
            chunk = capture.read(timeout=0.5)
            if chunk is None:
                continue
            stems = separator.push(chunk)
            if stems is None:
                continue
            mixed = mixer.mix(stems)
            playback.write(mixed)
            if recorder.active:
                recorder.write_stems(stems, mixed)
        except Exception:
            traceback.print_exc()


def main() -> None:
    parser = argparse.ArgumentParser(description="Real-time game audio stem separator")
    parser.add_argument("--model", default="htdemucs",
                        help="Demucs model name (htdemucs, htdemucs_ft, htdemucs_6s)")
    parser.add_argument("--window", type=float, default=2.0,
                        help="Separator window size in seconds")
    parser.add_argument("--hop", type=float, default=1.0,
                        help="Separator hop size in seconds (= effective output latency)")
    parser.add_argument("--device", default=None,
                        help="Force torch device, e.g. cuda or cpu (default: auto)")
    args = parser.parse_args()

    capture = LoopbackCapture()
    print(f"Capturing: {capture.device_name} @ {capture.sample_rate} Hz, "
          f"{capture.channels} ch")

    separator = StreamingSeparator(
        input_sr=capture.sample_rate,
        input_channels=capture.channels,
        model_name=args.model,
        window_seconds=args.window,
        hop_seconds=args.hop,
        device=args.device,
    )
    print(f"Separator: model={args.model}, device={separator.device}, "
          f"window={args.window}s, hop={args.hop}s, "
          f"latency≈{args.window - args.hop:.2f}s + processing")

    mixer = StemMixer(separator.stems)
    playback = Playback(sample_rate=capture.sample_rate, channels=capture.channels)
    recorder = StemRecorder(sample_rate=capture.sample_rate, channels=capture.channels)

    stop = threading.Event()
    worker = threading.Thread(
        target=_pipeline,
        args=(capture, separator, mixer, playback, recorder, stop),
        name="stem-pipeline",
        daemon=True,
    )

    capture.start()
    playback.start()
    worker.start()

    status = (f"{capture.sample_rate//1000}kHz · {capture.channels}ch · "
              f"{args.model} · {separator.device}")
    app = App(mixer, recorder, separator.stems, status_text=status,
              on_close=stop.set)
    try:
        app.mainloop()
    finally:
        stop.set()
        worker.join(timeout=2.0)
        playback.stop()
        capture.stop()


if __name__ == "__main__":
    main()

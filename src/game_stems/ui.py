"""Tkinter UI: per-stem channel strips (meter, gain, mute, solo) + record toggle."""
from __future__ import annotations

import tkinter as tk
from tkinter import ttk
from typing import Callable

import numpy as np

from .mixer import StemMixer
from .recorder import StemRecorder
from .separator import STEM_LABELS


METER_HEIGHT = 180
METER_WIDTH = 28
DB_FLOOR = -60.0


class StemStrip(ttk.Frame):
    def __init__(self, parent: tk.Widget, stem: str, mixer: StemMixer):
        super().__init__(parent, padding=(8, 4))
        self.stem = stem
        self.mixer = mixer

        ttk.Label(self, text=STEM_LABELS.get(stem, stem.title()),
                  font=("Segoe UI", 10, "bold")).pack()

        self._meter = tk.Canvas(
            self, width=METER_WIDTH, height=METER_HEIGHT,
            bg="#1e1e1e", highlightthickness=1, highlightbackground="#333",
        )
        self._meter.pack(pady=(4, 4))
        self._bar = self._meter.create_rectangle(
            2, METER_HEIGHT, METER_WIDTH - 2, METER_HEIGHT,
            fill="#4ade80", width=0,
        )

        self._gain = tk.DoubleVar(value=1.0)
        scale = ttk.Scale(
            self, from_=2.0, to=0.0, orient="vertical",
            variable=self._gain, length=120,
            command=lambda v: mixer.set_gain(stem, float(v)),
        )
        scale.pack()

        btns = ttk.Frame(self)
        btns.pack(pady=(6, 0))
        self._mute_btn = ttk.Button(btns, text="Mute", width=6, command=self._toggle_mute)
        self._mute_btn.grid(row=0, column=0, padx=2)
        self._solo_btn = ttk.Button(btns, text="Solo", width=6, command=self._toggle_solo)
        self._solo_btn.grid(row=0, column=1, padx=2)

    def _toggle_mute(self) -> None:
        muted = self.mixer.toggle_mute(self.stem)
        self._mute_btn.configure(text="Muted" if muted else "Mute")

    def _toggle_solo(self) -> None:
        soloed = self.mixer.toggle_solo(self.stem)
        self._solo_btn.configure(text="Soloed" if soloed else "Solo")

    def update_level(self, rms: float) -> None:
        db = 20.0 * np.log10(max(rms, 10 ** (DB_FLOOR / 20.0)))
        frac = max(0.0, min(1.0, (db - DB_FLOOR) / (-DB_FLOOR)))
        h = int(METER_HEIGHT * frac)
        color = "#4ade80" if db < -6 else ("#facc15" if db < -1 else "#ef4444")
        self._meter.itemconfigure(self._bar, fill=color)
        self._meter.coords(self._bar, 2, METER_HEIGHT - h, METER_WIDTH - 2, METER_HEIGHT)


class App(tk.Tk):
    def __init__(
        self,
        mixer: StemMixer,
        recorder: StemRecorder,
        stems: list[str],
        status_text: str = "",
        on_close: Callable[[], None] | None = None,
    ):
        super().__init__()
        self.title("Game Stems — real-time separator")
        self.configure(bg="#111")
        self._mixer = mixer
        self._recorder = recorder
        self._on_close = on_close

        try:
            ttk.Style(self).theme_use("clam")
        except tk.TclError:
            pass

        header = ttk.Frame(self, padding=(12, 8))
        header.pack(fill="x")
        ttk.Label(header, text=status_text, font=("Segoe UI", 9)).pack(side="left")
        self._record_btn = ttk.Button(header, text="● Record", command=self._toggle_record)
        self._record_btn.pack(side="right")
        self._record_status = ttk.Label(header, text="", font=("Segoe UI", 9))
        self._record_status.pack(side="right", padx=8)

        strips_frame = ttk.Frame(self, padding=(12, 4, 12, 12))
        strips_frame.pack(fill="both", expand=True)
        self._strips: dict[str, StemStrip] = {}
        for i, stem in enumerate(stems):
            strip = StemStrip(strips_frame, stem, mixer)
            strip.grid(row=0, column=i, padx=6, sticky="n")
            self._strips[stem] = strip

        footer = ttk.Frame(self, padding=(12, 4, 12, 10))
        footer.pack(fill="x")
        ttk.Label(
            footer,
            text=("Note: Demucs is trained on music. Dialog (vocals) separates well; "
                  "music stems also absorb percussive/tonal SFX."),
            foreground="#888", font=("Segoe UI", 8), wraplength=560, justify="left",
        ).pack(anchor="w")

        self.protocol("WM_DELETE_WINDOW", self._handle_close)
        self.after(50, self._tick)

    def _toggle_record(self) -> None:
        if self._recorder.active:
            session = self._recorder.stop()
            self._record_btn.configure(text="● Record")
            self._record_status.configure(
                text=f"Saved → {session}" if session else "", foreground="#888",
            )
        else:
            session = self._recorder.start()
            self._record_btn.configure(text="■ Stop")
            self._record_status.configure(text=f"Recording → {session}", foreground="#ef4444")

    def _tick(self) -> None:
        for stem, rms in self._mixer.levels().items():
            strip = self._strips.get(stem)
            if strip is not None:
                strip.update_level(rms)
        self.after(50, self._tick)

    def _handle_close(self) -> None:
        if self._recorder.active:
            self._recorder.stop()
        if self._on_close is not None:
            self._on_close()
        self.destroy()

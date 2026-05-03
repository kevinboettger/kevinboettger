"""WASAPI playback to default output device, fed by a lock-protected ring buffer."""
from __future__ import annotations

import threading

import numpy as np
import pyaudiowpatch as pyaudio


class Playback:
    def __init__(
        self,
        sample_rate: int,
        channels: int,
        chunk_frames: int = 2400,
        ring_seconds: float = 4.0,
    ):
        self.sample_rate = sample_rate
        self.channels = channels
        self.chunk_frames = chunk_frames
        self._pa = pyaudio.PyAudio()
        self._stream = None

        ring_len = int(sample_rate * ring_seconds)
        self._ring = np.zeros((ring_len, channels), dtype=np.float32)
        self._read_pos = 0
        self._write_pos = 0
        self._available = 0
        self._ring_lock = threading.Lock()

    def _callback(self, in_data, frame_count, time_info, status):
        out = np.zeros((frame_count, self.channels), dtype=np.float32)
        with self._ring_lock:
            n = min(frame_count, self._available)
            if n > 0:
                rl = len(self._ring)
                end = self._read_pos + n
                if end <= rl:
                    out[:n] = self._ring[self._read_pos:end]
                else:
                    first = rl - self._read_pos
                    out[:first] = self._ring[self._read_pos:]
                    out[first:n] = self._ring[: n - first]
                self._read_pos = end % rl
                self._available -= n
        return (out.tobytes(), pyaudio.paContinue)

    def start(self) -> None:
        self._stream = self._pa.open(
            format=pyaudio.paFloat32,
            channels=self.channels,
            rate=self.sample_rate,
            output=True,
            frames_per_buffer=self.chunk_frames,
            stream_callback=self._callback,
        )
        self._stream.start_stream()

    def write(self, audio: np.ndarray) -> None:
        if audio.ndim == 1:
            audio = audio[:, None]
        if audio.shape[1] != self.channels:
            if audio.shape[1] == 1:
                audio = np.repeat(audio, self.channels, axis=1)
            else:
                audio = audio[:, : self.channels]
        audio = audio.astype(np.float32, copy=False)
        n = len(audio)
        rl = len(self._ring)
        with self._ring_lock:
            # If the buffer would overflow, drop oldest samples to keep latency bounded.
            if self._available + n > rl:
                drop = self._available + n - rl
                self._read_pos = (self._read_pos + drop) % rl
                self._available -= drop
            end = self._write_pos + n
            if end <= rl:
                self._ring[self._write_pos:end] = audio
            else:
                first = rl - self._write_pos
                self._ring[self._write_pos:] = audio[:first]
                self._ring[: n - first] = audio[first:]
            self._write_pos = end % rl
            self._available += n

    def stop(self) -> None:
        if self._stream is not None:
            try:
                self._stream.stop_stream()
                self._stream.close()
            except Exception:
                pass
            self._stream = None
        self._pa.terminate()

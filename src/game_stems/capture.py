"""WASAPI loopback capture of the default Windows playback device."""
from __future__ import annotations

import queue

import numpy as np
import pyaudiowpatch as pyaudio


class LoopbackCapture:
    """Float32 WASAPI loopback grabber. Pushes (frames, channels) chunks to a queue."""

    def __init__(self, chunk_frames: int = 4800):
        self.chunk_frames = chunk_frames
        self._pa = pyaudio.PyAudio()
        self._stream = None
        self._queue: queue.Queue[np.ndarray] = queue.Queue(maxsize=128)
        self._device_info = self._find_default_loopback()
        self.sample_rate = int(self._device_info["defaultSampleRate"])
        self.channels = int(self._device_info["maxInputChannels"])
        self.device_name = str(self._device_info["name"])

    def _find_default_loopback(self) -> dict:
        try:
            return self._pa.get_default_wasapi_loopback()
        except (AttributeError, OSError):
            pass
        default_out = self._pa.get_default_output_device_info()
        for lb in self._pa.get_loopback_device_info_generator():
            if default_out["name"] in lb["name"]:
                return lb
        raise RuntimeError(
            "No WASAPI loopback device found. Ensure a playback device is enabled."
        )

    def _callback(self, in_data, frame_count, time_info, status):
        samples = np.frombuffer(in_data, dtype=np.float32)
        samples = samples.reshape(-1, self.channels)
        try:
            self._queue.put_nowait(samples.copy())
        except queue.Full:
            # Drop oldest to keep latency bounded.
            try:
                self._queue.get_nowait()
                self._queue.put_nowait(samples.copy())
            except queue.Empty:
                pass
        return (None, pyaudio.paContinue)

    def start(self) -> None:
        self._stream = self._pa.open(
            format=pyaudio.paFloat32,
            channels=self.channels,
            rate=self.sample_rate,
            frames_per_buffer=self.chunk_frames,
            input=True,
            input_device_index=self._device_info["index"],
            stream_callback=self._callback,
        )
        self._stream.start_stream()

    def stop(self) -> None:
        if self._stream is not None:
            try:
                self._stream.stop_stream()
                self._stream.close()
            except Exception:
                pass
            self._stream = None
        self._pa.terminate()

    def read(self, timeout: float = 1.0) -> np.ndarray | None:
        try:
            return self._queue.get(timeout=timeout)
        except queue.Empty:
            return None

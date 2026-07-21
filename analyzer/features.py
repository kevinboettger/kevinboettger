"""Per-file feature extraction for multichannel game-audio assets.

Handles mono / stereo / 5.1 / 7.1 / 7.1.4 files, plus a stereo fallback for
anything unusual. Computes:

- Spatial energy share: front / back / sides / tops / LFE (as fractions of total)
- Level: RMS, peak, crest factor (dB)
- Spectral: centroid, rolloff (85 %), flatness on the downmixed signal
- Temporal: onset rate per second

Channel-order assumption (WAVE_FORMAT_EXTENSIBLE / ITU):
    6ch  (5.1):   FL FR C LFE BL BR
    8ch  (7.1):   FL FR C LFE BL BR SL SR
    12ch (7.1.4): FL FR C LFE BL BR SL SR TFL TFR TBL TBR
"""
from __future__ import annotations

import numpy as np
import soundfile as sf
from scipy.signal import stft


CHANNEL_ROLES: dict[int, list[str]] = {
    1: ["C"],
    2: ["FL", "FR"],
    6: ["FL", "FR", "C", "LFE", "BL", "BR"],
    8: ["FL", "FR", "C", "LFE", "BL", "BR", "SL", "SR"],
    12: ["FL", "FR", "C", "LFE", "BL", "BR", "SL", "SR",
         "TFL", "TFR", "TBL", "TBR"],
}


def _role_indices(n_channels: int) -> dict[str, list[int]]:
    roles = CHANNEL_ROLES.get(n_channels)
    if roles is None:
        # Fallback: treat all as generic front L/R pairs.
        roles = []
        for i in range(n_channels):
            roles.append("FL" if i % 2 == 0 else "FR")
    out: dict[str, list[int]] = {}
    for i, r in enumerate(roles):
        out.setdefault(r, []).append(i)
    return out


def _energy(x: np.ndarray) -> float:
    if x.size == 0:
        return 0.0
    return float(np.mean(x.astype(np.float64) ** 2))


def extract_features(path: str) -> dict:
    data, sr = sf.read(path, dtype="float32", always_2d=True)
    n_frames, n_chan = data.shape
    if n_frames == 0:
        return {"path": path, "error": "empty"}

    roles = _role_indices(n_chan)
    total_e = _energy(data) + 1e-12

    def group_energy(*names: str) -> float:
        idxs: list[int] = []
        for n in names:
            idxs.extend(roles.get(n, []))
        return _energy(data[:, idxs]) if idxs else 0.0

    e_front = group_energy("FL", "FR", "C")
    e_back = group_energy("BL", "BR")
    e_sides = group_energy("SL", "SR")
    e_tops = group_energy("TFL", "TFR", "TBL", "TBR")
    e_lfe = group_energy("LFE")

    mono = data.mean(axis=1)
    rms = float(np.sqrt(np.mean(mono ** 2) + 1e-12))
    peak = float(np.max(np.abs(mono)) + 1e-12)
    crest_db = 20.0 * float(np.log10(peak / rms + 1e-12))

    centroid = rolloff = flatness = onset_rate = 0.0
    nfft = min(2048, len(mono))
    if nfft >= 256:
        f_axis, _, Z = stft(mono, fs=sr, nperseg=nfft, noverlap=nfft // 2)
        mag = np.abs(Z)
        power = mag.mean(axis=1) + 1e-12
        total_power = float(power.sum())
        centroid = float((f_axis * power).sum() / total_power)
        cum = np.cumsum(power)
        r_idx = int(np.searchsorted(cum, 0.85 * cum[-1]))
        rolloff = float(f_axis[min(r_idx, len(f_axis) - 1)])
        flatness = float(np.exp(np.mean(np.log(power))) / np.mean(power))
        env = mag.sum(axis=0)
        env_norm = env / (env.max() + 1e-12)
        diff = np.diff(env_norm)
        duration_s = max(len(mono) / sr, 1e-3)
        onset_rate = float(np.sum(diff > 0.3) / duration_s)

    return {
        "path": path,
        "sample_rate": sr,
        "channels": n_chan,
        "duration_s": round(n_frames / sr, 4),
        "spatial": {
            "front": round(e_front / total_e, 5),
            "back":  round(e_back  / total_e, 5),
            "sides": round(e_sides / total_e, 5),
            "tops":  round(e_tops  / total_e, 5),
            "lfe":   round(e_lfe   / total_e, 5),
        },
        "level": {
            "rms": round(rms, 6),
            "peak": round(peak, 6),
            "crest_db": round(crest_db, 3),
        },
        "spectral": {
            "centroid_hz": round(centroid, 2),
            "rolloff_hz": round(rolloff, 2),
            "flatness": round(flatness, 5),
        },
        "temporal": {
            "onset_rate_per_sec": round(onset_rate, 3),
        },
    }

"""Where to obtain the raw datasets. Run this script to print instructions.

We don't download automatically because most of these require manual license
acceptance or are too large/fragile to wget. Place the extracted contents under
training/data/raw/<category>/<source-name>/ and then run manifest.py.
"""
from __future__ import annotations

SOURCES: dict[str, list[tuple[str, str, str]]] = {
    "dialog": [
        (
            "LibriTTS-R clean-100",
            "https://www.openslr.org/resources/141/train_clean_100.tar.gz",
            "Clean studio English speech, ~6 GB. "
            "Extract to training/data/raw/dialog/libritts/.",
        ),
        (
            "VCTK Corpus (0.92)",
            "https://datashare.ed.ac.uk/handle/10283/3443",
            "Multi-speaker English, ~10 GB. "
            "Extract to training/data/raw/dialog/vctk/.",
        ),
    ],
    "music": [
        (
            "MUSDB18-HQ",
            "https://zenodo.org/records/3338373",
            "Music with isolated stems (we use only mixture.wav per track), ~30 GB. "
            "Extract to training/data/raw/music/musdb18hq/. "
            "Optional: also drop in royalty-free game OSTs you have rights to.",
        ),
    ],
    "sfx": [
        (
            "Sonniss GDC bundles (yearly, free with email)",
            "https://sonniss.com/gameaudiogdc",
            "Royalty-free game-audio bundles, ~30 GB per year. "
            "Extract to training/data/raw/sfx/sonniss/.",
        ),
        (
            "BBC Sound Effects (research download)",
            "https://sound-effects.bbcrewind.co.uk/",
            "16 k+ effects, personal/research use. "
            "Place under training/data/raw/sfx/bbc/.",
        ),
        (
            "Freesound.org (community uploads)",
            "https://freesound.org/",
            "Filter by CC0 / Attribution licenses. "
            "Place under training/data/raw/sfx/freesound/.",
        ),
    ],
}


def print_instructions() -> None:
    print("Place datasets under training/data/raw/<category>/<source>/ then run:")
    print("    python -m training.data.manifest\n")
    for cat, items in SOURCES.items():
        print(f"=== {cat.upper()} ===")
        for name, url, note in items:
            print(f"  - {name}")
            print(f"      url:   {url}")
            print(f"      note:  {note}")
        print()


if __name__ == "__main__":
    print_instructions()

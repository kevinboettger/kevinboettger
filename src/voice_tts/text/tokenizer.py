"""Character-level text frontend.

A from-scratch foundation deliberately avoids an external grapheme-to-phoneme
dependency: text is normalised and mapped to character ids. A phoneme frontend
can later be swapped in behind the same ``encode``/``decode`` interface.
"""

from __future__ import annotations

import re
import unicodedata

PAD = "<pad>"
BOS = "<bos>"
EOS = "<eos>"

_SPECIAL = [PAD, BOS, EOS]
_PUNCTUATION = " !'(),-.:;?"
_LETTERS = "abcdefghijklmnopqrstuvwxyz"
_SYMBOLS = _SPECIAL + list(_LETTERS) + list(_PUNCTUATION)

_WHITESPACE_RE = re.compile(r"\s+")
_ALLOWED = set(_LETTERS + _PUNCTUATION)


class Tokenizer:
    """Maps text to/from integer ids over a fixed character vocabulary."""

    def __init__(self) -> None:
        self._sym_to_id = {s: i for i, s in enumerate(_SYMBOLS)}
        self._id_to_sym = {i: s for s, i in self._sym_to_id.items()}

    @property
    def vocab_size(self) -> int:
        return len(self._sym_to_id)

    @property
    def pad_id(self) -> int:
        return self._sym_to_id[PAD]

    @property
    def bos_id(self) -> int:
        return self._sym_to_id[BOS]

    @property
    def eos_id(self) -> int:
        return self._sym_to_id[EOS]

    def normalize(self, text: str) -> str:
        text = unicodedata.normalize("NFKD", text)
        text = text.encode("ascii", "ignore").decode("ascii")
        text = text.lower()
        text = _WHITESPACE_RE.sub(" ", text).strip()
        return "".join(c for c in text if c in _ALLOWED)

    def encode(self, text: str, add_bos_eos: bool = True) -> list[int]:
        ids = [self._sym_to_id[c] for c in self.normalize(text)]
        if add_bos_eos:
            ids = [self.bos_id, *ids, self.eos_id]
        return ids

    def decode(self, ids: list[int]) -> str:
        return "".join(
            self._id_to_sym[i]
            for i in ids
            if self._id_to_sym.get(i) not in (None, *_SPECIAL)
        )

"""Train a genre classifier over per-game feature vectors.

With small N (a handful of games) we use leave-one-out CV; larger sets
fall back to stratified k-fold. Gradient boosting on standardized features
is the interpretable baseline; feature importances give you a direct 'what
makes an FPS sound like an FPS' answer.
"""
from __future__ import annotations

from typing import Any

import numpy as np
from sklearn.ensemble import GradientBoostingClassifier
from sklearn.metrics import classification_report, confusion_matrix
from sklearn.model_selection import LeaveOneOut, StratifiedKFold, cross_val_predict
from sklearn.pipeline import Pipeline
from sklearn.preprocessing import StandardScaler

from .aggregate import feature_vector


def _build_dataset(per_game: dict[str, dict], labels: dict[str, str]):
    X, y, names = [], [], []
    feat_names: list[str] = []
    for game, agg in per_game.items():
        label = labels.get(game)
        if not label or label == "unknown":
            continue
        fn, vec = feature_vector(agg)
        if not feat_names:
            feat_names = fn
        X.append(vec)
        y.append(label)
        names.append(game)
    return np.asarray(X), np.asarray(y), names, feat_names


def train(per_game: dict[str, dict], labels: dict[str, str]) -> dict[str, Any]:
    X, y, names, feat_names = _build_dataset(per_game, labels)
    if len(X) < 3:
        return {
            "error": (f"only {len(X)} labeled games; need at least 3 across "
                      f"2+ genres to train"),
            "labeled_games": names,
        }

    pipe = Pipeline([
        ("scale", StandardScaler()),
        ("clf", GradientBoostingClassifier(
            n_estimators=200, max_depth=3, learning_rate=0.05, random_state=42,
        )),
    ])

    classes, counts = np.unique(y, return_counts=True)
    if counts.min() >= 2 and len(classes) >= 2:
        cv = StratifiedKFold(n_splits=min(5, int(counts.min())), shuffle=True, random_state=42)
    else:
        cv = LeaveOneOut()

    try:
        y_pred = cross_val_predict(pipe, X, y, cv=cv, n_jobs=1)
    except ValueError as e:
        return {"error": f"CV failed: {e}", "labeled_games": names}

    pipe.fit(X, y)

    importances = pipe.named_steps["clf"].feature_importances_
    top = sorted(zip(feat_names, importances.tolist()), key=lambda kv: -kv[1])[:15]

    cm_classes = sorted(set(y.tolist()))
    cm = confusion_matrix(y, y_pred, labels=cm_classes).tolist()

    return {
        "n_games": int(len(X)),
        "n_features": int(X.shape[1]),
        "class_order": cm_classes,
        "confusion_matrix": cm,
        "report": classification_report(y, y_pred, zero_division=0),
        "top_features": top,
        "predictions_cv": [
            {"game": g, "true": t, "pred": p}
            for g, t, p in zip(names, y.tolist(), y_pred.tolist())
        ],
    }

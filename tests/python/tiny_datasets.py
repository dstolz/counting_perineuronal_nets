"""Tiny synthetic datasets in the exact on-disk formats the two trainers read.

Used by the Python regression tests of the trainer fixes (tests/python/test_trainer_fixes.py),
so they need no MATLAB and no real data. Images are float32 HDF5 '/data' of shape (H, W) on the
0-255 scale of the model input; cells are Gaussian blobs.

  make_rank_dataset(root, ...)       Stage 2: <root>/annotations.csv (imgName, X, Y, AV..VT)
                                     + <root>/fullFramesH5/<stem>.h5
  make_detection_dataset(root, ...)  Stage 1: <root>/train/annotations.csv (index imgName = <stem>.tif,
                                     Y, X, class) + <root>/train/fullFramesH5/<stem>.h5
"""
from pathlib import Path

import h5py
import numpy as np
import pandas as pd

RATERS = ['AV', 'R2', 'R3', 'R4', 'R5', 'R6', 'VT']


def _blob_image(rng, h, w, yx, sigma=6.0, amp=200.0):
    img = rng.normal(10.0, 2.0, size=(h, w)).astype(np.float32)
    yy, xx = np.mgrid[0:h, 0:w]
    for y, x in yx:
        img += (amp * np.exp(-((yy - y) ** 2 + (xx - x) ** 2) / (2 * sigma ** 2))).astype(np.float32)
    return np.clip(img, 0, 255).astype(np.float32)


def _write_h5(path, img):
    path.parent.mkdir(parents=True, exist_ok=True)
    with h5py.File(path, 'w') as f:
        f.create_dataset('data', data=img, chunks=True, compression='gzip')


def make_rank_dataset(root, n_images=2, size=(256, 256), n_per_image=24, seed=0, prefix='img'):
    """Stage-2 dataset: rows with agreement 7 (blob), 4 (dim blob) and 0 (background)."""
    root = Path(root)
    rng = np.random.default_rng(seed)
    h, w = size
    rows = []
    for k in range(n_images):
        stem = f'{prefix}{k}'
        yx = rng.integers(40, min(h, w) - 40, size=(n_per_image, 2))
        img = _blob_image(rng, h, w, yx)
        _write_h5(root / 'fullFramesH5' / f'{stem}.h5', img)
        for i, (y, x) in enumerate(yx):
            level = (7, 4, 0)[i % 3]
            r = {'imgName': f'{stem}.tif', 'X': int(x), 'Y': int(y)}
            for j, c in enumerate(RATERS):
                r[c] = int(j < level)
            rows.append(r)
    pd.DataFrame(rows).to_csv(root / 'annotations.csv', index=False)
    return root


def make_detection_dataset(root, n_images=2, size=(640, 640), n_cells=12, seed=0, prefix='img'):
    """Stage-1 dataset with positives in both halves of every image (train-half1/half2 splits)."""
    root = Path(root)
    rng = np.random.default_rng(seed)
    h, w = size
    rows = []
    for k in range(n_images):
        stem = f'{prefix}{k}'
        left = np.column_stack([rng.integers(40, h - 40, n_cells // 2), rng.integers(40, w // 2 - 40, n_cells // 2)])
        right = np.column_stack([rng.integers(40, h - 40, n_cells // 2), rng.integers(w // 2 + 40, w - 40, n_cells // 2)])
        yx = np.vstack([left, right]).astype(float)
        img = _blob_image(rng, h, w, yx, sigma=8.0)
        _write_h5(root / 'train' / 'fullFramesH5' / f'{stem}.h5', img)
        for y, x in yx:
            rows.append({'imgName': f'{stem}.tif', 'Y': y, 'X': x, 'class': 0})
    pd.DataFrame(rows).to_csv(root / 'train' / 'annotations.csv', index=False)
    return root

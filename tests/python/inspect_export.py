"""Instantiate the trainers' own dataset classes on a curated export (curation.Export) and report
what they see, as JSON, for the MATLAB tests tExportStage2 / tExportStage1.

    python tests/python/inspect_export.py stage2 <split root> <out.json>
        datasets.PerineuronalNetsRankDataset(root, split='all', mode='patches', patch_size=64,
        neg_fraction=0, random_offset=0, transforms=None): its length, images, agreement levels and,
        per item (in the dataset's own order): imgName, X, Y, agreement, patch shape and the offset
        of the patch's smoothed maximum from the patch centre (a blob or a ring centred on the
        cell gives ~(0, 0); a transposed or shifted image does not).

    python tests/python/inspect_export.py stage1 <export root> <out.json> [rects.csv]
        datasets.PerineuronalNetsDataset(root, split=train-half1 / train-half2, patch_size=640,
        target='detection', side 60, random_offset=0): per split its length (patches), images and
        annotations, every box centre in image coordinates (unclipped boxes only; patch start and
        split origin added back), the image shapes; with rects.csv (imgName, y0, y1, x0, x1;
        0-based, end exclusive) the max of /data in each rectangle.
"""
import json
import sys
from pathlib import Path

import numpy as np
import pandas as pd
from scipy.ndimage import gaussian_filter

REPO = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(REPO))

from datasets.PerineuronalNetsDataset import PerineuronalNetsDataset  # noqa: E402
from datasets.PerineuronalNetsRankDataset import PerineuronalNetsRankDataset  # noqa: E402


def stage2(root):
    ds = PerineuronalNetsRankDataset(root=root, split='all', mode='patches', patch_size=64, neg_fraction=0,
                                     random_offset=0, transforms=None)
    items = []
    for i in range(len(ds)):
        patch, agreement = ds[i]
        a = ds.annot.iloc[i]
        p = np.asarray(patch, dtype=np.float64)[:, :, 0]
        if p.size == 0:  # the point lies outside the image (e.g. a transposed export): no patch
            dy = dx = 9999
            cm = pm = 0.0
        else:
            s = gaussian_filter(p, 6)
            my, mx = np.unravel_index(np.argmax(s), s.shape)
            dy, dx = int(my) - p.shape[0] // 2, int(mx) - p.shape[1] // 2
            cm, pm = float(p[28:37, 28:37].mean()), float(p.mean())
        items.append({'imgName': str(a.imgName), 'X': int(a.X), 'Y': int(a.Y), 'agreement': int(agreement),
                      'h': int(p.shape[0]), 'w': int(p.shape[1]), 'dtype': str(np.asarray(patch).dtype),
                      'dy': dy, 'dx': dx, 'centreMean': cm, 'patchMean': pm})
    levels = ds.annot['agreement'].value_counts().to_dict()
    return {'len': len(ds), 'numImages': ds.patches.num_images(), 'str': str(ds),
            'xyDtype': str(ds.annot['X'].dtype), 'levels': {str(k): int(v) for k, v in levels.items()},
            'items': items}


def stage1(root, rects=None):
    out = {}
    for split in ('train-half1', 'train-half2'):
        ds = PerineuronalNetsDataset(root=root, split=split, patch_size=640, overlap=0, random_offset=0,
                                     target='detection', target_params={'side': 60}, transforms=None)
        centres = []
        for d in ds.datasets:
            oy, ox = (int(v) for v in d.origin_yx)
            for j in range(len(d)):
                datum, patch_hw, local_start, region_hw, image_id = d[j]
                patch, bbs, labels = datum
                ph, pw = (int(v) for v in patch_hw)
                sy, sx = int(local_start[0]) + oy, int(local_start[1]) + ox
                for (y0, x0, y1, x1) in np.asarray(bbs).reshape(-1, 4):
                    if y0 <= 0 or x0 <= 0 or y1 >= ph or x1 >= pw:
                        continue  # clipped at the patch border: its centre moved
                    centres.append({'imgName': image_id, 'Y': float((y0 + y1) / 2 + sy),
                                    'X': float((x0 + x1) / 2 + sx), 'side': float(y1 - y0)})
        out[split] = {'len': len(ds), 'numImages': ds.num_images(), 'numAnnotations': int(len(ds.annot)),
                      'str': str(ds), 'centres': centres,
                      'halves': [{'imgName': d.image_id, 'split': d.split} for d in ds.datasets]}
    ds = PerineuronalNetsDataset(root=root, split='train-half1', patch_size=640, target='detection',
                                 target_params={'side': 60}, transforms=None)
    out['shapes'] = {d.image_id: list(d.data.shape) for d in ds.datasets}
    out['dtype'] = {d.image_id: str(d.data.dtype) for d in ds.datasets}
    if rects:
        R = pd.read_csv(rects)
        data = {d.image_id: d.data for d in ds.datasets}
        out['rects'] = [float(np.max(data[r.imgName][int(r.y0):int(r.y1), int(r.x0):int(r.x1)])) for r in R.itertuples()]
    return out


if __name__ == '__main__':
    what, root, dst = sys.argv[1], sys.argv[2], sys.argv[3]
    res = stage2(root) if what == 'stage2' else stage1(root, sys.argv[4] if len(sys.argv) > 4 else None)
    Path(dst).write_text(json.dumps(res))
    print('INSPECT_OK', what, root)

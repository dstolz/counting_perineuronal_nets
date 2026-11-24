"""One Stage-1 training step with train.py's own configuration and command-line overrides.

    python tests/python/stage1_one_step.py <out.json> <override> <override> ...

The overrides are those of curation.Trainer.stage1Command (hydra.* overrides are dropped: no run
folder is made). This composes conf/config.yaml exactly as train.py's @hydra.main does, then does
what train.py does up to its first optimizer step: instantiates the training and validation datasets
(datasets.PerineuronalNetsDataset on the export), builds the FasterRCNN, loads model.pretrained
(weights_only=False, as train.py), runs ONE training step on the first training patch
(build_coco_compliant_batch + model(images, targets) + backward + optimizer step) and the model in
eval mode on the first validation patch. It does not run a full epoch, validate() or the metrics.
Writes a JSON summary to <out.json> and prints STAGE1_ONE_STEP_OK.
"""
import json
import os
import sys
from pathlib import Path

REPO = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(REPO))
os.chdir(REPO)

import hydra  # noqa: E402
import torch  # noqa: E402
from torch.utils.data import DataLoader  # noqa: E402

try:
    from hydra import compose, initialize_config_dir
except ImportError:  # Hydra 1.0
    from hydra.experimental import compose, initialize_config_dir

from methods.detection.utils import build_coco_compliant_batch, collate_fn  # noqa: E402

out_json = sys.argv[1]
overrides = [a for a in sys.argv[2:] if not a.startswith('hydra.')]
# ${hydra:runtime.cwd} only resolves inside a Hydra run: give the cache folders explicitly
zoo = str(REPO / 'model_zoo').replace('\\', '/')
overrides += [f'cache_folder={zoo}', f'model.cache_folder={zoo}']

with initialize_config_dir(config_dir=str(REPO / 'conf')):
    cfg = compose(config_name='config', overrides=overrides)

torch.manual_seed(0)
train_ds = hydra.utils.instantiate(cfg.data.train)
valid_ds = hydra.utils.instantiate(cfg.data.validation)
model = hydra.utils.instantiate(cfg.model.module, skip_weights_loading=True)
ckpt = torch.load(cfg.model.pretrained, map_location='cpu', weights_only=False)
model.load_state_dict(ckpt['model'])
optimizer = hydra.utils.instantiate(cfg.optim.optimizer, model.parameters())

loader = DataLoader(train_ds, batch_size=1, shuffle=False, num_workers=0, collate_fn=collate_fn)
sample = next(iter(loader))
images, targets = build_coco_compliant_batch(sample[0], mask=cfg.data.train.target_params.mask)
model.train()
loss_dict = model(images, targets)
loss = sum(v for v in loss_dict.values())
optimizer.zero_grad()
loss.backward()
optimizer.step()

model.eval()
vdatum = valid_ds[0][0]
with torch.no_grad():
    pred = model([vdatum[0]])[0]

res = {
    'train': str(train_ds), 'validation': str(valid_ds),
    'trainPatches': len(train_ds), 'validationPatches': len(valid_ds),
    'trainImages': train_ds.num_images(), 'validationImages': valid_ds.num_images(),
    'trainAnnotations': int(len(train_ds.annot)), 'validationAnnotations': int(len(valid_ds.annot)),
    'boxesInFirstPatch': int(targets[0]['boxes'].shape[0]),
    'loss': float(loss.item()), 'losses': {k: float(v.item()) for k, v in loss_dict.items()},
    'validationDetections': int(pred['boxes'].shape[0]),
    'pretrained': str(cfg.model.pretrained), 'epochs': int(cfg.optim.epochs), 'lr': float(cfg.optim.optimizer.lr),
}
Path(out_json).write_text(json.dumps(res))
print('STAGE1_ONE_STEP_OK', json.dumps(res))

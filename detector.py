from pathlib import Path

import hydra
from omegaconf import OmegaConf
import torch
from torch.utils.data import DataLoader
from tqdm import tqdm

from datasets.patched_datasets import PatchedMultiImageDataset, RandomAccessMultiImageDataset


class CellDetector:
    """
    Loads a detection model (and optionally a rescoring model) once and runs
    inference on individual images without reloading weights between calls.

    Parameters
    ----------
    run_path : str or Path
        Folder containing `.hydra/config.yaml` and `best.pth` for the
        detection model (e.g. ``"pnn_v2_fasterrcnn_640"``).
    device : str
        PyTorch device string, e.g. ``"cuda:0"`` or ``"cpu"``.
    threshold : float or None
        Detection threshold. If None, the value stored in the checkpoint is used.
    rescorer_path : str or Path or None
        Folder of the rescoring model. If None, rescoring is skipped and the
        returned DataFrame will not have a ``rescore`` column.
    """

    def __init__(self, run_path, device='cpu', threshold=None, rescorer_path=None):
        self.run_path = Path(run_path)
        self.device = torch.device(device)
        self.rescorer_path = Path(rescorer_path) if rescorer_path else None

        self._det_cfg, self._det_model, self.threshold = self._load_detection_model(threshold)

        if self.rescorer_path is not None:
            self._res_cfg, self._res_model = self._load_rescoring_model()
        else:
            self._res_cfg = None
            self._res_model = None

    # ------------------------------------------------------------------
    # Public API
    # ------------------------------------------------------------------

    def predict(self, image_path, batch_size=1):
        """
        Run detection (and optional rescoring) on a single image.

        Parameters
        ----------
        image_path : str or Path
        batch_size : int

        Returns
        -------
        pandas.DataFrame
            Columns: ``imgName``, ``Y``, ``X`` — plus ``rescore`` if a
            rescoring model was loaded.
        """
        image_path = Path(image_path)

        dataset_params = dict(
            patch_size=self._det_cfg.data.validation.get('patch_size', None),
            transforms=hydra.utils.instantiate(self._det_cfg.data.validation.transforms),
        )
        dataset = PatchedMultiImageDataset.from_paths([str(image_path)], **dataset_params)
        print(f'[  DATA] {dataset}')
        loader = DataLoader(dataset, batch_size=batch_size, shuffle=False, num_workers=0)

        predict_points = hydra.utils.get_method(
            f'methods.{self._det_cfg.method}.train_fn.predict_points'
        )
        localizations = predict_points(loader, self._det_model, self.device, self.threshold, self._det_cfg)
        localizations = localizations.sort_values(['imgName', 'Y', 'X'])

        if self._res_model is not None:
            localizations = self._rescore(localizations, image_path, batch_size)

        return localizations

    # ------------------------------------------------------------------
    # Private helpers
    # ------------------------------------------------------------------

    def _load_detection_model(self, threshold):
        cfg = self._load_cfg(self.run_path)

        model = hydra.utils.instantiate(cfg.model.module, skip_weights_loading=True)
        model = model.to(self.device)

        ckpt_path = self._find_ckpt(self.run_path, 'count/game-3/macro')
        checkpoint = torch.load(ckpt_path, map_location=self.device, weights_only=False)
        model.load_state_dict(checkpoint['model'])
        model.eval()

        if threshold is None:
            threshold = checkpoint['metrics']['count/game-3/macro']['threshold']

        model_param_string = ', '.join(
            f'{k}={v}' for k, v in cfg.model.module.items() if not k.startswith('_')
        )
        print(f'[ MODEL] {cfg.method} - {cfg.model.name}({model_param_string})')
        print(f'[DEVICE] {self.device}')
        print(f'[  CKPT] {ckpt_path}')
        print(f'[PARAMS] thr = {threshold:.2f}')

        return cfg, model, threshold

    def _load_rescoring_model(self):
        cfg = self._load_cfg(self.rescorer_path)

        model_params = cfg.model.get('wrapper', cfg.model.base)
        model = hydra.utils.instantiate(model_params)
        model = model.to(self.device)

        ckpt_path = self._find_ckpt(self.rescorer_path, 'rank/spearman', fallback_last=True)
        checkpoint = torch.load(ckpt_path, map_location=self.device, weights_only=False)
        model.load_state_dict(checkpoint['model'])
        model.eval()

        model_param_string = ', '.join(
            f'{k}={v}' for k, v in model_params.items() if not k.startswith('_')
        )
        print(f'[RESCORE] {cfg.model.name}({model_param_string})')
        print(f'[  CKPT] {ckpt_path}')

        return cfg, model

    @torch.no_grad()
    def _rescore(self, localizations, image_path, batch_size):
        dataset_params = dict(
            patch_size=self._res_cfg.data.validation.get('patch_size', None),
            transforms=hydra.utils.instantiate(self._res_cfg.data.validation.transforms),
        )

        paths_and_locs = (
            (img_name, data[['Y', 'X']].values.astype(int))
            for img_name, data in localizations.groupby('imgName')
        )
        paths, locs = zip(*paths_and_locs)
        paths = [Path(image_path).parent / p for p in paths]

        dataset = RandomAccessMultiImageDataset.from_paths_and_locs(paths, locs, **dataset_params)
        print(f'[  DATA] {dataset}')
        loader = DataLoader(dataset, batch_size=batch_size, shuffle=False, num_workers=0)

        compute_loss_and_scores = hydra.utils.get_method(
            f'methods.rank.methods.{self._res_cfg.optim.method}'
        )

        all_scores = []
        for sample in tqdm(loader, desc='RESCORE', leave=False, dynamic_ncols=True):
            dummy_targets = torch.zeros(sample.shape[0], dtype=torch.int64, device=self.device)
            _, scores = compute_loss_and_scores(
                (sample, dummy_targets), self._res_model, self.device, self._res_cfg
            )
            all_scores.append(scores.flatten().cpu())

        localizations = localizations.copy()
        localizations['rescore'] = torch.cat(all_scores).numpy()
        return localizations

    @staticmethod
    def _load_cfg(run_path):
        cfg = OmegaConf.load(run_path / '.hydra' / 'config.yaml')
        cfg['cache_folder'] = './model_zoo'
        return cfg

    @staticmethod
    def _find_ckpt(run_path, metric_name, fallback_last=False):
        ckpt = run_path / 'best.pth'
        if ckpt.exists():
            return ckpt
        ckpt = run_path / 'best_models' / f"best_model_metric_{metric_name.replace('/', '-')}.pth"
        if ckpt.exists():
            return ckpt
        if fallback_last:
            ckpt = run_path / 'last.pth'
            if ckpt.exists():
                return ckpt
        raise FileNotFoundError(f"No checkpoint found in {run_path}")

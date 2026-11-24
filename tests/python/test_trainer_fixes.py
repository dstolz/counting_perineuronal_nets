"""Regression tests of the fixes that make train_score.py, train.py and utils.CheckpointManager run
on Windows with current packages (pandas 2.x, torch >= 2.6). No MATLAB, no real data: tiny
synthetic datasets in the trainers' own formats (tiny_datasets.py).

Run from the repository root with the countpnn interpreter (unittest is in the standard library):

    python -m unittest discover -s tests/python -p "test_*.py" -v

The Stage-1 test runs one FasterRCNN epoch on the CPU (about a minute); everything else takes
seconds.
"""
import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock

import pandas as pd
import torch

REPO = Path(__file__).resolve().parents[2]
HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(REPO))
sys.path.insert(0, str(HERE))

from tiny_datasets import make_detection_dataset, make_rank_dataset  # noqa: E402

PY = sys.executable
SHIPPED_SCORER = REPO / 'pnn_v2_scoring_ordinal_regression' / 'best.pth'
SHIPPED_DETECTOR = REPO / 'pnn_v2_fasterrcnn_640' / 'best.pth'


def fwd(p):
    """Hydra override values: forward slashes (a backslash is an escape in Hydra's grammar)."""
    return str(p).replace('\\', '/')


def run(args, timeout=900):
    return subprocess.run([PY] + [str(a) for a in args], cwd=REPO, capture_output=True, text=True,
                          timeout=timeout, stdin=subprocess.DEVNULL)


def tail(r, n=4000):
    return f'\n--- exit {r.returncode}\n--- stdout\n{r.stdout[-n:]}\n--- stderr\n{r.stderr[-n:]}'


class TempDirCase(unittest.TestCase):
    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp(prefix='trainfix_'))

    def tearDown(self):
        shutil.rmtree(self.tmp, ignore_errors=True)


class TestTrainScore(TempDirCase):
    """train_score.py (Stage 2)."""

    def score_cmd(self, extra, run_dir=None):
        if not (self.tmp / 'train').exists():
            make_rank_dataset(self.tmp / 'train', n_images=2, seed=1, prefix='tr')
            make_rank_dataset(self.tmp / 'val', n_images=1, seed=2, prefix='va')
        run_dir = run_dir or self.tmp / 'run'
        return ['train_score.py', 'data=perineuronal_nets', 'method=ordinal_regression',
                f'data.train.root={fwd(self.tmp / "train")}', f'data.validation.root={fwd(self.tmp / "val")}',
                'data.train.split=all', 'data.validation.split=all',
                'data.train.neg_fraction=0', 'data.validation.neg_fraction=0',
                'optim.num_workers=0', 'optim.batch_size=8', 'gpu=null',
                f'hydra.run.dir={fwd(run_dir)}'] + list(extra)

    def test_two_epochs_run_to_completion(self):
        # pandas 2.x removed DataFrame.append: the loop used to die right after epoch 0
        r = run(self.score_cmd(['optim.epochs=2']))
        self.assertEqual(r.returncode, 0, tail(r))
        run_dir = self.tmp / 'run'
        log = pd.read_csv(run_dir / 'train_log.csv', index_col=0, header=[0, 1])
        self.assertEqual(list(log.index), [0, 1])
        vlog = pd.read_csv(run_dir / 'valid_log.csv', index_col=0, header=[0, 1])
        self.assertEqual(list(vlog.index), [0, 1])
        best = run_dir / 'best_models' / 'best_model_metric_rank-spearman.pth'
        self.assertTrue(best.exists(), sorted(p.name for p in (run_dir / 'best_models').iterdir()))
        ck = torch.load(best, map_location='cpu', weights_only=False)
        self.assertIn('link.cutpoints', ck['model'])

    def test_resume_from_last_checkpoint(self):
        # last.pth holds the MultiStepLR state; the default torch.load (weights_only=True) refuses it
        r = run(self.score_cmd(['optim.epochs=1']))
        self.assertEqual(r.returncode, 0, tail(r))
        r = run(self.score_cmd(['optim.epochs=2', 'optim.resume=true']))
        self.assertEqual(r.returncode, 0, tail(r))
        log = pd.read_csv(self.tmp / 'run' / 'train_log.csv', index_col=0, header=[0, 1])
        self.assertEqual(list(log.index), [0, 1], 'epoch 0 from the first run, epoch 1 resumed')

    def test_pretrained_loads_a_shipped_scorer(self):
        # model.pretrained=<best.pth>: the run starts from the shipped weights (lr 0 keeps them)
        r = run(self.score_cmd(['optim.epochs=1', 'optim.optimizer.lr=0', f'model.pretrained={fwd(SHIPPED_SCORER)}']))
        self.assertEqual(r.returncode, 0, tail(r))
        self.assertIn('[PRETRAINED]', r.stdout + r.stderr)
        got = torch.load(self.tmp / 'run' / 'last.pth', map_location='cpu', weights_only=False)['model']
        want = torch.load(SHIPPED_SCORER, map_location='cpu', weights_only=False)['model']
        self.assertEqual(sorted(got), sorted(want))
        for k in want:
            self.assertTrue(torch.equal(got[k], want[k]), k)

    def test_nonfinite_scores_do_not_hang(self):
        # add_histogram raises ValueError on non-finite scores; breakpoint() then waited on stdin.
        # stdin is a pipe that stays open and silent, as under MATLAB's ProcessBuilder
        # (communicate() would close it, and pdb would then quit on EOF instead of waiting).
        out_file = self.tmp / 'out.txt'
        with open(out_file, 'w') as fh:
            p = subprocess.Popen([PY, str(HERE / 'run_validate_nonfinite.py'), str(self.tmp / 'tb')], cwd=REPO,
                                 stdin=subprocess.PIPE, stdout=fh, stderr=subprocess.STDOUT)
            try:
                p.wait(timeout=90)
            except subprocess.TimeoutExpired:
                p.kill()
                p.wait()
                p.stdin.close()
                self.fail('validate() hung (waiting for a debugger on stdin):\n' + out_file.read_text()[-3000:])
            p.stdin.close()
        out = out_file.read_text()
        self.assertEqual(p.returncode, 0, out[-3000:])
        self.assertIn('VALIDATE_RETURNED', out)


class TestCheckpointManager(TempDirCase):
    """utils.CheckpointManager: best-checkpoint links."""

    def save_two_epochs(self):
        from utils import CheckpointManager
        cm = CheckpointManager(self.tmp, metric_modes=lambda m: 'min')
        cm.save({'epoch': 0}, {'loss': {'value': 2.0, 'threshold': None}}, 0)
        cm.save({'epoch': 1}, {'loss': {'value': 1.0, 'threshold': None}}, 1)
        return self.tmp / 'best_model_metric_loss.pth'

    def test_best_checkpoint_follows_the_best_epoch(self):
        best = self.save_two_epochs()
        self.assertEqual(torch.load(best, weights_only=False)['epoch'], 1)
        self.assertFalse((self.tmp / 'ckpt_e0.pth').exists(), 'the superseded checkpoint is removed')

    def test_falls_back_to_a_copy_when_symlinks_are_refused(self):
        # Windows without Developer Mode refuses symlinks (WinError 1314); simulate that refusal
        err = OSError(22, 'A required privilege is not held by the client')
        err.winerror = 1314
        with mock.patch.object(Path, 'symlink_to', side_effect=err):
            best = self.save_two_epochs()
        self.assertTrue(best.exists())
        self.assertFalse(best.is_symlink())
        self.assertEqual(torch.load(best, weights_only=False)['epoch'], 1)
        self.assertFalse((self.tmp / 'ckpt_e0.pth').exists())

    def test_report_whether_symlinks_work_here(self):
        target = self.tmp / 'a.txt'
        target.write_text('x')
        try:
            (self.tmp / 'b.txt').symlink_to(target.name)
            print('\n[info] this machine creates symlinks (Developer Mode or the privilege is present)')
        except OSError as e:
            print(f'\n[info] this machine refuses symlinks: {e}')


class TestTorchLoadDefault(TempDirCase):
    """What torch >= 2.6's default torch.load(weights_only=True) accepts. The trainers pass
    weights_only=False (as detector.py does) defensively; nothing written today needs it."""

    def test_default_load_refuses_a_numpy_scalar(self):
        import pickle

        import numpy as np
        p = self.tmp / 'ckpt.pth'
        torch.save({'epoch': 0, 'best_metrics': {'loss': {'value': np.float64(1.0)}}}, p)
        with self.assertRaises(pickle.UnpicklingError):
            torch.load(p)
        self.assertEqual(torch.load(p, weights_only=False)['epoch'], 0)

    def test_resume_checkpoint_layout_loads_with_the_default(self):
        m = torch.nn.Linear(2, 2)
        opt = torch.optim.SGD(m.parameters(), lr=0.1)
        sch = torch.optim.lr_scheduler.MultiStepLR(opt, milestones=[50, 75])
        p = self.tmp / 'last.pth'
        torch.save({'model': m.state_dict(), 'optimizer': opt.state_dict(), 'lr_scheduler': sch.state_dict(),
                    'epoch': 0, 'best_metrics': {'loss': {'value': 1.0, 'threshold': None, 'epoch': 0}}}, p)
        self.assertEqual(torch.load(p)['epoch'], 0)

    def test_shipped_checkpoints_load_with_the_default(self):
        for p in (SHIPPED_SCORER, SHIPPED_DETECTOR):
            self.assertIn('model', torch.load(p, map_location='cpu'))


class TestTrainPy(TempDirCase):
    """train.py (Stage 1): fine-tune from a shipped detector, then resume; one CPU epoch each."""

    def test_finetune_from_shipped_detector_then_resume(self):
        # Each half of an image must be at least one 640 px patch wide and high: with a narrower
        # region PatchedImageDataset's random offset clips the patch start to a negative index and
        # torchvision then gets an empty image (ZeroDivisionError). curation.Export.stage1 skips
        # such images; here the halves are 700 x 700.
        root = make_detection_dataset(self.tmp / 'data', n_images=2, size=(700, 1400), seed=3)
        run_dir = self.tmp / 'run'
        base = ['train.py', 'experiment=perineuronal-nets/detection/fasterrcnn_640',
                f'data.train.root={fwd(root)}', f'data.validation.root={fwd(root)}',
                'optim.num_workers=0', 'optim.batch_accumulation=1', 'optim.debug=false',
                'optim.val_device=cpu', 'gpu=null', f'hydra.run.dir={fwd(run_dir)}']
        r = run(base + ['optim.epochs=1', f'model.pretrained={fwd(SHIPPED_DETECTOR)}'])
        self.assertEqual(r.returncode, 0, tail(r))
        self.assertIn('[PRETRAINED]', r.stdout + r.stderr)
        self.assertTrue((run_dir / 'last.pth').exists())
        r = run(base + ['optim.epochs=2', 'optim.resume=true'])
        self.assertEqual(r.returncode, 0, tail(r))
        self.assertIn('[RESUME]', r.stdout + r.stderr)
        log = pd.read_csv(run_dir / 'train_log.csv', index_col=0, header=[0, 1])
        self.assertEqual(list(log.index), [0, 1])


if __name__ == '__main__':
    unittest.main()

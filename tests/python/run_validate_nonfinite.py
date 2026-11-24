"""Call train_score.validate() on a model whose scores are not finite.

TensorBoard's add_histogram raises ValueError on non-finite values; train_score.py used to answer
that with breakpoint(), which waits for a debugger command on stdin, so a headless run (stdin a pipe
nobody writes to, as under MATLAB's ProcessBuilder) hangs for ever. Prints VALIDATE_RETURNED when
validate() comes back. Used by test_trainer_fixes.TestTrainScore.test_nonfinite_scores_do_not_hang.

    python tests/python/run_validate_nonfinite.py <tensorboard log dir>
"""
import os
import sys
from pathlib import Path

REPO = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(REPO))
os.chdir(REPO)

import torch  # noqa: E402
from omegaconf import OmegaConf  # noqa: E402
from torch.utils.tensorboard import SummaryWriter  # noqa: E402

import train_score  # noqa: E402


class InfModel(torch.nn.Module):
    def forward(self, x):
        return torch.full((x.shape[0], 1), float('inf'))


cfg = OmegaConf.create({'optim': {'method': 'simple_regression', 'loss': {
    'spread': {'temperature': 5, 'weight': 0}, 'kl_div': {'bins': 10, 'eps': 1e-6}}}})
batches = [(torch.rand(4, 1, 64, 64), torch.tensor([0, 1, 2, 3]))]
writer = SummaryWriter(log_dir=sys.argv[1] if len(sys.argv) > 1 else None)
train_score.validate(batches, InfModel(), 'cpu', writer, 0, cfg)
print('VALIDATE_RETURNED', flush=True)

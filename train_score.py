import os
import logging
from functools import partial
from pathlib import Path

import hydra
import pandas as pd
import torch
from torch.utils.data import DataLoader
from torch.utils.tensorboard import SummaryWriter
from tqdm import tqdm, trange

# CenterLoss no longer exists in methods/rank/methods.py, so importing it unconditionally made
# train_score.py fail at import (ImportError) before any training. It is only used to log the
# centres of such a model, so the import is optional.
try:
    from methods.rank.methods import CenterLoss
except ImportError:
    CenterLoss = None
from spacecutter.models import OrdinalLogisticModel
from utils import CheckpointManager, seed_everything


log = logging.getLogger(__name__)
tqdm = partial(tqdm, dynamic_ncols=True)
trange = partial(trange, dynamic_ncols=True)


def train_one_epoch(dataloader, model, optimizer, device, writer, epoch, cfg):
    model.train()
    optimizer.zero_grad()
    compute_loss_and_scores = hydra.utils.get_method(f'methods.rank.methods.{cfg.optim.method}')

    metrics = []
    n_batches = len(dataloader)
    progress = tqdm(dataloader, desc='TRAIN', leave=False)
    for i, sample in enumerate(progress):
        batch_metrics, scores = compute_loss_and_scores(sample, model, device, cfg)
        loss = batch_metrics['loss']
        loss.backward()

        batch_metrics = {k: v.item() for k, v in batch_metrics.items()}
        metrics.append(batch_metrics)

        postfix = {metric: f'{value:.3f}' for metric, value in batch_metrics.items()}
        progress.set_postfix(postfix)

        if (i + 1) % cfg.optim.batch_accumulation == 0:
            optimizer.step()
            optimizer.zero_grad()

        if (i + 1) % cfg.optim.log_every == 0:
            batch_metrics.update({'lr': optimizer.param_groups[0]['lr']})
            n_iter = epoch * n_batches + i
            try:
                writer.add_histogram('train/scores', scores, n_iter)
            except ValueError as e:
                # TensorBoard refuses a histogram of non-finite scores. This used to call
                # breakpoint(), which waits for a debugger command on stdin: a headless run
                # (stdin an open pipe, e.g. launched from MATLAB) hung for ever. Log and go on.
                log.warning(f'[TRAIN] score histogram skipped at iteration {n_iter}: {e}')

            for metric, value in batch_metrics.items():
                writer.add_scalar(f'train/{metric}', value, n_iter)

            if isinstance(model, OrdinalLogisticModel):
                cutpoints = {str(i): c for i, c in enumerate(model.link.cutpoints.data.cpu())}
                writer.add_scalars('train/cutpoints', cutpoints, n_iter)
            
            if CenterLoss is not None and isinstance(model, CenterLoss):
                cutpoints = {str(i): c for i, c in enumerate(model.centers.data.cpu())}
                writer.add_scalars('train/centers', cutpoints, n_iter)

    metrics = pd.DataFrame(metrics).mean(axis=0).to_dict()
    metrics = {k: {'value': v, 'threshold': None} for k, v in metrics.items()}
    return metrics


@torch.no_grad()
def validate(dataloader, model, device, writer, epoch, cfg):
    """ Evaluate model on validation data. """
    model.eval()
    compute_loss_and_scores = hydra.utils.get_method(f'methods.rank.methods.{cfg.optim.method}')

    all_scores = []
    metrics = []
    progress = tqdm(dataloader, desc='EVAL', leave=False)
    for i, sample in enumerate(progress):

        batch_metrics, scores = compute_loss_and_scores(sample, model, device, cfg)
        batch_metrics = {k: v.item() for k, v in batch_metrics.items()}
        metrics.append(batch_metrics)
        all_scores.append(scores.cpu())

        postfix = {metric: f'{value:.3f}' for metric, value in batch_metrics.items()}
        progress.set_postfix(postfix)
    
    all_scores = torch.cat(all_scores)
    try:
        writer.add_histogram('valid/scores', all_scores, epoch)
    except ValueError as e:
        # was breakpoint(): a headless run hung here (see train_one_epoch)
        log.warning(f'[VALID] score histogram skipped at epoch {epoch}: {e}')

    metrics = pd.DataFrame(metrics).mean(axis=0).to_dict()
    metrics = {k: {'value': v, 'threshold': None} for k, v in metrics.items()}
    return metrics


@hydra.main(config_path="conf_score", config_name="config")
def main(cfg):
    from omegaconf import OmegaConf; print(OmegaConf.to_yaml(cfg))
    
    log.info(f"Run path: {Path.cwd()}")

    os.environ["CUDA_VISIBLE_DEVICES"] = str(cfg.gpu)
    device = torch.device(f'cuda' if cfg.gpu is not None else 'cpu')
    log.info(f"Use device {device} for training")

    # Reproducibility
    seed_everything(cfg.seed)
    torch.set_default_dtype(torch.float32)

    # create tensorboard writer
    writer = SummaryWriter()

    # training dataset and dataloader
    train_dataset = hydra.utils.instantiate(cfg.data.train)
    train_loader = DataLoader(train_dataset, batch_size=cfg.optim.batch_size, shuffle=True, num_workers=cfg.optim.num_workers)
    log.info(f'[TRAIN] {train_dataset}')

    # validation dataset and dataloader
    valid_dataset = hydra.utils.instantiate(cfg.data.validation)
    valid_loader = DataLoader(valid_dataset, batch_size=cfg.optim.val_batch_size, num_workers=cfg.optim.num_workers)
    log.info(f'[VALID] {valid_dataset}')

    # create model and move to device
    model_params = cfg.model.get('wrapper', cfg.model.base)
    model = hydra.utils.instantiate(model_params).to(device)
    model_param_string = ', '.join(f'{k}={v}' for k, v in model_params.items() if not k.startswith('_'))
    log.info(f"[MODEL] {cfg.model.name}({model_param_string})")

    # optionally start from pre-trained weights: model.pretrained=<path to a best.pth>, e.g. a shipped
    # scorer to fine-tune on curated labels. optim.resume cannot do that (a shipped best.pth has no
    # lr_scheduler state and resume reads last.pth of this run). weights_only=False as in detector.py
    # (torch >= 2.6 defaults to weights_only=True, which refuses non-allow-listed objects; the shipped
    # best.pth files load either way).
    pretrained = cfg.model.get('pretrained', None)
    if pretrained and not cfg.optim.resume:
        checkpoint = torch.load(pretrained, map_location=device, weights_only=False)
        state = checkpoint.get('model', checkpoint)
        if hasattr(model, 'predictor') and not any(k.startswith('predictor.') for k in state):
            model.predictor.load_state_dict(state)  # a plain ConvNet checkpoint into the ordinal wrapper
            log.info(f"[PRETRAINED] predictor weights from {pretrained}")
        else:
            model.load_state_dict(state)  # same architecture: all weights, ordinal cutpoints included
            log.info(f"[PRETRAINED] all weights from {pretrained}")

    # build the optimizer
    optimizer = hydra.utils.instantiate(cfg.optim.optimizer, model.parameters())
    scheduler = hydra.utils.instantiate(cfg.optim.lr_scheduler, optimizer)
        
    start_epoch = 0
    best_metrics = {}

    train_log_path = 'train_log.csv'
    valid_log_path = 'valid_log.csv'

    train_log = pd.DataFrame()
    valid_log = pd.DataFrame()

    # optionally resume from a saved checkpoint
    if cfg.optim.resume:
        assert Path('last.pth').exists(), 'Cannot find checkpoint for resuming.'
        # weights_only=False (as detector.py): torch >= 2.6 defaults to weights_only=True, which refuses
        # a checkpoint holding any non-allow-listed object (e.g. a numpy scalar in a metric). The
        # last.pth written today loads either way (checked with torch 2.11); this is defensive.
        checkpoint = torch.load('last.pth', map_location=device, weights_only=False)

        model.load_state_dict(checkpoint['model'])
        optimizer.load_state_dict(checkpoint['optimizer'])
        if scheduler is not None:
            scheduler.load_state_dict(checkpoint['lr_scheduler'])

        start_epoch = checkpoint['epoch'] + 1
        best_metrics = checkpoint['best_metrics']

        train_log = pd.read_csv(train_log_path, index_col=0, header=[0,1])
        valid_log = pd.read_csv(valid_log_path, index_col=0, header=[0,1])
        log.info(f"[RESUME] Resuming from epoch {start_epoch}")

    # checkpoint manager
    ckpt_dir = Path('best_models')
    ckpt_dir.mkdir(parents=True, exist_ok=True)
    ckpt_manager = CheckpointManager(ckpt_dir, current_best=best_metrics, metric_modes={
        'loss': 'min',
        'regression_loss': 'min',
        'rank/margin_loss': 'min',
        'rank/sorted_pct': 'max',
        'rank/spread_loss': 'min',
        'rank/classif_loss': 'min',
        'rank/kl_div': 'min',
        'rank/spearman': 'max',
    })

    # Train loop
    log.info(f"Training ...")
    progress = trange(start_epoch, cfg.optim.epochs, initial=start_epoch)
    for epoch in progress:
        # train
        train_metrics = train_one_epoch(train_loader, model, optimizer, device, writer, epoch, cfg)
        scheduler.step()  # update lr scheduler

        # convert for pandas
        train_metrics = {(metric, info): v for metric, infos in train_metrics.items() for info, v in infos.items()}
        train_metrics = pd.DataFrame(train_metrics, index=[epoch]).rename_axis('epoch')
        # DataFrame.append was removed in pandas 2.0 (AttributeError after the first epoch)
        train_log = pd.concat([train_log, train_metrics])
        train_log.to_csv(train_log_path)

        # evaluation
        if (epoch + 1) % cfg.optim.val_freq == 0:
            valid_metrics = validate(valid_loader, model, device, writer, epoch, cfg)

            for metric, info in valid_metrics.items():  # log to tensorboard
                value = info.get('value', None)
                writer.add_scalar(f'valid/{metric}', value, epoch)

                threshold = info.get('threshold', None)
                if threshold is not None:
                    writer.add_scalar(f'valid/{metric}_thr', threshold, epoch)

            # save only if best on some metric (via CheckpointManager)
            best_metrics = ckpt_manager.save({
                'model': model.state_dict(),
                'optimizer': optimizer.state_dict(),
                'epoch': epoch,
                'metrics': valid_metrics
            }, valid_metrics, epoch)

            # save last checkpoint for resuming
            torch.save({
                'model': model.state_dict(),
                'optimizer': optimizer.state_dict(),
                'lr_scheduler': scheduler.state_dict(),
                'epoch': epoch,
                'best_metrics': best_metrics,
            }, 'last.pth')

            # convert for pandas
            valid_metrics = {(metric, info): v for metric, infos in valid_metrics.items() for info, v in infos.items()}
            valid_metrics = pd.DataFrame(valid_metrics, index=[epoch]).rename_axis('epoch')
            valid_log = pd.concat([valid_log, valid_metrics])  # was DataFrame.append (pandas < 2)
            valid_log.to_csv(valid_log_path)

        # generate new tuples for train and validation
        train_loader.dataset.generate_tuples()
        valid_loader.dataset.generate_tuples()

    # flush TensorBoard while the working directory is still the run folder: Hydra restores the
    # original one after main() returns, and the writer's relative path then no longer exists
    writer.close()
    log.info("Training ended. Exiting....")


if __name__ == "__main__":
    main()
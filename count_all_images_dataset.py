import os
import gc
import time

import pandas as pd

try:
    import torch
except ImportError:
    torch = None

from detector import CellDetector


def main():
    DATASET_PATH = r'E:\PizzorussoLAB\proj_PNN-AtlasChR\PART1\DATASET'
    STAINING = "WFA"

    if STAINING == "WFA":
        PATTERN = "-C1.tif"
        MODEL_NAME = "pnn_v2_fasterrcnn_640"
        SCORING_MODEL = "pnn_v2_scoring_rank_learning"
    elif STAINING == "PV":
        PATTERN = "-C2.tif"
        MODEL_NAME = "pv_v2_fasterrcnn_640"
        SCORING_MODEL = "pv_v2_scoring_rank_learning"
    else:
        raise ValueError(f"Unsupported STAINING value: {STAINING}")

    THRESHOLD = 0.05
    DEVICE = "cuda:0"
    # Set SCORING_MODEL to None to skip rescoring
    # SCORING_MODEL = None

    print(f"Loading model: {MODEL_NAME}")
    detector = CellDetector(
        run_path=MODEL_NAME,
        device=DEVICE,
        threshold=THRESHOLD,
        rescorer_path=SCORING_MODEL,
    )

    bad_imgs = []
    cuda_context_broken = False

    mouse_folders = [
        d for d in os.listdir(DATASET_PATH)
        if os.path.isdir(os.path.join(DATASET_PATH, d))
    ]

    for mouse_name in mouse_folders:
        mouse_path = os.path.join(DATASET_PATH, mouse_name)
        hires_path = os.path.join(mouse_path, 'hiRes')
        counts_path = os.path.join(mouse_path, 'counts')

        if not os.path.isdir(hires_path):
            print(f"Skipping {mouse_name}: no hiRes folder found")
            continue

        if not os.path.isdir(counts_path):
            os.mkdir(counts_path)

        file_list = os.listdir(hires_path)
        img_list = [f for f in file_list if PATTERN in f]

        print(f"\nMouse: {mouse_name}")
        print(f"Found {len(img_list)} images matching {PATTERN}")

        for i, im in enumerate(img_list):
            if cuda_context_broken:
                print(f"Skipping {im}: CUDA context is broken, cannot process further images.")
                bad_imgs.append({
                    'mouse': mouse_name,
                    'image': im,
                    'staining': STAINING,
                    'error': 'Skipped: CUDA context broken by prior error'
                })
                continue

            print(f'Processing file: {im} ({i + 1}/{len(img_list)})')

            input_name = os.path.join(hires_path, im)
            output_file = (
                im.replace('.tif', '.csv')
                  .replace('-C1.csv', '-cells_C1.csv')
                  .replace('-C2.csv', '-cells_C2.csv')
            )
            output_name = os.path.join(counts_path, output_file)

            if os.path.exists(output_name):
                print(f"Skipping {im}: output already exists")
                continue

            try:
                localizations = detector.predict(input_name, batch_size=1)
                print(f'[OUTPUT] {output_name}')
                localizations.to_csv(output_name, index=False)
            except Exception as e:
                error_str = str(e)
                print(f"Error processing {input_name}: {e}")
                bad_imgs.append({
                    'mouse': mouse_name,
                    'image': im,
                    'staining': STAINING,
                    'error': error_str
                })
                if 'CUDA error' in error_str or 'CUDA out of memory' in error_str:
                    print("CUDA context is now broken. Remaining images in this run will be skipped.")
                    cuda_context_broken = True
                continue

        # ==========================================================
        # Cleanup after each mouse
        # ==========================================================
        print(f"Finished mouse {mouse_name}. Cleaning up memory and pausing briefly...")
        gc.collect()

        if torch is not None and not cuda_context_broken and torch.cuda.is_available():
            try:
                torch.cuda.empty_cache()
            except Exception as e:
                print(f"Warning: could not empty CUDA cache: {e}")
                cuda_context_broken = True

        time.sleep(10)
        # ==========================================================

    if bad_imgs:
        df = pd.DataFrame(bad_imgs)
        bad_csv_path = os.path.join(DATASET_PATH, f'bad_images_{STAINING}.csv')
        df.to_csv(bad_csv_path, index=False)
        print(f"\nSaved bad image log to: {bad_csv_path}")
    else:
        print("\nNo bad images encountered.")


if __name__ == '__main__':
    main()

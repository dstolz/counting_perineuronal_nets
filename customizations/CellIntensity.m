classdef CellIntensity
% CELLINTENSITY  Single-cell staining-intensity measurement (Lupori et al., 2023).
%   Quantifies the staining intensity of individual PNNs / PV cells exactly as
%   described in:
%
%     Lupori et al. (2023) "A comprehensive atlas of perineuronal net
%     distribution and colocalization with parvalbumin in the adult mouse
%     brain." Cell Reports 42(7):112788. doi:10.1016/j.celrep.2023.112788
%
%   Method (per cell)
%   -----------------
%     1. Extract an 80x80 px tile centred on the cell's (X,Y) position.
%     2. Segment each pixel as cell (foreground) or background with a random
%        forest pixel classifier (MATLAB TreeBagger).
%     3. The cell's intensity is the mean of the ORIGINAL pixel values over
%        the foreground (cell) pixels.
%
%   Pixel features (19 per pixel) used by the classifier:
%       * 1  : contrast-adjusted pixel intensity (imadjust)
%       * 2  : horizontal position relative to the tile centre (px)
%       * 3  : vertical   position relative to the tile centre (px)
%       * 4-19: pixel intensity in 16 Gabor-filtered versions of the tile
%               (4 wavelengths x 4 orientations).
%   Gabor wavelengths : 2*sqrt(2) * 2.^(0:3) = [2.83 5.66 11.31 22.63] px/cycle
%                       (the 2.8 / 5.6 / 11.3 / 22.6 of the paper).
%   Gabor orientations : 0, 45, 90, 135 degrees.
%
%   Every method is Static — no instance is needed.
%
%   Typical use
%   -----------
%       % --- Train once from pixel-labelled tiles -------------------------
%       %   tiles : 1xK cell of 80x80 image tiles
%       %   masks : 1xK cell of 80x80 logical masks (true = cell pixel)
%       model = CellIntensity.trainClassifier(tiles, masks);
%       save('pnn_intensity_rf.mat', 'model');
%
%       % --- Measure every detection in a locs CSV ------------------------
%       T = CellIntensity.measureFromCsv(model, 'img_PNN1_locs.csv');
%       %   -> adds an 'Intensity' column; cell array of masks also available.
%
%       % --- Or measure explicit points in an in-memory image -------------
%       img = imread('img.tif');
%       res = CellIntensity.measure(model, img, [X Y]);
%
%   Requires the Image Processing Toolbox (imadjust, gabor, imgaborfilt) and
%   the Statistics and Machine Learning Toolbox (TreeBagger).

    properties (Constant)
        TileSize        = 80;                       % px (square tile edge)
        GaborWavelengths = 2*sqrt(2) * 2.^(0:3);    % [2.83 5.66 11.31 22.63]
        GaborOrientations = [0 45 90 135];          % degrees
        PixelsPerTile   = 60;                        % training pixels / tile
        NumTrees        = 50;                        % TreeBagger default
    end

    %% ===================================================================
    %  Feature extraction
    %  ===================================================================
    methods (Static)

        function bank = gaborBank()
            % Build the 16-filter Gabor bank (4 wavelengths x 4 orientations)
            % used for pixel features. Returned as a 1x16 array of gabor
            % objects, ready for imgaborfilt.
            bank = gabor(CellIntensity.GaborWavelengths, ...
                         CellIntensity.GaborOrientations);
        end

        function [X, names] = tileFeatures(tile, bank)
            % Per-pixel feature matrix for one tile.
            %   tile : HxW grayscale image (any numeric class).
            %   bank : optional precomputed gabor bank (gaborBank()); pass it
            %          in a loop to avoid rebuilding the filters each call.
            % Returns:
            %   X     : (H*W) x 19 double feature matrix, pixels in MATLAB
            %           column-major order (matches tile(:) and mask(:)).
            %   names : 1x19 cellstr of feature names (for inspection/debug).
            if nargin < 2 || isempty(bank)
                bank = CellIntensity.gaborBank();
            end
            % Normalise intensity to [0,1] double for filtering/adjustment.
            t = CellIntensity.toUnit(tile);
            [H, W] = size(t);

            % 1) Contrast-adjusted intensity.
            tAdj = imadjust(t);

            % 2-3) Position relative to the geometric tile centre (px).
            cx = (W + 1) / 2;
            cy = (H + 1) / 2;
            [C, R] = meshgrid(1:W, 1:H);
            dx = C - cx;
            dy = R - cy;

            % 4-19) Gabor magnitude responses.
            gmag = imgaborfilt(t, bank);          % H x W x 16
            nF   = size(gmag, 3);
            G    = reshape(gmag, H * W, nF);

            X = [tAdj(:), dx(:), dy(:), G];

            if nargout > 1
                names = cell(1, 3 + nF);
                names{1} = 'intensity_adj';
                names{2} = 'pos_x';
                names{3} = 'pos_y';
                k = 0;
                for w = 1:numel(CellIntensity.GaborWavelengths)
                    for o = 1:numel(CellIntensity.GaborOrientations)
                        k = k + 1;
                        names{3 + k} = sprintf('gabor_w%.2f_o%d', ...
                            CellIntensity.GaborWavelengths(w), ...
                            CellIntensity.GaborOrientations(o));
                    end
                end
            end
        end

    end

    %% ===================================================================
    %  Training
    %  ===================================================================
    methods (Static)

        function model = trainClassifier(tiles, masks, opts)
            % Train a random forest pixel classifier from labelled tiles.
            %   tiles : 1xK (or Kx1) cell of grayscale image tiles.
            %   masks : 1xK cell of logical masks, same size as each tile,
            %           true where the pixel belongs to the cell (foreground).
            %   opts  : optional struct with fields
            %             PixelsPerTile : training pixels sampled / tile
            %                             (default 60, as in the paper)
            %             NumTrees      : number of trees (default 50)
            %             Balanced      : if true, sample equal numbers of
            %                             fg/bg pixels per tile (default false)
            % Returns a trained TreeBagger ready for segmentTile/measure.
            if nargin < 3, opts = struct(); end
            ppt   = CellIntensity.optOr(opts, 'PixelsPerTile', CellIntensity.PixelsPerTile);
            nTree = CellIntensity.optOr(opts, 'NumTrees',      CellIntensity.NumTrees);
            bal   = CellIntensity.optOr(opts, 'Balanced',      false);

            tiles = tiles(:);
            masks = masks(:);
            assert(numel(tiles) == numel(masks), ...
                'CellIntensity:trainClassifier', ...
                'tiles and masks must have the same number of elements.');

            bank = CellIntensity.gaborBank();
            Xall = cell(numel(tiles), 1);
            Yall = cell(numel(tiles), 1);
            for k = 1:numel(tiles)
                tile = tiles{k};
                m    = logical(masks{k});
                assert(isequal(size(tile), size(m)), ...
                    'CellIntensity:trainClassifier', ...
                    'tile %d and its mask differ in size.', k);

                F   = CellIntensity.tileFeatures(tile, bank);
                lbl = m(:);
                sel = CellIntensity.samplePixels(lbl, ppt, bal);
                Xall{k} = F(sel, :);
                Yall{k} = lbl(sel);
            end

            X = cell2mat(Xall);
            Y = cell2mat(Yall);
            % TreeBagger wants categorical/char labels for classification.
            Ylab = repmat("background", numel(Y), 1);
            Ylab(Y) = "cell";

            model = TreeBagger(nTree, X, cellstr(Ylab), ...
                'Method', 'classification', ...
                'OOBPrediction', 'on');
        end

    end

    %% ===================================================================
    %  Segmentation & measurement
    %  ===================================================================
    methods (Static)

        function [mask, prob] = segmentTile(model, tile, opts)
            % Classify every pixel of a tile into cell/background.
            %   model : trained TreeBagger (trainClassifier) OR '' / [] to use
            %           a threshold fallback (see opts.Method).
            %   tile  : grayscale image tile.
            %   opts  : optional struct with fields
            %             Method          : 'rf' (default when a model is
            %                               given) or 'otsu' (model-free
            %                               Otsu threshold fallback).
            %             CenterComponent : keep only the connected foreground
            %                               component nearest the tile centre
            %                               (default true). This isolates the
            %                               central cell from stray foreground.
            % Returns the logical mask and, for the RF method, the per-pixel
            % foreground probability map (else []).
            if nargin < 3, opts = struct(); end
            useRf  = ~isempty(model);
            method = CellIntensity.optOr(opts, 'Method', ...
                CellIntensity.ternary(useRf, 'rf', 'otsu'));
            keepCentre = CellIntensity.optOr(opts, 'CenterComponent', true);

            [H, W] = size(tile);
            prob = [];
            switch lower(method)
                case 'rf'
                    assert(useRf, 'CellIntensity:segmentTile', ...
                        'Method ''rf'' requires a trained model.');
                    F = CellIntensity.tileFeatures(tile);
                    [lbl, scores] = predict(model, F);
                    mask = reshape(strcmp(lbl, 'cell'), H, W);
                    % Probability of the 'cell' class, if recoverable.
                    cellCol = find(strcmp(model.ClassNames, 'cell'), 1);
                    if ~isempty(cellCol)
                        prob = reshape(scores(:, cellCol), H, W);
                    end
                case 'otsu'
                    t   = CellIntensity.toUnit(tile);
                    lvl = graythresh(t);
                    mask = t > lvl;
                otherwise
                    error('CellIntensity:segmentTile', ...
                        'Unknown segmentation Method "%s".', method);
            end

            if keepCentre && any(mask(:))
                mask = CellIntensity.centreComponent(mask);
            end
        end

        function mask = keepCentreComponent(mask)
            % Public wrapper around the centre-component reduction: reduce a
            % binary mask to the single connected foreground component nearest
            % the tile centre. Reused by the training-data builder.
            if any(mask(:))
                mask = CellIntensity.centreComponent(mask);
            end
        end

        function [intensity, mask, tile] = measureTile(model, fullTile, opts)
            % Measure the staining intensity of the cell centred in a tile.
            %   fullTile : grayscale tile centred on the cell (original units).
            % Returns:
            %   intensity : mean of the ORIGINAL pixel values over the cell
            %               (foreground) pixels; NaN if the segmentation is
            %               empty.
            %   mask      : logical cell mask used.
            %   tile      : the tile passed in (echoed for convenience).
            if nargin < 3, opts = struct(); end
            tile = fullTile;
            mask = CellIntensity.segmentTile(model, tile, opts);
            vals = double(tile(mask));
            if isempty(vals)
                intensity = NaN;
            else
                intensity = mean(vals);
            end
        end

        function res = measure(model, img, xy, opts)
            % Measure intensity for a set of (X,Y) cell centres in one image.
            %   img  : grayscale image (single page already selected).
            %   xy   : N x 2 matrix of [X Y] pixel coordinates (X = column,
            %          Y = row), as produced by predict.py / the locs CSVs.
            %   opts : optional struct, forwarded to segmentTile, plus
            %             TileSize : tile edge in px (default 80).
            % Returns a struct array (1 x N) with fields:
            %   X, Y, Intensity, NumPixels (foreground pixel count), Mask.
            if nargin < 4, opts = struct(); end
            sz = CellIntensity.optOr(opts, 'TileSize', CellIntensity.TileSize);

            img = CellIntensity.toGray(img);
            n   = size(xy, 1);
            res = repmat(struct('X', NaN, 'Y', NaN, 'Intensity', NaN, ...
                'NumPixels', 0, 'Mask', []), 1, n);
            for i = 1:n
                xc = xy(i, 1);
                yc = xy(i, 2);
                tile = CellIntensity.extractTile(img, xc, yc, sz);
                [val, mask] = CellIntensity.measureTile(model, tile, opts);
                res(i).X         = xc;
                res(i).Y         = yc;
                res(i).Intensity = val;
                res(i).NumPixels = nnz(mask);
                res(i).Mask      = mask;
            end
        end

        function [img, xy, T, live] = resolveCsvPoints(csvPath, opts)
            % Resolve a localization CSV to a page image and its effective
            % cell coordinates, following the shared CellToolkit conventions.
            % Shared by measureFromCsv and the training-data builder so the
            % CSV/TIFF/page/curation logic lives in one place.
            %   csvPath : a "*_locs.csv" from the Cell* pipeline.
            %   opts    : optional struct with fields
            %             ImagePath : override the auto-detected TIFF path
            %             Page      : override the auto-detected TIFF page
            % Returns:
            %   img  : the resolved page image.
            %   xy   : N x 2 effective [X Y] (CURATED_X/Y when present, else
            %          X/Y); deleted/merged rows keep X/Y but are flagged dead.
            %   T    : the table as read.
            %   live : N x 1 logical, false for rows curated away.
            if nargin < 2, opts = struct(); end
            T = readtable(char(csvPath), 'VariableNamingRule', 'preserve');
            vn = string(T.Properties.VariableNames);
            assert(all(ismember(["X", "Y"], vn)), ...
                'CellIntensity:resolveCsvPoints', ...
                'CSV "%s" must contain X and Y columns.', char(csvPath));

            % Effective coordinates: prefer curated, treat blanked as deleted.
            ex = double(T.X);  ey = double(T.Y);
            live = true(height(T), 1);
            if all(ismember(["CURATED_X", "CURATED_Y"], vn))
                cx = T.CURATED_X;  cy = T.CURATED_Y;
                live = ~isnan(cx) & ~isnan(cy);
                ex(live) = cx(live);
                ey(live) = cy(live);
            end
            xy = [ex, ey];

            % Resolve the companion image + page.
            imgPath = CellIntensity.optOr(opts, 'ImagePath', '');
            if isempty(imgPath)
                imgPath = CellToolkit.inferImagePath(csvPath);
            end
            assert(~isempty(imgPath) && isfile(imgPath), ...
                'CellIntensity:resolveCsvPoints', ...
                'Could not locate the companion image for "%s".', char(csvPath));
            page = CellIntensity.optOr(opts, 'Page', []);
            if isempty(page)
                page = CellToolkit.pageFromCsvName(csvPath);
                if isnan(page), page = 1; end
            end
            img = CellToolkit.readPage(imgPath, page);
        end

        function T = measureFromCsv(model, csvPath, opts)
            % Measure intensity for every detection in a localization CSV,
            % resolving the companion TIFF and reading the correct page via
            % the shared CellToolkit naming conventions.
            %   csvPath : a "*_locs.csv" produced by the Cell* pipeline. Uses
            %             CURATED_X/CURATED_Y when present (skipping rows the
            %             neighbour resolver deleted/merged away), else X/Y.
            %   opts    : optional struct, forwarded to measure(), plus
            %             ImagePath : override the auto-detected TIFF path
            %             Page      : override the auto-detected TIFF page
            %             Output    : path to write the augmented table to
            % Returns the input table with an added 'Intensity' column
            % (NaN for skipped rows).
            if nargin < 3, opts = struct(); end
            [img, xy, T, live] = CellIntensity.resolveCsvPoints(csvPath, opts);

            intensity = nan(height(T), 1);
            numPix    = zeros(height(T), 1);
            idx = find(live);
            if ~isempty(idx)
                res = CellIntensity.measure(model, img, xy(idx, :), opts);
                intensity(idx) = [res.Intensity];
                numPix(idx)    = [res.NumPixels];
            end
            T.Intensity      = intensity;
            T.IntensityNumPx = numPix;

            outPath = CellIntensity.optOr(opts, 'Output', '');
            if ~isempty(outPath)
                writetable(T, char(outPath));
            end
        end

    end

    %% ===================================================================
    %  Tile extraction
    %  ===================================================================
    methods (Static)

        function tile = extractTile(img, xc, yc, sz)
            % Extract an sz x sz tile centred on (xc,yc) (X=col, Y=row).
            % Pixels falling outside the image are filled by edge replication
            % so the tile is always exactly sz x sz.
            if nargin < 4, sz = CellIntensity.TileSize; end
            [H, W, ~] = size(img);
            half = floor(sz / 2);
            r0 = round(yc) - half;
            c0 = round(xc) - half;
            rows = r0 + (0:sz - 1);
            cols = c0 + (0:sz - 1);
            rows = min(max(rows, 1), H);     % clamp = replicate border
            cols = min(max(cols, 1), W);
            tile = img(rows, cols, 1);       % first channel if multi-channel
        end

    end

    %% ===================================================================
    %  Internal helpers
    %  ===================================================================
    methods (Static, Access = private)

        function mask = centreComponent(mask)
            % Reduce a binary mask to the single connected component nearest
            % the tile centre — the central cell the tile was built around.
            cc = bwconncomp(mask);
            if cc.NumObjects <= 1
                return;
            end
            [H, W] = size(mask);
            cr = (H + 1) / 2;
            cc2 = (W + 1) / 2;
            centreIdx = sub2ind([H, W], round(cr), round(cc2));
            % If the centre pixel itself is foreground, keep its component.
            for k = 1:cc.NumObjects
                if any(cc.PixelIdxList{k} == centreIdx)
                    mask = false(H, W);
                    mask(cc.PixelIdxList{k}) = true;
                    return;
                end
            end
            % Otherwise keep the component whose centroid is closest to centre.
            best = 1; bestD = inf;
            for k = 1:cc.NumObjects
                [rr, ccq] = ind2sub([H, W], cc.PixelIdxList{k});
                d = (mean(rr) - cr)^2 + (mean(ccq) - cc2)^2;
                if d < bestD
                    bestD = d; best = k;
                end
            end
            keep = false(H, W);
            keep(cc.PixelIdxList{best}) = true;
            mask = keep;
        end

        function sel = samplePixels(lbl, n, balanced)
            % Indices of n training pixels for one tile. Random across all
            % pixels (paper default) or n/2 from each class when balanced.
            N = numel(lbl);
            if balanced
                fg = find(lbl);  bg = find(~lbl);
                kEach = floor(n / 2);
                sel = [CellIntensity.pick(fg, kEach); ...
                       CellIntensity.pick(bg, n - kEach)];
            else
                sel = CellIntensity.pick((1:N)', n);
            end
        end

        function out = pick(pool, k)
            % Choose up to k random elements of a column vector pool.
            if isempty(pool) || k <= 0
                out = zeros(0, 1);
                return;
            end
            if numel(pool) <= k
                out = pool;
            else
                out = pool(randperm(numel(pool), k));
            end
        end

        function u = toUnit(img)
            % Convert any numeric image to double in [0,1] for filtering.
            if islogical(img)
                u = double(img);
                return;
            end
            switch class(img)
                case 'uint8',  u = double(img) / 255;
                case 'uint16', u = double(img) / 65535;
                case {'single', 'double'}
                    u = double(img);
                    mx = max(u(:));
                    if mx > 1, u = u / mx; end
                otherwise
                    u = double(img);
                    mx = max(u(:));
                    if mx > 0, u = u / mx; end
            end
        end

        function g = toGray(img)
            % Reduce an RGB image to a single channel; pass grayscale through.
            if ndims(img) == 3 && size(img, 3) == 3
                g = rgb2gray(img);
            else
                g = img;
            end
        end

        function v = optOr(s, name, default)
            % Value of opts.name, or default when absent/empty.
            if isstruct(s) && isfield(s, name) && ~isempty(s.(name))
                v = s.(name);
            else
                v = default;
            end
        end

        function r = ternary(cond, a, b)
            if cond, r = a; else, r = b; end
        end

    end

end

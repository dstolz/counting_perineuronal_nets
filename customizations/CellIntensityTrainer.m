classdef CellIntensityTrainer < handle
% CELLINTENSITYTRAINER  Build pixel-labelled training data for CellIntensity.
%   The random-forest pixel classifier used by CellIntensity needs tiles
%   paired with per-pixel cell/background masks. Hand-painting hundreds of
%   80x80 masks is the slow part, so this tool makes it semi-automatic:
%
%     * each tile gets an auto-proposed mask (Otsu + central component) — the
%       same primitives CellIntensity segments with — so most tiles need only
%       a confirmation;
%     * a threshold slider tightens/loosens the proposal instantly;
%     * freehand Add / Erase fix the few tiles the threshold can't get right;
%     * Include/skip lets you drop ambiguous tiles from the training set.
%
%   Then it trains the classifier in one click (CellIntensity.trainClassifier).
%
%   Quick start
%   -----------
%       % Label the detections in a locs CSV (companion TIFF auto-resolved):
%       CellIntensityTrainer.fromCsv('img_PNN1_locs.csv');
%
%       % Or from an in-memory image + points:
%       CellIntensityTrainer.fromImage(img, [X Y]);
%
%       % Pool detections from several CSVs into one labelling session:
%       CellIntensityTrainer.fromCsvList(["a_locs.csv"; "b_locs.csv"], ...
%           struct('MaxTiles', 1160, 'Shuffle', true));
%
%   In the window: drag the slider to fix the proposal, press A to draw an
%   addition / E to draw an erase, Space/→ to accept & advance, I to skip a
%   tile, then "Train model…". Hover any control for its shortcut.
%
%   Headless (scripted) use
%   -----------------------
%       ds    = CellIntensityTrainer.buildFromCsv('img_PNN1_locs.csv');
%       % ...inspect / edit ds.masks programmatically if desired...
%       model = CellIntensityTrainer.train(ds);     % -> TreeBagger
%       CellIntensityTrainer.saveDataset(ds, 'pnn_trainset.mat');
%
%   Dataset struct
%   --------------
%       .tiles    1xN cell of original-class image tiles
%       .masks    1xN cell of logical cell masks (true = cell pixel)
%       .included 1xN logical (tiles used for training)
%       .thrMult  1xN double  (per-tile Otsu threshold multiplier)
%       .edited   1xN logical  (mask hand-edited; slider won't be its source)
%       .tileSize scalar tile edge (px)
%       .source   provenance struct (csv list, image path, xy, ...)
%
%   Requires the Image Processing Toolbox (graythresh, drawfreehand) and,
%   for training, the Statistics and Machine Learning Toolbox.

    properties
        Dataset                 % the dataset struct being edited
        Idx = 1                 % current tile index
    end

    properties (Access = private)
        Fig
        Ax
        ImgH                    % image graphics object (CData updated in place)
        ThrSlider
        ThrLabel
        IncludeBox
        KeepCentreBox
        TitleLabel
        StatsLabel
        ProgressLabel
        Alpha = 0.45            % mask overlay opacity
        Busy = false           % reentrancy guard during freehand draw
    end

    %% ===================================================================
    %  Construction / entry points
    %  ===================================================================
    methods
        function app = CellIntensityTrainer(dataset)
            % Open the labelling GUI on a prepared dataset struct (use the
            % static fromCsv / fromImage helpers to build one from a source).
            if nargin < 1 || isempty(dataset)
                error('CellIntensityTrainer:noData', ...
                    'Provide a dataset; build one with fromCsv/fromImage.');
            end
            app.Dataset = CellIntensityTrainer.normaliseDataset(dataset);
            app.buildUI();
            app.showTile(1);
        end
    end

    methods (Static)
        function app = fromCsv(csvPath, opts)
            % Build a dataset from one locs CSV and open the labeller.
            if nargin < 2, opts = struct(); end
            ds  = CellIntensityTrainer.buildFromCsv(csvPath, opts);
            app = CellIntensityTrainer(ds);
        end

        function app = fromCsvList(csvPaths, opts)
            % Build a pooled dataset from several locs CSVs and open it.
            if nargin < 2, opts = struct(); end
            ds  = CellIntensityTrainer.buildFromCsvList(csvPaths, opts);
            app = CellIntensityTrainer(ds);
        end

        function app = fromImage(img, xy, opts)
            % Build a dataset from an image + Nx2 [X Y] points and open it.
            if nargin < 3, opts = struct(); end
            ds  = CellIntensityTrainer.buildFromImage(img, xy, opts);
            app = CellIntensityTrainer(ds);
        end
    end

    %% ===================================================================
    %  Headless dataset builders
    %  ===================================================================
    methods (Static)

        function ds = buildFromImage(img, xy, opts)
            % Extract tiles centred on each [X Y] point and auto-propose masks.
            %   opts fields: TileSize (80), ThrMult (1.0), KeepCentre (true),
            %                MaxTiles (Inf), Shuffle (false).
            if nargin < 3, opts = struct(); end
            sz   = CellIntensityTrainer.optOr(opts, 'TileSize',  CellIntensity.TileSize);
            thr  = CellIntensityTrainer.optOr(opts, 'ThrMult',   1.0);
            keep = CellIntensityTrainer.optOr(opts, 'KeepCentre', true);
            maxT = CellIntensityTrainer.optOr(opts, 'MaxTiles',  Inf);
            shuf = CellIntensityTrainer.optOr(opts, 'Shuffle',   false);

            img = CellIntensityTrainer.toGray(img);
            n   = size(xy, 1);
            order = 1:n;
            if shuf, order = randperm(n); end
            if maxT < numel(order), order = order(1:maxT); end

            m = numel(order);
            tiles = cell(1, m);
            masks = cell(1, m);
            for i = 1:m
                p = order(i);
                tile = CellIntensity.extractTile(img, xy(p, 1), xy(p, 2), sz);
                tiles{i} = tile;
                masks{i} = CellIntensityTrainer.proposeMask(tile, thr, keep);
            end

            ds = CellIntensityTrainer.makeDataset(tiles, masks, sz, thr, keep);
            ds.source.xy    = xy(order, :);
            ds.source.order = order(:);
        end

        function ds = buildFromCsv(csvPath, opts)
            % Build from one locs CSV; the companion TIFF/page is auto-resolved
            % and curated-away rows are skipped (via CellIntensity.resolveCsvPoints).
            if nargin < 2, opts = struct(); end
            [img, xy, ~, live] = CellIntensity.resolveCsvPoints(csvPath, opts);
            ds = CellIntensityTrainer.buildFromImage(img, xy(live, :), opts);
            ds.source.csv = {char(csvPath)};
        end

        function ds = buildFromCsvList(csvPaths, opts)
            % Pool detections from several locs CSVs into one dataset. MaxTiles
            % / Shuffle are applied across the pool (not per CSV), so you can
            % cap a balanced labelling session at, e.g., 1160 tiles total.
            if nargin < 2, opts = struct(); end
            csvPaths = cellstr(string(csvPaths));
            % Build each CSV without per-file capping; cap the pool afterwards.
            perOpts = opts;
            perOpts.MaxTiles = Inf;
            perOpts.Shuffle  = false;

            parts = cell(1, numel(csvPaths));
            for k = 1:numel(csvPaths)
                try
                    parts{k} = CellIntensityTrainer.buildFromCsv(csvPaths{k}, perOpts);
                catch err
                    warning('CellIntensityTrainer:csvSkipped', ...
                        'Skipping "%s": %s', csvPaths{k}, err.message);
                end
            end
            parts = parts(~cellfun(@isempty, parts));
            assert(~isempty(parts), 'CellIntensityTrainer:emptyPool', ...
                'No usable tiles from any CSV.');

            ds = CellIntensityTrainer.concatDatasets(parts);

            % Apply pool-wide Shuffle / MaxTiles.
            shuf = CellIntensityTrainer.optOr(opts, 'Shuffle',  false);
            maxT = CellIntensityTrainer.optOr(opts, 'MaxTiles', Inf);
            n = numel(ds.tiles);
            order = 1:n;
            if shuf, order = randperm(n); end
            if maxT < numel(order), order = order(1:maxT); end
            ds = CellIntensityTrainer.subsetDataset(ds, order);
        end

        function mask = proposeMask(tile, thrMult, keepCentre)
            % Auto-propose a cell mask by Otsu thresholding the tile, scaled by
            % thrMult (>1 = stricter/smaller, <1 = looser/larger), then reduced
            % to the central connected component.
            if nargin < 2 || isempty(thrMult),   thrMult = 1.0;  end
            if nargin < 3 || isempty(keepCentre), keepCentre = true; end
            t   = CellIntensityTrainer.toUnit(tile);
            lvl = min(max(graythresh(t) * thrMult, 0), 1);
            mask = t > lvl;
            if keepCentre
                mask = CellIntensity.keepCentreComponent(mask);
            end
        end

    end

    %% ===================================================================
    %  Training / persistence
    %  ===================================================================
    methods (Static)

        function model = train(ds, opts)
            % Train a CellIntensity classifier from the INCLUDED tiles of a
            % dataset. opts is forwarded to CellIntensity.trainClassifier
            % (PixelsPerTile, NumTrees, Balanced).
            if nargin < 2, opts = struct(); end
            inc = logical(ds.included);
            assert(any(inc), 'CellIntensityTrainer:noIncluded', ...
                'No tiles are included — nothing to train on.');
            model = CellIntensity.trainClassifier(ds.tiles(inc), ds.masks(inc), opts);
        end

        function saveDataset(ds, path)
            % Save a dataset struct to a MAT file (variable name 'dataset').
            dataset = ds;
            save(char(path), 'dataset', '-v7.3');
        end

        function ds = loadDataset(path)
            % Load a dataset struct previously saved with saveDataset.
            s = load(char(path), 'dataset');
            ds = CellIntensityTrainer.normaliseDataset(s.dataset);
        end

    end

    %% ===================================================================
    %  GUI construction
    %  ===================================================================
    methods (Access = private)

        function buildUI(app)
            n = numel(app.Dataset.tiles);
            app.Fig = uifigure('Name', 'CellIntensity — training-data builder', ...
                'Position', [100 100 900 620], ...
                'WindowKeyPressFcn', @(~, e) app.onKey(e));

            outer = uigridlayout(app.Fig, [1 2]);
            outer.ColumnWidth = {'1x', 260};
            outer.RowHeight   = {'1x'};

            app.Ax = uiaxes(outer);
            app.Ax.Layout.Row = 1; app.Ax.Layout.Column = 1;
            disableDefaultInteractivity(app.Ax);
            app.ImgH = imshow(zeros(2, 2, 3), 'Parent', app.Ax);
            axis(app.Ax, 'image'); app.Ax.XTick = []; app.Ax.YTick = [];

            % ---- control panel ------------------------------------------
            panel = uigridlayout(outer, [13 2]);
            panel.Layout.Row = 1; panel.Layout.Column = 2;
            panel.RowHeight = repmat({'fit'}, 1, 13);
            panel.ColumnWidth = {'1x', '1x'};

            app.TitleLabel = uilabel(panel, 'Text', sprintf('Tile 1 / %d', n), ...
                'FontWeight', 'bold', 'FontSize', 14);
            app.TitleLabel.Layout.Row = 1; app.TitleLabel.Layout.Column = [1 2];

            app.StatsLabel = uilabel(panel, 'Text', 'cell pixels: 0');
            app.StatsLabel.Layout.Row = 2; app.StatsLabel.Layout.Column = [1 2];

            app.ThrLabel = uilabel(panel, 'Text', 'Threshold x1.00');
            app.ThrLabel.Layout.Row = 3; app.ThrLabel.Layout.Column = [1 2];

            app.ThrSlider = uislider(panel, 'Limits', [0.3 2.0], 'Value', 1.0, ...
                'MajorTicks', [0.3 1 2], ...
                'ValueChangingFcn', @(~, e) app.onThreshold(e.Value), ...
                'Tooltip', 'Otsu multiplier  (keys: - / + )');
            app.ThrSlider.Layout.Row = 4; app.ThrSlider.Layout.Column = [1 2];

            addBtn = uibutton(panel, 'Text', 'Add (A)', ...
                'ButtonPushedFcn', @(~, ~) app.onDraw(true), ...
                'Tooltip', 'Freehand-draw an addition to the cell mask');
            addBtn.Layout.Row = 5; addBtn.Layout.Column = 1;
            eraseBtn = uibutton(panel, 'Text', 'Erase (E)', ...
                'ButtonPushedFcn', @(~, ~) app.onDraw(false), ...
                'Tooltip', 'Freehand-draw a region to remove from the mask');
            eraseBtn.Layout.Row = 5; eraseBtn.Layout.Column = 2;

            resetBtn = uibutton(panel, 'Text', 'Reset auto (R)', ...
                'ButtonPushedFcn', @(~, ~) app.onReset(), ...
                'Tooltip', 'Recompute the mask from the current threshold');
            resetBtn.Layout.Row = 6; resetBtn.Layout.Column = 1;
            clearBtn = uibutton(panel, 'Text', 'Clear (C)', ...
                'ButtonPushedFcn', @(~, ~) app.onClear(), ...
                'Tooltip', 'Empty the mask (exclude all pixels)');
            clearBtn.Layout.Row = 6; clearBtn.Layout.Column = 2;

            app.KeepCentreBox = uicheckbox(panel, ...
                'Text', 'Keep central component', ...
                'Value', app.Dataset.source.keepCentre, ...
                'ValueChangedFcn', @(~, ~) app.onReset(), ...
                'Tooltip', 'Auto-proposals keep only the cell nearest the centre');
            app.KeepCentreBox.Layout.Row = 7; app.KeepCentreBox.Layout.Column = [1 2];

            app.IncludeBox = uicheckbox(panel, 'Text', 'Include this tile (I)', ...
                'Value', true, ...
                'ValueChangedFcn', @(~, e) app.onInclude(e.Value));
            app.IncludeBox.Layout.Row = 8; app.IncludeBox.Layout.Column = [1 2];

            prevBtn = uibutton(panel, 'Text', '◀ Prev', ...
                'ButtonPushedFcn', @(~, ~) app.step(-1));
            prevBtn.Layout.Row = 9; prevBtn.Layout.Column = 1;
            nextBtn = uibutton(panel, 'Text', 'Next ▶', ...
                'ButtonPushedFcn', @(~, ~) app.step(1));
            nextBtn.Layout.Row = 9; nextBtn.Layout.Column = 2;

            app.ProgressLabel = uilabel(panel, 'Text', '', ...
                'HorizontalAlignment', 'center');
            app.ProgressLabel.Layout.Row = 10; app.ProgressLabel.Layout.Column = [1 2];

            saveBtn = uibutton(panel, 'Text', 'Save dataset…', ...
                'ButtonPushedFcn', @(~, ~) app.onSaveDataset());
            saveBtn.Layout.Row = 11; saveBtn.Layout.Column = [1 2];

            trainBtn = uibutton(panel, 'Text', 'Train model…', ...
                'FontWeight', 'bold', ...
                'ButtonPushedFcn', @(~, ~) app.onTrain());
            trainBtn.Layout.Row = 12; trainBtn.Layout.Column = [1 2];

            help = uilabel(panel, 'WordWrap', 'on', 'FontSize', 11, ...
                'Text', ['Shortcuts:  Space/→ accept & next · ← prev · ' ...
                         'A add · E erase · R reset · C clear · I include · ' ...
                         '+/- threshold']);
            help.Layout.Row = 13; help.Layout.Column = [1 2];
        end

    end

    %% ===================================================================
    %  GUI callbacks
    %  ===================================================================
    methods (Access = private)

        function showTile(app, idx)
            n = numel(app.Dataset.tiles);
            app.Idx = min(max(idx, 1), n);
            i = app.Idx;
            app.render();
            app.ThrSlider.Value   = app.Dataset.thrMult(i);
            app.ThrLabel.Text     = sprintf('Threshold x%.2f', app.Dataset.thrMult(i));
            app.IncludeBox.Value  = app.Dataset.included(i);
            app.TitleLabel.Text   = sprintf('Tile %d / %d', i, n);
        end

        function render(app)
            i    = app.Idx;
            tile = app.Dataset.tiles{i};
            mask = app.Dataset.masks{i};
            app.ImgH.CData = CellIntensityTrainer.overlayRGB(tile, mask, app.Alpha);
            app.ImgH.XData = [1 size(tile, 2)];
            app.ImgH.YData = [1 size(tile, 1)];
            app.StatsLabel.Text = sprintf('cell pixels: %d', nnz(mask));
            app.ProgressLabel.Text = sprintf('included: %d / %d', ...
                nnz(app.Dataset.included), numel(app.Dataset.included));
        end

        function onThreshold(app, val)
            i = app.Idx;
            app.Dataset.thrMult(i) = val;
            app.ThrLabel.Text = sprintf('Threshold x%.2f', val);
            app.Dataset.masks{i} = CellIntensityTrainer.proposeMask( ...
                app.Dataset.tiles{i}, val, app.KeepCentreBox.Value);
            app.Dataset.edited(i) = false;
            app.render();
        end

        function onReset(app)
            i = app.Idx;
            app.Dataset.masks{i} = CellIntensityTrainer.proposeMask( ...
                app.Dataset.tiles{i}, app.Dataset.thrMult(i), app.KeepCentreBox.Value);
            app.Dataset.edited(i) = false;
            app.render();
        end

        function onClear(app)
            i = app.Idx;
            app.Dataset.masks{i} = false(size(app.Dataset.tiles{i}));
            app.Dataset.edited(i) = true;
            app.render();
        end

        function onDraw(app, addMode)
            % Freehand-draw a region and OR it into (add) or remove it from
            % (erase) the current mask.
            if app.Busy, return; end
            app.Busy = true;
            cleanup = onCleanup(@() app.clearBusy());
            try
                roi = drawfreehand(app.Ax, 'Color', ...
                    CellIntensityTrainer.ternary(addMode, [0 1 0], [1 1 0]));
                if isempty(roi) || ~isvalid(roi) || isempty(roi.Position)
                    if ~isempty(roi) && isvalid(roi), delete(roi); end
                    return;
                end
                region = createMask(roi, app.ImgH);
                delete(roi);
                i = app.Idx;
                m = app.Dataset.masks{i};
                if addMode
                    m = m | region;
                else
                    m = m & ~region;
                end
                app.Dataset.masks{i} = m;
                app.Dataset.edited(i) = true;
                app.render();
            catch err
                if ~strcmp(err.identifier, 'images:roi:cancelled')
                    rethrow(err);
                end
            end
        end

        function clearBusy(app)
            app.Busy = false;
        end

        function onInclude(app, val)
            app.Dataset.included(app.Idx) = logical(val);
            app.render();
        end

        function step(app, delta)
            app.showTile(app.Idx + delta);
        end

        function onKey(app, e)
            switch e.Key
                case {'rightarrow', 'space', 'd'}
                    app.step(1);
                case {'leftarrow', 'a'}
                    % 'a' is Add when not also navigation; arrow handles nav.
                    if strcmp(e.Key, 'leftarrow')
                        app.step(-1);
                    else
                        app.onDraw(true);
                    end
                case 'e'
                    app.onDraw(false);
                case 'r'
                    app.onReset();
                case 'c'
                    app.onClear();
                case 'i'
                    app.IncludeBox.Value = ~app.IncludeBox.Value;
                    app.onInclude(app.IncludeBox.Value);
                case {'equal', 'add', 'hyphen', 'subtract'}
                    d = CellIntensityTrainer.ternary( ...
                        any(strcmp(e.Key, {'equal', 'add'})), 0.05, -0.05);
                    v = min(max(app.ThrSlider.Value + d, 0.3), 2.0);
                    app.ThrSlider.Value = v;
                    app.onThreshold(v);
            end
        end

        function onSaveDataset(app)
            [f, p] = uiputfile('*.mat', 'Save training dataset', ...
                'cellintensity_trainset.mat');
            if isequal(f, 0), return; end
            CellIntensityTrainer.saveDataset(app.Dataset, fullfile(p, f));
            uialert(app.Fig, sprintf('Saved %d tiles (%d included).', ...
                numel(app.Dataset.tiles), nnz(app.Dataset.included)), ...
                'Saved', 'Icon', 'success');
        end

        function onTrain(app)
            if ~any(app.Dataset.included)
                uialert(app.Fig, 'No tiles are included.', 'Nothing to train');
                return;
            end
            d = uiprogressdlg(app.Fig, 'Title', 'Training', ...
                'Message', 'Training random-forest pixel classifier…', ...
                'Indeterminate', 'on');
            cleanup = onCleanup(@() delete(d));
            try
                model = CellIntensityTrainer.train(app.Dataset);
            catch err
                uialert(app.Fig, err.message, 'Training failed');
                return;
            end
            delete(d); clear cleanup;

            [f, p] = uiputfile('*.mat', 'Save trained model', ...
                'cellintensity_rf.mat');
            if isequal(f, 0), return; end
            save(fullfile(p, f), 'model');
            uialert(app.Fig, sprintf(['Trained on %d tiles and saved the model.' ...
                '\nUse it with CellIntensity.measureFromCsv(model, csv).'], ...
                nnz(app.Dataset.included)), 'Done', 'Icon', 'success');
        end

    end

    %% ===================================================================
    %  Dataset helpers
    %  ===================================================================
    methods (Static, Access = private)

        function ds = makeDataset(tiles, masks, sz, thr, keep)
            n = numel(tiles);
            ds = struct();
            ds.tiles    = tiles(:)';
            ds.masks    = masks(:)';
            ds.included = true(1, n);
            ds.thrMult  = repmat(thr, 1, n);
            ds.edited   = false(1, n);
            ds.tileSize = sz;
            ds.source   = struct('keepCentre', logical(keep), 'csv', {{}});
        end

        function ds = normaliseDataset(ds)
            % Fill in any missing fields so older/hand-built datasets load.
            n = numel(ds.tiles);
            if ~isfield(ds, 'masks'),    ds.masks    = repmat({false(CellIntensity.TileSize)}, 1, n); end
            if ~isfield(ds, 'included'), ds.included = true(1, n);  end
            if ~isfield(ds, 'thrMult'),  ds.thrMult  = ones(1, n);  end
            if ~isfield(ds, 'edited'),   ds.edited   = false(1, n); end
            if ~isfield(ds, 'tileSize'), ds.tileSize = CellIntensity.TileSize; end
            if ~isfield(ds, 'source'),   ds.source   = struct(); end
            if ~isfield(ds.source, 'keepCentre'), ds.source.keepCentre = true; end
            ds.included = logical(ds.included);
            ds.edited   = logical(ds.edited);
        end

        function ds = concatDatasets(parts)
            ds = parts{1};
            for k = 2:numel(parts)
                p = parts{k};
                ds.tiles    = [ds.tiles,    p.tiles];
                ds.masks    = [ds.masks,    p.masks];
                ds.included = [ds.included, p.included];
                ds.thrMult  = [ds.thrMult,  p.thrMult];
                ds.edited   = [ds.edited,   p.edited];
                if isfield(p.source, 'csv')
                    ds.source.csv = [ds.source.csv, p.source.csv];
                end
            end
        end

        function ds = subsetDataset(ds, idx)
            ds.tiles    = ds.tiles(idx);
            ds.masks    = ds.masks(idx);
            ds.included = ds.included(idx);
            ds.thrMult  = ds.thrMult(idx);
            ds.edited   = ds.edited(idx);
        end

    end

    %% ===================================================================
    %  Small image / value utilities
    %  ===================================================================
    methods (Static, Access = private)

        function rgb = overlayRGB(tile, mask, alpha)
            % Grayscale tile with the mask painted as a translucent red layer.
            t = CellIntensityTrainer.toUnit(tile);
            r = t; g = t; b = t;
            if any(mask(:))
                r(mask) = (1 - alpha) .* r(mask) + alpha * 1;
                g(mask) = (1 - alpha) .* g(mask);
                b(mask) = (1 - alpha) .* b(mask);
            end
            rgb = cat(3, r, g, b);
        end

        function u = toUnit(img)
            if islogical(img), u = double(img); return; end
            switch class(img)
                case 'uint8',  u = double(img) / 255;
                case 'uint16', u = double(img) / 65535;
                otherwise
                    u = double(img);
                    mx = max(u(:));
                    if mx > 1, u = u / mx; end
            end
        end

        function g = toGray(img)
            if ndims(img) == 3 && size(img, 3) == 3
                g = rgb2gray(img);
            else
                g = img;
            end
        end

        function v = optOr(s, name, default)
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

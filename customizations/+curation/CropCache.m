classdef CropCache < handle
    %CropCache  Every crop of one source, extracted once; composing a page of tiles is then array indexing.
    %
    %   c = curation.CropCache.build(pageT, pageC, ids, xy, umPerPx, Name=Value)
    %       pageT    target page (H x W numeric, any class and scale)
    %       pageC    companion page of the same size, or [] for none
    %       ids      N x 1 CellIDs (non-negative integers, unique; stored as uint32)
    %       xy       N x 2 [X Y] in full-resolution pixels: X is the column, Y the row, pixel centres at
    %                integers (round(X), round(Y) index the page, as in the legacy QC app)
    %       umPerPx  page pixel size in micrometres
    %     Options
    %       WindowUm         side of the square window around each cell, in micrometres (default 44: what
    %                        the scoring network sees)
    %       TilePx           tile side in pixels (default 80): the window is resampled to TilePx x TilePx
    %       Percentiles      [low high] page percentiles mapped to 0 and 255 (default [1 99.9]); computed
    %                        once per page over a subsample of it, NOT per tile
    %       PerTileContrast  true: stretch each tile to its own percentiles instead (default false; makes
    %                        noise look like cells, so only for special uses)
    %       Kernel           "cubic" (default) or "linear" interpolation; anti-aliased when the window has
    %                        more pixels than the tile
    %       MaxSamples       page pixels sampled for the percentiles (default 1e6)
    %
    %   The crops of all N cells are sampled from the page with sub-pixel interpolation, directly at tile
    %   resolution, in one vectorised pass per chunk of cells (separable kernels applied with pagemtimes),
    %   converted to uint8 with the page's fixed limits and kept for both channels. Outside the page the
    %   tile is 0 (black); TouchesBorder says which windows reach past the page edge.
    %
    %   c.update(ids, xy)    re-extract the crops of moved cells (the cache keeps the two pages)
    %   c.add(ids, xy)       add cells;   c.remove(ids)   drop cells
    %   rows = c.rowsOf(ids) cache rows of IDS (0 where unknown)
    %
    %   [mosaic, layout] = c.compose(ids, nRows, nCols, style)
    %       A page of tiles, row-major (tile k is at row ceil(k/nCols), column k-(row-1)*nCols); unknown
    %       or 0 ids and slots after numel(ids) are drawn in the background colour.
    %       style (struct; every field optional):
    %         Mode        "target" | "companion" | "overlay" (target green, companion magenta) |
    %                     "side" (target | companion: tiles twice as wide)
    %         Gain, Gamma display = min(1, Gain*v)^Gamma on v in [0 1] (Gamma < 1 brightens); scalar or
    %                     [target companion]
    %         LUT         256 x 1 or 256 x 2 lookup table (uint8, or double 0-255) used instead of Gain/Gamma
    %         BorderRGB   K x 3 (or 1 x 3) border colours, uint8 or double 0-255; NaN rows: no border
    %         BorderPx    border width in pixels, drawn inside the tile (default 3)
    %         CornerRGB   K x 3 corner badge colours (top right, inside the border); NaN rows: no badge
    %         CornerPx    badge side in pixels (default round(TilePx/8))
    %         Dim         K x 1 logical: draw the tile dimmed (DimFactor of its brightness, default 0.4)
    %         Gap         pixels between tiles (default 0)
    %         Background  [r g b] (uint8 or double 0-255) for gaps and empty slots (default [24 24 24])
    %       mosaic  uint8 RGB, ready for an image's CData
    %       layout  struct: NRows NCols TileH TileW Gap Size([H W]) K S Ids Rows Rect(S x 4 [x y w h], x the
    %               first column, y the first row, 1-based mosaic pixels) Mode BorderPx CacheVersion
    %
    %   mosaic = c.repaint(mosaic, layout, tileIdx, style)
    %       Redraw tiles TILEIDX of a composed page with STYLE (a page style: K rows, indexed by tile
    %       number); equals compose with STYLE when only those tiles' styling changed.
    %
    %   See also curation.GalleryView.

    properties (SetAccess = private)
        Ids (:,1) uint32 = zeros(0, 1, 'uint32')   % CellID of each cached crop (one per row)
        XY (:,2) double = zeros(0, 2)              % [X Y] each crop was extracted at
        TouchesBorder (:,1) logical = false(0, 1)  % the window reaches past the page edge
        Limits (2,2) double = NaN(2, 2)            % [low high] page units; row 1 target, row 2 companion
        TilePx (1,1) double = 80
        WindowUm (1,1) double = 44
        UmPerPx (1,1) double = 1
        Percentiles (1,2) double = [1 99.9]
        PerTileContrast (1,1) logical = false
        Kernel (1,1) string = "cubic"
        HasCompanion (1,1) logical = false
        Version (1,1) double = 0                   % bumped by update, add and remove
        Crops = zeros(80, 80, 0, 'uint8')          % TilePx x TilePx x N uint8, target channel
        CropsC = zeros(80, 80, 0, 'uint8')         % the same for the companion channel (N = 0 without one)
    end

    properties (Dependent)
        N           % number of cached cells
        WindowPx    % window side in page pixels
    end

    properties (Access = private)
        PageT = []
        PageC = []
        RowOfId = zeros(0, 1)      % dense lookup: RowOfId(id + 1) = row, 0 = absent
        DenseLookup = true
        Geoms = struct('Key', {}, 'G', {})
    end

    properties (Constant, Access = private)
        ChunkCells = 512           % cells per vectorised extraction pass (bounds memory)
        MaxDenseId = 1e7
    end

    % ------------------------------------------------------------------------------------------------
    methods (Static)
        function c = build(pageT, pageC, ids, xy, umPerPx, opts)
            %build  Extract and cache the crops of every cell of a source (see the class help).
            arguments
                pageT {mustBeNumeric, mustBeReal}
                pageC {mustBeNumeric, mustBeReal}
                ids {mustBeNumeric, mustBeInteger, mustBeNonnegative}
                xy double {mustBeReal}
                umPerPx (1,1) double {mustBePositive, mustBeFinite}
                opts.WindowUm (1,1) double {mustBePositive, mustBeFinite} = 44
                opts.TilePx (1,1) double {mustBeInteger, mustBePositive} = 80
                opts.Percentiles (1,2) double {mustBeNonnegative} = [1 99.9]
                opts.PerTileContrast (1,1) logical = false
                opts.Kernel (1,1) string {mustBeMember(opts.Kernel, ["cubic" "linear"])} = "cubic"
                opts.MaxSamples (1,1) double {mustBePositive} = 1e6
            end
            if ~ismatrix(pageT) || isempty(pageT)
                error('CropCache:BadPage', 'The target page must be a non-empty H x W matrix.');
            end
            if ~isempty(pageC) && ~isequal(size(pageC), size(pageT))
                error('CropCache:BadPage', 'The companion page must be [] or the size of the target page (%d x %d).', ...
                    size(pageT, 1), size(pageT, 2));
            end
            if opts.Percentiles(2) <= opts.Percentiles(1) || opts.Percentiles(2) > 100
                error('CropCache:BadPercentiles', 'Percentiles must be [low high] with 0 <= low < high <= 100.');
            end
            [ids, xy] = curation.CropCache.checkCells(ids, xy);
            if numel(unique(ids)) ~= numel(ids)
                error('CropCache:DuplicateIds', 'CellIDs must be unique.');
            end

            c = curation.CropCache();
            c.PageT = pageT;
            c.PageC = pageC;
            c.HasCompanion = ~isempty(pageC);
            c.TilePx = opts.TilePx;
            c.WindowUm = opts.WindowUm;
            c.UmPerPx = umPerPx;
            c.Percentiles = opts.Percentiles;
            c.PerTileContrast = opts.PerTileContrast;
            c.Kernel = opts.Kernel;
            c.Limits(1, :) = curation.CropCache.pageLimits(pageT, opts.Percentiles, opts.MaxSamples);
            if c.HasCompanion
                c.Limits(2, :) = curation.CropCache.pageLimits(pageC, opts.Percentiles, opts.MaxSamples);
            end
            [c.Crops, c.CropsC, c.TouchesBorder] = c.extract(xy);
            c.Ids = ids;
            c.XY = xy;
            c.rebuildLookup();
        end

        function lim = pageLimits(page, percentiles, maxSamples)
            %pageLimits  [low high] percentiles of PAGE over a regular subsample of at most ~MAXSAMPLES
            %   pixels (prctile's definition). Falls back to [min max] when they coincide.
            if nargin < 3; maxSamples = 1e6; end
            [h, w] = size(page);
            s = max(1, ceil(sqrt(h * w / maxSamples)));
            v = page(1:s:end, 1:s:end);
            v = double(v(:));
            v = v(isfinite(v));
            if isempty(v)
                lim = [0 1];
                return
            end
            lim = curation.CropCache.quantiles(v, percentiles / 100);
            if ~(lim(2) > lim(1))
                lim = [min(v) max(v)];
                if ~(lim(2) > lim(1)); lim = [lim(1) lim(1) + 1]; end
            end
        end
    end

    % ------------------------------------------------------------------------------------------------
    methods
        function n = get.N(obj)
            n = numel(obj.Ids);
        end

        function w = get.WindowPx(obj)
            w = obj.WindowUm / obj.UmPerPx;
        end

        function rows = rowsOf(obj, ids)
            %rowsOf  Cache rows of IDS (same shape as IDS; 0 where an id is not cached).
            sz = size(ids);
            ids = double(ids(:));
            rows = zeros(numel(ids), 1);
            if obj.DenseLookup
                ok = ids >= 0 & ids < numel(obj.RowOfId) & ids == floor(ids);
                rows(ok) = obj.RowOfId(ids(ok) + 1);
            else
                [~, loc] = ismember(ids, double(obj.Ids));
                rows = loc;
            end
            rows = reshape(rows, sz);
        end

        function update(obj, ids, xy)
            %update  Re-extract the crops of cells IDS (already cached) at their new positions XY.
            [ids, xy] = curation.CropCache.checkCells(ids, xy);
            rows = obj.rowsOf(ids);
            if any(rows == 0)
                error('CropCache:UnknownId', 'CellID %d is not in the cache (use add).', ids(find(rows == 0, 1)));
            end
            [a, b, t] = obj.extract(xy);
            obj.Crops(:, :, rows) = a;
            if obj.HasCompanion; obj.CropsC(:, :, rows) = b; end
            obj.TouchesBorder(rows) = t;
            obj.XY(rows, :) = xy;
            obj.Version = obj.Version + 1;
        end

        function add(obj, ids, xy)
            %add  Extract and cache new cells IDS at XY.
            [ids, xy] = curation.CropCache.checkCells(ids, xy);
            if isempty(ids); return; end
            if any(obj.rowsOf(ids) > 0) || numel(unique(ids)) ~= numel(ids)
                error('CropCache:DuplicateIds', 'CellIDs must be new and unique (use update to move a cell).');
            end
            [a, b, t] = obj.extract(xy);
            obj.Crops = cat(3, obj.Crops, a);
            if obj.HasCompanion; obj.CropsC = cat(3, obj.CropsC, b); end
            obj.TouchesBorder = [obj.TouchesBorder; t];
            obj.XY = [obj.XY; xy];
            obj.Ids = [obj.Ids; ids];
            obj.rebuildLookup();
            obj.Version = obj.Version + 1;
        end

        function remove(obj, ids)
            %remove  Drop cells IDS from the cache (unknown ids are ignored).
            rows = obj.rowsOf(ids);
            rows = unique(rows(rows > 0));
            if isempty(rows); return; end
            keep = true(obj.N, 1);
            keep(rows) = false;
            obj.Crops = obj.Crops(:, :, keep);
            if obj.HasCompanion; obj.CropsC = obj.CropsC(:, :, keep); end
            obj.TouchesBorder = obj.TouchesBorder(keep);
            obj.XY = obj.XY(keep, :);
            obj.Ids = obj.Ids(keep);
            obj.rebuildLookup();
            obj.Version = obj.Version + 1;
        end

        function [mosaic, layout] = compose(obj, ids, nRows, nCols, style)
            %compose  A page of tiles as one uint8 RGB image (see the class help).
            if nargin < 5 || isempty(style); style = struct(); end
            ids = ids(:);
            K = numel(ids);
            S = nRows * nCols;
            if K > S
                error('CropCache:TooManyTiles', '%d ids do not fit a %d x %d page.', K, nRows, nCols);
            end
            s = obj.normalizeStyle(style, K);
            [TH, TW] = obj.tileSize(s.Mode);
            g = obj.geometry(nRows, nCols, TH, TW, s.Gap, s.BorderPx, s.CornerPx);
            rows = obj.rowsOf(ids);
            rowsS = [rows; zeros(S - K, 1)];
            dimS = [s.Dim; false(S - K, 1)];
            st = obj.tileStacks(rowsS, s, dimS);

            % stacks (TH x TW x S) -> planes (H x W)
            planes = cell(1, numel(st));
            for i = 1:numel(st)
                if s.Gap == 0
                    planes{i} = reshape(permute(reshape(st{i}, TH, TW, nCols, nRows), [1 4 2 3]), g.H, g.W);
                else
                    p = zeros(g.H, g.W, 'uint8');
                    p(g.TileLin) = st{i};
                    planes{i} = p;
                end
            end
            if s.Mode == "overlay"
                mosaic = cat(3, planes{2}, planes{1}, planes{2});   % companion magenta, target green
            else
                mosaic = cat(3, planes{1}, planes{1}, planes{1});
            end

            % background: gaps and empty slots
            HW = g.H * g.W;
            if s.Gap > 0
                for ch = 1:3
                    mosaic(g.GapLin + (ch - 1) * HW) = s.Background(ch);
                end
            end
            empty = find(rowsS == 0);
            if ~isempty(empty)
                mosaic = obj.paintSlots(mosaic, g, empty, g.TileRel, repmat(s.Background, numel(empty), 1));
            end
            mosaic = obj.paintDecor(mosaic, g, s, (1:K)');

            layout = struct('NRows', nRows, 'NCols', nCols, 'TileH', TH, 'TileW', TW, 'Gap', s.Gap, ...
                'Size', [g.H g.W], 'K', K, 'S', S, 'Ids', uint32(ids), 'Rows', rows, 'Rect', g.Rect, ...
                'Mode', s.Mode, 'BorderPx', s.BorderPx, 'CacheVersion', obj.Version);
        end

        function mosaic = repaint(obj, mosaic, layout, tileIdx, style)
            %repaint  Redraw tiles TILEIDX of a composed page with STYLE (see the class help).
            if nargin < 5 || isempty(style); style = struct(); end
            tileIdx = unique(round(double(tileIdx(:))));
            tileIdx = tileIdx(tileIdx >= 1 & tileIdx <= layout.S);
            if isempty(tileIdx); return; end
            K = layout.K;
            s = obj.normalizeStyle(style, K);
            [TH, TW] = obj.tileSize(s.Mode);
            if TH ~= layout.TileH || TW ~= layout.TileW || s.Gap ~= layout.Gap || ...
                    ~isequal(size(mosaic), [layout.Size 3])
                error('CropCache:LayoutChanged', 'The style changes the page geometry: compose the page again.');
            end
            if numel(tileIdx) > layout.S / 3
                mosaic = obj.compose(layout.Ids, layout.NRows, layout.NCols, style);   % cheaper in one pass
                return
            end
            g = obj.geometry(layout.NRows, layout.NCols, TH, TW, s.Gap, s.BorderPx, s.CornerPx);
            in = tileIdx <= K;
            rowsS = zeros(numel(tileIdx), 1);
            rowsS(in) = obj.rowsOf(layout.Ids(tileIdx(in)));
            dimS = false(numel(tileIdx), 1);
            dimS(in) = s.Dim(tileIdx(in));
            st = obj.tileStacks(rowsS, s, dimS);
            for j = 1:numel(tileIdx)
                r = g.Rect(tileIdx(j), :);
                ys = r(2):(r(2) + TH - 1);
                xs = r(1):(r(1) + TW - 1);
                if rowsS(j) == 0
                    for ch = 1:3; mosaic(ys, xs, ch) = s.Background(ch); end
                elseif s.Mode == "overlay"
                    mosaic(ys, xs, 1) = st{2}(:, :, j);
                    mosaic(ys, xs, 2) = st{1}(:, :, j);
                    mosaic(ys, xs, 3) = st{2}(:, :, j);
                else
                    blk = st{1}(:, :, j);
                    mosaic(ys, xs, 1) = blk;
                    mosaic(ys, xs, 2) = blk;
                    mosaic(ys, xs, 3) = blk;
                end
            end
            mosaic = obj.paintDecor(mosaic, g, s, tileIdx(in));
        end

        function [TH, TW] = tileSize(obj, mode)
            %tileSize  Tile height and width in pixels for display MODE ("side" tiles are twice as wide).
            TH = obj.TilePx;
            TW = obj.TilePx;
            if nargin > 1 && string(mode) == "side"; TW = 2 * obj.TilePx; end
        end

        function s = normalizeStyle(obj, style, K)
            %normalizeStyle  STYLE with every field filled in and checked, for a page of K tiles.
            %   Adds Lut (256 x 2 uint8: target, companion), LutIdentity (1 x 2) and DimLut.
            if nargin < 2 || isempty(style); style = struct(); end
            if ~isstruct(style) || ~isscalar(style)
                error('CropCache:BadStyle', 'style must be a scalar struct.');
            end
            s = struct('Mode', "target", 'Gain', 1, 'Gamma', 1, 'LUT', [], 'BorderRGB', [], 'BorderPx', 3, ...
                'CornerRGB', [], 'CornerPx', max(2, round(obj.TilePx / 8)), 'Dim', [], 'DimFactor', 0.4, ...
                'Gap', 0, 'Background', [24 24 24]);
            f = fieldnames(style);
            for i = 1:numel(f)
                if ~isfield(s, f{i})
                    error('CropCache:BadStyle', 'Unknown style field "%s".', f{i});
                end
                if ~isempty(style.(f{i}))       % empty = the default
                    s.(f{i}) = style.(f{i});
                end
            end
            s.Mode = lower(string(s.Mode));
            if ~any(s.Mode == ["target" "companion" "overlay" "side"])
                error('CropCache:BadStyle', 'Mode must be target, companion, overlay or side (got "%s").', s.Mode);
            end
            s.BorderPx = max(0, round(double(s.BorderPx)));
            s.CornerPx = max(0, round(double(s.CornerPx)));
            s.Gap = max(0, round(double(s.Gap)));
            [TH, TW] = obj.tileSize(s.Mode);
            s.BorderPx = min(s.BorderPx, floor(min(TH, TW) / 2));
            s.CornerPx = min(s.CornerPx, min(TH, TW) - 2 * s.BorderPx);
            s.Background = uint8(reshape(double(s.Background), 1, 3));
            s.BorderRGB = curation.CropCache.perTileColours(s.BorderRGB, K, 'BorderRGB');
            s.CornerRGB = curation.CropCache.perTileColours(s.CornerRGB, K, 'CornerRGB');
            if isempty(s.Dim)
                s.Dim = false(K, 1);
            elseif isscalar(s.Dim)
                s.Dim = repmat(logical(s.Dim), K, 1);
            elseif numel(s.Dim) == K
                s.Dim = logical(s.Dim(:));
            else
                error('CropCache:BadStyle', 'Dim must be empty, scalar or have one entry per tile (%d).', K);
            end

            % display lookup tables
            if ~isempty(s.LUT)
                lut = double(s.LUT);
                if size(lut, 1) ~= 256 && numel(lut) == 256; lut = lut(:); end
                if size(lut, 1) ~= 256 || size(lut, 2) > 2
                    error('CropCache:BadStyle', 'LUT must be 256 x 1 or 256 x 2.');
                end
                if size(lut, 2) == 1; lut = [lut lut]; end
                s.Lut = uint8(lut);
            else
                gain = double(s.Gain(:)');
                gam = double(s.Gamma(:)');
                if isscalar(gain); gain = [gain gain]; end
                if isscalar(gam); gam = [gam gam]; end
                if numel(gain) ~= 2 || numel(gam) ~= 2 || any(gain < 0) || any(gam <= 0)
                    error('CropCache:BadStyle', 'Gain (>= 0) and Gamma (> 0) must be scalars or [target companion].');
                end
                x = (0:255)' / 255;
                s.Lut = uint8(255 * min(1, max(0, x * gain)) .^ gam);
            end
            ident = uint8(0:255)';
            s.LutIdentity = [isequal(s.Lut(:, 1), ident) isequal(s.Lut(:, 2), ident)];
            s.DimLut = uint8(double(ident) * min(1, max(0, double(s.DimFactor))));
        end
    end

    % ------------------------------------------------------------------------------------------------
    methods (Access = private)
        function obj = CropCache()
            % use curation.CropCache.build
        end

        function rebuildLookup(obj)
            ids = double(obj.Ids);
            if isempty(ids)
                obj.RowOfId = zeros(0, 1);
                obj.DenseLookup = true;
                return
            end
            if max(ids) <= obj.MaxDenseId
                lk = zeros(max(ids) + 1, 1);
                lk(ids + 1) = 1:numel(ids);
                obj.RowOfId = lk;
                obj.DenseLookup = true;
            else
                obj.RowOfId = zeros(0, 1);
                obj.DenseLookup = false;
            end
        end

        function [A, B, touches] = extract(obj, xy)
            %extract  uint8 crops (TilePx x TilePx x n) of both channels at the positions XY.
            n = size(xy, 1);
            T = obj.TilePx;
            A = zeros(T, T, n, 'uint8');
            if obj.HasCompanion
                B = zeros(T, T, n, 'uint8');
            else
                B = zeros(T, T, 0, 'uint8');
            end
            touches = false(n, 1);
            [H, W] = size(obj.PageT);
            for s0 = 1:obj.ChunkCells:n
                r = s0:min(n, s0 + obj.ChunkCells - 1);
                [Wy, iy, inY] = obj.axisWeights(xy(r, 2)', H);
                [Wx, ix, inX] = obj.axisWeights(xy(r, 1)', W);
                inside = [];
                if ~all(inY, 'all') || ~all(inX, 'all')
                    m = numel(r);
                    inside = uint8(reshape(inY, T, 1, m) & reshape(inX, 1, T, m));
                    touches(r) = ~all(inY, 1)' | ~all(inX, 1)';
                end
                A(:, :, r) = obj.sample(obj.PageT, Wy, Wx, iy, ix, inside, obj.Limits(1, :));
                if obj.HasCompanion
                    B(:, :, r) = obj.sample(obj.PageC, Wy, Wx, iy, ix, inside, obj.Limits(2, :));
                end
            end
        end

        function [Wt, idx, inside] = axisWeights(obj, c, nPix)
            %axisWeights  Interpolation weights along one axis for cells centred at C (1 x m).
            %   Wt: T x h x m (sample j of cell n = sum_i Wt(j,i,n) * pixel idx(i,n)); idx: h x m page
            %   indices clamped to 1..nPix; inside: T x m, the sample lies on the page.
            T = obj.TilePx;
            step = obj.WindowPx / T;              % page pixels per tile pixel
            sc = max(1, step);                    % kernel stretch: anti-alias when shrinking
            if obj.Kernel == "cubic"; support = 2; else; support = 1; end
            R = support * sc;
            off = ((1:T)' - (T + 1) / 2) * step;  % T x 1, the tile centre is on the cell
            m = numel(c);
            u = c + off;                          % T x m sample positions (page coordinates)
            p0 = floor(u(1, :) - R);              % first page pixel of each cell's patch
            h = ceil((T - 1) * step + 2 * R) + 2;
            pix = p0 + (0:h - 1)';                % h x m
            d = (reshape(u, T, 1, m) - reshape(pix, 1, h, m)) / sc;
            if obj.Kernel == "cubic"
                a = abs(d);
                a2 = a .* a;
                a3 = a2 .* a;
                Wt = (1.5 * a3 - 2.5 * a2 + 1) .* (a <= 1) + (-0.5 * a3 + 2.5 * a2 - 4 * a + 2) .* (a > 1 & a < 2);
            else
                Wt = max(0, 1 - abs(d));
            end
            Wt = Wt ./ sum(Wt, 2);
            idx = min(max(pix, 1), nPix);
            inside = u >= 0.5 & u <= nPix + 0.5;
        end

        function U = sample(obj, page, Wy, Wx, iy, ix, inside, lim)
            %sample  uint8 tiles (T x T x m) of PAGE: Wy * patch * Wx' per cell, scaled by LIM.
            H = size(page, 1);
            [h, m] = size(iy);
            lin = reshape(iy, h, 1, m) + (reshape(ix, 1, h, m) - 1) * H;
            P = double(page(lin));
            if ~allfinite(P); P(~isfinite(P)) = lim(1); end
            V = pagemtimes(pagemtimes(Wy, P), 'none', Wx, 'transpose');
            if obj.PerTileContrast
                T = size(V, 1);
                v = sort(reshape(V, T * T, m), 1);
                q = obj.Percentiles / 100;
                pos = min(max(T * T * q + 0.5, 1), T * T);
                lo = v(floor(pos(1)), :) + (pos(1) - floor(pos(1))) * (v(min(T * T, floor(pos(1)) + 1), :) - v(floor(pos(1)), :));
                hi = v(floor(pos(2)), :) + (pos(2) - floor(pos(2))) * (v(min(T * T, floor(pos(2)) + 1), :) - v(floor(pos(2)), :));
                span = hi - lo;
                span(~(span > 0)) = 1;
                U = uint8((V - reshape(lo, 1, 1, m)) .* reshape(255 ./ span, 1, 1, m));
            else
                U = uint8((V - lim(1)) * (255 / (lim(2) - lim(1))));
            end
            if ~isempty(inside); U = U .* inside; end
        end

        function st = tileStacks(obj, rowsS, s, dimS)
            %tileStacks  The tiles of slots ROWSS (cache rows, 0 = empty) as uint8 stacks with the
            %   display LUT and dimming applied: {target} / {companion} / {target, companion} / {side}.
            useT = s.Mode ~= "companion";
            useC = s.Mode ~= "target";
            st = {};
            if useT
                st{end + 1} = obj.applyLut(obj.gather(obj.Crops, rowsS), s.Lut(:, 1), s.LutIdentity(1));
            end
            if useC
                if obj.HasCompanion
                    st{end + 1} = obj.applyLut(obj.gather(obj.CropsC, rowsS), s.Lut(:, 2), s.LutIdentity(2));
                elseif s.Mode == "companion"
                    st{end + 1} = obj.applyLut(obj.gather(obj.Crops, rowsS), s.Lut(:, 1), s.LutIdentity(1));
                else
                    st{end + 1} = zeros(obj.TilePx, obj.TilePx, numel(rowsS), 'uint8');
                end
            end
            if s.Mode == "side"
                st = {cat(2, st{1}, st{2})};
            end
            if any(dimS)
                for i = 1:numel(st)
                    st{i}(:, :, dimS) = curation.CropCache.lut8(st{i}(:, :, dimS), s.DimLut);
                end
            end
        end

        function A = gather(obj, crops, rowsS)
            v = rowsS > 0;
            if all(v)
                A = crops(:, :, rowsS);
            else
                T = obj.TilePx;
                A = zeros(T, T, numel(rowsS), 'uint8');
                A(:, :, v) = crops(:, :, rowsS(v));
            end
        end

        function A = applyLut(~, A, lut, isIdentity)
            if ~isIdentity
                A = curation.CropCache.lut8(A, lut);
            end
        end

        function mosaic = paintDecor(obj, mosaic, g, s, slots)
            %paintDecor  Border frames and corner badges of tiles SLOTS (indices <= K).
            if isempty(slots); return; end
            if s.BorderPx > 0 && ~isempty(g.FrameRel)
                col = s.BorderRGB(slots, :);
                ok = ~isnan(col(:, 1));
                if any(ok)
                    mosaic = obj.paintSlots(mosaic, g, slots(ok), g.FrameRel, col(ok, :));
                end
            end
            if s.CornerPx > 0 && ~isempty(g.CornerRel)
                col = s.CornerRGB(slots, :);
                ok = ~isnan(col(:, 1));
                if any(ok)
                    mosaic = obj.paintSlots(mosaic, g, slots(ok), g.CornerRel, col(ok, :));
                end
            end
        end

        function g = geometry(obj, nRows, nCols, TH, TW, gap, bpx, cpx)
            %geometry  Index tables of a page geometry (cached; a few geometries are kept).
            key = [nRows nCols TH TW gap bpx cpx];
            for i = 1:numel(obj.Geoms)
                if isequal(obj.Geoms(i).Key, key)
                    g = obj.Geoms(i).G;
                    return
                end
            end
            H = nRows * TH + (nRows - 1) * gap;
            W = nCols * TW + (nCols - 1) * gap;
            S = nRows * nCols;
            k = (1:S)';
            r = ceil(k / nCols);
            cc = k - (r - 1) * nCols;
            y0 = (r - 1) * (TH + gap) + 1;
            x0 = (cc - 1) * (TW + gap) + 1;
            g.H = H;
            g.W = W;
            g.Rect = [x0 y0 repmat(TW, S, 1) repmat(TH, S, 1)];
            g.SlotBase = (y0 + (x0 - 1) * H)';                 % 1 x S: top-left pixel of each slot
            [ii, jj] = ndgrid(0:TH - 1, 0:TW - 1);
            rel = ii + jj * H;                                 % offsets of a tile's pixels in the plane
            g.TileRel = rel(:);
            g.FrameRel = rel(ii < bpx | ii >= TH - bpx | jj < bpx | jj >= TW - bpx);
            g.CornerRel = rel(ii >= bpx & ii < bpx + cpx & jj >= TW - bpx - cpx & jj < TW - bpx);
            if gap > 0
                g.TileLin = reshape(g.TileRel + g.SlotBase, [], 1);
                isTile = false(H, W);
                isTile(g.TileLin) = true;
                g.GapLin = find(~isTile);
            else
                g.TileLin = [];
                g.GapLin = [];
            end
            obj.Geoms(end + 1) = struct('Key', key, 'G', g);
            if numel(obj.Geoms) > 8; obj.Geoms(1) = []; end
        end
    end

    % ------------------------------------------------------------------------------------------------
    methods (Static, Access = private)
        function mosaic = paintSlots(mosaic, g, slots, rel, colours)
            %paintSlots  Set pixels REL (offsets within a tile) of tiles SLOTS to COLOURS (n x 3, 0-255).
            idx = rel + g.SlotBase(slots(:)');          % P x n
            P = numel(rel);
            HW = g.H * g.W;
            colours = uint8(colours);
            for ch = 1:3
                mosaic(idx + (ch - 1) * HW) = repmat(colours(:, ch)', P, 1);
            end
        end

        function A = lut8(A, lut)
            %lut8  Apply a 256-entry uint8 lookup table to uint8 array A (any dimensions).
            persistent haveIntlut
            if isempty(haveIntlut); haveIntlut = exist('intlut', 'file') > 0; end
            sz = size(A);
            if haveIntlut
                A = reshape(intlut(reshape(A, sz(1), []), lut(:)), sz);
            else
                A = reshape(lut(double(A) + 1), sz);
            end
        end

        function c = perTileColours(c, K, name)
            %perTileColours  K x 3 double colours (0-255, NaN rows = none) from [], 1 x 3 or K x 3.
            if isempty(c)
                c = NaN(K, 3);
                return
            end
            c = double(c);
            if isequal(size(c), [1 3])
                c = repmat(c, K, 1);
            elseif ~isequal(size(c), [K 3])
                error('CropCache:BadStyle', '%s must be empty, 1 x 3 or %d x 3 (one row per tile).', name, K);
            end
            c(any(isnan(c), 2), :) = NaN;
        end

        function [ids, xy] = checkCells(ids, xy)
            ids = ids(:);
            if size(xy, 2) ~= 2 && numel(xy) == 2; xy = reshape(xy, 1, 2); end
            if size(xy, 2) ~= 2 || size(xy, 1) ~= numel(ids)
                error('CropCache:BadCells', 'xy must be N x 2 [X Y] with one row per id (%d ids, xy is %s).', ...
                    numel(ids), mat2str(size(xy)));
            end
            if any(~isfinite(xy), 'all')
                error('CropCache:BadCells', 'X and Y must be finite.');
            end
            if any(ids < 0 | ids ~= floor(ids))
                error('CropCache:BadCells', 'CellIDs must be non-negative integers.');
            end
            ids = uint32(ids);
            xy = double(xy);
        end

        function q = quantiles(v, p)
            %quantiles  Quantiles P (0-1) of the finite vector V, by prctile's definition (midpoint
            %   plotting positions, linear interpolation, clamped), using partial sorts.
            n = numel(v);
            q = zeros(size(p));
            for i = 1:numel(p)
                pos = min(max(n * p(i) + 0.5, 1), n);
                i1 = floor(pos);
                i2 = min(n, i1 + 1);
                if i2 <= n / 2
                    lo = mink(v, i2);
                    a = lo(i1); b = lo(i2);
                else
                    hi = maxk(v, n - i1 + 1);              % descending: ascending index i is hi(n - i + 1)
                    a = hi(n - i1 + 1); b = hi(n - i2 + 1);
                end
                q(i) = a + (pos - i1) * (b - a);
            end
        end
    end
end

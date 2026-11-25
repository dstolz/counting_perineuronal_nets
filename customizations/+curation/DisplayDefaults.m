classdef DisplayDefaults
%DISPLAYDEFAULTS  The default display of a source's tiles and map, chosen from the data (static).
%
%   d = curation.DisplayDefaults.fromCache(cache, opts)
%       cache: a curation.CropCache. Its crops are uint8 at the PAGE's fixed limits (the 1st and
%       99.9th percentile of the page): that rule stays (one contrast per page, never per tile).
%       Only the display mapping on top of it, min(1, Gain * v) ^ Gamma on v = crop / 255 (the
%       look-up table curation.CropCache and curation.MapView share), is chosen here, per channel
%       ([target companion]):
%         Gain   255 / the opts.Percentile-th percentile of the pixels INSIDE the source's crops
%                (cells and their surroundings, all crops pooled), clamped to opts.GainLimits:
%                lifts a page whose brightest pixels lie outside the cells. A gain below
%                MIN_GAIN_STEP (the percentile is within 2% of full scale) is left at 1: it would
%                brighten nothing a person can see and would clip the few pixels above it.
%         Gamma  the gamma that shows the typical cell at opts.Target of full brightness: the
%                median over the cells (opts.Ids, e.g. the middle-band candidates; default all) of
%                each crop's center brightness (the 95th percentile within CenterUm of the
%                center), after Gain; clamped to opts.GammaLimits. Below 1 it lifts the dim
%                mid-tones far more than the bright ones, so a dim net becomes visible while a
%                bright one keeps its structure (gamma does not saturate anything the page limits
%                did not).
%       d: struct Gain (1 x 2), Gamma (1 x 2), Level (1 x 2: the percentile, crop units 0-255),
%       Typical (1 x 2: the typical cell's center level before Gamma, 0-255), Note.
%       The window's brightness and gamma keys multiply these defaults; [0] returns to them.
%
%   OPTIONS (struct, every field optional)
%     Percentile  99.5     of the crop pixels
%     Target      0.6      where the typical cell's center is shown (0-1)
%     GammaLimits [0.45 1] never darker than the page limits; never flatter than 0.45
%     GainLimits  [1 6]
%     CenterUm    15       radius of a crop's center (a net is about 20-30 um across)
%     Ids         []       the cells that define "typical" (CellIDs of the cache); [] = all
%     MaxSamples  2e5      crop pixels sampled for the percentile (a regular subsample)
%
%   Measured on the three real sections of tests\tCuratorReal (WFA and PV, float32 pages; the
%   integration pass C report has the numbers and the mosaics): at the page limits the
%   middle-band cells' centers sit at a median 90-131 of 255 (dark gray), the crop pixels'
%   99.5th percentile is already 252-255 (so Gain stays 1 there), and the adaptive gamma (0.49 to
%   0.77) brings them to about 150 without saturating more pixels.
%
%   See also curation.CropCache, curation.MapView, CellCurator.

    properties (Constant)
        PERCENTILE = 99.5
        TARGET = 0.6
        GAMMA_LIMITS = [0.45 1]
        GAIN_LIMITS = [1 6]
        CENTER_UM = 15
        MIN_GAIN_STEP = 1.02        % a smaller gain is not applied
    end

    methods (Static)
        function d = fromCache(cache, opts)
            if nargin < 2 || isempty(opts), opts = struct(); end
            O = @(n, v) curation.DisplayDefaults.opt(opts, n, v);
            pc = O('Percentile', curation.DisplayDefaults.PERCENTILE);
            target = O('Target', curation.DisplayDefaults.TARGET);
            glim = O('GammaLimits', curation.DisplayDefaults.GAMMA_LIMITS);
            lim = O('GainLimits', curation.DisplayDefaults.GAIN_LIMITS);
            cum = O('CenterUm', curation.DisplayDefaults.CENTER_UM);
            ids = O('Ids', []);
            ns = O('MaxSamples', 2e5);
            d = struct('Gain', [1 1], 'Gamma', [1 1], 'Level', [NaN NaN], 'Typical', [NaN NaN], 'Note', "");
            if isempty(cache) || cache.N == 0
                d.Note = "no crops: the page limits as they are";
                return
            end
            rows = (1:cache.N)';
            if ~isempty(ids)
                r = cache.rowsOf(uint32(ids(:)));
                r = r(r > 0);
                if numel(r) >= 5, rows = r; end
            end
            if numel(rows) > 400                     % a median: 400 cells evenly spread suffice
                rows = rows(round(linspace(1, numel(rows), 400)));
            end
            T = cache.TilePx;
            [xx, yy] = meshgrid(1:T, 1:T);
            disc = hypot(xx - (T + 1) / 2, yy - (T + 1) / 2) <= cum * T / cache.WindowUm;
            stacks = {cache.Crops, cache.CropsC};
            for k = 1:2
                A = stacks{k};
                if isempty(A) || size(A, 3) == 0
                    d.Gain(k) = d.Gain(1);
                    d.Gamma(k) = d.Gamma(1);
                    continue
                end
                q = curation.DisplayDefaults.level(A, pc, ns);
                d.Level(k) = q;
                g = min(max(255 / max(q, 1), lim(1)), lim(2));
                if g < curation.DisplayDefaults.MIN_GAIN_STEP
                    g = lim(1);             % (GainLimits(1) is 1 unless the caller asked otherwise)
                end
                d.Gain(k) = g;
                typ = curation.DisplayDefaults.typical(A(:, :, rows), disc);
                d.Typical(k) = typ;
                v = min(1, g * typ / 255);
                if v > 0 && v < 1
                    d.Gamma(k) = min(max(log(target) / log(v), glim(1)), glim(2));
                else
                    d.Gamma(k) = glim(2);
                end
            end
        end

        function q = level(A, pc, maxSamples)
            %LEVEL  The PC-th percentile of the pixels of uint8 stack A (a regular subsample).
            n = numel(A);
            step = max(1, floor(n / maxSamples));
            v = A(1:step:n);
            c = accumarray(double(v(:)) + 1, 1, [256 1]);
            cdf = cumsum(c) / sum(c);
            q = find(cdf >= pc / 100, 1) - 1;
            if isempty(q), q = 255; end
        end

        function m = typical(A, disc)
            %TYPICAL  Median over the crops of A of their center's 95th percentile (0-255).
            n = size(A, 3);
            P = reshape(A, [], n);
            P = sort(P(disc(:), :), 1);
            c = double(P(max(1, round(0.95 * size(P, 1))), :));
            m = median(c);
        end

        function L = lut(gain, gamma)
            %LUT  The 256-entry display table of GAIN and GAMMA (scalars), as CropCache builds it.
            x = (0:255)' / 255;
            L = uint8(255 * min(1, max(0, x * gain)) .^ gamma);
        end
    end

    methods (Static, Access = private)
        function v = opt(s, name, d)
            v = d;
            if isstruct(s) && isfield(s, name) && ~isempty(s.(name)), v = s.(name); end
        end
    end
end

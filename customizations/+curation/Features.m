classdef Features
%FEATURES  Per-candidate features for the assist model, computed from the image (static, pure).
%
%   [F, names] = curation.Features.compute(pageT, pageC, T, umPerPx, opts)
%       pageT    target page (H x W, any numeric class, any intensity scale)
%       pageC    companion page of the same size (the other channel), or [] for none
%       T        table (or struct of columns) with X, Y (full-resolution pixels; X the column,
%                Y the row, pixel centers at integers) and optionally score, rescore
%       umPerPx  page pixel size in micrometers (read it per source)
%       opts     struct, every field optional:
%                  NeighborMask  N x 1 logical: rows that count as neighbors for nnUm and
%                                 densityN (default all rows). curation.ProjectIndex passes
%                                 InLocs (every detection in the current locs, whatever its
%                                 curation state), so the features never depend on curation
%                                 decisions such as merges.
%                  PageStats, PageStatsC   precomputed curation.Features.pageStats(page)
%                  Chunk          candidates per vectorized pass (default 512; bounds memory)
%       F        N x K double, row i belongs to row i of T; NaN = not available
%       names    1 x K string, the column names (= curation.Features.names())
%
%   names = curation.Features.names()
%   D = curation.Features.describe()       table Name, Meaning (one line per feature)
%   s = curation.Features.pageStats(page)  robust page statistics used for the normalization
%
%   INTENSITY SCALE. Pages are float32 on a scale that differs between sections. Every
%   image-derived feature is a ratio of intensity DIFFERENCES (local z-scores, or differences
%   divided by a robust page spread), so it is invariant to any affine change a*page + b with
%   a > 0: multiplying a page by 1000 and adding an offset leaves F unchanged up to rounding.
%   Page statistics (median, MAD, 99.9th percentile) are taken over the TISSUE pixels of a fixed
%   regular subsample of at most 1e6 pixels, which is affine-equivariant as well.
%
%   PADDING. A section rarely fills its frame: the rest of the page is one constant (exactly 0
%   in the real projections). When the page minimum holds more than PAD_FRACTION (2%) of the
%   sampled finite pixels it is taken as that padding value (pageStats: Pad, PadFraction) and
%   its pixels are left out of the page statistics AND of every local window, exactly like
%   pixels outside the page. Without this, a page more than half padding had median and MAD
%   equal to the padding value, and bgLevel / bgNoise / the profile bins lost their meaning.
%   Non-finite pixels are always left out. The rule follows the page under a*page + b (the pad
%   value moves with it). Caveat: an integer page whose dark background is clipped at its
%   minimum over more than 2% of the frame has those pixels treated as padding too.
%
%   GEOMETRY (micrometers, measured from the exact sub-pixel position of the candidate; the
%   image is sampled at integer pixels with a stride of max(1, round(1 / umPerPx)) px)
%     center      d <= 3                    the hole of a net / the core of a soma
%     annulus     5 <= d <= 10              the wall of a net (~18 um diameter)
%     background  14 <= d <= 22            local background ring (membership by integer offset)
%     profile     8 bins of 2.75 um from 0 to 22
%     blob        d <= 13, pixels above bg + max(0.5 * (peak - bg), local noise)
%   Pixels outside the page (and padding pixels, see PADDING) are missing (not zero): a window
%   that reaches past the border uses the pixels it has; a region with no pixel inside the page
%   gives NaN. Interior candidates never get NaN image features.
%
%   FEATURES (see describe() for the one-line meaning of each)
%     score, rescore, scoreRank, rescoreRank, centerZ, annulusZ, contrast, prof1..prof8,
%     ringRatio, angUniformity, peakRadiusUm, blobAreaUm2, blobCompactness, bgLevel, bgNoise,
%     compContrast, compCenterZ, borderUm, nnUm, densityN
%   rescore may be NaN (kept as NaN; the model handles missing values); compContrast and
%   compCenterZ are NaN without a companion page.
%
%   See also curation.AssistModel, curation.ProjectIndex, curation.CropCache.

    properties (Constant)
        VERSION = "features/2"     % 2: page statistics and windows leave the padding out
        CENTER_UM = 3
        ANNULUS_UM = [5 10]
        BG_UM = [14 22]
        PROFILE_UM = 22
        NBINS = 8
        NSECTORS = 8
        BLOB_UM = 13
        DENSITY_UM = 50
        MAX_NN_UM = 200
        NOISE_FLOOR = 0.25      % local noise is at least this fraction of the page noise
        PAD_FRACTION = 0.02     % the page minimum is padding when it holds more than this
    end

    methods (Static)

        function names = names()
            %NAMES  Feature names, in column order of F.
            names = ["score", "rescore", "scoreRank", "rescoreRank", ...
                "centerZ", "annulusZ", "contrast", ...
                "prof" + (1:curation.Features.NBINS), ...
                "ringRatio", "angUniformity", "peakRadiusUm", "blobAreaUm2", "blobCompactness", ...
                "bgLevel", "bgNoise", "compContrast", "compCenterZ", ...
                "borderUm", "nnUm", "densityN"];
        end

        function D = describe()
            %DESCRIBE  Table Name, Meaning: one line per feature.
            Name = curation.Features.names()';
            prof = "radial profile bin " + (1:8)' + " (" + compose("%.2f", ((0:7)' * 2.75)) + "-" + ...
                compose("%.2f", ((1:8)' * 2.75)) + " um): (bin mean - local background) / page spread";
            Meaning = [ ...
                "detector confidence (0-1)"; ...
                "ordinal scorer output (NaN when missing)"; ...
                "rank of score within the source, 0 (lowest) to 1"; ...
                "rank of rescore within the source, 0 to 1 (NaN when rescore is NaN)"; ...
                "(center mean - local background) / local noise"; ...
                "(annulus mean - local background) / local noise"; ...
                "(center mean - annulus mean) / local noise: > 0 solid blob, < 0 ring"; ...
                prof; ...
                "(annulus peak - center) / max(annulus peak - bg, center - bg, noise): ~1 net, < 0 blob"; ...
                "angular uniformity of the annulus over 8 sectors, (m - sd) / (|m| + sd + noise/2)"; ...
                "radius of the brightest profile bin within 16.5 um (bin center, um)"; ...
                "area above the local threshold within 13 um (um^2)"; ...
                "(2/3) sqrt(area/pi) / mean distance of the above-threshold pixels: 1 centered disk"; ...
                "(local background - page median) / page noise"; ...
                "local noise / page noise"; ...
                "companion channel (center - annulus) / its local noise (NaN without companion)"; ...
                "companion channel (center - background) / its local noise (NaN without companion)"; ...
                "distance to the nearest page edge (um; the page spans 0.5 .. W+0.5 px)"; ...
                "distance to the nearest other candidate (um, capped at 200)"; ...
                "number of other candidates within 50 um"];
            D = table(Name, Meaning);
        end

        function [F, names] = compute(pageT, pageC, T, umPerPx, opts)
            %COMPUTE  Features of every row of T (see the class help).
            if nargin < 5 || isempty(opts), opts = struct(); end
            if ~(isnumeric(umPerPx) && isscalar(umPerPx) && isfinite(umPerPx) && umPerPx > 0)
                error('curation:Features:badScale', 'umPerPx must be a positive finite scalar.');
            end
            if isempty(pageT) || ~ismatrix(pageT)
                error('curation:Features:badPage', 'The target page must be a non-empty H x W matrix.');
            end
            if ~isempty(pageC) && ~isequal(size(pageC), size(pageT))
                error('curation:Features:badPage', ...
                    'The companion page must be [] or the size of the target page (%d x %d).', ...
                    size(pageT, 1), size(pageT, 2));
            end
            names = curation.Features.names();
            X = double(curation.Features.col(T, 'X'));
            Y = double(curation.Features.col(T, 'Y'));
            n = numel(X);
            F = nan(n, numel(names));
            if n == 0, return; end
            if any(~isfinite(X) | ~isfinite(Y))
                error('curation:Features:badPosition', 'X and Y must be finite.');
            end
            nbMask = true(n, 1);
            if isfield(opts, 'NeighborMask') && ~isempty(opts.NeighborMask)
                nbMask = logical(opts.NeighborMask(:));
                if numel(nbMask) ~= n
                    error('curation:Features:badArgument', 'NeighborMask needs one entry per row.');
                end
            end
            chunk = 512;
            if isfield(opts, 'Chunk') && ~isempty(opts.Chunk), chunk = max(1, round(opts.Chunk)); end

            sc = curation.Features.colOr(T, 'score', n);
            rs = curation.Features.colOr(T, 'rescore', n);
            F(:, 1) = sc;
            F(:, 2) = rs;
            F(:, 3) = curation.Features.rank01(sc);
            F(:, 4) = curation.Features.rank01(rs);

            % image features of the target channel
            if isfield(opts, 'PageStats') && ~isempty(opts.PageStats)
                st = opts.PageStats;
            else
                st = curation.Features.pageStats(pageT);
            end
            G = curation.Features.geometry(umPerPx);
            A = curation.Features.imageBlock(pageT, X, Y, G, st, false, chunk);
            F(:, 5) = A.centerZ;
            F(:, 6) = A.annulusZ;
            F(:, 7) = A.contrast;
            F(:, 8:15) = A.prof;
            F(:, 16) = A.ringRatio;
            F(:, 17) = A.angUniformity;
            F(:, 18) = A.peakRadiusUm;
            F(:, 19) = A.blobAreaUm2;
            F(:, 20) = A.blobCompactness;
            F(:, 21) = A.bgLevel;
            F(:, 22) = A.bgNoise;

            % companion channel: center/annulus contrast only
            if ~isempty(pageC)
                if isfield(opts, 'PageStatsC') && ~isempty(opts.PageStatsC)
                    stc = opts.PageStatsC;
                else
                    stc = curation.Features.pageStats(pageC);
                end
                B = curation.Features.imageBlock(pageC, X, Y, G, stc, true, chunk);
                F(:, 23) = B.contrast;
                F(:, 24) = B.centerZ;
            end

            % context: border, nearest neighbor, density
            [H, W] = size(pageT);
            F(:, 25) = min([X - 0.5, W + 0.5 - X, Y - 0.5, H + 0.5 - Y], [], 2) * umPerPx;
            [nnUm, dens] = curation.Features.neighbors(X, Y, nbMask, umPerPx);
            F(:, 26) = nnUm;
            F(:, 27) = dens;
        end

        function s = pageStats(page, maxSamples)
            %PAGESTATS  Robust statistics of the tissue pixels of a page over a regular subsample
            %   (<= maxSamples px): Median, Noise (1.4826 * MAD), Spread (99.9th percentile -
            %   median), Pad (the padding value, NaN when none; see PADDING in the class help),
            %   PadFraction (its share of the sampled pixels), Step, N (tissue pixels used).
            %   Floors keep Noise and Spread positive and affine-equivariant (relative to the
            %   sampled tissue range).
            if nargin < 2 || isempty(maxSamples), maxSamples = 1e6; end
            [h, w] = size(page);
            step = max(1, ceil(sqrt(h * w / maxSamples)));
            v = page(1:step:end, 1:step:end);
            v = double(v(:));
            v = v(isfinite(v));
            s = struct('Median', 0, 'Noise', 1, 'Spread', 1, 'Step', step, 'N', numel(v), ...
                'Pad', NaN, 'PadFraction', 0);
            if isempty(v), return; end
            mn = min(v);
            isPad = v == mn;
            fr = nnz(isPad) / numel(v);
            if fr > curation.Features.PAD_FRACTION && fr < 1
                s.Pad = mn;
                s.PadFraction = fr;
                v = v(~isPad);
                s.N = numel(v);
            end
            med = median(v);
            mad = median(abs(v - med));
            k = max(1, ceil(0.001 * numel(v)));
            hi = min(maxk(v, k));
            rng0 = max(v) - min(v);
            floorV = 1e-6 * rng0;
            if ~(rng0 > 0), floorV = 1; end
            noise = max(1.4826 * mad, floorV);
            spread = hi - med;
            if ~(spread > 10 * noise), spread = max(spread, 10 * noise); end
            s.Median = med;
            s.Noise = noise;
            s.Spread = spread;
        end
    end

    methods (Static, Access = private)

        function G = geometry(umPerPx)
            % Sampling offsets of the window (integer pixels) and the fixed background ring.
            s = max(1, round(1 / umPerPx));
            rMaxPx = curation.Features.PROFILE_UM / umPerPx + 1;
            R = ceil(rMaxPx / s);
            o = (-R:R) * s;
            [dx, dy] = meshgrid(o, o);
            keep = hypot(dx, dy) <= rMaxPx;
            G.dx = dx(keep);
            G.dy = dy(keep);
            G.stride = s;
            G.umPerPx = umPerPx;
            G.pixAreaUm2 = (s * umPerPx) ^ 2;
            d0 = hypot(G.dx, G.dy) * umPerPx;
            G.bgRows = find(d0 >= curation.Features.BG_UM(1) & d0 <= curation.Features.BG_UM(2));
        end

        function A = imageBlock(page, X, Y, G, st, lite, chunk)
            % Image features of one channel for all candidates, in chunks of CHUNK.
            n = numel(X);
            nb = curation.Features.NBINS;
            A = struct('centerZ', nan(n, 1), 'annulusZ', nan(n, 1), 'contrast', nan(n, 1), ...
                'prof', nan(n, nb), 'ringRatio', nan(n, 1), 'angUniformity', nan(n, 1), ...
                'peakRadiusUm', nan(n, 1), 'blobAreaUm2', nan(n, 1), 'blobCompactness', nan(n, 1), ...
                'bgLevel', nan(n, 1), 'bgNoise', nan(n, 1));
            for s0 = 1:chunk:n
                r = s0:min(n, s0 + chunk - 1);
                B = curation.Features.imageChunk(page, X(r), Y(r), G, st, lite);
                f = fieldnames(B);
                for i = 1:numel(f)
                    A.(f{i})(r, :) = B.(f{i});
                end
            end
        end

        function B = imageChunk(page, X, Y, G, st, lite)
            [H, W] = size(page);
            m = numel(X);
            P = numel(G.dx);
            u = G.umPerPx;
            cx = round(X(:)');
            cy = round(Y(:)');
            fx = X(:)' - cx;
            fy = Y(:)' - cy;
            col = G.dx + cx;                       % P x m page columns
            row = G.dy + cy;
            inside = col >= 1 & col <= W & row >= 1 & row <= H;
            lin = (min(max(col, 1), W) - 1) * H + min(max(row, 1), H);
            V = double(page(lin));
            pad = NaN;
            if isfield(st, 'Pad'), pad = st.Pad; end
            valid = inside & isfinite(V) & V ~= pad;        % padding counts as outside the page
            V(~valid) = 0;
            ddx = G.dx - fx;
            ddy = G.dy - fy;
            d = hypot(ddx, ddy) * u;               % exact distance to the candidate, um

            % local background: median / MAD over the fixed ring
            Vb = V(G.bgRows, :);
            Vb(~valid(G.bgRows, :)) = NaN;
            bg = median(Vb, 1, 'omitnan');
            mad = median(abs(Vb - bg), 1, 'omitnan');
            noiseLoc = max(1.4826 * mad, curation.Features.NOISE_FLOOR * st.Noise);

            cenM = valid & d <= curation.Features.CENTER_UM;
            annM = valid & d >= curation.Features.ANNULUS_UM(1) & d <= curation.Features.ANNULUS_UM(2);
            cen = sum(V .* cenM, 1) ./ sum(cenM, 1);
            ann = sum(V .* annM, 1) ./ sum(annM, 1);

            B = struct();
            B.centerZ = ((cen - bg) ./ noiseLoc)';
            B.annulusZ = ((ann - bg) ./ noiseLoc)';
            B.contrast = ((cen - ann) ./ noiseLoc)';
            if lite, return; end

            % radial profile
            nb = curation.Features.NBINS;
            bw = curation.Features.PROFILE_UM / nb;
            bin = floor(d / bw) + 1;
            inBin = valid & bin <= nb;
            colIdx = repmat(1:m, P, 1);
            subs = bin(inBin) + nb * (colIdx(inBin) - 1);
            sz = [nb * m, 1];
            S = accumarray(subs, V(inBin), sz);
            C = accumarray(subs, 1, sz);
            prof = reshape(S ./ C, nb, m);              % NaN where a bin has no pixel
            B.prof = ((prof - bg) / st.Spread)';

            annPk = max(prof(2:4, :), [], 1);           % 2.75 - 11 um
            den = max([annPk - bg; cen - bg; noiseLoc], [], 1);
            B.ringRatio = min(max((annPk - cen) ./ den, -2), 2)';
            [~, ib] = max(prof(1:6, :), [], 1);
            pk6 = max(prof(1:6, :), [], 1);
            pr = ((ib - 0.5) * bw)';
            pr(isnan(pk6')) = NaN;
            B.peakRadiusUm = pr;

            % angular uniformity of the annulus
            ns = curation.Features.NSECTORS;
            ang = atan2(ddy, ddx);
            sec = min(floor((ang + pi) / (2 * pi / ns)), ns - 1) + 1;
            subs = sec(annM) + ns * (colIdx(annM) - 1);
            Ss = accumarray(subs, V(annM), [ns * m, 1]);
            Cs = accumarray(subs, 1, [ns * m, 1]);
            secM = reshape(Ss ./ Cs, ns, m) - bg;
            mu = mean(secM, 1, 'omitnan');
            sd = std(secM, 0, 1, 'omitnan');
            B.angUniformity = ((mu - sd) ./ (abs(mu) + sd + 0.5 * noiseLoc))';

            % blob above a local threshold
            pk = max(prof(1:5, :), [], 1);
            thr = bg + max(0.5 * (pk - bg), noiseLoc);
            above = valid & d <= curation.Features.BLOB_UM & V > thr;
            cnt = sum(above, 1);
            area = cnt * G.pixAreaUm2;
            meanD = sum(d .* above, 1) ./ max(cnt, 1);
            comp = (2 / 3) * sqrt(area / pi) ./ meanD;
            comp(cnt == 0 | ~(meanD > 0)) = 0;
            area(~isfinite(bg)) = NaN;
            comp(~isfinite(bg)) = NaN;
            B.blobAreaUm2 = area';
            B.blobCompactness = comp';

            B.bgLevel = ((bg - st.Median) / st.Noise)';
            B.bgNoise = (noiseLoc / st.Noise)';
        end

        function [nnUm, dens] = neighbors(X, Y, nbMask, umPerPx)
            % Nearest other neighbor (um, capped) and count within DENSITY_UM, by exact
            % distances in chunks. A row never counts itself; exact duplicates count (distance 0).
            n = numel(X);
            nnUm = repmat(curation.Features.MAX_NN_UM, n, 1);
            dens = zeros(n, 1);
            nbIdx = find(nbMask);
            if isempty(nbIdx), return; end
            xn = X(nbIdx)';
            yn = Y(nbIdx)';
            posInNb = zeros(n, 1);
            posInNb(nbIdx) = 1:numel(nbIdx);
            rPx = curation.Features.DENSITY_UM / umPerPx;
            step = max(1, floor(4e6 / numel(nbIdx)));
            for s0 = 1:step:n
                r = (s0:min(n, s0 + step - 1))';
                D = hypot(X(r) - xn, Y(r) - yn);
                self = posInNb(r) > 0;
                if any(self)
                    D(sub2ind(size(D), find(self), posInNb(r(self)))) = Inf;
                end
                nnUm(r) = min(min(D, [], 2) * umPerPx, curation.Features.MAX_NN_UM);
                dens(r) = sum(D <= rPx, 2);
            end
        end

        function r = rank01(v)
            % Rank of each finite value among the finite values, scaled to 0..1 (ties averaged).
            v = double(v(:));
            r = nan(size(v));
            ok = isfinite(v);
            k = nnz(ok);
            if k == 0, return; end
            if k == 1
                r(ok) = 0.5;
                return;
            end
            r(ok) = (tiedrank(v(ok)) - 1) / (k - 1);
        end

        function v = col(T, name)
            if istable(T)
                if ~ismember(name, T.Properties.VariableNames)
                    error('curation:Features:missingColumn', 'T needs a column %s.', name);
                end
                v = T.(name);
            elseif isstruct(T) && isfield(T, name)
                v = T.(name);
            else
                error('curation:Features:missingColumn', 'T needs a column %s.', name);
            end
            v = v(:);
        end

        function v = colOr(T, name, n)
            v = nan(n, 1);
            if (istable(T) && ismember(name, T.Properties.VariableNames)) || (isstruct(T) && isfield(T, name))
                v = double(curation.Features.col(T, name));
            end
        end
    end
end

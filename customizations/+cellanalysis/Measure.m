classdef Measure
%MEASURE  Luminance and morphology of every cell, measured from the image (static, pure).
%
%   [T, info] = cellanalysis.Measure.cells(page, xy, umPerPx, kind, opts)
%       page     H x W image page the cells were detected in (any numeric class and scale; use
%                the page as stored, not a normalized copy: luminance is reported in its units)
%       xy       N x 2 cell centers [X Y], full-resolution pixels (X the column, Y the row)
%       umPerPx  pixel size, micrometers
%       kind     "pnn" (a net: a bright wall around a darker center) or "pv" (a solid soma);
%                anything else is measured like "pv"
%       opts     struct, every field optional:
%         Other      H x W page of the other channel ([] = none): its luminance inside each cell
%         Valid      H x W logical: pixels that belong to the tissue (default all). Pixels
%                    outside are missing, like pixels beyond the frame, so the empty space beside
%                    a section never dilutes a background or a mean.
%         PageStats  struct Median, Mad of the tissue of this page (cellanalysis.Measure.pageStats):
%                    gives MeanNorm and the floor of the local noise
%         OtherStats the same for Other
%         StepUm     0.6   the cell is resampled (bicubic) on a grid no coarser than this, so a
%                          section imaged at 1.66 um/pixel is measured on 0.55 um steps
%         Chunk      256   cells per vectorized pass (bounds memory)
%         Masks      false true: info also holds the outlines (for drawing and for the tests)
%       T        table, row i belongs to xy(i, :): the columns of catalog() that are measured
%                from the image, and the flags
%                  Segmented    a cell was outlined (false: no signal above the background;
%                               shape and segmented luminance are NaN, ApertureNet still holds)
%                  TouchesEdge  the outline reaches the limit of the search radius: the cell runs
%                               into a neighbor or is larger than expected (its size is a lower
%                               bound)
%       info     struct StepUm, Upsample, Version, AxisUm (the window's grid, um from the center) and,
%                with opts.Masks, Foot and Wall (n x n x N logical: footprint and stained pixels on
%                that grid) and Patch (n x n x N single: the resampled image)
%
%   C = cellanalysis.Measure.catalog()
%       table Name, Label, Unit, Group ("Position" | "Luminance" | "Morphology" | "Net"), Kinds
%       ("both" | "pnn"), Source ("image" | "position"), Meaning: one row per metric, in the
%       order the columns are written. This is what the window lists and explains.
%
%   T = cellanalysis.Measure.spatial(xy, umPerPx, otherXY, opts)
%       NnUm (nearest other cell of the same source), LocalDensity (cells per mm^2 within
%       opts.DensityUm = 100 um, the cell itself included), OtherDistUm (nearest cell of the
%       other source; NaN without one).
%
%   R = cellanalysis.Measure.colocalize(xy, otherXY, umPerPx, opts)
%       Pair the cells of two channels of one section, one to one: every pair of cells no
%       farther apart than opts.MaxUm (10) is a candidate; the closest candidates are paired
%       first and a cell is in one pair at most, so the number of colocalized cells is the
%       same seen from either channel. R: struct
%         Colocalized  N x 1 logical      the cell has a partner
%         Partner      N x 1              row of otherXY of its partner (0 = none)
%         DistUm       N x 1              distance to the partner (NaN = none)
%         OtherColocalized  M x 1 logical the cell of the other channel has a partner
%         Chance       N x 1              how often the cell gets a partner BY CHANCE: the share
%                                         of opts.Shifts (8) copies of the other channel, each
%                                         displaced by opts.ShiftUm (default the larger of 50 um
%                                         and 5 x MaxUm) in another direction, in which it is
%                                         paired. A displacement of that size keeps the layers
%                                         and the local density of the other channel but breaks
%                                         every true pairing, so mean(Chance) is the fraction of
%                                         colocalized cells that density alone would give.
%
%   s = cellanalysis.Measure.pageStats(page, valid)   struct Median, Mad (1.4826 * MAD), N
%
%   HOW A CELL IS MEASURED (lengths in micrometers from the cell center)
%     Window        the image is resampled on a grid of StepUm around the exact center (+-23 for
%                   a soma, +-28 for a net, which is wider with the sheaths of its dendrites).
%     Background    median of the ring 15-23 (net: 20-28); its robust spread (1.4826 * MAD) is the
%                   local noise.
%     Profile       mean of each 1 um ring from the center to the window's edge (radial profile).
%     Outline, pv   pixels above background + max(half the peak within 4, 2 * noise), within 14:
%                   the connected piece under the peak, holes filled.
%     Outline, pnn  pixels above background + max(half the wall, 2 * noise), within 18, where the
%                   wall is the bright ring around the profile's peak radius. The pieces that
%                   reach the wall are the net's stained area; its footprint is their convex
%                   hull, so an open (C-shaped) net has a footprint too.
%     Shape         from the footprint: area, the ellipse with the same second moments (major and
%                   minor axis, orientation), perimeter (Cauchy-Crofton, four directions; the
%                   hull's own perimeter for a net), convex hull.
%     Net           ring radius = the profile's peak; wall thickness = its full width at half
%                   maximum; ring contrast = how empty the center is; completeness = share of 16
%                   directions in which the wall is present.
%   Luminance is taken from the page as it is (not smoothed); outlines from a copy smoothed with
%   a 1 um Gaussian when the pixels are small enough for that to matter.
%
%   The numbers describe the stained object at the image's resolution: at 1.66 um/pixel a soma
%   is about 7 pixels across, so shape values are coarse for single cells and meant for
%   distributions.
%
%   See also cellanalysis.Surface, cellanalysis.Project, curation.Features.

    properties (Constant)
        VERSION = "measure/1"
        % per kind: [soma net]. A net with the sheaths of its proximal dendrites is wider than a soma.
        WINDOW_UM = [23 28]         % half-width of the resampled window = number of 1 um profile rings
        BG_UM = [15 23; 20 28]      % background ring
        SEG_UM = [14 18]            % an outline is looked for within this radius
        PEAK_SEARCH_UM = 14
        PV_PEAK_UM = 4
        PV_APERTURE_UM = 6
        PNN_APERTURE_UM = 11
        SECTORS = 16
        WALL_BAND_UM = 3
        SMOOTH_UM = 1
    end

    methods (Static)

        function C = catalog()
            %CATALOG  Every metric: Name, Label, Unit, Group, Kinds, Source, Meaning.
            rows = {
                'SurfaceDistUm',  'Distance from brain surface', 'um',        'Position',   'both', 'position', ...
                    'Shortest distance from the cell to the brain surface (the edge between the tissue and the empty space outside it, or the traced line).'
                'NnUm',           'Nearest neighbor',           'um',        'Position',   'both', 'position', ...
                    'Distance to the nearest other cell of the same channel in the same section.'
                'LocalDensity',   'Local density',               'cells/mm^2', 'Position',  'both', 'position', ...
                    'Cells of the same channel within 100 um of the cell (itself included), per square millimeter. Not corrected for the edge of the tissue.'
                'OtherDistUm',    'Nearest cell of other channel', 'um',      'Position',   'both', 'position', ...
                    'Distance to the nearest cell of the section''s other channel (PV for a net, a net for a PV cell). Empty when the section has one channel.'
                'Colocalized',    'Colocalized (fraction)',      '',          'Position',   'both', 'position', ...
                    '1 when the cell is paired with a cell of the other channel within the colocalization distance (one to one, closest first), else 0: the mean is the fraction of colocalized cells.'
                'ColocChance',    'Colocalized by chance (fraction)', '',     'Position',   'both', 'position', ...
                    'How often the cell would be paired by chance: the share of 8 copies of the other channel, each displaced by 50 um in another direction, in which it has a partner. Its mean is the colocalization that the density of the two channels alone would give.'
                'AxisToSurfaceDeg', 'Long axis vs surface normal', 'deg',     'Position',   'both', 'position', ...
                    'Angle between the cell''s long axis and the direction into the tissue: 0 = pointing away from the surface (radial), 90 = parallel to it. Only meaningful for elongated cells.'
                'Mean',           'Mean intensity',              'image units', 'Luminance', 'both', 'image', ...
                    'Mean pixel value inside the cell (a net: its stained wall; a soma: its outline), in the units of the image.'
                'Background',     'Local background',            'image units', 'Luminance', 'both', 'image', ...
                    'Median pixel value of a ring around the cell (15-23 um from the center of a soma, 20-28 um for a net).'
                'NetMean',        'Mean above background',       'image units', 'Luminance', 'both', 'image', ...
                    'Mean intensity minus the local background.'
                'Contrast',       'Contrast',                    'ratio',     'Luminance',  'both', 'image', ...
                    '(Mean - background) / background (Weber contrast). Independent of the image''s gain; empty where the background is not above zero.'
                'Snr',            'Signal to noise',             'ratio',     'Luminance',  'both', 'image', ...
                    '(Mean - background) / local noise (robust spread of the background ring).'
                'MeanNorm',       'Mean / tissue median',        'ratio',     'Luminance',  'both', 'image', ...
                    'Mean intensity divided by the median of the section''s tissue in this channel: comparable between sections of different brightness.'
                'Integrated',     'Integrated intensity',        'image units x um^2', 'Luminance', 'both', 'image', ...
                    'Sum of (pixel - background) over the cell, times the pixel area: the total stain of the cell.'
                'PeakNet',        'Peak above background',       'image units', 'Luminance', 'both', 'image', ...
                    'Brightest (lightly smoothed) pixel of the cell minus the local background.'
                'ApertureNet',    'Aperture mean above background', 'image units', 'Luminance', 'both', 'image', ...
                    'Mean within a fixed radius of the center (6 um for a soma, 11 um for a net) minus the background. Needs no outline, so it exists for every cell.'
                'OtherNet',       'Other channel above background', 'image units', 'Luminance', 'both', 'image', ...
                    'Mean of the other channel inside the cell''s footprint minus that channel''s local background (PV inside a net; WFA around a PV cell).'
                'OtherSnr',       'Other channel signal to noise', 'ratio',   'Luminance',  'both', 'image', ...
                    'Other channel above background divided by that channel''s local noise.'
                'AreaUm2',        'Area',                        'um^2',      'Morphology', 'both', 'image', ...
                    'Area of the cell''s footprint (a soma: its outline with holes filled; a net: the convex hull of its stained wall).'
                'DiameterUm',     'Equivalent diameter',         'um',        'Morphology', 'both', 'image', ...
                    'Diameter of the circle with the footprint''s area.'
                'RadiusUm',       'Half-maximum radius',         'um',        'Morphology', 'both', 'image', ...
                    'Radius at which the radial profile falls to half of its peak above background: a size that needs no outline.'
                'MajorUm',        'Major axis',                  'um',        'Morphology', 'both', 'image', ...
                    'Long axis of the ellipse with the same second moments as the footprint.'
                'MinorUm',        'Minor axis',                  'um',        'Morphology', 'both', 'image', ...
                    'Short axis of that ellipse.'
                'AspectRatio',    'Aspect ratio',                'ratio',     'Morphology', 'both', 'image', ...
                    'Major axis / minor axis: 1 = round, larger = elongated.'
                'PerimeterUm',    'Perimeter',                   'um',        'Morphology', 'both', 'image', ...
                    'Length of the footprint''s outline.'
                'Circularity',    'Circularity',                 'ratio',     'Morphology', 'both', 'image', ...
                    '4 pi area / perimeter^2: 1 = a circle, lower = elongated or ragged.'
                'Solidity',       'Solidity',                    'ratio',     'Morphology', 'both', 'image', ...
                    'Stained area / area of its convex hull: 1 = solid and convex; a thin or open net is low.'
                'OrientationDeg', 'Orientation in the image',    'deg',       'Morphology', 'both', 'image', ...
                    'Angle of the long axis in the image, -90 to 90 degrees, counter-clockwise from the horizontal as displayed.'
                'WallAreaUm2',    'Net stained area',            'um^2',      'Net',        'pnn',  'image', ...
                    'Area of the net''s stained wall (the pixels above the half-maximum threshold).'
                'RingRadiusUm',   'Net radius',                  'um',        'Net',        'pnn',  'image', ...
                    'Radius at which the radial profile peaks: the distance of the net''s wall from its center (0 = brightest at the center).'
                'WallThicknessUm', 'Net wall thickness',         'um',        'Net',        'pnn',  'image', ...
                    'Full width at half maximum of the wall in the radial profile.'
                'RingContrast',   'Net ring contrast',           'ratio',     'Net',        'pnn',  'image', ...
                    '(wall - center) / (wall - background): 1 = an empty center (a clear ring), 0 = the center is as bright as the wall.'
                'Completeness',   'Net completeness',            'fraction',  'Net',        'pnn',  'image', ...
                    'Share of 16 directions around the center in which the wall is present (at least half as bright as the wall''s strong directions): 1 = a closed ring.'
                'AngularCV',      'Net wall unevenness',         'ratio',     'Net',        'pnn',  'image', ...
                    'Coefficient of variation of the wall''s brightness around the ring: 0 = even, larger = patchy.'
                };
            C = cell2table(rows, 'VariableNames', {'Name', 'Label', 'Unit', 'Group', 'Kinds', 'Source', 'Meaning'});
            for v = string(C.Properties.VariableNames)
                C.(v) = string(C.(v));
            end
        end

        function names = imageNames()
            %IMAGENAMES  The metrics cells() measures, in column order.
            C = cellanalysis.Measure.catalog();
            names = C.Name(C.Source == "image")';
        end

        function s = pageStats(page, valid)
            %PAGESTATS  Median and robust spread (1.4826 * MAD) of the tissue of a page.
            %   valid (optional H x W logical) selects the tissue; a regular subsample of at most
            %   about a million pixels is used.
            p = page;
            step = max(1, floor(sqrt(numel(p) / 1e6)));
            v = double(p(1:step:end, 1:step:end));
            if nargin >= 2 && ~isempty(valid)
                v = v(valid(1:step:end, 1:step:end));
            end
            v = v(isfinite(v));
            s = struct('Median', NaN, 'Mad', NaN, 'N', numel(v));
            if isempty(v), return; end
            s.Median = median(v);
            s.Mad = 1.4826 * median(abs(v - s.Median));
        end

        function [T, info] = cells(page, xy, umPerPx, kind, opts)
            %CELLS  Measure every cell of one page (see the class help).
            if nargin < 5 || isempty(opts), opts = struct(); end
            o = struct('Other', [], 'Valid', [], 'PageStats', [], 'OtherStats', [], 'StepUm', 0.6, 'Chunk', 256, ...
                'Masks', false);
            fn = fieldnames(opts);
            for i = 1:numel(fn)
                if ~isfield(o, fn{i})
                    error('cellanalysis:Measure:badOption', 'Unknown option "%s".', fn{i});
                end
                o.(fn{i}) = opts.(fn{i});
            end
            if ~(isnumeric(umPerPx) && isscalar(umPerPx) && isfinite(umPerPx) && umPerPx > 0)
                error('cellanalysis:Measure:badScale', 'umPerPx must be a positive finite scalar.');
            end
            if isempty(page) || ~ismatrix(page) || min(size(page)) < 4
                error('cellanalysis:Measure:badPage', 'The page must be an H x W matrix of at least 4 x 4 pixels.');
            end
            if ~isempty(o.Other) && ~isequal(size(o.Other), size(page))
                error('cellanalysis:Measure:badPage', 'Other must be [] or the size of the page.');
            end
            if ~isempty(o.Valid) && ~isequal(size(o.Valid), size(page))
                error('cellanalysis:Measure:badPage', 'Valid must be [] or the size of the page.');
            end
            xy = reshape(double(xy), [], 2);
            N = size(xy, 1);
            isNet = lower(string(kind)) == "pnn";
            M = cellanalysis.Measure;

            names = cellanalysis.Measure.imageNames();
            R = nan(N, numel(names));
            col = containers.Map(cellstr(names), 1:numel(names));
            segmented = false(N, 1);
            touches = false(N, 1);

            u = max(1, round(umPerPx / o.StepUm));
            s = umPerPx / u;                                   % sampling step, um
            kk = 1 + isNet;
            windowUm = M.WINDOW_UM(kk);
            bgUm = M.BG_UM(kk, :);
            segUm = M.SEG_UM(kk);
            hw = ceil(windowUm / s);
            ax = (-hw:hw) * s;
            n = numel(ax);
            info = struct('StepUm', s, 'Upsample', u, 'Version', M.VERSION, 'AxisUm', ax);
            keepMasks = logical(o.Masks);
            if keepMasks
                info.Foot = false(n, n, N);
                info.Wall = false(n, n, N);
                info.Patch = nan(n, n, N, 'single');
            end
            if N == 0
                T = cellanalysis.Measure.pack(R, names, segmented, touches);
                return
            end

            % ---- the sampling grid and its fixed masks -------------------------------------------
            [gx, gy] = meshgrid(ax, ax);
            rr = hypot(gx, gy);
            r = rr(:);
            ring = r >= bgUm(1) & r <= bgUm(2);
            center = r <= 2;
            segDisk = rr <= segUm;
            edgeBand = rr > segUm - 1.5 * s & segDisk;
            nb = windowUm;
            bin = floor(r) + 1;
            binIdx = cell(nb, 1);
            for b = 1:nb, binIdx{b} = find(bin == b); end
            if isNet, ap = M.PNN_APERTURE_UM; else, ap = M.PV_APERTURE_UM; end
            aperture = r <= ap;
            pvPeak = rr <= M.PV_PEAK_UM;
            ns = M.SECTORS;
            sec = floor(mod(atan2(-gy(:), gx(:)), 2 * pi) / (2 * pi / ns)) + 1;
            sec = min(sec, ns);
            polIdx = cell(nb, ns);
            if isNet
                for b = 1:nb
                    for q = 1:ns
                        polIdx{b, q} = find(bin == b & sec == q);
                    end
                end
            end

            % ---- interpolants ---------------------------------------------------------------------
            [F, Fs, smoothed] = cellanalysis.Measure.interpolants(page, o.Valid, M.SMOOTH_UM / umPerPx);
            Fo = [];
            if ~isempty(o.Other)
                Fo = cellanalysis.Measure.interpolants(o.Other, o.Valid, 0);
            end
            floorNoise = 0;
            if isstruct(o.PageStats) && isfield(o.PageStats, 'Mad') && isfinite(o.PageStats.Mad)
                floorNoise = 0.25 * o.PageStats.Mad;
            end
            floorOther = 0;
            if isstruct(o.OtherStats) && isfield(o.OtherStats, 'Mad') && isfinite(o.OtherStats.Mad)
                floorOther = 0.25 * o.OtherStats.Mad;
            end
            tissueMedian = NaN;
            if isstruct(o.PageStats) && isfield(o.PageStats, 'Median'), tissueMedian = o.PageStats.Median; end

            ox = gx(:) / umPerPx;
            oy = gy(:) / umPerPx;
            finiteXY = all(isfinite(xy), 2);

            for c0 = 1:o.Chunk:N
                idx = c0:min(N, c0 + o.Chunk - 1);
                m = numel(idx);
                Xq = ox + xy(idx, 1)';
                Yq = oy + xy(idx, 2)';
                V = double(F(Yq, Xq));
                if smoothed, Vs = double(Fs(Yq, Xq)); else, Vs = V; end

                % background and noise from the ring
                Rg = V(ring, :);
                nOk = sum(~isnan(Rg), 1);
                bg = median(Rg, 1, 'omitnan');
                noise = 1.4826 * median(abs(Rg - bg), 1, 'omitnan');
                noise = max(noise, max(floorNoise, 1e-9 * max(abs(bg), 1)));
                usable = nOk >= 0.3 * nnz(ring) & isfinite(bg) & finiteXY(idx)';

                % radial profile, center, aperture
                prof = nan(nb, m);
                for b = 1:nb
                    prof(b, :) = mean(Vs(binIdx{b}, :), 1, 'omitnan');
                end
                cen = mean(Vs(center, :), 1, 'omitnan');
                apMean = mean(V(aperture, :), 1, 'omitnan');

                % peak of the profile and its half-maximum crossings
                ks = M.PEAK_SEARCH_UM;
                [pk, ib] = max(prof(1:ks, :), [], 1);
                rPeak = nan(1, m); rOut = nan(1, m); rIn = zeros(1, m);
                for j = 1:m
                    if ~usable(j) || ~isfinite(pk(j)), continue; end
                    [rPeak(j), rIn(j), rOut(j)] = cellanalysis.Measure.profileRadii(prof(:, j), ib(j), pk(j), bg(j));
                end

                % the wall of a net, per direction
                wallRef = pk;
                compl = nan(1, m); angCv = nan(1, m);
                if isNet
                    Pol = nan(nb, ns, m);
                    for b = 1:nb
                        for q = 1:ns
                            if ~isempty(polIdx{b, q})
                                Pol(b, q, :) = mean(Vs(polIdx{b, q}, :), 1, 'omitnan');
                            end
                        end
                    end
                    for j = 1:m
                        if ~usable(j) || ~isfinite(rPeak(j)), continue; end
                        lo = max(1, floor(rPeak(j) - M.WALL_BAND_UM) + 1);
                        hi = min(nb, ceil(rPeak(j) + M.WALL_BAND_UM));
                        w = max(Pol(lo:hi, :, j), [], 1, 'omitnan');
                        w = w(isfinite(w));
                        if numel(w) < ns / 2, continue; end
                        ws = sort(w, 'descend');
                        wallRef(j) = ws(min(3, numel(ws)));
                        net = w - bg(j);
                        present = net >= 0.5 * (wallRef(j) - bg(j)) & net > 2 * noise(j);
                        compl(j) = nnz(present) / numel(w);
                        if mean(net) > 0
                            angCv(j) = std(net) / mean(net);
                        end
                    end
                end

                % the other channel
                if ~isempty(Fo)
                    Vo = double(Fo(Yq, Xq));
                    Ro = Vo(ring, :);
                    obg = median(Ro, 1, 'omitnan');
                    onoise = 1.4826 * median(abs(Ro - obg), 1, 'omitnan');
                    onoise = max(onoise, max(floorOther, 1e-9 * max(abs(obg), 1)));
                    oAp = mean(Vo(aperture, :), 1, 'omitnan');
                end

                for j = 1:m
                    i = idx(j);
                    if ~usable(j), continue; end
                    R(i, col('Background')) = bg(j);
                    R(i, col('ApertureNet')) = apMean(j) - bg(j);
                    if ~isempty(Fo)
                        R(i, col('OtherNet')) = oAp(j) - obg(j);
                        R(i, col('OtherSnr')) = (oAp(j) - obg(j)) / onoise(j);
                    end
                    img = reshape(Vs(:, j), n, n);
                    raw = reshape(V(:, j), n, n);
                    if keepMasks, info.Patch(:, :, i) = single(raw); end

                    % ---- outline -------------------------------------------------------------------
                    if isNet
                        peak = wallRef(j);
                    else
                        peak = max(img(pvPeak), [], 'omitnan');
                    end
                    if ~isfinite(peak) || peak - bg(j) <= 2 * noise(j), continue; end
                    thr = bg(j) + max(0.5 * (peak - bg(j)), 2 * noise(j));
                    B = img > thr & segDisk;
                    if ~any(B(:)), continue; end
                    L = bwlabel(B, 8);
                    if isNet
                        reach = rr <= max(rPeak(j) + 2, 5);
                        keep = unique(L(B & reach));
                        if isempty(keep), continue; end
                        wall = ismember(L, keep);
                        foot = cellanalysis.Measure.hullMask(wall) | wall;
                    else
                        cand = img;
                        cand(~(B & pvPeak)) = -Inf;
                        [top, at] = max(cand(:));
                        if ~isfinite(top), continue; end
                        wall = L == L(at);
                        foot = imfill(wall, 'holes');
                    end
                    sig = wall;
                    if ~isNet, sig = foot; end
                    vals = raw(sig);
                    vals = vals(isfinite(vals));
                    if isempty(vals), continue; end
                    segmented(i) = true;
                    touches(i) = any(foot(edgeBand));
                    if keepMasks
                        info.Foot(:, :, i) = foot;
                        info.Wall(:, :, i) = wall;
                    end

                    % ---- luminance -----------------------------------------------------------------
                    mu = mean(vals);
                    R(i, col('Mean')) = mu;
                    R(i, col('NetMean')) = mu - bg(j);
                    if bg(j) > 0, R(i, col('Contrast')) = (mu - bg(j)) / bg(j); end
                    R(i, col('Snr')) = (mu - bg(j)) / noise(j);
                    if tissueMedian > 0, R(i, col('MeanNorm')) = mu / tissueMedian; end
                    R(i, col('Integrated')) = sum(vals - bg(j)) * s^2;
                    R(i, col('PeakNet')) = max(img(sig), [], 'omitnan') - bg(j);
                    if ~isempty(Fo)
                        ov = Vo(foot(:), j);
                        ov = ov(isfinite(ov));
                        if ~isempty(ov)
                            R(i, col('OtherNet')) = mean(ov) - obg(j);
                            R(i, col('OtherSnr')) = (mean(ov) - obg(j)) / onoise(j);
                        end
                    end

                    % ---- shape ---------------------------------------------------------------------
                    sh = cellanalysis.Measure.shapeOf(foot, wall, isNet);
                    R(i, col('AreaUm2')) = sh.area * s^2;
                    R(i, col('DiameterUm')) = 2 * sqrt(sh.area / pi) * s;
                    R(i, col('MajorUm')) = sh.major * s;
                    R(i, col('MinorUm')) = sh.minor * s;
                    R(i, col('AspectRatio')) = sh.major / max(sh.minor, eps);
                    R(i, col('PerimeterUm')) = sh.perimeter * s;
                    R(i, col('Circularity')) = min(1, 4 * pi * sh.area / max(sh.perimeter^2, eps));
                    R(i, col('Solidity')) = min(1, sh.wallArea / max(sh.hullArea, eps));
                    R(i, col('OrientationDeg')) = sh.orientation;
                    R(i, col('RadiusUm')) = rOut(j);
                    if isNet
                        R(i, col('WallAreaUm2')) = sh.wallArea * s^2;
                        R(i, col('RingRadiusUm')) = rPeak(j);
                        R(i, col('WallThicknessUm')) = rOut(j) - rIn(j);
                        R(i, col('RingContrast')) = (pk(j) - cen(j)) / max(pk(j) - bg(j), eps);
                        R(i, col('Completeness')) = compl(j);
                        R(i, col('AngularCV')) = angCv(j);
                    end
                end
            end

            T = cellanalysis.Measure.pack(R, names, segmented, touches);
        end

        function T = spatial(xy, umPerPx, otherXY, opts)
            %SPATIAL  NnUm, LocalDensity and OtherDistUm of every row of xy (see the class help).
            if nargin < 3, otherXY = []; end
            if nargin < 4 || isempty(opts), opts = struct(); end
            densityUm = 100;
            if isfield(opts, 'DensityUm') && ~isempty(opts.DensityUm), densityUm = opts.DensityUm; end
            xy = reshape(double(xy), [], 2) * umPerPx;
            N = size(xy, 1);
            NnUm = nan(N, 1);
            LocalDensity = nan(N, 1);
            OtherDistUm = nan(N, 1);
            ok = all(isfinite(xy), 2);
            P = xy(ok, :);
            if size(P, 1) >= 2
                [~, d] = knnsearch(P, P, 'K', 2);
                NnUm(ok) = d(:, 2);
            end
            if ~isempty(P)
                near = rangesearch(P, P, densityUm);
                LocalDensity(ok) = cellfun(@numel, near) / (pi * densityUm^2) * 1e6;
            end
            if ~isempty(otherXY) && ~isempty(P)
                O = reshape(double(otherXY), [], 2) * umPerPx;
                O = O(all(isfinite(O), 2), :);
                if ~isempty(O)
                    [~, d] = knnsearch(O, P, 'K', 1);
                    OtherDistUm(ok) = d;
                end
            end
            T = table(NnUm, LocalDensity, OtherDistUm);
        end

        function R = colocalize(xy, otherXY, umPerPx, opts)
            %COLOCALIZE  One-to-one pairing of two channels and its chance level (see the class help).
            if nargin < 4 || isempty(opts), opts = struct(); end
            o = struct('MaxUm', 10, 'ShiftUm', NaN, 'Shifts', 8);
            for f = string(fieldnames(opts))'
                if ~isfield(o, f)
                    error('cellanalysis:Measure:badOption', 'Unknown option "%s".', f);
                end
                if ~isempty(opts.(f)), o.(f) = opts.(f); end
            end
            if ~isfinite(o.ShiftUm) || o.ShiftUm <= 0, o.ShiftUm = max(50, 5 * o.MaxUm); end
            P = reshape(double(xy), [], 2) * umPerPx;
            O = reshape(double(otherXY), [], 2) * umPerPx;
            N = size(P, 1); M = size(O, 1);
            R = struct('Colocalized', false(N, 1), 'Partner', zeros(N, 1), 'DistUm', nan(N, 1), ...
                'OtherColocalized', false(M, 1), 'Chance', nan(N, 1), 'MaxUm', o.MaxUm, 'ShiftUm', o.ShiftUm);
            okP = all(isfinite(P), 2);
            okO = all(isfinite(O), 2);
            if ~any(okP) || ~any(okO)
                if M > 0 && any(okO), R.Chance(:) = 0; end
                return
            end
            ip = find(okP); io = find(okO);
            [partner, d] = cellanalysis.Measure.pairUp(P(ip, :), O(io, :), o.MaxUm);
            has = partner > 0;
            R.Colocalized(ip(has)) = true;
            R.Partner(ip(has)) = io(partner(has));
            R.DistUm(ip(has)) = d(has);
            R.OtherColocalized(io(partner(has))) = true;
            hits = zeros(numel(ip), 1);
            K = max(1, round(o.Shifts));
            for k = 1:K
                th = 2 * pi * (k - 1) / K;
                pk = cellanalysis.Measure.pairUp(P(ip, :), O(io, :) + o.ShiftUm * [cos(th), sin(th)], o.MaxUm);
                hits = hits + (pk > 0);
            end
            R.Chance(ip) = hits / K;
        end

        function sh = shapeOf(foot, wall, isNet)
            %SHAPEOF  Shape of a footprint mask, in pixels of the mask (public for the tests).
            %   sh: area, major, minor, orientation (degrees), perimeter, hullArea, wallArea.
            %   foot: the filled footprint; wall: the stained pixels (= foot for a soma).
            if nargin < 2 || isempty(wall), wall = foot; end
            if nargin < 3, isNet = false; end
            [yy, xx] = find(foot);
            A = numel(xx);
            sh = struct('area', A, 'major', NaN, 'minor', NaN, 'orientation', NaN, ...
                'perimeter', NaN, 'hullArea', NaN, 'wallArea', nnz(wall));
            if A == 0, return; end
            x = xx - mean(xx);
            y = -(yy - mean(yy));                              % y up, as displayed
            uxx = sum(x .^ 2) / A + 1 / 12;
            uyy = sum(y .^ 2) / A + 1 / 12;
            uxy = sum(x .* y) / A;
            common = sqrt((uxx - uyy)^2 + 4 * uxy^2);
            sh.major = 2 * sqrt(2) * sqrt(uxx + uyy + common);
            sh.minor = 2 * sqrt(2) * sqrt(max(uxx + uyy - common, 0));
            if uyy > uxx
                num = uyy - uxx + common; den = 2 * uxy;
            else
                num = 2 * uxy; den = uxx - uyy + common;
            end
            if num == 0 && den == 0
                sh.orientation = 0;
            else
                sh.orientation = atand(num / den);
            end
            [hullA, hullP] = cellanalysis.Measure.hullOf(wall);
            sh.hullArea = hullA;
            if isNet
                sh.perimeter = hullP;
                sh.area = max(A, 1);
            else
                sh.perimeter = cellanalysis.Measure.crofton(foot);
            end
        end

        function p = crofton(B)
            %CROFTON  Perimeter of a mask in pixels (Cauchy-Crofton, 4 directions; public for the tests).
            B = padarray(logical(B), [1 1], false);
            n0 = nnz(B(:, 1:end - 1) ~= B(:, 2:end));
            n90 = nnz(B(1:end - 1, :) ~= B(2:end, :));
            n45 = nnz(B(1:end - 1, 1:end - 1) ~= B(2:end, 2:end));
            n135 = nnz(B(1:end - 1, 2:end) ~= B(2:end, 1:end - 1));
            p = pi / 8 * (n0 + n90 + (n45 + n135) / sqrt(2));
        end

    end

    methods (Static, Access = private)

        function [partner, dist] = pairUp(P, O, maxUm)
            %pairUp  One-to-one pairing of the rows of P with rows of O (micrometers) no farther
            %   than maxUm, closest pairs first. partner: row of O per row of P (0 = none).
            n = size(P, 1);
            partner = zeros(n, 1);
            dist = nan(n, 1);
            if n == 0 || isempty(O), return; end
            [idx, d] = rangesearch(O, P, maxUm);
            cnt = cellfun(@numel, idx);
            if ~any(cnt), return; end
            a = repelem((1:n)', cnt);
            b = [idx{:}]';
            dd = [d{:}]';
            [dd, ord] = sort(dd);
            a = a(ord); b = b(ord);
            usedO = false(size(O, 1), 1);
            for q = 1:numel(dd)
                if partner(a(q)) == 0 && ~usedO(b(q))
                    partner(a(q)) = b(q);
                    dist(a(q)) = dd(q);
                    usedO(b(q)) = true;
                end
            end
        end

        function T = pack(R, names, segmented, touches)
            T = array2table(R, 'VariableNames', cellstr(names));
            T.Segmented = segmented;
            T.TouchesEdge = touches;
        end

        function [F, Fs, smoothed] = interpolants(page, valid, sigmaPx)
            %interpolants  Bicubic interpolants of the page (and of a smoothed copy), NaN outside
            %   the frame and outside the valid pixels.
            P = single(page);
            P(~isfinite(P)) = NaN;
            if ~isempty(valid), P(~valid) = NaN; end
            F = griddedInterpolant(P, 'cubic', 'none');
            Fs = F;
            smoothed = false;
            if nargout > 1 && sigmaPx >= 0.5
                smoothed = true;
                ok = ~isnan(P);
                P0 = P; P0(~ok) = 0;
                num = imgaussfilt(P0, sigmaPx);
                den = imgaussfilt(single(ok), sigmaPx);
                Ps = num ./ den;
                Ps(~ok | den < 0.5) = NaN;
                Fs = griddedInterpolant(Ps, 'cubic', 'none');
            end
        end

        function [rPeak, rIn, rOut] = profileRadii(prof, ib, pk, bg)
            %profileRadii  Peak radius of a radial profile (1 um bins, centers at b - 0.5) and the
            %   radii where it crosses half of the peak above background, inside and outside.
            nb = numel(prof);
            rPeak = ib - 0.5;
            if ib == 1
                rPeak = 0;
            elseif ib < nb && all(isfinite(prof(ib - 1:ib + 1)))
                a = prof(ib - 1); b = prof(ib); c = prof(ib + 1);
                den = a - 2 * b + c;
                if den < 0
                    rPeak = ib - 0.5 + max(min(0.5 * (a - c) / den, 0.5), -0.5);
                end
            end
            half = bg + 0.5 * (pk - bg);
            rOut = NaN; rIn = 0;
            if ~(pk > bg), return; end
            for j = ib + 1:nb
                if ~isfinite(prof(j)), break; end
                if prof(j) < half
                    rOut = (j - 1.5) + (prof(j - 1) - half) / max(prof(j - 1) - prof(j), eps);
                    break
                end
            end
            for j = ib - 1:-1:1
                if ~isfinite(prof(j)), break; end
                if prof(j) < half
                    rIn = (j - 0.5) + (half - prof(j)) / max(prof(j + 1) - prof(j), eps);
                    break
                end
            end
        end

        function [area, perim, H] = hullOf(mask)
            %hullOf  The convex hull of a mask: its area and perimeter in pixels, and the hull as a
            %   mask. The area is counted in pixels like the mask's own, so a convex mask has
            %   solidity 1; the perimeter is that of the hull of the pixel centers, grown by half
            %   a pixel.
            [yy, xx] = find(mask);
            H = mask;
            area = numel(xx); perim = NaN;
            if isempty(xx), return; end
            box = 2 * (max(xx) - min(xx) + 1 + max(yy) - min(yy) + 1);
            if numel(xx) < 3 || max(xx) == min(xx) || max(yy) == min(yy)
                perim = box;
                return
            end
            try
                k = convhull(xx, yy);
            catch
                perim = box;
                return
            end
            hx = xx(k); hy = yy(k);
            H = poly2mask(hx, hy, size(mask, 1), size(mask, 2)) | mask;
            area = nnz(H);
            perim = sum(hypot(diff(hx), diff(hy))) + pi;
        end

        function H = hullMask(mask)
            %hullMask  The convex hull of a mask as a mask.
            [~, ~, H] = cellanalysis.Measure.hullOf(mask);
        end

    end
end

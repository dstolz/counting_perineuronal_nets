classdef Surface
%SURFACE  The brain surface of a section and the distance of every point from it (static, pure).
%
%   "Distance from the brain surface" is the shortest distance, in micrometers, from a cell to the
%   edge between the tissue and the empty space outside it (the pial surface of a cortical
%   section). The edge of the image frame is never surface: tissue cut off by the frame simply
%   continues beyond it.
%
%   S = cellanalysis.Surface.detect(pages, umPerPx, opts)
%       pages    H x W numeric, H x W x C, or a cell array of H x W pages of one section (every
%                page helps to tell tissue from background; any class, any intensity scale)
%       umPerPx  pixel size of the pages, micrometers
%       opts     struct, every field optional:
%         Mode          "auto" (default) | "all" | "traced"
%                         auto     the surface is the edge of the LARGEST empty area: a ventricle
%                                  or a tear is empty too, but is not the outside of the brain.
%                                  Empty areas that are parted only by a short stretch of tissue
%                                  along the frame (BridgeUm: a fold or a shred that reaches the
%                                  edge of the picture) count as one. A person's choice comes
%                                  on top: the empty area holding a point of Include is surface,
%                                  the one holding a point of Exclude is not.
%                         all      the edge of every empty area of at least MinOutsideUm2
%                         traced   the line a person drew (opts.Line); the tissue is still found
%                                  automatically (it is what areas and "in tissue" are taken from)
%         Line          M x 2 [X Y] polyline in full-resolution pixels (Mode "traced"; M >= 2)
%         Include, Exclude   K x 2 [X Y] points in full-resolution pixels (Mode "auto")
%         BridgeUm      500    see Mode "auto"
%         ReducedUm     3      the mask and the distance map are computed on pixels of about this
%                              size (never finer than the image), which bounds memory and time
%         SmoothUm      4      Gaussian smoothing before the threshold
%         Threshold     NaN    tissue threshold on the normalized image (0..1); NaN = automatic
%         CloseUm       15     cracks narrower than twice this are closed
%         OpenUm        10     tissue threads thinner than twice this are removed
%         MinTissueUm2  2.5e4  tissue islands smaller than this are debris
%         MinOutsideUm2 2.5e4  empty areas smaller than this are holes in the tissue (vessels)
%
%   S (struct)
%       Ok          a surface was found (false: Message says why; distances are NaN)
%       Message     "" or one plain sentence for a status bar
%       Mode        the mode used
%       UmPerPixel, ImageSize [H W]
%       Factor      full-resolution pixels per pixel of the reduced maps
%       Tissue      reduced logical map: tissue
%       Outside     reduced logical map: the empty area(s) whose edge is the surface (Mode
%                   "traced": the pixels the line passes through)
%       Areas       reduced label map of the empty areas (0 = tissue), AreaUsed (logical per
%                   label: its edge is surface)
%       DistUm      reduced single map: distance from the surface in micrometers (0 inside Outside)
%       Lines       cell array of K x 2 [X Y] polylines in full-resolution pixels: the surface,
%                   for drawing; OtherLines: the edges of the empty areas that are not surface
%       Line        the traced line (M x 2), or zeros(0, 2)
%       Threshold   the tissue threshold used (normalized image)
%       TissueFraction, OutsideFraction   share of the frame
%
%   d  = cellanalysis.Surface.distanceAt(S, xy)       N x 1 micrometers (NaN when ~S.Ok)
%   tf = cellanalysis.Surface.inTissue(S, xy)         N x 1 logical (true everywhere when ~S.Ok)
%   n  = cellanalysis.Surface.normalAt(S, xy)         N x 2 unit vectors pointing INTO the tissue,
%                                                     away from the surface (NaN where undefined)
%   M  = cellanalysis.Surface.tissueFull(S, growUm)   H x W logical tissue mask at full resolution,
%                                                     grown by growUm (default 0)
%   L  = cellanalysis.Surface.depthLines(S, um)       cell array of K x 2 [X Y] polylines (full-res
%                                                     pixels) along which the distance from the
%                                                     surface is UM: the inner border of the band
%                                                     within UM of it ({} when ~S.Ok or um <= 0)
%   [a, edges] = cellanalysis.Surface.depthArea(S, edgesUm, opts)
%       Tissue area (um^2) in each depth bin [edges(k), edges(k+1)), for cell densities.
%       opts.Exclude / opts.Include: cell arrays of M x 2 polygons (full-resolution pixels); area
%       inside an Exclude polygon is left out, and when Include is not empty only area inside one
%       of its polygons counts (the curation's exclusion and analysis regions).
%   xyR = cellanalysis.Surface.toReduced(S, xy), xy = cellanalysis.Surface.toFull(S, xyR)
%
%   ACCURACY. The maps have pixels of about ReducedUm, so a distance is good to a few
%   micrometers: far finer than how well the edge of a section is defined by its staining.
%   Automatic detection needs empty space in the frame. A frame filled with tissue has no
%   surface: S.Ok is false and the line must be traced.
%
%   See also cellanalysis.Project, cellanalysis.Measure.

    properties (Constant)
        VERSION = "surface/1"
        MODES = ["auto" "all" "traced"]
    end

    methods (Static)

        function o = defaults()
            %DEFAULTS  The option struct of detect with its default values.
            o = struct('Mode', "auto", 'Line', zeros(0, 2), 'Include', zeros(0, 2), 'Exclude', zeros(0, 2), ...
                'ReducedUm', 3, 'SmoothUm', 4, 'Threshold', NaN, 'CloseUm', 15, 'OpenUm', 10, ...
                'MinTissueUm2', 2.5e4, 'MinOutsideUm2', 2.5e4, 'BridgeUm', 500);
        end

        function S = detect(pages, umPerPx, opts)
            %DETECT  Find the tissue and the surface of one section (see the class help).
            if nargin < 3 || isempty(opts), opts = struct(); end
            o = cellanalysis.Surface.fill(opts);
            if ~(isnumeric(umPerPx) && isscalar(umPerPx) && isfinite(umPerPx) && umPerPx > 0)
                error('cellanalysis:Surface:badScale', 'umPerPx must be a positive finite scalar.');
            end
            pages = cellanalysis.Surface.pageList(pages);
            [H, W] = size(pages{1});

            f = max(1, round(o.ReducedUm / umPerPx));
            r = umPerPx * f;                                 % micrometers per reduced pixel
            hr = max(1, ceil(H / f));
            wr = max(1, ceil(W / f));

            S = struct('Ok', false, 'Message', "", 'Mode', o.Mode, 'UmPerPixel', umPerPx, ...
                'ImageSize', [H W], 'Factor', f, 'Tissue', true(hr, wr), 'Outside', false(hr, wr), ...
                'Areas', zeros(hr, wr), 'AreaUsed', false(0, 1), ...
                'DistUm', nan(hr, wr, 'single'), 'Lines', {{}}, 'OtherLines', {{}}, 'Line', zeros(0, 2), ...
                'Threshold', NaN, 'TissueFraction', 1, 'OutsideFraction', 0);

            % ---- one normalized image of the section, reduced ---------------------------------
            g = zeros(hr, wr, 'single');
            for k = 1:numel(pages)
                g = g + cellanalysis.Surface.reduceNormalized(pages{k}, hr, wr);
            end
            g = g / numel(pages);
            if o.SmoothUm > 0
                g = imgaussfilt(g, max(o.SmoothUm / r, 0.3));
            end

            % ---- tissue ---------------------------------------------------------------------------
            [thr, found] = cellanalysis.Surface.threshold(g, o.Threshold);
            S.Threshold = thr;
            if found
                T = g > thr;
                T = imclose(T, strel('disk', max(1, round(o.CloseUm / r)), 0));
                T = imopen(T, strel('disk', max(1, round(o.OpenUm / r)), 0));
                T = bwareaopen(T, max(1, round(o.MinTissueUm2 / r^2)));
                T = ~bwareaopen(~T, max(1, round(o.MinOutsideUm2 / r^2)), 4);
            else
                T = true(hr, wr);
            end
            S.Tissue = T;
            S.TissueFraction = nnz(T) / numel(T);
            cc = bwconncomp(~T, 4);
            S.Areas = labelmatrix(cc);
            S.AreaUsed = false(cc.NumObjects, 1);

            % ---- what the surface is the edge of --------------------------------------------------
            if o.Mode == "traced"
                line = double(o.Line);
                if size(line, 2) ~= 2 || size(line, 1) < 2 || any(~isfinite(line(:)))
                    S.Message = "No surface line is traced on this section yet.";
                    return
                end
                S.Line = line;
                src = cellanalysis.Surface.rasterize(cellanalysis.Surface.toReducedXY(line, f), hr, wr);
                if ~any(src(:))
                    S.Message = "The traced surface line lies outside the image.";
                    return
                end
                S.Lines = {line};
            else
                if ~found || ~any(~T(:))
                    S.Message = "No empty space was found beside the tissue, so the surface cannot be " + ...
                        "detected in this image: trace it on the Section tab.";
                    return
                end
                n = cellfun(@numel, cc.PixelIdxList)';
                used = true(cc.NumObjects, 1);
                if o.Mode == "auto"
                    grp = cellanalysis.Surface.bridged(S.Areas, cc.NumObjects, o.BridgeUm / r);
                    tot = accumarray(grp, n);
                    [~, big] = max(tot);
                    used = grp == big;
                    used(cellanalysis.Surface.areasAt(S.Areas, o.Include, f)) = true;
                    used(cellanalysis.Surface.areasAt(S.Areas, o.Exclude, f)) = false;
                end
                S.AreaUsed = used;
                src = ismember(S.Areas, find(used));
                if ~any(used)
                    S.Message = "Every empty area of this section is switched off as surface: switch one on, or trace the surface.";
                    S.OtherLines = cellanalysis.Surface.outlines(~T, f);
                    return
                end
                S.Lines = cellanalysis.Surface.outlines(src, f);
                S.OtherLines = cellanalysis.Surface.outlines(~T & ~src, f);
            end
            S.Outside = src;
            S.OutsideFraction = nnz(src) / numel(src);

            % distance from a pixel center to the edge of the source: half a pixel less than the
            % distance to the nearest source pixel center (a line has no width: no correction)
            d = bwdist(src);
            if o.Mode ~= "traced"
                d = max(d - 0.5, 0);
            end
            S.DistUm = single(d * r);
            S.Ok = true;
        end

        function d = distanceAt(S, xy)
            %DISTANCEAT  Distance from the surface (micrometers) of each row of xy (full-res pixels).
            xy = reshape(double(xy), [], 2);
            d = nan(size(xy, 1), 1);
            if ~S.Ok || isempty(xy), return; end
            q = cellanalysis.Surface.toReduced(S, xy);
            [hr, wr] = size(S.DistUm);
            qx = min(max(q(:, 1), 1), wr);
            qy = min(max(q(:, 2), 1), hr);
            if hr > 1 && wr > 1
                d = double(interp2(S.DistUm, qx, qy, 'linear'));
            else
                d = double(S.DistUm(sub2ind([hr wr], round(qy), round(qx))));
            end
            bad = ~all(isfinite(xy), 2);
            d(bad) = NaN;
        end

        function tf = inTissue(S, xy)
            %INTISSUE  True for the rows of xy that lie on tissue.
            xy = reshape(double(xy), [], 2);
            tf = true(size(xy, 1), 1);
            if isempty(xy), return; end
            q = round(cellanalysis.Surface.toReduced(S, xy));
            [hr, wr] = size(S.Tissue);
            ok = all(isfinite(q), 2);
            qx = min(max(q(:, 1), 1), wr);
            qy = min(max(q(:, 2), 1), hr);
            qx(~ok) = 1; qy(~ok) = 1;
            tf = S.Tissue(sub2ind([hr wr], qy, qx));
            tf(~ok) = false;
        end

        function n = normalAt(S, xy)
            %NORMALAT  Unit vectors [nx ny] (image axes: x right, y down) along which the distance
            %   from the surface grows fastest: the direction "into the tissue" at each point.
            xy = reshape(double(xy), [], 2);
            n = nan(size(xy, 1), 2);
            if ~S.Ok || isempty(xy) || any(size(S.DistUm) < 3), return; end
            % smooth first: the gradient of a distance map is undefined on its ridges
            D = imgaussfilt(S.DistUm, 2);
            [gx, gy] = gradient(D);
            q = cellanalysis.Surface.toReduced(S, xy);
            [hr, wr] = size(D);
            qx = min(max(q(:, 1), 1), wr);
            qy = min(max(q(:, 2), 1), hr);
            vx = double(interp2(gx, qx, qy, 'linear'));
            vy = double(interp2(gy, qx, qy, 'linear'));
            len = hypot(vx, vy);
            ok = len > 1e-6 & all(isfinite(xy), 2);
            n(ok, :) = [vx(ok) ./ len(ok), vy(ok) ./ len(ok)];
        end

        function M = tissueFull(S, growUm)
            %TISSUEFULL  The tissue mask at full resolution, grown by growUm micrometers.
            if nargin < 2 || isempty(growUm), growUm = 0; end
            T = S.Tissue;
            if growUm > 0
                T = imdilate(T, strel('disk', max(1, round(growUm / (S.UmPerPixel * S.Factor))), 0));
            end
            M = repelem(T, S.Factor, S.Factor);
            H = S.ImageSize(1); W = S.ImageSize(2);
            M = M(1:min(H, end), 1:min(W, end));
            if size(M, 1) < H, M(end + 1:H, :) = repmat(M(end, :), H - size(M, 1), 1); end
            if size(M, 2) < W, M(:, end + 1:W) = repmat(M(:, end), 1, W - size(M, 2)); end
        end

        function lines = depthLines(S, um)
            %DEPTHLINES  The lines at UM micrometers from the surface (see the class help).
            lines = cell(0, 1);
            if ~S.Ok || ~(isscalar(um) && isfinite(um) && um > 0) || any(size(S.DistUm) < 2), return; end
            c = contourc(double(S.DistUm), double([um um]));
            k = 1;
            while k < size(c, 2)
                n = c(2, k);
                q = c(:, k + 1:k + n)';
                k = k + n + 1;
                if n < 2, continue; end
                lines{end + 1, 1} = cellanalysis.Surface.toFull(S, q); %#ok<AGROW>
            end
        end

        function [a, edges] = depthArea(S, edgesUm, opts)
            %DEPTHAREA  Tissue area (um^2) per depth bin (see the class help).
            if nargin < 3 || isempty(opts), opts = struct(); end
            edges = double(edgesUm(:))';
            a = nan(1, max(numel(edges) - 1, 0));
            if ~S.Ok || numel(edges) < 2, return; end
            valid = S.Tissue & ~S.Outside;
            [hr, wr] = size(valid);
            if isfield(opts, 'Include') && ~isempty(opts.Include)
                inc = false(hr, wr);
                for k = 1:numel(opts.Include)
                    inc = inc | cellanalysis.Surface.polyMask(S, opts.Include{k});
                end
                valid = valid & inc;
            end
            if isfield(opts, 'Exclude') && ~isempty(opts.Exclude)
                for k = 1:numel(opts.Exclude)
                    valid = valid & ~cellanalysis.Surface.polyMask(S, opts.Exclude{k});
                end
            end
            d = double(S.DistUm(valid));
            px = (S.UmPerPixel * S.Factor)^2;
            a = histcounts(d, edges) * px;
        end

        function q = toReduced(S, xy)
            %TOREDUCED  Full-resolution pixel coordinates -> coordinates of the reduced maps.
            q = cellanalysis.Surface.toReducedXY(xy, S.Factor);
        end

        function xy = toFull(S, q)
            %TOFULL  Coordinates of the reduced maps -> full-resolution pixel coordinates.
            xy = (double(q) - 0.5) * S.Factor + 0.5;
        end

        function k = areaAt(S, xy)
            %AREAAT  Label (in S.Areas) of the empty area holding the point xy; 0 on tissue.
            k = 0;
            q = round(cellanalysis.Surface.toReduced(S, reshape(double(xy), 1, 2)));
            [hr, wr] = size(S.Areas);
            if all(isfinite(q)) && q(1) >= 1 && q(1) <= wr && q(2) >= 1 && q(2) <= hr
                k = double(S.Areas(q(2), q(1)));
            end
        end

        function h = hashOf(mode, line, include, exclude)
            %HASHOF  A short text that changes when the surface definition does (for caches).
            if nargin < 3, include = zeros(0, 2); end
            if nargin < 4, exclude = zeros(0, 2); end
            if string(mode) == "auto"
                line = [double(include); -double(exclude)];
            elseif string(mode) == "all"
                line = zeros(0, 2);
            end
            line = double(line);
            h = sprintf('%s|%s|%d|%s', cellanalysis.Surface.VERSION, char(string(mode)), size(line, 1), ...
                sprintf('%.2f,', line'));
            if strlength(h) > 120
                h = sprintf('%s|%s|%d|%.6g|%.6g', cellanalysis.Surface.VERSION, char(string(mode)), ...
                    size(line, 1), sum(line(:) .* (1:numel(line))'), sum(abs(line(:))));
            end
            h = string(h);
        end

    end

    methods (Static, Access = private)

        function o = fill(opts)
            o = cellanalysis.Surface.defaults();
            fn = fieldnames(opts);
            for i = 1:numel(fn)
                if ~isfield(o, fn{i})
                    error('cellanalysis:Surface:badOption', 'Unknown option "%s".', fn{i});
                end
                if ~isempty(opts.(fn{i}))
                    o.(fn{i}) = opts.(fn{i});
                end
            end
            o.Mode = lower(string(o.Mode));
            if ~isscalar(o.Mode) || ~any(o.Mode == cellanalysis.Surface.MODES)
                error('cellanalysis:Surface:badOption', 'Mode must be "auto", "all" or "traced".');
            end
            o.Include = reshape(double(o.Include), [], 2);
            o.Exclude = reshape(double(o.Exclude), [], 2);
        end

        function pages = pageList(pages)
            if isnumeric(pages) || islogical(pages)
                if isempty(pages) || ndims(pages) > 3
                    error('cellanalysis:Surface:badPage', 'pages must be H x W or H x W x C.');
                end
                pages = squeeze(num2cell(pages, [1 2]));
            end
            if ~iscell(pages) || isempty(pages)
                error('cellanalysis:Surface:badPage', 'pages must be a matrix or a cell array of matrices.');
            end
            pages = pages(:);
            sz = size(pages{1});
            for k = 1:numel(pages)
                if ~ismatrix(pages{k}) || isempty(pages{k}) || ~isequal(size(pages{k}), sz)
                    error('cellanalysis:Surface:badPage', 'Every page must be a non-empty H x W matrix of one size.');
                end
            end
        end

        function g = reduceNormalized(page, hr, wr)
            %reduceNormalized  The page on 0..1 (robust), averaged down to hr x wr.
            %   Invariant to a*page + b with a > 0: the low end is the page minimum when it is a
            %   padding value (it holds more than 2% of the pixels), else the 0.5th percentile;
            %   the high end the 99.5th percentile of the pixels above the low end.
            p = single(page);
            p(~isfinite(p)) = NaN;
            step = max(1, floor(sqrt(numel(p) / 4e5)));
            s = p(1:step:end, 1:step:end);
            s = s(isfinite(s));
            if isempty(s)
                g = zeros(hr, wr, 'single');
                return
            end
            lo = min(s);
            if nnz(s == lo) <= 0.02 * numel(s)
                lo = prctile(s, 0.5);
            end
            above = s(s > lo);
            if isempty(above)
                g = zeros(hr, wr, 'single');
                return
            end
            hi = prctile(above, 99.5);
            if ~(hi > lo), hi = max(above); end
            p = (p - lo) / max(hi - lo, eps('single'));
            p = min(max(p, 0), 1);
            p(isnan(p)) = 0;
            g = imresize(p, [hr wr], 'box');
        end

        function [thr, found] = threshold(g, given)
            %threshold  Split the reduced image into empty space and tissue.
            %   Otsu on the logarithm makes the first cut (tissue spans a wide range, the empty
            %   space is one dark mode). The threshold is then put a little above the empty
            %   space: 15% of the way from its median to the median of the tissue, and at least
            %   5 robust standard deviations of the empty space above it. No surface when the
            %   two classes are not clearly apart (a frame filled with tissue).
            found = false;
            thr = NaN;
            if isfinite(given)
                thr = double(given);
                found = any(g(:) <= thr) && any(g(:) > thr);
                return
            end
            v = double(g(:));
            lg = log(v + 0.005);
            lo = min(lg); hi = max(lg);
            if ~(hi > lo), return; end
            t = graythresh((lg - lo) / (hi - lo));
            cut = exp(lo + t * (hi - lo)) - 0.005;
            dark = v(v <= cut);
            bright = v(v > cut);
            if numel(dark) < 0.002 * numel(v) || isempty(bright), return; end
            dm = median(dark);
            bm = median(bright);
            ds = 1.4826 * median(abs(dark - dm));
            if ~(bm > 0) || dm > 0.4 * bm, return; end       % not two things: all tissue
            thr = dm + max(5 * ds, 0.15 * (bm - dm));
            thr = min(thr, dm + 0.6 * (bm - dm));
            found = any(v <= thr) && any(v > thr);
        end

        function grp = bridged(areas, nAreas, maxRun)
            %bridged  Group index per empty area: areas parted along the frame by a run of tissue
            %   shorter than maxRun (reduced pixels) are one group.
            grp = (1:nAreas)';
            if nAreas < 2, return; end
            [hr, wr] = size(areas);
            ring = [areas(1, 1:wr), areas(2:hr, wr)', areas(hr, wr - 1:-1:1), areas(hr - 1:-1:2, 1)'];
            ring = double(ring(:))';
            nz = find(ring > 0);
            if numel(nz) < 2, return; end
            L = numel(ring);
            for i = 1:numel(nz)
                a = nz(i);
                b = nz(mod(i, numel(nz)) + 1);
                gap = mod(b - a, L) - 1;
                la = ring(a); lb = ring(b);
                if la ~= lb && gap >= 1 && gap < maxRun
                    ga = grp(la); gb = grp(lb);
                    grp(grp == gb) = ga;
                end
            end
            [~, ~, grp] = unique(grp);
        end

        function k = areasAt(areas, pts, f)
            %areasAt  Labels of the empty areas holding the points (full-resolution pixels).
            k = zeros(0, 1);
            pts = reshape(double(pts), [], 2);
            if isempty(pts), return; end
            q = round(cellanalysis.Surface.toReducedXY(pts, f));
            [hr, wr] = size(areas);
            ok = all(isfinite(q), 2) & q(:, 1) >= 1 & q(:, 1) <= wr & q(:, 2) >= 1 & q(:, 2) <= hr;
            k = double(areas(sub2ind([hr wr], q(ok, 2), q(ok, 1))));
            k = unique(k(k > 0));
        end

        function q = toReducedXY(xy, f)
            q = (double(xy) - 0.5) / f + 0.5;
        end

        function M = rasterize(q, hr, wr)
            %rasterize  Logical hr x wr map of the pixels a polyline (reduced coordinates) crosses.
            M = false(hr, wr);
            for k = 1:size(q, 1) - 1
                a = q(k, :); b = q(k + 1, :);
                n = max(2, ceil(2 * hypot(b(1) - a(1), b(2) - a(2))) + 1);
                t = linspace(0, 1, n)';
                x = round(a(1) + t * (b(1) - a(1)));
                y = round(a(2) + t * (b(2) - a(2)));
                ok = x >= 1 & x <= wr & y >= 1 & y <= hr;
                M(sub2ind([hr wr], y(ok), x(ok))) = true;
            end
        end

        function lines = outlines(src, f)
            %outlines  The edge of the source area as polylines (full-res pixels), frame left out.
            [hr, wr] = size(src);
            B = bwboundaries(src, 8, 'noholes');
            % holes of the source are surface too (tissue islands are part of the brain's edge)
            Bh = bwboundaries(~src & imfill(src, 'holes'), 8, 'noholes');
            B = [B; Bh];
            lines = {};
            for i = 1:numel(B)
                rc = B{i};
                onFrame = rc(:, 1) <= 1 | rc(:, 1) >= hr | rc(:, 2) <= 1 | rc(:, 2) >= wr;
                if all(onFrame), continue; end
                % start the walk on the frame (when it touches it) so runs are not split in two
                first = find(onFrame, 1);
                if ~isempty(first)
                    rc = circshift(rc, -(first - 1), 1);
                    onFrame = circshift(onFrame, -(first - 1));
                end
                d = diff([true; onFrame; true]);
                starts = find(d == -1);
                stops = find(d == 1) - 1;
                for k = 1:numel(starts)
                    seg = rc(starts(k):stops(k), :);
                    if size(seg, 1) < 4, continue; end
                    xy = [seg(:, 2), seg(:, 1)];
                    w = min(5, 2 * floor((size(xy, 1) - 1) / 2) + 1);
                    if w >= 3
                        xy = [movmean(xy(:, 1), w), movmean(xy(:, 2), w)];
                    end
                    lines{end + 1, 1} = (xy - 0.5) * f + 0.5; %#ok<AGROW>
                end
            end
        end

        function M = polyMask(S, xy)
            [hr, wr] = size(S.Tissue);
            M = false(hr, wr);
            xy = double(xy);
            if size(xy, 1) < 3, return; end
            q = cellanalysis.Surface.toReduced(S, xy);
            M = poly2mask(q(:, 1), q(:, 2), hr, wr);
        end

    end
end

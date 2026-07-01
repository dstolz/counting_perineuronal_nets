function [XYnew, info] = snapToCellCentroid(I, XY, opts)
% snapToCellCentroid  Pull cell detections to their nearest cell-mass centroid.
%
%   XYnew = snapToCellCentroid(I, XY) refines a set of detected cell
%   locations XY by snapping each one to the intensity-weighted centroid of
%   the cell mass it sits on or near, using the source image I. This is a
%   localization-refinement step: the FasterRCNN detector returns a point per
%   cell, but that point is the centre of a predicted box and can land off the
%   true centre of the stained structure. Snapping recovers a consistent,
%   reproducible centre (the centre of intensity mass) for downstream cropping,
%   rescoring, neighbour resolution, and morphology.
%
%   [XYnew, info] = snapToCellCentroid(I, XY, opts) also returns per-point
%   diagnostics and the resolved parameter set (see "Outputs" below).
%
%   The routine is deliberately local and conservative: each detection is
%   refined inside its own window using locally-estimated background and
%   threshold, and a detection is only moved when a plausible blob is found
%   within a bounded search radius. Points with no nearby mass are left exactly
%   where they were (never silently dragged onto a neighbouring cell).
%
%   Two cell shapes are handled out of the box via CellType presets:
%     * "round" — parvalbumin (PV) somata: a single compact, roughly circular
%                 blob. Tight morphology, small search window.
%     * "oval"  — perineuronal nets (PNNs): an *open*, often reticular
%                 (mesh / ring-like) structure whose bright pixels form a halo
%                 or broken ring around a DARK central hole (the unstained
%                 soma), not a solid disk. A bright-mass centroid would land on
%                 the ring wall — biased toward whichever arc is brightest —
%                 rather than the hole at the centre, so this preset defaults to
%                 the "radial-symmetry" method, which votes each ring-wall
%                 pixel's gradient back toward the centre and recovers the hole
%                 even when the ring is incomplete. The preset also uses a
%                 larger window matched to the net's diameter. Orientation is
%                 irrelevant to a centre, so no orientation needs to be known.
%     * "auto"  — balanced settings that work acceptably for either (default).
%
%   Inputs
%   ------
%   I
%       The source image, given as any of:
%         * a 2-D numeric array (a single channel/page), or
%         * an H-by-W-by-C numeric array (channel selected by opts.Channel), or
%         * a char/string path to an image file (page selected by opts.Page).
%       Coordinates follow the detection-CSV convention: X is the column
%       (horizontal) and Y is the row (vertical), 1-based.
%
%   XY
%       Detections, given as either:
%         * an N-by-2 numeric matrix of [X Y] coordinates, or
%         * a table carrying numeric X and Y columns (e.g. a *_locs.csv loaded
%           with readtable). When a table is passed, XYnew is returned as a
%           copy of that table with non-destructive provenance columns added
%           (SNAP_X, SNAP_Y, SNAP_Shift, SNAP_Snapped); the original X/Y are
%           left untouched so the caller decides whether/how to apply the snap.
%
%   opts (name-value)
%   -----------------
%   Geometry / scale
%       CellType            "round" | "oval" | "auto" (default "auto"). Picks
%                           sensible defaults for every NaN-valued option below.
%       PixelSize           Microns per pixel. Default 0.645 (the training
%                           resolution; see CLAUDE.md).
%       CellDiameter        Expected cell diameter in microns. Default 18.
%       CellDiameterPx      Override the diameter directly in pixels. Default
%                           NaN => CellDiameter / PixelSize.
%       Channel             Channel to use for an H-by-W-by-C array. Default 1.
%       Page                Page to read when I is a multi-page file path.
%                           Default 1.
%
%   Preprocessing (applied once to the whole image)
%       MedianFilterSize    Square median-filter side length in pixels for
%                           speckle removal; <2 disables. Default 3.
%       BackgroundSubtraction  "none" | "tophat" | "gaussian". Default "tophat"
%                           (white top-hat with a disk larger than a cell,
%                           which flattens uneven illumination while preserving
%                           cell-sized bright structures). "gaussian" subtracts
%                           a large-sigma blur (unsharp-style high pass).
%       BackgroundRadius    Top-hat disk radius / Gaussian background sigma in
%                           pixels. Default NaN => auto from cell size.
%       SmoothingSigma      Gaussian smoothing sigma in pixels applied after
%                           background subtraction. Default NaN => auto.
%       NormLowPercentile   Low/high percentiles used to robustly rescale the
%       NormHighPercentile  resized image to [0,1] before thresholding.
%                           Defaults 1 and 99.5.
%
%   Segmentation (per window)
%       ThresholdMethod     "otsu" | "adaptive" | "relative". Default "otsu".
%       ThresholdScale      Multiplier on the Otsu threshold. <1 grows blobs,
%                           >1 shrinks them. Default 1.0.
%       AdaptiveK           For "adaptive": threshold = mean + AdaptiveK*std of
%                           the window. Default 1.0.
%       RelativeThreshold   For "relative": fraction of the window's intensity
%                           range, in [0,1]. Default 0.5.
%       CloseRadius         Morphological-closing disk radius in pixels (bridges
%                           gaps in reticular PNNs). Default NaN => auto.
%       FillHoles           Fill enclosed holes so a ring becomes a disk.
%                           Default true.
%       MinBlobArea         Accepted blob area bounds in pixels. Blobs outside
%       MaxBlobArea         the range are ignored. Defaults NaN => auto.
%
%   Search / snapping
%       Method              "auto" (default) picks the method from CellType:
%                           "radial-symmetry" for "oval"/PNN rings, otherwise
%                           "weighted-centroid". Pass an explicit value to
%                           override:
%                             "weighted-centroid" segments the local mass and
%                               takes its intensity-weighted centroid (best for
%                               solid, round somata such as PV).
%                             "radial-symmetry" finds the centre of a ring/halo
%                               by voting each bright ring-wall pixel's gradient
%                               inward and outward by the expected ring radius;
%                               votes from the whole annulus — even a single arc
%                               of an OPEN or reticular net — pile up at the dark
%                               centre. This is the right choice for PNNs, where
%                               the centre is a hole rather than a bright peak.
%                             "mean-shift" iteratively climbs to the local
%                               intensity mode with a Gaussian kernel (threshold
%                               free). NB it climbs to the BRIGHTEST point, so it
%                               lands on the ring wall, not the hole — prefer
%                               "radial-symmetry" for ring-like PNNs.
%       WindowRadius        Half-size of the square analysis window in pixels.
%                           Default NaN => auto.
%       SearchRadius        Max distance (px) from a detection to a candidate
%                           blob's centroid for that blob to be eligible.
%                           Default NaN => auto.
%       MaxShift            Max distance (px) a detection may move. Default
%                           NaN => equals SearchRadius.
%       KernelRadius        Gaussian kernel sigma (px) for "mean-shift".
%                           Default NaN => auto.
%       RingRadius          Expected ring/halo radius (px) for "radial-symmetry"
%                           — the distance from the dark centre to the bright
%                           wall. Default NaN => auto (~ half the cell diameter).
%       RingRadiusTolerance Fractional half-width of the radius band voted over
%                           for "radial-symmetry", so a range of net sizes and
%                           ring thicknesses all reinforce the same centre.
%                           Default NaN => auto.
%       GradientPercentile  For "radial-symmetry": percentile of gradient
%                           magnitude above which a pixel is treated as a ring
%                           wall and allowed to vote. Higher keeps only the
%                           strongest edges. Default NaN => auto.
%       DarkCenter          For "radial-symmetry": when true (default) bias the
%                           vote map toward locations that are darker than their
%                           surroundings, so the snap lands in the net's hole
%                           rather than on the wall. Set false for bright-centred
%                           targets.
%       RefineIterations    Re-centre the window on the new centroid and repeat,
%                           up to this many passes (early-out on convergence).
%                           Default 2.
%       ConvergenceTol      Stop iterating once a pass moves less than this many
%                           pixels. Default 0.5.
%       OverMaxShiftAction  What to do when the snap exceeds MaxShift:
%                           "reject" keeps the original point (default),
%                           "clamp" moves it MaxShift px toward the centroid,
%                           "keep" accepts the full move anyway.
%       Plot                If true, overlay original (red) and snapped (green)
%                           points with displacement arrows for visual QC.
%                           Default false.
%
%   Outputs
%   -------
%   XYnew
%       N-by-2 snapped [X Y] (or, for table input, the annotated table).
%   info
%       Struct of per-point diagnostics and bookkeeping:
%         .Snapped      N-by-1 logical, true where the point was moved.
%         .Shift        N-by-1 displacement in pixels (0 where not snapped).
%         .BlobArea     N-by-1 area of the selected blob (NaN if none).
%         .Eccentricity N-by-1 blob eccentricity (0 round .. 1 line; NaN for
%                       mean-shift, radial-symmetry, or unsnapped points).
%         .Orientation  N-by-1 blob major-axis angle in degrees (NaN as above).
%         .Reason       N-by-1 string explaining each outcome.
%         .Params       The fully-resolved option struct actually used.
%         .CellDiameterPx, .Method, .NumSnapped, .NumPoints.
%
%   Examples
%   --------
%       % PV somata on channel 2 of a TIFF, table in / table out:
%       T  = readtable('img_PV2_locs.csv');
%       img = imread('img.tif', 2);
%       T2 = snapToCellCentroid(img, T, CellType="round");
%       T2.X = T2.SNAP_X;  T2.Y = T2.SNAP_Y;   % apply the snap
%
%       % PNNs (open, ring-like nets), with a QC overlay. CellType="oval"
%       % already selects the radial-symmetry ring-centre finder by default:
%       [xy, info] = snapToCellCentroid('img.tif', [T.X T.Y], ...
%                        CellType="oval", Plot=true);
%
%   Requires the Image Processing Toolbox (imtophat, imgaussfilt, imclose,
%   imfill, bwareaopen, bwlabel, regionprops, graythresh, strel,
%   imgradientxy).
%
%   See also findCellNeighbors, correctBidirectionalLSMArtifact.

    arguments
        I
        XY
        opts.CellType (1,1) string {mustBeMember(opts.CellType, ["round","oval","auto"])} = "auto"
        opts.PixelSize (1,1) double {mustBePositive} = 0.645
        opts.CellDiameter (1,1) double {mustBePositive} = 18
        opts.CellDiameterPx (1,1) double = NaN
        opts.Channel (1,1) double {mustBeInteger, mustBePositive} = 1
        opts.Page (1,1) double {mustBeInteger, mustBePositive} = 1
        % preprocessing
        opts.MedianFilterSize (1,1) double {mustBeInteger, mustBeNonnegative} = 3
        opts.BackgroundSubtraction (1,1) string {mustBeMember(opts.BackgroundSubtraction, ["none","tophat","gaussian"])} = "tophat"
        opts.BackgroundRadius (1,1) double = NaN
        opts.SmoothingSigma (1,1) double = NaN
        opts.NormLowPercentile (1,1) double {mustBeInRange(opts.NormLowPercentile, 0, 100)} = 1
        opts.NormHighPercentile (1,1) double {mustBeInRange(opts.NormHighPercentile, 0, 100)} = 99.5
        % segmentation
        opts.Method (1,1) string {mustBeMember(opts.Method, ["auto","weighted-centroid","mean-shift","radial-symmetry"])} = "auto"
        opts.ThresholdMethod (1,1) string {mustBeMember(opts.ThresholdMethod, ["otsu","adaptive","relative"])} = "otsu"
        opts.ThresholdScale (1,1) double {mustBePositive} = 1.0
        opts.AdaptiveK (1,1) double = 1.0
        opts.RelativeThreshold (1,1) double {mustBeInRange(opts.RelativeThreshold, 0, 1)} = 0.5
        opts.CloseRadius (1,1) double = NaN
        opts.FillHoles (1,1) logical = true
        opts.MinBlobArea (1,1) double = NaN
        opts.MaxBlobArea (1,1) double = NaN
        % search / snapping
        opts.WindowRadius (1,1) double = NaN
        opts.SearchRadius (1,1) double = NaN
        opts.MaxShift (1,1) double = NaN
        opts.KernelRadius (1,1) double = NaN
        opts.RingRadius (1,1) double = NaN
        opts.RingRadiusTolerance (1,1) double = NaN
        opts.GradientPercentile (1,1) double = NaN
        opts.DarkCenter (1,1) logical = true
        opts.RefineIterations (1,1) double {mustBeInteger, mustBePositive} = 2
        opts.ConvergenceTol (1,1) double {mustBeNonnegative} = 0.5
        opts.OverMaxShiftAction (1,1) string {mustBeMember(opts.OverMaxShiftAction, ["reject","clamp","keep"])} = "reject"
        opts.Plot (1,1) logical = false
    end

    % --- Normalise the detection input (numeric matrix or table) -----------
    isTableIn = istable(XY);
    if isTableIn
        Tin = XY;
        if ~all(ismember({'X','Y'}, Tin.Properties.VariableNames))
            error("snapToCellCentroid:missingXY", ...
                "Table input must contain numeric X and Y columns.");
        end
        xy0 = [double(Tin.X), double(Tin.Y)];
    else
        if ~isnumeric(XY) || (~isempty(XY) && size(XY, 2) ~= 2)
            error("snapToCellCentroid:badXY", ...
                "XY must be an N-by-2 numeric matrix of [X Y] or a table.");
        end
        xy0 = double(XY);
    end
    nPts = size(xy0, 1);

    % --- Resolve the working grayscale image -------------------------------
    Ig = loadGrayImage(I, opts.Channel, opts.Page);
    [H, W] = size(Ig);

    % --- Resolve all NaN ("auto") parameters from the cell-size preset -----
    R = resolveParams(opts);

    % --- Preprocess the whole image once (background / smoothing / norm) ---
    In = preprocessImage(Ig, R);

    % --- Allocate diagnostics ----------------------------------------------
    xyNew    = xy0;
    snapped  = false(nPts, 1);
    shift    = zeros(nPts, 1);
    blobArea = nan(nPts, 1);
    blobEcc  = nan(nPts, 1);
    blobOri  = nan(nPts, 1);
    reason   = strings(nPts, 1);

    % --- Snap each point ---------------------------------------------------
    for k = 1:nPts
        x0 = xy0(k, 1);
        y0 = xy0(k, 2);

        % Skip points that are off-image or non-finite — nothing to snap to.
        if ~isfinite(x0) || ~isfinite(y0) || x0 < 1 || y0 < 1 || x0 > W || y0 > H
            reason(k) = "off image";
            continue;
        end

        switch R.Method
            case "mean-shift"
                [nx, ny, didSnap, why] = snapMeanShift(In, x0, y0, R);
                a = NaN; e = NaN; o = NaN;
            case "radial-symmetry"
                [nx, ny, didSnap, why] = snapRadialSymmetry(In, x0, y0, R);
                a = NaN; e = NaN; o = NaN;
            otherwise   % "weighted-centroid"
                [nx, ny, didSnap, a, e, o, why] = snapWeightedCentroid(In, x0, y0, R);
        end

        % Enforce the maximum-shift policy on the cumulative displacement.
        d = hypot(nx - x0, ny - y0);
        if didSnap && d > R.MaxShift
            switch R.OverMaxShiftAction
                case "reject"
                    nx = x0; ny = y0; didSnap = false; d = 0;
                    why = "exceeded MaxShift";
                case "clamp"
                    s  = R.MaxShift / d;
                    nx = x0 + (nx - x0) * s;
                    ny = y0 + (ny - y0) * s;
                    d  = R.MaxShift;
                    why = "clamped to MaxShift";
                case "keep"
                    % accept the full move
            end
        end

        xyNew(k, :)  = [nx, ny];
        snapped(k)   = didSnap;
        shift(k)     = d;
        blobArea(k)  = a;
        blobEcc(k)   = e;
        blobOri(k)   = o;
        reason(k)    = why;
    end

    % --- Assemble outputs --------------------------------------------------
    info = struct();
    info.Snapped       = snapped;
    info.Shift         = shift;
    info.BlobArea      = blobArea;
    info.Eccentricity  = blobEcc;
    info.Orientation   = blobOri;
    info.Reason        = reason;
    info.Params        = R;
    info.CellDiameterPx = R.CellDiameterPx;
    info.Method        = R.Method;
    info.NumPoints     = nPts;
    info.NumSnapped    = sum(snapped);

    if opts.Plot
        plotSnapOverlay(Ig, xy0, xyNew, snapped);
    end

    if isTableIn
        Tout = Tin;
        Tout.SNAP_X       = xyNew(:, 1);
        Tout.SNAP_Y       = xyNew(:, 2);
        Tout.SNAP_Shift   = shift;
        Tout.SNAP_Snapped = snapped;
        XYnew = Tout;
    else
        XYnew = xyNew;
    end
end

% =====================================================================
%  Parameter resolution
% =====================================================================
function R = resolveParams(opts)
    % Fill in every NaN-valued ("auto") option from the cell-size preset, and
    % coerce the values that index pixels / structuring elements to integers.
    R = opts;

    if isnan(opts.CellDiameterPx)
        R.CellDiameterPx = opts.CellDiameter / opts.PixelSize;
    else
        R.CellDiameterPx = opts.CellDiameterPx;
    end
    d   = R.CellDiameterPx;
    rad = 0.5 * d;

    % Per-shape multipliers. Oval/PNN gets a bigger window, stronger closing,
    % and a wider area band than the compact round/PV soma.
    switch opts.CellType
        case "round"
            k = struct('win',1.0,'search',0.60,'bg',1.5,'close',0.12, ...
                       'minA',0.15,'maxA',3.0,'kernel',0.60,'smooth',0.08, ...
                       'ring',0.85,'ringtol',0.30,'gradpct',75);
        case "oval"
            k = struct('win',1.6,'search',0.90,'bg',2.0,'close',0.30, ...
                       'minA',0.10,'maxA',6.0,'kernel',0.80,'smooth',0.12, ...
                       'ring',0.95,'ringtol',0.40,'gradpct',65);
        otherwise   % "auto"
            k = struct('win',1.3,'search',0.75,'bg',1.8,'close',0.20, ...
                       'minA',0.12,'maxA',4.5,'kernel',0.70,'smooth',0.10, ...
                       'ring',0.90,'ringtol',0.35,'gradpct',70);
    end

    if isnan(opts.WindowRadius),     R.WindowRadius     = max(3, round(k.win   * d)); end
    if isnan(opts.SearchRadius),     R.SearchRadius     = max(2, k.search * d);       end
    if isnan(opts.MaxShift),         R.MaxShift         = R.SearchRadius;             end
    if isnan(opts.BackgroundRadius), R.BackgroundRadius = max(2, round(k.bg    * d)); end
    if isnan(opts.CloseRadius),      R.CloseRadius      = max(0, round(k.close * d)); end
    if isnan(opts.SmoothingSigma),   R.SmoothingSigma   = max(0, k.smooth * d);       end
    if isnan(opts.KernelRadius),     R.KernelRadius     = max(1, k.kernel * d);       end
    if isnan(opts.MinBlobArea),      R.MinBlobArea      = max(1, round(k.minA * pi * rad^2)); end
    if isnan(opts.MaxBlobArea),      R.MaxBlobArea      = round(k.maxA * pi * rad^2);  end

    % radial-symmetry (ring-centre) parameters
    if isnan(opts.RingRadius),          R.RingRadius          = max(2, k.ring * rad); end
    if isnan(opts.RingRadiusTolerance), R.RingRadiusTolerance = k.ringtol;            end
    if isnan(opts.GradientPercentile),  R.GradientPercentile  = k.gradpct;            end
    R.RingRadiusTolerance = min(max(R.RingRadiusTolerance, 0), 0.95);
    R.GradientPercentile  = min(max(R.GradientPercentile, 1), 99);

    % Resolve the "auto" method from the cell-shape preset: ring-like PNNs use
    % the radial-symmetry centre finder (the centre is a dark hole, not a bright
    % peak); compact somata use the bright-mass centroid.
    if R.Method == "auto"
        switch opts.CellType
            case "oval"
                R.Method = "radial-symmetry";
            otherwise
                R.Method = "weighted-centroid";
        end
    end

    % Integerise the pixel-indexing / structuring-element parameters.
    R.WindowRadius = max(3, round(R.WindowRadius));
    R.MinBlobArea  = max(1, round(R.MinBlobArea));
    R.MaxBlobArea  = max(R.MinBlobArea + 1, round(R.MaxBlobArea));
    R.CloseRadius  = max(0, round(R.CloseRadius));
end

% =====================================================================
%  Image loading & preprocessing
% =====================================================================
function Ig = loadGrayImage(I, channel, page)
    % Resolve the input to a 2-D double grayscale image.
    if ischar(I) || isstring(I)
        path = char(I);
        if exist(path, 'file') ~= 2
            error("snapToCellCentroid:noImage", "Image file not found: %s", path);
        end
        nP = numel(imfinfo(path));
        if nP <= 1
            I = imread(path);
        else
            I = imread(path, min(max(page, 1), nP));
        end
    end

    if ndims(I) <= 2
        Ig = I;
    else
        c = min(max(round(channel), 1), size(I, 3));
        Ig = I(:, :, c);
    end
    Ig = double(Ig);
end

function In = preprocessImage(Ig, R)
    % One-time global preprocessing producing a non-negative image robustly
    % rescaled to [0,1], used both as the threshold input and the centroid
    % weighting. Done globally (not per window) so background and contrast are
    % estimated consistently and without per-window edge effects.
    Ip = Ig;

    if R.MedianFilterSize >= 2
        Ip = medfilt2(Ip, [R.MedianFilterSize R.MedianFilterSize], 'symmetric');
    end

    switch R.BackgroundSubtraction
        case "tophat"
            % White top-hat: subtract a morphological opening with a disk that
            % is larger than a cell, removing slow background while keeping
            % cell-sized bright structures intact.
            Ip = imtophat(Ip, strel('disk', max(1, round(R.BackgroundRadius))));
        case "gaussian"
            Ip = Ip - imgaussfilt(Ip, max(1, R.BackgroundRadius));
            Ip = max(Ip, 0);
        case "none"
            % leave as-is
    end

    if R.SmoothingSigma > 0
        Ip = imgaussfilt(Ip, R.SmoothingSigma);
    end

    lo = percentileValue(Ip, R.NormLowPercentile);
    hi = percentileValue(Ip, R.NormHighPercentile);
    if hi <= lo
        hi = lo + eps(max(abs(lo), 1));
    end
    In = (Ip - lo) ./ (hi - lo);
    In = min(max(In, 0), 1);
end

% =====================================================================
%  Per-point snapping: segmentation + weighted centroid
% =====================================================================
function [nx, ny, snapped, area, ecc, ori, reason] = snapWeightedCentroid(In, x0, y0, R)
    [H, W] = size(In);
    cx = x0; cy = y0;
    nx = x0; ny = y0;
    snapped = false; area = NaN; ecc = NaN; ori = NaN; reason = "no blob";

    for it = 1:R.RefineIterations
        % Window around the current estimate, clipped to the image.
        c1 = max(1, floor(cx - R.WindowRadius)); c2 = min(W, ceil(cx + R.WindowRadius));
        r1 = max(1, floor(cy - R.WindowRadius)); r2 = min(H, ceil(cy + R.WindowRadius));
        sub = In(r1:r2, c1:c2);
        if max(sub(:)) <= 0
            reason = "empty window"; break;
        end

        t  = computeThreshold(sub, R);
        bw = sub >= t & sub > 0;
        if R.CloseRadius >= 1
            bw = imclose(bw, strel('disk', R.CloseRadius));
        end
        if R.FillHoles
            bw = imfill(bw, 'holes');
        end
        bw = bwareaopen(bw, R.MinBlobArea);
        if ~any(bw(:))
            reason = "no blob"; break;
        end

        L     = bwlabel(bw);
        stats = regionprops(L, sub, 'WeightedCentroid', 'Area', ...
                                    'Eccentricity', 'Orientation');
        areas = [stats.Area];
        valid = find(areas >= R.MinBlobArea & areas <= R.MaxBlobArea);
        if isempty(valid)
            reason = "blob area out of range"; break;
        end

        % Detection position inside the window (1-based).
        dxw = cx - c1 + 1;
        dyw = cy - r1 + 1;
        rxw = min(max(round(dxw), 1), size(sub, 2));
        ryw = min(max(round(dyw), 1), size(sub, 1));
        containLabel = L(ryw, rxw);   % >0 if the point sits inside a blob

        % Choose the blob containing the point, else the nearest valid blob
        % whose centroid is within the search radius.
        bestD = inf; bestRegion = 0;
        for q = valid
            cwc = stats(q).WeightedCentroid;   % [x y] in window coords
            dd  = hypot(cwc(1) - dxw, cwc(2) - dyw);
            if q == containLabel
                dd = 0;
            end
            if dd < bestD
                bestD = dd; bestRegion = q;
            end
        end
        if bestRegion == 0 || bestD > R.SearchRadius
            reason = "no blob within search radius"; break;
        end

        cwc = stats(bestRegion).WeightedCentroid;
        nx  = c1 - 1 + cwc(1);
        ny  = r1 - 1 + cwc(2);
        area = stats(bestRegion).Area;
        ecc  = stats(bestRegion).Eccentricity;
        ori  = stats(bestRegion).Orientation;
        snapped = true; reason = "ok";

        move = hypot(nx - cx, ny - cy);
        cx = nx; cy = ny;
        if move <= R.ConvergenceTol
            break;   % converged: re-centring no longer moves the estimate
        end
    end
end

function t = computeThreshold(sub, R)
    % Per-window foreground threshold on the [0,1] normalised window.
    switch R.ThresholdMethod
        case "otsu"
            t = graythresh(sub) * R.ThresholdScale;
        case "adaptive"
            t = mean(sub(:)) + R.AdaptiveK * std(sub(:));
        case "relative"
            lo = min(sub(:)); hi = max(sub(:));
            t  = lo + R.RelativeThreshold * (hi - lo);
    end
    t = min(max(t, 0), 1);
end

% =====================================================================
%  Per-point snapping: threshold-free mean-shift
% =====================================================================
function [nx, ny, snapped, reason] = snapMeanShift(In, x0, y0, R)
    % Iteratively move to the intensity-weighted mean within a Gaussian kernel,
    % i.e. climb to the local mode of the (resized) intensity surface.
    % No threshold is needed, which is robust for faint or ring-like PNNs.
    [H, W] = size(In);
    cx = x0; cy = y0;
    snapped = false; reason = "ok";
    sigma  = max(1, R.KernelRadius);
    maxIter = max(R.RefineIterations, 25);   % mean-shift wants room to climb

    for it = 1:maxIter
        c1 = max(1, floor(cx - R.WindowRadius)); c2 = min(W, ceil(cx + R.WindowRadius));
        r1 = max(1, floor(cy - R.WindowRadius)); r2 = min(H, ceil(cy + R.WindowRadius));
        sub = In(r1:r2, c1:c2);

        [gx, gy] = meshgrid(c1:c2, r1:r2);     % full-image coords of the window
        d2   = (gx - cx).^2 + (gy - cy).^2;
        kern = exp(-d2 ./ (2 * sigma^2));
        kern(d2 > R.WindowRadius^2) = 0;       % hard support at the window edge
        wgt  = sub .* kern;
        wgt(sub <= 0) = 0;

        sw = sum(wgt(:));
        if sw <= 0
            reason = "empty window"; break;
        end
        nx = sum(wgt(:) .* gx(:)) / sw;
        ny = sum(wgt(:) .* gy(:)) / sw;

        move = hypot(nx - cx, ny - cy);
        cx = nx; cy = ny;
        snapped = true;
        if move <= R.ConvergenceTol
            break;
        end
    end
    nx = cx; ny = cy;
end

% =====================================================================
%  Per-point snapping: radial-symmetry ring-centre finder
% =====================================================================
function [nx, ny, snapped, reason] = snapRadialSymmetry(In, x0, y0, R)
    % Snap to the centre of a ring / halo (a bright wall around a DARK hole),
    % robust to OPEN, partial, or reticular nets where the bright pixels form an
    % arc or mesh rather than a closed circle — the typical appearance of a
    % perineuronal net.
    %
    % Idea (a localised Fast Radial Symmetry Transform, Loy & Zelinsky 2003):
    % every bright ring-wall pixel has an intensity gradient that points across
    % the wall, i.e. along the local radius. Stepping from each wall pixel both
    % inward and outward by the expected ring radius lands on the ring centre, so
    % each wall pixel "votes" for the centre. Votes from anywhere on the annulus
    % — even a single surviving arc — accumulate at the geometric centre, while
    % off-centre locations collect only incoherent votes. Because the net centre
    % is a dark hole (not a bright peak), the vote map is additionally biased
    % toward dark locations, which prevents the snap from settling on the bright
    % wall the way a brightest-point method (mean-shift) would.
    [H, W] = size(In);
    cx = x0; cy = y0;
    nx = x0; ny = y0;
    snapped = false; reason = "no ring";

    % Vote over a band of radii so a range of net sizes / wall thicknesses all
    % reinforce the same centre. Cap the count to keep the central peak tight.
    ringR = max(2, R.RingRadius);
    tol   = min(max(R.RingRadiusTolerance, 0), 0.95);
    rLo   = max(1, ringR * (1 - tol));
    rHi   = ringR * (1 + tol);
    nR    = min(7, max(3, round(rHi - rLo) + 1));
    radii = linspace(rLo, rHi, nR);

    for it = 1:R.RefineIterations
        % Window around the current estimate, clipped to the image.
        c1 = max(1, floor(cx - R.WindowRadius)); c2 = min(W, ceil(cx + R.WindowRadius));
        r1 = max(1, floor(cy - R.WindowRadius)); r2 = min(H, ceil(cy + R.WindowRadius));
        sub = In(r1:r2, c1:c2);
        [sh, sw] = size(sub);
        if sh < 5 || sw < 5 || max(sub(:)) <= 0
            reason = "empty window"; break;
        end

        % Gradient field = the radial direction at each ring wall.
        [Gx, Gy] = imgradientxy(sub, 'sobel');
        Gmag = hypot(Gx, Gy);
        gmax = max(Gmag(:));
        if gmax <= 0
            reason = "no ring edges"; break;
        end

        % Keep the strongest gradients (the ring walls); ignore flat background.
        gPos = Gmag(Gmag > 0);
        thr  = percentileValue(gPos, R.GradientPercentile);
        edge = Gmag >= max(thr, 0.05 * gmax);
        if nnz(edge) < 8
            reason = "too few ring edges"; break;
        end

        [ey, ex] = find(edge);
        wv = Gmag(edge);                 % vote weight = edge strength
        ux = Gx(edge) ./ Gmag(edge);     % unit radial direction (x = col)
        uy = Gy(edge) ./ Gmag(edge);     % unit radial direction (y = row)

        % Accumulate symmetric votes at +/- each radius along the gradient. The
        % centre is hit by inner-wall pixels (one sign) and outer-wall pixels
        % (the other), so both signs reinforce it.
        A = zeros(sh, sw);
        for r = radii
            for s = [-1, 1]
                vx = round(ex + s * r .* ux);
                vy = round(ey + s * r .* uy);
                inb = vx >= 1 & vx <= sw & vy >= 1 & vy <= sh;
                if any(inb)
                    A = A + accumarray([vy(inb), vx(inb)], wv(inb), [sh, sw]);
                end
            end
        end
        if max(A(:)) <= 0
            reason = "no symmetry votes"; break;
        end

        % Coalesce votes from neighbouring radii / edges into a smooth peak.
        A = imgaussfilt(A, max(1, 0.3 * ringR));

        % Favour dark centres: a net centre is a hole inside the bright wall, so
        % scale the votes by how dark each candidate is (bounded to [0.5,1] so a
        % faint centre is still admissible).
        if R.DarkCenter
            S = A .* (1 - 0.5 * min(max(sub, 0), 1));
        else
            S = A;
        end

        % Restrict candidates to within the search radius of the current point.
        dxw = cx - c1 + 1;  dyw = cy - r1 + 1;
        [gxw, gyw] = meshgrid(1:sw, 1:sh);
        within = (gxw - dxw).^2 + (gyw - dyw).^2 <= R.SearchRadius^2;
        if ~any(within(:))
            reason = "search radius empty"; break;
        end
        Sm = S; Sm(~within) = -inf;

        [~, idx] = max(Sm(:));
        [py, px] = ind2sub([sh, sw], idx);

        % Reject diffuse vote maps (no real ring): require the peak to stand out
        % from the bulk of the within-radius votes, so points over plain texture
        % are left where they are rather than dragged onto noise.
        wvals = S(within);
        if S(py, px) <= 3 * mean(wvals)
            reason = "weak radial symmetry"; break;
        end

        % Sub-pixel centre: vote-weighted centroid in a small neighbourhood of
        % the peak (uses the raw votes A, not the darkness-biased S).
        ringHalf = 2;
        xa = max(1, px - ringHalf):min(sw, px + ringHalf);
        ya = max(1, py - ringHalf):min(sh, py + ringHalf);
        patch = A(ya, xa);
        patch = max(patch - min(patch(:)), 0);
        if sum(patch(:)) > 0
            [pxg, pyg] = meshgrid(xa, ya);
            sxp = sum(patch(:) .* pxg(:)) / sum(patch(:));
            syp = sum(patch(:) .* pyg(:)) / sum(patch(:));
        else
            sxp = px; syp = py;
        end

        nx = c1 - 1 + sxp;
        ny = r1 - 1 + syp;
        snapped = true; reason = "ok";

        move = hypot(nx - cx, ny - cy);
        cx = nx; cy = ny;
        if move <= R.ConvergenceTol
            break;   % converged: re-centring no longer moves the estimate
        end
    end
end

% =====================================================================
%  Small utilities
% =====================================================================
function v = percentileValue(x, p)
    % Linear-interpolated percentile without a Statistics-Toolbox dependency.
    x = sort(x(:));
    x = x(~isnan(x));
    n = numel(x);
    if n == 0
        v = 0; return;
    end
    if n == 1
        v = x(1); return;
    end
    rank = (p / 100) * (n - 1) + 1;
    lo = floor(rank); hi = ceil(rank); frac = rank - lo;
    v = x(lo) * (1 - frac) + x(hi) * frac;
end

function plotSnapOverlay(Ig, xy0, xyNew, snapped)
    % Visual QC: image with original points (red), snapped points (green), and
    % displacement arrows. Guarded so a plotting failure never breaks a batch.
    try
        f = figure('Name', 'snapToCellCentroid — QC overlay', 'Color', 'w');
        ax = axes(f);
        imagesc(ax, Ig); colormap(ax, gray); axis(ax, 'image'); hold(ax, 'on');
        mv = snapped & (hypot(xyNew(:,1) - xy0(:,1), xyNew(:,2) - xy0(:,2)) > 0);
        if any(mv)
            quiver(ax, xy0(mv,1), xy0(mv,2), ...
                       xyNew(mv,1) - xy0(mv,1), xyNew(mv,2) - xy0(mv,2), ...
                       0, 'Color', [1 1 0], 'MaxHeadSize', 0.4, 'LineWidth', 0.75);
        end
        plot(ax, xy0(:,1),  xy0(:,2),  'o', 'MarkerEdgeColor', [0.9 0.2 0.2], ...
             'MarkerSize', 6, 'LineWidth', 1);
        plot(ax, xyNew(:,1), xyNew(:,2), '+', 'MarkerEdgeColor', [0.2 0.9 0.2], ...
             'MarkerSize', 7, 'LineWidth', 1.25);
        title(ax, sprintf('%d / %d detections snapped (red = original, green = snapped)', ...
              sum(snapped), numel(snapped)));
        hold(ax, 'off');
    catch
        % ignore plotting errors
    end
end

function [folder, truth] = makeSyntheticDataset(outDir, opts)
%makeSyntheticDataset  Write a small synthetic Cell* dataset (image, detections, legacy files) with known truth.
%   [FOLDER, TRUTH] = makeSyntheticDataset(OUTDIR) creates OUTDIR (if missing) and writes files that mirror
%   the real data layout, for BaseName "SYN-0001_sec1":
%
%     <Base>_proj.tif                          2-page float32 TIFF with resolution tags (UmPerPixel).
%                                              Page 1: ring-like cells (perineuronal nets, ~18 um);
%                                              page 2: solid Gaussian blobs (PV somata, ~15 um).
%     <Base>_proj_ECM1_locs.csv                detections of page 1: X,Y,class,score,imgName,thr,rescore
%     <Base>_proj_PV2_locs.csv                 detections of page 2
%     <Base>_proj_ECM1_locs.redetected.csv     (Variants) a re-detection of the same cells, other order
%     <Base>_proj_PV2_locs.redetected.csv        (not named *_locs.csv, so discovery ignores them; a test
%                                                copies one over the original to simulate re-detection)
%     <Base>_proj_PV2_locs_QC.csv              legacy CellQualityControl file labelling about half the rows
%     <Base>_proj_ECM1_locs.resolver.csv       legacy CellNeighborResolution file (CURATED_X/Y, pair status)
%
%   Name-value options (defaults)
%     ImageSize      [600 800]   rows, columns
%     NumCells       [120 180]   true cells of channel 1 (ECM) and channel 2 (PV)
%     UmPerPixel     1.657
%     Seed           1           everything is deterministic from it (a private RandStream is used)
%     BaseName       "SYN-0001_sec1"
%     IntensityScale 3000        float32 pixel values reach about this, deliberately not 0-255
%     Variants       true        also write the redetected, QC and resolver files
%
%   Coordinates: X is the column and Y the row of a 1-based pixel grid (pixel centres at integers).
%
%   TRUTH fields
%     baseName, umPerPixel, imageSize, seed, paths (struct of file paths)
%     ECM1, PV2 (one struct per channel key):
%        cellsXY         true cell positions [N x 2]
%        locs            the detections table as written to the original locs CSV
%        det             table Row, Kind ("tp"|"fp"|"dup"), TrueIdx (row of cellsXY, 0 for fp), DupOfRow
%        missedIdx       true cells without a detection (the 5% misses)
%        dupGroups       cell array of row vectors: each duplicate pair [primary dup], and the 3-member cluster
%        redet           table Row, Kind, TrueIdx, OldRow (0 = new detection) of the redetected CSV
%        droppedOldRows  rows of the original that the redetection no longer has
%     qc        table Row, Label, Code of the labelled rows of the PV2 QC file (Variants)
%     resolver  struct describing the resolver file (Variants): pairs, keepA/keepB/keepBoth/merged pair
%               rows, deletedRow, addedRow, mergedRow, curatedNaNRows, nRows
%
%   See also tFixture, CellDatasetManifest, CellQualityControl, CellNeighborResolution.

arguments
    outDir (1,1) string
    opts.ImageSize (1,2) double {mustBePositive, mustBeInteger} = [600 800]
    opts.NumCells (1,2) double {mustBePositive, mustBeInteger} = [120 180]
    opts.UmPerPixel (1,1) double {mustBePositive} = 1.657
    opts.Seed (1,1) double = 1
    opts.BaseName (1,1) string = "SYN-0001_sec1"
    opts.IntensityScale (1,1) double {mustBePositive} = 3000
    opts.Variants (1,1) logical = true
end

if ~isfolder(outDir); mkdir(outDir); end
folder = char(outDir);
s = RandStream('mt19937ar', 'Seed', opts.Seed);
H = opts.ImageSize(1);
W = opts.ImageSize(2);
upp = opts.UmPerPixel;
base = opts.BaseName;

keys = ["ECM1", "PV2"];
kinds = ["ring", "blob"];
channelNames = ["ECM", "PV"];
minDistPx = 22 / upp;      % true cells at least ~22 um apart
margin = 16;

paths = struct();
paths.tif = fullfile(folder, base + "_proj.tif");
imgs = cell(1, 2);
truth = struct('baseName', char(base), 'umPerPixel', upp, 'imageSize', [H W], 'seed', opts.Seed);
for c = 1:2
    key = keys(c);
    cells = placeCells(s, H, W, opts.NumCells(c), minDistPx, margin);
    imgs{c} = renderImage(s, H, W, cells, kinds(c), upp, opts.IntensityScale);
    imgName = base + "_proj_" + key;
    ch = detectionsFor(s, cells, H, W, upp, imgName);
    ch.cellsXY = cells;
    paths.(lower(char(key)) + "Locs") = fullfile(folder, imgName + "_locs.csv");
    writetable(ch.locs, char(paths.(lower(char(key)) + "Locs")));
    if opts.Variants
        [ch.redet, ch.droppedOldRows, redetLocs] = redetect(s, ch, H, W, upp, imgName);
        paths.(lower(char(key)) + "Redet") = fullfile(folder, imgName + "_locs.redetected.csv");
        writetable(redetLocs, char(paths.(lower(char(key)) + "Redet")));
    end
    truth.(char(key)) = ch;
end
writeTiff(char(paths.tif), imgs, upp);

if opts.Variants
    % legacy QC file of the PV2 channel
    imgName = base + "_proj_PV2";
    [qcTbl, truth.qc] = buildQcTable(s, truth.PV2, string(paths.pv2Locs), string(paths.tif), base, channelNames(2));
    paths.qc = fullfile(folder, imgName + "_locs_QC.csv");
    writetable(qcTbl, char(paths.qc));

    % legacy resolver file of the ECM1 channel
    [resTbl, truth.resolver] = buildResolverTable(truth.ECM1);
    paths.resolver = fullfile(folder, base + "_proj_ECM1_locs.resolver.csv");
    writetable(resTbl, char(paths.resolver));
    truth.resolver.path = char(paths.resolver);
end
truth.paths = structfun(@char, paths, 'UniformOutput', false);
end


%% ---- cells and image ---------------------------------------------------------------------------

function xy = placeCells(s, H, W, N, minD, margin)
%placeCells  N positions [x y] at least MINPX apart, MARGIN px from the edges (rejection sampling).
xy = zeros(N, 2);
n = 0; tries = 0;
while n < N
    tries = tries + 1;
    if tries > 500000
        error('makeSyntheticDataset:Crowded', 'Cannot place %d cells %.1f px apart in %dx%d px.', N, minD, H, W);
    end
    r = rand(s, 1, 2);
    c = [margin + (W - 2*margin - 1) * r(1), margin + (H - 2*margin - 1) * r(2)];
    if n == 0 || all(hypot(xy(1:n, 1) - c(1), xy(1:n, 2) - c(2)) >= minD)
        n = n + 1;
        xy(n, :) = round(c * 100) / 100;
    end
end
end


function img = renderImage(s, H, W, cells, kind, upp, scale)
%renderImage  Smooth background + cells (rings or blobs) + noise, float32, about 0..SCALE.
bgField = imgaussfilt(randn(s, H, W), 40);
bgField = (bgField - mean(bgField(:))) / std(bgField(:));
img = 0.15 + 0.04 * bgField;
rad = 16;
if kind == "ring"
    peak = 0.74 * 9 / upp;       % annulus of an 18 um cell: peak radius
    sig = 0.22 * 9 / upp;
else
    sig = (15 / upp) / 2.355;    % FWHM 15 um
end
amp = 0.6 + 0.4 * rand(s, size(cells, 1), 1);
for k = 1:size(cells, 1)
    x = cells(k, 1); y = cells(k, 2);
    cols = max(1, round(x) - rad):min(W, round(x) + rad);
    rows = max(1, round(y) - rad):min(H, round(y) + rad);
    [XX, YY] = meshgrid(cols, rows);
    d = hypot(XX - x, YY - y);
    if kind == "ring"
        prof = exp(-(d - peak).^2 / (2 * sig^2));
    else
        prof = exp(-d.^2 / (2 * sig^2));
    end
    img(rows, cols) = img(rows, cols) + amp(k) * 0.8 * prof;
end
img = img + 0.015 * randn(s, H, W);
img = single(max(img, 0) * scale);
end


function writeTiff(file, imgs, upp)
%writeTiff  A multi-page float32 TIFF whose resolution tags give UPP micrometres per pixel.
if isfile(file); delete(file); end
t = Tiff(file, 'w');
cleaner = onCleanup(@() t.close());
for p = 1:numel(imgs)
    tag = struct();
    tag.ImageLength = size(imgs{p}, 1);
    tag.ImageWidth = size(imgs{p}, 2);
    tag.Photometric = Tiff.Photometric.MinIsBlack;
    tag.BitsPerSample = 32;
    tag.SamplesPerPixel = 1;
    tag.SampleFormat = Tiff.SampleFormat.IEEEFP;
    tag.PlanarConfiguration = Tiff.PlanarConfiguration.Chunky;
    tag.Compression = Tiff.Compression.None;
    tag.RowsPerStrip = 16;
    tag.XResolution = 1e4 / upp;         % pixels per centimetre
    tag.YResolution = 1e4 / upp;
    tag.ResolutionUnit = Tiff.ResolutionUnit.Centimeter;
    tag.Software = 'makeSyntheticDataset';
    t.setTag(tag);
    t.write(imgs{p});
    if p < numel(imgs); t.writeDirectory(); end
end
end


%% ---- detections --------------------------------------------------------------------------------

function ch = detectionsFor(s, cells, H, W, upp, imgName)
%detectionsFor  The detections of one channel: true positives (with ~1 px jitter), misses, false positives, duplicates.
N = size(cells, 1);
nMiss = max(1, round(0.05 * N));
missed = sort(randperm(s, N, nMiss))';
tpIdx = setdiff(1:N, missed);
nDup = max(4, round(0.04 * N));
perm = tpIdx(randperm(s, numel(tpIdx)));
dupCells = perm(1:nDup);
clusterCell = perm(nDup + 1);
nTp = numel(tpIdx);

% pre-shuffle rows: tp first, then the duplicates, then the cluster's two, then false positives
xy = zeros(0, 2); kind = strings(0, 1); trueIdx = zeros(0, 1); dupOf = zeros(0, 1);
xy = [xy; clampXY(cells(tpIdx, :) + 0.6 * randn(s, nTp, 2), H, W)];
kind = [kind; repmat("tp", nTp, 1)]; trueIdx = [trueIdx; tpIdx(:)]; dupOf = [dupOf; zeros(nTp, 1)];
preRowOfCell = zeros(N, 1); preRowOfCell(tpIdx) = 1:nTp;

groupsPre = {};
for i = dupCells
    p = placeNear(s, cells, i, 3, 9, 0, H, W, upp);
    xy(end + 1, :) = p; kind(end + 1, 1) = "dup"; trueIdx(end + 1, 1) = i; dupOf(end + 1, 1) = preRowOfCell(i); %#ok<AGROW>
    groupsPre{end + 1} = [preRowOfCell(i), size(xy, 1)]; %#ok<AGROW>
end
ang0 = 2 * pi * rand(s);
members = preRowOfCell(clusterCell);
for k = 1:2
    p = placeNear(s, cells, clusterCell, 4, 8, ang0 + (k - 1) * (2*pi/3) + 0.3 * (rand(s) - 0.5), H, W, upp);
    xy(end + 1, :) = p; kind(end + 1, 1) = "dup"; trueIdx(end + 1, 1) = clusterCell; dupOf(end + 1, 1) = preRowOfCell(clusterCell); %#ok<AGROW>
    members(end + 1) = size(xy, 1); %#ok<AGROW>
end
groupsPre{end + 1} = members;

nFp = round(0.6 * N);
fpXY = sampleBackground(s, H, W, cells, xy, nFp, 14 / 1, 12);
xy = [xy; fpXY];
kind = [kind; repmat("fp", nFp, 1)]; trueIdx = [trueIdx; zeros(nFp, 1)]; dupOf = [dupOf; zeros(nFp, 1)];

[score, rescore] = scoresFor(s, kind);
n = numel(kind);
order = randperm(s, n)';            % order(k) = pre-row shown at final row k
rowOfPre = zeros(n, 1); rowOfPre(order) = 1:n;

xy = round(xy(order, :) * 100) / 100;
kind = kind(order); trueIdx = trueIdx(order);
dupOf = dupOf(order); dupOf(dupOf > 0) = rowOfPre(dupOf(dupOf > 0));
score = score(order); rescore = rescore(order);

ch = struct();
ch.locs = makeLocs(xy, score, rescore, imgName);
ch.det = table((1:n)', kind, trueIdx, dupOf, 'VariableNames', {'Row', 'Kind', 'TrueIdx', 'DupOfRow'}, 'DimensionNames', {'Index', 'Variables'});
ch.missedIdx = missed;
ch.dupGroups = cellfun(@(g) reshape(rowOfPre(g), 1, []), groupsPre, 'UniformOutput', false);
end


function locs = makeLocs(xy, score, rescore, imgName)
%makeLocs  The detections table with exactly the columns of a real locs CSV.
n = size(xy, 1);
locs = table(xy(:, 1), xy(:, 2), zeros(n, 1), score, repmat(string(imgName), n, 1), zeros(n, 1), rescore, ...
    'VariableNames', {'X', 'Y', 'class', 'score', 'imgName', 'thr', 'rescore'});
end


function [score, rescore] = scoresFor(s, kind)
%scoresFor  Scores and rescores by kind, with some overlap between true and false detections.
n = numel(kind);
score = zeros(n, 1); rescore = zeros(n, 1);
u = rand(s, n, 4);
for k = 1:n
    switch kind(k)
        case "tp"
            if u(k, 1) < 0.10; score(k) = 0.45 + 0.25 * u(k, 2); else; score(k) = 0.7 + 0.3 * u(k, 2); end
            if u(k, 3) < 0.10; rescore(k) = -1 + 2 * u(k, 4); else; rescore(k) = 1 + 5 * u(k, 4); end
        case "fp"
            if u(k, 1) < 0.10; score(k) = 0.6 + 0.2 * u(k, 2); else; score(k) = 0.02 + 0.58 * u(k, 2)^1.5; end
            if u(k, 3) < 0.10; rescore(k) = 0.5 + 1.5 * u(k, 4); else; rescore(k) = -5 + 5.5 * u(k, 4); end
        otherwise   % dup
            score(k) = 0.3 + 0.5 * u(k, 2);
            rescore(k) = -2 + 5 * u(k, 4);
    end
end
score = round(score * 1e4) / 1e4;
rescore = round(rescore * 1e4) / 1e4;
end


function xy = clampXY(xy, H, W)
xy(:, 1) = min(max(xy(:, 1), 1), W);
xy(:, 2) = min(max(xy(:, 2), 1), H);
end


function p = placeNear(s, cells, i, dMin, dMax, ang, H, W, ~)
%placeNear  A point dMin..dMax px from cell I (random angle unless ANG ~= 0), at least 11 px from every other true cell.
others = cells; others(i, :) = [];
for attempt = 1:200
    a = ang;
    if ang == 0 || attempt > 1; a = 2 * pi * rand(s); end
    d = dMin + (dMax - dMin) * rand(s);
    p = cells(i, :) + d * [cos(a) sin(a)];
    if p(1) >= 1 && p(1) <= W && p(2) >= 1 && p(2) <= H && all(hypot(others(:, 1) - p(1), others(:, 2) - p(2)) >= 11)
        return
    end
end
error('makeSyntheticDataset:NoRoom', 'No room for a duplicate next to cell %d.', i);
end


function pts = sampleBackground(s, H, W, cells, existing, n, minCell, minDet)
%sampleBackground  N points on background: >= MINCELL px from every true cell, >= MINDET px from every detection.
pts = zeros(0, 2);
tries = 0;
while size(pts, 1) < n
    tries = tries + 1;
    if tries > 500000
        error('makeSyntheticDataset:NoBackground', 'Cannot place %d false detections.', n);
    end
    r = rand(s, 1, 2);
    c = [8 + (W - 17) * r(1), 8 + (H - 17) * r(2)];
    if all(hypot(cells(:, 1) - c(1), cells(:, 2) - c(2)) >= minCell) && ...
            (isempty(existing) || all(hypot(existing(:, 1) - c(1), existing(:, 2) - c(2)) >= minDet)) && ...
            (isempty(pts) || all(hypot(pts(:, 1) - c(1), pts(:, 2) - c(2)) >= minDet))
        pts(end + 1, :) = c; %#ok<AGROW>
    end
end
end


%% ---- the re-detected variant -------------------------------------------------------------------

function [redet, droppedOldRows, locs] = redetect(s, ch, H, W, upp, imgName) %#ok<INUSD>
%redetect  Same cells, new sub-2-px jitter (relative to the previous position) and scores, ~5% dropped
%   (half true, half false), ~5% new (re-found misses and new false positives), rows in another order.
old = ch.locs;
det = ch.det;
n = height(old);
inGroup = unique([ch.dupGroups{:}]);
tpRows = setdiff(find(det.Kind == "tp"), inGroup);
fpRows = find(det.Kind == "fp");
nDrop = max(2, round(0.05 * n));
nDropFp = ceil(nDrop / 2);
nDropTp = nDrop - nDropFp;
dropped = sort([tpRows(randperm(s, numel(tpRows), nDropTp)); fpRows(randperm(s, numel(fpRows), nDropFp))]);
keep = setdiff((1:n)', dropped);

nk = numel(keep);
j = randn(s, nk, 2) * 0.6;
len = hypot(j(:, 1), j(:, 2));
j = j .* min(1, 1.9 ./ max(len, eps));               % displacement < 2 px
xy = clampXY([old.X(keep) old.Y(keep)] + j, H, W);
score = min(max(old.score(keep) + 0.05 * randn(s, nk, 1), 0.01), 1);
rescore = old.rescore(keep) + 0.3 * randn(s, nk, 1);
kind = det.Kind(keep);
trueIdx = det.TrueIdx(keep);
oldRow = keep;

nNew = max(2, round(0.05 * n));
nNewTp = min(numel(ch.missedIdx), floor(nNew / 2));
nNewFp = nNew - nNewTp;
refound = ch.missedIdx(randperm(s, numel(ch.missedIdx), nNewTp));
newTp = clampXY(ch.cellsXY(refound, :) + 0.6 * randn(s, nNewTp, 2), H, W);
newFp = sampleBackground(s, H, W, ch.cellsXY, [xy; newTp], nNewFp, 14, 12);
[sTp, rTp] = scoresFor(s, repmat("tp", nNewTp, 1));
[sFp, rFp] = scoresFor(s, repmat("fp", nNewFp, 1));
xy = [xy; newTp; newFp];
score = [score; sTp; sFp];
rescore = [rescore; rTp; rFp];
kind = [kind; repmat("tp", nNewTp, 1); repmat("fp", nNewFp, 1)];
trueIdx = [trueIdx; refound(:); zeros(nNewFp, 1)];
oldRow = [oldRow; zeros(nNew, 1)];

m = numel(kind);
order = randperm(s, m)';
xy = round(xy(order, :) * 100) / 100;
score = round(score(order) * 1e4) / 1e4;
rescore = round(rescore(order) * 1e4) / 1e4;
locs = makeLocs(xy, score, rescore, imgName);
redet = table((1:m)', kind(order), trueIdx(order), oldRow(order), 'VariableNames', {'Row', 'Kind', 'TrueIdx', 'OldRow'}, 'DimensionNames', {'Index', 'Variables'});
droppedOldRows = dropped;
end


%% ---- legacy QC file ----------------------------------------------------------------------------

function [tbl, qc] = buildQcTable(s, ch, csvPath, tifPath, base, channelName)
%buildQcTable  The table CellQualityControl.saveCurrentQC writes: the locs columns + the 18 QC columns.
locs = ch.locs;
det = ch.det;
n = height(locs);
labelled = rand(s, n, 1) < 0.5;
r = rand(s, n, 1);
label = strings(n, 1);
for k = 1:n
    if ~labelled(k); continue; end
    switch det.Kind(k)
        case "tp"
            if r(k) < 0.90; label(k) = "Good"; elseif r(k) < 0.97; label(k) = "Uncertain"; else; label(k) = "Bad"; end
        case "fp"
            if r(k) < 0.85; label(k) = "Bad"; elseif r(k) < 0.93; label(k) = "Uncertain"; else; label(k) = "Good"; end
        otherwise
            if r(k) < 0.5; label(k) = "Bad"; else; label(k) = "Good"; end
    end
end
lab = find(labelled);
p = lab(randperm(s, numel(lab)));
label(p(1:2)) = "Ignore";
if nnz(label == "Uncertain") < 3
    label(p(3:5)) = "Uncertain";
end
code = NaN(n, 1);
code(label == "Good") = 1; code(label == "Bad") = 2; code(label == "Uncertain") = 3; code(label == "Ignore") = 4;
isLab = strlength(label) > 0;
stamp = NaT(n, 1);
stamp(isLab) = datetime(2026, 1, 1, 12, 0, 0) + seconds(find(isLab));

[~, csvName] = fileparts(char(csvPath));
tbl = locs;
tbl.QCLabel = label;
tbl.QCCode = code;
tbl.QCReviewed = isLab;
tbl.QCReviewer = repmat("tester", n, 1);
tbl.QCReviewer(~isLab) = "";
tbl.QCTimestamp = stamp;
tbl.QCNotes = strings(n, 1);
tbl.QCCropWidth = repmat(64, n, 1);
tbl.QCCropHeight = repmat(64, n, 1);
tbl.QCDatasetID = repmat(string(base), n, 1);
tbl.QCChannel = repmat(string(channelName), n, 1);
tbl.QCSourceCsv = repmat(string(csvPath), n, 1);
tbl.QCSourceRow = (1:n)';
tbl.QCImagePath = repmat(string(tifPath), n, 1);
tbl.QCVersion = repmat("1.0", n, 1);
tbl.QCUniqueID = string(base) + "|" + string(channelName) + "|" + string(csvName) + ".csv|" + string((1:n)');
tbl.QCOutOfBounds = false(n, 1);
tbl.QCIncludesImageBorder = false(n, 1);
tbl.QCWarning = strings(n, 1);
qc = table(find(isLab), label(isLab), code(isLab), 'VariableNames', {'Row', 'Label', 'Code'}, 'DimensionNames', {'Index', 'Variables'});
end


%% ---- legacy resolver file ----------------------------------------------------------------------

function [out, info] = buildResolverTable(ch)
%buildResolverTable  The table CellNeighborResolution.saveResolved writes for the ECM detections.
%   Pairs: each duplicate pair, and the cluster's three pairs (left Unresolved). The first four duplicate
%   pairs (by row) become Keep A, Keep B, Keep Both and Merged. One false detection is deleted outright
%   and one point is added by hand (at the first missed cell), as the GUI would.
locs = ch.locs;
n = height(locs);

% neighbour pairs [rA rB isSimple], sorted by row
pairs = zeros(0, 3);
for g = 1:numel(ch.dupGroups)
    m = ch.dupGroups{g};
    if numel(m) == 2
        pairs(end + 1, :) = [min(m), max(m), 1]; %#ok<AGROW>
    else
        for a = 1:numel(m) - 1
            for b = a + 1:numel(m)
                pairs(end + 1, :) = [min(m(a), m(b)), max(m(a), m(b)), 0]; %#ok<AGROW>
            end
        end
    end
end
pairs = sortrows(pairs, [1 2]);
np = size(pairs, 1);
pairStatus = repmat("Unresolved", np, 1);
simple = find(pairs(:, 3) == 1);
actions = ["Keep A", "Keep B", "Keep Both", "Merged"];
pairStatus(simple(1:4)) = actions;

out = locs;
out.CURATED_X = locs.X;
out.CURATED_Y = locs.Y;
out.NeighborResolved = false(n, 1);
out.NeighborResolvedStatus = strings(n, 1);
out.NeighborPairID = strings(n, 1);

% the point added by hand sits in the table after the original rows (template: nearest row)
xyAdd = ch.cellsXY(ch.missedIdx(1), :);
[~, nearest] = min(hypot(locs.X - xyAdd(1), locs.Y - xyAdd(2)));
newRow = out(nearest, :);
newRow.X = xyAdd(1); newRow.Y = xyAdd(2);
newRow.CURATED_X = xyAdd(1); newRow.CURATED_Y = xyAdd(2);
newRow.NeighborResolved = false; newRow.NeighborResolvedStatus = ""; newRow.NeighborPairID = "";
out = [out; newRow];
addedRow = n + 1;

% the row deleted outright: the first false detection
deletedRow = find(ch.det.Kind == "fp", 1);
out.CURATED_X(deletedRow) = NaN;
out.CURATED_Y(deletedRow) = NaN;

mergedRow = 0;
pairLabels = strings(np, 1);
for p = 1:np
    rA = pairs(p, 1); rB = pairs(p, 2);
    pairLabels(p) = string(rA) + "-" + string(rB);
    st = pairStatus(p);
    for idx = [rA rB]
        out.NeighborPairID(idx) = joinToken(out.NeighborPairID(idx), pairLabels(p));
        out.NeighborResolvedStatus(idx) = joinToken(out.NeighborResolvedStatus(idx), st);
    end
    if st == "Unresolved"; continue; end
    out.NeighborResolved([rA rB]) = true;
    switch st
        case "Keep A"
            out.CURATED_X(rB) = NaN; out.CURATED_Y(rB) = NaN;
        case "Keep B"
            out.CURATED_X(rA) = NaN; out.CURATED_Y(rA) = NaN;
        case "Merged"
            mid = [mean(locs.X([rA rB])), mean(locs.Y([rA rB]))];
            mid = round(mid * 100) / 100;
            out.CURATED_X([rA rB]) = NaN; out.CURATED_Y([rA rB]) = NaN;
            merged = out(rA, :);
            merged.X = mid(1); merged.Y = mid(2);
            merged.CURATED_X = mid(1); merged.CURATED_Y = mid(2);
            merged.NeighborResolved = true; merged.NeighborResolvedStatus = st; merged.NeighborPairID = pairLabels(p);
            out = [out; merged]; %#ok<AGROW>
            mergedRow = height(out);
            mergedXY = mid;
    end
end

info = struct();
info.pairs = table(pairLabels, pairs(:, 1), pairs(:, 2), pairStatus, logical(pairs(:, 3)), ...
    'VariableNames', {'PairID', 'RowA', 'RowB', 'Status', 'Simple'});
info.keepA = pairs(simple(1), 1:2);
info.keepB = pairs(simple(2), 1:2);
info.keepBoth = pairs(simple(3), 1:2);
info.merged = pairs(simple(4), 1:2);
info.mergedRow = mergedRow;
info.mergedXY = mergedXY;
info.deletedRow = deletedRow;
info.addedRow = addedRow;
info.addedXY = xyAdd;
info.addedTrueIdx = ch.missedIdx(1);
info.clusterRows = ch.dupGroups{end};
info.curatedNaNRows = find(isnan(out.CURATED_X))';
info.nRows = height(out);
info.nOriginalRows = n;
end


function out = joinToken(existing, tok)
%joinToken  Append TOK to a ";"-joined list (as CellNeighborResolution.joinToken does).
if strlength(existing) == 0
    out = string(tok);
else
    out = existing + ";" + string(tok);
end
end

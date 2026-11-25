classdef tModelInput < matlab.unittest.TestCase
    %TMODELINPUT  The model input (the image the detector and the Stage-2 scorer read):
    %   CellToolkit.modelInputPage / modelInputFromFile / modelInputFactsFor and CellDiscovery's
    %   refactor onto them.
    %
    %   BIT IDENTITY. For every combination of LSM correction (joint over both pages), background
    %   subtraction, resize (manual 1 / auto from the TIFF calibration) and normalization, the
    %   image is compared, bit for bit and class, between
    %     OLD  the code before the refactor (frozen below, copied verbatim from commit 1936760:
    %          preprocessAllPages, applyPreprocess, the LSM option parsing, normalizeIntensity and
    %          writeScratchTiff), written to a scratch TIFF and read back as predict.py reads it;
    %     CD   CellDiscovery's refactored batch path (CellDiscovery.detectorInputForFile: the same
    %          preprocessAllPages + detectorInputPage the timer runs);
    %     TK   CellToolkit.modelInputFromFile driven by the facts CellDiscovery records
    %          (detectionFactsFor), after a round trip through the manifest JSON.
    %   On a synthetic page (float32 and uint16) and on a crop of a real page (Slow).
    %
    %   FALLBACK for sections detected before the facts were recorded: resize from the TIFF
    %   calibration, else the locs ratio; the rest assumed and reported. On a copy of a real
    %   section it prints the inferred factor next to the calibration (Slow; skipped when
    %   %LOCALAPPDATA%\counting_perineuronal_nets\real_sections is absent).
    %
    %   Run: pwsh -File tools\Run-Tests.ps1 tModelInput [-IncludeSlow]

    properties
        Dir
    end

    properties (Constant)
        REAL = fullfile(getenv('LOCALAPPDATA'), 'counting_perineuronal_nets', 'real_sections')
    end

    methods (TestMethodSetup)
        function makeDir(tc)
            fx = tc.applyFixture(matlab.unittest.fixtures.TemporaryFolderFixture);
            tc.Dir = fx.Folder;
        end
    end

    methods (Test)

        function syntheticFloat32AllCombinations(tc)
            [folder, ~] = makeSyntheticDataset(fullfile(tc.Dir, 'syn'), 'Variants', false, ...
                'ImageSize', [300 400], 'NumCells', [30 40]);
            tif = fullfile(folder, 'SYN-0001_sec1_proj.tif');
            tc.checkAllCombinations(tif, 1, 'ECM1', "synthetic float32");
        end

        function syntheticUint16AllCombinations(tc)
            [folder, ~] = makeSyntheticDataset(fullfile(tc.Dir, 'syn'), 'Variants', false, ...
                'ImageSize', [300 400], 'NumCells', [30 40]);
            src = fullfile(folder, 'SYN-0001_sec1_proj.tif');
            tif = fullfile(folder, 'U16_sec1_proj.tif');
            p1 = imread(src, 1); p2 = imread(src, 2);
            tModelInput.writePages(tif, {uint16(p1 * 10), uint16(p2 * 10)}, 1.657);
            tc.checkAllCombinations(tif, 2, 'PV2', "synthetic uint16");
        end

        function normalizeIntensityUnchanged(tc)
            rng(3);
            cases = {single(rand(50, 60) * 3000), single(ones(20)), ...
                cat(3, single(rand(30) * 10), single(5 * ones(30))), uint16(rand(40) * 60000), ...
                single([NaN 1 2; 3 Inf 5])};
            for k = 1:numel(cases)
                [a, la] = old_normalizeIntensity(cases{k}, [1 99.9], 255);
                [b, lb] = CellToolkit.normalizeIntensity(cases{k}, [1 99.9], 255);
                tc.verifyTrue(tModelInput.sameBits(a, b), sprintf('case %d', k));
                tc.verifyEqual(lb, la);
                c = CellToolkit.applyIntensityLimits(cases{k}, la, 255);
                tc.verifyTrue(tModelInput.sameBits(a, c), sprintf('re-applied limits, case %d', k));
            end
        end

        function fallbackUsesLocsRatioWithoutCalibration(tc)
            [folder, truth] = makeSyntheticDataset(fullfile(tc.Dir, 'syn'), 'Variants', false, ...
                'ImageSize', [300 400], 'NumCells', [30 40]);
            src = fullfile(folder, 'SYN-0001_sec1_proj.tif');
            tif = fullfile(folder, 'NOCAL_sec1_proj.tif');
            tModelInput.writePages(tif, {imread(src, 1), imread(src, 2)}, NaN);   % no resolution tags
            tc.verifyTrue(isnan(CellToolkit.tiffPixelSizeUm(tif, 1)));
            locs = truth.paths.ecm1Locs;
            resized = strrep(locs, '_locs.csv', '_locs_resized.csv');
            L = readtable(locs);
            L.X = L.X * 2.5; L.Y = L.Y * 2.5;
            writetable(L, resized);
            [f, rep] = CellToolkit.modelInputFactsFor(struct(), tif, 1, locs, resized);
            tc.verifyEqual(f.resize, 2.5, 'AbsTol', 1e-12);
            tc.verifyEqual(rep.resizeSource, "locs ratio");
            tc.verifyEqual(rep.inferred, "resize");
            tc.verifyEqual(sort(rep.assumed), sort(["bgRadius" "correctLSM" "normalized"]));
            tc.verifyTrue(f.normalized, 'assumed: today''s CellDiscovery default');
            tc.verifyEqual(f.bgRadius, 0);
            tc.verifyFalse(f.correctLSM);
            tc.verifyEqual(f.source, "inferred");
            img = CellToolkit.modelInputFromFile(tif, 1, f);
            tc.verifyEqual(size(img), [750 1000]);
            tc.verifyClass(img, 'single');
            tc.verifyLessThanOrEqual(max(img(:)), single(255));
        end

        function fallbackPrefersCalibrationAndReportsTheRatio(tc)
            [folder, truth] = makeSyntheticDataset(fullfile(tc.Dir, 'syn'), 'Variants', false, ...
                'ImageSize', [300 400], 'NumCells', [30 40]);
            tif = fullfile(folder, 'SYN-0001_sec1_proj.tif');
            locs = truth.paths.ecm1Locs;
            resized = strrep(locs, '_locs.csv', '_locs_resized.csv');
            L = readtable(locs);
            L.X = L.X * 2.5; L.Y = L.Y * 2.5;
            writetable(L, resized);
            [f, rep] = CellToolkit.modelInputFactsFor(struct(), tif, 1, locs, resized, ...
                struct('Assume', struct('bgRadius', 12)));
            tc.verifyEqual(f.resize, round(1.657 / 0.645, 4));
            tc.verifyEqual(rep.resizeSource, "tiff calibration");
            tc.verifyEqual(rep.resizeFromLocs, 2.5, 'AbsTol', 1e-9);
            tc.verifyTrue(any(contains(rep.notes, "locs files say x2.5000")), strjoin(rep.notes, ' | '));
            tc.verifyEqual(f.bgRadius, 12, 'opts.Assume is used, and still reported as assumed');
            tc.verifyTrue(any(rep.assumed == "bgRadius"));
        end

        function recordedFactsAreUsedAsRecorded(tc)
            [folder, ~] = makeSyntheticDataset(fullfile(tc.Dir, 'syn'), 'Variants', false, ...
                'ImageSize', [300 400], 'NumCells', [30 40]);
            tif = fullfile(folder, 'SYN-0001_sec1_proj.tif');
            % a detection recorded before this change: resize, bgRadius, normalized, normLimits only
            det = struct('done', true, 'resize', 3, 'bgRadius', 5, 'normalized', true, 'normLimits', [10; 2000]);
            [f, rep] = CellToolkit.modelInputFactsFor(det, tif, 1, '', '');
            tc.verifyEqual(f.resize, 3);
            tc.verifyEqual(f.bgRadius, 5);
            tc.verifyEqual(f.normLimits, [10 2000]);
            tc.verifyEqual(rep.assumed, "correctLSM", 'LSM was not recorded then');
            tc.verifyEqual(f.source, "manifest+inferred");
            img = CellToolkit.modelInputFromFile(tif, 1, f);
            tc.verifyEqual(size(img), [900 1200]);
        end
    end

    methods (Test, TestTags = {'Slow'})

        function realPageCropAllCombinations(tc)
            src = tModelInput.firstRealTiff();
            tc.assumeNotEmpty(src, 'no local copy of a real section');
            um = CellToolkit.tiffPixelSizeUm(src, 1);
            r0 = 1001; c0 = 1001; n = 700;
            P = cell(1, 2);
            for p = 1:2
                I = imread(src, p);
                P{p} = I(r0:r0 + n - 1, c0:c0 + n - 1);
            end
            tif = fullfile(tc.Dir, 'REAL_crop_proj.tif');
            tModelInput.writePages(tif, P, um);
            tc.checkAllCombinations(tif, 1, 'ECM1', sprintf("real crop %dx%d at %.4g um/px", n, n, um));
        end

        function realPageFullSizeAllOptions(tc)
            src = tModelInput.firstRealTiff();
            tc.assumeNotEmpty(src, 'no local copy of a real section');
            tif = fullfile(tc.Dir, 'REALFULL_proj.tif');
            copyfile(src, tif);
            tc.checkCombination(tif, 2, 'PV2', true, 15, 0, true, "real full page, all options");
        end

        function realSectionFallback(tc)
            src = tModelInput.firstRealTiff();
            tc.assumeNotEmpty(src, 'no local copy of a real section');
            [sdir, stem] = fileparts(src);
            dst = fullfile(tc.Dir, 'real');
            copyfile(sdir, dst);
            tif = fullfile(dst, [stem '.tif']);
            for key = ["ECM1" "PV2"]
                page = double(extractAfter(key, strlength(key) - 1));
                locs = fullfile(dst, stem + "_" + key + "_locs.csv");
                resized = fullfile(dst, stem + "_" + key + "_locs_resized.csv");
                tc.assertTrue(isfile(locs) && isfile(resized));
                tc.verifyEmpty(dir(fullfile(dst, '*.celldataset.json')), 'the copy has no manifest');
                [f, rep] = CellToolkit.modelInputFactsFor(struct(), tif, page, char(locs), char(resized));
                fprintf(['\n[fallback] %s %s: calibration %.5g um/px -> x%.4f; locs ratio x%.6f ' ...
                    '(%+.4f%% vs calibration); used x%.4f [%s]; assumed: %s\n'], stem, key, ...
                    rep.calibrationUm, rep.resizeFromCalibration, rep.resizeFromLocs, ...
                    100 * (rep.resizeFromLocs / rep.resizeFromCalibration - 1), f.resize, ...
                    rep.resizeSource, strjoin(rep.assumed, ', '));
                fprintf('[fallback]   %s\n', rep.text);
                tc.verifyEqual(rep.resizeSource, "tiff calibration");
                tc.verifyEqual(rep.resizeFromLocs, rep.resizeFromCalibration, 'RelTol', 1e-3, ...
                    'the detection used the calibration factor');
                tc.verifyEqual(sort(rep.assumed), sort(["bgRadius" "correctLSM" "normalized"]));
            end
        end
    end

    methods
        function checkAllCombinations(tc, tif, page, key, label)
            for lsm = [false true]
                for bg = [0 15]
                    for rz = [1 0]
                        for nrm = [false true]
                            tc.checkCombination(tif, page, key, lsm, bg, rz, nrm, label);
                        end
                    end
                end
            end
        end

        function checkCombination(tc, tif, page, key, lsm, bg, rz, nrm, label)
            % rz: the page map's "Resize x" (1 = manual none, 0 = auto from the calibration)
            lsmOpts = CellDiscovery.defaultLSMOptionsForTest();
            lsmOpts.NumIterations = '4';            % faster, and not the default: must round-trip
            lsmOpts.PyramidDownsample = '[2 1]';
            row = @(pg, sfx) {pg, sfx, 'model', '(none)', lsm, bg, rz, false, nrm};
            mapData = [row(1, 'ECM'); row(2, 'PV')];
            what = sprintf('%s page %d: lsm=%d bg=%d resize=%s norm=%d', label, page, lsm, bg, ...
                tModelInput.ternary(rz == 0, "auto", "x1"), nrm);
            t0 = tic;

            % OLD: the frozen pre-refactor code, through its scratch TIFF
            nPages = CellToolkit.countPages(tif);
            pagesOld = old_preprocessAllPages(tif, nPages, mapData, lsmOpts);
            img = pagesOld{page};
            if nrm, img = old_normalizeIntensity(img, [1 99.9], 255); end
            scratch = fullfile(tc.Dir, 'old_scratch.tif');
            old_writeScratchTiff(img, scratch);
            oldImg = imread(scratch);

            % CD: CellDiscovery's refactored batch path
            [cdImg, lims, lsmIdx] = CellDiscovery.detectorInputForFile(tif, page, mapData, lsmOpts, nrm);

            % TK: regenerated from the recorded facts after a manifest JSON round trip
            facts = CellDiscovery.detectionFactsFor(tif, mapData(page, :), lsmOpts, lsmIdx, lims);
            info = facts;
            info.image = tif; info.page = page; info.tool = 'CellDiscovery'; info.model = 'model'; info.count = 1;
            mf = CellDatasetManifest.forImage(tif);
            mf.recordDetection(key, info);
            tc.assertTrue(mf.save(), 'manifest saved');
            det = CellDatasetManifest.forImage(tif).source(key).stages.detection;
            [f2, rep] = CellToolkit.modelInputFactsFor(det, tif, page, '', '');
            tkImg = CellToolkit.modelInputFromFile(tif, page, f2);

            tc.verifyTrue(tModelInput.sameBits(oldImg, cdImg), "CellDiscovery differs from the old code: " + what);
            tc.verifyTrue(tModelInput.sameBits(oldImg, tkImg), "regenerated from facts differs: " + what);
            tc.verifyEmpty(rep.assumed, "nothing assumed when the facts are recorded: " + what);
            tc.verifyEmpty(rep.inferred, what);
            tc.verifyEqual(f2.source, "manifest", what);
            if lsm
                tc.verifyEqual(lsmIdx, [1 2], 'both pages corrected together');
                tc.verifyEqual(f2.lsmPages, [1 2]);
                % the identity is not trivial: the correction did change the pixels
                mapNo = mapData; mapNo(:, 5) = {false};
                noLsm = old_preprocessAllPages(tif, nPages, mapNo, lsmOpts);
                img = noLsm{page};
                if nrm, img = old_normalizeIntensity(img, [1 99.9], 255); end
                tc.verifyFalse(tModelInput.sameBits(oldImg, CellToolkit.modelInputClass(img)), ...
                    "LSM correction left the pixels unchanged, so this case proves nothing: " + what);
            end
            fprintf('[bit-identical] %s  (%s, %dx%d, %.1f s)\n', what, class(oldImg), size(oldImg, 1), ...
                size(oldImg, 2), toc(t0));
        end
    end

    methods (Static)
        function tf = sameBits(a, b)
            tf = strcmp(class(a), class(b)) && isequal(size(a), size(b));
            if ~tf, return; end
            switch class(a)
                case 'single', tf = isequal(typecast(a(:), 'uint32'), typecast(b(:), 'uint32'));
                case 'double', tf = isequal(typecast(a(:), 'uint64'), typecast(b(:), 'uint64'));
                otherwise,     tf = isequal(a, b);
            end
        end

        function writePages(file, pages, um)
            % A multi-page TIFF of the pages, with resolution tags for UM um/px (none when NaN).
            if isfile(file), delete(file); end
            t = Tiff(file, 'w');
            c = onCleanup(@() t.close());
            for p = 1:numel(pages)
                I = pages{p};
                tag = struct('ImageLength', size(I, 1), 'ImageWidth', size(I, 2), ...
                    'Photometric', Tiff.Photometric.MinIsBlack, 'SamplesPerPixel', 1, ...
                    'PlanarConfiguration', Tiff.PlanarConfiguration.Chunky, ...
                    'Compression', Tiff.Compression.None, 'RowsPerStrip', 16);
                if isa(I, 'single')
                    tag.BitsPerSample = 32; tag.SampleFormat = Tiff.SampleFormat.IEEEFP;
                else
                    tag.BitsPerSample = 16; tag.SampleFormat = Tiff.SampleFormat.UInt;
                end
                if isfinite(um)
                    tag.XResolution = 1e4 / um; tag.YResolution = 1e4 / um;
                    tag.ResolutionUnit = Tiff.ResolutionUnit.Centimeter;
                end
                t.setTag(tag);
                t.write(I);
                if p < numel(pages), t.writeDirectory(); end
            end
        end

        function f = firstRealTiff()
            f = '';
            d = dir(fullfile(tModelInput.REAL, '**', '*_proj.tif'));
            if ~isempty(d), f = fullfile(d(1).folder, d(1).name); end
        end

        function r = ternary(c, a, b)
            if c, r = a; else, r = b; end
        end
    end
end


%% =============================================================================================
%  FROZEN: the preprocessing code as it was before the refactor (commit 1936760), copied verbatim
%  from customizations\CellDiscovery.m (static private methods, renamed old_*) and
%  customizations\CellToolkit.m (normalizeIntensity). Do not edit: it is the reference.
%  =============================================================================================

function [rz, srcUm, mode] = old_resolveResize(imgFile, page, tableRz)
    % Resolve a page's resize factor from its page-map "Resize x" value.
    %   tableRz > 0 : manual factor, used as given        (mode 'manual')
    %   otherwise   : auto — the factor that brings the page to the
    %                 training pixel size, from the TIFF calibration
    %                 (mode 'auto'); x1 if the file has no usable
    %                 calibration                          (mode 'uncalibrated')
    % srcUm is the calibrated source pixel size in um (NaN if none).
    % Both buildJobs and preprocessAllPages resolve through here, so the
    % job's factor always matches the pixels the detector receives.
    srcUm = CellToolkit.tiffPixelSizeUm(imgFile, page);
    if tableRz > 0
        rz = tableRz;  mode = 'manual';
    elseif isfinite(srcUm)
        rz = round(srcUm / 0.645, 4);
        if abs(rz - 1) < 0.01, rz = 1; end   % already at the training pixel size
        mode = 'auto';
    else
        rz = 1;  mode = 'uncalibrated';
    end
end

function img = old_applyPreprocess(img, correctLSM, lsmOptions, bgRadius, resizeFactor)
    % Optional preprocessing applied before detection:
    %   - bidirectional LSM line artifact correction
    %   - morphological background subtraction (imtophat, disk strel)
    %   - resize by a scalar factor
    % LSM correction runs first, then background subtraction at full
    % resolution, then resizing.
    if correctLSM
        if exist('correctBidirectionalLSMArtifact', 'file') ~= 2
            error('correctBidirectionalLSMArtifact.m must be on the MATLAB path to use Correct LSM.');
        end
        img = old_callCorrectBidirectionalLSMArtifact(img, lsmOptions);
    end
    if bgRadius > 0
        se = strel('disk', round(bgRadius));
        if size(img, 3) == 1
            img = imtophat(img, se);
        else
            for c = 1:size(img, 3)
                img(:,:,c) = imtophat(img(:,:,c), se);
            end
        end
    end
    if resizeFactor > 0 && resizeFactor ~= 1
        img = imresize(img, resizeFactor, 'lanczos3', 'Antialiasing', true, 'Colormap', 'original', 'Dither', false);
    end
end

function opts = old_defaultLSMOptions()
    % Defaults for correctBidirectionalLSMArtifact name-value options.
    opts = struct( ...
        'ReverseRows', '"even"', ...
        'MaxDisplacement', '8', ...
        'NumIterations', '15', ...
        'PyramidDownsample', '[4 2 1]', ...
        'SmoothSigma', '4', ...
        'StepSize', '0.75', ...
        'UseAllChannels', 'true', ...
        'RegistrationChannel', '1', ...
        'ApplyGuidedFilter', 'false', ...
        'GuidedNeighborhoodSize', '[5 5]', ...
        'GuidedDegreeOfSmoothing', '0.01', ...
        'FillValue', 'NaN' ...
        );
end

function opts = old_sanitizeLSMOptions(opts)
    % Keep stored LSM options restricted to supported correction inputs.
    dflt = old_defaultLSMOptions();
    if ~isstruct(opts)
        opts = dflt;
        return;
    end
    names = fieldnames(dflt);
    clean = struct();
    for k = 1:numel(names)
        nm = names{k};
        if isfield(opts, nm) && ~isempty(opts.(nm))
            clean.(nm) = opts.(nm);
        else
            clean.(nm) = dflt.(nm);
        end
    end
    opts = clean;
end

function img = old_callCorrectBidirectionalLSMArtifact(img, opts)
    % Call correctBidirectionalLSMArtifact with persisted name-value
    % options.
    args = old_lsmOptionsToNameValue(opts);
    if isempty(args)
        img = correctBidirectionalLSMArtifact(img);
    else
        img = correctBidirectionalLSMArtifact(img, args{:});
    end
end

function args = old_lsmOptionsToNameValue(opts)
    opts = old_sanitizeLSMOptions(opts);
    names = fieldnames(opts);
    args = cell(1, 2*numel(names));
    for k = 1:numel(names)
        args{2*k-1} = names{k};
        args{2*k} = old_parseLSMOptionValue(opts.(names{k}));
    end
end

function v = old_parseLSMOptionValue(v)
    if isnumeric(v) || islogical(v)
        return;
    end
    if isstring(v)
        v = char(v);
    end
    if ~ischar(v)
        return;
    end
    txt = strtrim(v);
    low = lower(txt);
    if any(strcmp(low, {'true','false'}))
        v = strcmp(low, 'true');
        return;
    end
    num = str2num(txt); %#ok<ST2NM>
    if ~isempty(num)
        v = num;
        return;
    end
    if startsWith(txt, '"') && endsWith(txt, '"') && strlength(string(txt)) >= 2
        v = extractBetween(string(txt), 2, strlength(string(txt))-1);
        v = char(v);
    end
end

function [pages, rzArr, pagesFull] = old_preprocessAllPages(imgFile, nPages, mapData, lsmOptions)
    % Preprocess every page of a source file and return the finished
    % per-page images plus their resize factors.
    %
    % Two image sets are returned per page:
    %   pages     - joint-LSM + background-subtracted + RESIZED. This is
    %               exactly the input the detection model receives.
    %   pagesFull - the same preprocessing WITHOUT the final resize, i.e.
    %               at the source resolution. Snap (snapToCellCentroid)
    %               uses this so it sees the same pixels the detector did
    %               while keeping coordinates and PixelSize in
    %               original-image space (no resize remapping).
    %
    % LSM bidirectional correction is driven by ALL channels jointly
    % (correctBidirectionalLSMArtifact, UseAllChannels). Correcting each
    % page (single channel) in isolation makes the displacement field
    % unreliable wherever that one channel is dim, producing edge
    % artifacts (e.g. a dim green channel). So when any page requests LSM
    % correction, all same-size single-channel pages are stacked and
    % corrected together in one call — matching a full-stack manual run.
    % Background subtraction and resize are then applied per page (they
    % are channel-independent). Pages not listed in the map pass through
    % unmodified so the page count always matches the source file.

    % Build a lookup: page number -> row index in mapData.
    pageToRow = containers.Map('KeyType', 'int32', 'ValueType', 'int32');
    for r = 1:size(mapData, 1)
        pg = int32(CellToolkit.parseNum(mapData{r,1}, 0));
        if pg >= 1
            pageToRow(pg) = int32(r);
        end
    end

    % Read all pages and resolve each page's preprocessing settings.
    rawPages = cell(1, nPages);
    wantLSM  = false(1, nPages);
    bgArr    = zeros(1, nPages);
    rzArr    = ones(1, nPages);
    for pg = 1:nPages
        rawPages{pg} = CellToolkit.readPage(imgFile, pg, nPages);
        if isKey(pageToRow, int32(pg))
            r           = pageToRow(int32(pg));
            wantLSM(pg) = CellToolkit.parseLogical(mapData{r,5}, false);
            bgArr(pg)   = CellToolkit.parseNum(mapData{r,6}, 0);
            rzArr(pg)   = old_resolveResize( ...
                imgFile, pg, CellToolkit.parseNum(mapData{r,7}, 1));
        end
    end

    % Joint-channel LSM correction (once for all LSM-requested pages).
    % Only pages that have wantLSM=true are corrected; others stay raw.
    % Stack only the LSM-requested pages so non-LSM pages are not
    % affected, then redistribute the corrected slices back by index.
    lsmIdx = find(wantLSM);   % indices of pages that want LSM
    corrPages = rawPages;     % start as copy; overwrite LSM pages below
    if ~isempty(lsmIdx)
        if exist('correctBidirectionalLSMArtifact', 'file') ~= 2
            error('correctBidirectionalLSMArtifact.m must be on the MATLAB path to use Correct LSM.');
        end
        lsmRaws   = rawPages(lsmIdx);
        sameSize  = all(cellfun(@(im) isequal(size(im), size(lsmRaws{1})), lsmRaws));
        allSingle = all(cellfun(@(im) size(im, 3) == 1, lsmRaws));
        if numel(lsmIdx) > 1 && sameSize && allSingle
            stack  = cat(3, lsmRaws{:});   % H x W x numel(lsmIdx) stack
            Jstack = old_callCorrectBidirectionalLSMArtifact(stack, lsmOptions);
            for k = 1:numel(lsmIdx)
                corrPages{lsmIdx(k)} = Jstack(:,:,k);
            end
        else
            for k = 1:numel(lsmIdx)
                corrPages{lsmIdx(k)} = old_callCorrectBidirectionalLSMArtifact(lsmRaws{k}, lsmOptions);
            end
        end
    end

    % Per-page background subtraction (LSM already applied above), then
    % resize. pagesFull holds the bg-subtracted page at source
    % resolution; pages resizes it. Splitting the single applyPreprocess
    % call into "bg, then resize" yields pixels identical to the previous
    % combined call (order is unchanged: bg first, resize second) while
    % exposing the pre-resize image for snap.
    pages     = cell(1, nPages);
    pagesFull = cell(1, nPages);
    for pg = 1:nPages
        full          = old_applyPreprocess(corrPages{pg}, false, lsmOptions, bgArr(pg), 1);
        pagesFull{pg} = full;
        if rzArr(pg) > 0 && rzArr(pg) ~= 1
            pages{pg} = old_applyPreprocess(full, false, lsmOptions, 0, rzArr(pg));
        else
            pages{pg} = full;
        end
    end
end

function old_writeScratchTiff(img, path, createNew)
    % Write a single-page scratch TIFF.  The Tiff low-level class is used
    % instead of imwrite() so float32, uint8, uint16, int16, and uint32
    % source images are all handled correctly.  createNew is unused here
    % (scratch files are always single-page overwrites) but accepted so
    % callers with three arguments don't error.
    if isa(img, 'double')
        img = single(img);   % Tiff supports float32; float64 is exotic
    end
    t = Tiff(path, 'w');
    nCh = size(img, 3);

    phot = Tiff.Photometric.MinIsBlack; % assume this is always the case
    
    switch class(img)
        case 'single'
            bps = 32;  sf = Tiff.SampleFormat.IEEEFP;
        case 'uint16'
            bps = 16;  sf = Tiff.SampleFormat.UInt;
        case 'int16'
            bps = 16;  sf = Tiff.SampleFormat.Int;
        case 'uint32'
            bps = 32;  sf = Tiff.SampleFormat.UInt;
        otherwise   % uint8, logical, etc.
            img = uint8(img);
            bps = 8;   sf = Tiff.SampleFormat.UInt;
    end
    t.setTag('ImageLength',         size(img, 1));
    t.setTag('ImageWidth',          size(img, 2));
    t.setTag('Photometric',         phot);   % must precede SamplesPerPixel
    t.setTag('BitsPerSample',       bps);    % must precede SamplesPerPixel
    t.setTag('SamplesPerPixel',     nCh);
    t.setTag('SampleFormat',        sf);
    t.setTag('PlanarConfiguration', Tiff.PlanarConfiguration.Chunky);
    t.setTag('Compression',         Tiff.Compression.None);
    t.write(img);
    t.close();
end

function [out, lims] = old_normalizeIntensity(img, pct, target)
    % Linearly stretch an image so that its pct(1)-th percentile maps to
    % 0 and its pct(2)-th percentile to target, clipping outside.
    %   [out, lims] = CellToolkit.normalizeIntensity(img)            % [1 99.9] -> [0 255]
    %   [out, lims] = CellToolkit.normalizeIntensity(img, pct, target)
    %
    % The detection models were trained on 8-bit images and predict.py
    % divides pixel values by 255, so an image on any other scale
    % (16-bit, float projections, ...) reaches the model outside the
    % intensity range it learned and the number of detections follows
    % the image brightness. This puts every image on the same scale.
    %
    % out is single; lims = [lo hi] are the source intensities mapped to
    % 0 and target ([NaN NaN], with out = single(img), when the image
    % has no intensity spread to stretch). Multi-channel images are
    % stretched per channel (lims then has one row per channel).
    % Percentiles are taken over a regular subsample (<= ~4 M pixels)
    % of the finite pixels, so no toolbox is needed.
    if nargin < 2 || isempty(pct),    pct    = [1 99.9]; end
    if nargin < 3 || isempty(target), target = 255;      end
    out  = single(img);
    nCh  = size(out, 3);
    lims = nan(nCh, 2);
    step = max(1, floor(sqrt(size(out, 1) * size(out, 2) / 4e6)));
    for c = 1:nCh
        v = out(1:step:end, 1:step:end, c);
        v = sort(double(v(isfinite(v))));
        n = numel(v);
        if n == 0, continue; end
        lo = v(max(1, min(n, round(pct(1) / 100 * (n - 1)) + 1)));
        hi = v(max(1, min(n, round(pct(2) / 100 * (n - 1)) + 1)));
        if ~(hi > lo), continue; end
        ch = (out(:, :, c) - single(lo)) * single(target / (hi - lo));
        out(:, :, c) = min(max(ch, 0), single(target));
        lims(c, :)   = [lo hi];
    end
end

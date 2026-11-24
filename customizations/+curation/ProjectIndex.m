classdef ProjectIndex < handle
%PROJECTINDEX  Every source of a project folder: curation rows (labels) and cached features,
%   gathered read-only for the assist model and the audit.
%
%   idx = curation.ProjectIndex.build(parentDir, opts)
%   rep = idx.refresh(opts)              re-read sources whose files changed; recompute features
%                                        only where the fingerprint changed (opts.Rediscover
%                                        true: also look for new datasets)
%   [F, y, groups, sections, ids, calibrateOn] = idx.trainingSet(kind)
%   [T, F] = idx.table(kind)             every row of that kind, with Kind, SourceId, Section,
%                                        Animal, SourceKey, Folder, Base, RowId + the curation
%                                        columns (+ PriorLabel, PriorProposalP); F aligned (NaN
%                                        rows: no features)
%   [F, T] = idx.source(folder, base, key)   features + rows of one source (computed on demand)
%   s = idx.summary()                    per kind: sources, candidates, reviewed, labels per
%                                        class, sections with labels, animals
%   p = curation.ProjectIndex.modelPath(parentDir, kind)
%                                        fullfile(parentDir, '.cellcuration', ['assist_' kind '.mat'])
%
%   BUILD OPTIONS (struct, every field optional)
%     CacheDir   feature cache folder (default %LOCALAPPDATA%\counting_perineuronal_nets\cache\
%                <hash of parentDir>); must not be inside parentDir (the data tree is never
%                written)
%     All        false: compute features only for sources with labels or audit roles (reading
%                an image costs ~0.5 s); true: for every source
%     Progress   function handle Progress(k, n, name), called before each source
%     ReadImages true: read the image pages (features) and the TIFF calibration (pixel size) when
%                needed; false: never read an image (see BACKGROUND)
%     Features   true; false: the curation rows only, no feature is loaded or computed (what
%                curation.TrainingPanel counts from, on the background pool)
%
%   BACKGROUND. Thread workers (backgroundPool, a thread pool's parfeval) cannot read TIFF files.
%   There, build and refresh with struct('ReadImages', false); with ReadImages true they throw
%   curation:ProjectIndex:imagesOnThread instead of silently getting no features and a guessed
%   pixel size. Without images: features come only from the cache of an unchanged source (rows,
%   image file and pixel size as when they were computed), nothing is computed (idx.Warnings says
%   which sources lack them), and the pixel size comes only from the curation JSON or the
%   manifest (else UmPerPx NaN, UmSource "not read": never the 0.645 default). This is what
%   curation.AssistRunner does: its index job builds on the background pool with ReadImages=false,
%   and it computes the features itself, of the sources on screen from the pages the window holds
%   (curation.Features.compute on the worker) and of labelled sources not on screen from pages it
%   reads in MATLAB's own thread.
%
%   DISCOVERY. CellDatasetManifest.discover(parentDir, WriteManifest=false, Probe=false); a
%   source is one detected (channel, page) of a dataset: it needs its detector locs file (the
%   manifest's 'locs', else a full-resolution activeLocs). Section = path of <folder>/<base>
%   relative to parentDir ('/' separators; unique). Animal = curation.ProjectIndex.animalId:
%   the digits after "SUBJ-ID-" in the dataset base, else in the folder path, else the base;
%   leading zeros are dropped ("SUBJ-ID-0127" and "SUBJ-ID-127" are one animal, so grouped
%   cross-validation never splits it). Companion = another source of the same dataset (a
%   different kind preferred), used for the companion-channel features.
%
%   READING (never takes a lock, never writes): the snapshot '<stem>_curation.csv' (columns as
%   curation.Store.COLUMNS), its record in '<base>.curation.json' (revision, journalBytes,
%   umPerPixel), then the journal lines newer than that revision are replayed on top (so labels
%   appear before the store's 2 s debounced snapshot). A source without a snapshot contributes
%   its locs rows, unlabelled (CellID 1..n in file order, as the store would create them).
%   PriorLabel: for confirm-audit rows re-labelled blind, the label they had before (the Old
%   value of the Label line in the journal transaction that set LabelSource to blind; no such
%   line = unchanged); "" for every other row. PriorProposalP: for the same rows, the P shown
%   when they were confirmed (the Old value of the ProposalP line of that transaction, else the
%   current ProposalP), which gives the band of the page they were confirmed on; NaN otherwise.
%
%   FEATURES (curation.Features, from the image page of the source and its companion page)
%   are cached per source in CacheDir as feat_<hash of SourceId>.mat with a fingerprint of the
%   rows' CellID / X / Y / score / rescore / InLocs, the image file (path, size, time), the
%   pages, the pixel size and curation.Features.VERSION. The neighbour features count every
%   detection in the current locs (InLocs), whatever its curation state: labels, merges and
%   exclusions never change any row's features (moving a cell does: X/Y).
%   Pixel size per source: the curation JSON, else the manifest image record, else the TIFF
%   calibration, else 0.645 um/px with a warning (idx.Warnings).
%
%   Counters: FeatureComputations, CacheHits, SnapshotReads, ImageReads (for tests/diagnostics).
%
%   See also curation.Features, curation.AssistModel, curation.Audit, CellDatasetManifest.

    properties (Constant)
        CACHE_FORMAT = "featcache/1"
    end

    properties (SetAccess = private)
        ParentDir char = ''
        CacheDir char = ''
        Sources table = table()
        Options struct = struct()
        Warnings string = strings(0, 1)
        Counters struct = struct('FeatureComputations', 0, 'CacheHits', 0, 'SnapshotReads', 0, 'ImageReads', 0)
    end

    properties (Access = private)
        Rows cell = {}
        Feat cell = {}
        FeatFp string = strings(0, 1)
        Stamps cell = {}
        PageCache = struct('Key', {}, 'Page', {})
    end

    %% ------------------------------------------------------------------ construction
    methods (Static)
        function idx = build(parentDir, opts)
            %BUILD  Discover the sources below parentDir and read them (see the class help).
            if nargin < 2 || isempty(opts), opts = struct(); end
            idx = curation.ProjectIndex();
            pd = char(parentDir);
            if ~isfolder(pd)
                error('curation:ProjectIndex:noFolder', 'Folder not found: %s', pd);
            end
            pd = curation.ProjectIndex.absPath(pd);
            idx.ParentDir = pd;
            o = struct('CacheDir', '', 'All', false, 'Progress', [], 'ReadImages', true, 'Features', true);
            f = fieldnames(opts);
            for i = 1:numel(f), o.(f{i}) = opts.(f{i}); end
            o.ReadImages = logical(o.ReadImages);
            curation.ProjectIndex.checkThread(o.ReadImages);
            if isempty(o.CacheDir)
                root = getenv('LOCALAPPDATA');
                if isempty(root), root = tempdir; end
                o.CacheDir = fullfile(root, 'counting_perineuronal_nets', 'cache', ...
                    char(curation.Hash.of(lower(pd))));
            end
            cd = curation.ProjectIndex.absPath(char(o.CacheDir));
            a = lower(strrep(cd, '/', '\'));
            b = lower(strrep(pd, '/', '\'));
            if startsWith([a '\'], [b '\'])
                error('curation:ProjectIndex:cacheInData', ...
                    'The feature cache (%s) must not be inside the data folder (%s).', cd, pd);
            end
            if ~isfolder(cd), mkdir(cd); end
            idx.CacheDir = cd;
            idx.Options = o;
            idx.Sources = curation.ProjectIndex.emptySources();
            idx.discover();
            n = height(idx.Sources);
            st = idx.allStamps();
            for i = 1:n
                if ~isempty(o.Progress)
                    o.Progress(i, n, char(idx.Sources.SourceId(i)));
                end
                idx.readSource(i, st{i});
                if idx.needsFeatures(i)
                    idx.ensureFeatures(i);
                end
            end
            idx.PageCache = struct('Key', {}, 'Page', {});
        end

        function p = modelPath(parentDir, kind)
            %MODELPATH  Where the assist model of a kind lives: with the data.
            p = fullfile(char(parentDir), '.cellcuration', ['assist_' char(kind) '.mat']);
        end

        function a = animalId(base, folder)
            %ANIMALID  Animal of a dataset: the digits after "SUBJ-ID-" in the dataset base, else
            %   the last such digits in the folder path, else the base itself. Leading zeros are
            %   dropped ("0127" -> "127", "000" -> "0"), so one animal never becomes two groups.
            t = regexp(char(base), 'SUBJ-ID-(\d+)', 'tokens', 'once', 'ignorecase');
            if ~isempty(t)
                a = curation.ProjectIndex.stripZeros(t{1});
                return;
            end
            t = regexp(char(folder), 'SUBJ-ID-(\d+)', 'tokens', 'ignorecase');
            if ~isempty(t)
                a = curation.ProjectIndex.stripZeros(t{end}{1});
                return;
            end
            a = string(base);
        end
    end

    methods (Access = private)
        function idx = ProjectIndex()
        end
    end

    %% ------------------------------------------------------------------ public API
    methods
        function rep = refresh(idx, opts)
            %REFRESH  Re-read changed sources, recompute features where their fingerprint changed.
            %   rep: Reread, Recomputed, Added (counts), Changed (SourceIds re-read).
            if nargin < 2 || isempty(opts), opts = struct(); end
            rep = struct('Reread', 0, 'Recomputed', 0, 'Added', 0, 'Changed', strings(0, 1));
            curation.ProjectIndex.checkThread(idx.readsImages());
            if isfield(opts, 'Rediscover') && opts.Rediscover
                n0 = height(idx.Sources);
                idx.discover();
                rep.Added = height(idx.Sources) - n0;
            end
            st = idx.allStamps();
            before = idx.Counters.FeatureComputations;
            for i = 1:height(idx.Sources)
                if isempty(idx.Stamps{i}) || ~isequal(st{i}, idx.Stamps{i})
                    idx.readSource(i, st{i});
                    rep.Reread = rep.Reread + 1;
                    rep.Changed(end + 1, 1) = idx.Sources.SourceId(i);
                end
                if idx.needsFeatures(i) || (idx.Sources.HasFeatures(i) && ...
                        ~(isfield(idx.Options, 'Features') && ~logical(idx.Options.Features)))
                    idx.ensureFeatures(i);
                end
            end
            rep.Recomputed = idx.Counters.FeatureComputations - before;
            idx.PageCache = struct('Key', {}, 'Page', {});
        end

        function [F, y, groups, sections, ids, calibrateOn] = trainingSet(idx, kind)
            %TRAININGSET  Labelled rows of one kind (curation.AssistModel.trainingMask) with
            %   features, stacked over the project. y: Good; groups: animal; ids "<SourceId>|<CellID>".
            %   calibrateOn: N x 1 logical, the rows admissible for fit's opts.CalibrateOn: EVERY
            %   training row (all true). The output used to be the blind mask (confirm-audit,
            %   catch and re-ask rows), and calibrating on those rows, chosen by label or by
            %   disagreement, collapsed P (most candidates got P exactly 0). No subset of the
            %   training rows is a random sample of the candidates that would calibrate better
            %   than all of them, so passing calibrateOn equals the default. Kept in this position
            %   for compatibility.
            K = numel(curation.Features.names());
            Fc = {}; yc = {}; gc = {}; sc = {}; ic = {};
            for i = idx.sourcesOf(kind)'
                T = idx.Rows{i};
                m = curation.AssistModel.trainingMask(T);
                if ~any(m), continue; end
                if isempty(idx.Feat{i})
                    idx.warn(sprintf('%s has %d labelled rows but no features (image missing?); left out.', ...
                        idx.Sources.SourceId(i), nnz(m)));
                    continue;
                end
                Fc{end + 1, 1} = idx.Feat{i}(m, :); %#ok<AGROW>
                yc{end + 1, 1} = T.Label(m) == "Good"; %#ok<AGROW>
                gc{end + 1, 1} = repmat(idx.Sources.Animal(i), nnz(m), 1); %#ok<AGROW>
                sc{end + 1, 1} = repmat(idx.Sources.Section(i), nnz(m), 1); %#ok<AGROW>
                ic{end + 1, 1} = idx.Sources.SourceId(i) + "|" + string(T.CellID(m)); %#ok<AGROW>
            end
            if isempty(Fc)
                F = zeros(0, K); y = false(0, 1); groups = strings(0, 1); sections = strings(0, 1);
                ids = strings(0, 1); calibrateOn = false(0, 1);
                return;
            end
            F = vertcat(Fc{:}); y = vertcat(yc{:}); groups = vertcat(gc{:});
            sections = vertcat(sc{:}); ids = vertcat(ic{:});
            calibrateOn = true(numel(y), 1);
        end

        function [T, F] = table(idx, kind)
            %TABLE  All rows of one kind with their source columns (and features when asked).
            K = numel(curation.Features.names());
            parts = {};
            fparts = {};
            for i = idx.sourcesOf(kind)'
                parts{end + 1, 1} = idx.decorated(i); %#ok<AGROW>
                if nargout > 1
                    if isempty(idx.Feat{i})
                        fparts{end + 1, 1} = nan(height(idx.Rows{i}), K); %#ok<AGROW>
                    else
                        fparts{end + 1, 1} = idx.Feat{i}; %#ok<AGROW>
                    end
                end
            end
            if isempty(parts)
                T = idx.decoratedEmpty();
                F = zeros(0, K);
                return;
            end
            T = vertcat(parts{:});
            if nargout > 1, F = vertcat(fparts{:}); end
        end

        function [F, T] = source(idx, folder, base, key)
            %SOURCE  Features and decorated rows of one source; features computed if needed.
            i = idx.find(folder, base, key);
            idx.ensureFeatures(i);
            F = idx.Feat{i};
            T = idx.decorated(i);
            idx.PageCache = struct('Key', {}, 'Page', {});
        end

        function S = summary(idx)
            %SUMMARY  One row per kind (see the class help).
            kinds = unique(idx.Sources.Kind);
            n = numel(kinds);
            Z = zeros(n, 1);
            S = table(kinds, Z, Z, Z, Z, Z, Z, Z, Z, Z, Z, Z, Z, 'VariableNames', {'Kind', 'Sources', ...
                'SourcesWithLabels', 'SourcesWithFeatures', 'Candidates', 'Reviewed', 'Good', 'Bad', ...
                'Uncertain', 'Sections', 'SectionsWithLabels', 'Animals', 'AnimalsWithLabels'});
            for k = 1:n
                ii = idx.sourcesOf(kinds(k));
                lab = false(numel(ii), 1);
                for j = 1:numel(ii)
                    T = idx.Rows{ii(j)};
                    act = T.State == "active";
                    rv = act & T.Reviewed;
                    S.Candidates(k) = S.Candidates(k) + nnz(act);
                    S.Reviewed(k) = S.Reviewed(k) + nnz(rv);
                    S.Good(k) = S.Good(k) + nnz(rv & T.Label == "Good");
                    S.Bad(k) = S.Bad(k) + nnz(rv & T.Label == "Bad");
                    S.Uncertain(k) = S.Uncertain(k) + nnz(rv & T.Label == "Uncertain");
                    lab(j) = any(rv & (T.Label == "Good" | T.Label == "Bad"));
                end
                S.Sources(k) = numel(ii);
                S.SourcesWithLabels(k) = nnz(lab);
                S.SourcesWithFeatures(k) = nnz(idx.Sources.HasFeatures(ii));
                S.Sections(k) = numel(unique(idx.Sources.Section(ii)));
                S.SectionsWithLabels(k) = numel(unique(idx.Sources.Section(ii(lab))));
                S.Animals(k) = numel(unique(idx.Sources.Animal(ii)));
                S.AnimalsWithLabels(k) = numel(unique(idx.Sources.Animal(ii(lab))));
            end
        end
    end

    %% ------------------------------------------------------------------ discovery and reading
    methods (Access = private)

        function discover(idx)
            mfs = CellDatasetManifest.discover(idx.ParentDir, struct('WriteManifest', false, 'Probe', false));
            S = curation.ProjectIndex.emptySources();
            for d = 1:numel(mfs)
                mf = mfs(d);
                keys = mf.sourceKeys();
                locs = strings(numel(keys), 1);
                for k = 1:numel(keys)
                    locs(k) = string(curation.ProjectIndex.detectorLocs(mf, keys{k}));
                end
                have = find(locs ~= "");
                if isempty(have), continue; end
                folder = string(mf.Folder);
                base = string(mf.Base);
                rel = string(strrep(CellToolkit.makeRelativePath(fullfile(mf.Folder, mf.Base), idx.ParentDir), '\', '/'));
                animal = curation.ProjectIndex.animalId(base, folder);
                json = string(mf.curationJsonPath());
                for k = have'
                    key = string(keys{k});
                    kind = curation.Proposals.kindOf(key);
                    [~, page] = mf.channelPage(keys{k});
                    if ~isfinite(page), page = 1; end
                    img = "";
                    try img = string(mf.imageForLocs(char(locs(k)))); catch, end
                    csv = string(mf.curationPath(keys{k}));
                    jr = replace(csv, "_curation.csv", "_curation.journal.csv");
                    % companion: another detected source of the dataset, another kind first
                    others = setdiff(have, k);
                    ck = ""; cp = NaN;
                    if ~isempty(others)
                        okinds = strings(numel(others), 1);
                        for q = 1:numel(others)
                            okinds(q) = curation.Proposals.kindOf(keys{others(q)});
                        end
                        j = others(find(okinds ~= kind, 1));
                        if isempty(j), j = others(1); end
                        ck = string(keys{j});
                        [~, cp] = mf.channelPage(keys{j});
                        if ~isfinite(cp), cp = NaN; end
                    end
                    um = NaN; umSrc = "";
                    try
                        u = mf.Data.image.umPerPixel;
                        if isnumeric(u) && isscalar(u) && isfinite(u) && u > 0
                            um = double(u); umSrc = "manifest";
                        end
                    catch
                    end
                    sid = rel + "|" + key;
                    S(end + 1, :) = {sid, rel, animal, folder, base, key, kind, locs(k), csv, json, jr, img, ...
                        page, ck, cp, um, umSrc, false, 0, 0, false}; %#ok<AGROW>
                end
            end
            S = sortrows(S, 'SourceId');
            % keep the data of sources already known
            old = idx.Sources;
            n = height(S);
            rows = cell(n, 1); feat = cell(n, 1); fp = strings(n, 1); stamps = cell(n, 1);
            for i = 1:n
                j = find(old.SourceId == S.SourceId(i), 1);
                if ~isempty(j)
                    rows{i} = idx.Rows{j}; feat{i} = idx.Feat{j}; fp(i) = idx.FeatFp(j); stamps{i} = idx.Stamps{j};
                    S(i, {'HasSnapshot', 'NumRows', 'NumLabelled', 'HasFeatures', 'UmPerPx', 'UmSource'}) = ...
                        old(j, {'HasSnapshot', 'NumRows', 'NumLabelled', 'HasFeatures', 'UmPerPx', 'UmSource'});
                end
            end
            idx.Sources = S;
            idx.Rows = rows; idx.Feat = feat; idx.FeatFp = fp; idx.Stamps = stamps;
        end

        function readSource(idx, i, stamp)
            if nargin < 3
                st = idx.allStamps(i);
                stamp = st{1};
            end
            s = idx.Sources(i, :);
            csv = char(s.CurationCsv);
            rec = curation.ProjectIndex.jsonRecord(char(s.CurationJson), char(s.Key));
            if isfile(csv)
                C = curation.ProjectIndex.readSnapshot(csv);
                rev = curation.ProjectIndex.recField(rec, 'revision', 0);
                from = curation.ProjectIndex.recField(rec, 'journalBytes', 0);
                idx.Sources.HasSnapshot(i) = true;
            else
                C = curation.ProjectIndex.rowsFromLocs(char(s.LocsFile));
                rev = 0;
                from = 0;
                idx.Sources.HasSnapshot(i) = false;
            end
            jr = char(s.JournalFile);
            if isfile(jr)
                C = curation.ProjectIndex.replay(C, jr, rev, from);
            end
            u = curation.ProjectIndex.recField(rec, 'umPerPixel', NaN);
            if isnumeric(u) && isscalar(u) && isfinite(u) && u > 0
                idx.Sources.UmPerPx(i) = double(u);
                idx.Sources.UmSource(i) = "curation json";
            end
            T = struct2table(C);
            [T.PriorLabel, T.PriorProposalP] = curation.ProjectIndex.priorLabels(T, jr);
            idx.Rows{i} = T;
            idx.Stamps{i} = stamp;
            idx.Sources.NumRows(i) = height(T);
            idx.Sources.NumLabelled(i) = nnz(T.Reviewed & T.Label ~= "");
            idx.Counters.SnapshotReads = idx.Counters.SnapshotReads + 1;
        end

        function tf = needsFeatures(idx, i)
            tf = false;
            if isfield(idx.Options, 'Features') && ~logical(idx.Options.Features), return; end
            T = idx.Rows{i};
            tf = idx.Options.All || (~isempty(T) && (any(T.Reviewed & T.Label ~= "") || any(T.AuditRole ~= "")));
        end

        function ensureFeatures(idx, i)
            s = idx.Sources(i, :);
            T = idx.Rows{i};
            img = char(s.ImageFile);
            if isempty(img) || ~isfile(img)
                idx.warn(sprintf('%s: image not found; no features.', s.SourceId));
                return;
            end
            um = idx.pixelSize(i);
            if ~(isfinite(um) && um > 0)
                idx.warn(sprintf(['%s: no features (ReadImages false: the TIFF calibration was not read and no ' ...
                    'pixel size is recorded).'], s.SourceId));
                return;
            end
            fp = curation.ProjectIndex.fingerprint(T, img, s.Page, s.CompanionPage, um);
            if idx.FeatFp(i) == fp && ~isempty(idx.Feat{i}), return; end
            cfile = fullfile(idx.CacheDir, ['feat_' char(curation.Hash.of(s.SourceId)) '.mat']);
            if isfile(cfile)
                try
                    Cc = load(cfile);
                    if isfield(Cc, 'Fingerprint') && string(Cc.Fingerprint) == fp && ...
                            isequal(Cc.Names, curation.Features.names()) && size(Cc.F, 1) == height(T)
                        idx.Feat{i} = Cc.F;
                        idx.FeatFp(i) = fp;
                        idx.Sources.HasFeatures(i) = true;
                        idx.Counters.CacheHits = idx.Counters.CacheHits + 1;
                        return;
                    end
                catch
                end
            end
            if ~idx.readsImages()
                idx.warn(sprintf(['%s: features not computed (ReadImages false: images are not read here; ' ...
                    '%d labelled rows have none).'], s.SourceId, nnz(T.Reviewed & T.Label ~= "")));
                return;
            end
            pageT = idx.page(img, s.Page);
            pageC = [];
            if s.CompanionKey ~= "" && isfinite(s.CompanionPage)
                pageC = idx.page(img, s.CompanionPage);
                if ~isequal(size(pageC), size(pageT)), pageC = []; end
            end
            if isempty(pageT)
                idx.warn(sprintf('%s: page %d of %s could not be read; no features.', s.SourceId, s.Page, img));
                return;
            end
            F = curation.Features.compute(pageT, pageC, T, um, struct('NeighbourMask', logical(T.InLocs)));
            idx.Counters.FeatureComputations = idx.Counters.FeatureComputations + 1;
            idx.Feat{i} = F;
            idx.FeatFp(i) = fp;
            idx.Sources.HasFeatures(i) = true;
            Cs = struct('Format', curation.ProjectIndex.CACHE_FORMAT, 'Fingerprint', fp, ...
                'SourceId', s.SourceId, 'CellID', T.CellID, 'F', F, 'Names', curation.Features.names(), ...
                'Version', curation.Features.VERSION);
            try
                [~, tok] = fileparts(tempname);
                tmp = [cfile '.' tok '.tmp.mat'];
                save(tmp, '-struct', 'Cs', '-v7');
                movefile(tmp, cfile, 'f');
            catch ME
                idx.warn(sprintf('Feature cache not written (%s): %s', cfile, ME.message));
            end
        end

        function tf = readsImages(idx)
            tf = ~isfield(idx.Options, 'ReadImages') || logical(idx.Options.ReadImages);
        end

        function um = pixelSize(idx, i)
            um = idx.Sources.UmPerPx(i);
            if isfinite(um) && um > 0, return; end
            if ~idx.readsImages()
                um = NaN;                         % never guessed: the caller decides (BACKGROUND)
                idx.Sources.UmSource(i) = "not read";
                return;
            end
            um = CellToolkit.tiffPixelSizeUm(char(idx.Sources.ImageFile(i)), idx.Sources.Page(i));
            if isfinite(um) && um > 0
                idx.Sources.UmSource(i) = "tiff";
            else
                um = curation.Store.DEFAULT_UM_PER_PIXEL;
                idx.Sources.UmSource(i) = "default";
                idx.warn(sprintf('%s: no pixel size found; %.3f um/px assumed.', idx.Sources.SourceId(i), um));
            end
            idx.Sources.UmPerPx(i) = um;
        end

        function P = page(idx, img, pg)
            key = sprintf('%s|%d', lower(img), pg);
            for k = 1:numel(idx.PageCache)
                if strcmp(idx.PageCache(k).Key, key)
                    P = idx.PageCache(k).Page;
                    return;
                end
            end
            try
                P = imread(img, pg);
            catch
                try
                    P = imread(img);
                catch
                    P = [];
                end
            end
            idx.Counters.ImageReads = idx.Counters.ImageReads + 1;
            idx.PageCache(end + 1) = struct('Key', key, 'Page', P);
            if numel(idx.PageCache) > 4, idx.PageCache(1) = []; end
        end

        function st = allStamps(idx, which)
            % File stamps (bytes, datenum) of each source's snapshot, JSON, journal, locs, image;
            % one directory listing per folder.
            if nargin < 2, which = 1:height(idx.Sources); end
            st = cell(numel(which), 1);
            listing = containers.Map('KeyType', 'char', 'ValueType', 'any');
            for k = 1:numel(which)
                i = which(k);
                files = [idx.Sources.CurationCsv(i), idx.Sources.CurationJson(i), ...
                    idx.Sources.JournalFile(i), idx.Sources.LocsFile(i), idx.Sources.ImageFile(i)];
                v = zeros(1, 2 * numel(files));
                for f = 1:numel(files)
                    if files(f) == "", continue; end
                    [d, nm, ex] = fileparts(char(files(f)));
                    key = lower(d);
                    if ~isKey(listing, key)
                        L = dir(d);
                        L = L(~[L.isdir]);
                        m = containers.Map('KeyType', 'char', 'ValueType', 'any');
                        for q = 1:numel(L)
                            m(lower(L(q).name)) = [L(q).bytes L(q).datenum];
                        end
                        listing(key) = m;
                    end
                    m = listing(key);
                    nmx = lower([nm ex]);
                    if isKey(m, nmx), v(2 * f - 1:2 * f) = m(nmx); end
                end
                % the store keeps its journal open, and a directory listing shows a stale size
                % and time (updated lazily) for an open file on Windows: the journal is
                % append-only, so its length from a fresh handle is its stamp
                if v(5) > 0 || isfile(char(files(3)))
                    v(5) = curation.Journal.fileLength(char(files(3)));
                end
                v(6) = 0;
                st{k} = v;
            end
        end

        function i = find(idx, folder, base, key)
            f = lower(strrep(curation.ProjectIndex.absPath(char(folder)), '/', '\'));
            F = lower(strrep(idx.Sources.Folder, '/', '\'));
            i = find(F == string(f) & lower(idx.Sources.Base) == lower(string(base)) & ...
                lower(idx.Sources.Key) == lower(string(key)), 1);
            if isempty(i)
                error('curation:ProjectIndex:unknownSource', 'No source %s / %s / %s in this index.', ...
                    char(folder), char(base), char(key));
            end
        end

        function ii = sourcesOf(idx, kind)
            ii = find(idx.Sources.Kind == string(kind));
            ii = ii(:);
        end

        function T = decorated(idx, i)
            R = idx.Rows{i};
            n = height(R);
            s = idx.Sources(i, :);
            D = table(repmat(s.Kind, n, 1), repmat(s.SourceId, n, 1), repmat(s.Section, n, 1), ...
                repmat(s.Animal, n, 1), repmat(s.Key, n, 1), repmat(s.Folder, n, 1), repmat(s.Base, n, 1), ...
                s.SourceId + "|" + string(R.CellID), 'VariableNames', ...
                {'Kind', 'SourceId', 'Section', 'Animal', 'SourceKey', 'Folder', 'Base', 'RowId'});
            T = [D R];
        end

        function T = decoratedEmpty(~)
            C = curation.ProjectIndex.emptyColumns(0);
            R = struct2table(C);
            R.PriorLabel = strings(0, 1);
            R.PriorProposalP = zeros(0, 1);
            e = strings(0, 1);
            D = table(e, e, e, e, e, e, e, e, 'VariableNames', ...
                {'Kind', 'SourceId', 'Section', 'Animal', 'SourceKey', 'Folder', 'Base', 'RowId'});
            T = [D R];
        end

        function warn(idx, msg)
            msg = string(msg);
            if ~any(idx.Warnings == msg)
                idx.Warnings(end + 1, 1) = msg;
            end
        end
    end

    %% ------------------------------------------------------------------ static helpers
    methods (Static, Access = private)

        function S = emptySources()
            e = strings(0, 1);
            S = table(e, e, e, e, e, e, e, e, e, e, e, e, zeros(0, 1), e, zeros(0, 1), zeros(0, 1), e, ...
                false(0, 1), zeros(0, 1), zeros(0, 1), false(0, 1), 'VariableNames', ...
                {'SourceId', 'Section', 'Animal', 'Folder', 'Base', 'Key', 'Kind', 'LocsFile', 'CurationCsv', ...
                'CurationJson', 'JournalFile', 'ImageFile', 'Page', 'CompanionKey', 'CompanionPage', ...
                'UmPerPx', 'UmSource', 'HasSnapshot', 'NumRows', 'NumLabelled', 'HasFeatures'});
        end

        function p = absPath(p)
            p = char(p);
            if isfolder(p)
                d = dir(p);
                if ~isempty(d), p = d(1).folder; end
            end
        end

        function locs = detectorLocs(mf, key)
            % The detector locs file of a source (never a *_resized.csv), or ''.
            locs = '';
            s = mf.source(key);
            if isempty(s), return; end
            for f = {'locs', 'activeLocs'}
                if ~isfield(s, f{1}) || isempty(s.(f{1})), continue; end
                p = char(s.(f{1}));
                if ~(numel(p) > 1 && (p(2) == ':' || startsWith(p, '\\') || startsWith(p, '/')))
                    p = fullfile(mf.Folder, p);
                end
                if isfile(p) && isempty(regexpi(p, '_resized\.csv$', 'once'))
                    locs = p;
                    return;
                end
            end
        end

        function a = stripZeros(d)
            d = regexprep(char(d), '^0+', '');
            if isempty(d), d = '0'; end
            a = string(d);
        end

        function rec = jsonRecord(path, key)
            rec = [];
            if ~isfile(path), return; end
            try
                J = jsondecode(fileread(path));
                if isstruct(J) && isfield(J, 'sources') && isstruct(J.sources) && isfield(J.sources, key)
                    rec = J.sources.(key);
                end
            catch
            end
        end

        function v = recField(rec, name, d)
            v = d;
            if isstruct(rec) && isfield(rec, name) && ~isempty(rec.(name))
                v = rec.(name);
            end
        end

        function C = emptyColumns(n)
            cols = curation.Store.COLUMNS;
            types = curation.Store.TYPES;
            C = struct();
            for k = 1:numel(cols)
                switch types(k)
                    case "double", v = nan(n, 1);
                    case "uint32", v = zeros(n, 1, 'uint32');
                    case "logical", v = false(n, 1);
                    otherwise, v = strings(n, 1);
                end
                C.(char(cols(k))) = v;
            end
            C.Origin(:) = "detected";
            C.State(:) = "active";
            C.PosSource(:) = "det";
        end

        function C = readSnapshot(path)
            % The snapshot CSV, read-only, with the store's column types.
            cols = curation.Store.COLUMNS;
            types = curation.Store.TYPES;
            fid = fopen(path, 'r', 'n', 'UTF-8');
            if fid < 0
                error('curation:ProjectIndex:readFailed', 'Cannot open %s.', path);
            end
            hdr = fgetl(fid);
            if ~ischar(hdr), hdr = ''; end
            hdr = strtrim(strrep(hdr, char(65279), ''));
            D = [];
            if strcmp(hdr, char(join(cols, ",")))
                spec = repmat({'%q'}, 1, numel(types));
                spec(types == "double" | types == "logical") = {'%f'};
                spec(types == "uint32") = {'%u32'};
                try
                    D = textscan(fid, [spec{:}], 'Delimiter', ',', 'Whitespace', '', ...
                        'EmptyValue', NaN, 'ReturnOnError', false);
                    if any(cellfun(@numel, D) ~= numel(D{1})), D = []; end
                catch
                    D = [];
                end
            end
            fclose(fid);
            if ~isempty(D)
                C = struct();
                for k = 1:numel(cols)
                    v = D{k};
                    switch types(k)
                        case "logical", v = v ~= 0 & ~isnan(v);
                        case "string", v = string(v);
                        case "uint32", v = uint32(v);
                    end
                    C.(char(cols(k))) = reshape(v, [], 1);
                end
                return;
            end
            T = readtable(path, 'TextType', 'string', 'VariableNamingRule', 'preserve', 'Delimiter', ',');
            n = height(T);
            C = curation.ProjectIndex.emptyColumns(n);
            names = string(T.Properties.VariableNames);
            for k = 1:numel(cols)
                j = find(names == cols(k), 1);
                if isempty(j), continue; end
                C.(char(cols(k))) = curation.ProjectIndex.coerce(T.(char(names(j))), types(k), n);
            end
        end

        function v = coerce(v, type, n)
            switch type
                case "uint32"
                    if ~isnumeric(v), v = str2double(string(v)); end
                    v = double(v); v(isnan(v)) = 0; v = uint32(v);
                case "double"
                    if ~isnumeric(v) && ~islogical(v), v = str2double(string(v)); end
                    v = double(v);
                case "logical"
                    if isnumeric(v)
                        v = v ~= 0 & ~isnan(v);
                    elseif ~islogical(v)
                        s = lower(strtrim(string(v)));
                        v = s == "1" | s == "true";
                    end
                otherwise
                    if isnumeric(v) && all(isnan(v(:)))
                        v = strings(n, 1);
                    else
                        v = string(v);
                        v(ismissing(v)) = "";
                    end
            end
            v = reshape(v, [], 1);
        end

        function C = rowsFromLocs(path)
            % Unlabelled rows from a detector locs CSV (CellID 1..n in file order).
            L = readtable(path, 'TextType', 'string', 'VariableNamingRule', 'preserve');
            n = height(L);
            C = curation.ProjectIndex.emptyColumns(n);
            C.CellID = uint32((1:n)');
            names = string(L.Properties.VariableNames);
            get = @(nm) curation.ProjectIndex.locsCol(L, names, nm, n);
            C.X = double(get("X"));
            C.Y = double(get("Y"));
            C.DET_X = C.X;
            C.DET_Y = C.Y;
            for nm = ["class", "score", "rescore", "thr"]
                C.(char(nm)) = double(get(nm));
            end
            im = get("imgName");
            if isnumeric(im), im = strings(n, 1); end
            im = string(im); im(ismissing(im)) = "";
            C.imgName = im;
            C.InLocs(:) = true;
        end

        function v = locsCol(L, names, nm, n)
            j = find(lower(names) == lower(nm), 1);
            if isempty(j)
                v = nan(n, 1);
            else
                v = L.(char(names(j)));
                if ~isnumeric(v) && nm ~= "imgName", v = str2double(string(v)); end
            end
        end

        function C = replay(C, journal, rev, fromByte)
            % Apply journal lines newer than REV (as curation.Store does on open), read-only.
            R = curation.Journal.read(journal, fromByte);
            if isempty(R.Revision), return; end
            sel = R.RevisionNum > rev & strlength(R.Field) > 0;
            if ~any(sel) && fromByte > 0
                R = curation.Journal.read(journal, 0);       % the offset may be stale
                sel = R.RevisionNum > rev & strlength(R.Field) > 0;
            end
            idx = find(sel);
            if isempty(idx), return; end
            [~, o] = sortrows([R.RevisionNum(idx), idx]);
            idx = idx(o);
            typeOf = curation.Store.TYPE_OF;
            for i = idx'
                f = R.Field(i);
                if f == "+row"
                    row = curation.ProjectIndex.rowFromJson(R.New(i));
                    if isempty(row) || any(C.CellID == row.CellID), continue; end
                    names = fieldnames(C);
                    for k = 1:numel(names)
                        C.(names{k})(end + 1, 1) = row.(names{k});
                    end
                elseif f == "-row"
                    keep = C.CellID ~= uint32(str2double(R.CellID(i)));
                    names = fieldnames(C);
                    for k = 1:numel(names)
                        C.(names{k}) = C.(names{k})(keep);
                    end
                elseif isfield(typeOf, char(f))
                    id = str2double(R.CellID(i));
                    r = find(C.CellID == id, 1);
                    if isempty(r), continue; end
                    v = curation.Journal.decode(R.New(i), typeOf.(char(f)));
                    C.(char(f))(r) = v;
                end
            end
        end

        function R = rowFromJson(txt)
            R = [];
            try
                s = jsondecode(char(txt));
            catch
                return;
            end
            R = curation.ProjectIndex.emptyColumns(1);
            cols = curation.Store.COLUMNS;
            types = curation.Store.TYPES;
            for k = 1:numel(cols)
                nm = char(cols(k));
                if ~isfield(s, nm), continue; end
                v = s.(nm);
                switch types(k)
                    case "double"
                        if ischar(v) || isstring(v), v = str2double(v); end
                        if isempty(v), v = NaN; end
                        R.(nm) = double(v);
                    case "uint32"
                        if isempty(v), v = 0; end
                        R.(nm) = uint32(v);
                    case "logical"
                        if isempty(v), v = false; end
                        R.(nm) = logical(v);
                    otherwise
                        if isempty(v), v = ""; end
                        R.(nm) = string(v);
                end
            end
        end

        function [prior, priorP] = priorLabels(T, journal)
            % Label (and ProposalP) before the blind re-label of confirm-audit rows (class help).
            n = height(T);
            prior = strings(n, 1);
            priorP = nan(n, 1);
            q = find(T.AuditRole == "confirm-audit" & T.LabelSource == "blind" & T.Reviewed);
            if isempty(q) || ~isfile(journal), return; end
            R = curation.Journal.read(journal, 0);
            if isempty(R.Revision), return; end
            id = str2double(R.CellID);
            for r = q'
                cid = double(T.CellID(r));
                b = find(id == cid & R.Field == "LabelSource" & R.New == "blind", 1, 'last');
                if isempty(b)
                    continue;
                end
                sameTxn = id == cid & R.RevisionNum == R.RevisionNum(b);
                l = find(sameTxn & R.Field == "Label", 1, 'last');
                if isempty(l)
                    prior(r) = T.Label(r);           % the blind label did not change it
                else
                    prior(r) = R.Old(l);
                end
                pl = find(sameTxn & R.Field == "ProposalP", 1, 'last');
                if isempty(pl)
                    priorP(r) = T.ProposalP(r);      % the blind label did not overwrite it
                else
                    priorP(r) = double(curation.Journal.decode(R.Old(pl), "double"));
                end
            end
        end

        function checkThread(readImages)
            %CHECKTHREAD  Reading TIFF files on a thread worker is an error, not a silent gap.
            if ~readImages || ~curation.ProjectIndex.onThreadWorker(), return; end
            error('curation:ProjectIndex:imagesOnThread', ['curation.ProjectIndex reads TIFF images ' ...
                '(features, pixel size), which a thread worker (backgroundPool) cannot do. Build or ' ...
                'refresh it there with struct(''ReadImages'', false) (see BACKGROUND in its help), or ' ...
                'in MATLAB''s own thread.']);
        end

        function tf = onThreadWorker()
            tf = false;
            try
                tf = parallel.internal.pool.isPoolThreadWorker();
            catch
            end
        end

        function fp = fingerprint(T, img, page, cpage, um)
            d = dir(img);
            fp = curation.Hash.of(double(T.CellID), T.X, T.Y, T.score, T.rescore, logical(T.InLocs), ...
                lower(string(img)), d.bytes, d.datenum, page, cpage, um, curation.Features.VERSION);
        end
    end
end

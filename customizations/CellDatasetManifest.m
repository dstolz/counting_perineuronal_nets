classdef CellDatasetManifest < handle
% CELLDATASETMANIFEST  Authoritative per-dataset manifest for the Cell* tools.
%   A "dataset" is one source image (a TIFF, possibly multi-page) together with
%   every file the Cell* tools derive from it. This class is the single source
%   of truth for *which* files belong to a dataset and, in particular, *which
%   localization CSV is the one used for analysis* (the "active locs" pointer).
%
%   Every Cell* GUI resolves the files it reads/writes THROUGH this class
%   instead of re-deriving them by naming convention. Naming conventions
%   (CellToolkit.inferImagePath, pageFromCsvName, ...) are used only to
%   *bootstrap* a manifest the first time, after which the recorded paths win.
%
%   One instance == one dataset. The on-disk form is a sidecar JSON next to the
%   image, "<base>.celldataset.json", schema "celldataset/2.0".
%
%   The base of a dataset
%   ---------------------
%   CellDiscovery names what it writes after the image it read, suffix included
%   ("<x>_proj.tif" -> "<x>_proj_ECM1_locs.csv"), so the base of a dataset is
%   the stem its localization files start with: forCsv is the authority. An
%   image whose name ends in a role suffix (_proj, _resized, _preprocessed) is
%   therefore settled by the same three rules in forImage and in discover:
%     1. localization files named after the image exist -> it is THE image of
%        the dataset with its own name as base ("<x>_proj");
%     2. else the name without the suffix has an image of its own or
%        localization files -> it is that dataset's companion (base "<x>");
%     3. else a projection alone is a dataset of its own ("<x>_proj"), so its
%        base does not change when detections are added; a resized image alone
%        stays with the base without the suffix.
%   Until 2026-11-24 rule 2 was the only one: a section stored as "<x>_proj.tif"
%   beside "<x>_proj_ECM1_locs.csv" was listed twice (bases "<x>" and
%   "<x>_proj"), and CellDiscovery recorded its detection in "<x>" where no
%   reader looked. discover adopts what such a stray manifest recorded
%   (adoptStrayFacts).
%
%   Factories
%   ---------
%       mf = CellDatasetManifest.forImage(imagePath);   % by image
%       mf = CellDatasetManifest.forCsv(csvPath);       % by a locs/QC CSV
%       mf = CellDatasetManifest.forBase(folder, base); % by folder + base stem
%       arr = CellDatasetManifest.discover(parentDir);  % every dataset below
%
%   Authoritative queries (use these for ALL file operations)
%   ---------------------------------------------------------
%       img  = mf.imagePath();             % analyzed TIFF
%       np   = mf.pageCount();
%       pgs  = mf.analyzedPages();
%       keys = mf.sourceKeys();
%       csv  = mf.activeLocs(key);         % THE analysis CSV for a source
%       rcsv = mf.locsPath(key, 'resized');
%       qc   = mf.qcPath(key);
%       [ch, pg] = mf.channelPage(key);
%
%   Recording (called by the GUIs right after they save)
%   ----------------------------------------------------
%       mf.recordDetection(key, struct('image',img,'page',pg,'locs',csv, ...
%                                      'tool','CellDiscovery','model',m,'count',n));
%       mf.recordResized(key, resizedCsv, resizedTif);
%       mf.recordRescore(key, struct('tool','CellDiscovery','model',m));
%       mf.recordCuration(key, curationCsv, counts);
%       % recordResolve / recordQc: no caller since the legacy Neighbor Resolver
%       % and QC apps were removed; their stages are still derived from old files.
%       mf.recordResolve(key, struct('tool','CellNeighborResolution'));
%       mf.recordQc(key, qcPath, struct('reviewed',r,'good',g,'bad',b,'uncertain',u));
%       mf.setActiveLocs(key, csvPath, 'resized');   % user re-points the active file
%       mf.save();
%
%   The "<channel><page>" stream within a dataset is a "source"; a two-page
%   PNN/PV TIFF yields two sources (e.g. PNN1, PV2) under one dataset, each with
%   its own active locs file. Every write is best-effort/guarded so a manifest
%   problem can never break a GUI save.

    %% ===================================================================
    %  Constants
    %  ===================================================================
    properties (Constant)
        MANIFEST_EXT  = '.celldataset.json'
        SCHEMA        = 'celldataset/2.0'
        IMAGE_EXTS    = {'.tif', '.tiff'}
        STAGES        = {'detection', 'resized', 'resolve', 'rescore', 'qc', 'curation'}
        CURATION_EXT  = '.curation.json'   % dataset-level curation sidecar (curation.Store)
        % Scale-bar fallback when a TIFF carries no physical resolution tag.
        DEFAULT_UM_PER_PIXEL = 0.645
        % Filename suffix that marks a localization CSV. User-configurable via
        % the CellDatasetManager dashboard (persisted) so other naming
        % conventions can be scanned. See locsToken().
        DEFAULT_LOCS_TOKEN = '_locs'
    end

    %% ===================================================================
    %  Instance state (one dataset)
    %  ===================================================================
    properties
        Folder char = ''        % directory holding the image + sidecars
        Base   char = ''        % dataset base stem (image name without suffix)
        ManifestPath char = ''  % absolute path of the sidecar JSON
        Data struct = struct()  % in-memory schema-2.0 manifest
    end

    properties (Access = private, Transient)
        % Source-status array computed by the last reconcileFromDisk, reused by
        % toDatasetStruct so a scan probes each dataset's files only once.
        LastStatus = []
    end

    %% ===================================================================
    %  Construction / factories
    %  ===================================================================
    methods
        function obj = CellDatasetManifest(folder, base)
            % Build (or load) the manifest for the dataset at folder/base.
            if nargin == 0
                obj.Data = CellDatasetManifest.emptyData();
                return;
            end
            obj.Folder = char(folder);
            obj.Base   = char(base);
            obj.ManifestPath = CellDatasetManifest.pathFor(obj.Folder, obj.Base);
            obj.Data = CellDatasetManifest.readManifestFile(obj.ManifestPath);
            obj.Data.datasetBase = obj.Base;
        end
    end

    methods (Static)

        function mf = forBase(folder, base)
            % Manifest for a dataset identified by its folder and base stem.
            mf = CellDatasetManifest(folder, base);
        end

        function mf = forImage(imagePath)
            % Manifest for the dataset a (possibly suffixed) image belongs to.
            imagePath = char(imagePath);
            [folder, name, ~] = fileparts(imagePath);
            base = CellDatasetManifest.baseForImage(folder, name);
            mf = CellDatasetManifest(folder, base);
            % Seed the image filename when this is the raw/representative image
            % and none is recorded yet.
            if isempty(mf.Data.image.file) && isfile(imagePath)
                mf.Data.image.file = CellDatasetManifest.relName(imagePath, folder);
            end
        end

        function mf = forCsv(csvPath)
            % Manifest for the dataset a localization/QC CSV belongs to, with
            % its (channel,page) source ensured to exist.
            csvPath = char(csvPath);
            [folder, name, ext] = fileparts(csvPath);
            info = CellDatasetManifest.classifyFile(folder, name, lower(ext));
            if isempty(info)
                % Fall back to a tolerant stem stripper for non-standard names.
                tokPat = regexptranslate('escape', CellDatasetManifest.locsToken());
                base = regexprep(name, [tokPat '(_resized)?(_QC)?$'], '', 'ignorecase');
                base = regexprep(base, '_[A-Za-z_]+\d+$', '');
                info = struct('base', base, 'channel', '', 'page', NaN, ...
                    'resized', false, 'kind', 'locs');
            end
            mf = CellDatasetManifest(folder, info.base);
            key = CellDatasetManifest.sourceKey(info.channel, info.page);
            mf.ensureSource(key, info.channel, info.page);
        end

        function key = keyForCsv(csvPath)
            % Source key ('<channel><page>' or 'default') for a localization
            % CSV, following the Cell* naming convention. Shared by the GUIs so
            % they record/resolve against the same source the dashboard shows.
            [folder, name, ext] = fileparts(char(csvPath));
            info = CellDatasetManifest.classifyFile(folder, name, lower(ext));
            if isempty(info)
                key = 'default';
            else
                key = CellDatasetManifest.sourceKey(info.channel, info.page);
            end
        end

        function arr = discover(parentDir, opts)
            % Every dataset under parentDir as a CellDatasetManifest array.
            % Reconciles each manifest from disk and (by default) saves it.
            %
            %   opts (optional struct):
            %     .WriteManifest (default true)  rewrite reconciled manifests
            %     .Probe         (default true)  read CSV/QC contents for counts
            %     .LocsToken     (default locsToken())  localization-CSV suffix
            arguments
                parentDir
                opts struct = struct()
            end
            opts = CellDatasetManifest.fillOpts(opts);
            arr = CellDatasetManifest.empty(0, 1);

            parentDir = char(parentDir);
            if isempty(parentDir) || ~isfolder(parentDir)
                return;
            end
            allFiles = CellToolkit.recDir(parentDir);
            if isempty(allFiles)
                return;
            end

            % Group files by (folder, base).
            groups = containers.Map('KeyType', 'char', 'ValueType', 'any');
            for k = 1:numel(allFiles)
                f = allFiles{k};
                [folder, name, ext] = fileparts(f);
                info = CellDatasetManifest.classifyFile(folder, name, lower(ext), opts.LocsToken);
                if isempty(info)
                    continue;
                end
                gkey = lower(fullfile(folder, info.base));
                if isKey(groups, gkey)
                    g = groups(gkey);
                else
                    g = struct('folder', folder, 'base', info.base, 'files', {{}});
                end
                g.files{end+1} = struct('full', f, 'info', info);
                groups(gkey) = g;
            end

            groups = CellDatasetManifest.settleImages(groups);

            keys = groups.keys;
            nKeys = numel(keys);
            built = {};
            for k = 1:nKeys
                g = groups(keys{k});
                % Optional progress callback (k, total, datasetBase). Called
                % before each dataset's reconcile (the slow per-dataset step).
                % It is NOT guarded, so a caller can throw from it to cancel.
                if ~isempty(opts.Progress)
                    opts.Progress(k, nKeys, g.base);
                end
                mf = CellDatasetManifest(g.folder, g.base);
                mf.seedFromGroup(g);
                mf.adoptStrayFacts();
                mf.reconcileFromDisk(opts);
                if opts.WriteManifest
                    mf.save();
                end
                built{end+1} = mf; %#ok<AGROW>
            end
            if isempty(built)
                return;
            end
            arr = [built{:}];
            arr = arr(:);
            % Stable order by base for predictable display.
            [~, ord] = sort(lower(arrayfun(@(m) string(m.Base), arr)));
            arr = arr(ord);
        end

        function T = statusTable(parentDir, opts)
            % One-row-per-dataset summary table (handy for printing/reporting).
            arguments
                parentDir
                opts struct = struct()
            end
            mfs = CellDatasetManifest.discover(parentDir, opts);
            n = numel(mfs);
            DatasetID = strings(n, 1); Folder = strings(n, 1);
            Pages = zeros(n, 1);  Sources = zeros(n, 1);
            Detections = zeros(n, 1);
            Detected = strings(n, 1); Resolved = strings(n, 1);
            Rescored = strings(n, 1); Reviewed = strings(n, 1);
            Curated = strings(n, 1);
            Status = strings(n, 1);
            for k = 1:n
                d = mfs(k).toDatasetStruct(parentDir);
                DatasetID(k) = string(d.DatasetID);
                Folder(k)    = string(d.Folder);
                Pages(k)     = d.PageCount;
                Sources(k)   = numel(d.Sources);
                Detections(k)= d.TotalDetections;
                Detected(k)  = CellDatasetManifest.frac(d.Sources, 'Detected');
                Resolved(k)  = CellDatasetManifest.frac(d.Sources, 'Resolved');
                Rescored(k)  = CellDatasetManifest.frac(d.Sources, 'Rescored');
                Reviewed(k)  = CellDatasetManifest.frac(d.Sources, 'Reviewed');
                Curated(k)   = CellDatasetManifest.frac(d.Sources, 'CurComplete');
                Status(k)    = string(d.Status);
            end
            T = table(DatasetID, Folder, Pages, Sources, Detections, ...
                Detected, Resolved, Rescored, Reviewed, Curated, Status);
        end

        function tok = locsToken()
            % Configured localization-CSV suffix, shared across the Cell* GUIs
            % (persisted by the dashboard under the legacy 'CellDatasetManager'
            % pref group). Falls back to DEFAULT_LOCS_TOKEN when unset/blank.
            tok = CellDatasetManifest.DEFAULT_LOCS_TOKEN;
            try
                if ispref('CellDatasetManager', 'locsToken')
                    v = strtrim(char(getpref('CellDatasetManager', 'locsToken')));
                    if ~isempty(v)
                        tok = v;
                    end
                end
            catch
            end
        end

        function p = pathFor(folder, base)
            % Sidecar manifest path for a dataset identified by folder + base.
            p = fullfile(char(folder), [char(base), CellDatasetManifest.MANIFEST_EXT]);
        end
    end

    %% ===================================================================
    %  Authoritative file resolution
    %  ===================================================================
    methods

        function p = imagePath(obj)
            % The dataset's representative image. Trusts the recorded image when
            % it exists; otherwise finds one by convention and reconciles it in.
            p = obj.absPath(obj.Data.image.file);
            if ~isempty(p) && isfile(p)
                return;
            end
            p = CellDatasetManifest.findImageForBase(obj.Folder, obj.Base);
            if ~isempty(p)
                obj.Data.image.file = obj.relName(p, obj.Folder);
            end
        end

        function img = activeImage(obj)
            % The explicitly selected analysis image for this dataset. Falls
            % back to imagePath() when no active image has been set.
            img = obj.absPath(CellDatasetManifest.fieldChar(obj.Data.image, 'activeImage'));
            if isempty(img) || ~isfile(img)
                img = obj.imagePath();
            end
        end

        function setActiveImage(obj, imgPath)
            % Explicitly set which image file is the active analysis image for
            % this dataset (the user-facing override, driven from the
            % CellDatasetManager dashboard).
            imgPath = char(imgPath);
            obj.Data.image.activeImage = obj.relName(imgPath, obj.Folder);
        end

        function n = pageCount(obj)
            % Page count, computing it from the image (one imfinfo) and caching
            % it when not already recorded.
            n = obj.storedPageCount();
            if n <= 0
                img = obj.imagePath();
                if ~isempty(img) && isfile(img)
                    n = CellToolkit.countPages(img);
                    obj.Data.image.pageCount = n;
                end
            end
        end

        function n = storedPageCount(obj)
            % Page count recorded in the manifest, or 0 when unknown. Never
            % touches the image, so it is safe to call on every projection.
            n = 0;
            if isfield(obj.Data, 'image') && isfield(obj.Data.image, 'pageCount') ...
                    && ~isempty(obj.Data.image.pageCount)
                n = double(obj.Data.image.pageCount);
                if isnan(n), n = 0; end
            end
        end

        function pgs = analyzedPages(obj)
            % Pages that have been analyzed (a detection recorded). Self-heals
            % from the detected sources when the stored list is empty.
            pgs = [];
            if isfield(obj.Data.image, 'analyzedPages')
                pgs = obj.Data.image.analyzedPages(:)';
            end
            pgs = pgs(isfinite(pgs));
        end

        function keys = sourceKeys(obj)
            if isstruct(obj.Data.sources)
                keys = fieldnames(obj.Data.sources)';
            else
                keys = {};
            end
        end

        function tf = hasSource(obj, key)
            tf = isstruct(obj.Data.sources) && isfield(obj.Data.sources, key);
        end

        function s = source(obj, key)
            % Raw source sub-struct (empty when absent).
            s = [];
            if obj.hasSource(key)
                s = obj.Data.sources.(key);
            end
        end

        function [channel, page] = channelPage(obj, key)
            channel = ''; page = NaN;
            s = obj.source(key);
            if isempty(s), return; end
            if isfield(s, 'channel'), channel = char(s.channel); end
            if isfield(s, 'page') && ~isempty(s.page)
                page = double(s.page);
            end
        end

        function csv = activeLocs(obj, key)
            % THE localization CSV used for analysis of this source. Trusts the
            % recorded activeLocs when it exists, else the recorded plain locs,
            % else the conventional "<base>[_key]_locs.csv", reconciling the
            % resolved choice back into the manifest.
            csv = '';
            s = obj.source(key);
            if ~isempty(s)
                for f = {'activeLocs', 'locs'}
                    cand = obj.absPath(CellDatasetManifest.fieldChar(s, f{1}));
                    if ~isempty(cand) && isfile(cand)
                        csv = cand; break;
                    end
                end
            end
            if isempty(csv)
                csv = obj.conventionalLocs(key, false);
            end
            if ~isempty(csv) && obj.hasSource(key)
                obj.Data.sources.(key).activeLocs = obj.relName(csv, obj.Folder);
            end
        end

        function csv = locsPath(obj, key, space)
            % Localization CSV in a given coordinate space:
            %   'full'    -> the active (full-resolution) detections CSV
            %   'resized' -> the resized-image-space CSV ("*_locs_resized.csv")
            if nargin < 3 || isempty(space), space = 'full'; end
            if strcmpi(space, 'resized')
                csv = '';
                s = obj.source(key);
                if ~isempty(s)
                    cand = obj.absPath(CellDatasetManifest.fieldChar(s, 'locsResized'));
                    if ~isempty(cand) && isfile(cand)
                        csv = cand;
                    end
                end
                if isempty(csv)
                    csv = obj.conventionalLocs(key, true);
                end
            else
                csv = obj.activeLocs(key);
            end
        end

        function qc = qcPath(obj, key)
            % QC review file for this source. Trusts the recorded qc path, else
            % derives it from the active locs basename ("<locs>_QC.csv").
            qc = '';
            s = obj.source(key);
            if ~isempty(s)
                cand = obj.absPath(CellDatasetManifest.fieldChar(s, 'qc'));
                if ~isempty(cand)
                    qc = cand;
                end
            end
            if isempty(qc)
                csv = obj.activeLocs(key);
                if ~isempty(csv)
                    [folder, name, ~] = fileparts(csv);
                    qc = fullfile(folder, [name '_QC.csv']);
                end
            end
        end

        function p = curationJsonPath(obj)
            % Dataset-level curation sidecar written by curation.Store
            % ("<base>.curation.json"; shared by every source of the dataset).
            p = fullfile(obj.Folder, [obj.Base CellDatasetManifest.CURATION_EXT]);
        end

        function p = curationPath(obj, key)
            % Curation store snapshot ("<stem>_curation.csv") of a source, where
            % <stem> is the DETECTOR locs name without its locs token. Trusts the
            % recorded path, then the stem the store wrote into the curation
            % JSON, then the naming convention. The file need not exist yet.
            p = '';
            s = obj.source(key);
            if ~isempty(s)
                p = obj.absPath(CellDatasetManifest.fieldChar(s, 'curation'));
            end
            if ~isempty(p), return; end
            cj = CellDatasetManifest.readCurationJson(obj.curationJsonPath(), true);
            rec = CellDatasetManifest.curationRecord(cj, key);
            p = obj.curationCsvFor(key, CellDatasetManifest.fieldChar(rec, 'stem'));
        end

        function p = curationCsvFor(obj, key, stem)
            % "<folder of the detector locs>/<stem>_curation.csv". The store
            % writes its snapshot beside the locs file it curates, which need
            % not be the dataset folder. STEM comes from the curation JSON when
            % known, else from the locs name without its locs token. '' when the
            % source has no locs file to anchor on.
            p = '';
            csv = '';
            s = obj.source(key);
            if ~isempty(s)
                csv = obj.absPath(CellDatasetManifest.fieldChar(s, 'locs'));
            end
            if isempty(csv), csv = obj.activeLocs(key); end
            folder = obj.Folder;
            if ~isempty(csv)
                [locsFolder, name] = fileparts(csv);
                if ~isempty(locsFolder), folder = locsFolder; end
                if isempty(stem)
                    tok = regexptranslate('escape', CellDatasetManifest.locsToken());
                    stem = regexprep(name, [tok '(_resized)?$'], '', 'ignorecase');
                end
            end
            if isempty(stem), return; end
            p = fullfile(folder, [stem '_curation.csv']);
        end

        function sp = coordSpace(obj, key)
            % Coordinate space of the active locs: 'full' or 'resized'.
            sp = 'full';
            s = obj.source(key);
            if ~isempty(s) && isfield(s, 'coordSpace') && ~isempty(s.coordSpace)
                sp = char(s.coordSpace);
            end
        end

        function img = imageForLocs(obj, csvPath)
            % The companion image whose coordinate space matches a given
            % localization CSV: the resized image for a "*_locs_resized.csv",
            % otherwise the full-resolution image (raw, then projection). Used by
            % the resolver/QC so overlays land in the CSV's own pixel space.
            % Returns '' when nothing suitable is on disk.
            if ~isempty(regexpi(char(csvPath), '_resized\.csv$', 'once'))
                img = obj.absPath(CellDatasetManifest.fieldChar(obj.Data.image, 'resized'));
                if isempty(img) || ~isfile(img)
                    img = CellDatasetManifest.findCompanion(obj.Folder, obj.Base, '_resized');
                end
            else
                img = CellDatasetManifest.findCompanion(obj.Folder, obj.Base, '');
                if isempty(img)
                    img = CellDatasetManifest.findCompanion(obj.Folder, obj.Base, '_proj');
                end
                if isempty(img)
                    img = obj.imagePath();
                end
            end
            if isempty(img) || ~isfile(img)
                img = '';
            end
        end
    end

    %% ===================================================================
    %  Recording / mutation
    %  ===================================================================
    methods

        function ensureSource(obj, key, channel, page)
            % Make sure a (channel,page) source entry exists. When channel/page
            % are not supplied they are parsed from the key.
            if ~isstruct(obj.Data.sources)
                obj.Data.sources = struct();
            end
            if isfield(obj.Data.sources, key)
                return;
            end
            if nargin < 4
                [kch, kpg] = CellDatasetManifest.splitKey(key);
                if nargin < 3 || isempty(channel), channel = kch; end
                page = kpg;
            end
            obj.Data.sources.(key) = CellDatasetManifest.emptySource(channel, page);
        end

        function recordDetection(obj, key, info)
            % Record a detection: seed the image, page, plain locs + active
            % pointer, and the detection stage provenance/count.
            %   info fields (all optional): image, page, locs, tool, model, count,
            %   and the preprocessing the detector input went through: resize,
            %   resizeMode, srcUmPerPixel, bgRadius, correctLSM, lsmPages,
            %   lsmOptions, normalized, normPercentiles, normTarget, normLimits
            %   (CellToolkit's "Model input" facts: enough to regenerate it)
            if nargin < 3 || ~isstruct(info), info = struct(); end
            [channel, page] = CellDatasetManifest.splitKey(key);
            if CellDatasetManifest.has(info, 'page'), page = double(info.page); end
            obj.ensureSource(key, channel, page);
            s = obj.Data.sources.(key);

            if CellDatasetManifest.has(info, 'image') && isfile(char(info.image))
                obj.Data.image.file = obj.relName(char(info.image), obj.Folder);
                obj.Data.image.pageCount = CellToolkit.countPages(char(info.image));
                obj.Data.image.umPerPixel = CellDatasetManifest.pixelSizeUm(char(info.image));
            end
            if ~isempty(page) && ~isnan(page)
                obj.addAnalyzedPage(page);
            end
            if CellDatasetManifest.has(info, 'locs')
                rel = obj.relName(char(info.locs), obj.Folder);
                s.locs = rel;
                if isempty(s.activeLocs)
                    s.activeLocs = rel;
                    s.coordSpace = 'full';
                end
            end
            obj.Data.sources.(key) = s;

            facts = CellDatasetManifest.pickFacts(info, {'tool', 'model', 'count', ...
                'resize', 'resizeMode', 'srcUmPerPixel', 'bgRadius', 'correctLSM', 'lsmPages', ...
                'lsmOptions', 'normalized', 'normPercentiles', 'normTarget', 'normLimits'});
            obj.markStage(key, 'detection', facts);
        end

        function recordResized(obj, key, resizedCsv, resizedTif)
            % Record the resized-coordinate companion CSV (and resized TIFF).
            if nargin < 3, resizedCsv = ''; end
            if nargin < 4, resizedTif = ''; end
            obj.ensureSource(key);
            s = obj.Data.sources.(key);
            if ~isempty(resizedCsv)
                s.locsResized = obj.relName(char(resizedCsv), obj.Folder);
            end
            obj.Data.sources.(key) = s;
            if ~isempty(resizedTif) && isfile(char(resizedTif))
                obj.Data.image.resized = obj.relName(char(resizedTif), obj.Folder);
            end
            obj.markStage(key, 'resized', struct());
        end

        function recordResolve(obj, key, info)
            % Record neighbor-resolution provenance for a source.
            if nargin < 3 || ~isstruct(info), info = struct(); end
            obj.ensureSource(key);
            obj.markStage(key, 'resolve', CellDatasetManifest.pickFacts(info, {'tool'}));
        end

        function recordRescore(obj, key, info)
            % Record Stage-2 rescoring provenance for a source.
            if nargin < 3 || ~isstruct(info), info = struct(); end
            obj.ensureSource(key);
            obj.markStage(key, 'rescore', CellDatasetManifest.pickFacts(info, {'tool', 'model'}));
        end

        function recordQc(obj, key, qcPath, counts)
            % Record a QC review (path + Reviewed/Good/Bad/Uncertain counts).
            if nargin < 4 || ~isstruct(counts), counts = struct(); end
            obj.ensureSource(key);
            s = obj.Data.sources.(key);
            if nargin >= 3 && ~isempty(qcPath)
                s.qc = obj.relName(char(qcPath), obj.Folder);
            end
            obj.Data.sources.(key) = s;
            facts = CellDatasetManifest.pickFacts(counts, ...
                {'reviewed', 'good', 'bad', 'uncertain', 'tool'});
            obj.markStage(key, 'qc', facts);
        end

        function recordCuration(obj, key, curationCsv, counts)
            % Record a CellCurator session: the curation store path and its
            % counts (curation.Store.counts() plus 'complete' and 'tool').
            if nargin < 4 || ~isstruct(counts), counts = struct(); end
            obj.ensureSource(key);
            s = obj.Data.sources.(key);
            if nargin >= 3 && ~isempty(curationCsv)
                s.curation = obj.relName(char(curationCsv), obj.Folder);
            end
            obj.Data.sources.(key) = s;
            facts = CellDatasetManifest.pickFacts(counts, {'reviewed', ...
                'good', 'bad', 'uncertain', 'kept', 'autoRejected', 'complete', 'tool'});
            % 'total' means ACTIVE candidates (merged duplicates and stale rows
            % are not cells), the same number reconcileFromDisk derives from the
            % curation JSON, so the two writers of this stage never disagree.
            if isfield(counts, 'active') && ~isempty(counts.active)
                facts.total = counts.active;
            elseif isfield(counts, 'total') && ~isempty(counts.total)
                facts.total = counts.total;
            end
            obj.markStage(key, 'curation', facts);
        end

        function setActiveLocs(obj, key, csvPath, coordSpace)
            % Explicitly re-point which localization CSV is "the one used for
            % analysis" for a source (the user-facing override, driven from the
            % CellDatasetManager dashboard). coordSpace is inferred from the
            % filename when not supplied.
            csvPath = char(csvPath);
            if nargin < 4 || isempty(coordSpace)
                if ~isempty(regexpi(csvPath, '_resized\.csv$', 'once'))
                    coordSpace = 'resized';
                else
                    coordSpace = 'full';
                end
            end
            [channel, page] = CellDatasetManifest.splitKey(key);
            obj.ensureSource(key, channel, page);
            s = obj.Data.sources.(key);
            s.activeLocs = obj.relName(csvPath, obj.Folder);
            s.coordSpace = char(coordSpace);
            obj.Data.sources.(key) = s;
        end

        function markStage(obj, key, stage, facts)
            % Set a stage's done flag + freshly measured facts, keeping any
            % existing first-seen timestamp.
            if nargin < 4 || ~isstruct(facts), facts = struct(); end
            stage = CellDatasetManifest.validStage(stage);
            obj.ensureSource(key);
            s = obj.Data.sources.(key);
            if ~isfield(s, 'stages') || ~isstruct(s.stages)
                s.stages = struct();
            end
            st = CellDatasetManifest.stageStruct(s, stage);
            wasDone = isfield(st, 'done') && isequal(st.done, true);
            st.done = true;
            if ~wasDone || ~isfield(st, 'time') || isempty(st.time)
                st.time = CellDatasetManifest.nowIso();
            end
            fn = fieldnames(facts);
            for i = 1:numel(fn)
                st.(fn{i}) = facts.(fn{i});
            end
            s.stages.(stage) = st;
            obj.Data.sources.(key) = s;
        end

        function n = adoptStrayFacts(obj)
            % Take over what a stray manifest recorded for this dataset's
            % sources. Until 2026-11-24 CellDiscovery recorded a detection of
            % "<x>_proj.tif" in "<x>.celldataset.json" (forImage dropped the
            % suffix), while every reader asks for the manifest of the locs
            % file, "<x>_proj.celldataset.json": the tool, the model and the
            % model-input facts (resize, background radius, normalization, ...)
            % were recorded where nothing read them. For each source of this
            % dataset that the stray manifest lists WITH THE SAME locs file,
            % the detection, resized and rescore stages it recorded (a stage
            % with a tool, or model-input facts) are copied when this manifest
            % has none recorded. The stray file is left as it is. Returns the
            % number of stages adopted; never throws.
            n = 0;
            try
                if isempty(regexpi(obj.Base, '_proj$', 'once')) || ~isstruct(obj.Data.sources)
                    return;
                end
                strayPath = CellDatasetManifest.pathFor(obj.Folder, ...
                    regexprep(obj.Base, '_proj$', '', 'ignorecase'));
                if ~isfile(strayPath)
                    return;
                end
                stray = CellDatasetManifest.readManifestFile(strayPath);
                if ~isstruct(stray.sources)
                    return;
                end
                keys = fieldnames(obj.Data.sources);
                for i = 1:numel(keys)
                    key = keys{i};
                    if ~isfield(stray.sources, key) || ~isstruct(stray.sources.(key))
                        continue;
                    end
                    theirs = stray.sources.(key);
                    mine   = obj.Data.sources.(key);
                    if isempty(CellDatasetManifest.fieldChar(mine, 'locs')) || ~strcmpi( ...
                            CellDatasetManifest.fieldChar(theirs, 'locs'), ...
                            CellDatasetManifest.fieldChar(mine, 'locs'))
                        continue;   % not the same file: nothing to say about it
                    end
                    for stage = {'detection', 'resized', 'rescore'}
                        st = CellDatasetManifest.stageStruct(theirs, stage{1});
                        if CellDatasetManifest.isRecordedStage(st) && ...
                                ~CellDatasetManifest.isRecordedStage( ...
                                CellDatasetManifest.stageStruct(mine, stage{1}))
                            if ~isfield(mine, 'stages') || ~isstruct(mine.stages)
                                mine.stages = struct();
                            end
                            mine.stages.(stage{1}) = st;
                            n = n + 1;
                        end
                    end
                    if isempty(CellDatasetManifest.fieldChar(mine, 'locsResized'))
                        mine.locsResized = CellDatasetManifest.fieldChar(theirs, 'locsResized');
                    end
                    obj.Data.sources.(key) = mine;
                end
            catch
            end
        end

        function ok = save(obj)
            % Persist the in-memory manifest to its sidecar JSON. Never throws;
            % returns whether the write succeeded.
            ok = false;
            if isempty(obj.ManifestPath)
                obj.ManifestPath = CellDatasetManifest.pathFor(obj.Folder, obj.Base);
            end
            obj.Data.schema      = CellDatasetManifest.SCHEMA;
            obj.Data.datasetBase = obj.Base;
            try
                ok = CellDatasetManifest.writeManifestFile(obj.ManifestPath, obj.Data);
            catch
            end
        end
    end

    %% ===================================================================
    %  Reconciliation + legacy dataset-struct projection
    %  ===================================================================
    methods

        function reconcileFromDisk(obj, opts)
            % Recompute derivable facts (existence, counts, column presence, QC
            % counts, page count, analyzed pages) from the files in a SINGLE
            % probe pass, preserving provenance (tool/model/time) already
            % recorded. The probed status is cached on the object so a following
            % toDatasetStruct does not re-read the same files.
            if nargin < 2, opts = CellDatasetManifest.fillOpts(struct()); end
            rep = obj.imagePath();
            if ~isempty(rep) && isfile(rep)
                % Page count is read once (imfinfo is the costly call) and then
                % trusted on later scans; the scale (umPerPixel) is only needed
                % by the preview, which computes it itself, so it is not probed
                % here.
                if obj.storedPageCount() <= 0 && opts.Probe
                    obj.Data.image.pageCount = CellToolkit.countPages(rep);
                end
                obj.Data.image.proj    = obj.relName( ...
                    CellDatasetManifest.findCompanion(obj.Folder, obj.Base, '_proj'), obj.Folder);
                obj.Data.image.resized = obj.relName( ...
                    CellDatasetManifest.findCompanion(obj.Folder, obj.Base, '_resized'), obj.Folder);
            end

            sources = obj.buildSourceStatus(opts);
            obj.LastStatus = sources;

            pages = [];
            for i = 1:numel(sources)
                s = sources(i);
                key = s.Key;
                detFacts = struct();
                if s.Detected, detFacts.count = s.NumDetections; end
                obj.markStageDerived(key, 'detection', s.Detected, detFacts);
                obj.markStageDerived(key, 'resized',  s.HasResized, struct());
                obj.markStageDerived(key, 'resolve',  s.Resolved, struct());
                obj.markStageDerived(key, 'rescore',  s.Rescored, struct());
                obj.markStageDerived(key, 'qc', s.Reviewed, struct( ...
                    'reviewed', s.QcReviewed, 'good', s.QcGood, ...
                    'bad', s.QcBad, 'uncertain', s.QcUncertain));
                if s.CurFound
                    obj.markStageDerived(key, 'curation', s.Curated, struct( ...
                        'total', s.CurTotal, 'reviewed', s.CurReviewed, ...
                        'good', s.CurGood, 'bad', s.CurBad, ...
                        'uncertain', s.CurUncertain, 'kept', s.CurKept, ...
                        'complete', s.CurComplete));
                end
                % No curation record found (never curated, or the sidecar is
                % missing or unreadable right now): leave whatever was recorded
                % untouched rather than zeroing a real curation's facts.
                if s.Detected && ~isnan(s.Page)
                    pages(end+1) = s.Page; %#ok<AGROW>
                end
            end
            obj.Data.image.analyzedPages = unique(pages);
        end

        function d = toDatasetStruct(obj, parentDir)
            % Project this manifest onto the legacy dataset struct the
            % CellDatasetManager dashboard consumes. Reuses the status cached by
            % reconcileFromDisk (set during discover) to avoid re-probing. The
            % handle itself is attached as .ManifestObj so the dashboard can
            % edit the active pointer.
            if nargin < 2, parentDir = obj.Folder; end
            rep     = obj.imagePath();
            raw     = CellDatasetManifest.findCompanion(obj.Folder, obj.Base, '');
            if isempty(obj.LastStatus)
                % Not reconciled this scan: resolve companions directly.
                proj    = CellDatasetManifest.findCompanion(obj.Folder, obj.Base, '_proj');
                resized = CellDatasetManifest.findCompanion(obj.Folder, obj.Base, '_resized');
                sources = obj.buildSourceStatus();
            else
                % Trust the values reconcileFromDisk already resolved/probed.
                proj    = obj.absPath(CellDatasetManifest.fieldChar(obj.Data.image, 'proj'));
                resized = obj.absPath(CellDatasetManifest.fieldChar(obj.Data.image, 'resized'));
                sources = obj.LastStatus;
            end
            if isempty(rep)
                for cand = {raw, proj, resized}
                    if ~isempty(cand{1}), rep = cand{1}; break; end
                end
            end

            d = struct();
            d.Base         = obj.Base;
            d.Folder       = obj.Folder;
            anchor = CellToolkit.ternary(isempty(rep), fullfile(obj.Folder, obj.Base), rep);
            d.DatasetID    = CellToolkit.makeRelativePath(anchor, parentDir);
            d.ImagePath    = rep;
            d.ActiveImage  = obj.activeImage();
            d.RawImage     = raw;
            d.ProjImage    = proj;
            d.PreprocImage = resized;
            d.ManifestPath = obj.ManifestPath;
            d.PageCount    = obj.storedPageCount();
            d.Sources      = sources;
            if isempty(sources)
                d.TotalDetections = 0;
            else
                d.TotalDetections = sum([sources.NumDetections]);
            end
            d.Status       = CellDatasetManifest.rollupStatus(sources);
            d.Manifest     = obj.Data;
            d.ManifestObj  = obj;
        end

        function sources = buildSourceStatus(obj, opts)
            % Per-source status array in the legacy CellDatasetManager shape.
            if nargin < 2, opts = CellDatasetManifest.fillOpts(struct()); end
            keys = obj.sourceKeys();
            blank = CellDatasetManifest.emptyStatus();
            if isempty(keys)
                sources = blank; sources(1) = [];
                return;
            end
            % Order by page (NaN last).
            pg = zeros(1, numel(keys));
            for i = 1:numel(keys)
                [~, p] = obj.channelPage(keys{i});
                if isnan(p), p = inf; end
                pg(i) = p;
            end
            [~, ord] = sort(pg);
            keys = keys(ord);

            % The curation sidecar is one small JSON per dataset: read it once.
            curJson = CellDatasetManifest.readCurationJson(obj.curationJsonPath(), opts.Probe);

            sources = repmat(blank, numel(keys), 1);
            for i = 1:numel(keys)
                key = keys{i};
                [channel, page] = obj.channelPage(key);
                csv  = obj.activeLocs(key);
                rcsv = obj.locsPath(key, 'resized');
                qc   = obj.qcPath(key);

                s = blank;
                s.Key            = key;
                s.Channel        = channel;
                s.Page           = page;
                s.CsvPath        = csv;
                s.CsvResizedPath = rcsv;
                s.QcPath         = qc;

                s.Detected = ~isempty(csv) && isfile(csv);
                if opts.Probe && s.Detected
                    s.NumDetections = CellDatasetManifest.csvDataRows(csv);
                end
                s.HasResized = ~isempty(rcsv) && isfile(rcsv);

                cols = {};
                if opts.Probe && s.Detected
                    cols = CellDatasetManifest.csvColumns(csv);
                end
                s.Resolved = any(strcmpi(cols, 'CURATED_X'));
                s.Rescored = any(strcmpi(cols, 'rescore'));

                qcCounts = CellDatasetManifest.readQcCounts(qc, opts.Probe);
                s.QcReviewed  = qcCounts.reviewed;
                s.QcGood      = qcCounts.good;
                s.QcBad       = qcCounts.bad;
                s.QcUncertain = qcCounts.uncertain;
                s.Reviewed    = isfile(qc) && qcCounts.reviewed > 0;

                s.DetectionInfo = obj.provenanceStr(key, 'detection');
                s.ResolveInfo   = obj.provenanceStr(key, 'resolve');
                s.RescoreInfo   = obj.provenanceStr(key, 'rescore');
                s.QcInfo        = obj.provenanceStr(key, 'qc');

                % CellCurator status, from the counts the store keeps in the
                % curation JSON (no parsing of the curation CSV).
                rec = CellDatasetManifest.curationRecord(curJson, key);
                if ~isempty(rec)
                    s.CurFound = true;
                    s.CurationPath = obj.curationCsvFor(key, ...
                        CellDatasetManifest.fieldChar(rec, 'stem'));
                    cnt = struct();
                    if isfield(rec, 'counts') && isstruct(rec.counts), cnt = rec.counts; end
                    s.CurTotal     = CellDatasetManifest.numField(cnt, 'active');
                    s.CurReviewed  = CellDatasetManifest.numField(cnt, 'reviewed');
                    s.CurGood      = CellDatasetManifest.numField(cnt, 'good');
                    s.CurBad       = CellDatasetManifest.numField(cnt, 'bad');
                    s.CurUncertain = CellDatasetManifest.numField(cnt, 'uncertain');
                    s.CurKept      = CellDatasetManifest.numField(cnt, 'kept');
                    s.CurAutoRejected = CellDatasetManifest.numField(cnt, 'autoRejected');
                    s.CurComplete  = isfield(rec, 'complete') && isequal(logical(rec.complete), true);
                    s.Curated      = s.CurReviewed > 0 || s.CurComplete;
                end
                s.CurationInfo = obj.provenanceStr(key, 'curation');

                sources(i) = s;
            end
        end
    end

    %% ===================================================================
    %  Private instance helpers
    %  ===================================================================
    methods (Access = private)

        function seedFromGroup(obj, g)
            % Populate sources/images from a discovery file group (so a fresh
            % manifest knows its members before reconcileFromDisk runs).
            %
            % The group's localization files are the authoritative source set
            % for this dataset, so after seeding we prune any source carried
            % over from a previously-saved manifest that no longer has a
            % backing locs file on disk (e.g. a stale 'default' entry left by an
            % older naming scheme that wrote unsuffixed "<base>_locs.csv"). This
            % keeps the manifest's sources in sync with the files and stops the
            % dashboard from reporting phantom pages.
            groupKeys = {};
            for i = 1:numel(g.files)
                info = g.files{i}.info;
                full = g.files{i}.full;
                switch info.kind
                    case 'image'
                        switch info.role
                            case 'raw'
                                if isempty(obj.Data.image.file)
                                    obj.Data.image.file = obj.relName(full, obj.Folder);
                                end
                            case 'proj'
                                obj.Data.image.proj = obj.relName(full, obj.Folder);
                            case 'resized'
                                obj.Data.image.resized = obj.relName(full, obj.Folder);
                        end
                    case 'locs'
                        key = CellDatasetManifest.sourceKey(info.channel, info.page);
                        groupKeys{end+1} = key; %#ok<AGROW>
                        obj.ensureSource(key, info.channel, info.page);
                        s = obj.Data.sources.(key);
                        if info.resized
                            s.locsResized = obj.relName(full, obj.Folder);
                        else
                            s.locs = obj.relName(full, obj.Folder);
                            if isempty(s.activeLocs)
                                s.activeLocs = s.locs;
                            end
                        end
                        obj.Data.sources.(key) = s;
                end
            end
            obj.pruneSourcesExcept(groupKeys);
        end

        function pruneSourcesExcept(obj, keepKeys)
            % Drop source entries whose key is not in keepKeys (the set of
            % sources backed by an actual localization file in the current
            % discovery group). Removes stale entries from older naming schemes
            % so the manifest's source set tracks the files on disk.
            if ~isstruct(obj.Data.sources)
                return;
            end
            existing = fieldnames(obj.Data.sources);
            for i = 1:numel(existing)
                if ~any(strcmp(existing{i}, keepKeys))
                    obj.Data.sources = rmfield(obj.Data.sources, existing{i});
                end
            end
        end

        function addAnalyzedPage(obj, page)
            cur = [];
            if isfield(obj.Data.image, 'analyzedPages')
                cur = obj.Data.image.analyzedPages(:)';
            end
            obj.Data.image.analyzedPages = unique([cur, double(page)]);
        end

        function markStageDerived(obj, key, stage, done, facts)
            % Like markStage but for re-derived status: only sets a timestamp on
            % the first transition to done, and never clobbers it. Sets done to
            % the measured value (may be false).
            if nargin < 5 || ~isstruct(facts), facts = struct(); end
            s = obj.Data.sources.(key);
            if ~isfield(s, 'stages') || ~isstruct(s.stages)
                s.stages = struct();
            end
            st = CellDatasetManifest.stageStruct(s, stage);
            wasDone = isfield(st, 'done') && isequal(st.done, true);
            st.done = logical(done);
            if done && ~wasDone && (~isfield(st, 'time') || isempty(st.time))
                st.time = CellDatasetManifest.nowIso();
            end
            fn = fieldnames(facts);
            for i = 1:numel(fn)
                st.(fn{i}) = facts.(fn{i});
            end
            s.stages.(stage) = st;
            obj.Data.sources.(key) = s;
        end

        function csv = conventionalLocs(obj, key, resized)
            % Derive the conventional locs path for a source by naming
            % convention: "<base>[_<channel><page>]_locs[_resized].csv".
            tok = CellDatasetManifest.locsToken();
            [channel, page] = obj.channelPage(key);
            stem = obj.Base;
            if ~isempty(channel) && ~isnan(page)
                stem = sprintf('%s_%s%d', obj.Base, channel, page);
            elseif ~isempty(channel)
                stem = sprintf('%s_%s', obj.Base, channel);
            end
            suffix = tok;
            if resized
                suffix = [tok '_resized'];
            end
            csv = fullfile(obj.Folder, [stem suffix '.csv']);
            if ~isfile(csv)
                csv = '';
            end
        end

        function txt = provenanceStr(obj, key, stage)
            % Human-readable "tool  model  time" provenance for a stage.
            txt = '';
            s = obj.source(key);
            if isempty(s) || ~isfield(s, 'stages') || ~isfield(s.stages, stage)
                return;
            end
            st = s.stages.(stage);
            if ~isstruct(st), return; end
            parts = {};
            for f = {'tool', 'model', 'time'}
                if isfield(st, f{1}) && ~isempty(st.(f{1}))
                    parts{end+1} = char(string(st.(f{1}))); %#ok<AGROW>
                end
            end
            txt = strjoin(parts, '  ');
        end

        function p = absPath(obj, name)
            % Resolve a stored basename-relative path to absolute.
            p = '';
            name = char(name);
            if isempty(name)
                return;
            end
            if CellDatasetManifest.isAbsolute(name)
                p = name;
            else
                p = fullfile(obj.Folder, name);
            end
        end
    end

    %% ===================================================================
    %  Static helpers: schema scaffolding
    %  ===================================================================
    methods (Static, Access = private)

        function opts = fillOpts(opts)
            defaults = struct('WriteManifest', true, 'Probe', true, ...
                'LocsToken', CellDatasetManifest.locsToken(), 'Progress', []);
            fn = fieldnames(defaults);
            for k = 1:numel(fn)
                if ~isfield(opts, fn{k}) || isempty(opts.(fn{k}))
                    opts.(fn{k}) = defaults.(fn{k});
                end
            end
        end

        function d = emptyData()
            d = struct( ...
                'schema', CellDatasetManifest.SCHEMA, ...
                'datasetBase', '', ...
                'image', struct('file', '', 'pageCount', 0, 'umPerPixel', [], ...
                    'proj', '', 'resized', '', 'analyzedPages', [], 'activeImage', ''), ...
                'sources', struct(), ...
                'updatedUtc', '');
        end

        function s = emptySource(channel, page)
            if nargin < 1, channel = ''; end
            if nargin < 2, page = NaN; end
            if isempty(page) || (isnumeric(page) && isnan(page))
                pageVal = [];
            else
                pageVal = double(page);
            end
            blank = struct('done', false);
            s = struct('channel', char(channel), 'page', pageVal, ...
                'activeLocs', '', 'coordSpace', 'full', ...
                'locs', '', 'locsResized', '', 'qc', '', 'curation', '', ...
                'stages', struct('detection', blank, 'resized', blank, ...
                    'resolve', blank, 'rescore', blank, 'qc', blank, ...
                    'curation', blank));
        end

        function s = emptyStatus()
            % Legacy CellDatasetManager source-status shape.
            s = struct('Key', '', 'Channel', '', 'Page', NaN, ...
                'CsvPath', '', 'CsvResizedPath', '', 'QcPath', '', ...
                'Detected', false, 'NumDetections', 0, 'DetectionInfo', '', ...
                'HasResized', false, ...
                'Resolved', false, 'ResolveInfo', '', ...
                'Rescored', false, 'RescoreInfo', '', ...
                'Reviewed', false, 'QcReviewed', 0, 'QcGood', 0, ...
                'QcBad', 0, 'QcUncertain', 0, 'QcInfo', '', ...
                'CurationPath', '', 'CurFound', false, 'Curated', false, 'CurComplete', false, ...
                'CurTotal', 0, 'CurReviewed', 0, 'CurGood', 0, 'CurBad', 0, ...
                'CurUncertain', 0, 'CurKept', 0, 'CurAutoRejected', 0, ...
                'CurationInfo', '');
        end

        function cj = readCurationJson(jsonPath, probe)
            % Decoded "<base>.curation.json" (curation.Store), or [] when absent,
            % unreadable, or probing is off.
            cj = [];
            jsonPath = char(jsonPath);
            if ~probe || isempty(jsonPath) || ~isfile(jsonPath), return; end
            try
                cj = jsondecode(fileread(jsonPath));
            catch
                cj = [];
            end
        end

        function rec = curationRecord(cj, key)
            % sources.<key> record of a decoded curation JSON, or [] if none.
            rec = [];
            if isstruct(cj) && isfield(cj, 'sources') && isstruct(cj.sources) ...
                    && isfield(cj.sources, key) && isstruct(cj.sources.(key))
                rec = cj.sources.(key);
            end
        end

        function v = numField(s, name)
            % Scalar numeric field of a struct, 0 when missing or non-numeric.
            v = 0;
            if isstruct(s) && isfield(s, name) && isnumeric(s.(name)) && isscalar(s.(name)) ...
                    && isfinite(s.(name))
                v = double(s.(name));
            end
        end

        function m = readManifestFile(manifestPath)
            % Read a schema-2.0 manifest, or return an empty skeleton. Anything
            % that is not a 2.0 manifest is treated as absent (no migration).
            m = CellDatasetManifest.emptyData();
            manifestPath = char(manifestPath);
            if ~isfile(manifestPath)
                return;
            end
            try
                loaded = jsondecode(fileread(manifestPath));
            catch
                return;
            end
            if ~isstruct(loaded) || ~isfield(loaded, 'schema') ...
                    || ~strcmp(char(string(loaded.schema)), CellDatasetManifest.SCHEMA)
                return;   % greenfield: ignore foreign/legacy formats
            end
            m = CellDatasetManifest.normalize(loaded);
        end

        function m = normalize(loaded)
            % Coerce a decoded manifest into the canonical in-memory shape.
            m = CellDatasetManifest.emptyData();
            for f = {'schema', 'datasetBase', 'updatedUtc'}
                if isfield(loaded, f{1}), m.(f{1}) = loaded.(f{1}); end
            end
            if isfield(loaded, 'image') && isstruct(loaded.image)
                fn = intersect(fieldnames(loaded.image), fieldnames(m.image));
                for k = 1:numel(fn)
                    m.image.(fn{k}) = loaded.image.(fn{k});
                end
            end
            if isfield(loaded, 'sources') && isstruct(loaded.sources) ...
                    && isscalar(loaded.sources)
                m.sources = loaded.sources;
            end
        end

        function ok = writeManifestFile(manifestPath, m)
            % A manifest that says what the file already says is not written
            % again (a scan of a folder where nothing changed touches no file:
            % no writes on the NAS, and updatedUtc stays the time of the last
            % real change).
            ok = false;
            try
                if isfile(manifestPath)
                    was = fileread(char(manifestPath));
                    if strcmp(was, CellDatasetManifest.encode(m))
                        ok = true;
                        return;
                    end
                end
            catch
            end
            m.updatedUtc = CellDatasetManifest.nowIso();
            txt = CellDatasetManifest.encode(m);
            fid = fopen(char(manifestPath), 'w');
            if fid == -1
                return;
            end
            cleaner = onCleanup(@() fclose(fid));
            fwrite(fid, txt, 'char');
            ok = true;
        end

        function txt = encode(m)
            % The manifest's text on disk.
            try
                txt = jsonencode(m, 'PrettyPrint', true);
            catch
                txt = jsonencode(m);
            end
        end

        function s = nowIso()
            s = char(datetime('now', 'TimeZone', 'local', ...
                'Format', 'yyyy-MM-dd''T''HH:mm:ssZZZZZ'));
        end
    end

    %% ===================================================================
    %  Static helpers: classification & conventions
    %  ===================================================================
    methods (Static, Access = private)

        function info = classifyFile(folder, name, ext, token) %#ok<INUSL>
            % Classify a file into the dataset model, or [] when untracked.
            %   .kind 'image'|'locs'  .base  .role/.channel/.page/.resized
            if nargin < 4 || isempty(token)
                token = CellDatasetManifest.locsToken();
            end
            info = [];
            if any(strcmp(ext, CellDatasetManifest.IMAGE_EXTS))
                role = 'raw'; base = name;
                if ~isempty(regexpi(name, '_(resized|preprocessed)$', 'once'))
                    role = 'resized';
                    base = regexprep(name, '_(resized|preprocessed)$', '', 'ignorecase');
                elseif ~isempty(regexpi(name, '_proj$', 'once'))
                    role = 'proj';
                    base = regexprep(name, '_proj$', '', 'ignorecase');
                end
                info = struct('kind', 'image', 'base', base, 'role', role, ...
                    'channel', '', 'page', NaN, 'resized', false);
                return;
            end
            if strcmp(ext, '.csv')
                if ~isempty(regexpi(name, '_QC$', 'once'))
                    return;   % QC files are derived, not anchors
                end
                tokPat = regexptranslate('escape', token);
                m = regexpi(name, ['^(.*)' tokPat '(_resized)?$'], 'tokens', 'once');
                if isempty(m)
                    return;
                end
                stem    = m{1};
                resized = ~isempty(regexpi(name, [tokPat '_resized$'], 'once'));
                t = regexp(stem, '^(?<base>.+)_(?<ch>[A-Za-z_]+?)(?<pg>\d+)$', ...
                    'names', 'once');
                if isempty(t)
                    base = stem; channel = ''; page = NaN;
                else
                    base = t.base; channel = t.ch; page = str2double(t.pg);
                end
                info = struct('kind', 'locs', 'base', base, 'role', '', ...
                    'channel', channel, 'page', page, 'resized', resized);
            end
        end

        function key = sourceKey(channel, page)
            % Canonical, struct-field-safe key for a (channel,page) source.
            channel = char(channel);
            if isempty(channel) && (isempty(page) || isnan(page))
                key = 'default'; return;
            end
            if isempty(page) || isnan(page)
                key = channel;
            else
                key = sprintf('%s%d', channel, page);
            end
            key = regexprep(key, '[^A-Za-z0-9_]', '_');
            if isempty(regexp(key, '^[A-Za-z]', 'once'))
                key = ['s_' key];
            end
        end

        function [channel, page] = splitKey(key)
            % Inverse of sourceKey for the common "<channel><page>" form.
            channel = ''; page = NaN;
            key = char(key);
            if isempty(key) || strcmp(key, 'default')
                return;
            end
            t = regexp(key, '^(?<ch>[A-Za-z_]+?)(?<pg>\d+)$', 'names', 'once');
            if ~isempty(t)
                channel = t.ch; page = str2double(t.pg);
            else
                channel = key;
            end
        end

        function base = baseForImage(folder, name)
            % Dataset base of the image "<name>.<ext>" in folder: the three
            % rules of the class help ("The base of a dataset"), asked of the
            % files in the folder. Agrees with what discover makes of the same
            % folder, and with forCsv for the files CellDiscovery writes.
            name = char(name);
            info = CellDatasetManifest.classifyFile(folder, name, '.tif');
            base = info.base;
            if strcmp(info.role, 'raw')
                return;                                   % no role suffix
            end
            if CellDatasetManifest.hasLocsFor(folder, name)
                base = name;                              % rule 1
                return;
            end
            if strcmp(info.role, 'proj') ...
                    && isempty(CellDatasetManifest.findCompanion(folder, info.base, '')) ...
                    && ~CellDatasetManifest.hasLocsFor(folder, info.base)
                base = name;                              % rule 3
            end
        end

        function tf = hasLocsFor(folder, base)
            % True when folder holds a localization CSV of the dataset BASE
            % ("<base>[_<channel><page>]<token>[_resized].csv").
            tf = false;
            token = CellDatasetManifest.locsToken();
            d = dir(fullfile(char(folder), [char(base) '*' token '*.csv']));
            for k = 1:numel(d)
                [~, nm, ext] = fileparts(d(k).name);
                info = CellDatasetManifest.classifyFile(folder, nm, lower(ext), token);
                if ~isempty(info) && strcmp(info.kind, 'locs') && strcmpi(info.base, base)
                    tf = true;
                    return;
                end
            end
        end

        function groups = settleImages(groups)
            % Give every image with a role suffix to the dataset it belongs to
            % (the three rules of the class help), and drop the groups left
            % without a file. GROUPS maps lower(fullfile(folder, base)) to a
            % struct folder, base, files {struct full, info}; classifyFile put
            % each suffixed image with the base without its suffix (rule 2).
            keys = groups.keys;
            hasLocs = containers.Map('KeyType', 'char', 'ValueType', 'logical');
            hasAnchor = containers.Map('KeyType', 'char', 'ValueType', 'logical');
            for k = 1:numel(keys)
                g = groups(keys{k});
                isLocs = cellfun(@(f) strcmp(f.info.kind, 'locs'), g.files);
                isRaw  = cellfun(@(f) strcmp(f.info.kind, 'image') && strcmp(f.info.role, 'raw'), g.files);
                hasLocs(keys{k}) = any(isLocs);
                hasAnchor(keys{k}) = any(isLocs) || any(isRaw);
            end
            for k = 1:numel(keys)
                g = groups(keys{k});
                stay = true(1, numel(g.files));
                for i = 1:numel(g.files)
                    f = g.files{i};
                    if ~strcmp(f.info.kind, 'image') || strcmp(f.info.role, 'raw')
                        continue;
                    end
                    [~, own] = fileparts(f.full);
                    ownKey = lower(fullfile(g.folder, own));
                    ownHasLocs = isKey(hasLocs, ownKey) && hasLocs(ownKey);
                    alone = strcmp(f.info.role, 'proj') && ~hasAnchor(keys{k});
                    if ~(ownHasLocs || alone)
                        continue;                         % rule 2: a companion
                    end
                    f.info.base = own;                    % rules 1 and 3: THE image
                    f.info.role = 'raw';
                    if isKey(groups, ownKey)
                        t = groups(ownKey);
                    else
                        t = struct('folder', g.folder, 'base', own, 'files', {{}});
                    end
                    t.files{end+1} = f;
                    groups(ownKey) = t;
                    stay(i) = false;
                end
                if ~all(stay)
                    g.files = g.files(stay);
                    if isempty(g.files)
                        remove(groups, keys{k});
                    else
                        groups(keys{k}) = g;
                    end
                end
            end
        end

        function tf = isRecordedStage(st)
            % True for a stage a tool recorded (it names its tool, or carries
            % model-input facts), false for one only derived from the files.
            tf = isstruct(st) && isfield(st, 'done') && isequal(st.done, true) && ...
                (CellDatasetManifest.has(st, 'tool') || CellDatasetManifest.has(st, 'model') ...
                 || isfield(st, 'resize') || isfield(st, 'normalized'));
        end

        function p = findImageForBase(folder, base)
            % Representative image for a base: raw, then projection, then resized.
            for suffix = {'', '_proj', '_resized', '_preprocessed'}
                p = CellDatasetManifest.findCompanion(folder, base, suffix{1});
                if ~isempty(p)
                    return;
                end
            end
            p = '';
        end

        function p = findCompanion(folder, base, suffix)
            % Locate "<base><suffix>.<ext>" for the known image extensions.
            p = '';
            for ext = CellDatasetManifest.IMAGE_EXTS
                cand = fullfile(char(folder), [char(base), char(suffix), ext{1}]);
                if isfile(cand)
                    p = cand; return;
                end
            end
        end

        function um = pixelSizeUm(imgPath)
            % Micrometers-per-pixel from a TIFF's resolution tags, else default.
            % Reads ImageJ ("unit=micron") as well as plain TIFF calibration.
            um = CellToolkit.tiffPixelSizeUm(imgPath, 1);
            if ~isfinite(um)
                um = CellDatasetManifest.DEFAULT_UM_PER_PIXEL;
            end
        end
    end

    %% ===================================================================
    %  Static helpers: CSV probing & small utilities
    %  ===================================================================
    methods (Static, Access = private)

        function cols = csvColumns(csvPath)
            % Column names from a CSV header line (one cheap line read).
            cols = {};
            try
                fid = fopen(char(csvPath), 'r');
                if fid == -1, return; end
                cleaner = onCleanup(@() fclose(fid));
                line = fgetl(fid);
                if ~ischar(line), return; end
                cols = strtrim(strsplit(line, ','));
            catch
            end
        end

        function n = csvDataRows(csvPath)
            % Data rows (excludes header) by counting newlines.
            n = 0;
            try
                txt = fileread(char(csvPath));
                if isempty(txt), return; end
                nl = sum(txt == newline);
                if txt(end) ~= newline, nl = nl + 1; end
                n = max(nl - 1, 0);
            catch
            end
        end

        function c = readQcCounts(qcPath, probe)
            % Review counts from a *_QC.csv (Reviewed/Good/Bad/Uncertain).
            c = struct('reviewed', 0, 'good', 0, 'bad', 0, 'uncertain', 0);
            qcPath = char(qcPath);
            if ~probe || isempty(qcPath) || ~isfile(qcPath)
                return;
            end
            try
                tbl = readtable(qcPath, 'TextType', 'string', ...
                    'VariableNamingRule', 'preserve');
            catch
                return;
            end
            names = string(tbl.Properties.VariableNames);
            if ismember("QCLabel", names)
                labels = string(tbl.QCLabel);
                c.good      = sum(labels == "Good");
                c.bad       = sum(labels == "Bad");
                c.uncertain = sum(labels == "Uncertain");
            end
            if ismember("QCReviewed", names)
                v = tbl.QCReviewed;
                if ~islogical(v), v = (double(v) ~= 0); end
                c.reviewed = sum(v);
            elseif ismember("QCLabel", names)
                c.reviewed = sum(strlength(string(tbl.QCLabel)) > 0);
            end
        end

        function s = rollupStatus(sources)
            % Coarse pipeline status for a whole dataset.
            if isempty(sources)
                s = 'New (image only)'; return;
            end
            det = [sources.Detected];
            if ~any(det)
                s = 'New (image only)'; return;
            end
            if all([sources.CurComplete])
                s = 'Curated';
            elseif any([sources.Curated])
                s = 'Curating';
            elseif all([sources.Reviewed])
                s = 'Reviewed';
            elseif all([sources.Rescored])
                s = 'Rescored';
            elseif all([sources.Resolved])
                s = 'Resolved';
            elseif all(det)
                s = 'Detected';
            else
                s = 'Partial';
            end
        end

        function txt = frac(sources, field)
            % "k/n" of sources with a true status flag (for statusTable).
            n = numel(sources);
            if n == 0
                txt = "0/0"; return;
            end
            flags = [sources.(field)];
            txt = string(sprintf('%d/%d', sum(flags), n));
        end

        function stage = validStage(stage)
            stage = lower(char(stage));
            if ~any(strcmp(stage, CellDatasetManifest.STAGES))
                error('CellDatasetManifest:badStage', ...
                    'Unknown stage "%s". Expected one of: %s', ...
                    stage, strjoin(CellDatasetManifest.STAGES, ', '));
            end
        end

        function facts = pickFacts(info, names)
            % Copy a whitelist of non-empty fields from info into a facts struct.
            facts = struct();
            if ~isstruct(info), return; end
            for k = 1:numel(names)
                if isfield(info, names{k}) && ~isempty(info.(names{k}))
                    facts.(names{k}) = info.(names{k});
                end
            end
        end

        function tf = has(s, name)
            tf = isstruct(s) && isfield(s, name) && ~isempty(s.(name));
        end

        function st = stageStruct(s, stage)
            % A source's stage sub-struct, or an empty struct when absent.
            st = struct();
            if isfield(s, 'stages') && isstruct(s.stages) ...
                    && isfield(s.stages, stage) && isstruct(s.stages.(stage))
                st = s.stages.(stage);
            end
        end

        function v = fieldChar(s, name)
            v = '';
            if isstruct(s) && isfield(s, name) && ~isempty(s.(name))
                v = char(string(s.(name)));
            end
        end

        function rel = relName(absPath, folder)
            % Store a path as a basename relative to the dataset folder when it
            % lives there (the common case), else keep it absolute.
            absPath = char(absPath);
            folder  = char(folder);
            if isempty(absPath)
                rel = ''; return;
            end
            [pdir, nm, ext] = fileparts(absPath);
            if strcmpi(strrep(pdir, '\', '/'), strrep(folder, '\', '/'))
                rel = [nm ext];
            else
                rel = absPath;
            end
        end

        function tf = isAbsolute(p)
            p = char(p);
            tf = ~isempty(regexp(p, '^([A-Za-z]:[\\/]|[\\/]{2}|/)', 'once'));
        end
    end
end

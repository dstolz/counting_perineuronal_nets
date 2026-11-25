classdef Project
%PROJECT  The sections below a folder, the measurements of their cells, and how they are grouped.
%   Everything behind the CellAnalysis window that touches files (static; no GUI).
%
%   S = cellanalysis.Project.sources(parentDir)
%       One row per source (a channel of a section) below parentDir: a table with
%         Dataset, Folder, Key, Kind ("pnn" | "pv" | "unknown"), Page, ImagePath,
%         Curated, Complete, Detections, Kept            what the Dataset Manager knows
%         Subject, SectionID, Hemisphere, Stain, Section the section the file name names
%         Sex, Species, DbProject                        what the lab database last said about
%                                                        the subject (this computer's cache; "")
%         DbTags, DbVariables                            its tags and its variable values there,
%                                                        in a few words (celldb.subjectInfo)
%         Tag_<namespace>, HasTag_<tag>, Var_<name>      one column per tag namespace, bare tag and
%                                                        variable a subject here has (text, or a
%                                                        number for a number variable; see
%                                                        celldb.subjectFactors and DATABASE below)
%         MetricsPath, JsonPath                          where the measurements are kept
%         State        "none" | "current" | "stale"      see STATE
%         Measured     cells in the metrics file (NaN when none)
%         SurfaceMode  "auto" | "all" | "traced"         the dataset's surface definition
%         SurfaceOk    the surface was found at the last measurement
%         Mf           the dataset's CellDatasetManifest (handle)
%       Nothing is written by a scan.
%
%   [T, rec, loaded] = cellanalysis.Project.measure(src, opts)
%       Measure one source (a row of S) and write its metrics file. T is what was written, rec
%       the record stored in the JSON. opts: Force (false: cells whose position, image and
%       surface did not change keep their measurements, so a run after more curation only
%       measures what is new), Progress (function handle called with a text), Loaded (the
%       third output of the call for another source of the same dataset: its image and surface
%       are used again instead of being read and detected a second time).
%
%   [C, Sec] = cellanalysis.Project.load(S, kind, opts)
%       The cells of every measured source of one kind, as one long table: the section's tags
%       (Dataset, Section, Subject, Hemisphere, Stain, Sex, Species, DbProject, the lab database
%       columns and the grouping columns of S), CellID, X, Y, score, rescore, Label, Kept, every metric of
%       cellanalysis.Measure.catalog(), Segmented, TouchesEdge, InTissue, InAnalysis, PartnerID.
%       opts.Population "kept" (default: the cells a person kept) | "all" (every candidate that
%       is not merged, stale or inside an exclusion region); opts.ColocUm (10): the distance
%       within which a cell is paired with a cell of the section's other channel, of the same
%       population (one to one: cellanalysis.Measure.colocalize). opts.MinDepthUm (0 = none):
%       every cell closer than this to the brain surface (SurfaceDistUm < MinDepthUm) is
%       rejected, in both channels, before anything is computed; a cell without a distance (its
%       section has no surface) is kept. NnUm, LocalDensity,
%       OtherDistUm, Colocalized, ColocChance and PartnerID (the CellID of the partner in the
%       other channel's metrics file, NaN = none) are computed here, among the chosen population.
%       Sec: one row per source that gave cells: SourceRow, Cells, OtherKey ("" = the section
%       has no other channel), OtherCells, Pairs, TissueMm2 (NaN without a brain surface; the
%       tissue within MinDepthUm of the surface left out), NearSurface (cells of the population
%       rejected for MinDepthUm).
%
%   [T, near] = cellanalysis.Project.pick(T, population, minDepthUm)
%       The rows of a metrics table (readMetrics) that take part, as LOAD chooses them; near:
%       how many were rejected for lying within minDepthUm of the surface.
%
%   def = cellanalysis.Project.surfaceDef(src)          struct mode, line, include, exclude
%   cellanalysis.Project.setSurface(src, def)           store the dataset's surface definition
%   S = cellanalysis.Project.loadSurface(src)           detect it now (cellanalysis.Surface struct)
%
%   S = cellanalysis.Project.readDatabase(S)            read the lab database's facts about the
%       subjects again from this computer's cache (after celldb.refreshSubjects): Sex, Species,
%       DbProject, DbTags, DbVariables and the Tag_/HasTag_/Var_ columns
%   D = cellanalysis.Project.databaseColumns(S)         those columns: a table Name, Label, Source
%       ("tag" | "variable"), Type ("text" | "number"), Units, Key, Meaning (celldb.subjectFactors)
%
%   G = cellanalysis.Project.readGroups(parentDir)      the user's groupings (table)
%   cellanalysis.Project.writeGroups(parentDir, G)
%   G = cellanalysis.Project.setGroup(G, S, rows, value, factor)
%   [G, rep] = cellanalysis.Project.importGroups(G, S, file)
%   [S, factors] = cellanalysis.Project.applyGroups(S, G)
%
%   FILES
%     <stem>_metrics.csv          beside the detector's locs file (stem as curation.Store:
%                                 '<base>_<key>'), one row per measured cell: CellID, X, Y, score,
%                                 rescore, Label, Reviewed, Kept, InTissue, InAnalysis,
%                                 SurfaceDistUm, AxisToSurfaceDeg, the image metrics of
%                                 cellanalysis.Measure, Segmented, TouchesEdge. Written in one step
%                                 (temporary file, then rename).
%     <base>.cellanalysis.json    in the dataset folder, shared by its sources:
%         { "schema": "cellanalysis/1.0",
%           "surface": { "mode": "auto"|"all"|"traced", "line": [[x,y],...],
%                        "include": [[x,y],...], "exclude": [[x,y],...] },
%           "sources": { "<key>": { metricsFile, measuredAt, versions, cells, kept, umPerPixel,
%               image {name, bytes, modified}, locs {..}, curation {..}, journalBytes,
%               surfaceHash, surfaceOk, surfaceMessage, regionsHash, tissueMedian, tissueMad,
%               depthEdgesUm [..], depthAreaUm2 [..] } } }
%     <parentDir>\cellanalysis_groups.csv   the user's groupings: Dataset, Subject, Group and any
%                                 imported columns, one row per dataset.
%   The curation files and the detector's locs are only read (through curation.Store, opened
%   read-only): this package never writes them.
%
%   WHICH CELLS. The rows of the source's curation store that are active and not inside an
%   exclusion region; a source that was never curated has every detection, none of them Kept.
%   Positions are the curated ones (moved, added and merged cells included).
%
%   DATABASE. What the lab database (CarasLabDB) says about a section's subject is read from the
%   cache the lab database client keeps on this computer, never from the server, and is not
%   stored in any file of this package: a scan reads it again. A tag namespace gives a text
%   column (the subject's value in it), a bare tag a text column ("pilot" / "not pilot"), a text
%   variable a text column and a number variable a number column; all of them are factors a plot
%   can be grouped by, and the number columns can be plotted like a metric (one value per
%   subject, the same for every cell of it).
%
%   STATE. "current": the metrics file was made from the image, locs and curation files that
%   are there now, with the dataset's present surface definition and this version of the code.
%   "stale": something of that changed since (more cells reviewed, a re-detection, another
%   surface). "none": never measured.
%
%   See also CellAnalysis, cellanalysis.Measure, cellanalysis.Surface, cellanalysis.Stats.

    properties (Constant)
        VERSION = "project/1"
        SCHEMA = 'cellanalysis/1.0'
        JSON_EXT = '.cellanalysis.json'
        METRICS_TAIL = '_metrics.csv'
        GROUPS_FILE = 'cellanalysis_groups.csv'
        CACHE_FILES = 400           % metrics files kept in memory (readMetrics)
        DEPTH_STEP_UM = 25
        DEPTH_MAX_UM = 6000
        FIXED_FACTORS = ["Section" "Subject" "Hemisphere" "Stain" "Sex" "Species" "DbProject" "Group"]
    end

    methods (Static)

        % ======================================================================= sources
        function S = sources(parentDir, opts)
            %SOURCES  One row per source below parentDir (see the class help).
            if nargin < 2 || isempty(opts), opts = struct(); end
            scanOpts = struct('WriteManifest', false, 'Database', false);
            if isfield(opts, 'Progress') && ~isempty(opts.Progress), scanOpts.Progress = opts.Progress; end
            datasets = CellDatasetManager.scan(parentDir, scanOpts);
            rows = cell(0, 1);
            for k = 1:numel(datasets)
                d = datasets(k);
                if isempty(d.Sources), continue; end
                mf = d.ManifestObj;
                jsonPath = fullfile(d.Folder, [d.Base cellanalysis.Project.JSON_EXT]);
                J = cellanalysis.Project.readJson(jsonPath);
                def = cellanalysis.Project.defOf(J);
                sec = d.Section;
                label = strtrim(string(d.SectionLabel));
                if strlength(label) == 0, label = string(d.Base); end
                for i = 1:numel(d.Sources)
                    s = d.Sources(i);
                    if ~s.Detected, continue; end
                    r = struct();
                    r.Dataset = string(d.Base);
                    r.Folder = string(d.Folder);
                    r.Key = string(s.Key);
                    r.Kind = curation.Proposals.kindOf(s.Key);
                    r.Page = double(s.Page);
                    r.ImagePath = string(d.ImagePath);
                    r.Curated = logical(s.Curated);
                    r.Complete = logical(s.CurComplete);
                    r.Detections = double(s.NumDetections);
                    r.Kept = double(s.CurKept);
                    r.Subject = string(sec.SubjectID);
                    r.SectionID = string(sec.SectionID);
                    r.Hemisphere = string(sec.Hemisphere);
                    r.Stain = string(sec.Stain);
                    r.Section = label;
                    r.Sex = "";
                    r.Species = "";
                    r.DbProject = "";
                    r.DbTags = "";
                    r.DbVariables = "";
                    r.MetricsPath = string(cellanalysis.Project.metricsPathFor(mf, s.Key));
                    r.JsonPath = string(jsonPath);
                    rec = cellanalysis.Project.recordOf(J, s.Key);
                    [r.State, r.Measured] = cellanalysis.Project.stateOf(r, rec, def, mf);
                    r.SurfaceMode = string(def.mode);
                    r.SurfaceOk = isstruct(rec) && isfield(rec, 'surfaceOk') && isequal(logical(rec.surfaceOk), true);
                    r.Mf = mf;
                    rows{end + 1, 1} = r; %#ok<AGROW>
                end
            end
            if isempty(rows)
                S = cellanalysis.Project.emptySources();
                return
            end
            S = struct2table([rows{:}]', 'AsArray', true);
            S = cellanalysis.Project.readDatabase(S);
            % a label that names two datasets is no label: fall back to the base for those
            [u, ~, j] = unique(S.Subject + "|" + S.Section);
            for g = 1:numel(u)
                rowsG = find(j == g);
                if numel(unique(S.Dataset(rowsG))) > 1 || strlength(S.Subject(rowsG(1))) == 0
                    S.Section(rowsG) = S.Dataset(rowsG);
                else
                    S.Section(rowsG) = strtrim(extractAfter(S.Subject(rowsG), "SUBJ-ID-") + " " + S.Section(rowsG));
                end
            end
            S.Group = strings(height(S), 1);
            S = sortrows(S, {'Subject', 'Dataset', 'Page'});
        end

        function S = emptySources()
            %EMPTYSOURCES  A sources table without rows (every column, right types).
            S = table('Size', [0 26], 'VariableTypes', ...
                {'string', 'string', 'string', 'string', 'double', 'string', 'logical', 'logical', 'double', 'double', ...
                 'string', 'string', 'string', 'string', 'string', 'string', 'string', 'string', 'string', 'string', ...
                 'string', 'string', 'string', 'double', 'string', 'logical'}, ...
                'VariableNames', {'Dataset', 'Folder', 'Key', 'Kind', 'Page', 'ImagePath', 'Curated', 'Complete', ...
                 'Detections', 'Kept', 'Subject', 'SectionID', 'Hemisphere', 'Stain', 'Section', 'Sex', 'Species', ...
                 'DbProject', 'DbTags', 'DbVariables', 'MetricsPath', 'JsonPath', 'State', 'Measured', ...
                 'SurfaceMode', 'SurfaceOk'});
            S.Mf = cell(0, 1);
            S.Group = strings(0, 1);
        end

        function S = refreshState(S, rows)
            %REFRESHSTATE  Re-read State, Measured, SurfaceMode and SurfaceOk of the given rows.
            if nargin < 2, rows = 1:height(S); end
            for i = reshape(rows, 1, [])
                J = cellanalysis.Project.readJson(S.JsonPath(i));
                def = cellanalysis.Project.defOf(J);
                rec = cellanalysis.Project.recordOf(J, S.Key(i));
                [S.State(i), S.Measured(i)] = cellanalysis.Project.stateOf(table2struct(S(i, :)), rec, def, ...
                    cellanalysis.Project.mfOf(S, i));
                S.SurfaceMode(i) = string(def.mode);
                S.SurfaceOk(i) = isstruct(rec) && isfield(rec, 'surfaceOk') && isequal(logical(rec.surfaceOk), true);
            end
        end

        % ======================================================================= surface
        function def = surfaceDef(src)
            %SURFACEDEF  The surface definition of the source's dataset: struct mode, line.
            src = cellanalysis.Project.one(src);
            def = cellanalysis.Project.defOf(cellanalysis.Project.readJson(src.JsonPath));
        end

        function setSurface(src, def)
            %SETSURFACE  Store the surface definition of the source's dataset (every source of
            %   the dataset shares it). def: struct with any of mode ("auto" | "all" | "traced"),
            %   line (M x 2), include, exclude (K x 2 points); a field that is not given keeps
            %   its stored value, so switching to another mode and back loses nothing.
            src = cellanalysis.Project.one(src);
            if isfield(def, 'mode')
                def.mode = lower(string(def.mode));
                if ~isscalar(def.mode) || ~any(def.mode == cellanalysis.Surface.MODES)
                    error('cellanalysis:Project:badSurface', 'mode must be "auto", "all" or "traced".');
                end
            end
            for f = ["line" "include" "exclude"]
                if ~isfield(def, f), continue; end
                v = double(def.(f));
                if isempty(v), v = zeros(0, 2); end
                if size(v, 2) ~= 2 || any(~isfinite(v(:))) || (f == "line" && size(v, 1) == 1)
                    error('cellanalysis:Project:badSurface', '%s must be M x 2 finite coordinates.', f);
                end
                def.(f) = v;
            end
            function J = upd(J)
                J = cellanalysis.Project.blankJson(J);
                for g = ["mode" "line" "include" "exclude"]
                    if ~isfield(def, g), continue; end
                    if g == "mode"
                        J.surface.mode = char(def.mode);
                    else
                        J.surface.(g) = def.(g);
                    end
                end
            end
            curation.AtomicIO.updateJson(char(src.JsonPath), @upd);
        end

        function [Sf, pages, um] = loadSurface(src, def)
            %LOADSURFACE  Read the section's image and detect its surface with the dataset's
            %   definition (or DEF). Also returns the pages (cell) and the pixel size.
            src = cellanalysis.Project.one(src);
            if nargin < 2 || isempty(def), def = cellanalysis.Project.surfaceDef(src); end
            [pages, um] = cellanalysis.Project.readPages(src);
            Sf = cellanalysis.Surface.detect(pages, um, cellanalysis.Project.surfaceOpts(def));
        end

        function o = surfaceOpts(def)
            %SURFACEOPTS  The options of cellanalysis.Surface.detect for a surface definition.
            o = struct('Mode', def.mode, 'Line', def.line, 'Include', def.include, 'Exclude', def.exclude);
        end

        function h = surfaceHash(def)
            %SURFACEHASH  Changes when the surface definition does.
            h = cellanalysis.Surface.hashOf(def.mode, def.line, def.include, def.exclude);
        end

        % ======================================================================= measure
        function [T, rec, loaded] = measure(src, opts)
            %MEASURE  Measure one source and write its metrics file (see the class help).
            if nargin < 2 || isempty(opts), opts = struct(); end
            force = isfield(opts, 'Force') && ~isempty(opts.Force) && logical(opts.Force);
            say = @(txt) [];
            if isfield(opts, 'Progress') && ~isempty(opts.Progress), say = opts.Progress; end
            P = cellanalysis.Project;
            src = P.one(src);
            mf = src.Mf;
            if iscell(mf), mf = mf{1}; end
            loaded = [];
            if isfield(opts, 'Loaded') && isstruct(opts.Loaded), loaded = opts.Loaded; end

            % ---- the cells ------------------------------------------------------------------------
            say("Reading the cells");
            [C, meta] = P.cellsOf(mf, src.Key);
            um = meta.UmPerPixel;
            J = P.readJson(src.JsonPath);
            def = P.defOf(J);
            old = P.recordOf(J, src.Key);
            surfHash = P.surfaceHash(def);
            regHash = P.regionsHash(meta.Regions, src.Key);
            imgStamp = P.stamp(src.ImagePath);
            versions = P.versions();

            % ---- what can be kept from the last measurement ---------------------------------------
            names = cellanalysis.Measure.imageNames();
            keepCols = [names, "SurfaceDistUm", "AxisToSurfaceDeg", "InTissue", "InAnalysis", "Segmented", "TouchesEdge"];
            reuse = false(height(C), 1);
            Prev = table();
            sameBasis = ~force && isstruct(old) && isfield(old, 'versions') && isequal(reshape(string(old.versions), 1, []), versions) ...
                && isfield(old, 'image') && P.sameStamp(old.image, imgStamp) ...
                && isfield(old, 'surfaceHash') && string(old.surfaceHash) == surfHash ...
                && isfield(old, 'regionsHash') && string(old.regionsHash) == regHash ...
                && isfield(old, 'umPerPixel') && abs(double(old.umPerPixel) - um) < 1e-9 ...
                && isfile(src.MetricsPath);
            if sameBasis
                try
                    Prev = P.readMetrics(src.MetricsPath);
                    [tf, loc] = ismember(C.CellID, Prev.CellID);
                    loc(~tf) = 1;
                    if ~isempty(Prev)
                        reuse = tf & abs(C.X - Prev.X(loc)) <= 0.01 & abs(C.Y - Prev.Y(loc)) <= 0.01;
                    end
                    prevRow = loc;
                catch
                    reuse(:) = false;
                    Prev = table();
                end
            end
            todo = find(~reuse);

            % ---- measure what is new --------------------------------------------------------------
            T = C;
            for v = keepCols
                if any(v == ["InTissue" "InAnalysis" "Segmented" "TouchesEdge"])
                    T.(v) = false(height(T), 1);
                else
                    T.(v) = nan(height(T), 1);
                end
            end
            if any(reuse)
                for v = keepCols
                    T.(v)(reuse) = Prev.(v)(prevRow(reuse));
                end
            end
            rec = struct();
            if isstruct(old), rec = old; end
            needImage = ~isempty(todo) || ~sameBasis;
            if needImage
                tag = char(src.ImagePath) + "|" + surfHash + "|" + um;
                if isstruct(loaded) && isfield(loaded, 'Tag') && loaded.Tag == tag
                    pages = loaded.Pages;
                    Sf = loaded.Surface;
                else
                    say("Reading the image");
                    [pages, umImg] = P.readPages(src);
                    if ~isfinite(um) || um <= 0, um = umImg; end
                    say("Finding the brain surface");
                    Sf = cellanalysis.Surface.detect(pages, um, P.surfaceOpts(def));
                    loaded = struct('Tag', tag, 'Pages', {pages}, 'Surface', Sf);
                end
                pg = P.pageOf(src, numel(pages));
                otherPage = 0;
                if numel(pages) >= 2
                    rest = setdiff(1:numel(pages), pg);
                    otherPage = rest(1);
                end
                valid = [];
                if Sf.TissueFraction < 1
                    valid = cellanalysis.Surface.tissueFull(Sf, 10);
                end
                st = cellanalysis.Measure.pageStats(pages{pg}, valid);
                other = [];
                ost = [];
                if otherPage > 0
                    other = pages{otherPage};
                    ost = cellanalysis.Measure.pageStats(other, valid);
                end
                if ~isempty(todo)
                    say(sprintf("Measuring %d cells", numel(todo)));
                    xy = [T.X(todo), T.Y(todo)];
                    M = cellanalysis.Measure.cells(pages{pg}, xy, um, src.Kind, ...
                        struct('Other', other, 'Valid', valid, 'PageStats', st, 'OtherStats', ost));
                    for v = names
                        T.(v)(todo) = M.(v);
                    end
                    T.Segmented(todo) = M.Segmented;
                    T.TouchesEdge(todo) = M.TouchesEdge;
                    T.SurfaceDistUm(todo) = cellanalysis.Surface.distanceAt(Sf, xy);
                    T.InTissue(todo) = cellanalysis.Surface.inTissue(Sf, xy);
                    T.InAnalysis(todo) = curation.Regions.inAnalysis(meta.Regions, xy, src.Key);
                    nrm = cellanalysis.Surface.normalAt(Sf, xy);
                    th = T.OrientationDeg(todo);
                    ax = [cosd(th), -sind(th)];                 % image axes: y down
                    T.AxisToSurfaceDeg(todo) = acosd(min(1, abs(sum(ax .* nrm, 2))));
                end
                edges = 0:P.DEPTH_STEP_UM:P.DEPTH_MAX_UM;
                [area, edges] = cellanalysis.Surface.depthArea(Sf, edges, P.regionPolys(meta.Regions, src.Key));
                last = find(area > 0, 1, 'last');
                if isempty(last), last = 0; end
                rec.depthEdgesUm = edges(1:last + 1);
                rec.depthAreaUm2 = area(1:last);
                rec.surfaceOk = Sf.Ok;
                rec.surfaceMessage = char(Sf.Message);
                rec.tissueFraction = Sf.TissueFraction;
                rec.tissueMedian = st.Median;
                rec.tissueMad = st.Mad;
            end

            % ---- write ----------------------------------------------------------------------------
            say("Writing the measurements");
            T = T(:, [C.Properties.VariableNames(1:8), {'InTissue', 'InAnalysis', 'SurfaceDistUm', 'AxisToSurfaceDeg'}, ...
                cellstr(names), {'Segmented', 'TouchesEdge'}]);
            P.writeMetrics(src.MetricsPath, T);
            [~, nm, ex] = fileparts(char(src.MetricsPath));
            rec.metricsFile = [nm ex];
            rec.measuredAt = curation.AtomicIO.isoNow(false);
            rec.versions = cellstr(versions);
            rec.cells = height(T);
            rec.kept = nnz(T.Kept);
            rec.measuredNow = numel(todo);
            rec.umPerPixel = um;
            rec.image = imgStamp;
            rec.locs = P.stamp(meta.LocsFile);
            rec.curation = P.stamp(meta.CurationCsv);
            rec.journalBytes = P.bytesOf(meta.Journal);
            rec.surfaceHash = char(surfHash);
            rec.regionsHash = char(regHash);
            key = char(src.Key);
            function J = upd(J)
                J = cellanalysis.Project.blankJson(J);
                J.sources.(matlab.lang.makeValidName(key)) = rec;
                J.sources.(matlab.lang.makeValidName(key)).key = key;
            end
            curation.AtomicIO.updateJson(char(src.JsonPath), @upd);
        end

        function [C, meta] = cellsOf(mf, key)
            %CELLSOF  The cells of a source to measure, from its curation store (read-only).
            %   C: CellID, X, Y, score, rescore, Label, Reviewed, Kept. meta: UmPerPixel,
            %   ImageSize, Regions, LocsFile, CurationCsv, Journal.
            st = curation.Store.open(mf, char(key), struct('ReadOnly', true, 'AutosaveDelay', Inf));
            done = onCleanup(@() cellanalysis.Project.closeStore(st));
            A = st.T;
            kept = st.keptMask();
            use = A.State == "active" & ~A.Excluded & isfinite(A.X) & isfinite(A.Y);
            C = table(double(A.CellID(use)), A.X(use), A.Y(use), A.score(use), A.rescore(use), ...
                string(A.Label(use)), logical(A.Reviewed(use)), logical(kept(use)), ...
                'VariableNames', {'CellID', 'X', 'Y', 'score', 'rescore', 'Label', 'Reviewed', 'Kept'});
            meta = struct('UmPerPixel', double(st.Meta.UmPerPixel), 'ImageSize', double(st.Meta.ImageSize), ...
                'Regions', st.regions(), 'LocsFile', string(st.Meta.LocsFile), ...
                'CurationCsv', string(st.Paths.csv), 'Journal', string(st.Paths.journal));
        end

        % ======================================================================= load
        function [C, Sec] = load(S, kind, opts)
            %LOAD  The measured cells of every source of one kind, with their tags (class help).
            if nargin < 3 || isempty(opts), opts = struct(); end
            population = "kept";
            if isfield(opts, 'Population') && ~isempty(opts.Population), population = lower(string(opts.Population)); end
            colocUm = 10;
            if isfield(opts, 'ColocUm') && ~isempty(opts.ColocUm), colocUm = double(opts.ColocUm); end
            minDepth = 0;
            if isfield(opts, 'MinDepthUm') && ~isempty(opts.MinDepthUm)
                minDepth = double(opts.MinDepthUm);
                if ~(isscalar(minDepth) && isfinite(minDepth) && minDepth >= 0)
                    error('cellanalysis:Project:badOption', 'MinDepthUm must be a finite number of micrometers, 0 or more.');
                end
            end
            P = cellanalysis.Project;
            kind = string(kind);
            sel = find((S.Kind == kind | S.Key == kind) & S.State ~= "none");
            parts = cell(numel(sel), 1);
            factors = P.factors(S);
            Sec = table(zeros(0, 1), zeros(0, 1), strings(0, 1), zeros(0, 1), zeros(0, 1), zeros(0, 1), zeros(0, 1), ...
                'VariableNames', {'SourceRow', 'Cells', 'OtherKey', 'OtherCells', 'Pairs', 'TissueMm2', 'NearSurface'});
            cache = containers.Map('KeyType', 'char', 'ValueType', 'any');
            function [M, near] = metricsOf(row)
                k = char(S.MetricsPath(row));
                if ~isKey(cache, k)
                    [Mk, nk] = P.pick(P.readMetrics(k), population, minDepth);
                    cache(k) = struct('T', Mk, 'Near', nk);
                end
                e = cache(k);
                M = e.T;
                near = e.Near;
            end
            for q = 1:numel(sel)
                i = sel(q);
                try
                    [T, nNear] = metricsOf(i);
                catch
                    continue
                end
                um = P.umOf(S(i, :));
                % the other channel of the same section, same population
                oxy = zeros(0, 2);
                oid = zeros(0, 1);
                otherKey = "";
                others = find(S.Dataset == S.Dataset(i) & S.Folder == S.Folder(i) & S.Key ~= S.Key(i) & S.State ~= "none");
                if ~isempty(others)
                    diffKind = others(S.Kind(others) ~= S.Kind(i));
                    if ~isempty(diffKind), others = diffKind; end
                    try
                        O = metricsOf(others(1));
                        oxy = [O.X, O.Y];
                        oid = O.CellID;
                        otherKey = S.Key(others(1));
                    catch
                    end
                end
                Sp = cellanalysis.Measure.spatial([T.X, T.Y], um, oxy);
                T.NnUm = Sp.NnUm;
                T.LocalDensity = Sp.LocalDensity;
                T.OtherDistUm = Sp.OtherDistUm;
                n = height(T);
                T.Colocalized = nan(n, 1);
                T.ColocChance = nan(n, 1);
                T.PartnerID = nan(n, 1);
                pairs = NaN;
                if strlength(otherKey) > 0
                    Co = cellanalysis.Measure.colocalize([T.X, T.Y], oxy, um, struct('MaxUm', colocUm));
                    T.Colocalized = double(Co.Colocalized);
                    T.ColocChance = Co.Chance;
                    T.PartnerID(Co.Colocalized) = oid(Co.Partner(Co.Colocalized));
                    pairs = nnz(Co.Colocalized);
                end
                Sec(end + 1, :) = {i, n, otherKey, size(oxy, 1), pairs, P.tissueMm2(S(i, :), minDepth), nNear}; %#ok<AGROW>
                T.Dataset = repmat(S.Dataset(i), n, 1);
                T.Key = repmat(S.Key(i), n, 1);
                for f = factors
                    T.(f) = repmat(S.(f)(i), n, 1);
                end
                T.SourceRow = repmat(i, n, 1);
                parts{q} = T;
            end
            parts = parts(~cellfun(@isempty, parts));
            if isempty(parts)
                C = table();
                return
            end
            C = vertcat(parts{:});
            Sec = Sec(Sec.Cells > 0 | Sec.OtherCells > 0 | Sec.NearSurface > 0, :);
            lead = [{'Dataset', 'Key'}, cellstr(factors), {'SourceRow'}];
            C = C(:, [lead, setdiff(C.Properties.VariableNames, lead, 'stable')]);
        end

        function [T, near] = pick(T, population, minDepthUm)
            %PICK  The cells of a metrics table that take part (see the class help): those of the
            %   population ("kept" | "all"), without the ones closer than minDepthUm to the brain
            %   surface. A cell without a distance (no surface) is kept. near: the cells rejected
            %   for their distance.
            if nargin < 3 || isempty(minDepthUm), minDepthUm = 0; end
            if string(population) == "kept"
                T = T(T.Kept, :);
            end
            near = 0;
            if minDepthUm > 0 && ismember('SurfaceDistUm', T.Properties.VariableNames)
                within = T.SurfaceDistUm < minDepthUm;
                near = nnz(within);
                T = T(~within, :);
            end
        end

        function f = factors(S)
            %FACTORS  The columns of S a plot can be grouped by: the fixed ones and the imported.
            f = cellanalysis.Project.FIXED_FACTORS;
            known = string(cellanalysis.Project.emptySources().Properties.VariableNames);
            extra = setdiff(string(S.Properties.VariableNames), [known, f], 'stable');
            f = [f, reshape(extra, 1, [])];
            f = f(ismember(f, string(S.Properties.VariableNames)));
        end

        % ======================================================================= lab database
        function S = readDatabase(S)
            %READDATABASE  What this computer's cache of the lab database says about each subject:
            %   Sex, Species, DbProject, DbTags, DbVariables and one column per tag namespace, bare
            %   tag and variable (see the class help, DATABASE). Columns of an earlier call are
            %   replaced. Never the network, never an error.
            old = cellanalysis.Project.databaseColumns(S);
            for v = reshape(old.Name, 1, [])
                if ismember(v, string(S.Properties.VariableNames)), S.(v) = []; end
            end
            S.Properties.UserData = struct('DatabaseColumns', cellanalysis.Project.noDatabaseColumns());
            if height(S) == 0, return; end
            S.Sex(:) = ""; S.Species(:) = ""; S.DbProject(:) = ""; S.DbTags(:) = ""; S.DbVariables(:) = "";
            ids = unique(S.Subject(strlength(S.Subject) > 0));
            if isempty(ids), return; end
            try
                I = celldb.subjectInfo(ids);
                [W, info] = celldb.subjectFactors(ids);
            catch
                return
            end
            for k = 1:height(I)
                m = S.Subject == I.subject_id(k);
                S.DbTags(m) = I.tags(k);
                S.DbVariables(m) = I.variables(k);
                if ~I.known(k), continue; end
                S.Sex(m) = I.sex(k);
                S.Species(m) = I.species(k);
                S.DbProject(m) = I.project(k);
            end
            taken = string(S.Properties.VariableNames);
            keep = true(height(info), 1);
            for c = 1:height(info)
                name = info.Name(c);
                if ismember(name, taken), keep(c) = false; continue; end
                col = W.(name);
                if isnumeric(col)
                    v = nan(height(S), 1);
                else
                    v = strings(height(S), 1);
                end
                for k = 1:height(W)
                    v(S.Subject == W.subject_id(k)) = col(k);
                end
                S.(name) = v;
            end
            S.Properties.UserData = struct('DatabaseColumns', info(keep, :));
        end

        function D = databaseColumns(S)
            %DATABASECOLUMNS  The lab database columns of a sources table (celldb.subjectFactors'
            %   second output: Name, Label, Source, Type, Units, Key, Meaning); no rows when none.
            D = cellanalysis.Project.noDatabaseColumns();
            try
                u = S.Properties.UserData;
                if isstruct(u) && isfield(u, 'DatabaseColumns') && istable(u.DatabaseColumns)
                    D = u.DatabaseColumns;
                    D = D(ismember(D.Name, string(S.Properties.VariableNames)), :);
                end
            catch
            end
        end

        % ======================================================================= groups
        function G = readGroups(parentDir)
            %READGROUPS  The user's groupings below parentDir: a table of text columns Dataset,
            %   Subject, Group and any imported ones (no rows when there is no file).
            G = table(strings(0, 1), strings(0, 1), strings(0, 1), 'VariableNames', {'Dataset', 'Subject', 'Group'});
            f = fullfile(char(parentDir), cellanalysis.Project.GROUPS_FILE);
            if ~isfile(f), return; end
            try
                o = detectImportOptions(f, 'Delimiter', ',', 'VariableNamingRule', 'preserve', 'TextType', 'string');
                o = setvartype(o, 'string');
                R = readtable(f, o);
            catch
                return
            end
            for v = string(R.Properties.VariableNames)
                R.(v) = fillmissing(strtrim(string(R.(v))), 'constant', "");
            end
            for v = ["Dataset" "Subject" "Group"]
                if ~ismember(v, string(R.Properties.VariableNames)), R.(v) = strings(height(R), 1); end
            end
            valid = matlab.lang.makeValidName(R.Properties.VariableNames);
            R.Properties.VariableNames = matlab.lang.makeUniqueStrings(valid);
            G = R;
        end

        function writeGroups(parentDir, G)
            %WRITEGROUPS  Write the groupings file (deleted when it would hold nothing).
            f = fullfile(char(parentDir), cellanalysis.Project.GROUPS_FILE);
            extra = setdiff(string(G.Properties.VariableNames), ["Dataset" "Subject"], 'stable');
            used = false(height(G), 1);
            for v = extra
                used = used | strlength(G.(v)) > 0;
            end
            G = G(used, :);
            if isempty(G)
                if isfile(f), delete(f); end
                return
            end
            tmp = [f '.tmp'];
            writetable(G, tmp, 'FileType', 'text', 'Delimiter', ',', 'QuoteStrings', true);
            movefile(tmp, f, 'f');
        end

        function G = setGroup(G, S, rows, value, factor)
            %SETGROUP  Give the datasets of S(rows) the value VALUE of FACTOR (default "Group").
            if nargin < 5 || strlength(string(factor)) == 0, factor = "Group"; end
            factor = string(matlab.lang.makeValidName(char(factor)));
            if ~ismember(factor, string(G.Properties.VariableNames))
                G.(factor) = strings(height(G), 1);
            end
            value = strtrim(string(value));
            ds = unique(S.Dataset(rows), 'stable');
            for d = reshape(ds, 1, [])
                r = find(G.Dataset == d, 1);
                if isempty(r)
                    r = height(G) + 1;
                    G(r, :) = repmat({""}, 1, width(G));
                    G.Dataset(r) = d;
                    i = find(S.Dataset == d, 1);
                    G.Subject(r) = S.Subject(i);
                end
                G.(factor)(r) = value;
            end
        end

        function [G, rep] = importGroups(G, S, file)
            %IMPORTGROUPS  Take groupings from a CSV or spreadsheet: a table with one column that
            %   names the subject ("Subject", "SubjectID", "subject_id", "Animal") or the section
            %   ("Dataset", "Section", "Image Filename", "File"); every other column becomes a
            %   grouping. A row applies to every dataset of its subject, or to the dataset whose
            %   name starts with (or equals) its file name without extension and suffix.
            %   rep: struct matched (datasets), unmatched (rows of the file), factors, message.
            rep = struct('matched', 0, 'unmatched', 0, 'factors', strings(1, 0), 'message', "");
            [~, ~, ext] = fileparts(char(file));
            if strcmpi(ext, '.csv')
                o = detectImportOptions(char(file), 'Delimiter', ',', 'VariableNamingRule', 'preserve', 'TextType', 'string');
            else
                o = detectImportOptions(char(file), 'VariableNamingRule', 'preserve', 'TextType', 'string');
            end
            o = setvartype(o, 'string');
            R = readtable(char(file), o);
            names = string(R.Properties.VariableNames);
            low = lower(regexprep(names, '[\s_\-#]', ''));
            kSub = find(ismember(low, ["subject" "subjectid" "animal" "animalid"]), 1);
            kSec = find(ismember(low, ["dataset" "section" "imagefilename" "file" "filename" "image"]), 1);
            if isempty(kSub) && isempty(kSec)
                error('cellanalysis:Project:noKeyColumn', ['The file has no column that names the subject ' ...
                    '(Subject, SubjectID, Animal) or the section (Dataset, Section, Image Filename, File).']);
            end
            keyCols = [kSub, kSec];
            facCols = setdiff(1:numel(names), keyCols, 'stable');
            ds = unique(S(:, {'Dataset', 'Subject'}), 'rows', 'stable');
            hit = false(height(ds), 1);
            used = false(height(R), 1);
            for r = 1:height(R)
                m = false(height(ds), 1);
                if ~isempty(kSec)
                    v = strtrim(R{r, kSec});
                    if ~ismissing(v) && strlength(v) > 0
                        [~, stem] = fileparts(char(v));
                        stem = regexprep(stem, '(_proj|_mid|_composite)$', '');
                        m = ds.Dataset == string(v);
                        if ~isempty(stem), m = m | startsWith(ds.Dataset, string(stem)); end
                    end
                end
                if ~any(m) && ~isempty(kSub)
                    v = strtrim(R{r, kSub});
                    if ~ismissing(v) && strlength(v) > 0
                        m = ds.Subject == v | ds.Subject == "SUBJ-ID-" + v | extractAfter(ds.Subject, "SUBJ-ID-") == v;
                        m(ismissing(m)) = false;
                    end
                end
                if ~any(m), continue; end
                used(r) = true;
                hit = hit | m;
                for c = facCols
                    val = R{r, c};
                    if ismissing(val), val = ""; end
                    fac = names(c);
                    if lower(fac) == "group", fac = "Group"; end
                    G = cellanalysis.Project.setGroup(G, ds, find(m), val, fac);
                end
            end
            fac = names(facCols);
            fac(lower(fac) == "group") = "Group";
            rep.factors = string(matlab.lang.makeValidName(cellstr(fac)));
            rep.matched = nnz(hit);
            rep.unmatched = nnz(~used);
            rep.message = sprintf("Groupings read for %d of %d sections (%d rows of the file matched nothing): %s.", ...
                rep.matched, height(ds), rep.unmatched, strjoin(rep.factors, ", "));
        end

        function [S, factors] = applyGroups(S, G)
            %APPLYGROUPS  Put the groupings of G on the sources (Group and the imported columns).
            %   A row of G belongs to the dataset it names; a row without a dataset to every
            %   dataset of its subject.
            extra = setdiff(string(G.Properties.VariableNames), ["Dataset" "Subject"], 'stable');
            known = string(cellanalysis.Project.emptySources().Properties.VariableNames);
            known = [known, reshape(cellanalysis.Project.databaseColumns(S).Name, 1, [])];
            for v = extra
                if ismember(v, known) && v ~= "Group", continue; end   % never overwrite a column of the scan
                S.(v) = strings(height(S), 1);
                for r = 1:height(G)
                    if strlength(G.(v)(r)) == 0, continue; end
                    if strlength(G.Dataset(r)) > 0
                        m = S.Dataset == G.Dataset(r);
                    else
                        m = S.Subject == G.Subject(r) & strlength(S.Subject) > 0;
                    end
                    S.(v)(m) = G.(v)(r);
                end
            end
            if ~ismember("Group", string(S.Properties.VariableNames)), S.Group = strings(height(S), 1); end
            factors = cellanalysis.Project.factors(S);
        end

        % ======================================================================= files
        function T = readMetrics(path)
            %READMETRICS  Read a metrics file written by measure (types fixed by column name).
            %   A file that did not change since it was last read comes from memory (at most
            %   CACHE_FILES files are kept; cellanalysis.Project.clearCache empties it).
            path = char(path);
            d = dir(path);
            if isempty(d), error('cellanalysis:Project:noMetrics', 'Cannot read %s.', path); end
            stampNow = sprintf('%d|%.10f', d(1).bytes, d(1).datenum);
            cache = cellanalysis.Project.metricsCache();
            if isKey(cache, path)
                e = cache(path);
                if strcmp(e.Stamp, stampNow)
                    T = e.Table;
                    return
                end
            end
            T = cellanalysis.Project.readMetricsFile(path);
            if cache.Count >= cellanalysis.Project.CACHE_FILES
                remove(cache, cache.keys);
            end
            cache(path) = struct('Stamp', stampNow, 'Table', T);
        end

        function clearCache()
            %CLEARCACHE  Forget the metrics files kept in memory.
            cache = cellanalysis.Project.metricsCache();
            remove(cache, cache.keys);
        end

        function T = readMetricsFile(path)
            %READMETRICSFILE  Read a metrics file from disk (no cache).
            path = char(path);
            fid = fopen(path, 'r', 'n', 'UTF-8');
            if fid < 0, error('cellanalysis:Project:noMetrics', 'Cannot read %s.', path); end
            header = fgetl(fid);
            fclose(fid);
            if ~ischar(header), error('cellanalysis:Project:noMetrics', '%s is empty.', path); end
            names = strsplit(strtrim(header), ',');
            o = delimitedTextImportOptions('NumVariables', numel(names), 'Delimiter', ',', 'DataLines', [2 Inf], ...
                'VariableNamingRule', 'preserve', 'Encoding', 'UTF-8');
            o.VariableNames = names;
            types = repmat({'double'}, 1, numel(names));
            types(strcmp(names, 'Label')) = {'string'};
            o.VariableTypes = types;
            o.ExtraColumnsRule = 'ignore';
            o.EmptyLineRule = 'skip';
            T = readtable(path, o);
            if ismember('Label', names), T.Label = fillmissing(T.Label, 'constant', ""); end
            for v = ["Reviewed" "Kept" "InTissue" "InAnalysis" "Segmented" "TouchesEdge"]
                if ismember(v, string(names)), T.(v) = T.(v) == 1; end
            end
        end

        function writeMetrics(path, T)
            %WRITEMETRICS  Write a metrics table in one step (temporary file, then rename).
            path = char(path);
            W = T;
            for v = string(W.Properties.VariableNames)
                if islogical(W.(v)), W.(v) = double(W.(v)); end
            end
            [folder, nm, ex] = fileparts(path);
            tmp = fullfile(folder, ['.' nm ex '.tmp']);
            writetable(W, tmp, 'FileType', 'text', 'Delimiter', ',', 'QuoteStrings', false);
            movefile(tmp, path, 'f');
            cache = cellanalysis.Project.metricsCache();
            if isKey(cache, path), remove(cache, path); end
        end

        function p = metricsPathFor(mf, key)
            %METRICSPATHFOR  '<folder of the locs>/<stem>_metrics.csv' of a source.
            c = mf.curationPath(char(key));
            if isempty(c)
                p = fullfile(mf.Folder, [mf.Base '_' char(key) cellanalysis.Project.METRICS_TAIL]);
            else
                p = regexprep(c, '_curation\.csv$', cellanalysis.Project.METRICS_TAIL);
            end
        end

        function v = versions()
            %VERSIONS  The code versions a measurement depends on.
            v = [cellanalysis.Project.VERSION, cellanalysis.Measure.VERSION, cellanalysis.Surface.VERSION];
        end

    end

    methods (Static, Access = private)

        function D = noDatabaseColumns()
            D = table(strings(0, 1), strings(0, 1), strings(0, 1), strings(0, 1), strings(0, 1), strings(0, 1), ...
                strings(0, 1), 'VariableNames', {'Name', 'Label', 'Source', 'Type', 'Units', 'Key', 'Meaning'});
        end

        function c = metricsCache()
            persistent cache
            if isempty(cache), cache = containers.Map('KeyType', 'char', 'ValueType', 'any'); end
            c = cache;
        end

        function src = one(src)
            if istable(src)
                if height(src) ~= 1
                    error('cellanalysis:Project:oneSource', 'Give one source (one row of the sources table).');
                end
                src = table2struct(src);
            end
            if iscell(src.Mf), src.Mf = src.Mf{1}; end
        end

        function mf = mfOf(S, i)
            mf = S.Mf(i);
            if iscell(mf), mf = mf{1}; end
        end

        function closeStore(st)
            try
                if isvalid(st), st.close(); end
            catch
            end
        end

        function J = readJson(path)
            J = struct();
            path = char(path);
            if ~isfile(path), return; end
            try
                x = jsondecode(fileread(path));
                if isstruct(x) && isscalar(x), J = x; end
            catch
            end
        end

        function J = blankJson(J)
            if ~isstruct(J) || ~isscalar(J), J = struct(); end
            J.schema = cellanalysis.Project.SCHEMA;
            if ~isfield(J, 'surface') || ~isstruct(J.surface), J.surface = struct(); end
            if ~isfield(J.surface, 'mode') || isempty(J.surface.mode), J.surface.mode = 'auto'; end
            for g = ["line" "include" "exclude"]
                if ~isfield(J.surface, g), J.surface.(g) = zeros(0, 2); end
            end
            if ~isfield(J, 'sources') || ~isstruct(J.sources), J.sources = struct(); end
        end

        function def = defOf(J)
            def = struct('mode', "auto", 'line', zeros(0, 2), 'include', zeros(0, 2), 'exclude', zeros(0, 2));
            if ~isfield(J, 'surface') || ~isstruct(J.surface), return; end
            if isfield(J.surface, 'mode') && ~isempty(J.surface.mode)
                m = lower(string(J.surface.mode));
                if any(m == cellanalysis.Surface.MODES), def.mode = m; end
            end
            for g = ["line" "include" "exclude"]
                if ~isfield(J.surface, g) || isempty(J.surface.(g)), continue; end
                l = J.surface.(g);
                if iscell(l)
                    l = cell2mat(cellfun(@(c) double(c(:))', l(:), 'UniformOutput', false));
                end
                l = double(l);
                if size(l, 2) ~= 2 && numel(l) == 2, l = reshape(l, 1, 2); end
                if size(l, 2) == 2, def.(g) = l; end
            end
        end

        function rec = recordOf(J, key)
            rec = [];
            f = matlab.lang.makeValidName(char(key));
            if isfield(J, 'sources') && isstruct(J.sources) && isfield(J.sources, f) && isstruct(J.sources.(f))
                rec = J.sources.(f);
            end
        end

        function [state, measured] = stateOf(r, rec, def, mf)
            %stateOf  "none" | "current" | "stale" from the record and the files as they are now.
            P = cellanalysis.Project;
            state = "none";
            measured = NaN;
            if ~isstruct(rec) || ~isfile(r.MetricsPath), return; end
            if isfield(rec, 'cells'), measured = double(rec.cells); end
            state = "stale";
            if ~isfield(rec, 'versions') || ~isequal(reshape(string(rec.versions), 1, []), P.versions()), return; end
            if ~isfield(rec, 'surfaceHash') || string(rec.surfaceHash) ~= P.surfaceHash(def), return; end
            if ~isfield(rec, 'image') || ~P.sameStamp(rec.image, P.stamp(r.ImagePath)), return; end
            cur = mf.curationPath(char(r.Key));
            if ~isfield(rec, 'curation') || ~P.sameStamp(rec.curation, P.stamp(cur)), return; end
            if ~isfield(rec, 'journalBytes') || double(rec.journalBytes) ~= P.bytesOf(regexprep(cur, '\.csv$', '.journal.csv')), return; end
            if isfield(rec, 'locs') && isstruct(rec.locs) && isfield(rec.locs, 'name') && ~isempty(rec.locs.name)
                locs = fullfile(fileparts(char(r.MetricsPath)), char(rec.locs.name));
                if ~P.sameStamp(rec.locs, P.stamp(locs)), return; end
            end
            state = "current";
        end

        function s = stamp(path)
            %stamp  name, bytes and modification time of a file ('' / 0 / '' when it is not there).
            s = struct('name', '', 'bytes', 0, 'modified', '');
            path = char(path);
            if isempty(path), return; end
            d = dir(path);
            if isempty(d) || d(1).isdir, return; end
            s.name = d(1).name;
            s.bytes = d(1).bytes;
            s.modified = char(datetime(d(1).datenum, 'ConvertFrom', 'datenum', 'Format', 'yyyy-MM-dd''T''HH:mm:ss'));
        end

        function tf = sameStamp(a, b)
            tf = isstruct(a) && isstruct(b) && isfield(a, 'bytes') && isfield(a, 'modified') && isfield(a, 'name') ...
                && strcmp(char(a.name), char(b.name)) && double(a.bytes) == double(b.bytes) ...
                && strcmp(char(a.modified), char(b.modified));
        end

        function n = bytesOf(path)
            n = 0;
            d = dir(char(path));
            if ~isempty(d) && ~d(1).isdir, n = d(1).bytes; end
        end

        function h = regionsHash(regions, key)
            %regionsHash  Changes when a region that decides area or "in analysis" changes.
            txt = "";
            for i = 1:numel(regions)
                g = regions(i);
                if ~any(g.kind == ["exclude" "analysis"]), continue; end
                if ~(g.scope == "image" || g.scope == string(key)), continue; end
                txt = txt + sprintf("%s:%d:%.6g:%.6g;", g.kind, size(g.xy, 1), sum(g.xy(:)), sum(g.xy(:) .* (1:numel(g.xy))'));
            end
            h = txt;
        end

        function o = regionPolys(regions, key)
            o = struct('Exclude', {{}}, 'Include', {{}});
            for i = 1:numel(regions)
                g = regions(i);
                if ~(g.scope == "image" || g.scope == string(key)), continue; end
                if g.kind == "exclude"
                    o.Exclude{end + 1} = g.xy;
                elseif g.kind == "analysis"
                    o.Include{end + 1} = g.xy;
                end
            end
        end

        function [pages, um, otherPage] = readPages(src)
            %readPages  Every page of the section's image, the pixel size, and the page of the
            %   other channel (0 when the image has one page).
            img = char(src.ImagePath);
            if isempty(img) || ~isfile(img)
                error('cellanalysis:Project:noImage', 'The image of %s (%s) is not there: %s', ...
                    src.Dataset, src.Key, img);
            end
            n = CellToolkit.countPages(img);
            pages = cell(n, 1);
            for p = 1:n
                pg = CellToolkit.readPage(img, p, n);
                if ndims(pg) == 3, pg = mean(double(pg), 3); end
                pages{p} = pg;
            end
            pg = cellanalysis.Project.pageOf(src, n);
            um = CellToolkit.tiffPixelSizeUm(img, pg);
            if ~isfinite(um), um = cellanalysis.Project.umOf(src); end
            otherPage = 0;
            if n >= 2
                rest = setdiff(1:n, pg);
                otherPage = rest(1);
            end
        end

        function pg = pageOf(src, nPages)
            pg = double(src.Page);
            if ~isfinite(pg) || pg < 1, pg = 1; end
            pg = min(round(pg), nPages);
        end

        function um = umOf(src)
            %umOf  The pixel size the measurement used (the record), else the TIFF's, else the default.
            if istable(src), src = table2struct(src); end
            um = NaN;
            rec = cellanalysis.Project.recordOf(cellanalysis.Project.readJson(src.JsonPath), src.Key);
            if isstruct(rec) && isfield(rec, 'umPerPixel'), um = double(rec.umPerPixel); end
            if ~isfinite(um) || um <= 0
                um = CellToolkit.tiffPixelSizeUm(char(src.ImagePath), max(1, double(src.Page)));
            end
            if ~isfinite(um) || um <= 0, um = CellDatasetManifest.DEFAULT_UM_PER_PIXEL; end
        end

        function a = tissueMm2(src, minDepthUm)
            %tissueMm2  Tissue area of the source's section (mm^2) from its record, without the
            %   tissue closer than minDepthUm to the surface; NaN when the section has no brain
            %   surface (the area is counted by depth).
            if nargin < 2, minDepthUm = 0; end
            if istable(src), src = table2struct(src); end
            a = NaN;
            rec = cellanalysis.Project.recordOf(cellanalysis.Project.readJson(src.JsonPath), src.Key);
            if isstruct(rec) && isfield(rec, 'depthAreaUm2') && ~isempty(rec.depthAreaUm2)
                area = double(rec.depthAreaUm2(:))';
                if minDepthUm > 0 && isfield(rec, 'depthEdgesUm') && numel(rec.depthEdgesUm) == numel(area) + 1
                    area = cellanalysis.Stats.areaBeyond(rec.depthEdgesUm, area, minDepthUm);
                end
                a = sum(area) / 1e6;
            end
        end

    end
end

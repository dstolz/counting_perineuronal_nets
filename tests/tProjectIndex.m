classdef tProjectIndex < matlab.unittest.TestCase
    %TPROJECTINDEX  curation.ProjectIndex over a synthetic multi-section, multi-animal project:
    %   discovery, animal ids, unlabelled sources, labels written through curation.Store appearing
    %   after refresh (journal replay and snapshot), the feature cache, PriorLabel from the
    %   journal, and that nothing is ever written inside the data folders.
    %   Run: pwsh -File tools\Run-Tests.ps1 tProjectIndex

    properties
        Pristine    % folder with the synthetic project (built once)
        Parent      % per-test copy of it
        Cache       % per-test cache folder (outside the data)
        Truth       % struct: per dataset truth (by base)
    end

    properties (Constant)
        % folder (relative to the project) and dataset base name of each synthetic section
        LAYOUT = [ ...
            "SUBJ-ID-9001/sec1", "SUBJ-ID-9001IHC_sec1"; ...
            "SUBJ-ID-9001/sec2", "SUBJ-ID-9001IHC_sec2"; ...
            "SUBJ-ID-9002/sec1", "SUBJ-ID-9002IHC_sec1"; ...
            "SUBJ-ID-9003/a", "Slide3_sec1"; ...           % animal only in the folder name
            "misc", "SYN-0005_sec1"]                         % no animal id anywhere: the base
    end

    methods (TestClassSetup)
        function makeProject(tc)
            fx = tc.applyFixture(matlab.unittest.fixtures.TemporaryFolderFixture);
            tc.Pristine = fullfile(fx.Folder, 'project');
            L = tProjectIndex.LAYOUT;
            tr = struct();
            for k = 1:size(L, 1)
                [~, t] = makeSyntheticDataset(fullfile(tc.Pristine, L(k, 1)), 'BaseName', L(k, 2), ...
                    'Seed', 40 + k, 'Variants', false);
                tr.(matlab.lang.makeValidName(L(k, 2))) = t;
            end
            tc.Truth = tr;
        end
    end

    methods (TestMethodSetup)
        function copyProject(tc)
            fx = tc.applyFixture(matlab.unittest.fixtures.TemporaryFolderFixture);
            tc.Parent = fullfile(fx.Folder, 'data');
            copyfile(tc.Pristine, tc.Parent);
            tc.Cache = fullfile(fx.Folder, 'cache');
        end
    end

    methods
        function p = locs(tc, row, key)
            L = tProjectIndex.LAYOUT;
            p = fullfile(tc.Parent, L(row, 1), L(row, 2) + "_proj_" + key + "_locs.csv");
        end

        function s = openStore(tc, row, key)
            s = curation.Store.openCsv(char(tc.locs(row, key)), struct('AutosaveDelay', 0, 'ImportLegacy', false));
            tc.addTeardown(@() s.close());
        end

        function idx = buildIdx(tc, opts)
            if nargin < 2, opts = struct(); end
            opts.CacheDir = tc.Cache;
            idx = curation.ProjectIndex.build(tc.Parent, opts);
        end

        function L = listing(~, folder)
            d = dir(fullfile(folder, '**', '*'));
            d = d(~ismember({d.name}, {'.', '..'}));
            L = sort(string(fullfile({d.folder}, {d.name})) + "|" + string([d.bytes]) + "|" + ...
                string(arrayfun(@(x) sprintf('%.8f', x), [d.datenum], 'UniformOutput', false)))';
        end
    end

    methods (Static)
        function ids = errorIds(err)
            %errorIds  The identifiers of an error and of every cause (a future's error wraps the
            %   worker's).
            ids = string(err.identifier);
            c = {};
            try c = [c; err.cause(:)]; catch, end
            try c = [c; err.remotecause(:)]; catch, end
            for k = 1:numel(c)
                if ~isempty(c{k}), ids = [ids; tProjectIndex.errorIds(c{k})]; end %#ok<AGROW>
            end
        end
    end

    methods (Test)
        function buildsOverSectionsAndParsesAnimals(tc)
            rec = containers.Map('KeyType', 'double', 'ValueType', 'any');
            idx = tc.buildIdx(struct('Progress', @(k, n, name) recordCall(rec, k, n, name)));
            S = idx.Sources;
            tc.verifyEqual(height(S), 10, '5 datasets x 2 channels');
            calls = cell2mat(cellfun(@(c) c{1}, values(rec), 'UniformOutput', false)');
            names = string(cellfun(@(c) c{2}, values(rec), 'UniformOutput', false))';
            tc.verifyEqual(calls, [(1:10)' repmat(10, 10, 1)], 'Progress(k, n, name) once per source');
            tc.verifyEqual(names, S.SourceId);
            tc.verifyEqual(sort(unique(S.Kind))', ["pnn" "pv"]);
            tc.verifyEqual(numel(unique(S.Section)), 5);
            tc.verifyEqual(numel(unique(S.SourceId)), 10);
            an = @(base) unique(S.Animal(contains(S.Base, base)));
            tc.verifyEqual(an("SUBJ-ID-9001IHC_sec1"), "9001");
            tc.verifyEqual(an("SUBJ-ID-9001IHC_sec2"), "9001");
            tc.verifyEqual(an("SUBJ-ID-9002IHC_sec1"), "9002");
            tc.verifyEqual(an("Slide3_sec1"), "9003", 'animal from the folder name');
            tc.verifyEqual(an("SYN-0005_sec1"), "SYN-0005_sec1_proj", 'fallback: the dataset base');
            tc.verifyTrue(all(S.CompanionKey ~= ""), 'each source has the other channel as companion');
            tc.verifyEqual(S.CompanionKey(S.Key == "ECM1"), repmat("PV2", 5, 1));
            tc.verifyEqual(S.Page(S.Key == "PV2"), repmat(2, 5, 1));
            tc.verifyEqual(idx.Counters.FeatureComputations, 0, 'no labels: no features computed');
            sm = idx.summary();
            tc.verifyEqual(sm.Kind, ["pnn"; "pv"]);
            tc.verifyEqual(sm.Sources, [5; 5]);
            tc.verifyEqual(sm.Animals, [4; 4]);
            tc.verifyEqual(sm.Reviewed, [0; 0]);
            f = fieldnames(tc.Truth);
            nE = sum(cellfun(@(x) height(tc.Truth.(x).ECM1.locs), f));
            tc.verifyEqual(sm.Candidates(1), nE);
        end

        function sourcesWithoutSnapshotAreUnlabelled(tc)
            idx = tc.buildIdx();
            tc.verifyFalse(any(idx.Sources.HasSnapshot));
            [T, F] = idx.table("pv");
            tc.verifyEqual(height(T), size(F, 1));
            tc.verifyTrue(all(isnan(F), 'all'), 'no features computed for unlabelled sources');
            tc.verifyTrue(all(T.Label == "") && ~any(T.Reviewed) && all(T.State == "active"));
            t = tc.Truth.SUBJ_ID_9002IHC_sec1.PV2.locs;
            r = T(T.Base == "SUBJ-ID-9002IHC_sec1_proj", :);
            tc.verifyEqual(r.X, t.X);
            tc.verifyEqual(r.Y, t.Y);
            tc.verifyEqual(r.rescore, t.rescore);
            tc.verifyEqual(r.CellID, uint32((1:height(t))'), 'CellIDs 1..n in file order, as the store would');
            tc.verifyEqual(r.RowId, r.SourceId + "|" + string(r.CellID));
            [F, y] = idx.trainingSet("pv");
            tc.verifySize(F, [0 numel(curation.Features.names())]);
            tc.verifyEmpty(y);
        end

        function labelsFromStoreAppearAfterRefresh(tc)
            idx = tc.buildIdx();
            s = tc.openStore(1, "ECM1");
            ids = s.T.CellID;
            % journal only (no snapshot written since the labels): replayed by the index
            s.setLabel(ids(1:5), "Good", "human");
            s.setLabel(ids(6:8), "Bad", "human");
            s.setLabel(ids(9), "Uncertain", "human");
            rep = idx.refresh();
            tc.verifyEqual(sort(rep.Changed), ["SUBJ-ID-9001/sec1/SUBJ-ID-9001IHC_sec1_proj|ECM1"; ...
                "SUBJ-ID-9001/sec1/SUBJ-ID-9001IHC_sec1_proj|PV2"], ...
                'only the edited dataset is re-read (its two sources share the curation JSON)');
            tc.verifyEqual(rep.Recomputed, 1, 'ECM1 now has labels: features computed; PV2 has none');
            [F, y, g, sec, rid, isB] = idx.trainingSet("pnn");
            tc.verifyEqual(size(F, 1), 8, 'Good + Bad, not Uncertain');
            tc.verifyEqual(nnz(y), 5);
            tc.verifyEqual(unique(g), "9001");
            tc.verifyEqual(unique(sec), "SUBJ-ID-9001/sec1/SUBJ-ID-9001IHC_sec1_proj");
            tc.verifyEqual(rid, "SUBJ-ID-9001/sec1/SUBJ-ID-9001IHC_sec1_proj|ECM1|" + string(ids(1:8)));
            tc.verifyTrue(all(isB), '6th output: every training row may calibrate (finding 2)');
            tc.verifyTrue(all(isfinite(F(:, 5:7)), 'all'), 'image features present');
            % the snapshot written by close() gives the same rows
            s.setLabel(ids(10), "Bad", "blind");
            s.close();
            idx.refresh();
            T = idx.table("pnn");
            r = T(T.SourceId == "SUBJ-ID-9001/sec1/SUBJ-ID-9001IHC_sec1_proj|ECM1", :);
            tc.verifyEqual(r.Label(1:10), [repmat("Good", 5, 1); repmat("Bad", 3, 1); "Uncertain"; "Bad"]);
            tc.verifyEqual(r.LabelSource(10), "blind");
            [~, y2, ~, ~, ~, isB2] = idx.trainingSet("pnn");
            tc.verifyEqual(numel(y2), 9);
            tc.verifyTrue(all(isB2), 'a blind label does not make a row a calibration-only row');
            tc.verifyEqual(idx.summary().Reviewed(1), 10);
        end

        function featureCacheAvoidsRecomputation(tc)
            s = tc.openStore(3, "PV2");
            ids = s.T.CellID;
            s.setLabel(ids(1:20), "Good", "human");
            s.flush();
            idx1 = tc.buildIdx();
            tc.verifyEqual(idx1.Counters.FeatureComputations, 1);
            tc.verifyEqual(idx1.Counters.CacheHits, 0);
            F1 = idx1.trainingSet("pv");
            idx2 = tc.buildIdx();
            tc.verifyEqual(idx2.Counters.FeatureComputations, 0, 'second build: from the cache');
            tc.verifyEqual(idx2.Counters.CacheHits, 1);
            tc.verifyEqual(idx2.Counters.ImageReads, 0, 'the image is not even read');
            tc.verifyEqual(idx2.trainingSet("pv"), F1);
            % nothing changed: nothing re-read, nothing recomputed
            rep = idx2.refresh();
            tc.verifyEqual([rep.Reread rep.Recomputed], [0 0]);
            % a label change re-reads the source but keeps its features
            s.setLabel(ids(21), "Bad", "human");
            rep = idx2.refresh();
            tc.verifyEqual([rep.Reread rep.Recomputed], [1 0]);
            % a moved cell changes the fingerprint: recomputed once
            s.moveCell(ids(1), [s.T.X(1) + 3, s.T.Y(1)]);
            rep = idx2.refresh();
            tc.verifyEqual([rep.Reread rep.Recomputed], [1 1]);
            rep = idx2.refresh();
            tc.verifyEqual([rep.Reread rep.Recomputed], [0 0]);
        end

        function backgroundBuildSaysWhatItCannotRead(tc)
            % (integration pass C, defect 3c) thread workers (backgroundPool) cannot read TIFF files:
            % a build there silently got no features and a default pixel size. Now reading images on
            % a thread worker is an explicit error, and ReadImages=false builds without them.
            try
                pool = backgroundPool;
            catch err
                tc.assumeFail(['no background pool: ' err.message]);
            end
            s = tc.openStore(3, "PV2");
            ids = s.T.CellID;
            s.setLabel(ids(1:20), "Good", "human");
            s.flush();
            f = parfeval(pool, @curation.ProjectIndex.build, 1, char(tc.Parent), struct('CacheDir', tc.Cache));
            tc.assertTrue(wait(f, 'finished', 120), 'the build ended');
            tc.assertNotEmpty(f.Error, 'reading images on a thread worker is an error, not a silent gap');
            tc.verifyTrue(any(tProjectIndex.errorIds(f.Error) == "curation:ProjectIndex:imagesOnThread"), ...
                strjoin(tProjectIndex.errorIds(f.Error), ', '));
            % ReadImages=false: no image is read; no feature is computed and no pixel size guessed
            f = parfeval(pool, @curation.ProjectIndex.build, 1, char(tc.Parent), ...
                struct('CacheDir', tc.Cache, 'ReadImages', false));
            idx = fetchOutputs(f);
            tc.verifyEqual(idx.Counters.ImageReads, 0);
            tc.verifyEqual(idx.Counters.FeatureComputations, 0);
            i = find(contains(idx.Sources.SourceId, "SUBJ-ID-9002") & idx.Sources.Key == "PV2");
            tc.assertNumElements(i, 1);
            tc.verifyFalse(idx.Sources.HasFeatures(i), 'no cache yet: no features');
            tc.verifyFalse(any(idx.Sources.UmSource == "default"), 'no default pixel size assumed silently');
            tc.verifyEqual(idx.Sources.UmSource(i), "curation json", 'the pixel size the store recorded');
            tc.verifyTrue(any(contains(idx.Warnings, "ReadImages")), 'the warnings say why there are no features');
            % after a build in MATLAB's own thread (which caches the features) the background build
            % takes them from the cache
            idx1 = tc.buildIdx();
            tc.verifyEqual(idx1.Counters.FeatureComputations, 1);
            f = parfeval(pool, @curation.ProjectIndex.build, 1, char(tc.Parent), ...
                struct('CacheDir', tc.Cache, 'ReadImages', false));
            idx2 = fetchOutputs(f);
            tc.verifyTrue(idx2.Sources.HasFeatures(i), 'features from the cache');
            tc.verifyEqual(idx2.Counters.CacheHits, 1);
            tc.verifyEqual(idx2.trainingSet("pv"), idx1.trainingSet("pv"));
        end

        function sourceOnDemandAndModelPath(tc)
            idx = tc.buildIdx();
            L = tProjectIndex.LAYOUT;
            folder = fullfile(tc.Parent, L(4, 1));
            [F, T] = idx.source(folder, L(4, 2) + "_proj", "ECM1");
            tc.verifySize(F, [height(T), numel(curation.Features.names())]);
            tc.verifyEqual(unique(T.Animal), "9003");
            names = curation.Features.names();
            interior = F(:, names == "borderUm") > 25;
            tc.verifyTrue(all(isfinite(F(interior, 5:24)), 'all'), 'companion (PV2) features present');
            tc.verifyEqual(idx.Counters.FeatureComputations, 1);
            tc.verifyError(@() idx.source(folder, "nope", "ECM1"), 'curation:ProjectIndex:unknownSource');
            tc.verifyEqual(curation.ProjectIndex.modelPath(tc.Parent, "pnn"), ...
                fullfile(tc.Parent, '.cellcuration', 'assist_pnn.mat'));
        end

        function priorLabelOfConfirmAudit(tc)
            s = tc.openStore(2, "ECM1");
            ids = s.T.CellID;
            s.setLabel(ids(1:3), "Good", "confirmed");
            s.setAuditRole(ids(1:2), "confirm-audit");
            s.setLabel(ids(1), "Bad", "blind");      % disagrees
            s.setLabel(ids(2), "Good", "blind");     % agrees
            idx = tc.buildIdx();
            T = idx.table("pnn");
            r = T(T.Base == "SUBJ-ID-9001IHC_sec2_proj", :);
            tc.verifyEqual(r.PriorLabel(1:3), ["Good"; "Good"; ""]);
            tc.verifyEqual(r.Label(1:3), ["Bad"; "Good"; "Good"]);
            rep = curation.Audit.report(T);
            tc.verifyEqual(rep.Table.ConfirmAuditN, 2);
            tc.verifyEqual(rep.Table.ConfirmAuditDisagree, 1);
        end

        function trainingSetNeverNarrowsCalibrationToAuditRows(tc)
            % Finding 2: the 6th output was the blind mask (confirm-audit, catch and re-ask rows,
            % all chosen by label or disagreement) and the documented call passed it as
            % CalibrateOn, which collapsed P. Catch tiles (known non-cells) must not train at all.
            s = tc.openStore(1, "ECM1");
            ids = s.T.CellID;
            s.setLabel(ids(1:40), "Bad", "confirmed");
            s.setLabel(ids(41:60), "Good", "human");
            s.setAuditRole(ids(1:5), "confirm-audit");
            s.setLabel(ids(1:5), "Bad", "blind");
            s.setAuditRole(ids(6:8), "catch");
            s.setLabel(ids(6:8), "Good", "blind");              % failed attention checks
            s.setLabel(ids(61:63), "Good", "blind");            % disagreement re-asks
            s.close();
            idx = tc.buildIdx();
            [~, y, ~, ~, rid, cal] = idx.trainingSet("pnn");
            pre = "SUBJ-ID-9001/sec1/SUBJ-ID-9001IHC_sec1_proj|ECM1|";
            tc.verifyTrue(all(cal), sprintf(['the 6th output (rows admissible for CalibrateOn) selected ' ...
                'only %d of %d training rows'], nnz(cal), numel(cal)));
            tc.verifyFalse(any(ismember(rid, pre + string(ids(6:8)))), 'catch tiles never train');
            tc.verifyTrue(all(ismember(pre + string(ids([1:5 61:63])), rid)), ...
                'confirm-audit and re-ask rows train with their blind label');
            tc.verifyEqual(numel(y), 60 - 3 + 3);
        end

        function neighbourFeaturesIgnoreCurationState(tc)
            % nnUm / densityN counted only State "active" rows: a merge in one place changed the
            % features of other candidates. They count every detection in the locs (InLocs).
            s = tc.openStore(3, "PV2");
            ids = s.T.CellID;
            s.setLabel(ids(1:20), "Good", "human");
            s.flush();
            idx = tc.buildIdx();
            L = tProjectIndex.LAYOUT;
            folder = fullfile(tc.Parent, L(3, 1));
            F1 = idx.source(folder, L(3, 2) + "_proj", "PV2");
            X = s.T.X; Y = s.T.Y;
            D = hypot(X - X', Y - Y');
            D(1:numel(X) + 1:end) = Inf;
            [~, k] = min(D(:));
            [a, b] = ind2sub(size(D), k);
            s.mergeCells(ids([a b]), ids(a));
            s.flush();
            rep = idx.refresh();
            F2 = idx.source(folder, L(3, 2) + "_proj", "PV2");
            names = curation.Features.names();
            nb = ismember(names, ["nnUm" "densityN"]);
            tc.verifyEqual(F2(:, nb), F1(:, nb), sprintf(['merging rows %d and %d changed the neighbour ' ...
                'features of %d row(s)'], a, b, nnz(any(F2(:, nb) ~= F1(:, nb), 2))));
            tc.verifyEqual(rep.Recomputed, 0, 'a merge without a move does not invalidate the features');
        end

        function animalIdsWithLeadingZeros(tc)
            % "SUBJ-ID-09001" and "SUBJ-ID-9001" are one animal (grouped CV must not split it).
            fx = tc.applyFixture(matlab.unittest.fixtures.TemporaryFolderFixture);
            root = fullfile(fx.Folder, 'p');
            makeSyntheticDataset(fullfile(root, 'SUBJ-ID-09001', 'a'), 'BaseName', "SUBJ-ID-09001IHC_sec1", ...
                'Seed', 61, 'Variants', false, 'ImageSize', [200 260], 'NumCells', [20 20]);
            makeSyntheticDataset(fullfile(root, 'b'), 'BaseName', "SUBJ-ID-9001IHC_sec2", ...
                'Seed', 62, 'Variants', false, 'ImageSize', [200 260], 'NumCells', [20 20]);
            idx = curation.ProjectIndex.build(root, struct('CacheDir', fullfile(fx.Folder, 'c')));
            tc.verifyEqual(unique(idx.Sources.Animal), "9001");
            tc.verifyEqual(curation.ProjectIndex.animalId("SUBJ-ID-0127IHC_x", ""), "127");
            tc.verifyEqual(curation.ProjectIndex.animalId("x", "D:\data\SUBJ-ID-000\s1"), "0");
            tc.verifyEqual(curation.ProjectIndex.animalId("SUBJ-ID-1127IHC_ECM26A260519S2_1A_L_WFA-PV_Z3_260511_1", ""), "1127");
        end

        function priorProposalOfConfirmAudit(tc)
            % The P shown when a confirm-audit tile was first confirmed (its band) survives the
            % blind re-label, which may overwrite ProposalP.
            s = tc.openStore(2, "ECM1");
            ids = s.T.CellID;
            s.setLabel(ids(1:2), "Bad", "confirmed", struct('ProposalP', [0.05; 0.3]));
            s.setLabel(ids(3), "Good", "confirmed", struct('ProposalP', 0.9));
            s.setAuditRole(ids(1:3), "confirm-audit");
            s.setLabel(ids(1), "Good", "blind", struct('ProposalP', 0.5));    % changed, P overwritten
            s.setLabel(ids(2), "Bad", "blind");                               % same label, P kept
            idx = tc.buildIdx();
            T = idx.table("pnn");
            r = T(T.Base == "SUBJ-ID-9001IHC_sec2_proj", :);
            tc.verifyEqual(r.PriorLabel(1:3), ["Bad"; "Bad"; ""]);
            tc.verifyEqual(r.PriorProposalP(1:2), [0.05; 0.3], 'AbsTol', 1e-12);
            tc.verifyTrue(isnan(r.PriorProposalP(3)), 'not judged blind yet');
            rep = curation.Audit.report(T);
            k = rep.Kinds(rep.Table.Kind == "pnn");
            tc.verifyEqual([k.ConfirmBadDefaultN k.ConfirmBadDefaultChanged], [2 1]);
            B = k.ConfirmByBand;
            tc.verifyEqual(B.N(B.Band == "bad"), 1);
            tc.verifyEqual(B.N(B.Band == "middle-low"), 1);
        end

        function nothingWrittenInsideTheData(tc)
            % labels first (the store is the app: it may write), then only the index works
            s = tc.openStore(1, "PV2");
            s.setLabel(s.T.CellID(1:12), "Bad", "human");
            s.setAuditRole(s.T.CellID(13:15), "holdout");
            s.close();
            before = tc.listing(tc.Parent);
            idx = tc.buildIdx(struct('All', true));
            idx.refresh(struct('Rediscover', true));
            idx.trainingSet("pv");
            idx.table("pnn");
            idx.summary();
            L = tProjectIndex.LAYOUT;
            idx.source(fullfile(tc.Parent, L(5, 1)), L(5, 2) + "_proj", "PV2");
            curation.Audit.report(idx);
            after = tc.listing(tc.Parent);
            tc.verifyEqual(after, before, 'the data tree is untouched (names, sizes, times)');
            tc.verifyGreaterThan(numel(dir(fullfile(tc.Cache, 'feat_*.mat'))), 0, 'features cached outside');
            tc.verifyError(@() curation.ProjectIndex.build(tc.Parent, struct('CacheDir', fullfile(tc.Parent, 'c'))), ...
                'curation:ProjectIndex:cacheInData');
            tc.verifyFalse(isfolder(fullfile(tc.Parent, 'c')));
        end
    end
end


function recordCall(rec, k, n, name)
%recordCall  Progress callback of the build test: rec(k) = {[k n], name} (Map is a handle).
rec(k) = {[k n], string(name)};
end

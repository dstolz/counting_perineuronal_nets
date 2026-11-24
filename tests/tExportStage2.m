classdef tExportStage2 < matlab.unittest.TestCase
    %TEXPORTSTAGE2  curation.Export.stage2 (and .observations) on a synthetic multi-section,
    %   multi-animal project labelled through curation.Store, checked by instantiating the real
    %   Python dataset class (datasets.PerineuronalNetsRankDataset) on the export
    %   (tests\python\inspect_export.py):
    %     - its length equals the report's counts; X and Y are integers; agreement levels are 7/4/0
    %       exactly as the labels map (Good / Uncertain / Bad);
    %     - a patch fetched for a known true cell has that cell's blob where the coordinate
    %       convention puts it (to 2 px); a deliberately transposed export fails the same check;
    %     - no holdout, catch, excluded (also by a region the other channel drew), merged, auto,
    %       legacy-resolver or flagged row is present; an animal never straddles train and
    %       validation; the left-out counts per rule are what the labelling implies;
    %     - one animal needs AllowSameValidation; too few labels per class refuses; Overwrite.
    %   The project builder (makeProject) and the inspector call are static methods shared with
    %   tExportStage1, tTrainSmoke and tRescore.
    %   Run: pwsh -File tools\Run-Tests.ps1 tExportStage2 -IncludeSlow

    properties
        Root        % temporary root
        Parent      % the project folder
        Truth       % struct per section field (matlab.lang.makeValidName(base)) -> fixture truth + plan
        Index       % curation.ProjectIndex
    end

    properties (Constant)
        LAYOUT = [ ...
            "SUBJ-ID-9001/sec1", "SUBJ-ID-9001IHC_sec1"; ...
            "SUBJ-ID-9001/sec2", "SUBJ-ID-9001IHC_sec2"; ...
            "SUBJ-ID-9002/sec1", "SUBJ-ID-9002IHC_sec1"; ...
            "SUBJ-ID-9003/sec1", "SUBJ-ID-9003IHC_sec1"]
        CROSS = 3      % the section where the other channel (ECM1) draws an image-scope region
    end

    methods (TestClassSetup)
        function build(tc)
            fx = tc.applyFixture(matlab.unittest.fixtures.TemporaryFolderFixture);
            tc.Root = fx.Folder;
            tc.Parent = fullfile(tc.Root, 'project');
            tc.Truth = tExportStage2.makeProject(tc.Parent, tExportStage2.LAYOUT, @tExportStage2.labelStage2, ...
                tExportStage2.CROSS);
            tc.Index = curation.ProjectIndex.build(tc.Parent, struct('CacheDir', fullfile(tc.Root, 'cache')));
        end
    end

    methods (Test, TestTags = {'Slow', 'Python'})

        function exportMatchesThePythonDataset(tc)
            out = fullfile(tc.Root, 'exp_main');
            r = curation.Export.stage2(tc.Index, out, struct('Kind', "pv", 'MinPerClass', 5));
            tc.verifyEqual(r.Status, "ok");
            tc.verifyTrue(isfile(fullfile(out, 'export_report.json')) && isfile(fullfile(out, 'export_summary.txt')));
            fprintf('\n%s\n', fileread(fullfile(out, 'export_summary.txt')));

            % ---- the split: disjoint animals, every exported animal present
            Ptr = readtable(fullfile(out, 'train', 'annotations_provenance.csv'), 'TextType', 'string');
            Pva = readtable(fullfile(out, 'validation', 'annotations_provenance.csv'), 'TextType', 'string');
            tc.verifyEmpty(intersect(unique(string(Ptr.Animal)), unique(string(Pva.Animal))), ...
                'an animal straddles train and validation');
            tc.verifyEqual(sort(unique([string(Ptr.Animal); string(Pva.Animal)])), ["9001"; "9002"; "9003"]);
            P = [Ptr; Pva];
            tc.verifyEqual(height(P), sum(r.Counts.Total));

            % ---- no forbidden row
            tc.verifyForbiddenRowsAbsent(P);
            tc.verifyLeftOut(r);

            % ---- the real Python dataset on each split
            for sp = ["train" "validation"]
                Pq = Ptr; if sp == "validation", Pq = Pva; end
                J = tExportStage2.inspect('stage2', fullfile(out, char(sp)), fullfile(tc.Root, "insp_" + sp + ".json"));
                tc.verifyEqual(J.len, height(Pq), sp + ": dataset length = exported rows");
                tc.verifyEqual(J.numImages, numel(unique(Pq.imgName)));
                tc.verifyEqual(string(J.xyDtype), "int64", 'X/Y integers');
                items = struct2table(J.items);
                items.imgName = string(items.imgName);
                tc.verifyTrue(all(ismember(items.agreement, [0 4 7])));
                [ok, loc] = ismember(items(:, {'imgName', 'X', 'Y'}), Pq(:, {'imgName', 'X', 'Y'}));
                tc.verifyTrue(all(ok), 'every dataset item is an exported row');
                lab = string(Pq.Label(loc(ok)));
                want = 7 * (lab == "Good") + 4 * (lab == "Uncertain");
                tc.verifyEqual(items.agreement(ok), want, 'agreement = 7 Good / 4 Uncertain / 0 Bad');
                tc.verifyTrue(all(items.h == 64 & items.w == 64), '64 x 64 patches');
                [frac, off] = tc.centring(items, Pq, loc);
                fprintf('[centring] %s: %.0f%% of true-cell rows have the blob where expected (+-2 px); mean export - blob = (%.2f, %.2f) px\n', ...
                    sp, 100 * frac, off(1), off(2));
                tc.verifyGreaterThanOrEqual(frac, 0.9, 'patches are centred on their cells');
            end
        end

        function transposedExportFailsTheCoordinateCheck(tc)
            out = fullfile(tc.Root, 'exp_transposed');
            curation.Export.stage2(tc.Index, out, struct('Kind', "pv", 'MinPerClass', 5, 'TransposeForTest', true));
            Pq = readtable(fullfile(out, 'train', 'annotations_provenance.csv'), 'TextType', 'string');
            J = tExportStage2.inspect('stage2', fullfile(out, 'train'), fullfile(tc.Root, 'insp_t.json'));
            items = struct2table(J.items);
            items.imgName = string(items.imgName);
            [~, loc] = ismember(items(:, {'imgName', 'X', 'Y'}), Pq(:, {'imgName', 'X', 'Y'}));
            frac = tc.centring(items, Pq, loc);
            fprintf('[centring] transposed export: %.0f%% within 2 px\n', 100 * frac);
            tc.verifyLessThan(frac, 0.5, 'the coordinate check must catch a transposed image');
        end
    end

    methods (Test)

        function oneAnimalNeedsAllowSameValidation(tc)
            out = fullfile(tc.Root, 'exp_one');
            sec = "SUBJ-ID-9003/sec1/SUBJ-ID-9003IHC_sec1_proj";
            tc.verifyError(@() curation.Export.stage2(tc.Index, out, struct('Kind', "pv", 'Sections', sec, ...
                'MinPerClass', 5)), 'curation:Export:oneAnimal');
            tc.verifyFalse(isfolder(fullfile(out, '.staging')) || isfolder(fullfile(out, 'train')), ...
                'a refused export leaves no images behind');
            r = curation.Export.stage2(tc.Index, out, struct('Kind', "pv", 'Sections', sec, 'MinPerClass', 5, ...
                'AllowSameValidation', true, 'Overwrite', true));
            tc.verifyTrue(r.Split.SameAsTraining);
            tc.verifyTrue(any(contains(r.Notes, "not validated")));
            a = readtable(fullfile(out, 'train', 'annotations.csv'));
            b = readtable(fullfile(out, 'validation', 'annotations.csv'));
            tc.verifyEqual(a, b);
            tc.verifyEqual(a.Properties.VariableNames, {'imgName', 'X', 'Y', 'AV', 'R2', 'R3', 'R4', 'R5', 'R6', 'VT'});
        end

        function tooFewPerClassRefusesAndReports(tc)
            out = fullfile(tc.Root, 'exp_few');
            tc.verifyError(@() curation.Export.stage2(tc.Index, out, struct('Kind', "pv", 'MinPerClass', 1000)), ...
                'curation:Export:tooFew');
            J = jsondecode(fileread(fullfile(out, 'export_report.json')));
            tc.verifyEqual(string(J.Status), "refused");
            tc.verifyFalse(isfolder(fullfile(out, 'train')), 'no data left behind');
        end

        function overwriteIsExplicit(tc)
            out = fullfile(tc.Root, 'exp_over');
            o = struct('Kind', "pv", 'MinPerClass', 5);
            curation.Export.stage2(tc.Index, out, o);
            tc.verifyError(@() curation.Export.stage2(tc.Index, out, o), 'curation:Export:exists');
            o.Overwrite = true;
            r = curation.Export.stage2(tc.Index, out, o);
            tc.verifyEqual(r.Status, "ok");
            tc.verifySubstring(char(r.Commands.stage2), 'data=curated');
            tc.verifySubstring(char(r.Commands.stage2), 'method=ordinal_regression');
            tc.verifySubstring(char(r.Commands.stage2), ['data.validation.root=' strrep(fullfile(out, 'validation'), '\', '/')]);
            tc.verifySubstring(char(r.Commands.stage2), 'pv_v2_scoring_ordinal_regression/best.pth');
        end

        function observationsUseTheLegacySchema(tc)
            f = fullfile(tc.Root, 'obs', 'observations.csv');
            r = curation.Export.observations(tc.Index, f, struct('Kind', "pv"));
            O = readtable(f, 'TextType', 'string');
            tc.verifyEqual(O.Properties.VariableNames, {'ObservationID', 'ImagePath', 'TiffPageNumber', ...
                'PageAlias', 'X', 'Y', 'Score', 'Rescore', 'CropHeight', 'CropWidth', 'Classification'});
            T = tc.Index.table("pv");
            want = 0;
            for k = 1:size(tExportStage2.LAYOUT, 1)
                % reviewed, active, labelled, not excluded (by flag or by the JSON regions)
                R = T(T.Base == tExportStage2.LAYOUT(k, 2) + "_proj", :);
                js = fullfile(tc.Parent, tExportStage2.LAYOUT(k, 1), tExportStage2.LAYOUT(k, 2) + "_proj.curation.json");
                J = jsondecode(fileread(js));
                regs = curation.Regions.normalize(J.regions);
                ex = R.Excluded;
                if ~isempty(regs), ex = ex | curation.Regions.excluded(regs, [R.X R.Y], "PV2"); end
                want = want + nnz(R.State == "active" & R.Reviewed & R.Label ~= "" & ~ex);
            end
            tc.verifyEqual(height(O), want);
            tc.verifyEqual(sum(r.Counts.Total), want);
            tc.verifyTrue(all(O.PageAlias == "PV") && all(O.TiffPageNumber == 2) && all(O.CropHeight == 64));
            i = 1;
            key = sprintf('%s|%s|%.15g|%.15g', O.ImagePath(i), O.PageAlias(i), O.X(i), O.Y(i));
            d = java.security.MessageDigest.getInstance('MD5');
            h = lower(sprintf('%02x', typecast(d.digest(uint8(key)), 'uint8')));
            tc.verifyEqual(O.ObservationID(i), string(h), 'ObservationID as the legacy QC export computes it');
            tc.verifyTrue(isfile(fullfile(tc.Root, 'obs', 'observations_export_report.json')));
        end
    end

    %% ------------------------------------------------------------------ checks
    methods
        function verifyForbiddenRowsAbsent(tc, P)
            T = tc.Index.table("pv");
            [ok, loc] = ismember(string(P.SourceId) + "|" + string(P.CellID), T.SourceId + "|" + string(T.CellID));
            tc.assertTrue(all(ok));
            R = T(loc, :);
            tc.verifyFalse(any(ismember(R.AuditRole, ["holdout" "reject-audit" "catch"])), 'audit evidence exported');
            tc.verifyFalse(any(R.Excluded), 'excluded row exported');
            tc.verifyFalse(any(R.State ~= "active"), 'merged or stale row exported');
            tc.verifyFalse(any(ismember(R.LabelSource, ["auto" "legacy-resolver"])), 'auto / legacy-resolver label exported');
            tc.verifyFalse(any(R.Flag ~= ""), 'flagged row exported');
            tc.verifyTrue(all(R.Reviewed));
            % the row the OTHER channel's image-scope region covers (its own snapshot says not excluded)
            cross = tc.Truth.(matlab.lang.makeValidName(tExportStage2.LAYOUT(tExportStage2.CROSS, 2))).plan.crossId;
            sid = T.SourceId(find(T.Base == tExportStage2.LAYOUT(tExportStage2.CROSS, 2) + "_proj", 1));
            tc.verifyFalse(any(string(P.SourceId) == sid & P.CellID == cross), ...
                'a row inside a region the other channel drew was exported');
            tc.verifyFalse(T.Excluded(T.SourceId == sid & T.CellID == cross), ...
                'precondition: the PV2 snapshot does not know the region');
        end

        function verifyLeftOut(tc, r)
            n = size(tExportStage2.LAYOUT, 1);
            got = @(rule) sum(r.LeftOut.Count(r.LeftOut.Rule == rule));
            tc.verifyEqual(got("audit evidence (holdout/reject-audit/catch)"), 4 * n);
            tc.verifyEqual(got("inside an exclusion region"), n + 1, 'one per section + the cross-channel one');
            tc.verifyEqual(got("auto label"), 3 * n);
            tc.verifyEqual(got("legacy-resolver label"), n);
            tc.verifyEqual(got("merged duplicate"), n);
            tc.verifyEqual(got("flagged"), n);
            tc.verifyEqual(sum(r.Counts.Good), (16 + 5 + 1) * n - 1);
            tc.verifyEqual(sum(r.Counts.Uncertain), 3 * n);
            tc.verifyEqual(sum(r.Counts.Bad), 12 * n);
        end

        function [frac, meanOff] = centring(tc, items, Pq, loc)
            % share of true-cell rows whose patch maximum lies where the coordinate convention puts
            % the cell's blob: model 0-based centre = f * (x_true - 0.5) - 0.5 (imresize's pixel
            % mapping of the 1-based fixture coordinates), exported X = round(f * X_full)
            hit = false(0, 1); off = zeros(0, 2);
            for i = 1:height(items)
                if loc(i) == 0, continue; end
                p = Pq(loc(i), :);
                base = regexprep(extractBefore(string(p.Section), "_proj"), '^.*/', '');
                tr = tc.Truth.(matlab.lang.makeValidName(base));
                det = tr.PV2.det;
                cid = p.CellID;
                if det.Kind(cid) ~= "tp", continue; end
                xy = tr.PV2.cellsXY(det.TrueIdx(cid), :);
                f = tr.resize;
                cx = f * (xy(1) - 0.5) - 0.5; cy = f * (xy(2) - 0.5) - 0.5;
                ex = cx - items.X(i); ey = cy - items.Y(i);       % expected offset of the blob
                hit(end + 1, 1) = abs(items.dx(i) - ex) <= 2 && abs(items.dy(i) - ey) <= 2; %#ok<AGROW>
                off(end + 1, :) = [items.X(i) - cx, items.Y(i) - cy]; %#ok<AGROW>
            end
            tc.assertNotEmpty(hit, 'no true-cell rows to check');
            frac = mean(hit);
            meanOff = mean(off, 1);
        end
    end

    %% ------------------------------------------------------------------ shared builders
    methods (Static)

        function truth = makeProject(parent, layout, labelFcn, cross)
            %MAKEPROJECT  Synthetic sections (makeSyntheticDataset, 500 x 700 px at 1.657 um/px) in
            %   parent/<folder>, each labelled by labelFcn(store, truth, k) through curation.Store
            %   (PV2); returns per section the fixture truth plus .plan (what was labelled) and
            %   .resize. cross (optional): the section where the ECM1 store draws an image-scope
            %   exclusion region over a PV2 row labelled Good (plan.crossId) after PV2 was closed.
            if nargin < 4, cross = 0; end
            truth = struct();
            for k = 1:size(layout, 1)
                folder = fullfile(parent, layout(k, 1));
                [~, t] = makeSyntheticDataset(folder, 'BaseName', layout(k, 2), 'Seed', 70 + k, ...
                    'Variants', false, 'ImageSize', [500 700], 'NumCells', [50 70]);
                s = curation.Store.openCsv(t.paths.pv2Locs, struct('AutosaveDelay', 0, 'ImportLegacy', false));
                t.plan = labelFcn(s, t, k);
                s.close();
                if k == cross
                    e = curation.Store.openCsv(t.paths.ecm1Locs, struct('AutosaveDelay', 0, 'ImportLegacy', false));
                    xy = t.PV2.locs{t.plan.G(1), {'X', 'Y'}};
                    e.addRegion(struct('kind', "exclude", 'scope', "image", 'xy', tExportStage2.square(xy, 3)));
                    e.close();
                    t.plan.crossId = t.plan.G(1);
                end
                t.resize = round(1.657 / 0.645, 4);
                truth.(matlab.lang.makeValidName(layout(k, 2))) = t;
            end
        end

        function plan = labelStage2(s, t, ~)
            %LABELSTAGE2  Every kind of row the Stage-2 export must keep or leave out.
            det = t.PV2.det;
            dupRows = [t.PV2.dupGroups{:}];
            tp = setdiff(find(det.Kind == "tp"), dupRows)';
            fp = find(det.Kind == "fp")';
            g = t.PV2.dupGroups{1};
            plan = struct('G', tp(1:16), 'U', tp(17:19), 'C', tp(20:24), 'HG', tp(25:26), 'EX', tp(27), ...
                'FL', tp(28), 'B', fp(1:12), 'HB', fp(13), 'CA', fp(14), 'AU', fp(15:17), 'LR', fp(18), ...
                'dup', g, 'crossId', NaN);
            s.setLabel(plan.G, "Good", "human");
            s.setLabel(plan.U, "Uncertain", "human");
            s.setLabel(plan.C, "Good", "confirmed");
            s.setAuditRole(plan.HG, "holdout"); s.setLabel(plan.HG, "Good", "blind");
            s.setLabel(plan.EX, "Good", "human");
            s.setLabel(plan.FL, "Good", "human"); s.setFlag(plan.FL, "later");
            s.setLabel(plan.B, "Bad", "human");
            s.setAuditRole(plan.HB, "holdout"); s.setLabel(plan.HB, "Bad", "blind");
            s.setAuditRole(plan.CA, "catch"); s.setLabel(plan.CA, "Bad", "blind");
            s.setLabel(plan.AU, "Bad", "auto");
            s.setLabel(plan.LR, "Bad", "legacy-resolver");
            s.setLabel(g, "Good", "human");
            s.mergeCells(g, g(1));
            xy = t.PV2.locs{plan.EX, {'X', 'Y'}};
            s.addRegion(struct('kind', "exclude", 'scope', "PV2", 'xy', tExportStage2.square(xy, 3)));
        end

        function xy = square(c, h)
            xy = [c(1) - h, c(2) - h; c(1) + h, c(2) - h; c(1) + h, c(2) + h; c(1) - h, c(2) + h];
        end

        function J = inspect(what, root, outJson, varargin)
            %INSPECT  Run tests\python\inspect_export.py with the countpnn interpreter.
            repo = fileparts(fileparts(mfilename('fullpath')));
            py = curation.Trainer.defaultPython(repo);
            script = fullfile(repo, 'tests', 'python', 'inspect_export.py');
            [st, out] = CellToolkit.runPython(py, [{script, what, char(root), char(outJson)}, varargin]);
            if st ~= 0 || ~isfile(outJson)
                error('tExportStage2:inspect', 'inspect_export.py failed (exit %d):\n%s', st, out);
            end
            J = jsondecode(fileread(outJson));
        end
    end
end

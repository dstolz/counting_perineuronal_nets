classdef tExportStage1 < matlab.unittest.TestCase
    %TEXPORTSTAGE1  curation.Export.stage1 on a synthetic multi-animal project labeled through
    %   curation.Store, checked by instantiating the real Python dataset class
    %   (datasets.PerineuronalNetsDataset, splits train-half1 and train-half2) on the export
    %   (tests\python\inspect_export.py):
    %     - only sections marked Complete AND SweepDone are exported; the others are listed with
    %       the reason;
    %     - the dataset's annotations (both halves) are exactly the positives of the report: Good
    %       and Uncertain, no holdout, no excluded row, no merged duplicate;
    %     - every unclipped training box is centered on an exported positive (side 60 px);
    %     - the exclusion region is 0 in the image the dataset reads (and outside it is not), the
    %       holdout cells are painted out; the H5 is float32 of the model-input size.
    %   One training step with the Stage-1 command line is in tTrainSmoke.
    %   Run: pwsh -File tools\Run-Tests.ps1 tExportStage1 -IncludeSlow

    properties
        Root
        Parent
        Truth
        Index
    end

    properties (Constant)
        LAYOUT = [ ...
            "SUBJ-ID-9101/sec1", "SUBJ-ID-9101IHC_sec1"; ...   % complete + swept
            "SUBJ-ID-9101/sec2", "SUBJ-ID-9101IHC_sec2"; ...   % complete, sweep not done
            "SUBJ-ID-9102/sec1", "SUBJ-ID-9102IHC_sec1"; ...   % complete + swept
            "SUBJ-ID-9103/sec1", "SUBJ-ID-9103IHC_sec1"]       % neither
        REGION = [150 150; 230 150; 230 230; 150 230]          % exclusion square, full-res px
    end

    methods (TestClassSetup)
        function build(tc)
            fx = tc.applyFixture(matlab.unittest.fixtures.TemporaryFolderFixture);
            tc.Root = fx.Folder;
            tc.Parent = fullfile(tc.Root, 'project');
            tc.Truth = tExportStage2.makeProject(tc.Parent, tExportStage1.LAYOUT, @tExportStage1.labelAll);
            tc.Index = curation.ProjectIndex.build(tc.Parent, struct('CacheDir', fullfile(tc.Root, 'cache')));
        end
    end

    methods (Test, TestTags = {'Slow', 'Python'})
        function exportMatchesThePythonDataset(tc)
            out = fullfile(tc.Root, 'exp1');
            r = curation.Export.stage1(tc.Index, out, struct('Kind', "pv"));
            fprintf('\n%s\n', fileread(fullfile(out, 'export_summary.txt')));
            tc.verifyEqual(r.Status, "ok");

            % ---- which sections
            sk = r.Skipped;
            tc.verifyEqual(height(sk), 2);
            tc.verifySubstring(char(sk.Reason(contains(sk.SourceId, "9101IHC_sec2"))), 'sweep not done');
            tc.verifySubstring(char(sk.Reason(contains(sk.SourceId, "9103IHC_sec1"))), 'not marked Complete');
            tc.verifyEqual(height(r.Images), 2);

            % ---- the positives
            A = readtable(fullfile(out, 'train', 'annotations.csv'), 'TextType', 'string');
            tc.verifyEqual(A.Properties.VariableNames, {'imgName', 'Y', 'X', 'class'});
            P = readtable(fullfile(out, 'train', 'annotations_provenance.csv'), 'TextType', 'string');
            tc.verifyEqual(height(A), height(P));
            tc.verifyEqual(height(P), sum(r.Counts.Total));
            T = tc.Index.table("pv");
            [ok, loc] = ismember(string(P.SourceId) + "|" + string(P.CellID), T.SourceId + "|" + string(T.CellID));
            tc.assertTrue(all(ok));
            R = T(loc, :);
            tc.verifyTrue(all(ismember(R.Label, ["Good" "Uncertain"])));
            tc.verifyTrue(any(R.Label == "Uncertain"), 'Uncertain counts as a cell (UncertainIsCell)');
            tc.verifyFalse(any(R.AuditRole ~= ""), 'holdout rows are not positives');
            tc.verifyFalse(any(R.Excluded) || any(R.State ~= "active"));
            for k = [1 3]
                tr = tc.Truth.(matlab.lang.makeValidName(tExportStage1.LAYOUT(k, 2)));
                f = tr.resize;
                m = contains(string(P.SourceId), tExportStage1.LAYOUT(k, 2));
                want = setdiff([tr.plan.G tr.plan.U], [tr.plan.H tr.plan.inRegion]);
                tc.verifyEqual(sort(P.CellID(m))', sort(want), 'positives = Good + Uncertain, minus holdout and excluded');
                xy = tr.PV2.locs{P.CellID(m), {'X', 'Y'}};
                tc.verifyEqual([P.X(m) P.Y(m)], xy * f, 'AbsTol', 1e-9, 'X_full * resize, unrounded');
            end

            % ---- the Python dataset
            rects = tc.rects(r, out);
            J = tExportStage2.inspect('stage1', out, fullfile(tc.Root, 'insp1.json'), rects.file);
            h1 = J.train_half1; h2 = J.train_half2;
            fprintf('[stage1] %s\n[stage1] %s\n', h1.str, h2.str);
            tc.verifyEqual(h1.numImages, 2);
            tc.verifyEqual(h1.numAnnotations + h2.numAnnotations, height(A), ...
                'every positive is in exactly one of the two halves');
            C = struct2table([h1.centers; h2.centers]);
            C.imgName = string(C.imgName);
            tc.verifyTrue(all(abs(C.side - 60) < 1e-9), 'boxes of side 60');
            d = inf(height(C), 1);
            for i = 1:height(C)
                m = A.imgName == C.imgName(i);
                d(i) = min(hypot(A.X(m) - C.X(i), A.Y(m) - C.Y(i)));
            end
            tc.verifyLessThan(max(d), 1e-3, 'every unclipped box is centered on an exported positive');
            covered = 0;
            for i = 1:height(A)
                covered = covered + any(C.imgName == A.imgName(i) & hypot(C.X - A.X(i), C.Y - A.Y(i)) < 1e-3);
            end
            fprintf('[stage1] %d of %d positives seen as unclipped boxes\n', covered, height(A));
            tc.verifyGreaterThan(covered, 0.5 * height(A));
            shapes = J.shapes;
            for i = 1:height(r.Images)
                fld = matlab.lang.makeValidName(r.Images.imgName(i) + ".tif");
                tc.verifyEqual(shapes.(fld)(:)', [r.Images.Height(i) r.Images.Width(i)], 'H5 read as (H, W)');
                tc.verifyEqual(string(J.dtype.(fld)), "float32");
            end
            tc.verifyEqual(J.rects(rects.zero), zeros(nnz(rects.zero), 1), ...
                'exclusion region and holdout centers are 0 in what the dataset reads');
            tc.verifyTrue(all(J.rects(~rects.zero) > 0), 'outside them the image is not blank');

            % ---- the same, read by MATLAB (h5read gives the transpose)
            img1 = r.Images.imgName(1);
            D = h5read(fullfile(out, 'train', 'fullFramesH5', char(img1 + ".h5")), '/data')';
            tc.verifyEqual(size(D), [r.Images.Height(1) r.Images.Width(1)]);
            tc.verifyClass(D, 'single');
        end
    end

    methods
        function R = rects(tc, r, out)
            % rectangles (0-based, end exclusive) the inspector reads: inside the exclusion region
            % and at holdout centers (must be 0), and two controls outside (must not be blank)
            rows = {};
            zero = false(0, 1);
            for i = 1:height(r.Images)
                name = r.Images.imgName(i) + ".tif";
                f = r.Images.Resize(i);
                q = tExportStage1.REGION;
                x0 = ceil(min(q(:, 1)) * f) + 2; x1 = floor(max(q(:, 1)) * f) - 2;
                y0 = ceil(min(q(:, 2)) * f) + 2; y1 = floor(max(q(:, 2)) * f) - 2;
                rows(end + 1, :) = {name, y0, y1, x0, x1}; zero(end + 1, 1) = true; %#ok<AGROW>
                rows(end + 1, :) = {name, y1 + 40, y1 + 140, x1 + 40, x1 + 140}; zero(end + 1, 1) = false; %#ok<AGROW>
                base = extractBefore(r.Images.imgName(i), "_proj");
                tr = tc.Truth.(matlab.lang.makeValidName(base));
                for id = tr.plan.H
                    xy = tr.PV2.locs{id, {'X', 'Y'}} * f;
                    rows(end + 1, :) = {name, round(xy(2)), round(xy(2)) + 1, round(xy(1)), round(xy(1)) + 1}; %#ok<AGROW>
                    zero(end + 1, 1) = true; %#ok<AGROW>
                end
            end
            R.file = fullfile(out, '..', 'rects.csv');
            writetable(cell2table(rows, 'VariableNames', {'imgName', 'y0', 'y1', 'x0', 'x1'}), R.file);
            R.zero = zero;
        end
    end

    methods (Static)
        function plan = labelAll(s, t, k)
            %LABELALL  A fully reviewed section: true cells Good (3 Uncertain), false detections Bad,
            %   duplicates merged into their first member, 2 holdout cells, one exclusion square.
            %   Sections 1 and 3: Complete + SweepDone; 2: Complete only; 4: neither.
            det = t.PV2.det;
            groups = t.PV2.dupGroups;
            dupRows = [groups{:}];
            tp = setdiff(find(det.Kind == "tp"), dupRows)';
            fp = find(det.Kind == "fp")';
            for g = 1:numel(groups)
                s.setLabel(groups{g}, "Good", "human");
                s.mergeCells(groups{g}, groups{g}(1));
            end
            keepers = cellfun(@(g) g(1), groups);
            plan = struct('U', tp(1:3), 'H', tp(4:5), 'B', fp);
            plan.G = [setdiff(tp, [plan.U plan.H]) keepers];
            s.setLabel(plan.G, "Good", "human");
            s.setLabel(plan.U, "Uncertain", "human");
            s.setAuditRole(plan.H, "holdout"); s.setLabel(plan.H, "Good", "blind");
            s.setLabel(plan.B, "Bad", "confirmed");
            s.addRegion(struct('kind', "exclude", 'scope', "PV2", 'xy', tExportStage1.REGION));
            T = s.T;
            plan.inRegion = T.CellID(T.Excluded & T.State == "active")';
            if k == 1 || k == 3, s.setSweepDone(true); end
            if k <= 3, s.setComplete(true); end
        end
    end
end

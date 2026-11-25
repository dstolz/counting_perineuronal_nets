classdef tAnalysisProject < matlab.unittest.TestCase
    %tAnalysisProject  cellanalysis.Project on synthetic sections: a scan lists every source and writes
    %   nothing; measuring writes <stem>_metrics.csv and <base>.cellanalysis.json and nothing else (the
    %   curation files and the locs are only read); the measurements of the synthetic cells are right; a
    %   second run measures nothing again; more curation makes a section "out of date" and the next run
    %   only refreshes the labels; a moved cell is measured again; another surface makes everything out of
    %   date; cells inside an exclusion region are left out; the long table carries tags, neighborhood
    %   and colocalization; cells near the brain surface are rejected on request, with the tissue there;
    %   groupings are written, read, applied and imported.
    %
    %   Two sections: A (subject 9001), whose picture has 60 empty columns on the left (a brain surface),
    %   and B (subject 9002), whose picture is all tissue.
    %
    %   Run on the hidden desktop: pwsh -File tools\Run-Tests.ps1 tAnalysisProject

    properties (Constant)
        A = "SUBJ-ID-9001IHC_ECM26A260519S2_1A_L_WFA-PV_Z3_260511_1"
        B = "SUBJ-ID-9002IHC_ECM26A260519S2_2A_R_WFA-PV_Z3_260512_1"
        Margin = 60
    end

    properties
        Root
        TruthA
        TruthB
    end

    methods (TestMethodSetup)
        function buildSections(tc)
            fx = tc.applyFixture(matlab.unittest.fixtures.TemporaryFolderFixture);
            tc.Root = fullfile(fx.Folder, 'HISTOLOGY');
            tc.applyFixture(matlab.unittest.fixtures.EnvironmentVariableFixture('CELLDB_PROVENANCE_DIR', ...
                fullfile(fx.Folder, 'no_provenance')));
            [~, tc.TruthA] = tManagerScan.section(tc.Root, fullfile('SUBJ-ID-9001', 'A'), tc.A);
            [~, tc.TruthB] = tManagerScan.section(tc.Root, fullfile('SUBJ-ID-9002', 'B'), tc.B);
            addEmptyMargin(tc.TruthA.paths.tif, tc.Margin);
        end
    end

    methods
        function S = sources(tc)
            S = cellanalysis.Project.sources(tc.Root);
        end

        function src = source(tc, base, key)
            S = tc.sources();
            src = S(startsWith(S.Dataset, base) & S.Key == key, :);
            tc.assertEqual(height(src), 1);
        end
    end

    methods (Static)
        function L = listing(root)
            d = dir(fullfile(root, '**', '*'));
            d = d(~[d.isdir]);
            L = sort(string(fullfile({d.folder}, {d.name}))' + " " + [d.bytes]' + " " + string({d.date})');
        end
    end

    methods (Test)
        function aScanListsEverySourceAndWritesNothing(tc)
            before = tAnalysisProject.listing(tc.Root);
            S = tc.sources();
            tc.verifyEqual(tAnalysisProject.listing(tc.Root), before, 'a scan writes nothing');
            tc.verifyEqual(height(S), 4);
            tc.verifyEqual(sort(S.Kind)', ["pnn" "pnn" "pv" "pv"]);
            tc.verifyEqual(unique(S.Subject)', ["SUBJ-ID-9001" "SUBJ-ID-9002"]);
            tc.verifyTrue(all(S.State == "none"));
            tc.verifyTrue(all(isnan(S.Measured)));
            tc.verifyTrue(all(S.SurfaceMode == "auto"));
            a = S(S.Subject == "SUBJ-ID-9001" & S.Key == "ECM1", :);
            tc.verifyEqual(a.Section, "9001 1A L");
            tc.verifyEqual(a.Hemisphere, "L");
            tc.verifyEqual(a.Stain, "WFA-PV");
            tc.verifyTrue(endsWith(a.MetricsPath, tc.A + "_proj_ECM1_metrics.csv"));
            tc.verifyTrue(endsWith(a.JsonPath, tc.A + "_proj.cellanalysis.json"));
            tc.verifyFalse(a.Curated);
            tc.verifyEqual(a.Detections, height(tc.TruthA.ECM1.locs));
            tc.verifyEqual(height(cellanalysis.Project.sources(fullfile(tc.Root, 'nothing_here'))), 0);
            E = cellanalysis.Project.emptySources();
            tc.verifyTrue(all(ismember(string(E.Properties.VariableNames), string(S.Properties.VariableNames))));
        end

        function measuringWritesTwoFilesAndNothingElse(tc)
            src = tc.source(tc.A, "ECM1");
            before = tAnalysisProject.listing(tc.Root);
            said = strings(0, 1);
            function say(t), said(end + 1, 1) = string(t); end
            [T, rec] = cellanalysis.Project.measure(src, struct('Progress', @say));
            after = tAnalysisProject.listing(tc.Root);
            tc.verifyEqual(numel(setdiff(before, after)), 0, 'no file changed or went away (locs, image, curation)');
            new = setdiff(after, before);
            tc.verifyEqual(numel(new), 2, 'two new files');
            tc.verifyTrue(any(contains(new, "_ECM1_metrics.csv")) && any(contains(new, ".cellanalysis.json")));
            tc.verifyEqual(height(T), height(tc.TruthA.ECM1.locs), 'never curated: every detection is measured');
            tc.verifyFalse(any(T.Kept), 'and none is kept');
            tc.verifyEqual(rec.cells, height(T));
            tc.verifyEqual(rec.measuredNow, height(T));
            tc.verifyEqual(rec.umPerPixel, tc.TruthA.umPerPixel, 'AbsTol', 1e-6);
            tc.verifyTrue(rec.surfaceOk);
            tc.verifyTrue(any(contains(said, "surface")) && any(contains(said, "Measuring")), 'it says what it does');
            R = cellanalysis.Project.readMetrics(src.MetricsPath);
            tc.verifyEqual(R.CellID, T.CellID);
            tc.verifyEqual(R.SurfaceDistUm, T.SurfaceDistUm, 'AbsTol', 1e-9, 'the file reads back as it was written');
            tc.verifyClass(R.Kept, 'logical');
            tc.verifyClass(R.Label, 'string');
            S = tc.sources();
            a = S(startsWith(S.Dataset, tc.A), :);
            tc.verifyEqual(a.State(a.Key == "ECM1"), "current");
            tc.verifyEqual(a.State(a.Key == "PV2"), "none");
            tc.verifyEqual(a.Measured(a.Key == "ECM1"), height(T));
            tc.verifyTrue(a.SurfaceOk(a.Key == "ECM1"));
        end

        function theSyntheticCellsAreMeasuredRight(tc)
            um = tc.TruthA.umPerPixel;
            net = tc.source(tc.A, "ECM1");
            T = cellanalysis.Project.measure(net);
            det = tc.TruthA.ECM1.det;
            tp = det.Kind == "tp" & T.X > tc.Margin + 25 / um;       % true cells well inside the tissue
            tc.verifyGreaterThan(nnz(tp), 8);
            tc.verifyGreaterThan(mean(T.Segmented(tp)), 0.9);
            tc.verifyEqual(median(T.RingRadiusUm(tp), 'omitnan'), 0.74 * 9, 'AbsTol', 1.2, 'the nets are drawn with a 6.7 um ring');
            tc.verifyGreaterThan(median(T.RingContrast(tp), 'omitnan'), 0.6);
            tc.verifyGreaterThan(median(T.Completeness(tp), 'omitnan'), 0.85);
            % distance from the surface: the tissue starts right of the blank columns
            want = (T.X(tp) - (tc.Margin + 0.5)) * um;
            tc.verifyEqual(T.SurfaceDistUm(tp), want, 'AbsTol', 12);
            out = T.X < tc.Margin - 8;
            if any(out)
                tc.verifyFalse(any(T.InTissue(out)), 'a detection on the blank columns is not in tissue');
                tc.verifyEqual(T.SurfaceDistUm(out), zeros(nnz(out), 1), 'AbsTol', 4);
                tc.verifyFalse(any(T.Segmented(out)));
            end
            tc.verifyTrue(all(T.InTissue(tp)));
            tc.verifyTrue(all(T.InAnalysis), 'no analysis region: everything is inside');

            pv = tc.source(tc.A, "PV2");
            P = cellanalysis.Project.measure(pv);
            tpP = tc.TruthA.PV2.det.Kind == "tp" & P.X > tc.Margin + 25 / um;
            tc.verifyEqual(median(P.DiameterUm(tpP), 'omitnan'), 15, 'AbsTol', 2.5, 'the somata are drawn 15 um wide at half maximum');
            tc.verifyLessThan(median(P.AspectRatio(tpP), 'omitnan'), 1.3);
            tc.verifyTrue(all(isnan(P.RingRadiusUm)));
            tc.verifyGreaterThan(median(P.Snr(tpP), 'omitnan'), 5);

            % a picture without empty space: no surface, the rest is measured all the same
            b = tc.source(tc.B, "ECM1");
            [Tb, rec] = cellanalysis.Project.measure(b);
            tc.verifyFalse(rec.surfaceOk);
            tc.verifySubstring(rec.surfaceMessage, 'trace it');
            tc.verifyTrue(all(isnan(Tb.SurfaceDistUm)));
            tc.verifyGreaterThan(mean(Tb.Segmented(tc.TruthB.ECM1.det.Kind == "tp")), 0.9);
            tc.verifyEmpty(rec.depthAreaUm2);
        end

        function aSecondRunMeasuresNothingAgain(tc)
            src = tc.source(tc.A, "PV2");
            [T1, r1] = cellanalysis.Project.measure(src);
            [T2, r2] = cellanalysis.Project.measure(tc.source(tc.A, "PV2"));
            tc.verifyEqual(r1.measuredNow, height(T1));
            tc.verifyEqual(r2.measuredNow, 0, 'nothing changed: nothing is measured again');
            tc.verifyEqual(T2.DiameterUm, T1.DiameterUm, 'AbsTol', 1e-9);
            tc.verifyEqual(T2.SurfaceDistUm, T1.SurfaceDistUm, 'AbsTol', 1e-9);
            tc.verifyEqual(T2.Segmented, T1.Segmented);
            [T3, r3] = cellanalysis.Project.measure(tc.source(tc.A, "PV2"), struct('Force', true));
            tc.verifyEqual(r3.measuredNow, height(T3), 'Force measures everything');
            tc.verifyEqual(T3.DiameterUm, T1.DiameterUm, 'AbsTol', 1e-9, 'and gives the same numbers');
        end

        function oneImageReadServesBothChannels(tc)
            said = strings(0, 1);
            function say(t), said(end + 1, 1) = string(t); end
            [~, ~, loaded] = cellanalysis.Project.measure(tc.source(tc.A, "ECM1"), struct('Progress', @say));
            tc.verifyTrue(any(contains(said, "Reading the image")));
            said = strings(0, 1);
            [T, rec] = cellanalysis.Project.measure(tc.source(tc.A, "PV2"), struct('Progress', @say, 'Loaded', loaded));
            tc.verifyFalse(any(contains(said, "Reading the image")), 'the image of the first channel is used again');
            tc.verifyEqual(rec.measuredNow, height(T));
            tc.verifyEqual(median(T.DiameterUm, 'omitnan'), 15, 'AbsTol', 3);
        end

        function moreCurationOnlyRefreshesTheLabels(tc)
            src = tc.source(tc.A, "ECM1");
            cellanalysis.Project.measure(src);
            tManagerScan.curate(tc.TruthA.paths.ecm1Locs, 6, 2, false);
            src = tc.source(tc.A, "ECM1");
            tc.verifyEqual(src.State, "stale", 'curated since: out of date');
            tc.verifyTrue(src.Curated);
            [T, rec] = cellanalysis.Project.measure(src);
            tc.verifyEqual(rec.measuredNow, 0, 'no cell moved: only the labels are read again');
            tc.verifyEqual(nnz(T.Kept), 6);
            tc.verifyEqual(nnz(T.Label == "Bad"), 2);
            tc.verifyEqual(rec.kept, 6);
            tc.verifyEqual(tc.source(tc.A, "ECM1").State, "current");

            % a moved cell is measured again; the others are not
            s = curation.Store.openCsv(tc.TruthA.paths.ecm1Locs, struct('AutosaveDelay', 0, 'ImportLegacy', false));
            id = double(s.T.CellID(1));
            xy = [s.T.X(1), s.T.Y(1)];
            s.moveCell(id, xy + [3 2]);
            s.close();
            tc.verifyEqual(tc.source(tc.A, "ECM1").State, "stale");
            [T2, rec2] = cellanalysis.Project.measure(tc.source(tc.A, "ECM1"));
            tc.verifyEqual(rec2.measuredNow, 1);
            tc.verifyEqual([T2.X(T2.CellID == id), T2.Y(T2.CellID == id)], xy + [3 2], 'AbsTol', 1e-9, 'the curated position is measured');
            same = T2.CellID ~= id;
            tc.verifyEqual(T2.AreaUm2(same), T.AreaUm2(T.CellID ~= id), 'AbsTol', 1e-9);
        end

        function cellsInAnExclusionRegionAreLeftOut(tc)
            src = tc.source(tc.A, "PV2");
            [T0, r0] = cellanalysis.Project.measure(src);
            s = curation.Store.openCsv(tc.TruthA.paths.pv2Locs, struct('AutosaveDelay', 0, 'ImportLegacy', false));
            box = [200 1; 400 1; 400 300; 200 300];                   % the right half of the picture
            s.addRegion(curation.Regions.make("exclude", box));
            s.close();
            [T1, r1] = cellanalysis.Project.measure(tc.source(tc.A, "PV2"));
            tc.verifyLessThan(height(T1), height(T0));
            tc.verifyTrue(all(T1.X < 200.5), 'no cell of the excluded half is measured');
            tc.verifyEqual(height(T1), nnz(T0.X < 200), 'AbsTol', 1);
            tc.verifyLessThan(sum(r1.depthAreaUm2), 0.6 * sum(r0.depthAreaUm2), 'its tissue does not count for densities either');
            % the region belongs to the dataset: the other channel leaves those cells out too
            cellanalysis.Project.measure(tc.source(tc.A, "ECM1"));
            E = cellanalysis.Project.readMetrics(tc.source(tc.A, "ECM1").MetricsPath);
            tc.verifyTrue(all(E.X < 200.5));
        end

        function theSurfaceDefinitionIsKeptAndMakesMeasurementsOutOfDate(tc)
            src = tc.source(tc.B, "ECM1");
            cellanalysis.Project.measure(src);
            def = cellanalysis.Project.surfaceDef(src);
            tc.verifyEqual(def.mode, "auto");
            tc.verifyEmpty(def.line);
            line = [20 10; 20 290];
            cellanalysis.Project.setSurface(src, struct('mode', "traced", 'line', line));
            def = cellanalysis.Project.surfaceDef(src);
            tc.verifyEqual(def.mode, "traced");
            tc.verifyEqual(def.line, line);
            S = tc.sources();
            b = S(startsWith(S.Dataset, tc.B), :);
            tc.verifyTrue(all(b.SurfaceMode == "traced"), 'the surface belongs to the dataset: both channels');
            tc.verifyEqual(b.State(b.Key == "ECM1"), "stale", 'measured with another surface: out of date');
            [T, rec] = cellanalysis.Project.measure(tc.source(tc.B, "ECM1"));
            tc.verifyEqual(rec.measuredNow, height(T));
            tc.verifyTrue(rec.surfaceOk);
            tc.verifyEqual(T.SurfaceDistUm, abs(T.X - 20) * tc.TruthB.umPerPixel, 'AbsTol', 8, 'distance from the traced line');
            tc.verifyNotEmpty(rec.depthAreaUm2);

            % points a person clicked survive the round trip, also a single one
            cellanalysis.Project.setSurface(src, struct('mode', "auto", 'include', [5 6], 'exclude', [7 8; 9 10]));
            def = cellanalysis.Project.surfaceDef(src);
            tc.verifyEqual(def.mode, "auto");
            tc.verifyEqual(def.include, [5 6]);
            tc.verifyEqual(def.exclude, [7 8; 9 10]);
            tc.verifyEqual(def.line, line, 'the traced line is kept while another mode is used');
            cellanalysis.Project.setSurface(src, struct('include', zeros(0, 2)));
            tc.verifyEmpty(cellanalysis.Project.surfaceDef(src).include);
            tc.verifyError(@() cellanalysis.Project.setSurface(src, struct('mode', "nearest")), 'cellanalysis:Project:badSurface');
            tc.verifyError(@() cellanalysis.Project.setSurface(src, struct('line', [1 2])), 'cellanalysis:Project:badSurface');
            Sf = cellanalysis.Project.loadSurface(tc.source(tc.A, "ECM1"));
            tc.verifyTrue(Sf.Ok, 'the surface of a section can be detected without measuring');
        end

        function theLongTableCarriesTagsAndNeighborhood(tc)
            S = tc.sources();
            for i = 1:height(S), cellanalysis.Project.measure(S(i, :)); end
            tManagerScan.curate(tc.TruthA.paths.ecm1Locs, 8, 2, false);
            tManagerScan.curate(tc.TruthA.paths.pv2Locs, 8, 0, false);
            S = tc.sources();
            for i = find(S.State == "stale")', cellanalysis.Project.measure(S(i, :)); end
            S = tc.sources();
            tc.verifyTrue(all(S.State == "current"));

            K = cellanalysis.Project.load(S, "pnn");
            tc.verifyEqual(height(K), 8, 'kept cells: only the curated section has any');
            tc.verifyTrue(all(K.Kept));
            tc.verifyEqual(unique(K.Subject), "SUBJ-ID-9001");
            tc.verifyEqual(unique(K.Section), "9001 1A L");
            tc.verifyEqual(unique(K.Key), "ECM1");
            for nm = [cellanalysis.Measure.catalog().Name', "CellID", "X", "Y", "Label", "Segmented", "InTissue", "SourceRow", ...
                    "Hemisphere", "Stain", "Sex", "Species", "DbProject", "Group"]
                tc.verifyTrue(ismember(nm, string(K.Properties.VariableNames)), nm + " is a column");
            end
            tc.verifyEqual(unique(S.Dataset(K.SourceRow)), unique(K.Dataset), 'SourceRow points at the row of the sources');

            All = cellanalysis.Project.load(S, "pnn", struct('Population', "all"));
            tc.verifyEqual(height(All), height(tc.TruthA.ECM1.locs) + height(tc.TruthB.ECM1.locs));
            tc.verifyEqual(numel(unique(All.Subject)), 2);
            % neighborhood among the chosen population
            a = All(All.Subject == "SUBJ-ID-9001", :);
            um = tc.TruthA.umPerPixel;
            D = squareform(pdist([a.X a.Y])) * um;
            D(logical(eye(height(a)))) = Inf;
            tc.verifyEqual(a.NnUm, min(D, [], 2), 'RelTol', 1e-6);
            P = cellanalysis.Project.load(S, "pv", struct('Population', "all"));
            pa = P(P.Subject == "SUBJ-ID-9001", :);
            want = min(pdist2([a.X a.Y], [pa.X pa.Y]), [], 2) * um;
            tc.verifyEqual(a.OtherDistUm, want, 'RelTol', 1e-6, 'the nearest cell of the other channel');
            % colocalization: one to one within 10 um, the same pairs seen from either channel
            tc.verifyTrue(all(want(a.Colocalized == 1) <= 10 * (1 + 1e-6)), 'a paired net has a PV cell within the distance');
            tc.verifyGreaterThan(nnz(a.Colocalized), 0);
            tc.verifyLessThanOrEqual(nnz(a.Colocalized), nnz(want <= 10));
            tc.verifyEqual(nnz(pa.Colocalized), nnz(a.Colocalized), 'as many paired PV cells as paired nets');
            pairs = a(a.Colocalized == 1, :);
            [tf, loc] = ismember(pairs.PartnerID, pa.CellID);
            tc.verifyTrue(all(tf), 'PartnerID is the CellID of a PV cell of the section');
            tc.verifyEqual(pa.PartnerID(loc), pairs.CellID, 'and that cell names the net as its partner');
            tc.verifyTrue(all(isnan(a.PartnerID(a.Colocalized == 0))));
            tc.verifyTrue(all(a.ColocChance >= 0 & a.ColocChance <= 1));
            [~, Sec] = cellanalysis.Project.load(S, "pnn", struct('Population', "all"));
            sa = Sec(S.Subject(Sec.SourceRow) == "SUBJ-ID-9001", :);
            tc.verifyEqual(sa.Cells, height(a));
            tc.verifyEqual(sa.OtherKey, "PV2");
            tc.verifyEqual(sa.OtherCells, height(pa));
            tc.verifyEqual(sa.Pairs, nnz(a.Colocalized));
            tc.verifyGreaterThan(sa.TissueMm2, 0.15, 'the tissue area of the section with a surface');
            tc.verifyTrue(isnan(Sec.TissueMm2(S.Subject(Sec.SourceRow) == "SUBJ-ID-9002")), 'no surface: no area');
            wide = cellanalysis.Project.load(S, "pnn", struct('Population', "all", 'ColocUm', 1e4));
            tc.verifyEqual(nnz(wide.Colocalized(wide.Subject == "SUBJ-ID-9001")), min(height(a), height(pa)), ...
                'within any distance: as many pairs as the smaller channel has cells');
            % kept nets are compared with kept PV cells only
            keptPv = pa(pa.Kept, :);
            tc.verifyEqual(K.OtherDistUm, min(pdist2([K.X K.Y], [keptPv.X keptPv.Y]), [], 2) * um, 'RelTol', 1e-6);
            tc.verifyEqual(height(cellanalysis.Project.load(S, "nothing")), 0);
        end

        function cellsNearTheSurfaceAreRejected(tc)
            S = tc.sources();
            for i = 1:height(S), cellanalysis.Project.measure(S(i, :)); end
            S = tc.sources();
            opts = struct('Population', "all");
            [All, Sec0] = cellanalysis.Project.load(S, "pnn", opts);
            P0 = cellanalysis.Project.load(S, "pv", opts);
            opts.MinDepthUm = 100;
            [Kept, Sec] = cellanalysis.Project.load(S, "pnn", opts);
            P1 = cellanalysis.Project.load(S, "pv", opts);

            a0 = All(All.Subject == "SUBJ-ID-9001", :);
            a = Kept(Kept.Subject == "SUBJ-ID-9001", :);
            near = a0.SurfaceDistUm < 100;
            tc.assertGreaterThan(nnz(near), 0, 'the section has cells near its surface');
            tc.assertGreaterThan(nnz(~near), 0, 'and cells beyond');
            tc.verifyEqual(sort(a.CellID), sort(a0.CellID(~near)), 'exactly the cells closer than 100 um are rejected');
            tc.verifyEqual(nnz(Kept.Subject == "SUBJ-ID-9002"), nnz(All.Subject == "SUBJ-ID-9002"), ...
                'a section without a surface keeps all its cells');
            sa = Sec(S.Subject(Sec.SourceRow) == "SUBJ-ID-9001", :);
            sa0 = Sec0(S.Subject(Sec0.SourceRow) == "SUBJ-ID-9001", :);
            tc.verifyEqual(sa.NearSurface, nnz(near), 'the section says how many it lost');
            tc.verifyEqual(sa0.NearSurface, 0);
            tc.verifyEqual(Sec.NearSurface(S.Subject(Sec.SourceRow) == "SUBJ-ID-9002"), 0);

            % the other channel loses its cells near the surface too; pairs and neighbors are among the rest
            pa0 = P0(P0.Subject == "SUBJ-ID-9001", :);
            pa = P1(P1.Subject == "SUBJ-ID-9001", :);
            tc.verifyEqual(sort(pa.CellID), sort(pa0.CellID(pa0.SurfaceDistUm >= 100)));
            tc.verifyEqual(sa.OtherCells, height(pa));
            tc.verifyTrue(all(ismember(a.PartnerID(a.Colocalized == 1), pa.CellID)));
            um = tc.TruthA.umPerPixel;
            D = squareform(pdist([a.X a.Y])) * um;
            D(logical(eye(height(a)))) = Inf;
            tc.verifyEqual(a.NnUm, min(D, [], 2), 'RelTol', 1e-6);
            tc.verifyEqual(a.OtherDistUm, min(pdist2([a.X a.Y], [pa.X pa.Y]), [], 2) * um, 'RelTol', 1e-6);

            % the tissue of the band does not count: 100 um deep, as long as the picture is high
            tc.verifyEqual(sa0.TissueMm2 - sa.TissueMm2, 100 * 300 * um / 1e6, 'RelTol', 0.1);

            % PICK chooses as LOAD does
            M = cellanalysis.Project.readMetrics(S.MetricsPath(S.Subject == "SUBJ-ID-9001" & S.Key == "ECM1"));
            [K, n] = cellanalysis.Project.pick(M, "all", 100);
            tc.verifyEqual(n, nnz(near));
            tc.verifyEqual(sort(K.CellID), sort(a.CellID));
            [K0, n0] = cellanalysis.Project.pick(M, "all", 0);
            tc.verifyEqual([height(K0), n0], [height(M), 0]);
            tc.verifyError(@() cellanalysis.Project.load(S, "pnn", struct('MinDepthUm', -1)), 'cellanalysis:Project:badOption');
        end

        function groupings(tc)
            S = tc.sources();
            G = cellanalysis.Project.readGroups(tc.Root);
            tc.verifyEqual(height(G), 0, 'no file yet');
            a = find(startsWith(S.Dataset, tc.A));
            G = cellanalysis.Project.setGroup(G, S, a, "control");
            cellanalysis.Project.writeGroups(tc.Root, G);
            tc.verifyTrue(isfile(fullfile(tc.Root, 'cellanalysis_groups.csv')));
            G2 = cellanalysis.Project.readGroups(tc.Root);
            tc.verifyEqual(G2.Group, "control");
            tc.verifyEqual(G2.Subject, "SUBJ-ID-9001");
            [S2, factors] = cellanalysis.Project.applyGroups(S, G2);
            tc.verifyEqual(unique(S2.Group(a)), "control");
            tc.verifyEqual(unique(S2.Group(~startsWith(S2.Dataset, tc.A))), "");
            tc.verifyTrue(all(ismember(["Subject" "Hemisphere" "Sex" "Group"], factors)));

            % a spreadsheet by subject, with two groupings
            f = fullfile(tc.Root, 'animals.csv');
            writetable(table(["9001"; "SUBJ-ID-9002"; "7777"], ["noise"; "sham"; "sham"], ["P30"; "P90"; "P90"], ...
                'VariableNames', {'Animal', 'Treatment', 'Age'}), f);
            [G3, rep] = cellanalysis.Project.importGroups(G2, S, f);
            tc.verifyEqual(rep.matched, 2);
            tc.verifyEqual(rep.unmatched, 1, 'an animal that has no section here');
            tc.verifyEqual(rep.factors, ["Treatment" "Age"]);
            [S3, factors] = cellanalysis.Project.applyGroups(S, G3);
            tc.verifyEqual(unique(S3.Treatment(S3.Subject == "SUBJ-ID-9001")), "noise");
            tc.verifyEqual(unique(S3.Age(S3.Subject == "SUBJ-ID-9002")), "P90");
            tc.verifyEqual(unique(S3.Group(S3.Subject == "SUBJ-ID-9001")), "control", 'what was typed before stays');
            tc.verifyTrue(all(ismember(["Treatment" "Age"], factors)));

            % a tracker by image file name
            f2 = fullfile(tc.Root, 'tracker.csv');
            writetable(table(tc.B + "_proj.tif", "plate 31", 'VariableNames', {'Image Filename', 'Atlas'}), f2);
            [G4, rep] = cellanalysis.Project.importGroups(G3, S, f2);
            tc.verifyEqual(rep.matched, 1);
            S4 = cellanalysis.Project.applyGroups(S, G4);
            tc.verifyEqual(unique(S4.Atlas(startsWith(S4.Dataset, tc.B))), "plate 31");
            tc.verifyEqual(unique(S4.Atlas(startsWith(S4.Dataset, tc.A))), "");
            bad = fullfile(tc.Root, 'bad.csv');
            writetable(table(1, 2, 'VariableNames', {'p', 'q'}), bad);
            tc.verifyError(@() cellanalysis.Project.importGroups(G4, S, bad), 'cellanalysis:Project:noKeyColumn');

            % the long table carries the groupings
            cellanalysis.Project.measure(S4(a(1), :));
            S4 = cellanalysis.Project.applyGroups(tc.sources(), G4);
            C = cellanalysis.Project.load(S4, S4.Kind(a(1)), struct('Population', "all"));
            tc.verifyEqual(unique(C.Treatment), "noise");
            tc.verifyEqual(unique(C.Group), "control");

            % clearing everything removes the file
            G5 = cellanalysis.Project.setGroup(G2, S, a, "");
            cellanalysis.Project.writeGroups(tc.Root, G5);
            tc.verifyFalse(isfile(fullfile(tc.Root, 'cellanalysis_groups.csv')));
        end
    end
end

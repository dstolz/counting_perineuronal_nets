classdef tAnalysisGui < matlab.unittest.TestCase
    %tAnalysisGui  The Cell Analysis window, driven through its seams (no dialogs): it lists the sections
    %   of the chosen cell type, measures them, and draws every kind of plot for the checked sections or
    %   the selected one, grouped by subject or by the user's own groups; the Section tab shows the brain
    %   surface, which can be traced or corrected by switching empty areas on and off, after which the
    %   section is out of date until it is measured again; cells near the brain surface can be rejected;
    %   the cells and the per-section summary are
    %   exported; every interactive control has a tooltip, no two the same, and a disabled one says why;
    %   closing the window leaves no timer behind.
    %
    %   Three sections: A and B of subject 9001 (their pictures have empty columns on the left: a brain
    %   surface; A is curated in both channels, B in one), and C of subject 9002 (all tissue, not curated).
    %
    %   Run on the hidden desktop: pwsh -File tools\Run-Tests.ps1 tAnalysisGui

    properties (Constant)
        A = "SUBJ-ID-9001IHC_ECM26A260519S2_1A_L_WFA-PV_Z3_260511_1"
        B = "SUBJ-ID-9001IHC_ECM26A260519S2_1B_R_WFA-PV_Z3_260511_1"
        C = "SUBJ-ID-9002IHC_ECM26A260519S2_2A_L_WFA-PV_Z3_260512_1"
        Margin = 60
    end

    properties
        Root
        Truth
    end

    methods (TestMethodSetup)
        function buildSections(tc)
            fx = tc.applyFixture(matlab.unittest.fixtures.TemporaryFolderFixture);
            tc.Root = fullfile(fx.Folder, 'HISTOLOGY');
            tc.applyFixture(matlab.unittest.fixtures.EnvironmentVariableFixture('CELLDB_PROVENANCE_DIR', ...
                fullfile(fx.Folder, 'no_provenance')));
            [~, ta] = tManagerScan.section(tc.Root, fullfile('SUBJ-ID-9001', 'A'), tc.A);
            [~, tb] = tManagerScan.section(tc.Root, fullfile('SUBJ-ID-9001', 'B'), tc.B);
            [~, tcc] = tManagerScan.section(tc.Root, fullfile('SUBJ-ID-9002', 'C'), tc.C);
            addEmptyMargin(ta.paths.tif, tc.Margin);
            addEmptyMargin(tb.paths.tif, tc.Margin);
            tAnalysisGui.curate(ta.paths.ecm1Locs, ta.ECM1.det, 9, 2);
            tAnalysisGui.curate(ta.paths.pv2Locs, ta.PV2.det, 10, 0);
            tAnalysisGui.curate(tb.paths.ecm1Locs, tb.ECM1.det, 7, 1);
            tc.Truth = struct('A', ta, 'B', tb, 'C', tcc);
        end
    end

    methods
        function app = open(tc, measure)
            app = CellAnalysis(tc.Root, 'UseSettings', false, 'Scan', 'now');
            tc.addTeardown(@() tAnalysisGui.closeApp(app));
            drawnow;
            if nargin > 1 && measure
                tc.assertEqual(app.measure('all'), 6, app.StatusText);
            end
        end
    end

    methods (Static)
        function closeApp(app)
            if ~isempty(app) && isvalid(app)
                delete(app);
            end
        end

        function curate(locs, det, nGood, nBad)
            %curate  Keep the first nGood true cells right of the empty columns; reject nBad false detections.
            s = curation.Store.openCsv(locs, struct('AutosaveDelay', 0, 'ImportLegacy', false));
            T = s.T;
            good = find(det.Kind == "tp" & T.X > tAnalysisGui.Margin + 20, nGood);
            bad = find(det.Kind == "fp");
            bad = bad(1:min(nBad, numel(bad)));
            s.setLabel(double(T.CellID(good)), "Good", "human");
            if ~isempty(bad), s.setLabel(double(T.CellID(bad)), "Bad", "human"); end
            s.close();
        end

        function [h, tips, names] = controls(app)
            %controls  Every interactive component of the window, its tooltip and a readable name.
            all = findall(app.Figure);
            keep = false(numel(all), 1);
            for i = 1:numel(all)
                keep(i) = any(class(all(i)) == tManagerGui.Interactive);
            end
            h = all(keep);
            tips = strings(numel(h), 1);
            names = strings(numel(h), 1);
            for i = 1:numel(h)
                tips(i) = strjoin(string(h(i).Tooltip), " ");
                nm = string(class(h(i)));
                if isprop(h(i), 'Tag') && strlength(string(h(i).Tag)) > 0, nm = nm + " " + string(h(i).Tag); end
                names(i) = nm;
            end
        end
    end

    methods (Test)
        function itListsTheSectionsAndSaysWhatToDo(tc)
            app = tc.open();
            tc.verifyEqual(height(app.Sources), 6);
            tc.verifyEqual(app.Kind, "pnn");
            tc.verifyEqual(numel(app.Rows), 3, 'one row per section with nets');
            tbl = findall(app.Figure, 'Tag', 'table:sections');
            tc.verifySize(tbl.Data, [3 numel(CellAnalysis.COLUMNS)]);
            tc.verifyEqual(string(tbl.Data(:, 2))', ["SUBJ-ID-9001" "SUBJ-ID-9001" "SUBJ-ID-9002"]);
            tc.verifyEqual(string(tbl.Data(:, 3))', ["9001 1A L" "9001 1B R" "9002 2A L"]);
            tc.verifyEqual(string(tbl.Data(:, 6))', ["no" "no" "no"]);
            tc.verifyTrue(all([tbl.Data{:, 1}]), 'every section is checked');
            tc.verifySubstring(app.StatusText, '6 not measured yet');
            tc.verifyEqual(app.PlotInfo.Kind, "message");
            tc.verifySubstring(app.PlotInfo.Note, 'Nothing is measured yet');
            tc.verifyEmpty(app.Cells);
            % an empty window, and a folder without sections
            bare = CellAnalysis('UseSettings', false);
            tc.addTeardown(@() tAnalysisGui.closeApp(bare));
            tc.verifyEqual(height(bare.Sources), 0);
            tc.verifySubstring(bare.PlotInfo.Note, 'Scan a folder');
            empty = fullfile(tc.Root, 'empty');
            mkdir(empty);
            bare.scanFolder(empty);
            tc.verifySubstring(bare.StatusText, 'No section with detections');
        end

        function measuringAndEveryPlot(tc)
            app = tc.open(true);
            tc.verifyTrue(all(app.Sources.State == "current"));
            tc.verifySubstring(app.StatusText, 'Measured 6 source(s)');
            tbl = findall(app.Figure, 'Tag', 'table:sections');
            tc.verifyEqual(string(tbl.Data(:, 6))', ["yes" "yes" "yes"]);
            tc.verifyEqual(string(tbl.Data(:, 5))', ["9" "7" "0"], 'kept cells per section');
            tc.verifyEqual(height(app.Cells), 16);
            tc.verifyEqual(app.measure('all'), 0, 'nothing is out of date');
            tc.verifySubstring(app.StatusText, 'up to date');

            % kept cells: one subject has any
            app.setMetric('DiameterUm');
            app.setGroupBy('Subject');
            tc.verifyEqual(app.PlotInfo.Kind, "histogram");
            tc.verifyEqual(app.PlotInfo.Names, "SUBJ-ID-9001");
            tc.verifyEqual(app.PlotInfo.N, 16);
            tc.verifySubstring(app.PlotInfo.XLabel, 'Equivalent diameter (um)');
            tc.verifyEqual(height(app.View), 16);

            % every detection: both subjects
            app.setPopulation('all');
            nAll = height(app.Cells);
            tc.verifyEqual(nAll, height(tc.Truth.A.ECM1.locs) + height(tc.Truth.B.ECM1.locs) + height(tc.Truth.C.ECM1.locs));
            tc.verifyEqual(app.PlotInfo.Names, ["SUBJ-ID-9001"; "SUBJ-ID-9002"]);
            tc.verifyEqual(app.PlotInfo.YLabel, "Share of each group");
            tc.verifyEqual(app.Summary.Group, ["SUBJ-ID-9001"; "SUBJ-ID-9002"]);
            tc.verifyEqual(sum(app.Summary.Cells), nnz(isfinite(app.Cells.DiameterUm)));
            sm = findall(app.Figure, 'Tag', 'table:summary');
            tc.verifySize(sm.Data, [2 11]);
            tc.verifySubstring(sm.ColumnName{1}, 'Equivalent diameter');

            app.setPlot('Cumulative');
            tc.verifyEqual(app.PlotInfo.Kind, "cumulative");
            tc.verifyEqual(numel(app.PlotInfo.Names), 2);

            app.setPlot('Box by group');
            app.setUnit('section');
            tc.verifyEqual(app.PlotInfo.Kind, "box");
            tc.verifyEqual(app.PlotInfo.N, [2; 1], 'one point per section');
            tc.verifyEqual(app.Summary.N, [2; 1]);
            app.setUnit('subject');
            tc.verifyEqual(app.PlotInfo.N, [1; 1]);
            app.setUnit('cells');

            app.setPlot('Metric by depth');
            tc.verifyEqual(app.PlotInfo.Kind, "depth");
            tc.verifyEqual(app.PlotInfo.Names, "SUBJ-ID-9001", 'only the sections with a brain surface have a depth');
            tc.verifyEqual(app.PlotInfo.N, 2, 'two sections');
            app.setBinUm(110);
            tc.verifyEqual(findall(app.Figure, 'Tag', 'edit:bin').Value, 100, 'a multiple of 25');
            app.setPlot('Cell density by depth');
            tc.verifyEqual(app.PlotInfo.Kind, "depth");
            tc.verifySubstring(app.PlotInfo.YLabel, 'cells/mm^2');
            tc.verifyFalse(logical(findall(app.Figure, 'Tag', 'dd:metric').Enable));

            app.setPlot('Scatter');
            app.setXMetric('SurfaceDistUm');
            app.setMetric('NetMean');
            tc.verifyEqual(app.PlotInfo.Kind, "scatter");
            tc.verifySubstring(app.PlotInfo.XLabel, 'Distance from brain surface');
            tc.verifySubstring(app.PlotInfo.YLabel, 'Mean above background');
            tc.verifyTrue(isfinite(app.PlotInfo.Rho));

            % colocalization: pairs with the other channel, per group, with the chance level
            app.setPlot('Colocalization');
            app.setGroupBy('Subject');
            tc.verifyEqual(app.PlotInfo.Kind, "colocalization");
            tc.verifyEqual(app.PlotInfo.Names, ["SUBJ-ID-9001"; "SUBJ-ID-9002"]);
            tc.verifyEqual(app.PlotInfo.N, [2; 1], 'sections per group');
            tc.verifyEqual(app.PlotInfo.Series, ["PNN with PV", "PV with PNN"]);
            R = app.Summary;
            tc.verifyEqual(string(R.Properties.VariableNames(1:6)), ["Group" "Sections" "PNN" "PV" "Pairs" "% of PNN"]);
            tc.verifyEqual(R.Sections, [2; 1]);
            tc.verifyEqual(sum(R.PNN), height(app.Cells));
            tc.verifyEqual(sum(R.Pairs), nnz(app.Cells.Colocalized == 1));
            tc.verifyEqual(height(app.Sections), 3);
            tc.verifyFalse(logical(findall(app.Figure, 'Tag', 'dd:metric').Enable));
            tc.verifySubstring(findall(app.Figure, 'Tag', 'dd:unit').Tooltip, 'always one value per section');
            tc.verifySize(findall(app.Figure, 'Tag', 'table:summary').Data, [2 11]);

            app.setPlot('Histogram');
            app.setMetric('OtherDistUm');
            tc.verifyEqual(numel(findall(app.Figure, 'Type', 'ConstantLine')), 1, 'the colocalization distance is marked');
            app.setGroupBy('Colocalized');
            tc.verifyEqual(sort(app.PlotInfo.Names), ["Colocalized"; "Not colocalized"]);
            app.setColocUm(1e3);
            tc.verifyEqual(findall(app.Figure, 'Tag', 'edit:coloc').Value, 10, 'a distance beyond the field''s range is not taken');
            app.setColocUm(200);
            nPairs = nnz(app.Cells.Colocalized == 1);
            tc.verifyGreaterThan(nPairs, 60, 'within 200 um nearly every cell of the smaller channel has a partner');
            tc.verifyLessThanOrEqual(nPairs, height(tc.Truth.A.PV2.locs) + height(tc.Truth.B.PV2.locs) + height(tc.Truth.C.PV2.locs));
            app.setColocUm(10);
            app.setGroupBy('');
            tc.verifyEqual(app.PlotInfo.Names, "All");
            tc.verifyEqual(app.PlotInfo.YLabel, "Cells", 'one group: counts');
        end

        function rejectingCellsNearTheSurface(tc)
            app = tc.open(true);
            app.setPopulation('all');
            C0 = app.Cells;
            near = C0.SurfaceDistUm < 100;
            tc.assertGreaterThan(nnz(near), 0, 'the sections have cells near their surface');
            app.setMinDepthUm(100);
            tc.verifyEqual(findall(app.Figure, 'Tag', 'edit:minDepth').Value, 100);
            tc.verifyEqual(sort(app.Cells.CellID + 1e6 * app.Cells.SourceRow), ...
                sort(C0.CellID(~near) + 1e6 * C0.SourceRow(~near)), 'exactly the cells closer than 100 um are rejected');
            tc.verifyEqual(nnz(app.Cells.Subject == "SUBJ-ID-9002"), nnz(C0.Subject == "SUBJ-ID-9002"), ...
                'the section without a surface keeps its cells');
            tc.verifySubstring(app.StatusText, sprintf('%d cells within 100 um', nnz(near)));
            tc.verifySubstring(app.StatusText, '1 section(s) have no brain surface');
            tbl = findall(app.Figure, 'Tag', 'table:sections');
            want = arrayfun(@(r) sprintf('%d', nnz(app.Cells.SourceRow == r)), app.Rows, 'UniformOutput', false);
            tc.verifyEqual(tbl.Data(:, 5), want, 'the list counts the cells that are left');
            titles = strjoin(arrayfun(@(a) strjoin(string(a.Title.String), " "), findall(app.Figure, 'Type', 'axes')), " | ");
            tc.verifySubstring(titles, 'at least 100 um from the surface', 'the plot says so');

            % the border is marked where the horizontal axis is the depth
            app.setPlot('Histogram');
            app.setMetric('SurfaceDistUm');
            cl = findall(app.Figure, 'Type', 'ConstantLine');
            tc.verifyEqual(numel(cl), 1);
            tc.verifySubstring(cl.Label, 'rejected closer than 100 um');
            app.setPlot('Cell density by depth');
            tc.verifyEqual(app.PlotInfo.Kind, "depth");
            tc.verifyEqual(numel(findall(app.Figure, 'Type', 'ConstantLine')), 1);

            % the selected section says what it lost; the map shows the band and the rejected cells
            app.selectSection(1);
            nA = nnz(near & C0.SourceRow == app.Rows(1));
            tc.verifySubstring(findall(app.Figure, 'Tag', 'label:detail').Text, ...
                sprintf('%d cells rejected within 100 um', nA));
            app.showTab('Section');
            app.waitForIdle();
            tc.verifyEqual(app.MapInfo.Rejected, nA);
            tc.verifyGreaterThanOrEqual(app.MapInfo.DepthLines, 1);
            tc.verifyEqual(app.MapInfo.Cells, nnz(app.Cells.SourceRow == app.Rows(1)));
            app.selectSection(3);
            tc.verifySubstring(findall(app.Figure, 'Tag', 'label:detail').Text, 'No brain surface');

            % the section export records the choice
            out = fullfile(tc.Root, 'out');
            mkdir(out);
            app.showTab('Distributions');
            R = readtable(app.exportSummary(fullfile(out, 'sections.csv')), 'TextType', 'string');
            tc.verifyTrue(all(R.MinDepthUm == 100));
            tc.verifyEqual(sum(R.RejectedNearSurface), nnz(near));
            tc.verifyEqual(sum(R.Cells), height(app.Cells));

            % values beyond the field's range are not taken; 0 takes every cell back
            app.setMinDepthUm(-5);
            app.setMinDepthUm(5000);
            tc.verifyEqual(findall(app.Figure, 'Tag', 'edit:minDepth').Value, 100);
            app.setMinDepthUm(0);
            tc.verifyEqual(height(app.Cells), height(C0));
            tc.verifySubstring(app.StatusText, 'No cell is rejected');
        end

        function checkedSectionsAndTheSelectedOne(tc)
            app = tc.open(true);
            app.setPopulation('all');
            nA = height(tc.Truth.A.ECM1.locs); nB = height(tc.Truth.B.ECM1.locs); nC = height(tc.Truth.C.ECM1.locs);
            tc.verifyEqual(height(app.View), nA + nB + nC);
            app.setUse(2, false);
            tc.verifyEqual(height(app.View), nA + nC, 'an unchecked section takes no part');
            tbl = findall(app.Figure, 'Tag', 'table:sections');
            tc.verifyEqual([tbl.Data{:, 1}], [true false true]);
            app.setUse("all", false);
            tc.verifyEqual(app.PlotInfo.Kind, "message");
            tc.verifySubstring(app.PlotInfo.Note, 'No checked section');
            app.setUse("all", true);
            tc.verifyEqual(height(app.View), nA + nB + nC);

            app.setScope('selected');
            tc.verifySubstring(app.PlotInfo.Note, 'Select a measured section');
            tc.verifyTrue(app.selectSection(char(tc.B + "_proj")));
            tc.verifyEqual(height(app.View), nB, 'within the selected section');
            tc.verifyEqual(unique(app.View.Section), "9001 1B R");
            tc.verifyEqual(app.SelectedRows, 2);
            tc.verifyFalse(app.selectSection('no such section'));
            tc.verifySubstring(findall(app.Figure, 'Tag', 'label:detail').Text, '7 kept cells');
        end

        function ownGroups(tc)
            app = tc.open(true);
            app.setPopulation('all');
            app.setMetric('DiameterUm');
            app.setGroup([1 2], 'control');
            app.setGroup(3, 'treated');
            tc.verifyTrue(isfile(fullfile(tc.Root, 'cellanalysis_groups.csv')));
            tbl = findall(app.Figure, 'Tag', 'table:sections');
            tc.verifyEqual(string(tbl.Data(:, 4))', ["control" "control" "treated"]);
            app.setGroupBy('Group');
            tc.verifyEqual(app.PlotInfo.Names, ["control"; "treated"]);
            app.setKind('pv');
            tc.verifyEqual(app.PlotInfo.Names, ["control"; "treated"], 'a group belongs to the section, whatever the channel');

            % imported groupings become choices of "Group by"
            f = fullfile(tc.Root, 'animals.csv');
            writetable(table(["9001"; "9002"], ["P30"; "P90"], 'VariableNames', {'Subject', 'Age'}), f);
            rep = app.importGroups(f);
            tc.verifyEqual(rep.matched, 3);
            dd = findall(app.Figure, 'Tag', 'dd:groupBy');
            tc.verifyTrue(ismember('Age', dd.ItemsData));
            app.setGroupBy('Age');
            tc.verifyEqual(app.PlotInfo.Names, ["P30"; "P90"]);

            % another window on the same folder reads them
            again = CellAnalysis(tc.Root, 'UseSettings', false, 'Scan', 'now');
            tc.addTeardown(@() tAnalysisGui.closeApp(again));
            tc.verifyEqual(unique(again.Sources.Group(again.Sources.Subject == "SUBJ-ID-9002")), "treated");
            tc.verifyEqual(unique(again.Sources.Age(again.Sources.Subject == "SUBJ-ID-9001")), "P30");
        end

        function theCellTypeChoosesTheMetrics(tc)
            app = tc.open(true);
            dd = findall(app.Figure, 'Tag', 'dd:metric');
            tc.verifyTrue(ismember('RingRadiusUm', dd.ItemsData), 'nets have net measures');
            app.setMetric('RingRadiusUm');
            tc.verifySubstring(dd.Tooltip, 'radial profile peaks', 'the tooltip explains the chosen metric');
            app.setKind('pv');
            tc.verifyEqual(app.Kind, "pv");
            tc.verifyEqual(numel(app.Rows), 3);
            tc.verifyFalse(ismember('RingRadiusUm', dd.ItemsData), 'PV cells have none');
            tc.verifyEqual(height(app.Cells), 10, 'the kept PV cells');
            tc.verifyEqual(unique(app.Cells.Key), "PV2");
            kd = findall(app.Figure, 'Tag', 'dd:kind');
            tc.verifyEqual(string(kd.ItemsData), ["pnn" "pv"]);
        end

        function theSectionTabShowsAndCorrectsTheSurface(tc)
            app = tc.open(true);
            app.setPopulation('all');
            app.showTab('Section');
            app.selectSection(1);
            app.waitForIdle();
            tc.verifyTrue(app.MapInfo.SurfaceOk, char(app.MapInfo.Message));
            tc.verifyEqual(app.MapInfo.Mode, "auto");
            tc.verifyEqual(app.MapInfo.Cells, height(tc.Truth.A.ECM1.locs));
            tc.verifyGreaterThanOrEqual(app.MapInfo.Lines, 1);
            tc.verifyTrue(logical(findall(app.Figure, 'Tag', 'btn:pickAreas').Enable));

            % switching the outside off leaves no surface; switching it on again brings it back
            tc.verifyFalse(app.toggleSurfaceArea([200 150]), 'a click on tissue does nothing');
            tc.verifySubstring(app.StatusText, 'That is tissue');
            tc.verifyTrue(app.toggleSurfaceArea([20 150]));
            tc.verifyFalse(app.MapInfo.SurfaceOk);
            tc.verifySubstring(app.MapInfo.Message, 'switched off');
            a = app.Sources(startsWith(app.Sources.Dataset, tc.A), :);
            tc.verifyTrue(all(a.State == "stale"), 'both channels of the section are out of date');
            tc.verifySubstring(app.StatusText, 'out of date');
            tc.verifyTrue(app.toggleSurfaceArea([20 150]));
            tc.verifyTrue(app.MapInfo.SurfaceOk);
            a = app.Sources(startsWith(app.Sources.Dataset, tc.A), :);
            tc.verifyTrue(all(a.State == "current"), 'as it was measured: up to date again');

            % a section without empty space: no surface until it is traced
            app.selectSection(3);
            app.waitForIdle();
            tc.verifyFalse(app.MapInfo.SurfaceOk);
            tc.verifySubstring(app.MapInfo.Message, 'trace it');
            tc.verifyTrue(all(isnan(app.Cells.SurfaceDistUm(app.Cells.Subject == "SUBJ-ID-9002"))));
            app.setSurfaceLine([30 5; 30 295]);
            tc.verifyTrue(app.MapInfo.SurfaceOk);
            tc.verifyEqual(app.MapInfo.Mode, "traced");
            tc.verifyEqual(findall(app.Figure, 'Tag', 'dd:surface').Value, 'traced');
            tc.verifyFalse(logical(findall(app.Figure, 'Tag', 'btn:pickAreas').Enable));
            tbl = findall(app.Figure, 'Tag', 'table:sections');
            tc.verifyEqual(string(tbl.Data{3, 6}), "out of date");
            tc.verifyEqual(string(tbl.Data{3, 7}), "traced");
            tc.verifyEqual(app.measure('selected'), 2, 'both channels of the selected section');
            c = app.Cells(app.Cells.Subject == "SUBJ-ID-9002", :);
            tc.verifyEqual(c.SurfaceDistUm, abs(c.X - 30) * tc.Truth.C.umPerPixel, 'AbsTol', 8);
            tc.verifyEqual(string(tbl.Data{3, 6}), "yes");
            app.setSurfaceMode('all');
            tc.verifyEqual(app.MapInfo.Mode, "all");
            tc.verifyEqual(string(tbl.Data{3, 7}), "every area");
            app.measure('selected');
            tc.verifyEqual(string(tbl.Data{3, 7}), "every area: not found", 'measured: the picture has no empty area');
        end

        function exports(tc)
            app = tc.open(true);
            app.setPopulation('all');
            app.setGroup([1 2], 'control');
            out = fullfile(tc.Root, 'out');
            mkdir(out);
            f = app.exportCells(fullfile(out, 'cells.csv'));
            T = readtable(f, 'TextType', 'string');
            tc.verifyEqual(height(T), height(app.View));
            for nm = ["Dataset" "Subject" "Section" "Group" "CellID" "SurfaceDistUm" "DiameterUm" "RingRadiusUm" "Colocalized" "Kept"]
                tc.verifyTrue(ismember(nm, string(T.Properties.VariableNames)), nm + " is exported");
            end
            tc.verifyFalse(ismember("SourceRow", string(T.Properties.VariableNames)));
            tc.verifyEqual(numel(unique(T.Subject)), 2);
            tc.verifySubstring(app.StatusText, 'cells written');

            g = app.exportSummary(fullfile(out, 'sections.csv'));
            R = readtable(g, 'TextType', 'string');
            tc.verifyEqual(height(R), 3, 'one row per section');
            tc.verifyEqual(sum(R.Cells), height(app.View));
            a = app.View(app.View.Section == "9001 1A L", :);
            tc.verifyEqual(R.DiameterUm(R.Section == "9001 1A L"), median(a.DiameterUm, 'omitnan'), 'RelTol', 1e-6, 'the median of the section');
            tc.verifyEqual(R.Colocalized(R.Section == "9001 1A L"), mean(a.Colocalized), 'RelTol', 1e-6, 'the fraction for a yes/no metric');
            tc.verifyEqual(R.Pairs(R.Section == "9001 1A L"), nnz(a.Colocalized));
            tc.verifyEqual(R.OtherCells(R.Section == "9001 1A L"), height(tc.Truth.A.PV2.locs));
            tc.verifyEqual(R.OtherChannel(R.Section == "9001 1A L"), "PV2");
            tc.verifyEqual(R.ColocChance(R.Section == "9001 1A L"), mean(a.ColocChance), 'RelTol', 1e-6);
            tc.verifyTrue(ismember("PartnerID", string(T.Properties.VariableNames)), 'the partner''s CellID is exported with each cell');
            tc.verifyEqual(R.Group(R.Section == "9001 1A L"), "control");

            p = app.saveFigure(fullfile(out, 'plot.png'));
            d = dir(p);
            tc.verifyGreaterThan(d.bytes, 2000);
            app.showTab('Section');
            app.selectSection(1);
            app.waitForIdle();
            p2 = app.saveFigure(fullfile(out, 'map.png'));
            tc.verifyGreaterThan(dir(p2).bytes, 2000);

            % nothing to export
            app.setUse("all", false);
            tc.verifyEmpty(app.exportCells(fullfile(out, 'none.csv')));
            tc.verifyFalse(isfile(fullfile(out, 'none.csv')));
        end

        function everyControlHasATooltipAndADisabledOneSaysWhy(tc)
            bare = CellAnalysis('UseSettings', false);
            tc.addTeardown(@() tAnalysisGui.closeApp(bare));
            app = tc.open(true);
            app.selectSection(1);
            for w = {bare, app}
                [h, tips, names] = tAnalysisGui.controls(w{1});
                tc.verifyGreaterThan(numel(h), 25, 'the window has its controls');
                for i = 1:numel(h)
                    tc.verifyGreaterThan(strlength(strip(tips(i))), 10, names(i) + " has no tooltip");
                    if isprop(h(i), 'Enable') && string(h(i).Enable) == "off"
                        tc.verifySubstring(tips(i), 'Unavailable now:', names(i) + " is disabled and does not say why");
                    else
                        tc.verifyFalse(contains(tips(i), 'Unavailable now:'), names(i) + " is enabled");
                    end
                end
                [u, ~, j] = unique(tips);
                dup = u(accumarray(j, 1) > 1);
                tc.verifyEmpty(dup, "two controls share a tooltip: " + strjoin(dup, " | "));
            end
            % the reasons
            tc.verifySubstring(findall(bare.Figure, 'Tag', 'btn:measureAll').Tooltip, 'no folder is scanned yet');
            tc.verifySubstring(findall(bare.Figure, 'Tag', 'btn:setGroup').Tooltip, 'no section is selected');
            tc.verifySubstring(findall(app.Figure, 'Tag', 'dd:xmetric').Tooltip, 'only the scatter plot');
            tc.verifyTrue(logical(findall(app.Figure, 'Tag', 'btn:measureSelected').Enable));
            app.setPlot('Scatter');
            tc.verifyTrue(logical(findall(app.Figure, 'Tag', 'dd:xmetric').Enable));
            tc.verifyTrue(logical(findall(app.Figure, 'Tag', 'dd:unit').Enable), ...
                'a scatter plot shows one point per cell, section or subject');
            % buttons with a shortcut show it
            tc.verifySubstring(findall(app.Figure, 'Tag', 'btn:scan').Text, '[F5]');
            tc.verifySubstring(findall(app.Figure, 'Tag', 'btn:measureSelected').Text, '[Ctrl+M]');
        end

        function keysAndClosing(tc)
            app = tc.open();
            tc.verifyTrue(app.handleKey('f5', {}));
            tc.verifySubstring(app.StatusText, '6 not measured yet', 'F5 scans again');
            tc.verifyFalse(app.handleKey('m', {}), 'm alone is not a shortcut');
            tc.verifyFalse(app.handleKey('q', {'control'}));
            app.selectSection(3);
            tc.verifyTrue(app.handleKey('m', {'control'}));
            tc.verifySubstring(app.StatusText, 'Measured 2 source(s)', 'Ctrl+M measures the selected section');
            closed = false;
            function mark(), closed = true; end
            app.addCloseListener(@mark);
            app.showTab('Section');                       % leaves a deferred map
            fig = app.Figure;
            delete(app);
            tc.verifyFalse(isvalid(fig));
            tc.verifyTrue(closed);
            t = timerfindall;
            names = string(arrayfun(@(x) string(x.Name), t, 'UniformOutput', false));
            tc.verifyFalse(any(startsWith(names, "CellAnalysis.")), 'no timer of the window is left');
        end

        function aDeferredScanShowsTheWindowFirst(tc)
            app = CellAnalysis(tc.Root, 'UseSettings', false);
            tc.addTeardown(@() tAnalysisGui.closeApp(app));
            tc.verifyEqual(height(app.Sources), 0, 'the constructor returns before the scan');
            app.waitForIdle();
            tc.verifyEqual(height(app.Sources), 6);
        end
    end
end

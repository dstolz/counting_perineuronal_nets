classdef tAnalysisStats < matlab.unittest.TestCase
    %tAnalysisStats  cellanalysis.Stats on a small hand-made table: what one observation is (a cell, a
    %   section's median, a subject's median), the summary numbers, histograms on common bins, cumulative
    %   distributions, and depth profiles of a metric and of the cell density (cells per mm^2 of tissue).
    %
    %   Three sections: A1 and A2 of subject S1 (group ctrl), B1 of subject S2 (group trt).
    %
    %   Run on the hidden desktop: pwsh -File tools\Run-Tests.ps1 tAnalysisStats

    properties
        C
        S
    end

    methods (TestMethodSetup)
        function build(tc)
            fx = tc.applyFixture(matlab.unittest.fixtures.TemporaryFolderFixture);
            ds = ["A1"; "A1"; "A1"; "A1"; "A2"; "A2"; "B1"; "B1"; "B1"];
            Dataset = ds;
            Key = repmat("ECM1", 9, 1);
            Subject = ["S1"; "S1"; "S1"; "S1"; "S1"; "S1"; "S2"; "S2"; "S2"];
            Group = ["ctrl"; "ctrl"; "ctrl"; "ctrl"; "ctrl"; "ctrl"; "trt"; "trt"; "trt"];
            SourceRow = [1; 1; 1; 1; 2; 2; 3; 3; 3];
            X = [1; 2; 3; 10; 5; 7; 20; 30; NaN];
            SurfaceDistUm = [10; 60; 60; 110; 20; 70; 30; 30; 120];
            Colocalized = [1; 0; 0; 1; 1; 1; 0; 0; 1];
            InAnalysis = true(9, 1);
            tc.C = table(Dataset, Key, Subject, Group, SourceRow, X, SurfaceDistUm, Colocalized, InAnalysis);
            % the sources: each section has 0.1 mm^2 of tissue in every 25 um of depth, down to 200 um
            JsonPath = strings(3, 1);
            for i = 1:3
                JsonPath(i) = fullfile(fx.Folder, sprintf('s%d.cellanalysis.json', i));
                J = struct('sources', struct('ECM1', struct('depthEdgesUm', 0:25:200, 'depthAreaUm2', repmat(1e5, 1, 8))));
                fid = fopen(JsonPath(i), 'w'); fprintf(fid, '%s', jsonencode(J)); fclose(fid);
            end
            tc.S = table(["A1"; "A2"; "B1"], repmat("ECM1", 3, 1), JsonPath, ["S1 A1"; "S1 A2"; "S2 B1"], ...
                'VariableNames', {'Dataset', 'Key', 'JsonPath', 'Section'});
        end
    end

    methods (Test)
        function oneObservationPerCell(tc)
            [v, g, names, n] = cellanalysis.Stats.values(tc.C, "X");
            tc.verifyEqual(sort(v), [1; 2; 3; 5; 7; 10; 20; 30], 'the cell without a value is left out');
            tc.verifyEqual(names, "All");
            tc.verifyEqual(g, ones(8, 1));
            tc.verifyEqual(n, ones(8, 1));
            [v, g, names] = cellanalysis.Stats.values(tc.C, "X", "Group", "cells");
            tc.verifyEqual(names, ["ctrl"; "trt"]);
            tc.verifyEqual(sort(v(g == 1)), [1; 2; 3; 5; 7; 10]);
            tc.verifyEqual(sort(v(g == 2)), [20; 30]);
        end

        function oneObservationPerSectionOrSubject(tc)
            [v, g, names, n] = cellanalysis.Stats.values(tc.C, "X", "Group", "section");
            tc.verifyEqual(names, ["ctrl"; "trt"]);
            tc.verifyEqual(sort(v(g == 1)), [2.5; 6], 'the median of each section');
            tc.verifyEqual(v(g == 2), 25);
            tc.verifyEqual(sort(n), [2; 2; 4], 'the cells behind each observation');
            [v, g] = cellanalysis.Stats.values(tc.C, "X", "Group", "subject");
            tc.verifyEqual(v(g == 1), 4, 'the median of all cells of subject S1');
            tc.verifyEqual(v(g == 2), 25);
            [v, ~, names] = cellanalysis.Stats.values(tc.C, "X", "", "subject");
            tc.verifyEqual(sort(v), [4; 25]);
            tc.verifyEqual(names, "All");
            tc.verifyError(@() cellanalysis.Stats.values(tc.C, "X", "", "litter"), 'cellanalysis:Stats:badUnit');
        end

        function aYesNoMetricGivesTheFraction(tc)
            [v, g] = cellanalysis.Stats.values(tc.C, "Colocalized", "Group", "section");
            tc.verifyEqual(sort(v(g == 1)), [0.5; 1], 'the share of colocalized cells of each section, not a median');
            tc.verifyEqual(v(g == 2), 1 / 3, 'AbsTol', 1e-12);
        end

        function summaryNumbers(tc)
            R = cellanalysis.Stats.summary(tc.C, "X", "Group", "section");
            tc.verifyEqual(R.Group, ["ctrl"; "trt"]);
            tc.verifyEqual(R.N, [2; 1]);
            tc.verifyEqual(R.Cells, [6; 2]);
            tc.verifyEqual(R.Mean, [4.25; 25]);
            tc.verifyEqual(R.Median, [4.25; 25]);
            tc.verifyEqual(R.SD(1), std([2.5 6]), 'AbsTol', 1e-12);
            tc.verifyEqual(R.SEM(1), std([2.5 6]) / sqrt(2), 'AbsTol', 1e-12);
            tc.verifyEqual([R.Min(1) R.Max(1)], [2.5 6]);
            A = cellanalysis.Stats.summary(tc.C, "X");
            tc.verifyEqual(A.N, 8);
            tc.verifyEqual(A.Mean, mean([1 2 3 10 5 7 20 30]));
            tc.verifyEqual(height(cellanalysis.Stats.summary(tc.C, "NoSuchMetric")), 0);
            tc.verifyEqual(height(cellanalysis.Stats.summary(table(), "X")), 0);
        end

        function histogramsShareTheirBins(tc)
            H = cellanalysis.Stats.histogram(tc.C, "X", "Group", "cells", struct('Bins', 6, 'Limits', [0 30]));
            tc.verifyEqual(H.Edges, 0:5:30);
            tc.verifyEqual(H.Names, ["ctrl"; "trt"]);
            tc.verifyEqual(H.Counts, [3 2 1 0 0 0; 0 0 0 0 1 1], 'the value 30 is in the last bin');
            tc.verifyEqual(sum(H.Share, 2), [1; 1], 'AbsTol', 1e-12, 'each group''s shares add up to 1');
            tc.verifyEqual(H.N, [6; 2]);
            clamp = cellanalysis.Stats.histogram(tc.C, "X", "", "cells", struct('Bins', 2, 'Limits', [2 6]));
            tc.verifyEqual(clamp.Counts, [3 5], 'values beyond the limits are counted in the end bins');
            auto = cellanalysis.Stats.histogram(tc.C, "X");
            tc.verifyEqual(sum(auto.Counts), 8);
            yn = cellanalysis.Stats.histogram(tc.C, "Colocalized");
            tc.verifyEqual(yn.Edges([1 end]), [0 1]);
            tc.verifyEqual(sum(yn.Counts), 9);
            none = cellanalysis.Stats.histogram(tc.C(1:0, :), "X");
            tc.verifyEqual(sum(none.Counts(:)), 0);
        end

        function cumulativeDistributions(tc)
            E = cellanalysis.Stats.cdf(tc.C, "X", "Group", "cells");
            tc.verifyEqual(E.X{1}, [1; 2; 3; 5; 7; 10]);
            tc.verifyEqual(E.F{1}, (1:6)' / 6);
            tc.verifyEqual(E.F{2}(end), 1);
            tc.verifyEqual(E.N, [6; 2]);
        end

        function groupsOfCells(tc)
            g = cellanalysis.Stats.groupOf(tc.C, "Colocalized");
            tc.verifyEqual(g(1:3), ["Colocalized"; "Not colocalized"; "Not colocalized"]);
            T = tc.C; T.Colocalized(:) = NaN;
            tc.verifyEqual(unique(cellanalysis.Stats.groupOf(T, "Colocalized")), "(no other channel)");
            T.Group(2) = "";
            g = cellanalysis.Stats.groupOf(T, "Group");
            tc.verifyEqual(g(2), "(none)");
            tc.verifyEqual(unique(cellanalysis.Stats.groupOf(tc.C, "")), "All");
            tc.verifyEqual(unique(cellanalysis.Stats.groupOf(tc.C, "Missing")), "All");
        end

        function densityByDepth(tc)
            D = cellanalysis.Stats.depthProfile(tc.C, tc.S, "Density", "Group", struct('BinUm', 50, 'MaxUm', 150));
            tc.verifyTrue(D.IsDensity);
            tc.verifyEqual(D.Edges, 0:50:150);
            tc.verifyEqual(D.Names, ["ctrl"; "trt"]);
            % each 50 um bin of a section holds 0.2 mm^2 of tissue
            a1 = [1 2 1] / 0.2; a2 = [1 1 0] / 0.2; b1 = [2 0 1] / 0.2;
            tc.verifyEqual(D.PerSection, [a1; a2; b1], 'AbsTol', 1e-9, 'cells per mm^2, per section');
            tc.verifyEqual(D.Mean, [(a1 + a2) / 2; b1], 'AbsTol', 1e-9, 'a group is the mean of its sections');
            tc.verifyEqual(D.Sem(1, :), std([a1; a2]) / sqrt(2), 'AbsTol', 1e-9);
            tc.verifyTrue(all(isnan(D.Sem(2, :))), 'one section has no standard error');
            tc.verifyEqual(D.N, [2 2 2; 1 1 1]);
            tc.verifyEqual(D.Sections, ["S1 A1"; "S1 A2"; "S2 B1"]);
            % cells outside the analysis region do not count, and a bin with too little tissue has no density
            T = tc.C; T.InAnalysis(1) = false;
            D2 = cellanalysis.Stats.depthProfile(T, tc.S, "Density", "", struct('BinUm', 50, 'MaxUm', 150));
            tc.verifyEqual(D2.PerSection(1, 1), 0);
            D3 = cellanalysis.Stats.depthProfile(tc.C, tc.S, "Density", "", struct('BinUm', 50, 'MaxUm', 150, 'MinAreaUm2', 1e6));
            tc.verifyTrue(all(isnan(D3.PerSection(:))));
            D4 = cellanalysis.Stats.depthProfile(tc.C, tc.S, "Density", "", struct('BinUm', 60, 'MaxUm', 150));
            tc.verifyEqual(D4.Edges(2), 50, 'the bin width is a multiple of 25 um');
        end

        function cellsAndTissueNearTheSurfaceAreRejected(tc)
            tc.verifyEqual(cellanalysis.Stats.areaBeyond(0:25:75, [1 1 1], 30), [0 0.8 1], 'AbsTol', 1e-12, ...
                'the share of each bin at 30 um or deeper');
            tc.verifyEqual(cellanalysis.Stats.areaBeyond(0:25:75, [1 2 3], 0), [1 2 3], 'no band: the area as it is');
            tc.verifyEqual(cellanalysis.Stats.areaBeyond(0:25:75, [1 2 3], 500), [0 0 0]);
            % 60 um: the bin [0, 50) has no tissue left, [50, 100) keeps 0.06 + 0.1 mm^2
            D = cellanalysis.Stats.depthProfile(tc.C, tc.S, "Density", "", ...
                struct('BinUm', 50, 'MaxUm', 150, 'MinDepthUm', 60));
            tc.verifyEqual(D.PerSection, [NaN 2 / 0.16, 1 / 0.2; NaN 1 / 0.16, 0; NaN 0, 1 / 0.2], 'AbsTol', 1e-9, ...
                'cells per mm^2 of the tissue beyond the band');
            M = cellanalysis.Stats.depthProfile(tc.C, tc.S, "X", "", ...
                struct('BinUm', 50, 'MaxUm', 150, 'MinCells', 1, 'MinDepthUm', 60));
            tc.verifyEqual(M.PerSection, [NaN 2.5 10; NaN 7 NaN], ...
                'the metric of the cells beyond the band; section B1 has none left with a value');
        end

        function metricByDepth(tc)
            D = cellanalysis.Stats.depthProfile(tc.C, tc.S, "X", "", struct('BinUm', 50, 'MaxUm', 150, 'MinCells', 1));
            tc.verifyFalse(D.IsDensity);
            tc.verifyEqual(D.PerSection, [1 2.5 10; 5 7 NaN; 25 NaN NaN], 'the mean of the metric in each bin of each section');
            tc.verifyEqual(D.Mean, [mean([1 5 25]), mean([2.5 7]), 10], 'AbsTol', 1e-12);
            tc.verifyEqual(D.N, [3 2 1]);
            few = cellanalysis.Stats.depthProfile(tc.C, tc.S, "X", "", struct('BinUm', 50, 'MaxUm', 150, 'MinCells', 2));
            tc.verifyEqual(few.PerSection(1, :), [NaN 2.5 NaN], 'a bin with fewer cells than MinCells gives no value');
        end

        function colocalizationPerSectionAndGroup(tc)
            T = tc.C;
            T.ColocChance = [0.25; 0; 0; 0.25; 0.5; 0; 0; 0; 0.125];
            Sec = table([1; 2; 3], [4; 2; 3], ["PV2"; "PV2"; "PV2"], [8; 2; 0], [2; 2; 1], [0.5; 0.5; NaN], ...
                'VariableNames', {'SourceRow', 'Cells', 'OtherKey', 'OtherCells', 'Pairs', 'TissueMm2'});
            K = cellanalysis.Stats.colocalization(T, Sec, "Group");
            S = K.Sections;
            tc.verifyEqual(S.Cells, [4; 2; 3]);
            tc.verifyEqual(S.Pairs, [2; 2; 1]);
            tc.verifyEqual(S.PctThis, [50; 100; 100 / 3], 'AbsTol', 1e-9, 'of the analyzed cells');
            tc.verifyEqual(S.PctOther, [25; 100; NaN], 'AbsTol', 1e-9, 'of the other channel''s cells');
            tc.verifyEqual(S.PctChance, 100 * [0.125; 0.25; 0.125 / 3], 'AbsTol', 1e-9);
            tc.verifyEqual(S.Enrichment, [4; 4; 8], 'AbsTol', 1e-9, 'times above chance');
            tc.verifyEqual(S.ThisPerMm2(1:2), [8; 4]);
            tc.verifyEqual(K.Names, ["ctrl"; "trt"]);
            R = K.Summary;
            tc.verifyEqual(R.Sections, [2; 1]);
            tc.verifyEqual(R.Cells, [6; 3]);
            tc.verifyEqual(R.OtherCells, [10; 0]);
            tc.verifyEqual(R.Pairs, [4; 1]);
            tc.verifyEqual(R.PctThis, [75; 100 / 3], 'AbsTol', 1e-9, 'the mean of the sections, not of the cells');
            tc.verifyEqual(R.SEM(1), std([50 100]) / sqrt(2), 'AbsTol', 1e-9);
            tc.verifyTrue(isnan(R.SEM(2)));
            tc.verifyEqual(R.PctOther(1), 62.5, 'AbsTol', 1e-9);
            % a section without another channel is left out; a grouping by cell is ignored
            Sec.OtherKey(3) = "";
            K2 = cellanalysis.Stats.colocalization(T, Sec, "Colocalized");
            tc.verifyEqual(height(K2.Sections), 2);
            tc.verifyEqual(K2.Names, "All");
            tc.verifyEqual(height(cellanalysis.Stats.colocalization(T, Sec(1:0, :), "").Sections), 0);
            % per section the fraction is a mean, whatever the values
            [v, ~] = cellanalysis.Stats.values(T, "ColocChance", "", "section");
            tc.verifyEqual(sort(v), sort([0.125; 0.25; 0.125 / 3]), 'AbsTol', 1e-9);
        end

        function aCellLevelGroupingSplitsEachSection(tc)
            D = cellanalysis.Stats.depthProfile(tc.C, tc.S, "Density", "Colocalized", struct('BinUm', 50, 'MaxUm', 150));
            tc.verifyEqual(D.Names, ["Colocalized"; "Not colocalized"]);
            tc.verifyEqual(size(D.PerSection, 1), 5, 'one profile per section and group that has cells');
            tc.verifyEqual(D.Mean(1, :), mean([1 0 1; 1 1 0; 0 0 1] / 0.2), 'AbsTol', 1e-9);
        end
    end
end

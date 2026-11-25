classdef tAnalysisDatabase < matlab.unittest.TestCase
    %tAnalysisDatabase  The lab database's tags and variables in Cell Analysis: a scan reads them from
    %   this computer's cache and never asks the server; Check subjects asks, and then every tag
    %   namespace, bare tag and variable of the subjects here is a grouping, every number variable can
    %   be plotted as the metric or on the horizontal axis of the scatter plot (one point per cell,
    %   section or subject), the sections can be checked by a tag filter, and the exports carry the
    %   columns; and the same window without the client, which says why it offers none of it.
    %
    %   Three sections as in tAnalysisGui: A and B of subject 9001 (cohort:a, condition:noise, pilot;
    %   age at perfusion 92 d, housing pair) and C of subject 9002 (cohort:b, condition:sham; age at
    %   perfusion 120.5 d), from tCelldbFacts.seed. Everything runs against labclient.FakeBackend
    %   (tests\celldb_test_client): no server is contacted and nothing of the user's is touched.
    %   Needs the labclient package with interface version 4; skipped without it and under
    %   tools\Run-Tests.ps1 -WithoutClient, except the last two tests.
    %
    %   Run on the hidden desktop: pwsh -File tools\Run-Tests.ps1 tAnalysisDatabase

    properties
        Root
        Fake
        Restore = {}
        Top string = ""
    end

    methods (TestMethodSetup)
        function buildSections(tc)
            fx = tc.applyFixture(matlab.unittest.fixtures.TemporaryFolderFixture);
            tc.Root = fullfile(fx.Folder, 'HISTOLOGY');
            tc.applyFixture(matlab.unittest.fixtures.EnvironmentVariableFixture('CELLDB_PROVENANCE_DIR', ...
                fullfile(fx.Folder, 'no_provenance')));
            [~, ta] = tManagerScan.section(tc.Root, fullfile('SUBJ-ID-9001', 'A'), tAnalysisGui.A);
            [~, tb] = tManagerScan.section(tc.Root, fullfile('SUBJ-ID-9001', 'B'), tAnalysisGui.B);
            tManagerScan.section(tc.Root, fullfile('SUBJ-ID-9002', 'C'), tAnalysisGui.C);
            addEmptyMargin(ta.paths.tif, tAnalysisGui.Margin);
            addEmptyMargin(tb.paths.tif, tAnalysisGui.Margin);
            tc.addTeardown(@() tc.restoreClient());
        end
    end

    methods
        function restoreClient(tc)
            for k = numel(tc.Restore):-1:1
                tc.Restore{k} = [];
            end
            tc.Restore = {};
            if tc.Top ~= "" && isfolder(tc.Top)
                rmdir(tc.Top, 's');
            end
            try celldb.available('Refresh', true); catch, end
        end

        function useClient(tc)
            tc.assumeNotEqual(string(getenv('CELLDB_NO_CLIENT')), "1", 'run without the client');
            [ok, why] = celldb.available('Refresh', true);
            tc.assumeTrue(ok, "The lab database client is not usable here: " + why);
            [ok, why] = labclient.Api.atLeast(4);
            tc.assumeTrue(ok, "The lab database client here keeps no tags: " + string(why));
            [tc.Fake, tc.Restore, tc.Top] = celldb_test_client();
            celldb.available('Refresh', true);
            tCelldbFacts.seed(tc.Fake);
        end

        function app = open(tc, measure)
            app = CellAnalysis(tc.Root, 'UseSettings', false, 'Scan', 'now');
            tc.addTeardown(@() tAnalysisGui.closeApp(app));
            drawnow;
            if nargin > 1 && measure
                tc.assertEqual(app.measure('all'), 6, app.StatusText);
                app.setPopulation("all");        % the sections are not curated: every detection
            end
        end
    end

    methods (Static)
        function items = itemsOf(app, tag)
            dd = findall(app.Figure, 'Tag', tag);
            items = struct('Items', string(dd.Items), 'Data', string(dd.ItemsData));
        end
    end

    methods (Test)

        function aScanReadsTheCacheAndCheckSubjectsAsksTheDatabase(tc)
            tc.useClient();
            app = tc.open();
            tc.verifyEqual(height(app.DbColumns), 0, 'nothing is known before the database was asked');
            tc.verifyEmpty(tc.Fake.Calls(ismember(string(tc.Fake.Calls), ["subjectCurrent" "entityTags" "entityVariables"])), ...
                'a scan never asks the server');
            g = tAnalysisDatabase.itemsOf(app, 'dd:groupBy');
            tc.verifyFalse(any(startsWith(g.Items, ["Tag:" "Variable:"])));
            btn = findall(app.Figure, 'Tag', 'btn:checkSubjects');
            tc.verifyTrue(logical(btn.Enable));

            r = app.checkSubjects();
            tc.verifyTrue(r.ok && r.tagsRead, r.message);
            tc.verifySubstring(app.StatusText, 'tags and variables were read');
            D = app.DbColumns;
            tc.verifyEqual(sort(D.Name)', sort(["Tag_cohort" "Tag_condition" "HasTag_pilot" "Var_age_at_perfusion" "Var_housing"]), ...
                'the tags and variables of the subjects here, and of no other');
            S = app.Sources;
            tc.verifyEqual(unique(S.Tag_cohort(S.Subject == "SUBJ-ID-9001")), "a");
            tc.verifyEqual(unique(S.Tag_cohort(S.Subject == "SUBJ-ID-9002")), "b");
            tc.verifyEqual(unique(S.Var_age_at_perfusion(S.Subject == "SUBJ-ID-9002")), 120.5);
            tc.verifyEqual(unique(S.DbTags(S.Subject == "SUBJ-ID-9001")), "cohort:a condition:noise pilot");
            tc.verifyEqual(unique(S.Sex(S.Subject == "SUBJ-ID-9002")), "M", 'what was read before is still read');

            g = tAnalysisDatabase.itemsOf(app, 'dd:groupBy');
            tc.verifyEqual(g.Items(g.Data == "Tag_cohort"), "Tag: cohort");
            tc.verifyEqual(g.Items(g.Data == "HasTag_pilot"), "Tag: pilot");
            tc.verifyEqual(g.Items(g.Data == "Var_housing"), "Variable: housing");
            tc.verifyEqual(g.Items(g.Data == "Var_age_at_perfusion"), "Variable: Age at perfusion (d)");
            for tag = ["dd:metric" "dd:xmetric"]
                m = tAnalysisDatabase.itemsOf(app, tag);
                tc.verifyEqual(m.Items(m.Data == "Var_age_at_perfusion"), "Variable: Age at perfusion (d)", ...
                    'a number variable can be plotted');
                tc.verifyFalse(any(m.Data == "Var_housing"), 'a text variable is a grouping, not a metric');
            end

            % the detail of a section says what the database knows
            tc.assertTrue(app.selectSection(1));
            txt = string(findall(app.Figure, 'Tag', 'label:detail').Text);
            tc.verifySubstring(strjoin(txt, " "), 'Tags: cohort:a condition:noise pilot');
            tc.verifySubstring(strjoin(txt, " "), 'Age at perfusion = 92 d');

            % a new window finds the answers in the cache, with the server out of reach
            tc.Fake.Reachable = false;
            labclient.DB.disconnect();
            again = tc.open();
            tc.verifyEqual(sort(again.DbColumns.Name), sort(D.Name));
        end

        function tagsAndVariablesGroupAndPlot(tc)
            tc.useClient();
            celldb.refreshSubjects(["SUBJ-ID-9001"; "SUBJ-ID-9002"]);
            app = tc.open(true);
            tc.assertNotEmpty(app.Cells);
            tc.verifyTrue(all(ismember(["Tag_cohort" "HasTag_pilot" "Var_age_at_perfusion" "Var_housing"], ...
                string(app.Cells.Properties.VariableNames))), 'every cell carries its subject''s tags and variables');
            tc.verifyClass(app.Cells.Var_age_at_perfusion, 'double');

            % grouped by a tag namespace, a bare tag and a text variable
            app.setPlot('Box by group');
            app.setMetric('Mean');
            app.setUnit('section');
            app.setGroupBy('Tag_cohort');
            tc.verifyEqual(app.PlotInfo.Names, ["a"; "b"]);
            tc.verifyEqual(app.PlotInfo.N, [2; 1], 'sections per cohort');
            app.setGroupBy('HasTag_pilot');
            tc.verifyEqual(app.PlotInfo.Names, ["not pilot"; "pilot"]);
            app.setGroupBy('Var_housing');
            tc.verifyEqual(app.PlotInfo.Names, ["(none)"; "pair"], 'a subject without the variable is in no group');
            app.setGroupBy('Var_age_at_perfusion');
            tc.verifyEqual(app.PlotInfo.Names, ["120.5"; "92"], 'a number variable groups by its values');

            % a number variable as the metric: one value per subject
            app.setGroupBy('none');
            app.setPlot('Histogram');
            app.setMetric('Var_age_at_perfusion');
            app.setUnit('subject');
            tc.verifyEqual(app.PlotInfo.Kind, "histogram");
            tc.verifySubstring(app.PlotInfo.XLabel, 'Age at perfusion (d)');
            tc.verifyEqual(app.Summary.N, 2, 'two subjects');
            tc.verifyEqual(app.Summary.Min, 92);
            tc.verifyEqual(app.Summary.Max, 120.5);
            tc.verifySubstring(findall(app.Figure, 'Tag', 'dd:metric').Tooltip, 'age at perfusion');

            % a measurement against a number variable, one point per subject and per section
            app.setPlot('Scatter');
            app.setXMetric('Var_age_at_perfusion');
            app.setMetric('Mean');
            tc.verifyTrue(logical(findall(app.Figure, 'Tag', 'dd:unit').Enable));
            tc.verifyEqual(app.PlotInfo.Kind, "scatter");
            tc.verifySubstring(app.PlotInfo.XLabel, 'Age at perfusion (d)');
            tc.verifyEqual(sum(app.PlotInfo.N), 2, 'one point per subject');
            [x, y, ~, ~, n] = cellanalysis.Stats.pairs(app.View, "Var_age_at_perfusion", "Mean", "", "subject");
            tc.verifyEqual(sort(x), [92; 120.5]);
            tc.verifyEqual(sum(n), nnz(isfinite(app.View.Mean)));
            young = app.View.Subject == "SUBJ-ID-9001" & isfinite(app.View.Mean);
            tc.verifyEqual(y(x == 92), median(app.View.Mean(young)), 'AbsTol', 1e-9);
            app.setUnit('section');
            tc.verifyEqual(sum(app.PlotInfo.N), 3, 'one point per section');
            app.setUnit('cells');
            tc.verifyEqual(sum(app.PlotInfo.N), nnz(isfinite(app.View.Mean)), 'one point per cell');
            app.setGroupBy('Tag_condition');
            tc.verifyEqual(app.PlotInfo.Names, ["noise"; "sham"]);

            % the exports carry the columns
            out = fileparts(tc.Root);
            f = app.exportCells(fullfile(out, 'cells.csv'));
            T = readtable(f, 'TextType', 'string');
            tc.verifyTrue(all(ismember(["Tag_cohort" "Tag_condition" "HasTag_pilot" "Var_age_at_perfusion" "Var_housing"], ...
                string(T.Properties.VariableNames))));
            tc.verifyEqual(unique(T.Var_age_at_perfusion(T.Subject == "SUBJ-ID-9002")), 120.5);
            g = app.exportSummary(fullfile(out, 'sections.csv'));
            R = readtable(g, 'TextType', 'string');
            tc.verifyEqual(height(R), 3);
            tc.verifyEqual(sort(R.Tag_cohort)', ["a" "a" "b"]);
            tc.verifyEqual(sort(R.Var_age_at_perfusion)', [92 92 120.5]);
        end

        function sectionsAreTickedByATagFilter(tc)
            tc.useClient();
            celldb.refreshSubjects(["SUBJ-ID-9001"; "SUBJ-ID-9002"]);
            app = tc.open();
            subj = app.Sources.Subject(app.Rows);
            n = app.useByTags("Cohort:A");
            tc.verifyEqual(n, 2);
            tc.verifyEqual(app.Use(app.Rows), subj == "SUBJ-ID-9001");
            tbl = findall(app.Figure, 'Tag', 'table:sections');
            tc.verifyEqual([tbl.Data{:, 1}]', subj == "SUBJ-ID-9001", 'the table shows the check marks');
            tc.verifySubstring(app.StatusText, '2 of 3 section(s) checked');
            n = app.useByTags("-condition:noise");
            tc.verifyEqual(n, 1);
            tc.verifyEqual(app.Use(app.Rows), subj == "SUBJ-ID-9002");
            n = app.useByTags("cohort:a -qc:fial");
            tc.verifyEqual(n, 2);
            tc.verifySubstring(app.StatusText, 'qc:fial', 'a tag nobody here carries is said, not silently ignored');
            before = app.Use;
            tc.verifyEqual(app.useByTags(""), 2, 'an empty filter changes nothing');
            tc.verifyEqual(app.Use, before);
        end

        function aSubjectVariableIsOneValuePerSubject(tc)
            % pure: the pairs behind the scatter plot
            C = table(["s1"; "s1"; "s1"; "s2"; "s2"], [1; 1; 2; 3; 3], [10; 20; 60; 5; NaN], [30; 30; 30; 50; 50], ...
                ["a"; "a"; "a"; "b"; "b"], 'VariableNames', {'Subject', 'SourceRow', 'M', 'Age', 'G'});
            C.Dataset = "d" + string(C.SourceRow);
            C.Key = repmat("ECM1", 5, 1);
            [x, y, g, names, n] = cellanalysis.Stats.pairs(C, "Age", "M", "G", "cells");
            tc.verifyEqual([x y], [30 10; 30 20; 30 60; 50 5], 'only the cells where both are finite');
            tc.verifyEqual(names(g)', ["a" "a" "a" "b"]);
            tc.verifyEqual(n, ones(4, 1));
            [x, y, ~, ~, n] = cellanalysis.Stats.pairs(C, "Age", "M", "", "section");
            tc.verifyEqual([x y n], [30 15 2; 30 60 1; 50 5 1]);
            [x, y, g, names, n] = cellanalysis.Stats.pairs(C, "Age", "M", "G", "subject");
            tc.verifyEqual([x y n], [30 20 3; 50 5 1], 'the median of the subject''s cells against its one value');
            tc.verifyEqual(names(g), ["a"; "b"]);
            [x, y] = cellanalysis.Stats.pairs(C, "Age", "NoSuchMetric", "", "cells");
            tc.verifyEmpty(x);
            tc.verifyEmpty(y);
        end

        function aSourcesTableKeepsItsDatabaseColumns(tc)
            tc.useClient();
            celldb.refreshSubjects(["SUBJ-ID-9001"; "SUBJ-ID-9002"]);
            S = cellanalysis.Project.sources(tc.Root);
            D = cellanalysis.Project.databaseColumns(S);
            tc.verifyEqual(height(D), 5);
            tc.verifyTrue(all(ismember(D.Name, cellanalysis.Project.factors(S))), 'each is a factor a plot can be grouped by');
            tc.verifyFalse(any(ismember(["DbTags" "DbVariables"], cellanalysis.Project.factors(S))));
            tc.verifyEqual(height(cellanalysis.Project.databaseColumns(S(2, :))), 5, 'a row of the table knows them too');
            % a grouping file cannot overwrite what the database said
            G = cellanalysis.Project.readGroups(tc.Root);
            G = cellanalysis.Project.setGroup(G, S, 1, "mine", "Tag_cohort");
            S2 = cellanalysis.Project.applyGroups(S, G);
            tc.verifyEqual(S2.Tag_cohort, S.Tag_cohort);
            % the tags changed in the database and were read again: the columns follow
            tc.Fake.Tags = tc.Fake.Tags(tc.Fake.Tags.tag ~= "Pilot", :);
            celldb.refreshSubjects(["SUBJ-ID-9001"; "SUBJ-ID-9002"]);
            S3 = cellanalysis.Project.readDatabase(S);
            tc.verifyFalse(ismember("HasTag_pilot", string(S3.Properties.VariableNames)));
            tc.verifyEqual(height(cellanalysis.Project.databaseColumns(S3)), 4);
            tc.verifyEqual(width(S3), width(S) - 1);
        end

        function withoutTheClientTheWindowWorksAndSaysWhy(tc)
            tc.applyFixture(matlab.unittest.fixtures.EnvironmentVariableFixture('CELLDB_NO_CLIENT', '1'));
            celldb.available('Refresh', true);
            tc.addTeardown(@() celldb.available('Refresh', true));
            app = tc.open();
            tc.verifyEqual(height(app.Sources), 6);
            tc.verifyEqual(height(app.DbColumns), 0);
            btn = findall(app.Figure, 'Tag', 'btn:checkSubjects');
            tc.verifyFalse(logical(btn.Enable));
            tc.verifySubstring(btn.Tooltip, 'Unavailable now');
            tc.verifySubstring(btn.Tooltip, 'CELLDB_NO_CLIENT');
            n = app.useByTags("cohort:a");
            tc.verifyEqual(n, 0);
            tc.verifySubstring(app.StatusText, 'shows nothing');
            r = app.checkSubjects();
            tc.verifyFalse(r.ok);
            tc.verifyEqual(height(app.Sources), 6, 'the window is as it was');
        end

    end
end

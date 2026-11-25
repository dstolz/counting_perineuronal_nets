classdef tManagerGui < matlab.unittest.TestCase
    %tManagerGui  The Cell Dataset Manager window, driven through its seams (no dialogs): the list shows
    %   one row per dataset with the subject, section, curation progress and status; Find and Show
    %   narrow it and keep the selection when it is still listed; Next to curate walks the unfinished
    %   datasets and picks their unfinished source; Enter / a double-click asks for Cell Curator (Cell
    %   Discovery for an image without detections) with the selected dataset and source; the report is
    %   written; the preview is drawn a moment after the selection and comes from the cache the second
    %   time; every interactive control has a tooltip, no two the same, and a disabled one says why;
    %   closing the window leaves no timer behind.
    %
    %   Three sections: A (subject 9001) curated and complete, B (9001) in curation, C (9002) detected
    %   only, and D (9002), an image without detections.
    %
    %   Run on the hidden desktop: pwsh -File tools\Run-Tests.ps1 tManagerGui

    properties (Constant)
        A = "SUBJ-ID-9001IHC_ECM26A260519S2_1A_L_WFA-PV_Z3_260511_1"
        B = "SUBJ-ID-9001IHC_ECM26A260519S2_1B_R_WFA-PV_Z3_260511_1"
        C = "SUBJ-ID-9002IHC_ECM26A260519S2_2A_L_WFA-PV_Z3_260512_1"
        D = "SUBJ-ID-9002IHC_ECM26A260519S2_2B_R_WFA-PV_Z3_260512_1"
        Interactive = ["matlab.ui.control.Button" "matlab.ui.control.StateButton" ...
            "matlab.ui.control.DropDown" "matlab.ui.control.CheckBox" "matlab.ui.control.Slider" ...
            "matlab.ui.control.Spinner" "matlab.ui.control.EditField" "matlab.ui.control.NumericEditField" ...
            "matlab.ui.control.ListBox" "matlab.ui.control.Table" "matlab.ui.container.Tab" ...
            "matlab.ui.control.TextArea" "matlab.ui.control.ToggleButton" "matlab.ui.control.RadioButton"]
    end

    properties
        Root
        Truth
    end

    methods (TestClassSetup)
        function buildSections(tc)
            fx = tc.applyFixture(matlab.unittest.fixtures.TemporaryFolderFixture);
            tc.Root = fullfile(fx.Folder, 'HISTOLOGY');
            tc.applyFixture(matlab.unittest.fixtures.EnvironmentVariableFixture('CELLDB_PROVENANCE_DIR', ...
                fullfile(fx.Folder, 'no_provenance')));
            [~, ta] = tManagerScan.section(tc.Root, fullfile('SUBJ-ID-9001', 'A'), tc.A);
            [~, tb] = tManagerScan.section(tc.Root, fullfile('SUBJ-ID-9001', 'B'), tc.B);
            [~, tcc] = tManagerScan.section(tc.Root, fullfile('SUBJ-ID-9002', 'C'), tc.C);
            tManagerScan.curate(ta.paths.ecm1Locs, 6, 0, true);
            tManagerScan.curate(ta.paths.pv2Locs, 5, 0, true);
            tManagerScan.curate(tb.paths.ecm1Locs, 4, 2, true);     % B: one source complete,
            tManagerScan.curate(tb.paths.pv2Locs, 3, 1, false);     %    the other started
            folderD = fullfile(tc.Root, 'SUBJ-ID-9002', 'D');
            mkdir(folderD);
            copyfile(tcc.paths.tif, fullfile(folderD, tc.D + "_proj.tif"));
            tc.Truth = struct('A', ta, 'B', tb, 'C', tcc);
        end
    end

    methods
        function app = open(tc)
            app = CellDatasetManager(tc.Root, 'UseSettings', false, 'Scan', 'now');
            tc.addTeardown(@() tManagerGui.closeApp(app));
            app.LaunchFcn = @(req) [];                      % never open another tool from a test
            drawnow;
        end

        function names = listed(~, app)
            names = strings(1, numel(app.View));
            for r = 1:numel(app.View)
                names(r) = string(app.Datasets(app.View(r)).Base);
            end
        end
    end

    methods (Static)
        function closeApp(app)
            if ~isempty(app) && isvalid(app)
                delete(app);
            end
        end

        function rows = markedRows(tbl)
            %markedRows  The rows of a uitable that carry a whole-row style (the selected source's mark).
            S = tbl.StyleConfigurations;
            rows = zeros(1, 0);
            for i = 1:height(S)
                if string(S.Target(i)) == "row"
                    rows = [rows, reshape(double(S.TargetIndex{i}), 1, [])]; %#ok<AGROW>
                end
            end
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
                if isprop(h(i), 'Text'), nm = nm + " '" + string(h(i).Text) + "'"; end
                names(i) = nm;
            end
        end
    end

    methods (Test)
        function theListShowsEveryDatasetOnce(tc)
            app = tc.open();
            tc.assertNumElements(app.Datasets, 4, 'three sections with detections and one image');
            tc.verifyEqual(sort(tc.listed(app)), sort([tc.A tc.B tc.C tc.D] + "_proj"));
            tbl = findall(app.Figure, 'Type', 'uitable');
            ds = tbl(arrayfun(@(t) isequal(t.ColumnName(:)', CellDatasetManager.DATASET_COLUMNS), tbl));
            tc.assertNumElements(ds, 1, 'the dataset table');
            T = cell2table(ds.Data, 'VariableNames', {'Subject', 'Section', 'Name', 'Sources', 'Detections', ...
                'Rescored', 'Reviewed_', 'Curated', 'Kept', 'Status', 'Database', 'Tags'});
            tc.assertEqual(height(T), 4);
            a = T(string(T.Name) == tc.A + "_proj", :);
            tc.verifyEqual(string(a.Subject), "SUBJ-ID-9001");
            tc.verifyEqual(string(a.Section), "1A L");
            tc.verifyEqual(a.Sources, 2);
            tc.verifyEqual(a.Detections, height(tc.Truth.A.ECM1.locs) + height(tc.Truth.A.PV2.locs));
            tc.verifyEqual(string(a.Rescored), "2/2");
            tc.verifyEqual(a.Reviewed_, 100);
            tc.verifyEqual(string(a.Curated), "2/2");
            tc.verifyEqual(a.Kept, 11);
            tc.verifyEqual(string(a.Status), "Curated");
            b = T(string(T.Name) == tc.B + "_proj", :);
            tc.verifyEqual(string(b.Curated), "1/2");
            tc.verifyEqual(string(b.Status), "Curating");
            tc.verifyEqual(b.Kept, 4 + 3);
            tc.verifyGreaterThan(b.Reviewed_, 0);
            tc.verifyLessThan(b.Reviewed_, 100);
            d = T(string(T.Name) == tc.D + "_proj", :);
            tc.verifyEqual(string(d.Status), "New (image only)");
            tc.verifyEqual(d.Sources, 0);
            tc.verifyEqual(string(d.Subject), "SUBJ-ID-9002");
            tc.verifySubstring(app.StatusText, '4 dataset(s)');

            % the stat cards count everything found
            lbl = findall(app.Figure, 'Type', 'uilabel');
            texts = string(arrayfun(@(l) string(strjoin(string(l.Text), " ")), lbl));
            tc.verifyTrue(any(texts == "3/6"), 'Sources curated: 3 of 6');
            tc.verifyTrue(any(texts == "Sources curated"));
        end

        function findAndShowNarrowTheList(tc)
            app = tc.open();
            app.setFilter('9002');
            tc.verifyEqual(sort(tc.listed(app)), sort([tc.C tc.D] + "_proj"));
            tc.verifySubstring(app.StatusText, '2 of 4');
            app.setFilter('9001 1b');                             % every word, any case
            tc.verifyEqual(tc.listed(app), tc.B + "_proj");
            app.setFilter('curated');                             % the status is searched too
            tc.verifyEqual(tc.listed(app), tc.A + "_proj");
            app.setFilter('', 'To detect');
            tc.verifyEqual(tc.listed(app), tc.D + "_proj");
            app.setFilter('', 'To curate');
            tc.verifyEqual(tc.listed(app), tc.C + "_proj");
            app.setFilter('', 'In curation');
            tc.verifyEqual(tc.listed(app), tc.B + "_proj");
            app.setFilter('', 'Curated');
            tc.verifyEqual(tc.listed(app), tc.A + "_proj");
            app.setFilter('', 'Database: not sent');
            tc.verifyEqual(sort(tc.listed(app)), sort([tc.A tc.B] + "_proj"), ...
                'completed sources whose state was not sent from here');
            app.setFilter('no such thing', 'All datasets');
            tc.verifyEmpty(app.View);
            tc.verifyError(@() app.setFilter('', 'Nonsense'), 'CellDatasetManager:show');

            % the selection stays while it is listed, and goes when it is not
            app.setFilter('');
            tc.assertTrue(app.selectDataset(tc.B + "_proj"));
            tc.assertTrue(app.selectSource('PV2'));
            app.setFilter('9001');
            tc.verifyEqual(string(app.selectedDataset().Base), tc.B + "_proj");
            app.setFilter('9002');
            tc.verifyEmpty(app.selectedDataset());
            tc.verifyEqual(app.SelectedDatasetIndex, 0);
            % selecting a dataset the filter hides clears the filter
            tc.assertTrue(app.selectDataset(tc.A + "_proj"));
            tc.verifyNumElements(app.View, 4);
            tc.verifyFalse(app.selectDataset('no such dataset'));
        end

        function nextToCurateWalksTheUnfinished(tc)
            app = tc.open();
            tc.assertTrue(app.nextToCurate());
            first = string(app.selectedDataset().Base);
            tc.verifyTrue(ismember(first, [tc.B tc.C] + "_proj"), 'an unfinished dataset with detections');
            tc.assertTrue(app.nextToCurate());
            second = string(app.selectedDataset().Base);
            tc.verifyEqual(sort([first second]), sort([tc.B tc.C] + "_proj"), 'then the other one');
            tc.assertTrue(app.nextToCurate());
            tc.verifyEqual(string(app.selectedDataset().Base), first, 'and round again');
            % in B the unfinished source is PV2
            app.selectDataset(tc.A + "_proj");
            while string(app.selectedDataset().Base) ~= tc.B + "_proj"
                tc.assertTrue(app.nextToCurate());
            end
            tc.verifyEqual(app.selectedSource().Key, 'PV2');
            tc.verifySubstring(app.StatusText, 'cells reviewed');
            % nothing left in a list of finished datasets
            app.setFilter('', 'Curated');
            tc.verifyFalse(app.nextToCurate());
            tc.verifySubstring(app.StatusText, 'Nothing left to curate');
            tc.verifyTrue(app.handleKey('e', {'control'}), 'Ctrl+E is Next to curate');
            tc.verifyFalse(app.handleKey('e', {}), 'a plain letter is not a shortcut');
        end

        function enterOpensTheRightTool(tc)
            app = tc.open();
            app.LaunchFcn = @(req) assignin('base', 'tManagerGui_lastLaunch', req);
            tc.addTeardown(@() evalin('base', 'clear tManagerGui_lastLaunch'));

            app.openSelected();
            tc.verifySubstring(app.StatusText, 'Select a dataset first');

            app.selectDataset(tc.B + "_proj");
            app.selectSource('PV2');
            tc.verifyTrue(app.handleKey('return', {}));
            req = evalin('base', 'tManagerGui_lastLaunch');
            tc.verifyEqual(req.Tool, 'curator');
            tc.verifyEqual(req.Folder, tc.Root, 'Cell Curator opens on the parent directory');
            tc.verifyEqual(string(req.Base), tc.B + "_proj");
            tc.verifyEqual(req.Key, 'PV2');
            tc.verifyEqual(app.LastLaunch, req);

            app.selectDataset(tc.D + "_proj");                   % an image without detections
            app.openSelected();
            req = evalin('base', 'tManagerGui_lastLaunch');
            tc.verifyEqual(req.Tool, 'discovery');
            tc.verifyEqual(req.Folder, fullfile(tc.Root, 'SUBJ-ID-9002', 'D'));

            app.selectDataset(tc.C + "_proj");                   % no source row selected: no key
            app.launch('curator');
            req = evalin('base', 'tManagerGui_lastLaunch');
            tc.verifyEqual(string(req.Base), tc.C + "_proj");
            tc.verifyEqual(req.Key, '');

            app.launch('analysis');                              % Analyze...: the whole scanned folder
            req = evalin('base', 'tManagerGui_lastLaunch');
            tc.verifyEqual(req.Tool, 'analysis');
            tc.verifyEqual(req.Folder, tc.Root);
            tc.verifyEqual(string(req.Base), tc.C + "_proj");
            tc.verifyError(@() app.launch('nonsense'), 'CellDatasetManager:tool');
        end

        function theSelectedDatasetIsDescribed(tc)
            app = tc.open();
            app.selectDataset(tc.B + "_proj");
            app.waitForIdle();
            lbl = findall(app.Figure, 'Type', 'uilabel');
            texts = string(arrayfun(@(l) string(strjoin(string(l.Text), newline)), lbl));
            detail = texts(contains(texts, "Status: Curating"));
            tc.assertNumElements(detail, 1, 'the detail text');
            tc.verifySubstring(detail, "SUBJ-ID-9001");
            tc.verifySubstring(detail, "section 1B, right hemisphere, stain WFA-PV");
            tc.verifySubstring(detail, "1 of 2 source(s) complete");
            tc.verifySubstring(detail, "7 kept");
            tbl = findall(app.Figure, 'Type', 'uitable');
            src = tbl(arrayfun(@(t) isequal(t.ColumnName(:)', CellDatasetManager.SOURCE_COLUMNS), tbl));
            tc.assertNumElements(src, 1, 'the source table');
            S = cell2table(src.Data, 'VariableNames', CellDatasetManager.SOURCE_COLUMNS);
            tc.assertEqual(height(S), 2);
            e = S(string(S.Source) == "ECM1", :);
            p = S(string(S.Source) == "PV2", :);
            tc.verifyEqual(string(e.Complete), "Yes");
            tc.verifyEqual(e.Kept, 4);
            tc.verifyEqual(e.Good, 4);
            tc.verifyEqual(string(e.Database), "not recorded", 'complete, and no record was made (the test wrote the files itself)');
            tc.verifyEqual(string(p.Complete), "-");
            tc.verifyEqual([p.Reviewed p.Good p.Bad p.Kept], [4 3 1 3]);
            tc.verifyEqual(string(p.Database), "-");
            % a selected source is the highlighted row, also after the list is read again
            tc.assertTrue(app.selectSource('PV2'));
            drawnow;
            marked = @() tManagerGui.markedRows(src);
            tc.verifyEqual(double(src.Selection), 2, 'the selected source is the table''s selected row');
            tc.verifyEqual(marked(), 2, 'and its row is marked by the window itself');
            app.refreshDatabase();
            drawnow;
            tc.verifyEqual(double(src.Selection), 2, 'also when the table is filled again');
            tc.verifyEqual(marked(), 2);
            src.SelectionChangedFcn(src, struct('Selection', 1));        % a click on the other row
            tc.verifyEqual(app.SelectedSourceRow, 1);
            tc.verifyEqual(marked(), 1, 'the mark follows a click');
            app.selectDataset(tc.C + "_proj");
            tc.verifyEmpty(marked(), 'no source is selected in a newly selected dataset');
            % the buttons that need a dataset are on, and off again without one
            btn = findall(app.Figure, 'Type', 'uibutton');
            manifest = btn(string({btn.Text}) == "Open manifest");
            tc.verifyTrue(logical(manifest.Enable));
            app.setFilter('no such thing');
            tc.verifyFalse(logical(manifest.Enable));
            tc.verifySubstring(manifest.Tooltip, 'select a dataset first');
        end

        function theReportIsWritten(tc)
            app = tc.open();
            fx = tc.applyFixture(matlab.unittest.fixtures.TemporaryFolderFixture);
            file = fullfile(fx.Folder, 'report.csv');
            app.setFilter('9002');                                % the report is of everything found
            out = app.exportReport(file);
            tc.verifyEqual(out, file);
            tc.assertTrue(isfile(file));
            R = readtable(file, 'TextType', 'string');
            tc.verifyEqual(height(R), 6, 'two sources of each of the three detected sections');
            tc.verifyEqual(sort(unique(R.Subject))', ["SUBJ-ID-9001" "SUBJ-ID-9002"]);
            tc.verifyEqual(nnz(R.Complete), 3);
            done = R(R.Complete == 1, :);
            tc.verifyTrue(all(strlength(done.FinalCsv) > 0) && all(isfile(done.FinalCsv)));
            tc.verifyEqual(sum(R.Kept), 6 + 5 + 4 + 3);
            tc.verifySubstring(app.StatusText, 'Report written: 6 source(s) of 4 dataset(s)');
        end

        function thePreviewIsDeferredAndCached(tc)
            CellDatasetManager.clearCache();
            app = tc.open();
            axesOf = @() findall(app.Figure, 'Type', 'axes');
            tc.verifyEmpty(axesOf(), 'no preview without a selection');
            app.selectDataset(tc.A + "_proj");
            tc.verifyEmpty(axesOf(), 'moving through the list does not wait for the preview');
            t0 = tic; app.waitForIdle(); first = toc(t0);
            tc.verifyNumElements(axesOf(), 2, 'one tile per TIFF page');
            app.selectDataset(tc.C + "_proj");
            app.waitForIdle();
            app.selectDataset(tc.A + "_proj");
            t0 = tic; app.waitForIdle(); again = toc(t0);
            tc.verifyNumElements(axesOf(), 2);
            fprintf('[manager] preview of a 2-page section: first %.0f ms, again (cached) %.0f ms\n', 1000 * first, 1000 * again);

            % the composite and the overlay, by label
            dd = findall(app.Figure, 'Type', 'uidropdown');
            view = dd(arrayfun(@(d) any(strcmp(d.Items, 'Colorized composite')), dd));
            view.Value = 'Colorized composite';
            view.ValueChangedFcn(view, []);
            tc.verifyNumElements(axesOf(), 1, 'the composite is one tile');
            cb = findall(app.Figure, 'Type', 'uicheckbox');
            color = dd(arrayfun(@(d) any(strcmp(d.Items, 'By class')), dd));
            cb.Value = true;
            color.Value = 'By class';
            cb.ValueChangedFcn(cb, []);
            sc = findall(axesOf(), 'Type', 'scatter');
            tc.verifyNotEmpty(sc, 'the cell locations are drawn');
            nShown = sum(arrayfun(@(s) numel(s.XData), sc));
            tc.verifyEqual(nShown, height(tc.Truth.A.ECM1.locs) + height(tc.Truth.A.PV2.locs), ...
                'every cell of both sources, colored by its label');
            % an image-only dataset has a preview and nothing to overlay
            app.selectDataset(tc.D + "_proj");
            app.waitForIdle();
            tc.verifyNumElements(axesOf(), 1);
            tc.verifyEmpty(findall(axesOf(), 'Type', 'scatter'));
        end

        function everyControlExplainsItself(tc)
            app = tc.open();
            for withSelection = [false true]
                if withSelection
                    app.selectDataset(tc.B + "_proj");
                    app.waitForIdle();
                end
                [h, tips, names] = tManagerGui.controls(app);
                tc.verifyGreaterThanOrEqual(numel(h), 17, 'the window has its controls');
                for i = 1:numel(h)
                    tc.verifyGreaterThan(strlength(strip(tips(i))), 20, names(i) + " has no tooltip");
                    if isprop(h(i), 'Enable') && string(h(i).Enable) == "off"
                        tc.verifyTrue(contains(tips(i), ["Disabled:" "Not available:" "Nothing to" "Check Cell locations"]), ...
                            names(i) + " is disabled and its tooltip does not say why: " + tips(i));
                    end
                end
                [u, ~, g] = unique(tips);
                dup = u(accumarray(g, 1) > 1);
                tc.verifyEmpty(dup, "two controls share a tooltip: " + strjoin(dup, " | "));
            end
            % the buttons that have a shortcut show it
            btn = findall(app.Figure, 'Type', 'uibutton');
            texts = string({btn.Text});
            tc.verifyTrue(any(texts == "Scan [F5]"));
            tc.verifyTrue(any(texts == "Next to curate [Ctrl+E]"));
            tc.verifyTrue(any(texts == "Curate... [Enter]"));
            % the stat cards have one too
            lbl = findall(app.Figure, 'Type', 'uilabel');
            card = lbl(string({lbl.Text}) == "Cells kept");
            tc.assertNumElements(card, 1);
            tc.verifyGreaterThan(strlength(string(card.Tooltip)), 20);
        end

        function scanningAgainKeepsNothingStale(tc)
            app = tc.open();
            app.selectDataset(tc.C + "_proj");
            tc.verifyTrue(app.handleKey('f5', {}), 'F5 scans again');
            tc.verifyEmpty(app.selectedDataset(), 'a scan from the button clears the selection');
            tc.verifyNumElements(app.Datasets, 4);
            % a folder that does not exist is refused in the status bar, and the list stays
            app.scanFolder(fullfile(tc.Root, 'not_there'));
            tc.verifySubstring(app.StatusText, 'valid parent directory');
            tc.verifyNumElements(app.Datasets, 4);
            % a narrower folder
            app.scanFolder(fullfile(tc.Root, 'SUBJ-ID-9002'));
            tc.verifyNumElements(app.Datasets, 2);
            tc.verifyEqual(app.ParentDirectory, fullfile(tc.Root, 'SUBJ-ID-9002'));
            % a folder with nothing in it: an empty list, and every action still answers
            fx = tc.applyFixture(matlab.unittest.fixtures.TemporaryFolderFixture);
            app.scanFolder(fx.Folder);
            tc.verifyEmpty(app.Datasets);
            tc.verifyEmpty(app.View);
            tc.verifySubstring(app.StatusText, '0 dataset(s)');
            tc.verifyFalse(app.nextToCurate());
            tc.verifyEmpty(app.exportReport(fullfile(fx.Folder, 'none.csv')), 'nothing to export');
            app.setFilter('anything', 'Curated');
            app.refreshDatabase();
            app.openSelected();
            tc.verifySubstring(app.StatusText, 'Select a dataset first');
            % and back to the full folder
            app.scanFolder(tc.Root);
            tc.assertNumElements(app.Datasets, 4);
        end

        function closingLeavesNothingBehind(tc)
            before = timerfindall;
            app = CellDatasetManager(tc.Root, 'UseSettings', false);        % the first scan is deferred
            fig = app.Figure;
            tc.verifyEmpty(app.Datasets, 'the constructor returned before the scan');
            tc.verifySubstring(app.StatusText, 'first scan');
            app.waitForIdle();
            tc.verifyNumElements(app.Datasets, 4, 'the deferred scan ran');
            app.selectDataset(tc.A + "_proj");                               % leaves a preview pending
            app.addCloseListener(@() assignin('base', 'tManagerGui_closed', true));
            tc.addTeardown(@() evalin('base', 'clear tManagerGui_closed'));
            close(fig);
            drawnow;
            tc.verifyFalse(isvalid(fig));
            tc.verifyTrue(evalin('base', 'exist(''tManagerGui_closed'', ''var'')') == 1, 'the close listener ran');
            after = timerfindall;
            tc.verifyEqual(numel(after), numel(before), 'no timer is left behind');
            delete(app);
        end
    end
end

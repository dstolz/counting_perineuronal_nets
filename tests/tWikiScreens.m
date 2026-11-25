classdef (TestTags = {'Slow', 'RealData'}) tWikiScreens < matlab.unittest.TestCase
    %tWikiScreens  The Dataset Manager pictures of the user wiki, made from real sections.
    %   Not a test of the code: a generator that runs under the test runner so that the window is
    %   drawn on the hidden desktop. It does nothing (filtered by assumption) unless the environment
    %   variable WIKI_SCREENS_OUT names a folder to write to.
    %
    %   To make the pictures again (PowerShell, from the repository):
    %
    %     $env:WIKI_SCREENS_OUT = "$env:TEMP\wiki_screens"
    %     pwsh -File tools\Run-Tests.ps1 tWikiScreens -IncludeSlow
    %     & "$env:LOCALAPPDATA\miniconda3\envs\countpnn\python.exe" tools\wiki\annotate_manager.py `
    %         $env:WIKI_SCREENS_OUT <clone of the wiki>\images
    %     Remove-Item Env:WIKI_SCREENS_OUT
    %
    %   The first step writes manager_annotated_raw.png, manager_annotated.json (where the numbered
    %   markers go, from the components' positions in the window), manager_curated.png and
    %   manager_database.png into WIKI_SCREENS_OUT; the second draws the markers and puts the three
    %   pictures of the wiki (manager_annotated.png, manager_curated.png, manager_database.png) into
    %   the images folder of a clone of counting_perineuronal_nets.wiki.git. Look at them, then
    %   commit and push the wiki yourself.
    %
    %   What it shows: the three real sections of the local copy
    %   (%LOCALAPPDATA%\counting_perineuronal_nets\real_sections; skipped without it), copied to a
    %   temporary folder that is mapped to a drive letter (subst X:, WIKI_SCREENS_DRIVE for another
    %   letter; it must be free and is released at the end), so the window shows X:\HISTOLOGY and
    %   no user name. Section 1127 1A has both channels curated through curation.Store (Good where
    %   the rescore is at or above Threshold) and marked complete, with their lab database records
    %   sent; 1127 1B has the first PartRows detections of its WFA channel reviewed; 1146 1A is
    %   untouched. For the third picture the WFA channel of 1B is completed and its record left
    %   waiting in the outbox. The lab database is the client's FAKE server
    %   (tests\celldb_test_client.m): nothing of the user's own client is read or written, and the
    %   subjects are never checked against it (the fake's made-up sex and project must not appear
    %   beside real animal numbers). Needs the labclient package.
    %
    %   The Cell Analysis pictures of the user wiki come from the second test, analysisPictures, on
    %   a fresh copy of the same sections (every detection labeled Good where the rescore is at or
    %   above Threshold, none marked complete, so no lab database record is made; the three sections
    %   get the user groups "Group A" and "Group B" so that the Group column has something in it).
    %   It writes analysis_annotated_raw.png and analysis_annotated.json (marker positions) for
    %   tools\wiki\annotate_analysis.py, and analysis_<name>.png for the others. The window shows
    %   X:\HISTOLOGY. The subjects are not checked against any lab database.
    %
    %     $env:WIKI_SCREENS_OUT = "$env:TEMP\wiki_screens"
    %     pwsh -File tools\Run-Tests.ps1 tWikiScreens -IncludeSlow
    %     python tools\wiki\annotate_manager.py  $env:WIKI_SCREENS_OUT <clone of the wiki>\images
    %     python tools\wiki\annotate_analysis.py $env:WIKI_SCREENS_OUT <clone of the wiki>\images
    %
    %   See also tManagerReal, tCuratorReal, CellDatasetManager, CellAnalysis.

    properties (Constant)
        Threshold = 0.5        % rescore at or above which a cell is labeled Good
        PartRows = 400         % detections of 1B's WFA channel reviewed in the first two pictures
    end

    properties
        Out
        Root                   % X:\HISTOLOGY
        Drive
        Master
        Before
        Restore = {}
    end

    methods (TestMethodSetup)
        function prepare(tc)
            tc.Out = getenv('WIKI_SCREENS_OUT');
            tc.assumeNotEmpty(tc.Out, 'WIKI_SCREENS_OUT is not set: no wiki pictures are made (see the class help)');
            tc.Master = fullfile(getenv('LOCALAPPDATA'), 'counting_perineuronal_nets', 'real_sections');
            tc.assumeTrue(isfolder(tc.Master), 'no local copy of real sections here');
            tc.assumeNotEqual(string(getenv('CELLDB_NO_CLIENT')), "1", 'the pictures need the lab database client');
            [ok, why] = celldb.available('Refresh', true);
            tc.assumeTrue(ok, "The lab database client is not usable here: " + why);
            if ~isfolder(tc.Out), mkdir(tc.Out); end

            tc.Drive = upper(getenv('WIKI_SCREENS_DRIVE'));
            if isempty(tc.Drive), tc.Drive = 'X'; end
            tc.assertFalse(isfolder([tc.Drive ':\']), sprintf( ...
                'drive %s: is in use; set WIKI_SCREENS_DRIVE to a free letter', tc.Drive));

            tc.Before = tCuratorReal.listing(tc.Master);
            fx = tc.applyFixture(matlab.unittest.fixtures.TemporaryFolderFixture);
            copyfile(tc.Master, fullfile(fx.Folder, 'data', 'HISTOLOGY'));
            tc.applyFixture(matlab.unittest.fixtures.EnvironmentVariableFixture('CELLDB_PROVENANCE_DIR', ...
                fullfile(fx.Folder, 'provenance')));
            [st, msg] = system(sprintf('subst %s: "%s"', tc.Drive, fullfile(fx.Folder, 'data')));
            tc.assertEqual(st, 0, ['subst failed: ' msg]);
            tc.addTeardown(@() system(sprintf('subst %s: /D', tc.Drive)));
            tc.Root = [tc.Drive ':\HISTOLOGY'];
            tc.assertTrue(isfolder(tc.Root));

            % the lab database: the client's fake server, its storage root the mapped folder
            [~, tc.Restore] = celldb_test_client();
            tc.addTeardown(@() tc.restoreClient());
            st = labclient.Settings.load();
            st.Roots = struct("Name", "nas", "Path", string(tc.Root));
            labclient.Settings.save(st);
            celldb.available('Refresh', true);
        end
    end

    methods
        function restoreClient(tc)
            for k = numel(tc.Restore):-1:1
                tc.Restore{k} = [];
            end
            tc.Restore = {};
            try celldb.available('Refresh', true); catch, end
        end

        function rec = curate(tc, locs, rows, complete)
            %curate  Label ROWS (Inf = every row not decided yet) of a source by its rescore, as a
            %   person reviewing it would leave it; with COMPLETE mark it complete, write the final
            %   list and make its lab database record.
            rec = [];
            s = curation.Store.openCsv(locs, struct('AutosaveDelay', 0, 'ImportLegacy', false));
            closer = onCleanup(@() s.close());
            ids = double(s.T.CellID);
            todo = strlength(string(s.T.Label)) == 0;
            if isfinite(rows)
                todo = todo & (1:numel(ids))' <= rows;
            end
            good = double(s.T.rescore) >= tc.Threshold;
            if any(todo & good), s.setLabel(ids(todo & good), "Good", "human"); end
            if any(todo & ~good), s.setLabel(ids(todo & ~good), "Bad", "human"); end
            if complete
                s.setComplete(true);
                s.flush();
                s.exportFinal(s.Paths.final);
                rec = celldb.recordCuration(s);
            end
        end
    end

    methods (Static)
        function save(fig, file)
            drawnow;
            pause(1);
            drawnow;
            try
                exportapp(fig, file);
            catch
                F = getframe(fig);
                imwrite(F.cdata, file);
            end
            fprintf('[wiki] %s\n', file);
        end

        function r = box(h)
            %box  A component's rectangle in picture coordinates: [left top width height], pixels
            %   from the top left corner of the figure's drawing area.
            fig = ancestor(h, 'figure');
            p = getpixelposition(h, true);
            r = [p(1) - 1, fig.Position(4) - (p(2) - 1) - p(4), p(3), p(4)];
        end

        function U = controls(app)
            f = app.Figure;
            btn = findall(f, 'Type', 'uibutton');
            dd = findall(f, 'Type', 'uidropdown');
            tbl = findall(f, 'Type', 'uitable');
            ef = findall(f, 'Type', 'uieditfield');
            lbl = findall(f, 'Type', 'uilabel');
            pnl = findall(f, 'Type', 'uipanel');
            byText = @(t) btn(startsWith(string({btn.Text}), t));
            tip = @(h, t) h(arrayfun(@(e) contains(string(e.Tooltip), t), h));
            caption = lbl(string({lbl.Text}) == "Datasets");
            U = struct( ...
                'Parent', tip(ef, "Parent directory to search"), ...
                'Find', tip(ef, "every word"), ...
                'View', dd(arrayfun(@(d) any(strcmp(d.Items, 'Colorized composite')), dd)), ...
                'Color', dd(arrayfun(@(d) any(strcmp(d.Items, 'By class')), dd)), ...
                'Locations', findall(f, 'Type', 'uicheckbox'), ...
                'Datasets', tbl(arrayfun(@(t) isequal(t.ColumnName(:)', CellDatasetManager.DATASET_COLUMNS), tbl)), ...
                'Sources', tbl(arrayfun(@(t) isequal(t.ColumnName(:)', CellDatasetManager.SOURCE_COLUMNS), tbl)), ...
                'Cards', caption, ...
                'Detail', pnl(string({pnl.Title}) == "Selected dataset"), ...
                'Detect', byText("Detect cells"), ...
                'CheckSubjects', findall(f, 'Tag', 'btn:checkSubjects'), ...
                'Lamp', findall(f, 'Tag', 'LabClientLamp'));
        end

        function preview(U, view, locations, color)
            %preview  Set the preview's View, Cell locations and Color as a person would.
            U.View.Value = view;
            U.Locations.Value = locations;
            U.Color.Value = color;
            U.Locations.ValueChangedFcn(U.Locations, []);
            U.View.ValueChangedFcn(U.View, []);
        end

        function txt = cellText(U, base, column)
            col = strcmp(CellDatasetManager.DATASET_COLUMNS, column);
            row = string(U.Datasets.Data(:, strcmp(CellDatasetManager.DATASET_COLUMNS, 'Name'))) == string(base);
            txt = string(U.Datasets.Data{row, col});
        end
    end

    methods (Test)
        function analysisPictures(tc)
            CellDatasetManager.clearCache();
            d0 = CellDatasetManager.scan(tc.Root, struct('Database', false));
            tc.assertNumElements(d0, 3, 'each real section is one dataset');
            for d = d0(:)'
                for k = 1:numel(d.Sources)
                    tc.curate(d.Sources(k).CsvPath, Inf, false);
                end
            end

            app = CellAnalysis(tc.Root, 'UseSettings', false, 'Scan', 'now');
            tc.addTeardown(@() tAnalysisGui.closeApp(app));
            drawnow;
            n = numel(app.Rows);
            tc.assertEqual(n, 3, 'one row per section');
            rowOf = @(subject, sec) find(app.Sources.Subject(app.Rows) == subject & contains(app.Sources.Section(app.Rows), sec));
            r1A = rowOf("SUBJ-ID-1127", "1A"); r1B = rowOf("SUBJ-ID-1127", "1B"); r46 = rowOf("SUBJ-ID-1146", "1A");
            app.setGroup([r1A r46], "Group A");
            app.setGroup(r1B, "Group B");
            tc.assertEqual(app.measure('all'), 6, app.StatusText);
            app.waitForIdle();
            tc.assertTrue(all(app.Sources.State == "current"));
            tc.assertTrue(all(app.Sources.SurfaceOk), 'the brain surface is found in every section');
            out = @(name) fullfile(tc.Out, ['analysis_' name '.png']);
            S = @(name) tWikiScreens.save(app.Figure, out(name));

            % ---- 1: the whole window, to be annotated: a histogram of the depth, grouped by subject
            app.setPlot('Histogram'); app.setMetric('SurfaceDistUm'); app.setGroupBy('Subject');
            tc.assertEqual(app.PlotInfo.Kind, "histogram");
            app.selectSection(r1A);
            app.waitForIdle();
            tWikiScreens.save(app.Figure, fullfile(tc.Out, 'analysis_annotated_raw.png'));
            tc.writeAnalysisMarkers(app, fullfile(tc.Out, 'analysis_annotated.json'));

            % ---- the Section tab: 1127 1A (its brain surface in red, a ventricle's edge dotted blue)
            app.setMetric('SurfaceDistUm');
            app.showTab('Section');
            app.selectSection(r1A);
            app.waitForIdle();
            tc.verifyTrue(app.MapInfo.SurfaceOk);
            S('section');
            app.showTab('Distributions');

            % ---- cell density by depth, by subject
            app.setPlot('Cell density by depth'); app.setBinUm(100); app.setGroupBy('Subject');
            tc.assertEqual(app.PlotInfo.Kind, "depth");
            S('density');

            % ---- colocalization: by subject, and the distance to the nearest cell of the other channel
            app.setPlot('Colocalization'); app.setGroupBy('Subject');
            tc.assertEqual(app.PlotInfo.Kind, "colocalization");
            S('colocalization');
            app.setPlot('Histogram'); app.setMetric('OtherDistUm'); app.setGroupBy('');
            S('other_distance');

            % ---- do colocalized cells differ: Group by Colocalized, and a box plot per section
            app.setPlot('Cumulative'); app.setMetric('NetMean'); app.setGroupBy('Colocalized');
            S('cumulative_coloc');
            app.setPlot('Box by group'); app.setMetric('Completeness'); app.setGroupBy('Section');
            S('box');

            % ---- PV cells
            app.setKind('pv');
            app.setPlot('Histogram'); app.setMetric('DiameterUm'); app.setGroupBy('Subject');
            S('pv');

            % what the pictures show, for their captions
            app.setKind('pnn');
            fprintf('[wiki] Cell Analysis: %d kept nets in %d sections\n', height(app.Cells), n);
            tc.verifyEqual(tCuratorReal.listing(tc.Master), tc.Before, 'the local master copy is unchanged');
        end

        function managerPictures(tc)
            CellDatasetManager.clearCache();
            d0 = CellDatasetManager.scan(tc.Root, struct('Database', false));
            tc.assertNumElements(d0, 3, 'each real section is one dataset');
            pick = @(subject, section) d0(strcmp({d0.SubjectID}, subject) & startsWith(string({d0.SectionLabel}), section));
            A = pick('SUBJ-ID-1127', "1A");
            B = pick('SUBJ-ID-1127', "1B");
            C = pick('SUBJ-ID-1146', "1A");
            tc.assertNumElements([A B C], 3, 'the three sections the pictures are of');
            src = @(d, key) d.Sources(strcmp({d.Sources.Key}, key));

            % 1127 1A: both channels curated, complete, recorded and sent. 1127 1B: WFA started.
            r1 = tc.curate(src(A, 'ECM1').CsvPath, Inf, true);
            r2 = tc.curate(src(A, 'PV2').CsvPath, Inf, true);
            tc.assertTrue(r1.queued && r2.queued, 'the records are in the fake client''s outbox');
            labclient.Sync.flush('Budget', 20);
            tc.assertEqual([labclient.Outbox.stateOf(r1.runId) labclient.Outbox.stateOf(r2.runId)], ["done" "done"]);
            tc.curate(src(B, 'ECM1').CsvPath, tc.PartRows, false);

            app = CellDatasetManager(tc.Root, 'UseSettings', false, 'Scan', 'now');
            tc.addTeardown(@() tManagerGui.closeApp(app));
            app.LaunchFcn = @(req) [];
            drawnow;
            U = tWikiScreens.controls(app);
            tc.assertNumElements(app.Datasets, 3);
            tc.assertFalse(any([app.Datasets.SubjectAsked]), 'the subjects are not checked against the fake server');
            tc.verifyEqual(tWikiScreens.cellText(U, A.Base, 'Status'), "Curated");
            tc.verifyEqual(tWikiScreens.cellText(U, A.Base, 'Database'), "2 sent");
            tc.verifyEqual(tWikiScreens.cellText(U, B.Base, 'Status'), "Curating");
            tc.verifyEqual(tWikiScreens.cellText(U, B.Base, 'Database'), "");
            tc.verifyEqual(tWikiScreens.cellText(U, C.Base, 'Status'), "Rescored");

            % ---- 1: the whole window, to be annotated: 1B selected, the composite with every detection
            tWikiScreens.preview(U, 'Colorized composite', true, 'By page');
            tc.assertTrue(app.nextToCurate(), 'Next to curate finds the section in progress');
            tc.assertEqual(string(app.selectedDataset().Base), string(B.Base));
            app.waitForIdle();
            tc.verifyNotEmpty(findall(app.Figure, 'Type', 'scatter'));
            tWikiScreens.save(app.Figure, fullfile(tc.Out, 'manager_annotated_raw.png'));
            tc.writeMarkers(app, U, fullfile(tc.Out, 'manager_annotated.json'));

            % ---- 2: the curated section, its pages colored by label
            tWikiScreens.preview(U, 'Individual pages', true, 'By class');
            app.setFilter('');
            tc.assertTrue(app.selectDataset(A.Base));
            app.waitForIdle();
            tc.verifyNumElements(findall(app.Figure, 'Type', 'axes'), 2);
            tWikiScreens.save(app.Figure, fullfile(tc.Out, 'manager_curated.png'));

            % ---- 3: the lab database: 1B's WFA channel completed, its record waiting to be sent
            r3 = tc.curate(src(B, 'ECM1').CsvPath, Inf, true);
            tc.assertTrue(r3.queued);
            tc.assertEqual(labclient.Outbox.stateOf(r3.runId), "pending");
            app.scanFolder(tc.Root);
            tWikiScreens.preview(U, 'Individual pages', false, 'By class');
            app.setFilter('');
            tc.assertTrue(app.selectDataset(B.Base));
            tc.assertTrue(app.selectSource('ECM1'));
            app.waitForIdle();
            tc.verifyEqual(tWikiScreens.cellText(U, A.Base, 'Database'), "2 sent");
            tc.verifyEqual(tWikiScreens.cellText(U, B.Base, 'Database'), "1 waiting");
            tc.verifySubstring(char(string(U.Lamp.Text)), 'connected');
            tc.verifySubstring(char(string(U.Lamp.Text)), '1 to send');
            tWikiScreens.save(app.Figure, fullfile(tc.Out, 'manager_database.png'));

            % what the pictures show, for their captions
            for d = app.Datasets(:)'
                p = CellDatasetManager.progressOf(d);
                fprintf('[wiki] %s %s: %d detections, %d reviewed (%d%%), %d kept, %d/%d complete, %s, database "%s"\n', ...
                    d.SubjectID, d.SectionLabel, d.TotalDetections, p.Reviewed, p.Pct, p.Kept, p.Complete, ...
                    p.Sources, d.Status, d.Database);
            end

            tc.verifyEqual(tCuratorReal.listing(tc.Master), tc.Before, 'the local master copy is unchanged');
        end
    end

    methods
        function writeAnalysisMarkers(tc, app, file)
            %writeAnalysisMarkers  Where the numbered markers of analysis_annotated.png go (see writeMarkers).
            R = 13.5;
            f = app.Figure;
            b = @tWikiScreens.box;
            tag = @(t) findall(f, 'Tag', t);
            midY = @(r) r(2) + r(4) / 2;
            right = @(r) r(1) + r(3);
            ax = findall(f, 'Type', 'axes');
            ax = ax(arrayfun(@(a) ~isempty(ancestor(a, 'uitab')) && strcmp(ancestor(a, 'uitab').Tag, 'tab:distributions'), ax));
            pe = b(tag('edit:parent')); kind = b(tag('dd:kind')); tb = b(tag('table:sections'));
            sg = b(tag('btn:setGroup')); ma = b(tag('btn:measureAll')); ec = b(tag('btn:exportCells'));
            pl = b(tag('dd:plot')); ap = b(ax(1)); st = b(tag('table:summary')); tg = b(tag('tab:section'));
            tabs = b(ancestor(tag('tab:section'), 'uitabgroup'));
            M = struct('n', {}, 'x', {}, 'y', {}, 'what', {});
            M(end + 1) = struct('n', 1, 'x', right(pe) - R - 6, 'y', midY(pe), 'what', 'the Parent directory field and Scan');
            M(end + 1) = struct('n', 2, 'x', kind(1) + kind(3) / 2, 'y', kind(2) - R + 2, 'what', 'Cell type, Cells, Coloc. within');
            M(end + 1) = struct('n', 3, 'x', tb(1) + tb(3) - R - 8, 'y', tb(2) + tb(4) / 2, 'what', 'the list of sections');
            M(end + 1) = struct('n', 4, 'x', sg(1) - R - 2, 'y', midY(sg), 'what', 'Use all, Use none, Set group, Import groups');
            M(end + 1) = struct('n', 5, 'x', ma(1) + ma(3) / 2, 'y', ma(2) + ma(4) + R - 4, 'what', 'Measure all');
            M(end + 1) = struct('n', 6, 'x', ec(1) + ec(3) / 2, 'y', ec(2) + ec(4) + R - 4, 'what', 'the export buttons');
            M(end + 1) = struct('n', 7, 'x', pl(1) - R - 4, 'y', midY(pl), 'what', 'Plot, Metric, Group by ...');
            M(end + 1) = struct('n', 8, 'x', ap(1) + ap(3) - R - 20, 'y', ap(2) + R + 20, 'what', 'the plot');
            M(end + 1) = struct('n', 9, 'x', st(1) + st(3) - R - 20, 'y', st(2) + st(4) / 2, 'what', 'the table of numbers');
            M(end + 1) = struct('n', 10, 'x', tabs(1) + 182, 'y', tabs(2) + 11, 'what', 'the Section tab');
            J = struct('figure', f.Position(3:4), 'radius', R, 'markers', M);
            fid = fopen(file, 'w');
            tc.assertGreaterThan(fid, 0);
            fwrite(fid, jsonencode(J, 'PrettyPrint', true), 'char');
            fclose(fid);
            for m = M
                fprintf('[wiki]   marker %d at (%.0f, %.0f): %s\n', m.n, m.x, m.y, m.what);
            end
        end

        function writeMarkers(tc, app, U, file)
            %writeMarkers  Where the numbered markers of manager_annotated.png go: centers in picture
            %   coordinates (pixels from the top left of the figure's drawing area), each derived
            %   from the position of the component it names.
            R = 13.5;                                        % the marker's radius (annotate_manager.py)
            b = @tWikiScreens.box;
            midY = @(r) r(2) + r(4) / 2;
            right = @(r) r(1) + r(3);
            scan = findall(app.Figure, 'Type', 'uibutton');
            scan = scan(startsWith(string({scan.Text}), "Scan"));
            rows = size(U.Datasets.Data, 1);
            pe = b(U.Parent); fe = b(U.Find); cards = b(U.Cards); tb = b(U.Datasets);
            dp = b(U.Detail); det = b(U.Detect); col = b(U.Color); chk = b(U.CheckSubjects);
            M = struct('n', {}, 'x', {}, 'y', {}, 'what', {});
            M(end + 1) = struct('n', 1, 'x', right(pe) - R - 6, 'y', midY(pe), ...
                'what', 'the Parent directory field and Scan');
            % (the caption label of the first card: its top edge is the middle of the card)
            M(end + 1) = struct('n', 2, 'x', cards(1) + R + 8, 'y', cards(2), 'what', 'the stat cards');
            M(end + 1) = struct('n', 3, 'x', right(fe) - R - 6, 'y', midY(fe), ...
                'what', 'Find, Show, Next to curate, Export report');
            M(end + 1) = struct('n', 4, 'x', tb(1) + R + 10, 'y', tb(2) + 28 + 23.5 * rows + R + 10, ...
                'what', 'the dataset table');
            M(end + 1) = struct('n', 5, 'x', dp(1) + 112, 'y', dp(2) + 10, 'what', 'the Selected dataset panel');
            M(end + 1) = struct('n', 6, 'x', det(1) - R - 1, 'y', midY(det), 'what', 'the buttons that open the tools');
            M(end + 1) = struct('n', 7, 'x', right(col) + R + 14, 'y', midY(col), 'what', 'the TIFF preview');
            M(end + 1) = struct('n', 8, 'x', chk(1) - R - 8, 'y', midY(chk), 'what', 'the lab database controls');
            J = struct('figure', app.Figure.Position(3:4), 'radius', R, 'markers', M, ...
                'scanButton', b(scan));
            fid = fopen(file, 'w');
            tc.assertGreaterThan(fid, 0);
            fwrite(fid, jsonencode(J, 'PrettyPrint', true), 'char');
            fclose(fid);
            fprintf('[wiki] %s\n', file);
            for m = M
                fprintf('[wiki]   marker %d at (%.0f, %.0f): %s\n', m.n, m.x, m.y, m.what);
            end
        end
    end
end

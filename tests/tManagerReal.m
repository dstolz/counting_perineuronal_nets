classdef (TestTags = {'Slow', 'RealData'}) tManagerReal < matlab.unittest.TestCase
    %tManagerReal  The Cell Dataset Manager on real sections: three sections of two animals (WFA/PNN and
    %   PV, float32 projections of about 2816 x 2355 px at 1.657 um/px) from the local copy in
    %   %LOCALAPPDATA%\counting_perineuronal_nets\real_sections (skipped when it is absent). The folder
    %   is copied to a temporary one and only the copy is opened.
    %
    %   Checks: each section is listed once (3 datasets, 6 sources) with its subject and section; one
    %   source is curated and completed through the store and its lab database record followed to
    %   "sent" against the fake server (when the labclient package is here); the subject the fake
    %   server lacks is marked. Measures (ms): the scan, the first preview of a section, the same
    %   preview again (cached), and a move to another section's list row. Saves screenshots for a
    %   person to look at: %LOCALAPPDATA%\counting_perineuronal_nets\test_logs\screens\manager_real_*.png
    %
    %   Run on the hidden desktop: tools\Run-Tests.ps1 -IncludeSlow tManagerReal

    properties (Constant)
        % Milliseconds. Measured 2026-11-24 on the development laptop in a MATLAB started for this test
        % alone (cold: the first window, table and axes of the session), four runs: scan into the list
        % 1200-1310, first preview 1730-1800, the same again 340-390, the first move to another row
        % 100-630, a later move 40-43 (two runs). The budgets leave about twice that or more.
        Budget = struct('Scan', 3000, 'FirstPreview', 4000, 'CachedPreview', 1000, 'FirstSelect', 1200, 'Select', 250)
    end

    properties
        Folder
        Restore = {}
    end

    methods (TestClassSetup)
        function copyRealSections(tc)
            master = fullfile(getenv('LOCALAPPDATA'), 'counting_perineuronal_nets', 'real_sections');
            tc.assumeTrue(isfolder(master), 'no local copy of real sections here');
            fx = tc.applyFixture(matlab.unittest.fixtures.TemporaryFolderFixture);
            tc.Folder = fullfile(fx.Folder, 'HISTOLOGY');
            copyfile(master, tc.Folder);
            tc.applyFixture(matlab.unittest.fixtures.EnvironmentVariableFixture('CELLDB_PROVENANCE_DIR', ...
                fullfile(fx.Folder, 'provenance')));
            tc.addTeardown(@() tc.restoreClient());
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
    end

    methods (Test)
        function realSectionsInTheManager(tc)
            % the lab database: the fake server when the client is here (it has SUBJ-ID-1127 only)
            withClient = string(getenv('CELLDB_NO_CLIENT')) ~= "1" && celldb.available('Refresh', true);
            if withClient
                [~, tc.Restore] = celldb_test_client();
                st = labclient.Settings.load();              % the storage root "nas" is this copy
                st.Roots = struct("Name", "nas", "Path", string(tc.Folder));
                labclient.Settings.save(st);
                celldb.available('Refresh', true);
            end
            CellDatasetManager.clearCache();

            % one source curated and completed, one started, as a person would leave them
            t0 = tic;
            d0 = CellDatasetManager.scan(tc.Folder, struct('Database', false));
            tCold = 1000 * toc(t0);
            t0 = tic;
            CellDatasetManager.scan(tc.Folder);
            tWarm = 1000 * toc(t0);
            fprintf('\n[manager-real] headless scan of 3 sections: first %.0f ms (page counts read, manifests written), again %.0f ms\n', ...
                tCold, tWarm);
            tc.assertNumElements(d0, 3, 'each real section is one dataset');
            tc.verifyEqual(arrayfun(@(d) numel(d.Sources), d0), [2 2 2]);
            first = d0(find(strcmp({d0.SubjectID}, 'SUBJ-ID-1127'), 1));
            done = first.Sources(1);
            s = curation.Store.openCsv(done.CsvPath, struct('AutosaveDelay', 0, 'ImportLegacy', false));
            ids = double(s.T.CellID);
            r = double(s.T.rescore);
            s.setLabel(ids(r >= 0.5), "Good", "human");
            s.setLabel(ids(~(r >= 0.5)), "Bad", "human");
            s.setComplete(true);
            s.flush();
            s.exportFinal(s.Paths.final);
            rec = celldb.recordCuration(s);
            s.close();
            started = first.Sources(2);
            s = curation.Store.openCsv(started.CsvPath, struct('AutosaveDelay', 0, 'ImportLegacy', false));
            ids = double(s.T.CellID);
            s.setLabel(ids(1:120), "Good", "human");
            s.setLabel(ids(121:160), "Bad", "human");
            s.close();

            t0 = tic;
            app = CellDatasetManager(tc.Folder, 'UseSettings', false, 'Scan', 'none');
            drawnow;
            tWindow = 1000 * toc(t0);
            t0 = tic;
            app.scanFolder(tc.Folder);
            drawnow;
            tScan = 1000 * toc(t0);
            tc.addTeardown(@() tManagerGui.closeApp(app));
            app.LaunchFcn = @(req) [];
            tc.assertNumElements(app.Datasets, 3);
            tc.verifyEqual(sort(unique(string({app.Datasets.SubjectID}))), ["SUBJ-ID-1127" "SUBJ-ID-1146"]);
            tc.verifyTrue(all(strlength(string({app.Datasets.SectionLabel})) > 0));
            p = CellDatasetManager.progressOf(app.Datasets(strcmp({app.Datasets.Base}, first.Base)));
            tc.verifyEqual(p.Stage, 'curating');
            tc.verifyEqual(p.Complete, 1);
            tc.verifyGreaterThan(p.Kept, 100);

            if withClient
                tc.verifyTrue(rec.queued);
                r = app.checkSubjects();
                tc.verifyTrue(r.ok);
                tc.verifyEqual(r.missing, "SUBJ-ID-1146", 'the fake server has 1127 only');
                labclient.Sync.flush('Budget', 10);
                app.waitForIdle();
                d = app.Datasets(strcmp({app.Datasets.Base}, first.Base));
                tc.verifyEqual(d.Sources(1).Db.state, "sent");
                tc.verifyEqual(string(d.Database), "1 sent");
            end

            % the preview: first time, again, and moving on
            app.selectDataset(first.Base);
            t0 = tic; app.waitForIdle(); tFirst = 1000 * toc(t0);
            tc.verifyNumElements(findall(app.Figure, 'Type', 'axes'), 2);
            other = app.Datasets(find(~strcmp({app.Datasets.Base}, first.Base), 1)).Base;
            t0 = tic; app.selectDataset(other); drawnow; tSelect = 1000 * toc(t0);
            app.waitForIdle();
            app.selectDataset(first.Base);
            t0 = tic; app.waitForIdle(); tAgain = 1000 * toc(t0);
            t0 = tic; app.selectDataset(other); drawnow; tSelectWarm = 1000 * toc(t0);
            app.waitForIdle();
            app.selectDataset(first.Base);
            app.waitForIdle();
            fprintf(['\n[manager-real] window %.0f ms; scan of 3 sections into the list %.0f ms; first preview %.0f ms; ' ...
                'the same again (cached) %.0f ms; move to another row (detail, no preview) first %.0f ms, later %.0f ms\n'], ...
                tWindow, tScan, tFirst, tAgain, tSelect, tSelectWarm);
            tc.verifyLessThan(tScan, tc.Budget.Scan);
            tc.verifyLessThan(tFirst, tc.Budget.FirstPreview);
            tc.verifyLessThan(tAgain, tc.Budget.CachedPreview);
            tc.verifyLessThan(tSelect, tc.Budget.FirstSelect);
            tc.verifyLessThan(tSelectWarm, tc.Budget.Select);

            % for a person to look at
            app.selectSource(2);
            tCuratorReal.saveScreen(app.Figure, 'manager_real_pages.png');
            dd = findall(app.Figure, 'Type', 'uidropdown');
            view = dd(arrayfun(@(d) any(strcmp(d.Items, 'Colorized composite')), dd));
            view.Value = 'Colorized composite';
            view.ValueChangedFcn(view, []);
            cb = findall(app.Figure, 'Type', 'uicheckbox');
            color = dd(arrayfun(@(d) any(strcmp(d.Items, 'By class')), dd));
            cb.Value = true;
            color.Value = 'By class';
            cb.ValueChangedFcn(cb, []);
            tc.verifyNotEmpty(findall(findall(app.Figure, 'Type', 'axes'), 'Type', 'scatter'));
            tCuratorReal.saveScreen(app.Figure, 'manager_real_composite_by_class.png');
            app.setFilter('1146');
            tc.verifyNumElements(app.View, 1);
            tCuratorReal.saveScreen(app.Figure, 'manager_real_filtered.png');
        end
    end
end

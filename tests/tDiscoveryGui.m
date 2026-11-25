classdef tDiscoveryGui < matlab.unittest.TestCase
    %TDISCOVERYGUI  CellDiscovery's main window (default set; it opens on the hidden desktop):
    %     tooltips        every interactive control has one and no two share it (tTooltips' rule)
    %     window          lies within the screen; the file list uses the whole width of its panel
    %     file marks      a search marks the files whose page-map rows all have a result CSV and counts
    %                     them in the label; editing the page map redraws the marks from the cached
    %                     listing; the selection survives
    %     fields          a bad Device / Batch size / Threshold refuses to start (no batch, no Python)
    %     closing         closing the window mid-batch asks through the replaceable ConfirmCloseFcn
    %                     (no dialog); deleting the object never asks; an idle window closes unasked
    %     environment     a passed check is reused by Start while the three fields stay the same, the
    %                     Test env button always runs it; CUDA is reported, a cuda Device without a
    %                     GPU is refused, cpu with a GPU gets a [HINT] and goes on
    %   The batch tests run a real batch with a stub "python": a .bat that answers the environment
    %   check (OK and a CUDA line) and then idles like a long predict.py, so no Python is needed.
    %   Own preference group; every window the tests open is closed. uialert is non-blocking.
    %
    %   Run: pwsh -File tools\Run-Tests.ps1 tDiscoveryGui

    properties (Constant)
        PREFS = 'tDiscoveryGuiPrefs'
        Interactive = ["matlab.ui.control.Button" "matlab.ui.control.StateButton" ...
            "matlab.ui.control.DropDown" "matlab.ui.control.CheckBox" "matlab.ui.control.Slider" ...
            "matlab.ui.control.Spinner" "matlab.ui.control.EditField" "matlab.ui.control.NumericEditField" ...
            "matlab.ui.control.ListBox" "matlab.ui.control.Table" "matlab.ui.container.Tab" ...
            "matlab.ui.control.TextArea" "matlab.ui.control.ToggleButton" "matlab.ui.control.RadioButton"]
    end

    properties
        Dir         % folder with the images the window searches
        Stub        % folder of the stub interpreters
        Repo
        Model       % a detection model of the repository ('' = none)
    end

    methods (TestMethodSetup)
        function setup(tc)
            tc.Repo = fileparts(fileparts(mfilename('fullpath')));
            fx = tc.applyFixture(matlab.unittest.fixtures.TemporaryFolderFixture);
            tc.Dir  = fullfile(fx.Folder, 'data');
            tc.Stub = fullfile(fx.Folder, 'stub');
            mkdir(tc.Dir); mkdir(tc.Stub);
            det = CellToolkit.discoverModels(tc.Repo);
            tc.Model = '';
            if ~isempty(det), tc.Model = det{1}; end
            before = findall(groot, 'Type', 'figure');
            tc.addTeardown(@() tDiscoveryGui.closeNewFigures(before));
            tc.addTeardown(@() tDiscoveryGui.removePrefs(tc.PREFS));
            tDiscoveryGui.ask('reset');
        end
    end

    methods
        function app = openApp(tc)
            delete(findall(groot, 'Tag', 'PNNBatchGUIMain'));   % an open window would be reused
            app = CellDiscovery(tc.Dir, 'PrefGroup', tc.PREFS, 'Search', false);
            tc.addTeardown(@() tDiscoveryGui.closeApp(app));
            drawnow;
        end

        function fig = figureOf(tc, app) %#ok<INUSL>
            fig = findall(groot, 'Tag', 'PNNBatchGUIMain');
            tc.assertNumElements(fig, 1);
        end

        function row = pageRow(tc, page, suffix)
            row = {page, suffix, tc.Model, '(none)', false, 0, 1, false, true};
        end

        function makeTiffs(tc, names)
            for k = 1:numel(names)
                f = fullfile(tc.Dir, names{k});
                if ~isfolder(fileparts(f)), mkdir(fileparts(f)); end
                fclose(fopen(f, 'w'));
            end
        end

        function py = makeStubPython(tc, name, cuda)
            % A "python" that passes the environment check (OK, CUDA <cuda>) and otherwise idles.
            py = fullfile(tc.Stub, [name '.bat']);
            fid = fopen(py, 'w');
            fprintf(fid, '@echo off\r\nif "%%~1"=="-c" (\r\n  echo OK\r\n  echo CUDA %d\r\n  exit /b 0\r\n)\r\nping -n 15 127.0.0.1 >nul\r\n', cuda);
            fclose(fid);
        end

        function app = openBatchApp(tc, cuda, device)
            % The window set up to run a batch of one real, small TIFF with the stub interpreter.
            tc.assumeNotEmpty(tc.Model, 'no detection model in the repository');
            imwrite(uint8(round(255 * rand(64, 64))), fullfile(tc.Dir, 's.tif'));
            py = tc.makeStubPython('python_stub', cuda);
            app = tc.openApp();
            app.configure('PythonExe', py, 'CondaExe', '', 'CondaEnv', '', 'Device', device, ...
                'BatchSize', '1', 'Threshold', '', 'Overwrite', false, 'SavePng', false, ...
                'SaveTif', false, 'Diagnostic', false, 'PageMap', tc.pageRow(1, 'page'));
            app.setSearchDir(tc.Dir);
        end

        function waitForStage(tc, app, stage, timeout)
            t0 = tic;
            while app.isRunning() && ~strcmp(app.batchState().Stage, stage) && toc(t0) < timeout
                pause(0.05);
            end
            tc.assertEqual(app.batchState().Stage, stage, 'the batch did not reach the stage');
        end

        function endBatch(tc, app)
            % Stop, then Abort now: the stub is killed and the batch ends.
            app.requestStop();
            app.requestStop();
            t0 = tic;
            while app.isRunning() && toc(t0) < 30
                pause(0.1);
            end
            tc.assertFalse(app.isRunning(), 'the batch did not end');
        end
    end

    methods (Test)
        function theFileListIsNarrowedBySubjectTags(tc)
            % Subject tags: only the files whose subject carries the lab database tags typed; the
            % tags come from this computer's cache, Check subjects asks the (fake) server
            tc.assumeNotEqual(string(getenv('CELLDB_NO_CLIENT')), "1", 'run without the client');
            [ok, why] = celldb.available('Refresh', true);
            tc.assumeTrue(ok, "The lab database client is not usable here: " + why);
            [ok, why] = labclient.Api.atLeast(4);
            tc.assumeTrue(ok, "The lab database client here keeps no tags: " + string(why));
            [fake, restore, top] = celldb_test_client();
            tc.addTeardown(@() tDiscoveryGui.restoreClient(restore, top));
            celldb.available('Refresh', true);
            tCelldbFacts.seed(fake);

            a = 'SUBJ-ID-9001IHC_ECM26A260519S2_1A_L_WFA-PV_Z3_260511_1_proj.tif';   % cohort:a, pilot
            b = 'SUBJ-ID-9002IHC_ECM26A260519S2_1A_L_WFA-PV_Z3_260511_1_proj.tif';   % cohort:b
            c = 'SUBJ-ID-4040IHC_ECM26A260519S2_1A_L_WFA-PV_Z3_260511_1_proj.tif';   % not in the database
            tc.makeTiffs({fullfile('one', a), fullfile('two', b), fullfile('three', c), 'no_subject.tif'});
            app = tc.openApp();
            fig = tc.figureOf(app);
            app.setSearchDir(tc.Dir);
            lbl = findall(fig, 'Tag', 'fileCountLabel');
            names = @() sort(cellfun(@(f) string(tDiscoveryGui.nameOf(f)), app.listedFiles()))';
            tc.verifyNumElements(app.listedFiles(), 4);
            tc.verifyTrue(startsWith(string(lbl.Text), "4 files found"));

            % nothing was asked yet: a filter lists nothing rather than everything, and says why
            app.setTagFilter('cohort:a');
            tc.verifyEmpty(app.listedFiles());
            tc.verifySubstring(lbl.Text, '4 left out by tags');
            tc.verifySubstring(lbl.Tooltip, 'never checked');
            tc.verifyEmpty(fake.Calls(ismember(string(fake.Calls), ["subjectCurrent" "entityTags"])), ...
                'a filter reads the cache, never the server');

            r = app.checkSubjects();
            tc.verifyTrue(r.ok && r.tagsRead, r.message);
            tc.verifyEqual(names(), string(a), 'the filter that was set now has tags to go by');
            tc.verifySubstring(lbl.Text, '1 file found');
            tc.verifySubstring(lbl.Text, '3 left out by tags');
            tc.verifyEqual(numel(findall(fig, 'Tag', 'fileList').Items), 1);

            app.setTagFilter('cohort:* -pilot');
            tc.verifyEqual(names(), string(b));
            app.setTagFilter('-qc:fial');
            tc.verifyEqual(names(), sort([string(a) string(b)]), ...
                'a file without a subject, and a subject the database lacks, are not listed by a filter');
            tc.verifySubstring(lbl.Tooltip, 'qc:fial');
            app.setTagFilter('');
            tc.verifyNumElements(app.listedFiles(), 4);
            tc.verifyTrue(startsWith(string(lbl.Text), "4 files found"));
            tc.verifyEqual(findall(fig, 'Tag', 'tagsEdit').Value, '');

            % a new search keeps the filter
            app.setTagFilter('cohort:b');
            app.setSearchDir(tc.Dir);
            tc.verifyEqual(names(), string(b));
        end


        %% Tooltips

        function everyInteractiveControlHasATooltip(tc)
            app = tc.openApp(); %#ok<NASGU>
            [h, tips, names] = tDiscoveryGui.controls(tc.figureOf(app));
            tc.verifyGreaterThan(numel(h), 25, 'the window has its controls');
            for i = 1:numel(h)
                tc.verifyGreaterThan(strlength(strip(tips(i))), 10, names(i) + " has no tooltip");
            end
        end

        function noTooltipIsShared(tc)
            app = tc.openApp();
            [~, tips, names] = tDiscoveryGui.controls(tc.figureOf(app));
            [u, ~, j] = unique(tips);
            for k = 1:numel(u)
                who = names(j == k);
                tc.verifyEqual(numel(who), 1, "these controls share a tooltip: " + strjoin(who, " | ") + ...
                    newline + "tooltip: " + u(k));
            end
        end

        function pageTableTooltipExplainsEveryColumn(tc)
            app = tc.openApp();
            tbl = findall(tc.figureOf(app), 'Tag', 'pageTable');
            tc.assertNumElements(tbl, 1);
            tip = string(strjoin(string(tbl.Tooltip), " "));
            for col = tbl.ColumnName(:)'
                name = regexprep(string(col), ' \(.*\)$', '');   % "Resize x (0=auto)" -> "Resize x"
                tc.verifySubstring(tip, name + ":", "the table tooltip lacks the column " + string(col));
            end
            tc.verifySubstring(tip, "<stem>_<suffix><page>_locs.csv");
            tc.verifySubstring(lower(tip), "letters only");
        end

        %% The window

        function windowLiesWithinTheScreen(tc)
            app = tc.openApp();
            fig = tc.figureOf(app);
            scr = get(groot, 'ScreenSize');
            p = fig.Position;
            tc.verifyGreaterThanOrEqual(p(1), 1);
            tc.verifyGreaterThanOrEqual(p(2), 1);
            tc.verifyLessThanOrEqual(p(1) + p(3) - 1, scr(3), 'right edge within the screen');
            tc.verifyLessThanOrEqual(p(2) + p(4) - 1, scr(4), 'top edge within the screen');
            tc.verifyEqual(p, CellDiscovery.windowPosition(scr(3:4)), 'AbsTol', 1, 'the position the helper computes');
        end

        function fileListSpansItsPanel(tc)
            app = tc.openApp();
            fig = tc.figureOf(app);
            lb = findall(fig, 'Tag', 'fileList');
            tc.assertNumElements(lb, 1);
            pFiles = lb.Parent.Parent;
            tc.assertClass(pFiles, 'matlab.ui.container.Panel');
            midGrid = pFiles.Parent;
            tc.verifyNumElements(midGrid.ColumnWidth, 1, 'one column: no empty one beside the list');
            drawnow; pause(1); drawnow;
            fprintf('[gui] file list %g px wide in a panel %g px wide\n', lb.Position(3), pFiles.InnerPosition(3));
            tc.verifyGreaterThanOrEqual(lb.Position(3), pFiles.InnerPosition(3) - 16, ...
                'the list uses the whole width of its panel');
        end

        %% Done marks

        function searchMarksTheFilesThatAreDone(tc)
            tc.assumeNotEmpty(tc.Model, 'no detection model in the repository');
            tc.makeTiffs({'a.tif', fullfile('sub', 'b.tif'), 'c.tif', 'c_resized.tif', 'notes.txt'});
            tc.makeTiffs({'a_page1_locs.csv', fullfile('sub', 'b_page1_locs.csv'), 'c_ECM1_locs.csv'});
            app = tc.openApp();
            app.configure('PageMap', tc.pageRow(1, 'page'));
            app.setSearchDir(tc.Dir);
            fig = tc.figureOf(app);
            lb = findall(fig, 'Tag', 'fileList');
            lbl = findall(fig, 'Tag', 'fileCountLabel');
            tc.verifyNumElements(lb.Items, 3, 'the resized TIF and the text file are not listed');
            tc.verifyEqual(sort(string(lb.ItemsData)), sort(string({fullfile(tc.Dir, 'a.tif'), ...
                fullfile(tc.Dir, 'c.tif'), fullfile(tc.Dir, 'sub', 'b.tif')})), 'values are the absolute paths');
            tc.verifyEmpty(lb.Value, 'nothing selected (= all files)');
            tc.verifyEqual(sort(tDiscoveryGui.marked(lb)), sort(["a.tif" "sub/b.tif"]), 'the files with their page-1 CSV');
            tc.verifyEqual(lbl.Text, CellDiscovery.fileCountText(3, 1, 2));
            tc.verifySubstring(lbl.Text, '3 files found');
            tc.verifySubstring(lbl.Text, '2 done');
            tc.verifySubstring(lbl.Text, '(1 *_resized.tif hidden)');

            % the selection survives a page-map edit; the marks follow the map
            lb.Value = {fullfile(tc.Dir, 'c.tif')};
            app.configure('PageMap', tc.pageRow(1, 'ECM'));
            tc.verifyEqual(tDiscoveryGui.marked(lb), "c.tif", 'only c has a CSV with the suffix ECM');
            tc.verifySubstring(lbl.Text, '1 done');
            tc.verifyEqual(lb.Value, {fullfile(tc.Dir, 'c.tif')}, 'the selection is kept');

            app.configure('PageMap', [tc.pageRow(1, 'page'); tc.pageRow(2, 'page')]);
            tc.verifyEmpty(tDiscoveryGui.marked(lb), 'every file lacks its page-2 CSV');
            tc.verifySubstring(lbl.Text, ' 0 done');

            % a new result shows after the next search (the listing is cached)
            tc.makeTiffs({'a_page2_locs.csv'});
            tc.verifyEmpty(tDiscoveryGui.marked(lb), 'the cached listing does not know it yet');
            app.setSearchDir(tc.Dir);
            lb = findall(fig, 'Tag', 'fileList');
            tc.verifyEqual(tDiscoveryGui.marked(lb), "a.tif");
            tc.verifySubstring(lbl.Text, '1 done');
            tc.verifyEqual(lb.Value, {fullfile(tc.Dir, 'c.tif')}, 'a new search keeps the selected files that are still listed');
        end

        %% Free-text fields

        function badFieldsRefuseToStart(tc)
            tc.makeTiffs({'a.tif'});
            app = tc.openApp();
            app.configure('PageMap', tc.pageRow(1, 'page'));
            app.setSearchDir(tc.Dir);
            tc.assumeNotEmpty(tc.Model, 'no detection model in the repository');
            good = {'Device', 'cpu', 'BatchSize', '1', 'Threshold', ''};
            bad = {'Device', 'gpu'; 'Device', 'cuda:'; 'BatchSize', '0'; 'BatchSize', '1.5'; 'Threshold', '2'; 'Threshold', 'abc'};
            for k = 1:size(bad, 1)
                app.configure(good{:}, bad{k, :});
                runs0 = app.batchState().PythonRuns;
                app.start();
                st = app.batchState();
                tc.verifyFalse(st.Running, sprintf('%s = %s must not start', bad{k, :}));
                tc.verifyEqual(st.PythonRuns, runs0, 'no Python was started');
                tc.verifyEqual(char(findall(tc.figureOf(app), 'Tag', 'startBtn').Enable), 'on', 'the window is usable again');
            end
        end

        %% Closing mid-batch

        function closeMidBatchAsks(tc)
            app = tc.openBatchApp(0, 'cpu');
            fig = tc.figureOf(app);
            app.start();
            tc.assertTrue(app.isRunning(), app.batchState().Progress);
            tc.waitForStage(app, 'detect', 60);
            % keep it running
            app.ConfirmCloseFcn = @(~) tDiscoveryGui.ask(false);
            fig.CloseRequestFcn(fig, []);
            tc.verifyEqual(tDiscoveryGui.ask('count'), 1, 'it asked');
            tc.verifyTrue(app.isRunning(), 'the batch goes on');
            tc.verifyTrue(isvalid(fig), 'and the window stays');
            % stop it and close
            app.ConfirmCloseFcn = @(~) tDiscoveryGui.ask(true);
            fig.CloseRequestFcn(fig, []);
            tc.verifyEqual(tDiscoveryGui.ask('count'), 2);
            tc.verifyFalse(app.isRunning(), 'the batch is stopped');
            tc.verifyEmpty(findall(groot, 'Tag', 'PNNBatchGUIMain'), 'and the window is closed');
        end

        function aFailingQuestionKeepsTheBatch(tc)
            app = tc.openBatchApp(0, 'cpu');
            fig = tc.figureOf(app);
            app.start();
            tc.waitForStage(app, 'detect', 60);
            app.ConfirmCloseFcn = @(~) error('tDiscoveryGui:noDialog', 'cannot ask');
            fig.CloseRequestFcn(fig, []);
            tc.verifyTrue(app.isRunning());
            tc.verifyTrue(isvalid(fig));
            tc.endBatch(app);
        end

        function deleteNeverAsks(tc)
            app = tc.openBatchApp(0, 'cpu');
            app.start();
            tc.waitForStage(app, 'detect', 60);
            app.ConfirmCloseFcn = @(~) tDiscoveryGui.ask(false);
            delete(app);
            tc.verifyEqual(tDiscoveryGui.ask('count'), 0, 'delete(app) does not ask');
            tc.verifyEmpty(findall(groot, 'Tag', 'PNNBatchGUIMain'));
        end

        function anIdleWindowClosesWithoutAsking(tc)
            app = tc.openApp();
            fig = tc.figureOf(app);
            app.ConfirmCloseFcn = @(~) tDiscoveryGui.ask(false);
            fig.CloseRequestFcn(fig, []);
            tc.verifyEqual(tDiscoveryGui.ask('count'), 0);
            tc.verifyEmpty(findall(groot, 'Tag', 'PNNBatchGUIMain'));
        end

        %% Environment check: cache, CUDA

        function passedEnvironmentCheckIsReused(tc)
            app = tc.openBatchApp(1, 'cpu');
            fig = tc.figureOf(app);
            runs0 = app.batchState().PythonRuns;
            out = evalc('app.start();');
            tc.assertTrue(app.isRunning(), app.batchState().Progress);
            tc.verifySubstring(out, '[HINT]', 'cpu with a GPU available: a hint');
            tc.verifySubstring(out, 'cuda:0');
            tc.waitForStage(app, 'detect', 60);
            tc.verifyEqual(app.batchState().PythonRuns - runs0, 2, 'the environment check and predict.py');
            tc.endBatch(app);

            % same three fields: not checked again
            out = evalc('app.start();');
            tc.assertTrue(app.isRunning(), app.batchState().Progress);
            tc.verifySubstring(out, 'not repeated');
            tc.waitForStage(app, 'detect', 60);
            tc.verifyEqual(app.batchState().PythonRuns - runs0, 3, 'predict.py only');
            tc.endBatch(app);

            % the Test env button always runs it, and says whether a GPU is there
            btn = findall(fig, 'Tag', 'testEnvBtn');
            btn.ButtonPushedFcn(btn, []);
            tc.verifyEqual(app.batchState().PythonRuns - runs0, 4);
            tc.verifySubstring(app.batchState().Progress, 'GPU available');

            % a changed field: checked again
            app.configure('PythonExe', tc.makeStubPython('python_stub2', 1));
            app.start();
            tc.assertTrue(app.isRunning(), app.batchState().Progress);
            tc.waitForStage(app, 'detect', 60);
            tc.verifyEqual(app.batchState().PythonRuns - runs0, 6, 'a new interpreter: the check and predict.py');
            tc.endBatch(app);
        end

        function cudaDeviceWithoutAGpuIsRefused(tc)
            app = tc.openBatchApp(0, 'cuda:0');
            runs0 = app.batchState().PythonRuns;
            app.start();
            st = app.batchState();
            tc.verifyFalse(st.Running, 'it does not start');
            tc.verifyEqual(st.PythonRuns - runs0, 1, 'the environment was checked once');
            tc.verifySubstring(st.Progress, 'Device not available');
            tc.verifyEqual(CellDiscovery.gpuCheck('cuda:0', false), 'block');
            % cpu on the same environment starts, with no hint (there is no GPU)
            app.configure('Device', 'cpu');
            out = evalc('app.start();');
            tc.assertTrue(app.isRunning(), app.batchState().Progress);
            tc.verifyFalse(contains(out, '[HINT]'), 'no GPU: no hint');
            tc.endBatch(app);
        end
    end

    methods (Static)
        function restoreClient(restore, top)
            for k = numel(restore):-1:1
                delete(restore{k});   % onCleanup objects: put back now, the last first
            end
            if isfolder(top), rmdir(top, 's'); end
            try celldb.available('Refresh', true); catch, end
        end

        function n = nameOf(f)
            [~, n, e] = fileparts(char(f));
            n = [n e];
        end

        function [h, tips, names] = controls(fig)
            %controls  Every interactive component of the window, its tooltip and a readable name.
            all = findall(fig);
            keep = false(numel(all), 1);
            for i = 1:numel(all)
                keep(i) = any(class(all(i)) == tDiscoveryGui.Interactive);
            end
            h = all(keep);
            tips = strings(numel(h), 1);
            names = strings(numel(h), 1);
            for i = 1:numel(h)
                tips(i) = strjoin(string(h(i).Tooltip), " ");
                nm = string(class(h(i)));
                if isprop(h(i), 'Tag') && strlength(string(h(i).Tag)) > 0, nm = nm + " " + string(h(i).Tag); end
                if isprop(h(i), 'Text'), nm = nm + " '" + string(h(i).Text) + "'"; end
                names(i) = nm;
            end
        end

        function files = marked(lb)
            % The relative paths the file list shows with a check mark.
            labels = string(lb.Items);
            isDone = startsWith(labels, string(char(10003)));
            files = strrep(extractAfter(labels(isDone), 2), "\", "/");
            files = reshape(files, 1, []);
        end

        function r = ask(arg)
            % The test's stand-in for the close question: ask(true | false) answers (and counts),
            % ask('count') returns how often it was asked, ask('reset') clears the count.
            persistent n
            if isempty(n), n = 0; end
            if ischar(arg) && strcmp(arg, 'count')
                r = n;
            elseif ischar(arg) && strcmp(arg, 'reset')
                n = 0; r = 0;
            else
                n = n + 1;
                r = logical(arg);
            end
        end

        function closeApp(app)
            if ~isempty(app) && isvalid(app)
                delete(app);
            end
        end

        function closeNewFigures(before)
            figs = findall(groot, 'Type', 'figure');
            delete(figs(~ismember(figs, before)));
        end

        function removePrefs(g)
            if ispref(g), rmpref(g); end
        end
    end
end

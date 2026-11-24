classdef tDiscovery < matlab.unittest.TestCase
    %TDISCOVERY  CellDiscovery's pure logic, without its window: the page map (migration of saved
    %   maps, the default suffix and the names it gives, the checks Start makes), the file search
    %   (its own *_resized.tif hidden), the Ignore-mode pre-filter, when the resized TIF is
    %   written, the constructor's arguments, the preferences write, the words of a run's tally
    %   (progress label and Command Window summary: tallySummary), and two parsers
    %   (sanitizeImageDescription, parseSnapOptionValue). Reached through CellDiscovery's
    %   Static, Hidden seams. No test reads or writes the PNNBatchGUI preferences.
    %   The batch itself, in its window, is tDiscoveryBatch (Slow, Python).
    %
    %   Run: pwsh -File tools\Run-Tests.ps1 tDiscovery

    properties
        Dir
    end

    properties (Constant)
        DET  = {'(skip)', 'pnn_v2_fasterrcnn_640', 'pv_v2_fasterrcnn_640'}
        RESC = {'(none)', 'pnn_v2_scoring_rank_learning'}
        PREFS = 'tDiscoveryPrefs'   % a group of the test's own (the runner also isolates prefs)
    end

    methods (TestMethodSetup)
        function makeDir(tc)
            fx = tc.applyFixture(matlab.unittest.fixtures.TemporaryFolderFixture);
            tc.Dir = fx.Folder;
        end
    end

    methods (Test)

        %% Page map: saved maps, the default suffix and the names it gives

        function sanitizeMigratesOldLayouts(tc)
            m = tc.DET{2};
            six = {2, 'ECM', m, '(none)', 5, 1.5};
            out = CellDiscovery.sanitizePageMapForTest(six, tc.DET, tc.RESC);
            tc.verifyEqual(out, {2, 'ECM', m, '(none)', false, 5, 1.5, false, true}, ...
                '6 columns: LSM inserted after Rescore, Snap and Normalize appended');

            seven = {1, 'PV', m, '(none)', true, 0, 0};
            out = CellDiscovery.sanitizePageMapForTest(seven, tc.DET, tc.RESC);
            tc.verifyEqual(out, {1, 'PV', m, '(none)', true, 0, 0, false, true}, '7 columns: Snap, Normalize appended');

            eight = {1, 'PV', m, '(none)', false, 0, 2, true};
            out = CellDiscovery.sanitizePageMapForTest(eight, tc.DET, tc.RESC);
            tc.verifyEqual(out, {1, 'PV', m, '(none)', false, 0, 2, true, true}, '8 columns: Normalize appended (on)');

            nine = {1, 'PV', m, tc.RESC{2}, false, 3, 0, false, false};
            out = CellDiscovery.sanitizePageMapForTest(nine, tc.DET, tc.RESC);
            tc.verifyEqual(out, nine, '9 columns: unchanged, Normalize off kept');

            two = [six; {3, 'PV', 'gone_model', 'gone_scorer', 0, -1}];
            out = CellDiscovery.sanitizePageMapForTest(two, tc.DET, tc.RESC);
            tc.verifySize(out, [2 9]);
            tc.verifyEqual(out(2, :), {3, 'PV', m, '(none)', false, 0, 0, false, true}, ...
                'unknown models fall back; a negative resize becomes 0 (auto)');
        end

        function sanitizeFallsBackToTheDefaultMap(tc)
            for bad = {{}, 'not a cell', {1, 'x', 'y'}, cell(1, 10)}
                out = CellDiscovery.sanitizePageMapForTest(bad{1}, tc.DET, tc.RESC);
                tc.verifyEqual(out, {1, 'page', tc.DET{2}, '(none)', false, 0, 0, false, true});
            end
        end

        function defaultSuffixIsPage(tc)
            d = CellDiscovery.defaultPageMapForTest();
            tc.verifyEqual(d{1, 2}, 'page');
            out = CellDiscovery.sanitizePageMapForTest({1, 7, tc.DET{2}, '(none)', false, 0, 0, false, true; ...
                                                        2, [], tc.DET{2}, '(none)', false, 0, 0, false, true}, tc.DET, tc.RESC);
            tc.verifyEqual(out(:, 2), {'page'; 'page'}, 'a non-text suffix becomes ''page'' (was ''page<row>'')');
        end

        function sanitizeKeepsSavedCharSuffixes(tc)
            % Existing results are named after the saved suffix, and Ignore mode finds them by it.
            rows = {1, 'page2', tc.DET{2}, '(none)', false, 0, 0, false, true; ...
                    2, '',      tc.DET{2}, '(none)', false, 0, 0, false, true; ...
                    3, "PV",    tc.DET{2}, '(none)', false, 0, 0, false, true};
            out = CellDiscovery.sanitizePageMapForTest(rows, tc.DET, tc.RESC);
            tc.verifyEqual(out{1, 2}, 'page2');
            tc.verifyEqual(out{2, 2}, '');
            tc.verifyEqual(out{3, 2}, 'PV', 'a string suffix is kept, as char');
        end

        function defaultRowNameRoundTripsToItsPage(tc)
            img = fullfile(tc.Dir, 'SUBJ-1_sec2_proj.tif');
            for pg = [1 2 3 12]
                row = tDiscovery.row(pg, 'page');
                [csv, base] = CellDiscovery.outputCsvPath(tc.Dir, 'SUBJ-1_sec2_proj', 'page', pg);
                tc.verifyEqual(base, sprintf('SUBJ-1_sec2_proj_page%d', pg));
                tc.verifyEqual(csv, fullfile(tc.Dir, [base '_locs.csv']));
                tc.verifyEqual(CellToolkit.pageFromCsvName(csv), pg, csv);
                tc.verifyEqual(CellToolkit.pageFromIdentity(base), pg, base);

                job = CellDiscovery.jobForRowForTest(img, row);   % the name makeJob gives
                tc.verifyEqual(job.outCsvOrig, csv, 'makeJob names the CSV through outputCsvPath');
                tc.verifyEqual(job.imgName, base);
            end
            job = CellDiscovery.jobForRowForTest(img, tDiscovery.row(2, 'page', 2));   % manual resize x2
            tc.verifyEqual(CellToolkit.pageFromCsvName(job.outCsvResized), 2, job.outCsvResized);
        end

        function oldDefaultSuffixesMisreadThePage(tc)
            % The regression this fixes: "Add page" gave suffix 'page<k>', and the first-run default
            % was '' — the page number appended to them reads back wrongly or not at all.
            csv = CellDiscovery.outputCsvPath(tc.Dir, 'img', sprintf('page%d', 2), 2);
            tc.verifyEqual(CellToolkit.pageFromCsvName(csv), 22, 'img_page22_locs.csv reads as page 22');
            csv = CellDiscovery.outputCsvPath(tc.Dir, 'img', '', 2);
            tc.verifyTrue(isnan(CellToolkit.pageFromCsvName(csv)), 'img_2_locs.csv has no readable page');
        end

        %% Page map: what Start refuses and warns about

        function duplicateActivePagesAreAnError(tc)
            m = tc.DET{2};
            map = [tDiscovery.row(1, 'ECM', 0, m); tDiscovery.row(2, 'PV', 0, m); tDiscovery.row(2, 'PNN', 0, m)];
            [errs, warns] = CellDiscovery.checkPageMap(map);
            tc.verifyNumElements(errs, 1);
            tc.verifyTrue(contains(errs{1}, 'Page 2 is in rows 2, 3'), errs{1});
            tc.verifyEmpty(warns);

            map = [map; tDiscovery.row(1, 'ECM', 0, m)];
            errs = CellDiscovery.checkPageMap(map);
            tc.verifyNumElements(errs, 2, 'one error per duplicated page');
            tc.verifyTrue(contains(errs{1}, 'Page 1 is in rows 1, 4'), errs{1});
        end

        function inactiveRowAfterAnActiveOneIsAnError(tc)
            % preprocessAllPages takes the last row naming a page, active or not
            m = tc.DET{2};
            map = [tDiscovery.row(2, 'PV', 0, m); tDiscovery.row(2, 'PV', 3, '(skip)')];
            errs = CellDiscovery.checkPageMap(map);
            tc.verifyNumElements(errs, 1);
            tc.verifyTrue(contains(errs{1}, 'last of them (row 2)'), errs{1});

            errs = CellDiscovery.checkPageMap(flipud(map));
            tc.verifyEmpty(errs, 'an inactive row above the active one is harmless');

            map = [tDiscovery.row(1, 'ECM', 0, m); tDiscovery.row(2, 'PV', 0, '(skip)'); tDiscovery.row(2, 'PV', 0, '')];
            tc.verifyEmpty(CellDiscovery.checkPageMap(map), 'duplicates among inactive rows only');
        end

        function distinctPagesPass(tc)
            m = tc.DET{2};
            map = [tDiscovery.row(1, 'ECM', 0, m); tDiscovery.row(2, 'PV', 0, tc.DET{3}); tDiscovery.row(3, 'page', 0, m)];
            [errs, warns] = CellDiscovery.checkPageMap(map);
            tc.verifyEmpty(errs);
            tc.verifyEmpty(warns);
            [errs, warns] = CellDiscovery.checkPageMap({});
            tc.verifyEmpty(errs);
            tc.verifyEmpty(warns);
        end

        function badSuffixesWarn(tc)
            m = tc.DET{2};
            map = [tDiscovery.row(1, '', 0, m); tDiscovery.row(2, 'page2', 0, m); tDiscovery.row(3, 'P_V', 0, m); ...
                   tDiscovery.row(4, 'ECM', 0, m); tDiscovery.row(5, '7', 0, '(skip)')];
            [errs, warns] = CellDiscovery.checkPageMap(map);
            tc.verifyEmpty(errs);
            tc.verifyNumElements(warns, 3, strjoin(warns, newline));
            tc.verifyTrue(contains(warns{1}, 'row 1 (page 1)') && contains(warns{1}, 'empty') ...
                && contains(warns{1}, 'no page number'), warns{1});
            tc.verifyTrue(contains(warns{2}, '''page2''') && contains(warns{2}, 'read as page 22'), warns{2});
            tc.verifyTrue(contains(warns{3}, '''P_V''') && contains(warns{3}, 'not letters only'), warns{3});
            tc.verifyFalse(any(contains(warns, 'row 4')), 'a letters-only suffix is fine');
            tc.verifyFalse(any(contains(warns, 'row 5')), 'an inactive row is not checked');
        end

        %% File search

        function searchHidesResizedTifs(tc)
            files = fullfile('D:\data', {'a.tif'; 'a_resized.tif'; 'b_RESIZED.TIFF'; 'c_resized.tiff'; ...
                'resized.tif'; 'a_resized_more.tif'; 'a_resized.tif.bak'; 'a_resized.png'});
            [kept, nHidden] = CellDiscovery.hideDerivedImages(files);
            tc.verifyEqual(nHidden, 3);
            tc.verifyEqual(kept, fullfile('D:\data', {'a.tif'; 'resized.tif'; 'a_resized_more.tif'; ...
                'a_resized.tif.bak'; 'a_resized.png'}));
            [kept, nHidden] = CellDiscovery.hideDerivedImages({});
            tc.verifyEmpty(kept);
            tc.verifyEqual(nHidden, 0);
        end

        function fileCountSaysHowManyWereHidden(tc)
            tc.verifyEqual(CellDiscovery.fileCountText(12, 3), '12 files found (3 *_resized.tif hidden)');
            tc.verifyEqual(CellDiscovery.fileCountText(1, 0), '1 file found');
            tc.verifyEqual(CellDiscovery.fileCountText(0, 2), '0 files found (2 *_resized.tif hidden)');
        end

        %% Ignore mode: rows whose result exists are left out before any TIFF is opened

        function pendingRowsSkipsDoneRowsByName(tc)
            m = tc.DET{2};
            map = [tDiscovery.row(1, 'ECM', 0, m); tDiscovery.row(2, 'PV', 0, m); tDiscovery.row(3, 'page', 0, '(skip)')];
            sub = fullfile(tc.Dir, 'animal', 'sec');
            mkdir(sub);
            % None of the images exists: the pre-filter goes by file names only.
            a = fullfile(tc.Dir, 'A_proj.tif');
            b = fullfile(sub, 'B_proj.tif');
            c = fullfile(tc.Dir, 'C_proj.tif');
            tDiscovery.touch(CellDiscovery.outputCsvPath(tc.Dir, 'A_proj', 'ECM', 1));
            tDiscovery.touch(CellDiscovery.outputCsvPath(tc.Dir, 'A_proj', 'PV', 2));
            tDiscovery.touch(CellDiscovery.outputCsvPath(sub, 'B_proj', 'ECM', 1));
            tDiscovery.touch(fullfile(tc.Dir, 'C_proj_page3_locs.csv'));   % an inactive row's name
            files = {a; b; c};

            [todo, nDone] = CellDiscovery.pendingRows(files, map, false);
            tc.verifySize(todo, [3 1]);
            tc.verifyEmpty(todo{1}, 'all of A is done: it is not opened at all');
            tc.verifyEqual(todo{2}, 2);
            tc.verifyEqual(todo{3}, [1 2], 'the inactive row 3 is never a job');
            tc.verifyEqual(nDone, 3);

            [todo, nDone] = CellDiscovery.pendingRows(files, map, true);
            tc.verifyEqual(todo, {[1 2]; [1 2]; [1 2]}, 'Overwrite: every active row');
            tc.verifyEqual(nDone, 0);

            [todo, nDone] = CellDiscovery.pendingRows(files, map(3, :), false);
            tc.verifyEqual(todo, {zeros(1, 0); zeros(1, 0); zeros(1, 0)});
            tc.verifyEqual(nDone, 0, 'no active row: nothing done, nothing to do');
        end

        function preFilterAndJobUseTheSameName(tc)
            img = fullfile(tc.Dir, 'D_proj.tif');
            row = tDiscovery.row(2, 'PV', 0, tc.DET{2});
            job = CellDiscovery.jobForRowForTest(img, row);
            [todo, nDone] = CellDiscovery.pendingRows({img}, row, false);
            tc.verifyEqual(todo, {1});
            tc.verifyEqual(nDone, 0);
            tDiscovery.touch(job.outCsvOrig);   % the file the job would write
            [todo, nDone] = CellDiscovery.pendingRows({img}, row, false);
            tc.verifyEqual(todo, {zeros(1, 0)});
            tc.verifyEqual(nDone, 1);
        end

        %% The resized TIF: once per file in a run, by the first job that completes

        function resizedTifDecision(tc)
            % (saveTif, writtenThisRun, overwrite, tifExists)
            tc.verifyFalse(CellDiscovery.resizedTifDue(false, false, true, false), 'box off');
            tc.verifyFalse(CellDiscovery.resizedTifDue(true, true, true, false), 'already written for this file');
            tc.verifyTrue(CellDiscovery.resizedTifDue(true, false, false, false), 'Ignore, no TIF yet');
            tc.verifyFalse(CellDiscovery.resizedTifDue(true, false, false, true), 'Ignore keeps an existing TIF');
            tc.verifyTrue(CellDiscovery.resizedTifDue(true, false, true, true), 'Overwrite replaces it');
            tc.verifyTrue(CellDiscovery.resizedTifDue(1, 0, 1, false), 'numeric flags (radio/checkbox values)');
        end

        function jobsNoLongerCarryFirstPage(tc)
            job = CellDiscovery.jobForRowForTest(fullfile(tc.Dir, 'E.tif'), tDiscovery.row(1, 'page'));
            tc.verifyFalse(isfield(job, 'firstPage'), 'the TIF no longer depends on the first row');
        end

        %% Constructor arguments and preferences

        function constructorArguments(tc)
            [f, o] = CellDiscovery.parseConstructorArgs();
            tc.verifyEqual(f, '');
            tc.verifyEqual(o.PrefGroup, 'PNNBatchGUI');
            tc.verifyTrue(o.Search);

            [f, o] = CellDiscovery.parseConstructorArgs(" D:\data\set 1 ");
            tc.verifyEqual(f, 'D:\data\set 1', 'text folder, trimmed, as char');
            tc.verifyTrue(o.Search);

            [f, o] = CellDiscovery.parseConstructorArgs('D:\data', 'Search', false, 'PrefGroup', tc.PREFS);
            tc.verifyEqual(f, 'D:\data');
            tc.verifyFalse(o.Search);
            tc.verifyEqual(o.PrefGroup, tc.PREFS);

            [f, o] = CellDiscovery.parseConstructorArgs('prefgroup', "myGroup", 'search', 0);
            tc.verifyEqual(f, '', 'an even count is all name-value pairs');
            tc.verifyEqual(o.PrefGroup, 'myGroup');
            tc.verifyFalse(o.Search);

            tc.verifyError(@() CellDiscovery.parseConstructorArgs(5), 'CellDiscovery:badFolder');
            tc.verifyError(@() CellDiscovery.parseConstructorArgs('D:\data', 'Bogus', 1), ?MException);
            tc.verifyError(@() CellDiscovery.parseConstructorArgs('PrefGroup', 'not a name'), ?MException);
        end

        function prefsAreWrittenInOneCall(tc)
            g = tc.PREFS;
            tc.addTeardown(@() tDiscovery.removePrefs(g));
            tDiscovery.removePrefs(g);
            P = struct('parentDir', 'D:\data', 'overwrite', 0, 'autoContrast', true, ...
                'lsmOptions', CellDiscovery.defaultLSMOptionsForTest(), 'snapOptions', struct(), ...
                'pageMapData', {[tDiscovery.row(1, 'ECM'); tDiscovery.row(2, 'PV')]});
            CellDiscovery.writePrefs(g, P);
            tc.verifyEqual(getpref(g), P, 'every field, including the cell-valued page map');
            tc.verifyEqual(size(getpref(g, 'pageMapData')), [2 9]);
            P.parentDir = 'E:\other';
            CellDiscovery.writePrefs(g, P);
            tc.verifyEqual(getpref(g, 'parentDir'), 'E:\other');
        end

        %% The run's tally: the progress label and the Command Window summary

        function tallyOfACleanRun(tc)
            t = CellDiscovery.newTally(3, 0);
            tc.verifyEqual([t.queued t.done t.skipped t.notRun], [3 0 0 0]);
            tc.verifyEmpty(t.failed);
            tc.verifyEmpty(t.warnings);
            tc.verifyEmpty(t.aborted);
            t.done = 3;
            t.state = 'complete';
            [label, lines, failed] = CellDiscovery.tallySummary(t);
            tc.verifyEqual(label, 'Complete: 3 done, 0 skipped, 0 failed');
            tc.verifyFalse(failed);
            tc.verifyEqual(lines, {'=== PNN Batch GUI: complete: 3 done, 0 skipped, 0 failed ==='; ''}');
        end

        function tallyNamesFailedPagesAndWarnings(tc)
            t = CellDiscovery.newTally(40, 4);
            t.done = 38;
            t.failed(end+1, 1) = struct('label', 'A_proj  (page 1/2)', 'reason', 'predict.py exited with code 1');
            t.failed(end+1, 1) = struct('label', 'B_proj  (page 2/2)', 'reason', 'could not read or preprocess the page: bad TIFF');
            t.state = 'complete';
            [label, lines, failed] = CellDiscovery.tallySummary(t);
            tc.verifyEqual(label, 'Complete: 38 done, 4 skipped, 2 failed (see the Command Window)');
            tc.verifyTrue(failed, 'a failed page makes the label red');
            tc.verifyEqual(lines, {'=== PNN Batch GUI: complete: 38 done, 4 skipped, 2 failed ==='; ...
                'Failed pages (2):'; ...
                '  A_proj  (page 1/2): predict.py exited with code 1'; ...
                '  B_proj  (page 2/2): could not read or preprocess the page: bad TIFF'; ''}');

            t.warnings(end+1, 1) = struct('label', 'C_proj  (page 1/1)', 'reason', 'rescoring failed: score.py exited with code 2');
            [label, lines] = CellDiscovery.tallySummary(t);
            tc.verifyEqual(label, 'Complete: 38 done, 4 skipped, 2 failed, 1 warning (see the Command Window)');
            tc.verifyEqual(lines(end-2:end), {'Warnings on completed pages (1):'; ...
                '  C_proj  (page 1/1): rescoring failed: score.py exited with code 2'; ''}');

            t.failed = t.failed([]);
            t.warnings(end+1, 1) = struct('label', 'D_proj  (page 1/1)', 'reason', 'PNG not saved');
            [label, ~, failed] = CellDiscovery.tallySummary(t);
            tc.verifyEqual(label, 'Complete: 38 done, 4 skipped, 0 failed, 2 warnings (see the Command Window)');
            tc.verifyFalse(failed, 'warnings alone do not make the label red');
        end

        function tallyOfAStoppedAndAnAbortedRun(tc)
            t = CellDiscovery.newTally(8, 1);
            t.done = 3;
            t.notRun = 5;
            t.state = 'stopped';
            [label, lines, failed] = CellDiscovery.tallySummary(t);
            tc.verifyEqual(label, 'Stopped: 3 done, 1 skipped, 0 failed, 5 not run');
            tc.verifyEqual(lines{1}, '=== PNN Batch GUI: stopped: 3 done, 1 skipped, 0 failed, 5 not run ===');
            tc.verifyFalse(failed);

            t.aborted = 'E_proj  (page 2/2)';
            t.notRun = 4;
            t.state = 'aborted';
            [label, lines, failed] = CellDiscovery.tallySummary(t);
            tc.verifyEqual(label, 'Aborted: 3 done, 1 skipped, 0 failed, 1 aborted, 4 not run (see the Command Window)');
            tc.verifyEqual(lines{2}, 'Aborted page (discarded, nothing written for it): E_proj  (page 2/2)');
            tc.verifyFalse(failed, 'an abort is the person''s choice, not a failure');

            t = CellDiscovery.newTally(2, 0);
            t.failed(end+1, 1) = struct('label', 'F_proj  (page 1/1)', 'reason', 'internal error: boom');
            t.notRun = 1;
            t.error = 'boom';
            t.state = 'error';
            [label, ~, failed] = CellDiscovery.tallySummary(t);
            tc.verifyEqual(label, 'Stopped on an internal error: 0 done, 0 skipped, 1 failed, 1 not run (see the Command Window)');
            tc.verifyTrue(failed);
        end

        %% Parsers

        function sanitizeImageDescriptionDropsStackLayout(tc)
            f = @CellDiscovery.sanitizeImageDescriptionForTest;
            tc.verifyEqual(f(''), '');
            tc.verifyEqual(f([]), '');
            plain = sprintf('made by a camera\nimages=3');
            tc.verifyEqual(f(plain), plain, 'not ImageJ: unchanged');

            ij = sprintf(['ImageJ=1.53k\nimages=2\nchannels=2\nslices=1\nframes=1\nhyperstack=true\n' ...
                'mode=composite\nunit=micron\nspacing=1.0\nloop=false\n']);
            tc.verifyEqual(f(ij), sprintf('ImageJ=1.53k\nunit=micron\nspacing=1.0\n'));

            crlf = sprintf('ImageJ=1.54f\r\n  Images=4\r\nunit=micron\r\n');
            tc.verifyEqual(f(crlf), sprintf('ImageJ=1.54f\nunit=micron\n'), 'CRLF, case and indentation');
            tc.verifyEqual(f(string(ij)), sprintf('ImageJ=1.53k\nunit=micron\nspacing=1.0\n'), 'string in, char out');
        end

        function parseSnapOptionValues(tc)
            f = @CellDiscovery.parseSnapOptionValueForTest;
            for skipMe = {'auto', 'AUTO', '', '   ', "auto", {}, struct()}
                [~, skip] = f(skipMe{1});
                tc.verifyTrue(skip, sprintf('skipped: %s', class(skipMe{1})));
            end
            tc.verifyEqual(tDiscovery.parsed(f, 'true'), true);
            tc.verifyEqual(tDiscovery.parsed(f, 'False'), false);
            tc.verifyEqual(tDiscovery.parsed(f, '18'), 18);
            tc.verifyEqual(tDiscovery.parsed(f, ' 1.5 '), 1.5);
            tc.verifyEqual(tDiscovery.parsed(f, '[5 5]'), [5 5]);
            tc.verifyEqual(tDiscovery.parsed(f, "0.645"), 0.645);
            tc.verifyEqual(tDiscovery.parsed(f, 'tophat'), 'tophat');
            tc.verifyEqual(tDiscovery.parsed(f, 'radial-symmetry'), 'radial-symmetry');
            tc.verifyEqual(tDiscovery.parsed(f, 'weighted-centroid'), 'weighted-centroid');
            tc.verifyEqual(tDiscovery.parsed(f, 7), 7);
            tc.verifyEqual(tDiscovery.parsed(f, true), true);
        end
    end

    methods (Test)

        %% Stage 3: window size, done marks, field checks, GPU hint, environment cache

        function windowFitsEveryScreen(tc)
            for sz = [1536 864; 1920 1080; 2560 1440; 1366 768; 1280 720; 3840 2160]'
                pos = CellDiscovery.windowPosition(sz');
                w = sz(1); h = sz(2);
                tc.verifyGreaterThanOrEqual(pos(1), 1, sprintf('%dx%d: left edge on screen', w, h));
                tc.verifyLessThanOrEqual(pos(1) + pos(3) - 1, w, sprintf('%dx%d: right edge on screen', w, h));
                tc.verifyGreaterThanOrEqual(pos(2), 1 + 40, sprintf('%dx%d: clear of the taskbar', w, h));
                tc.verifyLessThanOrEqual(pos(2) + pos(4) - 1 + 40, h, sprintf('%dx%d: title bar on screen', w, h));
                tc.verifyLessThanOrEqual(pos(3), 1300);
                tc.verifyLessThanOrEqual(pos(4), 1010);
                tc.verifyLessThan(abs((pos(1) - 1) - (w - pos(1) - pos(3) + 1)), 2, 'centred sideways');
            end
            big = CellDiscovery.windowPosition([3840 2160]);
            tc.verifyEqual(big(3:4), [1300 1010], 'a big screen keeps the design size');
            p = CellDiscovery.windowPosition([1536 864]);
            tc.verifyEqual(p(3:4), [1300 768]);
        end

        function resultCsvsAreTakenFromTheListing(tc)
            L = {'C:\d\a.tif'; 'C:\d\a_page1_locs.csv'; 'C:\d\A_PAGE2_LOCS.CSV'; 'C:\d\a_page1_locs_resized.csv'; 'C:\d\n.txt'};
            tc.verifyEqual(CellDiscovery.resultCsvsOf(L), L([2 3]));
            tc.verifyEqual(CellDiscovery.resultCsvsOf({}), {});
        end

        function filesDoneNeedsEveryActiveRow(tc)
            d = 'C:\data';
            a = fullfile(d, 'a.tif');  b = fullfile(d, 'sub', 'b.tif');  c = fullfile(d, 'c.tif');
            files = {a; b; c};
            map = [tDiscovery.row(1, 'page'); tDiscovery.row(2, 'page'); ...
                   tDiscovery.row(3, 'page', 0, '(skip)')];   % row 3 is inactive
            listing = { ...
                fullfile(d, 'a_page1_locs.csv'); fullfile(d, 'a_page2_locs.csv'); ...      % a: both rows
                fullfile(d, 'sub', 'b_page1_locs.csv'); ...                                  % b: page 2 missing
                fullfile(d, 'c_page2_locs.csv'); ...                                         % c: page 1 missing
                fullfile(d, 'a_page3_locs.csv')};                                            % the inactive row's file is irrelevant
            tc.verifyEqual(CellDiscovery.filesDone(files, map, listing), [true; false; false]);
            % case does not matter on Windows
            if ispc
                tc.verifyEqual(CellDiscovery.filesDone(files(1), map, upper(listing)), true);
            end
            % one row only: b is done now
            tc.verifyEqual(CellDiscovery.filesDone(files, map(1, :), listing), [true; true; false]);
            % no active row: nothing is done
            tc.verifyEqual(CellDiscovery.filesDone(files, map(3, :), listing), [false; false; false]);
            % the suffix is part of the name
            tc.verifyEqual(CellDiscovery.filesDone(files(1), tDiscovery.row(1, 'ECM'), listing), false);
            % nothing listed, no files
            tc.verifyEqual(CellDiscovery.filesDone(files, map, {}), [false; false; false]);
            tc.verifyEmpty(CellDiscovery.filesDone({}, map, listing));
        end

        function wantedCsvsMatchTheJobsOutputs(tc)
            map = [tDiscovery.row(2, 'ECM'); tDiscovery.row(1, 'x', 0, '(skip)')];
            want = CellDiscovery.wantedCsvs({fullfile(tc.Dir, 's.tif')}, map);
            tc.verifySize(want, [1 1]);
            tc.verifyEqual(want{1}, CellDiscovery.outputCsvPath(tc.Dir, 's', 'ECM', 2));
        end

        function fileLabelsAndCountText(tc)
            lab = CellDiscovery.fileLabels({'a.tif'; 'b.tif'}, [true; false]);
            tc.verifyEqual(lab{1}, [char(10003) ' a.tif']);
            tc.verifyEqual(lab{2}, '   b.tif');
            tc.verifyEqual(CellDiscovery.fileCountText(132, 3, 97), ...
                ['132 files found ' char(183) ' 97 done (3 *_resized.tif hidden)']);
            tc.verifyEqual(CellDiscovery.fileCountText(1, 0, 0), ['1 file found ' char(183) ' 0 done']);
            tc.verifyEqual(CellDiscovery.fileCountText(0, 0, 0), '0 files found', 'no "done" without files');
            tc.verifyEqual(CellDiscovery.fileCountText(12, 3), '12 files found (3 *_resized.tif hidden)', 'two arguments: as before');
        end

        function fieldChecks(tc)
            ok = @(d, b, t) CellDiscovery.checkFields(d, b, t);
            tc.verifyEmpty(ok('cpu', '1', ''));
            tc.verifyEmpty(ok(' CUDA:0 ', ' 16 ', ' 0.5 '));
            tc.verifyEmpty(ok('mps', '512', '0'));
            tc.verifyEmpty(ok('cuda', '2', '1'));
            tc.verifyEmpty(ok("cuda:12", "4", "0.05"));
            e = ok('gpu', '1', '');
            tc.verifyNumElements(e, 1);
            tc.verifySubstring(e{1}, 'Device ''gpu''');
            tc.verifySubstring(e{1}, 'cuda:<n>');
            for d = {'', 'cuda:', 'cuda:x', 'cuda0', 'cpu0', 'cuda:-1', 'cuda:0:1'}
                tc.verifyNotEmpty(ok(d{1}, '1', ''), "device '" + d{1} + "' is refused");
            end
            for b = {'', '0', '-1', '1.5', 'abc', '1e3', '2 3'}
                e = ok('cpu', b{1}, '');
                tc.verifyNumElements(e, 1, "batch size '" + b{1} + "' is refused");
                tc.verifySubstring(e{1}, 'Batch size');
            end
            for t = {'1.5', '-0.1', 'abc', 'NaN', 'Inf'}
                e = ok('cpu', '1', t{1});
                tc.verifyNumElements(e, 1, "threshold '" + t{1} + "' is refused");
                tc.verifySubstring(e{1}, 'Threshold');
            end
            e = ok('x', '0', '2');
            tc.verifyNumElements(e, 3, 'each bad field is named');
        end

        function gpuCheckBlocksCudaWithoutAGpu(tc)
            [a, m] = CellDiscovery.gpuCheck('cuda:0', false);
            tc.verifyEqual(a, 'block');
            tc.verifySubstring(m, 'no CUDA GPU');
            tc.verifyEqual(CellDiscovery.gpuCheck(' CUDA ', false), 'block');
            [a, m] = CellDiscovery.gpuCheck('cpu', true);
            tc.verifyEqual(a, 'hint');
            tc.verifySubstring(m, 'cuda:0');
            tc.verifyEqual(CellDiscovery.gpuCheck('cuda:0', true), 'ok');
            tc.verifyEqual(CellDiscovery.gpuCheck('cpu', false), 'ok');
            tc.verifyEqual(CellDiscovery.gpuCheck('mps', true), 'ok');
            for d = {'cpu', 'cuda:0', 'mps'}
                tc.verifyEqual(CellDiscovery.gpuCheck(d{1}, NaN), 'ok', 'unknown: never blocks');
            end
        end

        function environmentKeyAndStatusText(tc)
            k = CellDiscovery.envKey('python', 'C:\conda\conda.exe', 'countpnn');
            tc.verifyEqual(CellDiscovery.envKey(' python ', 'C:\conda\conda.exe ', ' countpnn'), k, 'blanks around a field do not matter');
            tc.verifyNotEqual(CellDiscovery.envKey('python3', 'C:\conda\conda.exe', 'countpnn'), k);
            tc.verifyNotEqual(CellDiscovery.envKey('python', 'D:\conda\conda.exe', 'countpnn'), k);
            tc.verifyNotEqual(CellDiscovery.envKey('python', 'C:\conda\conda.exe', 'other'), k);
            tc.verifyEqual(CellDiscovery.envStatusText(NaN), 'Environment OK');
            tc.verifySubstring(CellDiscovery.envStatusText(true), 'GPU available');
            tc.verifyEqual(CellDiscovery.envStatusText(true), ['Environment OK ' char(183) ' GPU available']);
            tc.verifySubstring(CellDiscovery.envStatusText(false), 'no GPU');
        end
    end

    methods (Static)
        function r = row(page, suffix, resize, model)
            % One 9-column page-map row: Page, Suffix, Detection model, Rescore model, LSM,
            % Bg radius, Resize x, Snap, Normalize.
            if nargin < 3, resize = 0; end
            if nargin < 4, model = 'pnn_v2_fasterrcnn_640'; end
            r = {page, suffix, model, '(none)', false, 0, resize, false, true};
        end

        function v = parsed(f, x)
            [v, skip] = f(x);
            assert(~skip, 'unexpectedly skipped');
        end

        function touch(file)
            fid = fopen(file, 'w');
            assert(fid > 0, 'could not create %s', file);
            fclose(fid);
        end

        function removePrefs(g)
            if ispref(g), rmpref(g); end
        end
    end
end

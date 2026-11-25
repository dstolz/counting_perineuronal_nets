classdef tCuratorHeadlessFlow < matlab.unittest.TestCase
    %tCuratorHeadlessFlow  CellCurator driven through its test seams (handleKey, galleryClick,
    %   hoverTile, confirmPage, showQueue, nextSource) on the synthetic fixture; every decision is
    %   checked in the curation store and its journal.
    %
    %   Run on the hidden desktop: tools\Run-Tests.ps1 tCuratorHeadlessFlow

    properties
        Folder
        Truth
        TimersBefore
    end

    methods (TestMethodSetup)
        function makeFixture(tc)
            tc.TimersBefore = timerfindall;
            fx = tc.applyFixture(matlab.unittest.fixtures.TemporaryFolderFixture);
            % Mark source complete makes a lab database record: no client, and its sidecar kept here
            tc.applyFixture(matlab.unittest.fixtures.EnvironmentVariableFixture('CELLDB_NO_CLIENT', '1'));
            tc.applyFixture(matlab.unittest.fixtures.EnvironmentVariableFixture('CELLDB_PROVENANCE_DIR', ...
                fullfile(fx.Folder, 'provenance')));
            [tc.Folder, tc.Truth] = makeSyntheticDataset(fullfile(fx.Folder, 'ds'));
        end
    end

    methods
        function app = openApp(tc, varargin)
            %openApp  A CellCurator on the fixture's ECM1 source, laid out, closed at teardown.
            app = CellCurator('UseSettings', false, 'PrepareNext', false, 'Assist', false, 'ConfirmAudit', false, varargin{:});
            tc.addTeardown(@() tCuratorHeadlessFlow.closeApp(app));
            app.openParent(tc.Folder, '', 'ECM1');
            app.waitForLayout();
            tc.assertEqual(app.SourceKey, "ECM1", app.StatusText);
            tc.assertEqual(app.Page.Kind, "active", app.ContextText);
        end

        function R = journal(~, app)
            R = curation.Journal.read(app.Store.Paths.journal, 0);
        end
    end

    methods (Static)
        function closeApp(app)
            if ~isempty(app) && isvalid(app)
                delete(app);
            end
        end

        function s = opposite(label)
            if label == "Good", s = "Bad"; else, s = "Good"; end
        end
    end

    % ------------------------------------------------------------------------------------------------
    methods (Test)
        function firstPageHasDefaultAndContext(tc)
            app = tc.openApp();
            P = app.Page;
            K = numel(P.Ids);
            tc.verifyTrue(any(P.Default == ["Good" "Bad"]), 'a review page has one default');
            tc.verifyGreaterThan(K, 5);
            tc.verifyLessThanOrEqual(K, prod(app.Gallery.Grid), 'page size = gallery capacity');
            tc.verifyEqual(nnz(P.Untouched), K, 'every tile starts untouched');
            tc.verifySubstring(char(app.ContextText), sprintf('Enter: mark the %d untouched tiles %s', K, P.Default));
            tc.verifySubstring(char(app.ContextText), sprintf('page 1 of '));
            % the page is homogeneous in P: one band
            T = app.Store.T;
            tc.verifyTrue(all(T.Label(app.Store.rowsOf(P.Ids)) == ""), 'only undecided cells are proposed');
        end

        function clicksCreateHumanExceptions(tc)
            app = tc.openApp();
            P = app.Page;
            st = app.Store;
            K = numel(P.Ids);
            id = P.Ids(1);
            opp = tCuratorHeadlessFlow.opposite(P.Default);
            app.galleryClick(1, 'normal');
            tc.verifyEqual(st.get('Label', id), opp, 'a click marks the exception');
            tc.verifyEqual(st.get('LabelSource', id), "human");
            tc.verifyTrue(st.get('Reviewed', id));
            tc.verifyEqual(st.get('ProposalP', id), P.P(1), 'AbsTol', 1e-12, 'ProposalP is stored');
            tc.verifyFalse(app.Page.Untouched(1));
            tc.verifySubstring(char(app.ContextText), sprintf('mark the %d untouched', K - 1), ...
                'the context line follows the exceptions');
            % already in the journal (crash-safe), with the page context
            R = tc.journal(app);
            hit = R.CellID == string(id) & R.Field == "Label" & R.New == opp;
            tc.verifyTrue(any(hit), 'the decision is journaled at once');
            tc.verifyTrue(any(hit & R.PageId == P.PageId & R.Queue == "review"), 'journal line carries Queue and PageId');
            % click again: back to untouched
            app.galleryClick(1, 'normal');
            tc.verifyEqual(st.get('Label', id), "");
            tc.verifyFalse(st.get('Reviewed', id));
            tc.verifyTrue(app.Page.Untouched(1));
            tc.verifySubstring(char(app.ContextText), sprintf('mark the %d untouched', K));
        end

        function enterConfirmsExactlyTheUntouched(tc)
            app = tc.openApp();
            P = app.Page;
            st = app.Store;
            app.galleryClick(2, 'normal');
            app.galleryClick(4, 'alt');
            pause(0.05);
            app.handleKey('return', {});
            ids = P.Ids;
            exc = ids([2 4]);
            rest = ids(setdiff(1:numel(ids), [2 4]));
            tc.verifyEqual(st.get('LabelSource', exc), ["human"; "human"]);
            tc.verifyEqual(st.get('Label', exc(2)), "Uncertain", 'right-click = Uncertain');
            tc.verifyTrue(all(st.get('Label', rest) == P.Default), 'untouched tiles get the default');
            tc.verifyTrue(all(st.get('LabelSource', rest) == "confirmed"));
            tc.verifyEqual(st.get('ProposalP', rest), P.P(setdiff(1:numel(ids), [2 4])), 'AbsTol', 1e-12);
            tc.verifyEqual(app.Page.Kind, "active");
            tc.verifyEmpty(intersect(app.Page.Ids, ids), 'the next page shows other cells');
            tc.verifySubstring(char(app.ContextText), 'page 2 of ');
            tc.verifySubstring(char(app.StatusText), sprintf('Marked %d %s', numel(rest), P.Default));
            % one transaction with the dwell time on every journal line
            R = tc.journal(app);
            conf = R.Field == "LabelSource" & R.New == "confirmed" & R.PageId == P.PageId;
            tc.verifyEqual(nnz(conf), numel(rest));
            tc.verifyTrue(all(strlength(R.DwellMs(conf)) > 0), 'DwellMs is journaled');
            tc.verifyEqual(numel(unique(R.Seq(conf))), 1, 'one transaction');
            tc.verifyGreaterThan(str2double(R.DwellMs(find(conf, 1))), 0);
        end

        function undoRestoresThePageRedoReapplies(tc)
            app = tc.openApp();
            P = app.Page;
            st = app.Store;
            app.galleryClick(3, 'normal');
            app.handleKey('return', {});
            tc.assertNotEqual(app.Page.PageId, P.PageId);
            app.handleKey('z', {'control'});
            tc.verifyEqual(app.Page.PageId, P.PageId, 'undo brings the confirmed page back');
            tc.verifyEqual(app.Page.Kind, "active");
            u = setdiff(1:numel(P.Ids), 3);
            tc.verifyTrue(all(st.get('Label', P.Ids(u)) == ""), 'its untouched tiles are untouched again');
            tc.verifyEqual(st.get('Label', P.Ids(3)), tCuratorHeadlessFlow.opposite(P.Default), 'the exception stays');
            tc.verifyEqual(nnz(app.Page.Untouched), numel(u));
            tc.verifySubstring(char(app.StatusText), 'Undid: Confirm page 1');
            app.handleKey('y', {'control'});
            tc.verifyTrue(all(st.get('LabelSource', P.Ids(u)) == "confirmed"), 'redo confirms again');
            tc.verifyNotEqual(app.Page.PageId, P.PageId, 'and moves on');
            tc.verifySubstring(char(app.StatusText), 'Redid: Confirm page 1');
            % undo an exception on the page on screen: repainted in place
            Q = app.Page;
            app.galleryClick(1, 'normal');
            app.handleKey('z', {'control'});
            tc.verifyEqual(app.Page.PageId, Q.PageId);
            tc.verifyEqual(st.get('Label', Q.Ids(1)), "");
        end

        function keysActOnHoverElseCursor(tc)
            app = tc.openApp();
            P = app.Page;
            st = app.Store;
            K = numel(P.Ids);
            tc.assumeGreaterThanOrEqual(K, 8, 'the first page is long enough for this test');
            app.hoverTile(5);
            app.handleKey('b', {});
            tc.verifyEqual(st.get('Label', P.Ids(5)), "Bad", 'key acts on the tile under the pointer');
            tc.verifyEqual(app.InspectedTile, 5, 'hover shows the cell in the inspector');
            app.hoverTile(0);
            app.handleKey('g', {});
            tc.verifySubstring(char(app.StatusText), 'Point at a tile', 'nothing to act on: a hint, no change');
            app.handleKey('downarrow', {});          % shows the cursor
            k = app.Cursor;
            tc.verifyGreaterThan(k, 0);
            app.handleKey('downarrow', {});
            k2 = app.Cursor;
            want = k + app.Gallery.Layout.NCols;
            if want > K, want = k; end
            tc.verifyEqual(k2, want, 'down moves one row (stays on the last row)');
            app.handleKey('rightarrow', {});
            want = k2 + 1;
            if want > K, want = k2; end
            tc.verifyEqual(app.Cursor, want, 'right moves one tile');
            app.handleKey('leftarrow', {});
            tc.verifyEqual(app.Cursor, max(want - 1, 1), 'left moves one tile back');
            app.handleKey('rightarrow', {});
            tc.verifyEqual(app.Cursor, want, 'and right again');
            tc.verifyEqual(app.Page.Kind, "active", 'the arrows never turn the page');
            k3 = app.Cursor;
            app.handleKey('u', {});
            tc.verifyEqual(st.get('Label', P.Ids(k3)), "Uncertain", 'no hover: the cursor tile');
            app.hoverTile(7);
            app.handleKey('g', {});
            tc.verifyEqual(st.get('Label', P.Ids(7)), "Good", 'hover wins over the cursor');
            tc.verifyEqual(st.get('LabelSource', P.Ids([5 7 k3])), repmat("human", 3, 1));
        end

        function flagAndClear(tc)
            app = tc.openApp();
            P = app.Page;
            st = app.Store;
            K = numel(P.Ids);
            app.hoverTile(2);
            app.handleKey('f', {});
            tc.verifyEqual(st.get('Flag', P.Ids(2)), "later");
            tc.verifyFalse(app.Page.Untouched(2), 'a flagged tile is not confirmed by Enter');
            tc.verifySubstring(char(app.ContextText), sprintf('mark the %d untouched', K - 1));
            app.handleKey('f', {});
            tc.verifyEqual(st.get('Flag', P.Ids(2)), "", 'f again removes the flag');
            app.handleKey('b', {});
            app.handleKey('f', {});
            tc.verifyEqual(st.get('Label', P.Ids(2)), "Bad");
            tc.verifyEqual(st.get('Flag', P.Ids(2)), "later");
            app.handleKey('x', {});
            tc.verifyEqual(st.get('Label', P.Ids(2)), "", 'x clears the label');
            tc.verifyEqual(st.get('Flag', P.Ids(2)), "", 'and the flag');
            tc.verifyTrue(app.Page.Untouched(2));
            app.handleKey('b', {});
            app.handleKey('backspace', {});
            tc.verifyEqual(st.get('Label', P.Ids(2)), "", 'Backspace clears too');
            % flagged tiles are left out of the confirm and wait in the Flagged queue
            app.handleKey('f', {});
            app.handleKey('return', {});
            tc.verifyEqual(st.get('Label', P.Ids(2)), "", 'Enter leaves a flagged tile alone');
            app.showQueue('flagged');
            tc.verifyEqual(app.QueueName, "flagged");
            tc.verifyEqual(app.Page.Kind, "list");
            tc.verifyTrue(any(app.Page.Ids == P.Ids(2)));
            tc.verifyEqual(app.Page.Default, "", 'no default on the Flagged queue');
        end

        function rightClickAndDragPaint(tc)
            app = tc.openApp();
            P = app.Page;
            st = app.Store;
            app.galleryClick(6, 'alt');
            tc.verifyEqual(st.get('Label', P.Ids(6)), "Uncertain");
            app.galleryClick(6, 'alt');
            tc.verifyEqual(st.get('Label', P.Ids(6)), "", 'right-click again: back to untouched');
            % a drag: the press decides, every tile entered gets the same change, one undo step
            opp = tCuratorHeadlessFlow.opposite(P.Default);
            g = app.Gallery;
            g.onButtonDown(struct('AxesPoint', g.tileCenter(1), 'SelectionType', 'normal'));
            g.onMotion(struct('AxesPoint', g.tileCenter(2)));
            g.onMotion(struct('AxesPoint', g.tileCenter(3)));
            g.onButtonUp(struct('AxesPoint', g.tileCenter(3)));
            tc.verifyEqual(st.get('Label', P.Ids(1:3)), repmat(opp, 3, 1), 'drag paints the exception');
            app.handleKey('z', {'control'});
            tc.verifyEqual(st.get('Label', P.Ids(1:3)), repmat("", 3, 1), 'one undo step for the drag');
        end

        function queueSwitchAndHistory(tc)
            app = tc.openApp();
            P1 = app.Page;
            app.handleKey('return', {});
            P2 = app.Page;
            app.handleKey('pageup', {});
            tc.verifyEqual(app.Page.Kind, "history");
            tc.verifyEqual(app.Page.PageId, P1.PageId, 'PgUp shows the previous page');
            % a click on a history page switches Good <-> Bad as a human decision
            lab = app.Store.get('Label', P1.Ids(1));
            app.galleryClick(1, 'normal');
            tc.verifyEqual(app.Store.get('Label', P1.Ids(1)), tCuratorHeadlessFlow.opposite(lab));
            tc.verifyEqual(app.Store.get('LabelSource', P1.Ids(1)), "human");
            app.handleKey('pagedown', {});
            tc.verifyEqual(app.Page.PageId, P2.PageId, 'PgDn goes forward to the live page');
            tc.verifyEqual(app.Page.Kind, "active");
            app.showQueue('browseGood');
            tc.verifyEqual(app.QueueName, "browseGood");
            if app.Page.Kind == "list"
                tc.verifyTrue(all(app.Store.get('Label', app.Page.Ids) == "Good"));
                tc.verifySubstring(char(app.ContextText), 'Browse Good');
            end
            app.showQueue('review');
            tc.verifyEqual(app.Page.Kind, "active");
            tc.verifyEmpty(intersect(app.Page.Ids, P1.Ids), 'reviewed cells are not proposed again');
        end

        function pageKeysMoveFreelyAndLabelNothing(tc)
            % PgDn leaves a page unconfirmed (nothing is labeled, its tiles stay in the queue) and
            % PgUp comes back to it; Enter confirms only the page on screen
            app = tc.openApp();
            st = app.Store;
            P1 = app.Page;
            tc.assumeGreaterThanOrEqual(P1.Total, 3, 'the fixture has three review pages');
            nLab = nnz(st.get('Label') ~= "");
            app.handleKey('pagedown', {});
            P2 = app.Page;
            tc.verifyEqual(P2.Kind, "active");
            tc.verifyEmpty(intersect(P2.Ids, P1.Ids), 'PgDn shows the next page');
            tc.verifyEqual(P2.Number, P1.Number + 1);
            tc.verifyEqual(P2.Total, P1.Total, 'the queue is as long as before');
            tc.verifyEqual(nnz(st.get('Label') ~= ""), nLab, 'PgDn labels nothing');
            tc.verifySubstring(char(app.StatusText), 'left unconfirmed');
            app.handleKey('pageup', {});
            tc.verifyEqual(app.Page.Kind, "active");
            tc.verifyEqual(sort(app.Page.Ids), sort(P1.Ids), 'PgUp comes back to the page that was left');
            tc.verifyEqual(nnz(st.get('Label') ~= ""), nLab, 'PgUp labels nothing');
            % the buttons do the same
            nextBtn = findall(app.Figure, 'Tag', 'btn:next');
            prevBtn = findall(app.Figure, 'Tag', 'btn:prev');
            tc.assertNumElements(nextBtn, 1);
            tc.verifyEqual(nextBtn.Text, 'Next page [PgDn]');
            tc.verifyEqual(nextBtn.Layout.Row, prevBtn.Layout.Row, 'Previous page and Next page share a row');
            tc.verifyEqual([prevBtn.Layout.Column nextBtn.Layout.Column], [1 2], 'previous on the left, next on the right');
            tc.verifyGreaterThan(strlength(string(nextBtn.Tooltip)), 40);
            app.nextPage();
            tc.verifyEqual(sort(app.Page.Ids), sort(P2.Ids), 'the same second page');
            % Enter confirms the page on screen only; the page left behind still waits
            app.handleKey('return', {});
            tc.verifyTrue(all(st.get('Label', P2.Ids) ~= ""), 'the second page is confirmed');
            tc.verifyTrue(all(st.get('Label', P1.Ids) == ""), 'the first page was not touched');
            P3 = app.Page;
            tc.verifyEqual(P3.Kind, "active");
            tc.verifyEmpty(intersect(P3.Ids, [P1.Ids; P2.Ids]), 'then the page after it');
            app.handleKey('pageup', {});
            tc.verifyEqual(sort(app.Page.Ids), sort(P1.Ids), 'PgUp: the page that still waits');
            app.handleKey('pageup', {});
            tc.verifyEqual(app.Page.Kind, "history", 'before it: the page confirmed in this session');
            tc.verifyEqual(sort(app.Page.Ids), sort(P2.Ids));
            app.handleKey('pagedown', {});
            tc.verifyEqual(sort(app.Page.Ids), sort(P1.Ids), 'and forward again');
            % PgDn stops at the last page and says so
            nLab = nnz(st.get('Label') ~= "");
            for i = 1:P1.Total + 2
                app.handleKey('pagedown', {});
            end
            tc.verifyEqual(app.Page.Kind, "active");
            tc.verifySubstring(char(app.StatusText), 'last page');
            tc.verifyEqual(nnz(st.get('Label') ~= ""), nLab, 'paging to the end labels nothing');
            last = app.Page;
            % confirming the last page brings back what was left behind
            app.handleKey('return', {});
            tc.verifyTrue(all(st.get('Label', last.Ids) ~= ""));
            tc.verifyEqual(app.Page.Kind, "active", 'pages left behind are still to review');
            tc.verifyTrue(all(st.get('Label', app.Page.Ids) == ""));
        end

        function finishingTheQueueOffersTheNextSource(tc)
            app = tc.openApp();
            for k = 1:200
                if app.Page.Kind ~= "active", break; end
                app.handleKey('space', {});
            end
            tc.assertEqual(app.Page.Kind, "empty", 'the review queue runs out');
            c = app.Store.counts();
            tc.verifyEqual(c.toReview, 0);
            % keep both cells of every close pair, so that the source can be completed
            for k = 1:20
                C = curation.Pairs.find(app.Store.kept(), app.Store.Meta.UmPerPixel, ...
                    struct('KeptPairs', app.Store.Meta.KeptPairs));
                if isempty(C), break; end
                app.Store.keepBoth(vertcat(C.Edges));
            end
            app.showQueue('review');
            tc.verifySubstring(char(app.ContextText), 'ECM1 is reviewed');
            tc.verifySubstring(char(app.ContextText), 'Enter: mark it complete');
            app.handleKey('return', {});
            tc.verifyTrue(logical(app.Store.Meta.Complete), 'Enter on the checklist completes the source');
            tc.verifySubstring(char(app.ContextText), 'ECM1 is complete');
            tc.verifySubstring(char(app.ContextText), 'open PV2', 'the next source with work is named');
            app.handleKey('n', {});
            tc.verifyEqual(app.SourceKey, "PV2", 'n opens it');
            tc.verifyEqual(app.Page.Kind, "active");
            tc.verifySubstring(char(app.StatusText), 'Opened PV2');
            % and Ctrl+Left goes back to the finished one (kept in memory)
            app.handleKey('leftarrow', {'control'});
            tc.verifyEqual(app.SourceKey, "ECM1");
            tc.verifyEqual(app.Page.Kind, "empty");
            app.handleKey('return', {});
            tc.verifyEqual(app.SourceKey, "PV2", 'Enter on a completed source opens the next one');
        end

        function reopeningResumesWithNothingLost(tc)
            app = tc.openApp();
            P = app.Page;
            app.galleryClick(1, 'normal');
            app.hoverTile(2);
            app.handleKey('u', {});
            app.handleKey('return', {});
            labels = app.Store.get('Label', P.Ids);
            sources = app.Store.get('LabelSource', P.Ids);
            csv = app.Store.Paths.csv;
            delete(app);
            app2 = tc.openApp();
            tc.verifyEqual(app2.Store.Paths.csv, csv);
            tc.verifyEqual(app2.Store.get('Label', P.Ids), labels, 'every label survives the reopen');
            tc.verifyEqual(app2.Store.get('LabelSource', P.Ids), sources);
            tc.verifyEmpty(intersect(app2.Page.Ids, P.Ids), 'the review resumes after the decided cells');
            % the manifest recorded the session when the app closed
            mf = CellDatasetManifest.forCsv(tc.Truth.paths.ecm1Locs);
            stg = mf.Data.sources.ECM1.stages.curation;
            tc.verifyEqual(char(stg.tool), 'CellCurator');
            tc.verifyEqual(double(stg.reviewed), nnz(labels ~= ""));
        end

        function secondAppIsReadOnly(tc)
            app1 = tc.openApp();
            app2 = tc.openApp();
            tc.verifyTrue(app2.Store.ReadOnly, 'the second window gets a read-only store');
            tc.verifySubstring(lower(char(app2.StatusText)), 'read-only', 'and says so');
            tc.verifySubstring(char(app2.ContextText), 'Read-only');
            P = app2.Page;
            before = app2.Store.get('Label', P.Ids);
            app2.hoverTile(1);
            app2.handleKey('b', {});
            app2.galleryClick(2, 'normal');
            app2.handleKey('return', {});
            tc.verifyEqual(app2.Store.get('Label', P.Ids), before, 'nothing changes');
            tc.verifySubstring(lower(char(app2.StatusText)), 'read-only');
            tc.verifyFalse(logical(findall(app2.Figure, 'Tag', 'btn:good').Enable), 'label buttons are off');
            tc.verifySubstring(findall(app2.Figure, 'Tag', 'btn:good').Tooltip, 'read-only');
            % the first window still works
            app1.hoverTile(1);
            app1.handleKey('b', {});
            tc.verifyEqual(app1.Store.get('Label', app1.Page.Ids(1)), "Bad");
        end

        function displayKeys(tc)
            app = tc.openApp();
            app.handleKey('o', {});
            tc.verifyEqual(app.DisplayMode, "overlay");
            g0 = app.Gain;
            app.handleKey(']', {});
            tc.verifyGreaterThan(app.Gain, g0);
            app.handleKey('leftbracket', {});
            tc.verifyEqual(app.Gain, g0, 'AbsTol', 1e-9);
            gm = app.Gamma;
            app.handleKey('semicolon', {});
            tc.verifyGreaterThan(app.Gamma, gm);
            app.handleKey('quote', {});
            tc.verifyEqual(app.Gamma, gm, 'AbsTol', 1e-9);
            app.handleKey('c', {});
            tc.verifyEqual(app.Gallery.Style.Mode, "companion", 'holding c shows the other channel');
            app.handleKeyRelease('c');
            tc.verifyEqual(app.Gallery.Style.Mode, "overlay");
            % side by side doubles the tile width: the page is cut to what fits
            app.handleKey('o', {});
            app.handleKey('o', {});
            tc.verifyEqual(app.DisplayMode, "side");
            tc.verifyLessThanOrEqual(numel(app.Page.Ids), prod(app.Gallery.Grid));
            app.handleKey('o', {});
            tc.verifyEqual(app.DisplayMode, "target");
            n0 = prod(app.Gallery.Grid);
            app.handleKey('-', {});
            tc.verifyGreaterThanOrEqual(prod(app.Gallery.Grid), n0, 'smaller tiles: at least as many per page');
            app.handleKey('?', {});
            tc.verifyEqual(char(findall(app.Figure, 'Tag', 'pn:cheat').Visible), 'on');
            app.handleKey('escape', {});
            tc.verifyEqual(char(findall(app.Figure, 'Tag', 'pn:cheat').Visible), 'off');
            app.handleKey('s', {'control'});
            tc.verifyFalse(app.Store.Dirty, 'Ctrl+S writes the snapshot');
        end

        function noTimersOrLocksAfterClose(tc)
            app = CellCurator('UseSettings', false, 'PrepareNext', true);
            app.openParent(tc.Folder, '', 'ECM1');
            app.waitForLayout();
            app.galleryClick(1, 'normal');
            app.handleKey('return', {});
            pause(2.6);                    % let the idle timer prepare the next source
            drawnow;
            app.nextSource();              % PV2 (prepared in the background)
            tc.verifyEqual(app.SourceKey, "PV2");
            app.hoverTile(1);
            app.handleKey('g', {});
            locks = dir(fullfile(tc.Folder, '*_curation.lock'));
            tc.verifyNotEmpty(locks, 'open sources hold their locks');
            delete(app);
            drawnow;
            after = timerfindall;
            before = tc.TimersBefore;
            isNew = true(1, numel(after));
            for i = 1:numel(after)
                for j = 1:numel(before)
                    if isequal(after(i), before(j)), isNew(i) = false; end
                end
            end
            extra = after(isNew);
            names = "";
            if ~isempty(extra), names = strjoin(string(get(extra, 'Name')), ', '); end
            tc.verifyEmpty(extra, "timers left behind: " + names);
            tc.verifyEmpty(dir(fullfile(tc.Folder, '*_curation.lock')), 'no lock files left behind');
        end
    end
end

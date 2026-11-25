classdef tCuratorReviewFixes < matlab.unittest.TestCase
    %tCuratorReviewFixes  The defects the independent review of CellCurator reproduced (integration
    %   pass C): each is a way a reviewer's decision could land on a cell they were not looking at, or
    %   a file could say something the store does not. One test per finding, through the window's
    %   seams and its real callbacks (key events through the figure's WindowKeyPressFcn).
    %
    %   Run on the hidden desktop: tools\Run-Tests.ps1 tCuratorReviewFixes

    properties
        Folder
        Truth
        Provenance
        KeyAt string = ""           % aKeyWhileTheLassoClosesLabelsNothing: where g was pressed
        EscDone logical = false
    end

    methods (TestMethodSetup)
        function makeFixture(tc)
            fx = tc.applyFixture(matlab.unittest.fixtures.TemporaryFolderFixture);
            tc.applyFixture(matlab.unittest.fixtures.EnvironmentVariableFixture('CELLDB_NO_CLIENT', '1'));
            tc.Provenance = fullfile(fx.Folder, 'provenance');
            tc.applyFixture(matlab.unittest.fixtures.EnvironmentVariableFixture('CELLDB_PROVENANCE_DIR', tc.Provenance));
            [tc.Folder, tc.Truth] = makeSyntheticDataset(fullfile(fx.Folder, 'ds'), 'Variants', false);
        end
    end

    methods
        function app = openApp(tc, varargin)
            app = CellCurator('UseSettings', false, 'PrepareNext', false, 'Assist', false, ...
                'ConfirmAudit', false, varargin{:});
            tc.addTeardown(@() tCuratorReviewFixes.closeApp(app));
            app.openParent(tc.Folder, '', 'ECM1');
            app.waitForLayout();
            tc.assertEqual(app.Page.Kind, "active", app.StatusText);
        end
    end

    methods (Static)
        function closeApp(app)
            if ~isempty(app) && isvalid(app), delete(app); end
        end

        function idle(s)
            if nargin < 1, s = 0.4; end
            pause(s); drawnow;
        end

        function key(app, k, down)
            %key  A key event through the window's own keyboard callbacks (press, then release).
            if nargin < 3, down = "both"; end
            ch = '';
            switch k
                case 'return', ch = char(13);
                case 'space', ch = ' ';
                otherwise, if numel(k) == 1, ch = k; end
            end
            e = struct('Key', k, 'Character', ch, 'Modifier', {{}});
            f = app.Figure;
            if down ~= "up", f.WindowKeyPressFcn(f, e); end
            if down ~= "down", f.WindowKeyReleaseFcn(f, e); end
        end

        function px = border(app, k)
            r = app.Gallery.Layout.Rect(k, :);
            px = double(squeeze(app.Gallery.Mosaic(r(2) + round(r(4) / 2), r(1), :)))';
        end

        function labelAll(st, label, src)
            ids = st.get('CellID');
            st.setLabel(ids(st.get('State') == "active"), label, src);
        end

        function keyDuringEscape(tc, tm, app)
            %keyDuringEscape  Press g inside the Esc's bar relayout (showBar on the interrupted stack,
            %   where the review found the key let in) or after the Esc; wait until then (a timer can
            %   run between any two statements, where a real key cannot).
            if tc.KeyAt ~= "", return; end
            s = dbstack;
            if any(contains({s.name}, 'showBar'))
                tc.KeyAt = "inside";
            elseif tc.EscDone
                tc.KeyAt = "after";
            else
                return
            end
            stop(tm);
            app.handleKey('g', {});
        end

        function makeCompletable(st)
            %makeCompletable  Every cell Good and every close pair kept: Mark source complete can run.
            tCuratorReviewFixes.labelAll(st, "Good", "human");
            C = curation.Pairs.find(st.kept(), st.Meta.UmPerPixel, struct('KeptPairs', st.Meta.KeptPairs));
            for k = 1:numel(C)
                st.keepBoth(C(k).Edges);
            end
        end
    end

    methods (Test)
        %% 1 a held or double-tapped Enter confirms pages the reviewer has not seen
        function enterHeldOrTooSoonConfirmsNothing(tc)
            app = tc.openApp();
            st = app.Store;
            tCuratorReviewFixes.idle(0.5);
            P1 = app.Page;
            tCuratorReviewFixes.key(app, 'return', "down");          % held: no release
            tc.assertNotEqual(app.Page.PageId, P1.PageId, 'the first press confirms the page');
            P2 = app.Page;
            for i = 1:5                                               % the OS repeats the held key
                tCuratorReviewFixes.key(app, 'return', "down");
            end
            tc.verifyEqual(app.Page.PageId, P2.PageId, 'a held Enter confirms no further page');
            tc.verifyTrue(all(st.get('Label', P2.Ids) == ""), 'page 2 is untouched');
            tc.verifySubstring(char(app.StatusText), 'release it first');
            tCuratorReviewFixes.key(app, 'return', "up");
            tCuratorReviewFixes.idle(0.4);
            P2 = app.Page;
            tCuratorReviewFixes.key(app, 'return');                   % released and seen: confirms
            tc.verifyNotEqual(app.Page.PageId, P2.PageId);
            P3 = app.Page;
            tCuratorReviewFixes.key(app, 'return');                   % a double tap: too soon
            tc.verifyEqual(app.Page.PageId, P3.PageId, 'a page on screen for less than 300 ms is not confirmed');
            tc.verifySubstring(char(app.StatusText), 'less than 300 ms');
            tc.verifyTrue(all(st.get('Label', P3.Ids) == ""));
            % the close pairs: the same guard on the map
            tCuratorReviewFixes.labelAll(st, "Good", "human");
            app.showQueue('closePairs');
            tc.assumeNotEmpty(app.PairList, 'the fixture has close pairs');
            n0 = numel(app.PairList);
            tCuratorReviewFixes.key(app, 'return');
            tc.verifyEqual(numel(app.PairList), n0, 'a pair shown a moment ago is not resolved by Enter');
        end

        %% 2 in Close pairs a label key acted on both cells of the pair
        function closePairLabelKeysActOnOneCell(tc)
            app = tc.openApp();
            st = app.Store;
            tCuratorReviewFixes.labelAll(st, "Good", "human");
            app.showQueue('closePairs');
            tc.assumeNotEmpty(app.PairList, 'the fixture has close pairs');
            c = app.PairList(1);
            xy = [st.get('X', c.Ids) st.get('Y', c.Ids)];
            tc.verifyEmpty(app.MapSelection, 'the pair is marked, not selected');
            tc.verifyEqual(sort(app.Map.Marks), sort(uint32(c.Ids(:))), 'its cells are marked');
            app.mapHover(xy(2, :));
            tCuratorReviewFixes.idle(0.3);
            app.handleKey('b', {});
            tc.verifyEqual(st.get('Label', c.Ids(2)), "Bad", 'the cell under the pointer');
            tc.verifyEqual(st.get('Label', c.Ids(1)), "Good", 'and not the other one');
            % a click on a cell of the pair selects that cell alone
            app.mapClick(xy(1, :));
            tc.verifyEqual(app.MapSelection, uint32(c.Ids(1)));
            app.mapHover([3 3]);
            tCuratorReviewFixes.idle(0.3);
            app.handleKey('u', {});
            tc.verifyEqual(st.get('Label', c.Ids(1)), "Uncertain");
            tc.verifyEqual(st.get('Label', c.Ids(2)), "Bad");
            % Esc clears that selection; nothing then is a target
            app.handleKey('escape', {});
            tc.verifyEmpty(app.MapSelection);
            app.handleKey('g', {});
            tc.verifyEqual(st.get('Label', c.Ids), ["Uncertain"; "Bad"]);
            tc.verifySubstring(char(app.StatusText), 'Point at one cell of the pair');
        end

        %% 3 a note landed on the last tile the pointer crossed while it was typed
        function noteBelongsToTheCellOfItsFocus(tc)
            app = tc.openApp();
            st = app.Store;
            P = app.Page;
            ef = findall(app.Figure, 'Tag', 'ef:note');
            app.hoverTile(1);
            tCuratorReviewFixes.idle(0.2);
            ef.ValueChangingFcn(ef, struct('Value', 'odd'));       % typing starts: tile 1's cell
            app.hoverTile(5);                                       % the pointer crosses tile 5
            app.hoverTile(7);
            f = string(findall(app.Figure, 'Tag', 'lbl:fields').Text);
            tc.verifySubstring(f, sprintf('Cell %d', P.Ids(1)), 'the inspector stays on the cell of the note');
            ef.Value = 'odd shape';
            ef.ValueChangedFcn(ef, struct('Value', 'odd shape'));
            tc.verifyEqual(st.get('Notes', P.Ids(1)), "odd shape", 'the note is on the cell it was typed for');
            tc.verifyEqual(st.get('Notes', P.Ids(7)), "");
            tc.verifyEqual(st.get('Notes', P.Ids(5)), "");
        end

        %% 4 after Enter held a page for an audit tile, g/b/u hit the ordinary tile under the pointer
        function heldPageKeysGoToTheAuditTile(tc)
            app = tc.openApp();
            st = app.Store;
            ids = st.get('CellID');
            free = ids(st.get('State') == "active" & ~st.get('Reviewed'));
            st.setAuditRole(free(end), "holdout");
            app.showQueue('review');
            P = app.Page;
            b = find(P.Blind, 1);
            tc.assertNotEmpty(b, 'the holdout tile is on the first page');
            k = find(~P.Blind, 1);
            app.hoverTile(k);                         % the pointer rests on an ordinary tile
            app.handleKey('return', {});
            tc.assertEqual(app.Page.PageId, P.PageId, 'the page is held for the audit tile');
            tc.verifyEqual(app.Cursor, b);
            app.handleKey('g', {});
            tc.verifyEqual(st.get('LabelSource', P.Ids(b)), "blind", 'the key decides the audit tile');
            tc.verifyEqual(st.get('LabelSource', P.Ids(k)), "confirmed", 'not the ordinary tile under the stale hover');
        end

        %% 5 after a zoom, a display-mode change or a return from the map, keys hit the old tile index
        function keysAfterRelayoutFollowThePointer(tc)
            app = tc.openApp();
            st = app.Store;
            P = app.Page;
            try
                app.Figure.CurrentPoint = [2 2];       % the pointer: off the tiles
            catch
                tc.assumeFail('CurrentPoint cannot be set here');
            end
            for k = ["+" "o" "tab"]
                app.hoverTile(3);
                app.handleKey(k, {});
                if k == "tab", app.handleKey('tab', {}); end         % to the map and back
                app.handleKey('b', {});
                tc.verifyTrue(all(st.get('Label', P.Ids) == ""), "after " + k + ": no tile was labeled");
                tc.verifySubstring(char(app.StatusText), 'Point at a tile', "after " + k);
            end
        end

        %% 6 the confirm audit drew tiles of the page still on screen
        function confirmAuditNeverDrawsFromThePageOnScreen(tc)
            app = tc.openApp('ConfirmAudit', true);
            st = app.Store;
            keep = app.Page.Ids;                          % the last page: its tiles, one of them holdout
            ids = st.get('CellID');
            act = ids(st.get('State') == "active");
            tc.assumeGreaterThan(numel(act), numel(keep) + 10);
            % the other cells decided one by one: the only tiles confirmed by default will be this page's
            st.setLabel(setdiff(act, keep), "Good", "human");
            st.setAuditRole(keep(end), "holdout");
            app.showQueue('review');
            P = app.Page;
            tc.assertEqual(sort(P.Ids), sort(keep), 'the last ordinary page with its audit tile');
            app.handleKey('return', {});
            tc.assertEqual(app.Page.PageId, P.PageId, 'held for the holdout tile');
            drawn = ids(st.get('AuditRole') == "confirm-audit");
            tc.verifyEmpty(intersect(drawn, P.Ids), ...
                'none of the confirm audit from the page on screen (its tiles would turn gray under the reviewer)');
            % the audit tile judged, the page left: the confirm audit is drawn then, from those tiles
            b = find(P.Blind, 1);
            app.hoverTile(b);
            app.handleKey('g', {});
            app.hoverTile(0);
            app.handleKey('return', {});
            tCuratorReviewFixes.idle(0.6);
            drawn = ids(st.get('AuditRole') == "confirm-audit");
            tc.verifyNotEmpty(drawn, 'drawn once the page was left');
            tc.verifyTrue(all(ismember(drawn, P.Ids)), 'from the tiles confirmed by default');
        end

        %% 7 the map's context line showed the earlier label of an audit cell
        function mapContextHidesTheLabelOfAnAuditCell(tc)
            app = tc.openApp();
            st = app.Store;
            ids = st.get('CellID');
            st.setLabel(ids(5), "Good", "confirmed");
            st.setAuditRole(ids(5), "confirm-audit");
            app.showCenter("map");
            app.mapClick([st.get('X', ids(5)) st.get('Y', ids(5))]);
            tc.assertEqual(app.MapSelection, ids(5));
            tc.verifyEmpty(strfind(char(app.ContextText), 'Good'), 'no earlier label');
            tc.verifySubstring(char(app.ContextText), 'audit cell');
        end

        %% 8 a key processed during the lasso bar's relayout relabeled the whole lasso
        function aKeyWhileTheLassoClosesLabelsNothing(tc)
            app = tc.openApp();
            st = app.Store;
            app.showCenter("map");
            x = st.get('X'); y = st.get('Y');
            c = [median(x) median(y)];
            poly = c + 60 * [-1 -1; 1 -1; 1 1; -1 1];
            app.mapLasso(poly);
            tc.assertNotEmpty(app.Lasso, 'a lasso is up');
            inside = app.Lasso.Ids;
            tc.assumeNotEmpty(inside);
            % g arrives while Esc is being handled: a polling timer presses it inside the cancel's bar
            % relayout, or else just after the Esc returned; never before it (g on a live lasso labels
            % the lasso: that is its job; in the full suite a one-shot timer sometimes fired there)
            tc.KeyAt = "";
            tc.EscDone = false;
            t = timer('ExecutionMode', 'fixedSpacing', 'Period', 0.001, 'TasksToExecute', 100000, ...
                'TimerFcn', @(tm, ~) tCuratorReviewFixes.keyDuringEscape(tc, tm, app));
            tc.addTeardown(@() delete(t));
            start(t);
            app.handleKey('escape', {});              % cancels the lasso (the bar goes away)
            tc.EscDone = true;
            tCuratorReviewFixes.idle(0.3);
            tc.assertNotEqual(tc.KeyAt, "", 'the timer pressed g');
            tc.verifyEmpty(app.Lasso);
            tc.verifyTrue(all(st.get('Label', inside) == ""), ...
                sprintf('the key did not reach the lassoed cells (g pressed %s the Esc)', tc.KeyAt));
        end

        %% 9 a _final.csv that could not be written was reported as written, and Complete was set
        function anUnwritableFinalListLeavesTheSourceIncomplete(tc)
            app = tc.openApp();
            st = app.Store;
            tCuratorReviewFixes.makeCompletable(st);
            app.showQueue('review');
            final = st.Paths.final;
            fid = fopen(final, 'w');                   % held open by another program: it cannot be replaced
            tc.assertGreaterThan(fid, 0);
            fwrite(fid, 'old');
            tc.addTeardown(@() fclose(fid));
            app.markComplete();
            tc.verifyFalse(logical(st.Meta.Complete), 'not complete without its final list');
            tc.verifySubstring(char(app.StatusText), 'NOT complete');
            tc.verifyEmpty(strfind(char(app.StatusText), 'kept cells written'));
        end

        %% 10 Complete stayed set and _final.csv went stale after edits of the kept cells
        function editsOfTheKeptCellsClearCompleteAndRetireTheList(tc)
            app = tc.openApp();
            st = app.Store;
            tCuratorReviewFixes.makeCompletable(st);
            app.showQueue('review');
            app.markComplete();
            final = st.Paths.final;
            stale = strrep(final, '_final.csv', '_final.stale.csv');
            tc.assertTrue(logical(st.Meta.Complete) && isfile(final));
            % a kept cell relabeled Bad (Browse Good: a click switches it)
            app.showQueue('browseGood');
            id = app.Page.Ids(1);
            app.galleryClick(1, 'normal');
            tc.assertEqual(st.get('Label', id), "Bad");
            tc.verifyFalse(logical(st.Meta.Complete), 'the kept cells changed: no longer complete');
            tCuratorReviewFixes.idle(0.5);
            tc.verifyFalse(isfile(final), 'the old final list does not look current');
            tc.verifyTrue(isfile(stale), 'it is kept as .stale.csv');
            % undo brings Complete back, and with it the list
            app.handleKey('z', {'control'});
            tc.verifyTrue(logical(st.Meta.Complete));
            tCuratorReviewFixes.idle(0.5);
            tc.verifyTrue(isfile(final), 'written again for the restored kept cells');
            T = readtable(final);
            tc.verifyEqual(height(T), st.counts().kept);
            % undoing the completion retires the list too
            app.handleKey('z', {'control'});
            tc.verifyFalse(logical(st.Meta.Complete));
            tCuratorReviewFixes.idle(0.5);
            tc.verifyFalse(isfile(final));
            % an added cell on a complete source
            app.showQueue('review');
            app.markComplete();
            tc.assertTrue(logical(st.Meta.Complete) && isfile(final));
            app.setMapTool("add", true);
            app.mapClick([20 20]);
            tc.verifyFalse(logical(st.Meta.Complete), 'an added cell changes the kept cells');
        end

        %% 11 after the lock was lost mid-drag, the reverted labels stayed painted on the tiles
        function aLostLockRepaintsThePage(tc)
            app = tc.openApp();
            st = app.Store;
            C = curation.UiText.colors();
            P = app.Page;
            g = app.Gallery;
            g.onButtonDown(struct('AxesPoint', g.tileCenter(1), 'SelectionType', 'normal'));
            g.onMotion(struct('AxesPoint', g.tileCenter(2)));
            tc.assertNotEqual(st.get('Label', P.Ids(1)), "", 'the drag painted tile 1');
            mf = CellDatasetManifest.forCsv(tc.Truth.paths.ecm1Locs);
            st2 = curation.Store.open(mf, 'ECM1', struct('Force', true, 'AutosaveDelay', 0));
            c2 = onCleanup(@() st2.close());
            g.onButtonUp(struct('AxesPoint', g.tileCenter(2)));      % the drag's commit finds the lock gone
            tc.assertTrue(st.ReadOnly, 'the source is read-only now');
            tc.verifyEqual(st.get('Label', P.Ids(1:2)), ["", ""]', 'the store reverted the drag');
            if P.Default == "Bad", want = C.ProposedBad; else, want = C.ProposedGood; end
            tc.verifyEqual(tCuratorReviewFixes.border(app, 1), want, 'tile 1 shows it is untouched again');
            tc.verifyEqual(tCuratorReviewFixes.border(app, 2), want);
            tc.verifyEqual(nnz(app.Page.Untouched), nnz(P.Untouched));
            clear c2
        end

        %% 12 undoing a review-page confirm from a list queue left the window in that list queue
        function undoFromABrowseQueueReturnsToReview(tc)
            app = tc.openApp();
            P = app.Page;
            app.handleKey('return', {});
            if P.Default == "Good", q = 'browseGood'; else, q = 'browseBad'; end
            app.showQueue(q);
            tc.assertEqual(app.QueueName, string(q));
            app.handleKey('z', {'control'});
            tc.verifyEqual(app.Page.PageId, P.PageId, 'the confirmed page is live again');
            tc.verifyEqual(app.Page.Kind, "active");
            tc.verifyEqual(app.QueueName, "review", 'and the window is in the Review queue');
            tc.verifyEqual(findall(app.Figure, 'Tag', 'lb:queues').Value, 'review');
            tc.verifySubstring(char(app.ContextText), 'Enter: mark the');
        end

        %% a  the app's own writes wait for the reviewer's open batch
        function backgroundWritesWaitForTheDrag(tc)
            app = tc.openApp('ConfirmAudit', true);
            st = app.Store;
            tCuratorReviewFixes.labelAll(st, "Good", "confirmed");     % the ordinary queue is empty
            app.showQueue('browseGood');
            g = app.Gallery;
            g.onButtonDown(struct('AxesPoint', g.tileCenter(1), 'SelectionType', 'normal'));   % a drag: a batch
            tCuratorReviewFixes.idle(0.8);
            tc.verifyEqual(nnz(st.get('AuditRole') == "confirm-audit"), 0, 'nothing is drawn inside the drag');
            g.onButtonUp(struct('AxesPoint', g.tileCenter(1)));
            tCuratorReviewFixes.idle(0.8);
            tc.verifyGreaterThan(nnz(st.get('AuditRole') == "confirm-audit"), 0, 'drawn once it ended');
            id = app.Page.Ids(1);
            app.handleKey('z', {'control'});
            tc.verifyEqual(st.get('Label', id), "Good", 'Ctrl+Z undoes the drag, the last own action');
            tc.verifyGreaterThan(nnz(st.get('AuditRole') == "confirm-audit"), 0, 'the audit roles are no undo step');
        end

        %% b  a key ends a drag whose button-up was missed
        function aKeyEndsAMissedDrag(tc)
            app = tc.openApp();
            st = app.Store;
            P = app.Page;
            g = app.Gallery;
            g.onButtonDown(struct('AxesPoint', g.tileCenter(1), 'SelectionType', 'normal'));
            app.handleKey('rightarrow', {'shift'});                    % any key
            g.onMotion(struct('AxesPoint', g.tileCenter(3)));         % plain motion afterward
            tc.verifyEqual(st.get('Label', P.Ids(3)), "", 'the missed drag paints nothing more');
            % a Move drag on the map
            app.setMapTool("move", true);
            m = app.Map;
            id = st.get('CellID', 1);
            xy = [st.get('X', id) st.get('Y', id)];
            app.mapClick(xy);
            m.onButtonDown(struct('AxesPoint', xy, 'SelectionType', 'normal'));
            m.onMotion(struct('AxesPoint', xy + [30 0]));
            app.handleKey('g', {});                                    % the release was missed; the next key
            m.onMotion(struct('AxesPoint', xy + [40 0]));
            m.onButtonUp(struct('AxesPoint', xy + [40 0]));
            tc.verifyEqual([st.get('X', id) st.get('Y', id)], xy, 'the cell did not move');
        end

        %% c  a missed release of c left the other channel showing
        function anotherKeyEndsTheHeldCompanion(tc)
            app = tc.openApp();
            app.handleKey('c', {});
            tc.assertEqual(app.Gallery.Style.Mode, "companion");
            app.handleKey('downarrow', {});                            % c's release was missed
            tc.verifyEqual(app.Gallery.Style.Mode, "target", 'the reviewed channel is back');
        end

        %% f  a rescore did not drop the prefetched next page
        function aRescoreDropsThePrefetchedPage(tc)
            app = tc.openApp();
            st = app.Store;
            tCuratorReviewFixes.idle(0.6);                             % the next page is prefetched
            ids = st.get('CellID');
            st.setRescore(ids, 5 + zeros(numel(ids), 1), "test_scorer");
            app.handleKey('return', {});
            tc.verifyFalse(app.LastTimings.NextPrefetched, 'the page after it is computed with the new scores');
        end
    end
end

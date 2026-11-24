classdef tCuratorFinish < matlab.uitest.TestCase
    %tCuratorFinish  The end of a source in CellCurator: the Close pairs queue (merge, keep both, a
    %   kept pair not proposed again), the missed-cell sweep (fields, resume, SweepDone) and the finish
    %   checklist (blockers, Mark source complete, _final.csv, the manifest, undo, going back to
    %   incomplete after a later edit).
    %
    %   Run on the hidden desktop: tools\Run-Tests.ps1 tCuratorFinish

    properties
        Folder
        Truth
    end

    methods (TestMethodSetup)
        function makeFixture(tc)
            fx = tc.applyFixture(matlab.unittest.fixtures.TemporaryFolderFixture);
            % Mark source complete makes a lab database record: no client, and its sidecar kept here
            tc.applyFixture(matlab.unittest.fixtures.EnvironmentVariableFixture('CELLDB_NO_CLIENT', '1'));
            tc.applyFixture(matlab.unittest.fixtures.EnvironmentVariableFixture('CELLDB_PROVENANCE_DIR', ...
                fullfile(fx.Folder, 'provenance')));
            [tc.Folder, tc.Truth] = makeSyntheticDataset(fullfile(fx.Folder, 'ds'));
        end
    end

    methods
        function app = openApp(tc, key)
            if nargin < 2, key = 'ECM1'; end
            app = CellCurator('UseSettings', false, 'PrepareNext', false, 'Assist', false, 'ConfirmAudit', false);
            tc.addTeardown(@() tCuratorFinish.closeApp(app));
            app.openParent(tc.Folder, '', key);
            app.waitForLayout();
            tc.assertEqual(app.SourceKey, string(key), app.StatusText);
        end
    end

    methods (Static)
        function closeApp(app)
            if ~isempty(app) && isvalid(app)
                delete(app);
            end
        end

        function idle()
            pause(0.4);
            drawnow;
        end

        function labelAllGood(st)
            ids = st.get('CellID');
            st.setLabel(ids(st.get('State') == "active"), "Good", "human");
        end

        function C = pairsOf(st)
            C = curation.Pairs.find(st.kept(), st.Meta.UmPerPixel, struct('KeptPairs', st.Meta.KeptPairs));
        end

        function h = byTag(app, tag)
            h = findall(app.Figure, 'Tag', tag);
            h = h(1);
        end
    end

    % ------------------------------------------------------------------------------------------------
    methods (Test)
        %% 6 close pairs
        function closePairsMergeAndKeepBoth(tc)
            app = tc.openApp();
            st = app.Store;
            tCuratorFinish.labelAllGood(st);
            app.showQueue('closePairs');
            tc.assertEqual(app.CentreView, "map", app.StatusText);
            tc.assertEqual(app.MapTask, "pairs");
            n0 = numel(app.PairList);
            tc.assumeGreaterThanOrEqual(n0, 3, 'the fixture has duplicate detections');
            tc.verifyEqual(n0, numel(tCuratorFinish.pairsOf(st)), 'the queue holds the clusters of the kept cells');
            tCuratorFinish.idle();
            lb = tCuratorFinish.byTag(app, 'lb:queues');
            tc.verifyTrue(any(contains(string(lb.Items), sprintf('Close pairs  (%d)', n0))), 'the count is in the queue list');
            c = app.PairList(1);
            tc.verifyEqual(sort(app.Map.Marks), sort(uint32(c.Ids(:))), 'its cells are ringed (marked)');
            tc.verifyEmpty(app.MapSelection, 'not selected: a key acts on the cell under the pointer (pass C)');
            r = app.Map.viewRect();
            tc.verifyLessThanOrEqual(min(r(2) - r(1), r(4) - r(3)) * st.Meta.UmPerPixel, 70, 'zoomed to about 60 um');
            tc.verifyTrue(c.Centroid(1) > r(1) && c.Centroid(1) < r(2), 'centred on the pair');
            tc.verifyEqual(char(tCuratorFinish.byTag(app, 'pn:pairBar').Visible), 'on');
            tc.verifySubstring(char(app.ContextText), char(c.Title));
            tc.verifySubstring(char(app.ContextText), sprintf('pair 1 of %d', n0));

            % the proposal first: Enter does it; the context line says so
            km = find([app.PairList.Proposal] == "merge", 1);
            tc.assumeNotEmpty(km, 'a pair closer than half a cell');
            for i = 2:km, app.handleKey('rightarrow', {}); end
            tc.assertEqual(app.PairIndex, km);
            c = app.PairList(km);
            accept = tCuratorFinish.byTag(app, 'btn:pairAccept');
            tc.verifyEqual(accept.Text, curation.UiText.label('pairAcceptMerge'), 'the proposal is the first button');
            tc.verifySubstring(char(app.ContextText), sprintf('Enter: merge, keep cell %d', c.KeeperId));
            app.handleKey('return', {});
            loser = setdiff(c.Ids, c.KeeperId);
            tc.verifyEqual(st.get('State', loser), repmat("merged", numel(loser), 1));
            tc.verifyEqual(st.get('MergedInto', loser), repmat(c.KeeperId, numel(loser), 1));
            tc.verifyEqual(numel(app.PairList), n0 - 1, 'the pair is resolved');
            tc.verifyEqual(app.Map.rowsOf(loser), zeros(numel(loser), 1), 'the merged cell leaves the map');
            app.handleKey('z', {'control'});
            tc.verifyEqual(numel(app.PairList), n0, 'undo brings the pair back');
            tc.verifyEqual(sort(app.PairList(app.PairIndex).Ids), sort(c.Ids), 'and shows it');
            app.handleKey('y', {'control'});
            tc.verifyEqual(numel(app.PairList), n0 - 1);

            % keep both with k; such a pair is never proposed again, also after reopening
            c = app.PairList(app.PairIndex);
            app.handleKey('k', {});
            K = st.Meta.KeptPairs;
            tc.verifyTrue(all(ismember(sort(c.Edges, 2), K, 'rows')), 'the pair is recorded as two cells');
            tc.verifyFalse(any(arrayfun(@(q) isequal(sort(q.Ids), sort(c.Ids)), app.PairList)), 'not proposed again');
            tc.verifyEqual(numel(app.PairList), n0 - 2);
            % skip and back
            if numel(app.PairList) >= 2
                k0 = app.PairIndex;
                app.handleKey('rightarrow', {});
                tc.verifyNotEqual(app.PairIndex, k0);
                app.handleKey('leftarrow', {});
                tc.verifyEqual(app.PairIndex, k0);
            end
            delete(app);
            app2 = tc.openApp();
            app2.showQueue('closePairs');
            tc.verifyFalse(any(arrayfun(@(q) isequal(sort(q.Ids), sort(c.Ids)), app2.PairList)), ...
                'a kept pair stays kept after reopening');
            tc.verifyEqual(numel(app2.PairList), n0 - 2);
        end

        %% 7 the missed-cell sweep
        function sweepMarksDoneAndResumes(tc)
            app = tc.openApp();
            st = app.Store;
            app.showQueue('sweep');
            tc.assertEqual(app.MapTask, "sweep", app.StatusText);
            tc.verifyEqual(app.MapTool, "add", 'the Add tool is active');
            n = size(app.Map.SweepRects, 1);
            tc.assumeGreaterThanOrEqual(n, 4);
            tc.verifyEqual(app.Map.SweepIndex, 1);
            tc.verifySubstring(char(app.ContextText), sprintf('Sweep field 1 of %d', n));
            tc.verifySubstring(char(tCuratorFinish.byTag(app, 'lbl:sweepBar').Text), sprintf('Field 1 of %d', n));
            app.handleKey('space', {});
            tc.verifyEqual(app.Map.SweepIndex, 2, 'Space: next field');
            app.handleKey('return', {});
            tc.verifyEqual(app.Map.SweepIndex, 3, 'Enter: next field');
            app.handleKey('backspace', {});
            tc.verifyEqual(app.Map.SweepIndex, 2, 'Backspace: previous field');
            app.handleKey('leftarrow', {});
            app.handleKey('leftarrow', {});
            tc.verifyEqual(app.Map.SweepIndex, 1, 'not before the first');
            tc.verifySubstring(char(app.StatusText), 'first field');
            app.handleKey('rightarrow', {});
            tc.verifyEqual(app.Map.SweepIndex, 2);
            % a missed cell added in the field on screen
            r = app.Map.SweepRects(2, :);
            m = app.Map;
            p = [];
            for y = r(3) + 20:8:r(4) - 20
                for x = r(1) + 20:8:r(2) - 20
                    if min(hypot(m.XY(:, 1) - x, m.XY(:, 2) - y)) > 25, p = [x y]; break; end
                end
                if ~isempty(p), break; end
            end
            tc.assertNotEmpty(p);
            n0 = st.NumRows;
            app.mapClick(p);
            tc.verifyEqual(st.NumRows, n0 + 1, 'a click in the sweep adds a cell');
            tc.verifyEqual(app.Map.SweepIndex, 2, 'and stays on the field');
            % leave and resume
            app.handleKey('tab', {});
            tc.verifyEqual(app.CentreView, "gallery");
            tc.verifyEqual(app.QueueName, "review", 'leaving the sweep returns to the review');
            tc.verifyEqual(app.Session.SweepField, 2, 'the field reached is remembered');
            tCuratorFinish.idle();
            lb = tCuratorFinish.byTag(app, 'lb:queues');
            tc.verifyTrue(any(contains(string(lb.Items), 'Sweep for missed cells  (at field 2)')));
            app.showQueue('sweep');
            tc.verifyEqual(app.Map.SweepIndex, 2, 'the sweep resumes there');
            tc.verifySubstring(char(app.StatusText), 'resumed at field 2');
            % the field width is a setting
            app.setSweepWidth(300);
            tc.verifyGreaterThan(size(app.Map.SweepRects, 1), n, 'narrower fields: more of them');
            tc.verifyEqual(tCuratorFinish.byTag(app, 'ef:sweepWidth').Value, 300);
            app.setSweepWidth(600);
            n = size(app.Map.SweepRects, 1);
            % to the end
            tc.verifyFalse(logical(st.Meta.SweepDone));
            for k = 1:n + 2
                if app.MapTask ~= "sweep", break; end
                app.handleKey('space', {});
            end
            tc.verifyTrue(logical(st.Meta.SweepDone), 'after the last field the sweep is done');
            tc.verifyEqual(app.CentreView, "gallery");
            tc.verifySubstring(char(app.StatusText), 'Sweep done');
            tc.verifyEqual(app.Session.SweepField, 0, 'a new sweep starts at the first field');
            app.handleKey('z', {'control'});
            tc.verifyFalse(logical(st.Meta.SweepDone), 'undoable');
        end

        %% 8 finishing a source
        function finishChecklistCompleteAndRevert(tc)
            app = tc.openApp();
            st = app.Store;
            CK = curation.UiText.CHECK;
            % Good cells, then an exclusion region over them (they must not reach the final list)
            app.handleKey('tab', {});
            sq = [120 120; 300 120; 300 260; 120 260];
            app.mapLasso(sq);
            app.handleKey('g', {});
            app.mapLasso(sq);
            app.lassoAction('exclude');
            tc.assumeGreaterThan(nnz(st.get('Excluded') & st.get('Label') == "Good"), 0);
            app.handleKey('tab', {});
            % review everything
            for k = 1:300
                if app.Page.Kind ~= "active", break; end
                app.handleKey('space', {});
            end
            tc.assertEqual(app.Page.Kind, "empty");
            fin = tCuratorFinish.byTag(app, 'pn:finish');
            tc.verifyEqual(char(fin.Visible), 'on', 'the checklist replaces the bare message');
            tc.verifySubstring(char(tCuratorFinish.byTag(app, 'lbl:finUnreviewed').Text), ['0 ' CK]);
            nPairs = numel(tCuratorFinish.pairsOf(st));
            tc.assumeGreaterThan(nPairs, 0, 'the fixture''s duplicates make close pairs');
            done = tCuratorFinish.byTag(app, 'btn:finishComplete');
            tc.verifySubstring(done.Text, 'first:', 'pairs still open: the button says what comes first');
            tc.verifySubstring(done.Text, 'close pair');
            tc.press(done);
            tc.verifyFalse(logical(st.Meta.Complete), 'pairs still open: a press does not complete');
            tc.verifySubstring(char(app.StatusText), 'Not complete yet');
            tc.verifySubstring(done.Tooltip, 'still open');
            tc.verifySubstring(done.Tooltip, 'close pair');
            pb = tCuratorFinish.byTag(app, 'btn:finishPairs');
            tc.verifySubstring(pb.Text, sprintf('Close pairs: %d', nPairs));
            tc.verifyTrue(logical(pb.Enable));
            sw = tCuratorFinish.byTag(app, 'btn:finishSweep');
            tc.verifySubstring(sw.Text, 'not done');
            tc.verifySubstring(sw.Text, 'only needed if this section will be used to train the detector');
            tc.verifySubstring(char(app.ContextText), 'still open');
            % a flagged cell blocks too; the checklist's button opens the queue
            app.showQueue('browseGood');
            app.hoverTile(1);
            app.handleKey('f', {});
            flaggedId = app.Page.Ids(1);
            app.showQueue('review');
            fb = tCuratorFinish.byTag(app, 'btn:finishFlagged');
            tc.verifySubstring(fb.Text, 'Flagged for later: 1');
            tc.press(fb);
            tc.verifyEqual(app.QueueName, "flagged", 'the checklist line opens the queue');
            app.hoverTile(find(app.Page.Ids == flaggedId, 1));
            app.handleKey('f', {});
            % resolve the pairs: merge the first, keep the others
            pb = tCuratorFinish.byTag(app, 'btn:finishPairs');
            app.showQueue('review');
            tc.press(pb);
            tc.verifyEqual(app.MapTask, "pairs");
            app.handleKey('j', {});
            for k = 1:20
                if isempty(app.PairList), break; end
                app.handleKey('k', {});
            end
            tc.verifyEmpty(app.PairList);
            app.handleKey('tab', {});
            tc.verifyEqual(app.Page.Kind, "empty");
            tc.verifyTrue(logical(done.Enable), 'nothing open: Mark source complete is on');
            tc.verifyEqual(done.Text, curation.UiText.label('finishComplete'));
            tc.verifySubstring(char(app.ContextText), 'Enter: mark it complete');
            app.handleKey('return', {});
            tc.verifyTrue(logical(st.Meta.Complete), 'Enter completes the source');
            tc.verifySubstring(char(app.StatusText), 'is complete');
            tc.verifySubstring(char(app.ContextText), 'ECM1 is complete');
            % the final list: kept cells only (no Bad, merged or excluded rows)
            tc.assertTrue(isfile(st.Paths.final));
            F = readtable(st.Paths.final, 'TextType', 'string');
            tc.verifyEqual(string(F.Properties.VariableNames), ...
                ["X" "Y" "class" "score" "imgName" "thr" "rescore" "CellID"]);
            ids = st.get('CellID');
            kept = ids(st.keptMask());
            tc.verifyEqual(sort(uint32(F.CellID)), sort(kept));
            tc.verifyTrue(all(st.get('Label', uint32(F.CellID)) == "Good"));
            tc.verifyTrue(all(st.get('State', uint32(F.CellID)) == "active"));
            tc.verifyFalse(any(st.get('Excluded', uint32(F.CellID))));
            tc.verifyGreaterThan(nnz(st.get('Label') == "Bad"), 0, 'there were Bad rows to leave out');
            tc.verifyGreaterThan(nnz(st.get('State') == "merged"), 0, 'and merged rows');
            tc.verifyGreaterThan(nnz(st.get('Excluded') & st.get('Label') == "Good"), 0, 'and excluded Good rows');
            % the manifest, the sections list and the source button
            mf = CellDatasetManifest.forCsv(tc.Truth.paths.ecm1Locs);
            tc.verifyTrue(logical(mf.Data.sources.ECM1.stages.curation.complete), 'recorded in the manifest');
            tCuratorFinish.idle();
            sec = tCuratorFinish.byTag(app, 'lb:sections');
            tc.verifySubstring(char(sec.Items{1}), [CK ' ECM1'], 'the sections list shows it');
            tc.verifySubstring(tCuratorFinish.byTag(app, 'src:ECM1').Text, CK);
            tc.verifySubstring(done.Text, 'Completed', 'complete: readable, in the done colour');
            % undoable
            app.handleKey('z', {'control'});
            tc.verifyFalse(logical(st.Meta.Complete), 'Ctrl+Z undoes the completion');
            app.handleKey('y', {'control'});
            tc.verifyTrue(logical(st.Meta.Complete));
            % a later edit that leaves a cell to review: back to incomplete, in the same undo step
            app.showQueue('browseGood');
            id = app.Page.Ids(1);
            app.hoverTile(1);
            app.handleKey('x', {});
            tc.verifyEqual(st.get('Label', id), "");
            tc.verifyFalse(logical(st.Meta.Complete), 'no longer complete');
            tCuratorFinish.idle();
            tc.verifySubstring(char(app.StatusText), 'ECM1 is no longer complete');
            app.handleKey('z', {'control'});
            tc.verifyEqual(st.get('Label', id), "Good");
            tc.verifyTrue(logical(st.Meta.Complete), 'one undo restores both');
        end
    end
end

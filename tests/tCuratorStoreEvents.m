classdef tCuratorStoreEvents < matlab.unittest.TestCase
    %tCuratorStoreEvents  CellCurator facing what the curation store reports: exclusions kept by the
    %   store itself, an undo refused for a region conflict, another session taking the source over,
    %   read-only opens and opens that fail, a save whose shared JSON cannot be written, and a
    %   reconcile at open (described in the status bar; its near-kept detections queued as close
    %   pairs). Nothing may throw out of a key press, and nothing may open a dialog.
    %
    %   Run on the hidden desktop: tools\Run-Tests.ps1 tCuratorStoreEvents

    properties
        Folder
        Truth
    end

    methods (TestMethodSetup)
        function makeFixture(tc)
            fx = tc.applyFixture(matlab.unittest.fixtures.TemporaryFolderFixture);
            [tc.Folder, tc.Truth] = makeSyntheticDataset(fullfile(fx.Folder, 'ds'));
        end
    end

    methods
        function app = openApp(tc, key)
            if nargin < 2, key = 'ECM1'; end
            app = CellCurator('UseSettings', false, 'PrepareNext', false, 'Assist', false, 'ConfirmAudit', false);
            tc.addTeardown(@() tCuratorStoreEvents.closeApp(app));
            app.openParent(tc.Folder, '', key);
            app.waitForLayout();
        end
    end

    methods (Static)
        function closeApp(app)
            if ~isempty(app) && isvalid(app)
                delete(app);
            end
        end

        function closeStore(st)
            if ~isempty(st) && isvalid(st)
                try st.close(); catch, end
                delete(st);
            end
        end

        function idle()
            pause(0.4);
            drawnow;
        end
    end

    methods (Test)
        %% 1 exclusions follow the regions inside the store; an undo refused for a region conflict
        function regionsAreTheStoresAndConflictsAreReported(tc)
            app = tc.openApp();
            st = app.Store;
            tc.assertEqual(app.SourceKey, "ECM1", app.StatusText);
            app.handleKey('tab', {});
            sq = [150 150; 330 150; 330 300; 150 300];
            app.mapLasso(sq);
            n = numel(app.Lasso.Ids);
            tc.assumeGreaterThan(n, 0);
            app.lassoAction('exclude');
            R = st.regions();
            tc.assertNumElements(R, 1);
            xy = [st.get('X'), st.get('Y')];
            act = st.get('State') == "active";
            want = act & curation.Regions.excluded(R, xy, "ECM1");
            tc.verifyEqual(st.get('Excluded') & act, want, 'the store excluded the cells inside');
            tc.verifySubstring(char(app.StatusText), sprintf('%d cells left out', nnz(want)));
            % a cell added inside the region is excluded by the store
            app.setMapTool('add');
            m = app.Map;
            p = [];
            for y = 165:6:285
                for x = 165:6:315
                    if min(hypot(m.XY(:, 1) - x, m.XY(:, 2) - y)) > 20, p = [x y]; break; end
                end
                if ~isempty(p), break; end
            end
            tc.assertNotEmpty(p);
            app.mapClick(p);
            ids = st.get('CellID');
            tc.verifyTrue(st.get('Excluded', ids(end)), 'an added cell inside the region is excluded');
            app.handleKey('z', {'control'});            % the add
            app.handleKey('z', {'control'});            % the region
            tc.verifyEmpty(st.regions());
            tc.verifyFalse(any(st.get('Excluded')), 'undo includes the cells again');
            % another session now gives that region id to a different region
            mf = CellDatasetManifest.forCsv(tc.Truth.paths.pv2Locs);
            st2 = curation.Store.open(mf, 'PV2', struct('AutosaveDelay', 0));
            c2 = onCleanup(@() tCuratorStoreEvents.closeStore(st2));
            st2.addRegion(struct('kind', "exclude", 'xy', [500 400; 560 400; 560 460; 500 460], 'id', R.id));
            tCuratorStoreEvents.closeStore(st2);
            handled = app.handleKey('y', {'control'});  % the redo would re-add region R.id
            tc.verifyTrue(handled, 'the key is handled, nothing is thrown');
            tc.verifySubstring(char(app.StatusText), 'Nothing changed');
            tc.verifyTrue(logical(st.CanRedo), 'the refused step is kept');
        end

        %% 2 another session takes the source over
        function lockLostTurnsTheWindowReadOnly(tc)
            app = tc.openApp();
            st = app.Store;
            P = app.Page;
            app.hoverTile(1);
            app.handleKey('b', {});
            tc.assertEqual(st.get('Label', P.Ids(1)), "Bad");
            mf = CellDatasetManifest.forCsv(tc.Truth.paths.ecm1Locs);
            st2 = curation.Store.open(mf, 'ECM1', struct('Force', true, 'AutosaveDelay', 0));
            c2 = onCleanup(@() tCuratorStoreEvents.closeStore(st2));
            tc.assertFalse(st2.ReadOnly, 'the second session took the lock');
            app.hoverTile(2);
            handled = app.handleKey('g', {});
            tc.verifyTrue(handled);
            tc.verifyEqual(st.get('Label', P.Ids(2)), "", 'the change was not saved');
            tc.verifyTrue(st.ReadOnly);
            tc.verifyTrue(st.LockInfo.Lost);
            tc.verifySubstring(char(app.StatusText), 'took this source over');
            good = findall(app.Figure, 'Tag', 'btn:good');
            tc.verifyFalse(logical(good.Enable), 'editing controls are off');
            tc.verifySubstring(good.Tooltip, 'took this source over', 'and say why');
            tc.verifyFalse(logical(findall(app.Figure, 'Tag', 'btn:undo').Enable));
            tc.verifyFalse(logical(findall(app.Figure, 'Tag', 'btn:toolAdd').Enable));
            tc.verifySubstring(char(app.ContextText), 'Read-only');
            % every later action is refused quietly
            before = st.get('Label');
            tc.verifyTrue(app.handleKey('return', {}));
            app.galleryClick(3, 'normal');
            tc.verifyTrue(app.handleKey('z', {'control'}));
            tc.verifyTrue(app.handleKey('s', {'control'}));
            app.handleKey('tab', {});
            app.mapClick(app.Map.XY(1, :));
            tc.verifyTrue(app.handleKey('u', {}));
            tc.verifyEqual(st.get('Label'), before, 'nothing changes after the takeover');
            tc.verifySubstring(lower(char(app.StatusText)), 'read-only');
        end

        %% 3 read-only opens say why; an open that fails leaves the previous source on screen
        function readOnlyOpenSaysWhy(tc)
            app = tc.openApp();
            json = app.Store.Paths.json;
            delete(app);
            fid = fopen(json, 'w');
            fwrite(fid, '{"schema": "cellcuration/1.0", "regions": [');   % not JSON any more
            fclose(fid);
            app2 = tc.openApp();
            tc.assertEqual(app2.SourceKey, "ECM1");
            tc.verifyTrue(app2.Store.ReadOnly, 'an unreadable JSON opens the source read-only');
            tc.verifySubstring(lower(char(app2.StatusText)), 'read-only');
            [~, nm, ex] = fileparts(json);
            tc.verifySubstring(char(app2.StatusText), [nm ex], 'the status bar names the reason');
            good = findall(app2.Figure, 'Tag', 'btn:good');
            tc.verifyFalse(logical(good.Enable));
            tc.verifySubstring(good.Tooltip, 'opened read-only');
        end

        function openFailureKeepsThePreviousSource(tc)
            app = tc.openApp('PV2');
            tc.assertEqual(app.SourceKey, "PV2", app.StatusText);
            csv = app.Store.Paths.csv;
            app.hoverTile(1);
            app.handleKey('b', {});
            delete(app);
            delete(csv);                                   % the snapshot of PV2 is gone ...
            L = readtable(tc.Truth.paths.pv2Locs, 'TextType', 'string');
            L(end + 1, :) = L(1, :);                       % ... and its locs file changed since
            L.X(end) = L.X(end) + 40;
            writetable(L, tc.Truth.paths.pv2Locs);
            app2 = tc.openApp('ECM1');
            tc.assertEqual(app2.SourceKey, "ECM1");
            P = app2.Page;
            handled = app2.handleKey('rightarrow', {'control'});
            tc.verifyTrue(handled);
            tc.verifyEqual(app2.SourceKey, "ECM1", 'the previous source stays on screen');
            tc.verifyEqual(app2.Page.PageId, P.PageId);
            tc.verifySubstring(char(app2.StatusText), 'Could not open PV2');
            tc.verifySubstring(char(app2.StatusText), 'snapshot', 'with the store''s explanation');
            app2.hoverTile(1);
            app2.handleKey('g', {});
            tc.verifyEqual(app2.Store.get('Label', P.Ids(1)), "Good", 'and it still works');
        end

        %% 4 a save whose shared JSON cannot be written
        function saveWithUnreadableJsonIsReported(tc)
            app = tc.openApp();
            st = app.Store;
            P = app.Page;
            app.hoverTile(1);
            app.handleKey('b', {});
            fid = fopen(st.Paths.json, 'w');
            fwrite(fid, '{"broken": ');
            fclose(fid);
            tc.verifyTrue(app.handleKey('s', {'control'}), 'Ctrl+S does not throw');
            tc.verifySubstring(char(app.StatusText), 'shared regions file was not');
            T = readtable(st.Paths.csv, 'TextType', 'string', 'Delimiter', ',');
            tc.verifyEqual(T.Label(T.CellID == P.Ids(1)), "Bad", 'the cells were saved');
            % going on works; leaving the source reports the same instead of failing
            app.hoverTile(2);
            app.handleKey('g', {});
            tc.verifyEqual(st.get('Label', P.Ids(2)), "Good");
            tc.verifyTrue(app.handleKey('rightarrow', {'control'}));
            tc.verifyEqual(app.SourceKey, "PV2");
        end

        %% 5 a reconcile at open: described; its near-kept detections are close pairs
        function reconcileIsDescribedAndNearKeptQueued(tc)
            app = tc.openApp();
            st = app.Store;
            P = app.Page;
            app.hoverTile(1);
            app.handleKey('g', {});
            app.hoverTile(2);
            app.handleKey('g', {});
            idA = P.Ids(1);
            idB = P.Ids(2);
            detA = [st.get('DET_X', idA), st.get('DET_Y', idA)];
            detB = [st.get('DET_X', idB), st.get('DET_Y', idB)];
            delete(app);
            % the re-detection: B's detection is gone; a new one lies 3.6 px (6 um) from A's
            L = readtable(tc.Truth.paths.ecm1Locs, 'TextType', 'string');
            rB = find(abs(L.X - detB(1)) < 0.01 & abs(L.Y - detB(2)) < 0.01, 1);
            rA = find(abs(L.X - detA(1)) < 0.01 & abs(L.Y - detA(2)) < 0.01, 1);
            tc.assertNotEmpty(rA);
            tc.assertNotEmpty(rB);
            L(end + 1, :) = L(rA, :);
            L.X(end) = L.X(end) + 3;
            L.Y(end) = L.Y(end) + 2;
            L(rB, :) = [];
            writetable(L, tc.Truth.paths.ecm1Locs);
            app2 = tc.openApp();
            st2 = app2.Store;
            rep = st2.LastReconcile;
            tc.assertTrue(rep.Ran, 'the locs changed: a reconcile ran');
            s = char(app2.StatusText);
            tc.verifySubstring(s, 'Detections changed since last time');
            tc.verifySubstring(s, '1 new');
            tc.verifySubstring(s, '1 kept cell no longer detected');
            tc.verifySubstring(s, 'right next to reviewed cells');
            tc.verifyFalse(contains(s, 'nearKeptIds'), 'no technical note');
            tc.assertEqual(size(rep.nearKeptIds, 1), 1);
            idNew = rep.nearKeptIds(1, 1);
            tc.verifyEqual(rep.nearKeptIds(1, 2), idA);
            app2.showQueue('closePairs');
            tc.assertNotEmpty(app2.PairList);
            c = app2.PairList(1);
            tc.verifyEqual(c.Kind, "nearKept");
            tc.verifyEqual(sort(c.Ids), sort([idA; idNew]));
            tc.verifyEqual(c.KeeperId, idA, 'the reviewed cell is kept');
            tc.verifySubstring(char(app2.ContextText), sprintf('merge the new detection into reviewed cell %d', idA));
            tc.verifyEqual(findall(app2.Figure, 'Tag', 'btn:pairAccept').Text, ...
                curation.UiText.label('pairAcceptMergeReviewed'));
            n = numel(app2.PairList);
            app2.handleKey('return', {});
            tc.verifyEqual(st2.get('State', idNew), "merged");
            tc.verifyEqual(st2.get('MergedInto', idNew), idA);
            tc.verifyEqual(st2.get('Label', idA), "Good", 'the reviewed cell keeps its label');
            tc.verifyEqual(numel(app2.PairList), n - 1, 'resolved');
            app2.handleKey('z', {'control'});
            tc.verifyEqual(numel(app2.PairList), n, 'undo brings the pair back');
        end
    end
end

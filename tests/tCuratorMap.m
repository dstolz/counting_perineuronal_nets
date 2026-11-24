classdef tCuratorMap < matlab.unittest.TestCase
    %tCuratorMap  CellCurator's section map driven through its seams (handleKey, mapClick, mapDrag,
    %   mapLasso, showRightTab, clickLocator) on the synthetic fixture; every edit is checked in the
    %   curation store, the crop cache, the map and the gallery.
    %
    %   Run on the hidden desktop: tools\Run-Tests.ps1 tCuratorMap

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
            tc.addTeardown(@() tCuratorMap.closeApp(app));
            app.openParent(tc.Folder, '', key);
            app.waitForLayout();
            tc.assertEqual(app.SourceKey, string(key), app.StatusText);
            tc.assertEqual(app.Page.Kind, "active", app.ContextText);
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

        function rgb = colourOf(app, id)
            m = app.Map;
            r = m.rowsOf(id);
            rgb = double(m.RGB(r, :));
        end

        function [id, xy] = lonePoint(app, minDistPx, exclude)
            %lonePoint  A map point with no other point within MINDISTPX (not in EXCLUDE).
            if nargin < 3, exclude = zeros(0, 1, 'uint32'); end
            m = app.Map;
            XY = m.XY;
            for k = 1:m.N
                if any(m.Ids(k) == exclude), continue; end
                d = hypot(XY(:, 1) - XY(k, 1), XY(:, 2) - XY(k, 2));
                d(k) = Inf;
                if min(d) > minDistPx
                    id = m.Ids(k);
                    xy = XY(k, :);
                    return
                end
            end
            error('no lone point');
        end

        function xy = emptySpot(app, minDistPx)
            %emptySpot  An image point at least MINDISTPX from every point, away from the edges.
            m = app.Map;
            sz = m.ImageSize;
            for y = 60:15:sz(1) - 60
                for x = 60:15:sz(2) - 60
                    if min(hypot(m.XY(:, 1) - x, m.XY(:, 2) - y)) > minDistPx
                        xy = [x y];
                        return
                    end
                end
            end
            error('no empty spot');
        end
    end

    % ------------------------------------------------------------------------------------------------
    methods (Test)
        %% 1 the map as a full-size view, the locator
        function mapViewFollowsTheStore(tc)
            app = tc.openApp();
            st = app.Store;
            C = curation.UiText.colors();
            tc.verifyEqual(app.CentreView, "gallery");
            tc.verifyEqual(app.Counters.MapLoads, 0, 'the map is loaded on first use');
            app.handleKey('tab', {});
            tc.verifyEqual(app.Counters.MapLoads, 1);
            tc.assertEqual(app.CentreView, "map", app.StatusText);
            m = app.Map;
            tc.assertNotEmpty(m);
            ids = st.get('CellID');
            act = st.get('State') == "active";
            tc.verifyEqual(sort(m.Ids), sort(ids(act)), 'every active cell is a point');
            tc.verifyFalse(any(ismember(ids(~act), m.Ids)), 'merged and stale rows are not drawn');
            % a merge (made outside the window) takes the loser off the map; its undo brings it back
            two = ids(act);
            two = two(end - 1:end);
            st.mergeCells(two, two(1));
            tc.verifyEqual(m.rowsOf(two(2)), 0, 'a merged row leaves the map');
            st.undo();
            tc.verifyGreaterThan(m.rowsOf(two(2)), 0, 'and comes back with the undo');
            lab = st.get('Label');
            k = find(act & lab == "" & ~st.get('Excluded') & st.get('Flag') == "", 1);
            tc.verifyEqual(tCuratorMap.colourOf(app, ids(k)), C.Unreviewed, 'not reviewed: the to-review colour');
            k = find(act & lab == "Bad" & st.get('LabelSource') ~= "auto" & ~st.get('Excluded'), 1);
            if ~isempty(k)
                tc.verifyEqual(tCuratorMap.colourOf(app, ids(k)), C.Bad);
            end
            tc.verifySubstring(char(app.ContextText), 'Map of ECM1');
            loads = app.Counters.MapLoads;

            % an edit in the gallery while the map is hidden reaches it when it shows again
            app.handleKey('tab', {});
            tc.assertEqual(app.CentreView, "gallery");
            P = app.Page;
            app.hoverTile(1);
            app.handleKey('b', {});
            tc.verifyEqual(st.get('Label', P.Ids(1)), "Bad");
            tc.verifyEqual(tCuratorMap.colourOf(app, P.Ids(1)), C.Unreviewed, 'the hidden map is not touched on the key path');
            app.handleKey('v', {});
            tc.assertEqual(app.CentreView, "map");
            tc.verifyEqual(tCuratorMap.colourOf(app, P.Ids(1)), C.Bad, 'shown again: the changed point is recoloured');
            tc.verifyEqual(app.Counters.MapLoads, loads, 'loaded once per source; then only the changed points');

            % with the map showing every change arrives at once: excluded dimmed, flagged distinct
            id2 = P.Ids(2);
            p2 = [st.get('X', id2), st.get('Y', id2)];
            rid = st.addRegion(curation.Regions.make("exclude", p2 + [-3 -3; 3 -3; 3 3; -3 3]));
            tc.assertTrue(st.get('Excluded', id2), 'the store excludes a cell inside a region');
            d = C.DimFactor;
            tc.verifyEqual(tCuratorMap.colourOf(app, id2), round(d * C.Unreviewed + (1 - d) * C.Background), ...
                'an excluded cell is dimmed');
            st.removeRegion(rid);
            tc.verifyEqual(tCuratorMap.colourOf(app, id2), C.Unreviewed, 'and bright again');
            st.setFlag(id2, "later");
            tc.verifyEqual(tCuratorMap.colourOf(app, id2), C.Flag, 'a flagged cell wears the flag colour');
            st.setFlag(id2, "");

            % the display settings apply to the map
            app.handleKey('o', {});
            tc.verifyEqual(m.Mode, "overlay");
            app.handleKey(']', {});
            tc.verifyGreaterThan(m.Gain(1), 1);
            app.handleKey('c', {});
            tc.verifyEqual(m.Mode, "companion", 'holding c shows the other channel on the map too');
            app.handleKeyRelease('c');
            tc.verifyEqual(m.Mode, "overlay");
            app.handleKey('o', {}); app.handleKey('o', {});
            tc.verifyEqual(app.DisplayMode, "side");
            tc.verifyEqual(m.Mode, "overlay", 'side by side shows the overlay on a map');
        end

        function locatorCostsNothingWhileHidden(tc)
            app = tc.openApp();
            st = app.Store;
            C = curation.UiText.colors();
            n0 = app.Counters.LocatorUpdates;
            P = app.Page;
            app.hoverTile(3);
            app.handleKey('b', {});
            app.hoverTile(4);
            app.handleKey('return', {});
            app.handleKey('tab', {});
            app.mapClick(app.Map.XY(1, :));
            app.handleKey('g', {});
            app.handleKey('tab', {});
            tCuratorMap.idle();
            tc.verifyEqual(app.Counters.LocatorUpdates, n0, 'no locator work while its tab is hidden');
            tc.verifyEmpty(app.Locator, 'the locator is not even created');

            app.showRightTab('map');
            L = app.Locator;
            tc.assertNotEmpty(L);
            n1 = app.Counters.LocatorUpdates;
            tc.verifyGreaterThan(n1, n0, 'showing the tab draws it');
            tc.verifyEqual(sort(L.Ids), sort(app.Map.Ids), 'the same cells as the map');
            P = app.Page;
            % the page's cells in colour, the others dimmed
            act = st.get('State') == "active" & st.get('Label') == "" & st.get('Flag') == "" & ~st.get('Excluded');
            ids = st.get('CellID');
            onPage = ids(act & ismember(ids, P.Ids));
            offPage = ids(act & ~ismember(ids, P.Ids));
            tc.assumeNotEmpty(onPage);
            tc.verifyEqual(double(L.RGB(L.rowsOf(onPage(1)), :)), C.Unreviewed, 'a cell of the page: full colour');
            d = C.DimFactor;
            tc.verifyEqual(double(L.RGB(L.rowsOf(offPage(1)), :)), round(d * C.Unreviewed + (1 - d) * C.Background), ...
                'a cell of another page: dimmed');
            app.hoverTile(5);
            tCuratorMap.idle();
            tc.verifyEqual(L.Selection, P.Ids(5), 'the hovered tile is ringed on the locator');
            tc.verifyGreaterThan(app.Counters.LocatorUpdates, n1);

            % a click on the locator shows that place on the big map
            id = P.Ids(6);
            xy = [st.get('X', id), st.get('Y', id)];
            app.clickLocator(xy + [40 30]);
            tc.verifyEqual(app.CentreView, "map");
            r = app.Map.viewRect();
            tc.verifyTrue(xy(1) > r(1) && xy(1) < r(2) && xy(2) > r(3) && xy(2) < r(4), 'the clicked place is in view');
            tc.verifyFalse(app.Map.IsFit, 'zoomed in on it');

            % hidden again: no more work
            app.showRightTab('inspector');
            n2 = app.Counters.LocatorUpdates;
            app.handleKey('tab', {});
            app.hoverTile(2);
            app.handleKey('u', {});
            app.handleKey('return', {});
            tCuratorMap.idle();
            tc.verifyEqual(app.Counters.LocatorUpdates, n2, 'hidden again: no locator work');
        end

        %% 2 linking gallery, map and inspector
        function showOnMapAndBack(tc)
            app = tc.openApp();
            st = app.Store;
            C = curation.UiText.colors();
            P = app.Page;
            id = P.Ids(4);
            app.hoverTile(4);
            app.handleKey('.', {});
            tc.assertEqual(app.CentreView, "map");
            tc.verifyEqual(app.MapSelection, id, 'the cell is selected on the map');
            xy = [st.get('X', id), st.get('Y', id)];
            r = app.Map.viewRect();
            tc.verifyTrue(xy(1) > r(1) && xy(1) < r(2) && xy(2) > r(3) && xy(2) < r(4), 'centred on it');
            tc.verifyEqual(app.Map.Selection, id, 'and ringed');
            tCuratorMap.idle();
            fields = findall(app.Figure, 'Tag', 'lbl:fields');
            tc.verifySubstring(char(fields.Text), sprintf('Cell %d', id), 'the inspector shows it');

            % keys act on the selected point exactly as on a tile
            app.handleKey('g', {});
            tc.verifyEqual(st.get('Label', id), "Good");
            tc.verifyEqual(st.get('LabelSource', id), "human");
            tc.verifyTrue(st.get('Reviewed', id));
            tc.verifyEqual(tCuratorMap.colourOf(app, id), C.Good, 'recoloured at once');
            app.handleKey('f', {});
            tc.verifyEqual(st.get('Flag', id), "later");
            tc.verifyEqual(tCuratorMap.colourOf(app, id), C.Flag);
            app.handleKey('f', {});
            tc.verifyEqual(st.get('Flag', id), "");
            app.handleKey('x', {});
            tc.verifyEqual(st.get('Label', id), "");
            tc.verifyEqual(tCuratorMap.colourOf(app, id), C.Unreviewed);

            % a click selects; Shift+click adds; a key then acts on all, one transaction
            [id2, xy2] = tCuratorMap.lonePoint(app, 12, id);
            [id3, xy3] = tCuratorMap.lonePoint(app, 12, [id; id2]);
            app.mapClick(xy2);
            tc.verifyEqual(app.MapSelection, id2);
            app.mapClick(xy3, 'extend');
            tc.verifyEqual(sort(app.MapSelection), sort([id2; id3]));
            app.handleKey('b', {});
            tc.verifyEqual(st.get('Label', [id2; id3]), ["Bad"; "Bad"]);
            R = curation.Journal.read(st.Paths.journal, 0);
            hit = R.Field == "Label" & R.New == "Bad" & ismember(R.CellID, string([id2; id3]));
            tc.verifyEqual(numel(unique(R.Seq(hit))), 1, 'one transaction for the selection');
            tc.verifyTrue(all(R.Queue(hit) == "map"), 'journaled as a map edit');

            % Enter on a selected point: the gallery page that holds it
            app.mapClick(xy2);
            app.handleKey('return', {});
            tc.assertEqual(app.CentreView, "gallery");
            tc.verifyEqual(app.QueueName, "browseBad", 'a Bad cell is shown in Browse Bad');
            tc.verifyEqual(app.Page.Ids(app.Cursor), id2, 'with the cursor on it');

            % a double click on an unreviewed cell: its page of the Review queue
            app.handleKey('tab', {});
            ids = st.get('CellID');
            elig = ids(st.get('State') == "active" & ~st.get('Reviewed') & ~st.get('Excluded') & ...
                st.get('Label') == "" & st.get('Flag') == "");
            idU = elig(end);
            k = app.Map.rowsOf(idU);
            app.mapClick(app.Map.XY(k, :), 'open');
            tc.assertEqual(app.CentreView, "gallery");
            tc.verifyEqual(app.QueueName, "review");
            tc.verifyEqual(app.Page.Kind, "active");
            tc.verifyEqual(app.Page.Ids(app.Cursor), idU);
            % the confirm button belongs to the gallery: off on the map, with the reason
            app.handleKey('tab', {});
            b = findall(app.Figure, 'Tag', 'btn:confirm');
            tc.verifyFalse(logical(b.Enable));
            tc.verifySubstring(b.Tooltip, 'the map is showing');
        end

        %% 3 tools: add, move, snap; undo and redo keep store, crops, map and gallery in step
        function addMoveUndoRedoStayInStep(tc)
            app = tc.openApp();
            st = app.Store;
            app.handleKey('tab', {});
            m = app.Map;
            cache = app.Session.Cache;
            n0 = st.NumRows;
            app.handleKey('a', {});
            tc.verifyEqual(app.MapTool, "add");
            tc.verifyTrue(logical(findall(app.Figure, 'Tag', 'btn:toolAdd').Value), 'the active tool is highlighted');
            tc.verifyFalse(logical(findall(app.Figure, 'Tag', 'btn:toolSelect').Value));
            xy = tCuratorMap.emptySpot(app, 25);
            app.mapClick(xy);
            tc.assertEqual(st.NumRows, n0 + 1, app.StatusText);
            ids = st.get('CellID');
            id = ids(end);
            tc.verifyEqual([st.get('X', id), st.get('Y', id)], xy, 'AbsTol', 1e-6, 'placed where clicked');
            tc.verifyEqual(st.get('Origin', id), "added");
            tc.verifyEqual(st.get('Label', id), "Good");
            tc.verifyEqual(st.get('LabelSource', id), "human");
            tc.verifyTrue(st.get('Reviewed', id));
            tc.verifyEqual(st.get('PosSource', id), "human");
            tc.verifyGreaterThan(cache.rowsOf(id), 0, 'its crops are cut');
            tc.verifyEqual(cache.XY(cache.rowsOf(id), :), xy, 'AbsTol', 1e-6);
            tc.verifyGreaterThan(m.rowsOf(id), 0, 'it is drawn');
            tc.verifyEqual(app.MapSelection, id, 'and selected');
            tc.verifySubstring(char(app.StatusText), sprintf('Added cell %d', id));

            % a click on an existing point in the Add tool selects it instead of adding
            [idP, xyP] = tCuratorMap.lonePoint(app, 12, id);
            app.mapClick(xyP);
            tc.verifyEqual(st.NumRows, n0 + 1, 'nothing added');
            tc.verifyEqual(app.MapSelection, idP);

            % undo: the row, its crops and its point are gone; redo brings them all back
            app.handleKey('z', {'control'});
            tc.verifyFalse(any(st.get('CellID') == id), 'undo removes the added row');
            tc.verifyEqual(cache.rowsOf(id), 0, 'and its crops');
            tc.verifyEqual(m.rowsOf(id), 0, 'and its point');
            app.handleKey('y', {'control'});
            tc.verifyTrue(any(st.get('CellID') == id), 'redo adds it again');
            tc.verifyGreaterThan(cache.rowsOf(id), 0);
            tc.verifyEqual(m.XY(m.rowsOf(id), :), xy, 'AbsTol', 1e-6);

            % the Move tool: a drag moves a cell, its crops are cut again at the new place
            app.handleKey('m', {});
            tc.verifyEqual(app.MapTool, "move");
            [idM, xyM] = tCuratorMap.lonePoint(app, 25, id);
            to = xyM + [6 -5];
            pp = getpixelposition(m.Panel, true);
            before = sprintf('before the drag: scale %.3f, view %s, panel %s, tool %s', m.Scale, ...
                mat2str(m.viewRect(), 5), mat2str(pp), m.Tool);
            app.mapDrag(xyM, to);
            got = [st.get('X', idM), st.get('Y', idM)];
            tc.verifyEqual(got, to, 'AbsTol', 1e-6, sprintf('moved in the store (%s; status: %s)', ...
                before, app.StatusText));
            tc.verifyEqual(st.get('PosSource', idM), "human");
            tc.verifyEqual(cache.XY(cache.rowsOf(idM), :), to, 'AbsTol', 1e-6, 'crops cut at the new place');
            tc.verifyEqual(m.XY(m.rowsOf(idM), :), to, 'AbsTol', 1e-6);
            app.handleKey('z', {'control'});
            tc.verifyEqual([st.get('X', idM), st.get('Y', idM)], xyM, 'AbsTol', 1e-6, 'undo moves it back');
            tc.verifyEqual(cache.XY(cache.rowsOf(idM), :), xyM, 'AbsTol', 1e-6);
            tc.verifyEqual(m.XY(m.rowsOf(idM), :), xyM, 'AbsTol', 1e-6);
            app.handleKey('y', {'control'});
            tc.verifyEqual(m.XY(m.rowsOf(idM), :), to, 'AbsTol', 1e-6, 'redo moves it again');
            app.handleKey('escape', {});
            tc.verifyEqual(app.MapTool, "select", 'Esc returns to Select');

            % the gallery shows the added cell; undoing the add while its page is on screen takes it
            % off the page
            app.mapClick(xy);
            tc.verifyEqual(app.MapSelection, id);
            app.handleKey('return', {});
            tc.assertEqual(app.CentreView, "gallery");
            tc.verifyEqual(app.QueueName, "browseGood");
            tc.verifyEqual(app.Page.Ids(app.Cursor), id, 'the added cell is on a Browse Good page');
            tc.verifyTrue(any(app.Gallery.Ids == id));
            app.handleKey('z', {'control'});      % the move
            app.handleKey('z', {'control'});      % the add
            tc.verifyFalse(any(st.get('CellID') == id));
            tc.verifyFalse(any(app.Page.Ids == id), 'the vanished cell left the page');
            tc.verifyFalse(any(app.Gallery.Ids == id));
            app.handleKey('tab', {});
            tc.verifyEqual(m.rowsOf(id), 0, 'and the map');
        end

        function snapToCentre(tc)
            app = tc.openApp('PV2');
            st = app.Store;
            truth = tc.Truth.PV2;
            miss = truth.missedIdx;
            tc.assumeGreaterThanOrEqual(numel(miss), 2, 'the fixture has missed cells');
            app.handleKey('tab', {});
            app.setSnap(true);
            tc.verifyTrue(logical(findall(app.Figure, 'Tag', 'cb:snap').Value));
            app.setMapTool('add');
            c = truth.cellsXY(miss(1), :);
            off = [3 -2];
            n0 = st.NumRows;
            m = app.Map;
            near = min(hypot(m.XY(:, 1) - c(1) - off(1), m.XY(:, 2) - c(2) - off(2)));
            app.mapClick(c + off);
            tc.assertEqual(st.NumRows, n0 + 1, sprintf(['%s (scale %.3f, view %s, panel %s, tool %s, ' ...
                'nearest point %.1f px, selection %s)'], app.StatusText, m.Scale, mat2str(m.viewRect(), 5), ...
                mat2str(getpixelposition(m.Panel, true)), m.Tool, near, mat2str(app.MapSelection)));
            ids = st.get('CellID');
            id = ids(end);
            p = [st.get('X', id), st.get('Y', id)];
            tc.verifyEqual(st.get('PosSource', id), "snap", 'snapped: PosSource snap');
            tc.verifyLessThan(norm(p - c), norm(off), 'snapped towards the true centre');
            tc.verifyEqual(app.Map.XY(app.Map.rowsOf(id), :), p, 'AbsTol', 1e-6, 'drawn where it was snapped');
            % a move with snap on also refines the drop
            app.setMapTool('move');
            app.mapDrag(p, c + [-3 3]);
            p2 = [st.get('X', id), st.get('Y', id)];
            tc.verifyEqual(st.get('PosSource', id), "snap");
            tc.verifyLessThan(norm(p2 - c), norm([-3 3]));
            % snap off: exactly where clicked, PosSource human
            app.setSnap(false);
            app.setMapTool('add');
            c2 = truth.cellsXY(miss(2), :);
            app.mapClick(c2 + off);
            ids = st.get('CellID');
            id2 = ids(end);
            tc.verifyEqual([st.get('X', id2), st.get('Y', id2)], c2 + off, 'AbsTol', 1e-6);
            tc.verifyEqual(st.get('PosSource', id2), "human");
        end

        %% 4 lasso: label, exclude, merge; regions reach the other channel
        function lassoExcludeIsOneStepAndReachesTheOtherChannel(tc)
            app = tc.openApp();
            st = app.Store;
            C = curation.UiText.colors();
            app.handleKey('tab', {});
            m = app.Map;
            sq = [150 150; 330 150; 330 300; 150 300];
            ids = st.get('CellID');
            xy = [st.get('X'), st.get('Y')];
            act = st.get('State') == "active";
            inside = act & inpolygon(xy(:, 1), xy(:, 2), sq(:, 1), sq(:, 2));
            tc.assumeGreaterThan(nnz(inside), 3, 'cells inside the square');
            app.mapLasso(sq);
            tc.assertNotEmpty(app.Lasso, app.StatusText);
            tc.verifyEqual(sort(app.Lasso.Ids), sort(ids(inside)), 'the lasso holds the cells inside');
            bar = findall(app.Figure, 'Tag', 'pn:lassoBar');
            tc.verifyEqual(char(bar.Visible), 'on', 'the action bar shows');
            tc.verifySubstring(char(findall(app.Figure, 'Tag', 'lbl:lassoBar').Text), sprintf('%d cells', nnz(inside)));
            tc.verifySubstring(char(app.ContextText), 'Lasso:');
            app.handleKey('e', {});
            R = st.regions();
            tc.assertNumElements(R, 1, 'one exclusion region');
            tc.verifyEqual(R.kind, "exclude");
            tc.verifyEqual(R.scope, "image", 'for every channel of the section');
            want = curation.Regions.excluded(R, xy, "ECM1") & act;
            tc.verifyEqual(st.get('Excluded') & act, want, 'Excluded == inside the region, for every active row');
            tc.verifyTrue(all(want(inside)));
            tc.verifyEqual(char(bar.Visible), 'off');
            tc.verifyTrue(any([m.Regions.kind] == "exclude"), 'drawn on the map');
            k = find(inside, 1);
            d = C.DimFactor;
            base = curation.UiText.colors();
            tc.verifyEqual(tCuratorMap.colourOf(app, ids(k)), ...
                round(d * tCuratorMap.stateColour(st, ids(k), base) + (1 - d) * C.Background), 'excluded cells are dimmed');
            eligible = st.get('State') == "active" & ~st.get('Reviewed') & ~st.get('Excluded') & ...
                st.get('Label') == "" & st.get('Flag') == "";
            tc.verifyFalse(any(eligible & inside), 'excluded cells leave the review queue');
            % one undo step: the region and the exclusions together
            app.handleKey('z', {'control'});
            tc.verifyEmpty(st.regions());
            tc.verifyFalse(any(st.get('Excluded')), 'undo includes the cells again');
            app.handleKey('y', {'control'});
            tc.verifyNumElements(st.regions(), 1);
            tc.verifyEqual(st.get('Excluded') & act, want, 'redo excludes them again');

            % the other channel: the image-scope region is applied when it opens
            app.handleKey('rightarrow', {'control'});
            tc.assertEqual(app.SourceKey, "PV2");
            st2 = app.Store;
            xy2 = [st2.get('X'), st2.get('Y')];
            act2 = st2.get('State') == "active";
            in2 = act2 & inpolygon(xy2(:, 1), xy2(:, 2), R.xy(:, 1), R.xy(:, 2));
            tc.assumeGreaterThan(nnz(in2), 0);
            ids2 = st2.get('CellID');
            tc.verifyTrue(all(st2.get('Excluded', ids2(in2))), 'PV2 cells inside are excluded');
            tc.verifyFalse(any(st2.get('Excluded', ids2(act2 & ~in2))));
            tc.verifySubstring(lower(char(app.StatusText)), 'exclusion regions', 'the status bar says so');
            tc.verifyEqual(app.CentreView, "map", 'the map stays on screen');
            tc.verifyTrue(any([app.Map.Regions.kind] == "exclude"), 'and shows the region for PV2');
            tc.verifyEqual(sort(app.Map.Ids), sort(ids2(act2)), 'with the points of PV2');
        end

        function regionRemovalAndLassoLabelMerge(tc)
            app = tc.openApp();
            st = app.Store;
            app.handleKey('tab', {});
            m = app.Map;
            sq = [420 300; 640 300; 640 480; 420 480];
            app.mapLasso(sq);
            app.lassoAction('exclude');
            R = st.regions();
            tc.assertNumElements(R, 1);
            ids = st.get('CellID');
            exc = st.get('Excluded');
            tc.assumeGreaterThan(nnz(exc), 0);
            app.handleKey('escape', {});
            tc.verifyEqual(app.MapTool, "select");
            % a click on empty space inside the region selects it; Del removes it
            p = [];
            for y = 310:6:470
                for x = 430:6:630
                    if min(hypot(m.XY(:, 1) - x, m.XY(:, 2) - y)) > 15
                        p = [x y];
                        break
                    end
                end
                if ~isempty(p), break; end
            end
            tc.assertNotEmpty(p);
            app.mapClick(p);
            tc.verifyEqual(app.SelectedRegion, R.id, 'the region is selected');
            tc.verifyEqual(char(findall(app.Figure, 'Tag', 'pn:regionBar').Visible), 'on');
            tc.verifySubstring(char(app.ContextText), 'Del: remove it');
            app.handleKey('delete', {});
            tc.verifyEmpty(st.regions(), 'removed');
            tc.verifyFalse(any(st.get('Excluded')), 'its cells count again');
            tc.verifyEqual(app.SelectedRegion, 0);
            app.handleKey('z', {'control'});
            tc.verifyNumElements(st.regions(), 1, 'one undo step restores the region');
            tc.verifyEqual(st.get('Excluded'), exc, 'and the exclusions');
            app.handleKey('y', {'control'});

            % lasso + g: every cell inside Good, one transaction
            sq2 = [100 100; 260 100; 260 220; 100 220];
            xy = [st.get('X'), st.get('Y')];
            in = st.get('State') == "active" & inpolygon(xy(:, 1), xy(:, 2), sq2(:, 1), sq2(:, 2));
            tc.assumeGreaterThan(nnz(in), 1);
            app.mapLasso(sq2);
            app.handleKey('g', {});
            tc.verifyTrue(all(st.get('Label', ids(in)) == "Good"));
            tc.verifyTrue(all(st.get('LabelSource', ids(in)) == "human"));
            J = curation.Journal.read(st.Paths.journal, 0);
            hit = J.Field == "Label" & J.New == "Good" & ismember(J.CellID, string(ids(in)));
            tc.verifyEqual(numel(unique(J.Seq(hit))), 1, 'one transaction');
            tc.verifyEmpty(app.Lasso);

            % Esc cancels a lasso: nothing changes
            before = st.get('Label');
            app.mapLasso(sq2);
            app.handleKey('escape', {});
            tc.verifyEmpty(app.Lasso);
            tc.verifyEqual(st.get('Label'), before);

            % lasso + j: two cells merged into the higher-scored one
            [a, xa] = tCuratorMap.lonePoint(app, 30);
            [b, xb] = tCuratorMap.lonePoint(app, 30, a);
            % move b next to a, then lasso both
            app.setMapTool('move');
            app.mapDrag(xb, xa + [8 0]);
            tc.assertEqual([st.get('X', b), st.get('Y', b)], xa + [8 0], 'AbsTol', 1e-6);
            poly = [xa(1) - 5, xa(2) - 5; xa(1) + 13, xa(2) - 5; xa(1) + 13, xa(2) + 5; xa(1) - 5, xa(2) + 5];
            app.mapLasso(poly);
            tc.assertEqual(sort(app.Lasso.Ids), sort([a; b]));
            r = st.get('rescore', [a; b]);
            r(~isfinite(r)) = -Inf;
            [~, i] = max(r);
            keeper = [a; b];
            keeper = keeper(i);
            loser = setdiff([a; b], keeper);
            app.handleKey('j', {});
            tc.verifyEqual(st.get('State', loser), "merged");
            tc.verifyEqual(st.get('MergedInto', loser), keeper, 'merged into the higher-scored cell');
            tc.verifyEqual(st.get('State', keeper), "active");
            tc.verifyEqual(m.rowsOf(loser), 0, 'the merged cell leaves the map');
            app.handleKey('z', {'control'});
            tc.verifyEqual(st.get('State', loser), "active", 'undo unmerges');
            tc.verifyGreaterThan(m.rowsOf(loser), 0);
        end

        %% 5 the reference ROI
        function referenceRoiIsDrawnOnly(tc)
            p = fullfile(tc.Folder, [tc.Truth.baseName '_proj_roi.roi']);
            tCuratorMap.writeWideLine(p, [100 300], [700 300], 80);
            app = tc.openApp();
            st = app.Store;
            ref = app.Session.Reference;
            tc.assertNotEmpty(ref, app.StatusText);
            tc.verifyEqual(ref.kind, "reference");
            tc.verifyEqual(ref.xy, [100 340; 700 340; 700 260; 100 260] + 0.5, 'AbsTol', 1e-4, ...
                'the wide line becomes its strip');
            tc.verifyEmpty(st.regions(), 'the reference is not stored');
            tc.verifyFalse(any(st.get('Excluded')), 'and filters nothing');
            J = jsondecode(fileread(st.Paths.json));
            tc.verifyTrue(~isfield(J, 'regions') || isempty(J.regions), 'not in the JSON either');
            app.handleKey('tab', {});
            k = find([app.Map.Regions.kind] == "reference");
            tc.verifyNumElements(k, 1, 'drawn on the map');
            tc.verifyEqual(app.Map.Regions(k).xy, ref.xy);
        end

        function badReferenceRoiIsReported(tc)
            p = fullfile(tc.Folder, [tc.Truth.baseName '_proj_roi.roi']);
            fid = fopen(p, 'w');
            fwrite(fid, zeros(1, 70, 'uint8'));
            fclose(fid);
            app = tc.openApp();
            tc.verifyEmpty(app.Session.Reference);
            tc.verifySubstring(char(app.StatusText), 'could not be read');
            tc.verifySubstring(char(app.StatusText), '_proj_roi.roi');
            app.handleKey('tab', {});
            kinds = string({app.Map.Regions.kind});
            tc.verifyFalse(any(kinds == "reference"));
        end
    end

    methods (Static)
        function rgb = stateColour(st, id, C)
            lab = st.get('Label', id);
            rgb = C.Unreviewed;
            pend = any(st.get('AuditRole', id) == ["holdout" "confirm-audit"]) && st.get('LabelSource', id) ~= "blind";
            switch lab
                case "Good", rgb = C.Good;
                case "Bad", rgb = C.Bad;
                case "Uncertain", rgb = C.Uncertain;
            end
            if pend, rgb = C.Unreviewed; end       % an audit tile waiting for its blind judgement
            if st.get('Flag', id) ~= "", rgb = C.Flag; end
        end

        function writeWideLine(p, p1, p2, w)
            %writeWideLine  A byte-exact ImageJ line ROI with stroke width W (big-endian header).
            be16 = @(v) typecast(swapbytes(int16(v)), 'uint8');
            be32f = @(v) typecast(swapbytes(single(v)), 'uint8');
            h = zeros(1, 64, 'uint8');
            h(1:4) = uint8('Iout');
            h(5:6) = be16(228);
            h(7) = 3;                                   % line
            h(19:34) = [be32f(p1(1)) be32f(p1(2)) be32f(p2(1)) be32f(p2(2))];
            h(35:36) = be16(w);
            fid = fopen(p, 'w');
            fwrite(fid, h, 'uint8');
            fclose(fid);
        end
    end
end

classdef tCuratorGestures < matlab.uitest.TestCase
    %tCuratorGestures  Real matlab.uitest gestures on CellCurator (presses on the gallery, a drag,
    %   hover, buttons, typing, choosing) prove the wiring from real events to the app's seams;
    %   screenshots for a person to look at; and (tag Benchmark) the speed budgets on a real-size
    %   source.
    %
    %   Run on the hidden desktop:
    %     tools\Run-Tests.ps1 tCuratorGestures                 gestures + screenshots
    %     tools\Run-Tests.ps1 tCuratorGestures -IncludeSlow    + benchmarks (real-size fixture)

    properties (Constant)
        Budget = struct('LabelKey', 30, 'Enter', 100, 'SourceCold', 2000, 'SourceBack', 300)
    end

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
        function app = openApp(tc, folder, varargin)
            if nargin < 2 || isempty(folder), folder = tc.Folder; end
            app = CellCurator('UseSettings', false, 'PrepareNext', false, 'Assist', false, 'ConfirmAudit', false, varargin{:});
            tc.addTeardown(@() tCuratorGestures.closeApp(app));
            app.openParent(folder, '', 'ECM1');
            app.waitForLayout();
            tc.assertEqual(app.Page.Kind, "active", app.StatusText);
        end

        function fp = tilePoint(~, app, k)
            %tilePoint  Figure-pixel point at the center of tile K.
            fp = app.Gallery.mosaicToFigure(app.Gallery.tileCenter(k));
        end
    end

    methods (Static)
        function closeApp(app)
            if ~isempty(app) && isvalid(app)
                delete(app);
            end
        end

        function h = byTag(app, tag)
            h = findall(app.Figure, 'Tag', tag);
            h = h(1);
        end

        function s = opposite(label)
            if label == "Good", s = "Bad"; else, s = "Good"; end
        end

        function d = screensDir()
            d = fullfile(getenv('LOCALAPPDATA'), 'counting_perineuronal_nets', 'test_logs', 'screens');
            if ~isfolder(d), mkdir(d); end
        end

        function saveScreen(fig, name)
            file = fullfile(tCuratorGestures.screensDir(), name);
            drawnow;
            pause(0.5);
            drawnow;
            try
                exportapp(fig, file);
                how = 'exportapp';
            catch err1
                try
                    F = getframe(fig);
                    imwrite(F.cdata, file);
                    how = 'getframe';
                catch err2
                    I = print(fig, '-RGBImage');
                    imwrite(I, file);
                    how = sprintf('print -RGBImage (exportapp: %s; getframe: %s)', err1.message, err2.message);
                end
            end
            fprintf('[screens] %s (%s)\n', file, how);
        end

        function v = p90(x)
            x = sort(x(:));
            v = x(max(1, ceil(0.9 * numel(x))));
        end

        function writeWideLine(p, p1, p2, w)
            %writeWideLine  A byte-exact ImageJ line ROI with stroke width W (the reference strip).
            be16 = @(v) typecast(swapbytes(int16(v)), 'uint8');
            be32f = @(v) typecast(swapbytes(single(v)), 'uint8');
            h = zeros(1, 64, 'uint8');
            h(1:4) = uint8('Iout');
            h(5:6) = be16(228);
            h(7) = 3;
            h(19:34) = [be32f(p1(1)) be32f(p1(2)) be32f(p2(1)) be32f(p2(2))];
            h(35:36) = be16(w);
            fid = fopen(p, 'w');
            fwrite(fid, h, 'uint8');
            fclose(fid);
        end
    end

    % ------------------------------------------------------------------------------------------------
    methods (Test)
        function pressOnTilesMarksExceptions(tc)
            app = tc.openApp();
            P = app.Page;
            st = app.Store;
            opp = tCuratorGestures.opposite(P.Default);
            tc.press(app.Figure, tc.tilePoint(app, 2));
            drawnow;
            tc.verifyEqual(st.get('Label', P.Ids(2)), opp, 'a real click marks the exception');
            tc.verifyEqual(st.get('LabelSource', P.Ids(2)), "human");
            tc.press(app.Figure, tc.tilePoint(app, 3), 'SelectionType', 'alt');
            drawnow;
            tc.verifyEqual(st.get('Label', P.Ids(3)), "Uncertain", 'a real right-click: Uncertain');
            tc.press(app.Figure, tc.tilePoint(app, 2));
            drawnow;
            tc.verifyEqual(st.get('Label', P.Ids(2)), "", 'clicked again: untouched');
            % the border in the shown mosaic is the label's color
            C = curation.UiText.colors();
            L = app.Gallery.Layout;
            r = L.Rect(3, :);
            px = double(squeeze(app.Gallery.Mosaic(r(2) + r(4) / 2, r(1), :)))';
            tc.verifyEqual(px, C.Uncertain, 'the decided tile wears its label color');
            r = L.Rect(1, :);
            px = double(squeeze(app.Gallery.Mosaic(r(2) + r(4) / 2, r(1), :)))';
            if P.Default == "Good", want = C.ProposedGood; else, want = C.ProposedBad; end
            tc.verifyEqual(px, want, 'an untouched tile wears the muted proposed color');
        end

        function dragPaintsTheSameChange(tc)
            app = tc.openApp();
            P = app.Page;
            tc.assumeGreaterThanOrEqual(app.Gallery.Layout.NCols, 4);
            tc.assumeGreaterThanOrEqual(numel(P.Ids), 4);
            opp = tCuratorGestures.opposite(P.Default);
            tc.drag(app.Figure, tc.tilePoint(app, 1), tc.tilePoint(app, 4));
            drawnow;
            tc.verifyEqual(app.Store.get('Label', P.Ids(1:4)), repmat(opp, 4, 1), ...
                'a real drag paints the exception over every tile it crosses');
        end

        function hoverAndInspectorButtons(tc)
            app = tc.openApp();
            P = app.Page;
            st = app.Store;
            tc.hover(app.Figure, tc.tilePoint(app, 5));
            pause(0.2);
            drawnow;
            tc.verifyEqual(app.InspectedTile, 5, 'hovering a tile shows it in the inspector');
            tc.verifySubstring(char(tCuratorGestures.byTag(app, 'lbl:fields').Text), sprintf('Cell %d', P.Ids(5)));
            tc.press(tCuratorGestures.byTag(app, 'btn:bad'));
            tc.verifyEqual(st.get('Label', P.Ids(5)), "Bad", 'Bad [b] acts on the inspected cell');
            tc.press(tCuratorGestures.byTag(app, 'btn:flag'));
            tc.verifyEqual(st.get('Flag', P.Ids(5)), "later");
            tc.press(tCuratorGestures.byTag(app, 'btn:clear'));
            tc.verifyEqual(st.get('Label', P.Ids(5)), "");
            tc.verifyEqual(st.get('Flag', P.Ids(5)), "");
            tc.press(tCuratorGestures.byTag(app, 'btn:confirm'));
            tc.verifyNotEqual(app.Page.PageId, P.PageId, 'Confirm page [Enter] moves on');
            tc.verifyTrue(all(st.get('Label', P.Ids) == P.Default));
            undo = tCuratorGestures.byTag(app, 'btn:undo');
            pause(0.3); drawnow;                     % the deferred refresh enables Undo
            tc.verifyTrue(logical(undo.Enable));
            tc.press(undo);
            tc.verifyEqual(app.Page.PageId, P.PageId, 'Undo [Ctrl+Z] brings the page back');
            tc.press(tCuratorGestures.byTag(app, 'btn:prev'));
            tc.verifySubstring(char(app.StatusText), 'No earlier page');
        end

        function typeChooseAndDrag(tc)
            app = tc.openApp();
            P = app.Page;
            tc.hover(app.Figure, tc.tilePoint(app, 4));
            pause(0.2); drawnow;
            tc.type(tCuratorGestures.byTag(app, 'ef:note'), 'odd shape');
            tc.verifyEqual(app.Store.get('Notes', P.Ids(4)), "odd shape", 'typing a note saves it on the cell');
            tc.choose(tCuratorGestures.byTag(app, 'dd:mode'), 'Overlay');
            tc.verifyEqual(app.DisplayMode, "overlay");
            tc.verifyEqual(app.Gallery.Style.Mode, "overlay");
            tc.choose(tCuratorGestures.byTag(app, 'lb:queues'), find(CellCurator.QUEUES == "browseGood"));
            tc.verifyEqual(app.QueueName, "browseGood", 'choosing a queue switches to it');
            tc.choose(tCuratorGestures.byTag(app, 'lb:queues'), 1);
            tc.verifyEqual(app.QueueName, "review");
            g0 = app.Gain;
            s = tCuratorGestures.byTag(app, 'sl:gain');
            tc.drag(s, s.Value, s.Value + 1);
            tc.verifyGreaterThan(app.Gain, g0, 'dragging the brightness slider brightens');
            tc.press(tCuratorGestures.byTag(app, 'btn:help'));
            tc.verifyEqual(char(tCuratorGestures.byTag(app, 'pn:cheat').Visible), 'on', 'Keys [?] shows the cheat sheet');
            tc.press(findall(app.Figure, 'Tag', 'btn:help', 'Text', curation.UiText.label('closeHelp')));
            tc.verifyEqual(char(tCuratorGestures.byTag(app, 'pn:cheat').Visible), 'off');
            tc.choose(findall(app.Figure, 'Tag', 'tg:right'), 'Map');
            tc.verifyNotEmpty(app.MapPanel);
            tc.verifyTrue(isvalid(app.MapPanel));
        end

        function evenTilesButtonAndKey(tc)
            % Even tiles [t]: the state button and the key scale each tile to the source's typical level
            app = tc.openApp();
            b = tCuratorGestures.byTag(app, 'btn:evenTiles');
            tc.verifyFalse(app.EvenTiles);
            tc.verifyEmpty(app.Gallery.Style.TileLevel, 'off: one contrast for the page');
            m0 = app.Gallery.Mosaic;
            tc.press(b);
            tc.verifyTrue(app.EvenTiles, 'pressing the button turns it on');
            lv = app.Gallery.Style.TileLevel;
            tc.verifySize(lv, [1 2]);
            tc.verifyTrue(all(lv >= 1 & lv <= 255));
            tc.verifyNotEqual(app.Gallery.Mosaic, m0, 'the tiles are drawn again, leveled');
            tc.verifySubstring(app.StatusText, 'Even tiles on');
            tc.verifyTrue(app.handleKey('t'));
            tc.verifyFalse(app.EvenTiles, 't turns it off');
            tc.verifyFalse(logical(b.Value), 'the button follows the key');
            tc.verifyEmpty(app.Gallery.Style.TileLevel);
            tc.verifyEqual(app.Gallery.Mosaic, m0, 'off again: the page contrast as before');
        end

        function keyCallbacksReachTheSeam(tc)
            % matlab.uitest has no key gesture for a figure: call the figure's key callbacks with the
            % event fields a real key press carries.
            app = tc.openApp();
            P = app.Page;
            f = app.Figure;
            app.hoverTile(2);
            f.WindowKeyPressFcn(f, struct('Key', 'b', 'Modifier', {{}}, 'Character', 'b'));
            tc.verifyEqual(app.Store.get('Label', P.Ids(2)), "Bad");
            f.WindowKeyPressFcn(f, struct('Key', 'z', 'Modifier', {{'control'}}, 'Character', char(26)));
            tc.verifyEqual(app.Store.get('Label', P.Ids(2)), "", 'Ctrl+Z through the callback');
            f.WindowKeyPressFcn(f, struct('Key', 'c', 'Modifier', {{}}, 'Character', 'c'));
            tc.verifyEqual(app.Gallery.Style.Mode, "companion");
            f.WindowKeyReleaseFcn(f, struct('Key', 'c', 'Modifier', {{}}, 'Character', 'c'));
            tc.verifyEqual(app.Gallery.Style.Mode, "target");
            f.WindowKeyPressFcn(f, struct('Key', 'rightbracket', 'Modifier', {{}}, 'Character', ']'));
            tc.verifyGreaterThan(app.Gain, 1);
            % typing in the note field must not label tiles
            note = tCuratorGestures.byTag(app, 'ef:note');
            note.ValueChangingFcn(note, struct('Value', 'g'));
            f.WindowKeyPressFcn(f, struct('Key', 'g', 'Modifier', {{}}, 'Character', 'g'));
            tc.verifyEqual(app.Store.get('Label', P.Ids(2)), "", 'keys go to the note field while it is typed in');
            f.WindowKeyPressFcn(f, struct('Key', 'return', 'Modifier', {{}}, 'Character', char(13)));
            tc.verifyEqual(app.Page.PageId, P.PageId, 'Enter in the note field does not confirm the page');
            note.ValueChangedFcn(note, struct('Value', 'gg', 'PreviousValue', ''));
            f.WindowKeyPressFcn(f, struct('Key', 'g', 'Modifier', {{}}, 'Character', 'g'));
            tc.verifyEqual(app.Store.get('Label', P.Ids(2)), "Good", 'after the note is saved keys work again');
        end

        function screenshotsForReview(tc)
            dir0 = tCuratorGestures.screensDir();
            app = tc.openApp();
            P = app.Page;
            opp = tCuratorGestures.opposite(P.Default);
            % a few exceptions, one Uncertain, one flag, the cursor and a hovered cell
            tc.press(app.Figure, tc.tilePoint(app, 2));
            tc.press(app.Figure, tc.tilePoint(app, 7), 'SelectionType', 'alt');
            app.galleryClick(min(12, numel(P.Ids)), 'normal');
            app.hoverTile(min(9, numel(P.Ids)));
            app.handleKey('f', {});
            app.hoverTile(0);
            app.handleKey('downarrow', {});
            app.hoverTile(2);
            pause(0.4);
            drawnow;
            tc.verifyEqual(app.Store.get('Label', P.Ids(2)), opp);
            tCuratorGestures.saveScreen(app.Figure, 'curator_review.png');
            app.handleKey('?', {});
            tCuratorGestures.saveScreen(app.Figure, 'curator_cheatsheet.png');
            g = tCuratorGestures.byTag(app, 'gl:cheat');
            scroll(g, 'bottom');
            tCuratorGestures.saveScreen(app.Figure, 'curator_cheatsheet_end.png');
            app.handleKey('?', {});
            app.handleKey('o', {});
            tCuratorGestures.saveScreen(app.Figure, 'curator_overlay.png');
            delete(app);

            % the empty state, with a folder to reopen in the (test) settings
            setpref('CellCurator', 'Settings', struct('LastFolder', tc.Folder));
            tc.addTeardown(@() rmpref('CellCurator'));
            app2 = CellCurator('UseSettings', true, 'PrepareNext', false, 'Assist', false, 'ConfirmAudit', false);
            tc.addTeardown(@() tCuratorGestures.closeApp(app2));
            app2.waitForLayout(6);
            reopen = tCuratorGestures.byTag(app2, 'btn:reopen');
            tc.verifyEqual(char(reopen.Visible), 'on', 'the empty state offers the last folder');
            tCuratorGestures.saveScreen(app2.Figure, 'curator_empty.png');
            tc.press(reopen);
            tc.verifyEqual(app2.Page.Kind, "active", 'Reopen opens the last folder');
            app2.waitForLayout();
            % the end of a source
            for k = 1:100
                if app2.Page.Kind ~= "active", break; end
                app2.confirmPage();
            end
            tCuratorGestures.saveScreen(app2.Figure, 'curator_done.png');
            tc.verifyTrue(isfile(fullfile(dir0, 'curator_review.png')));
        end

        function mapScreenshots(tc)
            % the map with every point color, an exclusion region, the reference strip, the locator,
            % the lasso bar, a close pair, a sweep field and the finish checklist
            dir0 = tCuratorGestures.screensDir();
            roi = fullfile(tc.Folder, [tc.Truth.baseName '_proj_roi.roi']);
            tCuratorGestures.writeWideLine(roi, [60 420], [760 380], 90);
            app = tc.openApp();
            st = app.Store;
            P = app.Page;
            app.galleryClick(2, 'normal');
            app.galleryClick(5, 'alt');
            app.hoverTile(7);
            app.handleKey('f', {});
            app.handleKey('return', {});
            app.handleKey('return', {});
            app.handleKey('tab', {});
            tc.assertEqual(app.CenterView, "map");
            app.mapLasso([480 80; 700 80; 700 200; 480 200]);
            app.lassoAction('exclude');
            app.showRightTab('map');
            app.setMapTool('select');
            [~, k] = min(hypot(app.Map.XY(:, 1) - 300, app.Map.XY(:, 2) - 300));
            app.mapClick(app.Map.XY(k, :));
            pause(0.5); drawnow;
            tCuratorGestures.saveScreen(app.Figure, 'curator_map.png');
            % the lasso bar
            app.showRightTab('inspector');
            app.Map.fit();
            app.mapLasso([150 250; 330 230; 360 380; 200 420; 130 340]);
            pause(0.3); drawnow;
            tCuratorGestures.saveScreen(app.Figure, 'curator_lasso.png');
            app.lassoAction('cancel');
            % a close pair
            ids = st.get('CellID');
            st.setLabel(ids(st.get('State') == "active" & st.get('Label') == ""), "Good", "human");
            app.showQueue('closePairs');
            km = find([app.PairList.Proposal] == "merge", 1);
            for i = 2:km
                app.handleKey('rightarrow', {});
            end
            pause(0.4); drawnow;
            tCuratorGestures.saveScreen(app.Figure, 'curator_pairs.png');
            % a sweep field
            app.showQueue('sweep');
            app.handleKey('space', {});
            pause(0.4); drawnow;
            tCuratorGestures.saveScreen(app.Figure, 'curator_sweep.png');
            % the finish checklist
            app.handleKey('tab', {});
            for k = 1:200
                if app.Page.Kind ~= "active", break; end
                app.handleKey('space', {});
            end
            pause(0.4); drawnow;
            tc.verifyEqual(char(tCuratorGestures.byTag(app, 'pn:finish').Visible), 'on');
            tCuratorGestures.saveScreen(app.Figure, 'curator_finish.png');
            for f = ["curator_map.png" "curator_lasso.png" "curator_pairs.png" "curator_sweep.png" "curator_finish.png"]
                tc.verifyTrue(isfile(fullfile(dir0, f)), f);
            end
            tc.verifyGreaterThan(numel(P.Ids), 0);
        end
    end

    % ------------------------------------------------------------------------------------------------
    methods (Test, TestTags = {'Benchmark'})
        function benchmarkBudgets(tc)
            % A real-size source: two 3277 x 2355 float32 pages, ~1,000 WFA and ~2,000 PV cells
            % (about 1,650 and 3,300 detections). Times from the call until drawnow has returned.
            fx = tc.applyFixture(matlab.unittest.fixtures.TemporaryFolderFixture);
            t0 = tic;
            folder = makeSyntheticDataset(fullfile(fx.Folder, 'big'), 'ImageSize', [3277 2355], ...
                'NumCells', [1000 2000]);
            makeSyntheticDataset(fullfile(fx.Folder, 'big'), 'ImageSize', [3277 2355], ...
                'NumCells', [1000 2000], 'BaseName', "SYN-0002_sec1", 'Seed', 2);
            fprintf('\n[curator-perf] real-size fixture (2 sections) written in %.1f s\n', toc(t0));
            % with the assist model and blind tiles active: section 2's WFA channel carries 400 labels
            % (so a model is fitted in the background), the holdout and the confirm audit are on
            locs2 = fullfile(folder, 'SYN-0002_sec1_proj_ECM1_locs.csv');
            st2 = curation.Store.open(CellDatasetManifest.forCsv(locs2), 'ECM1', struct('AutosaveDelay', 0));
            ids2 = st2.get('CellID');
            sc = st2.get('score');
            st2.setLabel(ids2(1:400), "Good", "human");
            st2.setLabel(ids2(sc(1:400) < 0.6), "Bad", "human");
            st2.flush(); st2.close(); delete(st2);
            t0 = tic;
            app = tc.openApp(folder, 'Assist', true, 'ConfirmAudit', true, ...
                'AssistOptions', struct('CacheDir', fullfile(fx.Folder, 'cache'), 'RefreshSec', 0));
            fprintf('[curator-perf] app built + ECM1 opened + layout in %.1f s\n', toc(t0));
            app.waitForAssist(300);
            fprintf(['[curator-perf] assist: model %d, %d predictions applied, %d holdout tiles in this source; ' ...
                'last apply %.1f ms\n'], app.Assist.summary("pnn").Number, app.Counters.ModelApplies, ...
                nnz(app.Store.get('AuditRole') == "holdout"), app.LastTimings.ApplyModelMs);
            app.showQueue('review');      % the page on screen as it is now (model order, blind tiles)
            tCuratorGestures.printOpen(app, 'first source (ECM1, section 1)');
            c = app.Store.counts();
            fprintf('[curator-perf] ECM1: %d detections; page %d x %d = %d tiles; screen %s\n', c.total, ...
                app.Gallery.Grid(2), app.Gallery.Grid(1), prod(app.Gallery.Grid), mat2str(get(groot, 'ScreenSize')));
            R = struct();

            % 1 label key -> border changed: first without the map, then with the map loaded (and
            %   hidden again): the gallery's key path must not pay for keeping it in step
            [tA, tCallA, okA] = tCuratorGestures.labelKeySeries(app, 30, 4);
            t1 = tic;
            app.showCenter("map");
            drawnow;
            tMap = 1000 * toc(t1);
            app.showCenter("gallery");
            drawnow;
            tc.assertEqual(app.Counters.MapLoads, 1);
            fprintf('[curator-perf] map shown for ECM1 in %.0f ms and hidden again; the budgets below run with it loaded\n', tMap);
            [t, tCall, okColor] = tCuratorGestures.labelKeySeries(app, 30, 4);
            R.LabelKey = t;
            tc.verifyTrue(okA && okColor, 'the border shows the new label');
            fprintf(['[curator-perf] label key -> border changed, median: %.1f ms before the map was loaded ' ...
                '(call %.1f ms), %.1f ms with it loaded (call %.1f ms)\n'], median(tA), median(tCallA), ...
                median(t), median(tCall));
            % the store alone (journal append, event), for reference
            st = app.Store;
            idsT = st.get('CellID');
            idsT = idsT(end - 25:end);
            tS = zeros(numel(idsT), 1);
            for i = 1:numel(idsT)
                t1 = tic;
                st.setLabel(idsT(i), "Bad", "human");
                tS(i) = toc(t1);
            end
            st.setLabel(idsT, "", "human");
            fprintf(['[curator-perf] label key: handleKey call median %.1f ms + drawnow %.1f ms; ' ...
                'Store.setLabel alone %.1f ms\n'], median(tCall), median(t - tCall), 1000 * median(tS(4:end)));

            % 2 Enter -> next page shown (the user looks at each page first: the prefetch has run)
            for k = 1:numel(app.Page.Ids)
                if app.Store.get('Label', app.Page.Ids(k)) ~= "", app.hoverTile(k); app.handleKey('x', {}); end
            end
            n = 14;
            t = NaN(n, 1);
            pre = false(n, 1);
            for i = 1:n
                pause(0.5);
                drawnow;
                if app.Page.Kind ~= "active", break; end
                P = app.Page;
                for kb = find(P.Blind(:))'               % the audit tiles: judged (not timed)
                    app.hoverTile(kb); app.handleKey('g', {});
                end
                app.hoverTile(0);
                o = find(~P.Blind, 1);
                app.galleryClick(o, 'normal');           % one exception per page
                pause(0.3); drawnow;
                t1 = tic;
                app.handleKey('return', {});
                drawnow;
                t(i) = toc(t1);
                pre(i) = app.LastTimings.NextPrefetched;
            end
            R.Enter = 1000 * t(isfinite(t));
            fprintf('[curator-perf] Enter: the next page was prefetched on %d of %d pages; confirm call %.1f ms\n', ...
                nnz(pre), nnz(isfinite(t)), app.LastTimings.ConfirmMs);

            % 3 switching to a source not opened yet: PV2 of the same section (its TIFF pages are in
            %   memory; store + crops built now), then the first source of the next section (its TIFF
            %   is read too: the worst case)
            pause(0.3); drawnow;
            t1 = tic;
            app.handleKey('rightarrow', {'control'});
            drawnow;
            tPV2 = 1000 * toc(t1);
            tc.verifyEqual(app.SourceKey, "PV2");
            tCuratorGestures.printOpen(app, 'PV2, same section');
            pause(0.3); drawnow;
            t1 = tic;
            app.handleKey('rightarrow', {'control'});
            drawnow;
            tSec2 = 1000 * toc(t1);
            tc.verifyEqual(app.SourceKey, "ECM1");
            tc.verifyEqual(app.DatasetIndex, 2);
            tCuratorGestures.printOpen(app, 'ECM1, next section (new TIFF)');
            R.SourceCold = [tPV2; tSec2];

            % 4 switching back and forth between opened sources
            n = 8;
            t = zeros(n, 1);
            for i = 1:n
                pause(0.3); drawnow;
                if mod(i, 2), d = 'leftarrow'; else, d = 'rightarrow'; end
                t1 = tic;
                app.handleKey(d, {'control'});
                drawnow;
                t(i) = toc(t1);
            end
            R.SourceBack = 1000 * t;
            delete(app);

            % (informational) switching to a source that was prepared in the background
            app2 = CellCurator('UseSettings', false, 'PrepareNext', true);
            tc.addTeardown(@() tCuratorGestures.closeApp(app2));
            app2.openParent(folder, '', 'ECM1');
            app2.waitForLayout();
            pause(4.5); drawnow;
            prepared = ~isempty(app2.Prepared) && app2.Prepared.Done;
            t1 = tic;
            app2.nextSource();
            drawnow;
            tPrepared = 1000 * toc(t1);

            fprintf('\n[curator-perf] ============ CellCurator budgets (ms, call -> drawnow returned) ============\n');
            fprintf('[curator-perf] %-44s %8s %8s %8s %8s  %s\n', 'action', 'median', 'p90', 'max', 'budget', 'verdict');
            names = ["LabelKey" "Enter" "SourceCold" "SourceBack"];
            what = ["label key -> border changed" "Enter -> next page shown" ...
                "switch to a source not opened yet" "switch back to an opened source"];
            for i = 1:numel(names)
                v = R.(names(i));
                b = tc.Budget.(names(i));
                verdict = "ok";
                if median(v) > b, verdict = "OVER BUDGET"; end
                fprintf('[curator-perf] %-44s %8.1f %8.1f %8.1f %8.0f  %s (n=%d)\n', what(i), median(v), ...
                    tCuratorGestures.p90(v), max(v), b, verdict, numel(v));
            end
            fprintf('[curator-perf] %-44s %8.1f %35s\n', 'switch to a source prepared in the background', ...
                tPrepared, sprintf('(prepared: %d)', prepared));
            fprintf('[curator-perf] ==========================================================================\n');
            for i = 1:numel(names)
                v = R.(names(i));
                tc.verifyLessThanOrEqual(median(v), tc.Budget.(names(i)), ...
                    sprintf('%s: median %.1f ms exceeds %g ms', what(i), median(v), tc.Budget.(names(i))));
            end
            tc.verifyLessThanOrEqual(max(R.SourceCold), tc.Budget.SourceCold, ...
                sprintf('the slowest switch to a new source took %.0f ms', max(R.SourceCold)));
        end
    end

    methods (Static)
        function [t, tCall, ok] = labelKeySeries(app, n, w)
            %labelKeySeries  N label keys (after W warm-up keys) on tiles of the page, each after the
            %   idle refresh of the last one: ms from the call until drawnow returned, and of the call.
            K = numel(app.Page.Ids);
            t = zeros(n + w, 1);
            tCall = zeros(n + w, 1);
            ok = true;
            C = curation.UiText.colors();
            for i = 1:n + w
                k = mod(7 * i, K) + 1;
                app.hoverTile(k);
                drawnow;
                pause(0.2);                      % the idle refresh of the last key has run
                drawnow;
                key = 'b';
                if app.Store.get('Label', app.Page.Ids(k)) == "Bad", key = 'x'; end
                t1 = tic;
                app.handleKey(key, {});
                tCall(i) = toc(t1);
                drawnow;
                t(i) = toc(t1);
                r = app.Gallery.Layout.Rect(k, :);
                px = double(squeeze(app.Gallery.Mosaic(r(2) + r(4) / 2, r(1), :)))';
                if key == 'b', ok = ok && isequal(px, C.Bad); end
            end
            t = 1000 * t(w + 1:end);
            tCall = 1000 * tCall(w + 1:end);
        end

        function printOpen(app, what)
            L = app.LastTimings;
            fprintf(['[curator-perf] open %s: %d detections; %.0f ms in openSourceAt = store %.0f + ' ...
                'images %.0f + crops %.0f + page/UI %.0f\n'], what, app.Store.counts().total, L.OpenSourceMs, ...
                L.StoreOpenMs, L.ImageReadMs, L.CacheBuildMs, ...
                L.OpenSourceMs - L.StoreOpenMs - L.ImageReadMs - L.CacheBuildMs);
        end
    end
end

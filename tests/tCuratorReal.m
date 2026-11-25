classdef (TestTags = {'Slow', 'RealData'}) tCuratorReal < matlab.unittest.TestCase
    %tCuratorReal  CellCurator on real sections, for the first time: three sections of two animals
    %   (WFA/PNN and PV, float32 projections of about 2816 x 2355 px at 1.657 um/px) from the local copy
    %   in %LOCALAPPDATA%\counting_perineuronal_nets\real_sections (skipped when it is absent). The
    %   folder is copied to a temporary one and only the copy is opened; the local master copy is
    %   checked to be unchanged (names, sizes, times) at the end.
    %
    %   Checks: the sections list (3 sections, 6 sources) and that every source opens; two full pages
    %   reviewed through the seams and checked in the store; the map with its reference strip; a source
    %   reviewed to its finish checklist. Measures (ms, call -> drawnow returned): folder open -> first
    %   page, every source open, label key -> border, Enter -> next page, source switch, first Map show
    %   and Gallery <-> Map. Saves screenshots for a person to look at:
    %   %LOCALAPPDATA%\counting_perineuronal_nets\test_logs\screens\curator_real_*.png
    %
    %   Run on the hidden desktop: tools\Run-Tests.ps1 -IncludeSlow tCuratorReal

    properties (Constant)
        Budget = struct('FirstOpen', 2000, 'Open', 1000, 'LabelKey', 30, 'Enter', 100, 'Toggle', 150)
    end

    properties
        Master
        Folder
        Cache
        Before
    end

    methods (TestClassSetup)
        function copyRealSections(tc)
            tc.Master = fullfile(getenv('LOCALAPPDATA'), 'counting_perineuronal_nets', 'real_sections');
            tc.assumeTrue(isfolder(tc.Master), 'no local copy of real sections here');
            tc.Before = tCuratorReal.listing(tc.Master);
            fx = tc.applyFixture(matlab.unittest.fixtures.TemporaryFolderFixture);
            tc.Folder = fullfile(fx.Folder, 'real_sections');
            tc.Cache = fullfile(fx.Folder, 'cache');
            t0 = tic;
            copyfile(tc.Master, tc.Folder);
            fprintf('\n[real] copied %d files (%.0f MB) to a temporary folder in %.1f s\n', height(tc.Before), ...
                sum(tc.Before.Bytes) / 1e6, toc(t0));
        end
    end

    methods (Static)
        function L = listing(folder)
            d = dir(fullfile(folder, '**', '*'));
            d = d(~[d.isdir]);
            rel = string(strrep(fullfile({d.folder}, {d.name}), [folder filesep], ''))';
            L = table(rel, [d.bytes]', [d.datenum]', 'VariableNames', {'File', 'Bytes', 'Time'});
            L = sortrows(L, 'File');
        end

        function closeApp(app)
            if ~isempty(app) && isvalid(app)
                delete(app);
            end
        end

        function d = screensDir()
            d = fullfile(getenv('LOCALAPPDATA'), 'counting_perineuronal_nets', 'test_logs', 'screens');
            if ~isfolder(d), mkdir(d); end
        end

        function saveScreen(fig, name)
            file = fullfile(tCuratorReal.screensDir(), name);
            drawnow;
            pause(0.8);
            drawnow;
            try
                exportapp(fig, file);
            catch
                F = getframe(fig);
                imwrite(F.cdata, file);
            end
            fprintf('[real] screenshot %s\n', file);
        end

        function v = p90(x)
            x = sort(x(:));
            v = x(max(1, ceil(0.9 * numel(x))));
        end

        function judgeBlind(app)
            %judgeBlind  Decide the audit tiles of the page on screen (Good), as a person would.
            P = app.Page;
            for k = find(P.Blind(:))'
                if app.Store.get('LabelSource', P.Ids(k)) ~= "blind"
                    app.hoverTile(k);
                    app.handleKey('g', {});
                end
            end
            app.hoverTile(0);
        end

        function px = border(app, k)
            r = app.Gallery.Layout.Rect(k, :);
            px = double(squeeze(app.Gallery.Mosaic(r(2) + round(r(4) / 2), r(1), :)))';
        end
    end

    methods (Test)
        function realSectionsInTheWindow(tc)
            R = struct();
            % the window waits for a folder first, as when a person chooses one (the warm-up runs)
            app = CellCurator('UseSettings', false, 'PrepareNext', true, 'AssistOptions', struct('CacheDir', tc.Cache));
            tc.addTeardown(@() tCuratorReal.closeApp(app));
            app.waitForLayout(6);
            pause(4);
            drawnow;
            t1 = tic;
            app.openParent(tc.Folder);
            drawnow;
            R.FirstOpen = 1000 * toc(t1);
            L = app.LastTimings;
            fprintf(['[real] folder open -> first page drawn: %.0f ms (openSourceAt %.0f = store %.0f + images %.0f + ' ...
                'crops %.0f + page/UI %.0f); window preload %.0f ms\n'], R.FirstOpen, L.OpenSourceMs, L.StoreOpenMs, ...
                L.ImageReadMs, L.CacheBuildMs, L.OpenSourceMs - L.StoreOpenMs - L.ImageReadMs - L.CacheBuildMs, L.PreloadMs);
            fprintf(['[real]   of which: display defaults %.0f, regions %.0f, roles (orphans, holdout) %.0f, ' ...
                'first page %.0f ms\n'], L.DisplayDefaultsMs, L.OpenRegionsMs, L.OpenRolesMs, L.OpenPageMs);
            app.waitForLayout();
            tc.assertEqual(app.Page.Kind, "active", app.StatusText);
            % the sections list: 3 sections, 6 sources
            tc.verifyNumElements(app.Datasets, 3, 'three sections');
            nSrc = sum(arrayfun(@(d) numel(d.Sources), app.Datasets));
            tc.verifyEqual(nSrc, 6, 'six sources');
            lb = findall(app.Figure, 'Tag', 'lb:sections');
            tc.verifyNumElements(lb.Items, 3);
            fprintf('[real] sections list: %s\n', strjoin(string(lb.Items), ' | '));
            dd = findall(app.Figure, 'Tag', 'dd:dataset');
            fprintf('[real] section dropdown: %s (width %d px)\n', string(dd.Value), dd.Position(3));
            % every source opens
            opens = [];
            for di = 1:numel(app.Datasets)
                d = app.Datasets(di);
                for si = 1:numel(d.Sources)
                    s = d.Sources(si);
                    pause(0.3); drawnow;
                    t1 = tic;
                    app.openSource(s.LocsPath);
                    drawnow;
                    ms = 1000 * toc(t1);
                    tc.verifyEqual(app.SourceKey, string(s.Key), app.StatusText);
                    tc.verifyEqual(app.Page.Kind, "active", sprintf('%s of %s opens: %s', s.Key, d.Base, app.StatusText));
                    c = app.Store.counts();
                    L = app.LastTimings;
                    fprintf(['[real] open %-4s of %s: %.0f ms (store %.0f, images %.0f, crops %.0f); %d detections, ' ...
                        '%d tiles per page; %s\n'], s.Key, d.Base, ms, L.StoreOpenMs, L.ImageReadMs, L.CacheBuildMs, ...
                        c.total, numel(app.Page.Ids), app.StatusText);
                    opens(end + 1, 1) = ms; %#ok<AGROW>
                end
            end
            R.Open = opens(2:end);
            % back to the first section's WFA channel
            d1 = app.Datasets(1);
            app.openSource(d1.Sources(strcmp({d1.Sources.Key}, 'ECM1')).LocsPath);
            tc.assertEqual(app.SourceKey, "ECM1");
            app.waitForLayout();
            app.waitForAssist(240);
            fprintf('[real] assist: %s | %s | %s\n', string(findall(app.Figure, 'Tag', 'lbl:assistSource').Text), ...
                string(findall(app.Figure, 'Tag', 'lbl:assistAccuracy').Text), ...
                string(findall(app.Figure, 'Tag', 'lbl:assistAgreement').Text));
            if ~isempty(app.Assist), fprintf('[real] runner: %s\n', app.Assist.LastError); end
            tc.showPage(app);
            tCuratorReal.saveScreen(app.Figure, 'curator_real_gallery_ecm.png');
            % two full pages reviewed through the seams
            st = app.Store;
            for pg = 1:2
                P = app.Page;
                o = find(~P.Blind);
                ex = o([1 min(3, numel(o))]);
                app.galleryClick(ex(1), 'normal');
                app.galleryClick(ex(2), 'alt');
                tCuratorReal.judgeBlind(app);
                app.handleKey('return', {});
                tc.verifyNotEqual(app.Page.PageId, P.PageId, 'the next page');
                opp = "Good";
                if P.Default == "Good", opp = "Bad"; end
                tc.verifyEqual(st.get('Label', P.Ids(ex(1))), opp);
                tc.verifyEqual(st.get('Label', P.Ids(ex(2))), "Uncertain");
                rest = setdiff(o, ex);
                tc.verifyTrue(all(st.get('Label', P.Ids(rest)) == P.Default), 'Enter labeled the rest');
                tc.verifyTrue(all(st.get('LabelSource', P.Ids(rest)) == "confirmed"));
                if any(P.Blind)
                    tc.verifyTrue(all(st.get('LabelSource', P.Ids(P.Blind)) == "blind"), 'audit tiles: blind');
                end
            end
            % label key -> border
            C = curation.UiText.colors();
            K = numel(app.Page.Ids);
            ord = find(~app.Page.Blind);
            t = zeros(24, 1);
            okc = true;
            for i = 1:numel(t)
                k = ord(mod(7 * i, numel(ord)) + 1);
                app.hoverTile(k);
                drawnow; pause(0.2); drawnow;
                key = 'b';
                if st.get('Label', app.Page.Ids(k)) == "Bad", key = 'x'; end
                t1 = tic;
                app.handleKey(key, {});
                drawnow;
                t(i) = 1000 * toc(t1);
                if key == 'b', okc = okc && isequal(tCuratorReal.border(app, k), C.Bad); end
            end
            R.LabelKey = t(5:end);
            tc.verifyTrue(okc, 'the border shows the label');
            for k = 1:K
                if st.get('Label', app.Page.Ids(k)) ~= "" && ~app.Page.Blind(k), app.hoverTile(k); app.handleKey('x', {}); end
            end
            % Enter -> next page (each page looked at first: the prefetch has run)
            t = NaN(8, 1);
            for i = 1:numel(t)
                pause(0.6); drawnow;
                if app.Page.Kind ~= "active", break; end
                tCuratorReal.judgeBlind(app);
                pause(0.3); drawnow;
                t1 = tic;
                app.handleKey('return', {});
                drawnow;
                t(i) = 1000 * toc(t1);
            end
            R.Enter = t(isfinite(t));
            % switching sources: PV2 of the same section and back
            t = zeros(6, 1);
            for i = 1:numel(t)
                pause(0.4); drawnow;
                if mod(i, 2), arrow = 'rightarrow'; else, arrow = 'leftarrow'; end
                t1 = tic;
                app.handleKey(arrow, {'control'});
                drawnow;
                t(i) = 1000 * toc(t1);
            end
            R.Switch = t;
            tc.verifyEqual(app.SourceKey, "ECM1");
            % the overlay
            app.handleKey('o', {});
            tc.showPage(app);
            tCuratorReal.saveScreen(app.Figure, 'curator_real_overlay.png');
            app.handleKey('o', {}); app.handleKey('o', {}); app.handleKey('o', {});
            tc.verifyEqual(app.DisplayMode, "target");
            % the PV channel
            app.handleKey('rightarrow', {'control'});
            tc.verifyEqual(app.SourceKey, "PV2");
            tc.showPage(app);
            tCuratorReal.saveScreen(app.Figure, 'curator_real_gallery_pv.png');
            app.handleKey('leftarrow', {'control'});
            % the map: first show, then Gallery <-> Map
            pause(CellCurator.PrepareIdleSec + 1); drawnow;
            busy = ~isempty(app.Assist) && app.Assist.isBusy();
            t1 = tic;
            app.handleKey('tab', {});
            drawnow;
            R.MapFirst = 1000 * toc(t1);
            L = app.LastTimings;
            fprintf(['[real] first Map show: %.0f ms (map made at the pause: %d; ensure+layout %.0f, load %.0f; ' ...
                'assist runner busy then: %d)\n'], R.MapFirst, ~isempty(app.Map), L.MapEnsureMs, L.MapLoadMs, busy);
            tc.assertEqual(app.CenterView, "map");
            pause(0.5); drawnow;
            kinds = string({app.Map.Regions.kind});
            tc.verifyTrue(any(kinds == "reference"), 'the reference strip is on the map');
            tc.verifyNotEmpty(app.Session.Reference, 'the ROI beside the image was read');
            tc.verifyTrue(any(isfinite(app.Map.ReferenceLine.XData)), 'and drawn');
            app.showRightTab('map');
            tCuratorReal.saveScreen(app.Figure, 'curator_real_map.png');
            app.showRightTab('inspector');
            t = zeros(10, 1);
            for i = 1:numel(t)
                pause(0.3); drawnow;
                t1 = tic;
                app.handleKey('tab', {});
                drawnow;
                t(i) = 1000 * toc(t1);
            end
            R.Toggle = t;
            tc.verifyEqual(app.CenterView, "map");
            app.handleKey('tab', {});
            % a source reviewed to its finish checklist (blind tiles judged on the way)
            for i = 1:200
                if app.Page.Kind ~= "active", break; end
                tCuratorReal.judgeBlind(app);
                app.handleKey('return', {});
            end
            tc.verifyEqual(app.Page.Kind, "empty", 'the review queue ran out');
            tc.verifyEqual(char(findall(app.Figure, 'Tag', 'pn:finish').Visible), 'on');
            tCuratorReal.saveScreen(app.Figure, 'curator_real_finish.png');
            fprintf('[real] finish: %s\n', app.ContextText);
            delete(app);

            fprintf('\n[real] ============ CellCurator on real sections (ms, call -> drawnow returned) ============\n');
            fprintf('[real] %-44s %8s %8s %8s %8s  %s\n', 'action', 'median', 'p90', 'max', 'budget', 'verdict');
            names = ["FirstOpen" "Open" "LabelKey" "Enter" "Switch" "MapFirst" "Toggle"];
            what = ["folder open -> first page (first of session)" "open a source (later ones)" ...
                "label key -> border" "Enter -> next page" "switch source (opened)" "first Map show" ...
                "Gallery <-> Map"];
            budget = [tc.Budget.FirstOpen tc.Budget.Open tc.Budget.LabelKey tc.Budget.Enter tc.Budget.Open 500 tc.Budget.Toggle];
            for i = 1:numel(names)
                v = R.(names(i));
                verdict = "ok";
                if median(v) > budget(i), verdict = "OVER BUDGET"; end
                fprintf('[real] %-44s %8.1f %8.1f %8.1f %8.0f  %s (n=%d)\n', what(i), median(v), tCuratorReal.p90(v), ...
                    max(v), budget(i), verdict, numel(v));
            end
            fprintf('[real] =========================================================================================\n');
            for i = 1:numel(names)
                tc.verifyLessThanOrEqual(median(R.(names(i))), budget(i), sprintf('%s: median %.1f ms over %g ms', ...
                    what(i), median(R.(names(i))), budget(i)));
            end
            % the local master copy is exactly as it was
            after = tCuratorReal.listing(tc.Master);
            tc.verifyEqual(after, tc.Before, 'the local master copy of the real sections is unchanged');
        end
    end

    methods
        function showPage(~, app)
            if app.CenterView ~= "gallery", app.showCenter("gallery"); end
            app.hoverTile(min(5, numel(app.Page.Ids)));
            pause(0.4);
            drawnow;
        end
    end
end

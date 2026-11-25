classdef tCuratorMarkers < matlab.unittest.TestCase
    %tCuratorMarkers  The map's markers (curation.MapMarkers, curation.MarkerDialog): the defaults
    %   (cells to review: filled blue squares; labeled cells: open circles), the Markers... window
    %   (every change shown on the map, the legend and the locator at once; OK keeps, Cancel / Esc /
    %   closing goes back), and the markers remembered between sessions (only the kept ones).
    %
    %   Run on the hidden desktop: tools\Run-Tests.ps1 tCuratorMarkers

    properties
        Folder
    end

    methods (TestMethodSetup)
        function makeFixture(tc)
            fx = tc.applyFixture(matlab.unittest.fixtures.TemporaryFolderFixture);
            tc.Folder = makeSyntheticDataset(fullfile(fx.Folder, 'ds'));
            tCuratorMarkers.clearPrefs();
            tc.addTeardown(@tCuratorMarkers.clearPrefs);
        end
    end

    methods
        function app = openApp(tc, useSettings, withFolder)
            if nargin < 2, useSettings = false; end
            if nargin < 3, withFolder = true; end
            app = CellCurator('UseSettings', useSettings, 'PrepareNext', false, 'Assist', false, ...
                'ConfirmAudit', false, 'WarmUp', false);
            tc.addTeardown(@() tCuratorMarkers.closeApp(app));
            if withFolder
                app.openParent(tc.Folder, '', 'ECM1');
                app.waitForLayout();
                tc.assertEqual(app.SourceKey, "ECM1", app.StatusText);
            end
        end
    end

    methods (Static)
        function closeApp(app)
            if ~isempty(app) && isvalid(app), delete(app); end
        end

        function clearPrefs()
            if ispref('CellCurator', 'Settings'), rmpref('CellCurator', 'Settings'); end
        end

        function idle()
            pause(0.4);
            drawnow;
        end

        function id = unreviewedCell(app)
            st = app.Store;
            ok = st.get('State') == "active" & st.get('Label') == "" & ~st.get('Excluded') & ...
                st.get('Flag') == "" & isfinite(st.get('X'));
            ids = st.get('CellID');
            id = ids(find(ok, 1));
        end

        function m = markerOf(v, id)
            %markerOf  The scatter Marker that draws point ID of map view V, and its face.
            %   Marker as the code ('o', 's', 'd', 'h', ...): MATLAB spells some out ('square').
            k = v.Layer(v.rowsOf(id));
            mk = char(v.Layers(k).Marker);
            long = struct('circle', 'o', 'square', 's', 'diamond', 'd', 'pentagram', 'p', 'hexagram', 'h');
            if isfield(long, mk), mk = long.(mk); end
            m = struct('Marker', mk, 'Face', char(string(v.Layers(k).MarkerFaceColor)));
        end

        function h = legendItem(app, name)
            h = findall(app.Figure, 'Tag', ['mapLegend:' name]);
        end

        function verifyLegend(tc, app, name, s)
            %verifyLegend  The map legend's swatch NAME is the picture of marker S.
            h = tCuratorMarkers.legendItem(app, name);
            tc.assertNumElements(h, 1, "legend item " + name);
            want = curation.MapMarkers.swatch(s, 255 * h.Parent.BackgroundColor, 18);
            tc.verifyEqual(h.ImageSource, want, "the legend draws the " + name + " marker");
        end
    end

    methods (Test)
        function defaultsAreFilledBlueSquaresForCellsToReview(tc)
            S = curation.MapMarkers.defaults();
            tc.verifyEqual(S.Unreviewed.Symbol, 's');
            tc.verifyTrue(S.Unreviewed.Filled);
            c = S.Unreviewed.Color;
            tc.verifyGreaterThan(c(3), max(c(1:2)) + 50, 'bluish');
            tc.verifyNotEqual(c, curation.UiText.colors().Selection, 'not the selection color');
            for k = ["Good" "Bad" "Uncertain" "Flagged"]
                tc.verifyEqual(S.(k).Symbol, 'o');
                tc.verifyFalse(S.(k).Filled, k + ": an open circle (the cell stays visible)");
            end
            [styles, layerOf] = curation.MapMarkers.layerStyles(S);
            tc.verifyNumElements(styles, 2, 'the four circles share one scatter');
            tc.verifyEqual(layerOf, [1 2 2 2 2]);

            app = tc.openApp();
            tc.verifyEqual(app.MarkerStyle, S);
            app.showCenter("map");
            m = app.Map;
            tc.verifyEqual(numel(m.Layers), 2);
            id = tCuratorMarkers.unreviewedCell(app);
            tc.verifyEqual(tCuratorMarkers.markerOf(m, id), struct('Marker', 's', 'Face', 'flat'));
            tc.verifyEqual(double(m.RGB(m.rowsOf(id), :)), S.Unreviewed.Color);
            % a label moves the point to the circles
            app.mapClick(m.XY(m.rowsOf(id), :));
            tc.assertEqual(app.MapSelection, id);
            app.handleKey('g', {});
            tc.assertEqual(app.Store.get('Label', id), "Good");
            tc.verifyEqual(tCuratorMarkers.markerOf(m, id), struct('Marker', 'o', 'Face', 'none'));
            tc.verifyEqual(double(m.RGB(m.rowsOf(id), :)), S.Good.Color);
            app.undo();
            tc.verifyEqual(tCuratorMarkers.markerOf(m, id).Marker, 's', 'undo: a square again');
            % the legend draws the markers
            tCuratorMarkers.verifyLegend(tc, app, 'unreviewed', S.Unreviewed);
            tCuratorMarkers.verifyLegend(tc, app, 'good', S.Good);
            img = tCuratorMarkers.legendItem(app, 'unreviewed').ImageSource;
            tc.verifyEqual(double(squeeze(img(9, 9, :)))', S.Unreviewed.Color, 'a filled square: its color inside');
            img = tCuratorMarkers.legendItem(app, 'good').ImageSource;
            tc.verifyEqual(double(squeeze(img(9, 9, :)))', curation.UiText.colors().Background, ...
                'an open circle: the background inside');
            % the swatches of the other symbols are pictures of the right size, never empty
            for code = string(curation.MapMarkers.SYMBOLS(:, 1))'
                for filled = [false true]
                    sw = curation.MapMarkers.swatch(struct('Symbol', code, 'Filled', filled, 'Color', [255 255 255]), [0 0 0], 18);
                    tc.verifySize(sw, [18 18 3]);
                    tc.verifyGreaterThan(nnz(sw(:, :, 1) > 128), 8, "the " + code + " marker is drawn");
                end
            end
        end

        function dialogShowsChangesAtOnceOkKeepsCancelGoesBack(tc)
            app = tc.openApp();
            app.showCenter("map");
            m = app.Map;
            S0 = app.MarkerStyle;
            id = tCuratorMarkers.unreviewedCell(app);
            d = app.openMarkerDialog();
            tc.assertNotEmpty(d);
            tc.verifySameHandle(app.MarkerDialog, d);
            tc.verifySameHandle(app.openMarkerDialog(), d, 'a second click brings the same window');
            % every control of the window has its own tooltip
            f = d.Figure;
            h = [findall(f, 'Type', 'uibutton'); findall(f, 'Type', 'uidropdown'); ...
                findall(f, 'Type', 'uicheckbox'); findall(f, 'Type', 'uicolorpicker')];
            tc.verifyEqual(numel(h), 3 + 3 * numel(curation.MapMarkers.CLASSES));
            tips = arrayfun(@(x) string(x.Tooltip), h);
            tc.verifyTrue(all(strlength(tips) > 10), 'every control has a tooltip');
            tc.verifyNumElements(unique(tips), numel(tips), 'no two share one');
            tc.verifySubstring(string(findall(app.Figure, 'Tag', 'btn:markers').Tooltip), 'remembered');
            tCuratorGestures.saveScreen(f, 'curator_markers_dialog.png');    % for a person to look at

            % changes show at once
            d.setSymbol("Unreviewed", 'd');
            d.setColor("Unreviewed", [255 0 255]);
            tc.verifyEqual(app.MarkerStyle.Unreviewed.Symbol, 'd');
            tc.verifyEqual(tCuratorMarkers.markerOf(m, id), struct('Marker', 'd', 'Face', 'flat'));
            tc.verifyEqual(double(m.RGB(m.rowsOf(id), :)), [255 0 255]);
            tCuratorMarkers.verifyLegend(tc, app, 'unreviewed', app.MarkerStyle.Unreviewed);
            tc.verifyEqual(findall(f, 'Tag', 'img:markerUnreviewed').ImageSource, ...
                curation.MarkerDialog.previewImage(app.MarkerStyle.Unreviewed), 'the window''s own preview');
            tCuratorGestures.saveScreen(app.Figure, 'curator_markers_preview.png');
            d.setFilled("Unreviewed", false);
            tc.verifyEqual(tCuratorMarkers.markerOf(m, id).Face, 'none');
            % a line symbol cannot be filled
            d.setSymbol("Flagged", 'x');
            cb = findall(f, 'Tag', 'cb:markerFlagged');
            tc.verifyFalse(logical(cb.Enable), 'x has no face to fill');
            % Cancel: back to the markers it was opened with, window gone
            d.cancel();
            tc.verifyEmpty(app.MarkerDialog);
            tc.verifyFalse(isvalid(f));
            tc.verifyEqual(app.MarkerStyle, S0);
            tc.verifyEqual(tCuratorMarkers.markerOf(m, id), struct('Marker', 's', 'Face', 'flat'));
            tc.verifyEqual(double(m.RGB(m.rowsOf(id), :)), S0.Unreviewed.Color);
            tCuratorMarkers.verifyLegend(tc, app, 'unreviewed', S0.Unreviewed);

            % Esc is Cancel too
            d = app.openMarkerDialog();
            d.setSymbol("Good", 'p');
            d.handleKey('escape');
            tc.verifyEqual(app.MarkerStyle, S0);

            % OK keeps them; Defaults (before OK) puts everything back
            d = app.openMarkerDialog();
            d.setColor("Bad", [10 20 30]);
            d.setSymbol("Bad", '^');
            d.resetDefaults();
            tc.verifyEqual(app.MarkerStyle, curation.MapMarkers.defaults());
            d.setSymbol("Bad", 'v');
            d.ok();
            tc.verifyEmpty(app.MarkerDialog);
            tc.verifyEqual(app.MarkerStyle.Bad.Symbol, 'v');
            tc.verifyEqual(numel(m.Layers), 3, 'a third style: a third scatter');
            % the window closes with the app
            d = app.openMarkerDialog();
            f = d.Figure;
            delete(app);
            tc.verifyFalse(isvalid(f), 'the markers window closes with Curator');
        end

        function locatorUsesTheMarkers(tc)
            app = tc.openApp();
            app.showRightTab("map");
            tCuratorMarkers.idle();
            L = app.Locator;
            tc.assertNotEmpty(L);
            id = tCuratorMarkers.unreviewedCell(app);
            tc.verifyEqual(tCuratorMarkers.markerOf(L, id).Marker, 's');
            d = app.openMarkerDialog();
            d.setSymbol("Unreviewed", 'h');
            tCuratorMarkers.idle();
            tc.verifyEqual(tCuratorMarkers.markerOf(L, id).Marker, 'h', 'the locator follows at once');
            d.ok();
        end

        function markersAreRememberedBetweenSessions(tc)
            app = tc.openApp(true, false);
            tc.verifyEqual(app.MarkerStyle, curation.MapMarkers.defaults(), 'no settings yet: the defaults');
            d = app.openMarkerDialog();
            d.setSymbol("Unreviewed", '^');
            d.setColor("Unreviewed", [10 20 200]);
            d.setFilled("Good", true);
            d.ok();
            delete(app);

            app = tc.openApp(true, false);
            S = app.MarkerStyle;
            tc.verifyEqual(S.Unreviewed.Symbol, '^');
            tc.verifyEqual(S.Unreviewed.Color, [10 20 200]);
            tc.verifyTrue(S.Good.Filled);
            tCuratorMarkers.verifyLegend(tc, app, 'unreviewed', S.Unreviewed);   % the legend starts with them
            % a change that was only previewed is not remembered, even when Curator closes meanwhile
            d = app.openMarkerDialog();
            d.setSymbol("Bad", 's');
            delete(app);
            app = tc.openApp(true, false);
            tc.verifyEqual(app.MarkerStyle.Bad.Symbol, 'o');
            tc.verifyEqual(app.MarkerStyle.Unreviewed.Symbol, '^');
            delete(app);

            % settings that are damaged fall back to the defaults, part by part
            st = getpref('CellCurator', 'Settings');
            st.MarkerStyles.Good = struct('Color', [999 0 0], 'Symbol', 'Z', 'Filled', 'yes');
            st.MarkerStyles.Bad.Color = [1 2 3];
            setpref('CellCurator', 'Settings', st);
            app = tc.openApp(true, false);
            D = curation.MapMarkers.defaults();
            tc.verifyEqual(app.MarkerStyle.Good, D.Good);
            tc.verifyEqual(app.MarkerStyle.Bad.Color, [1 2 3]);
            tc.verifyEqual(app.MarkerStyle.Unreviewed.Symbol, '^');
        end
    end
end

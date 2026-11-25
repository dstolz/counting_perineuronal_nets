classdef tManagerGestures < matlab.uitest.TestCase
    %tManagerGestures  Real matlab.uitest gestures on the Cell Dataset Manager (typing in Find, choosing
    %   in Show, choosing a table row, pressing buttons, checking the overlay) prove the wiring from
    %   real events to the window's seams, which tManagerGui tests directly. The key and double-click
    %   handlers, which uitest has no gesture for, are called with the event data MATLAB gives them.
    %
    %   Run on the hidden desktop: pwsh -File tools\Run-Tests.ps1 tManagerGestures

    properties
        Root
    end

    methods (TestClassSetup)
        function buildSections(tc)
            fx = tc.applyFixture(matlab.unittest.fixtures.TemporaryFolderFixture);
            tc.Root = fullfile(fx.Folder, 'HISTOLOGY');
            tc.applyFixture(matlab.unittest.fixtures.EnvironmentVariableFixture('CELLDB_PROVENANCE_DIR', ...
                fullfile(fx.Folder, 'no_provenance')));
            [~, ta] = tManagerScan.section(tc.Root, fullfile('SUBJ-ID-9001', 'A'), tManagerGui.A);
            [~, tb] = tManagerScan.section(tc.Root, fullfile('SUBJ-ID-9001', 'B'), tManagerGui.B);
            tManagerScan.section(tc.Root, fullfile('SUBJ-ID-9002', 'C'), tManagerGui.C);
            tManagerScan.curate(ta.paths.ecm1Locs, 6, 0, true);
            tManagerScan.curate(ta.paths.pv2Locs, 5, 0, true);
            tManagerScan.curate(tb.paths.pv2Locs, 3, 1, false);
        end
    end

    methods
        function [app, U] = open(tc)
            app = CellDatasetManager(tc.Root, 'UseSettings', false, 'Scan', 'now');
            tc.addTeardown(@() tManagerGui.closeApp(app));
            app.LaunchFcn = @(req) [];
            drawnow;
            f = app.Figure;
            btn = findall(f, 'Type', 'uibutton');
            dd = findall(f, 'Type', 'uidropdown');
            tbl = findall(f, 'Type', 'uitable');
            ef = findall(f, 'Type', 'uieditfield');
            byText = @(t) btn(startsWith(string({btn.Text}), t));
            U = struct( ...
                'Find', ef(arrayfun(@(e) contains(string(e.Tooltip), "every word"), ef)), ...
                'Show', dd(arrayfun(@(d) any(strcmp(d.Items, 'To curate')), dd)), ...
                'Color', dd(arrayfun(@(d) any(strcmp(d.Items, 'By class')), dd)), ...
                'Datasets', tbl(arrayfun(@(t) isequal(t.ColumnName(:)', CellDatasetManager.DATASET_COLUMNS), tbl)), ...
                'Sources', tbl(arrayfun(@(t) isequal(t.ColumnName(:)', CellDatasetManager.SOURCE_COLUMNS), tbl)), ...
                'Next', byText("Next to curate"), 'Curate', byText("Curate..."), ...
                'Detect', byText("Detect cells"), 'Scan', byText("Scan"), ...
                'Locations', findall(f, 'Type', 'uicheckbox'));
        end
    end

    methods (Test)
        function typingAndChoosingNarrowTheList(tc)
            [app, U] = tc.open();
            tc.assertNumElements(app.View, 3);
            tc.type(U.Find, '9002');
            tc.verifyNumElements(app.View, 1, 'typing in Find filters the list');
            tc.verifyEqual(string(app.Datasets(app.View).SubjectID), "SUBJ-ID-9002");
            tc.type(U.Find, '');
            tc.verifyNumElements(app.View, 3);
            tc.choose(U.Show, 'Curated');
            tc.verifyNumElements(app.View, 1, 'choosing in Show filters the list');
            tc.verifyEqual(string(app.Datasets(app.View).Base), tManagerGui.A + "_proj");
            tc.choose(U.Show, 'All datasets');
            tc.verifyNumElements(app.View, 3);
        end

        function aRowChosenInTheTableIsTheSelectedDataset(tc)
            [app, U] = tc.open();
            for row = [2 3 1]
                tc.choose(U.Datasets, [row 3]);
                tc.verifyEqual(app.SelectedDatasetIndex, app.View(row), sprintf('row %d', row));
                want = app.Datasets(app.View(row));
                tc.verifyEqual(size(U.Sources.Data, 1), numel(want.Sources), 'its sources are listed');
            end
            % a source row
            tc.choose(U.Datasets, [find(strcmp({app.Datasets(app.View).Base}, char(tManagerGui.B + "_proj"))) 3]);
            tc.choose(U.Sources, [2 1]);
            tc.verifyEqual(app.SelectedSourceRow, 2);
            tc.verifyEqual(app.selectedSource().Key, 'PV2');
            app.waitForIdle();
            tc.verifyNumElements(findall(app.Figure, 'Type', 'axes'), 2, 'the preview followed the selection');
        end

        function theButtonsDoWhatTheySay(tc)
            [app, U] = tc.open();
            tc.press(U.Next);
            d = app.selectedDataset();
            tc.assertNotEmpty(d, 'Next to curate selected a dataset');
            tc.verifyTrue(ismember(string(d.Base), [tManagerGui.B tManagerGui.C] + "_proj"));
            tc.press(U.Curate);
            tc.verifyEqual(app.LastLaunch.Tool, 'curator');
            tc.verifyEqual(string(app.LastLaunch.Base), string(d.Base));
            tc.verifyEqual(app.LastLaunch.Folder, tc.Root);
            tc.press(U.Detect);
            tc.verifyEqual(app.LastLaunch.Tool, 'discovery');
            tc.verifyEqual(app.LastLaunch.Folder, d.Folder);
            tc.press(U.Scan);
            tc.verifyEmpty(app.selectedDataset(), 'Scan read the folder again and cleared the selection');
            tc.verifySubstring(app.StatusText, '3 dataset(s)');
        end

        function tickingCellLocationsDrawsThem(tc)
            [app, U] = tc.open();
            app.selectDataset(tManagerGui.A + "_proj");
            app.waitForIdle();
            tc.verifyEmpty(findall(app.Figure, 'Type', 'scatter'));
            tc.verifyEqual(string(U.Color.Enable), "off");
            tc.choose(U.Locations);
            tc.verifyNotEmpty(findall(app.Figure, 'Type', 'scatter'), 'the overlay is drawn');
            tc.verifyEqual(string(U.Color.Enable), "on");
            tc.choose(U.Color, 'By rescore');
            sc = findall(app.Figure, 'Type', 'scatter');
            tc.verifyTrue(all(arrayfun(@(s) size(s.CData, 1) == numel(s.XData), sc)), 'one color per cell');
            tc.choose(U.Locations, false);
            tc.verifyEmpty(findall(app.Figure, 'Type', 'scatter'));
        end

        function thePreviewZoomsAtThePointerAndPans(tc)
            % uitest has no wheel gesture and cannot drag on axes: the figure's mouse handlers are
            % called with the pointer's tile and image point, as the class help describes.
            [app, U] = tc.open();
            app.selectDataset(tManagerGui.A + "_proj");
            app.waitForIdle();
            f = app.Figure;
            ax = findall(f, 'Type', 'axes');
            tc.assertNumElements(ax, 2);
            tc.verifyTrue(all(arrayfun(@(a) isempty(a.Toolbar), ax)), 'no axes toolbar on hover');
            full = app.previewLimits(1);
            W = [diff(full(1:2)) diff(full(3:4))];

            % the wheel zooms about the pointer, and the other page follows
            p = full([1 3]) + 0.25 * W;
            f.WindowScrollWheelFcn(f, struct('VerticalScrollCount', -2, 'Tile', 1, 'AxesPoint', p));
            L = app.previewLimits(1);
            tc.verifyEqual(diff(L(1:2)), W(1) / CellDatasetManager.PREVIEW_ZOOM_STEP ^ 2, ...
                'RelTol', 1e-9, 'two notches up zoom in');
            tc.verifyEqual((p - L([1 3])) ./ [diff(L(1:2)) diff(L(3:4))], [0.25 0.25], 'AbsTol', 1e-9, ...
                'the image point under the pointer stays under it');
            tc.verifyEqual(app.previewLimits(2), L, 'the pages zoom together');
            bar = findobj(app.Figure, 'Type', 'rectangle', 'FaceColor', [1 1 1]);
            tc.assertNotEmpty(bar, 'a scale bar');
            tc.verifyTrue(all(arrayfun(@(b) b.Position(1) >= L(1) && b.Position(1) <= L(2), bar)), ...
                'the scale bar is drawn again inside the zoomed view');

            % a drag pans: the pressed image point follows the pointer
            q = [mean(L(1:2)) mean(L(3:4))];
            f.WindowButtonDownFcn(f, struct('Tile', 1, 'AxesPoint', q, 'SelectionType', 'normal'));
            f.WindowButtonMotionFcn(f, struct('AxesPoint', q + [5 3]));
            f.WindowButtonUpFcn(f, struct());
            tc.verifyEqual(app.previewLimits(1) - L, [-5 -5 -3 -3], 'AbsTol', 1e-9);
            tc.verifyEqual(app.previewLimits(2), app.previewLimits(1), 'the pages pan together');
            f.WindowButtonMotionFcn(f, struct('AxesPoint', q + [50 50]));
            tc.verifyEqual(app.previewLimits(1) - L, [-5 -5 -3 -3], 'AbsTol', 1e-9, 'no pan after the release');

            % a pan stops at the edge; zooming out stops at the whole image
            f.WindowButtonDownFcn(f, struct('Tile', 1, 'AxesPoint', q, 'SelectionType', 'normal'));
            f.WindowButtonMotionFcn(f, struct('AxesPoint', q + 10 * W));
            f.WindowButtonUpFcn(f, struct());
            L = app.previewLimits(1);
            tc.verifyEqual(L([1 3]), full([1 3]), 'AbsTol', 1e-9, 'the view stays inside the image');
            f.WindowScrollWheelFcn(f, struct('VerticalScrollCount', 30, 'Tile', 1, 'AxesPoint', q));
            tc.verifyEqual(app.previewLimits(1), full, 'AbsTol', 1e-9);

            % the right-click menu fits; a double-click opens the page in its own window
            app.zoomPreview(1, -3);
            tc.verifyLessThan(diff(app.previewLimits(1)), diff(full(1:2)));
            a1 = ax(arrayfun(@(a) isequal([a.XLim a.YLim], app.previewLimits(1)), ax));
            fit = findobj(a1(1).ContextMenu, 'Text', 'Fit whole image');
            fit.MenuSelectedFcn(fit, []);
            tc.verifyEqual(app.previewLimits(1), full, 'AbsTol', 1e-9);
            before = findall(groot, 'Type', 'figure');
            f.WindowButtonDownFcn(f, struct('Tile', 2, 'AxesPoint', q, 'SelectionType', 'open'));
            opened = setdiff(findall(groot, 'Type', 'figure'), before);
            tc.addTeardown(@() delete(opened(isvalid(opened))));
            tc.verifyNumElements(opened, 1, 'a double-click opens the page');
            tc.verifySubstring(opened(1).Name, 'page 2/2');

            % the cell locations are filled circles
            tc.choose(U.Locations);
            sc = findall(f, 'Type', 'scatter');
            tc.assertNotEmpty(sc);
            tc.verifyEqual(unique(string({sc.Marker})), "o");
            tc.verifyEqual(unique(string({sc.MarkerFaceColor})), "flat");
        end

        function realWheelAndDragOnThePreview(tc)
            % The real path: the pointer's tile and point come from the figure and the axes.
            [app, ~] = tc.open();
            app.selectDataset(tManagerGui.A + "_proj");
            app.waitForIdle();
            full = app.previewLimits(1);
            ax = findall(app.Figure, 'Type', 'axes');
            a1 = ax(arrayfun(@(a) strcmp(a.Title.String, 'Page 1'), ax));
            W = [diff(full(1:2)) diff(full(3:4))];
            tc.scroll(a1, 'up');                       % uitest scrolls at the middle of the axes
            L = app.previewLimits(1);
            tc.verifyLessThan(diff(L(1:2)), W(1), 'the wheel zoomed in');
            tc.verifyEqual([mean(L(1:2)) mean(L(3:4))], [mean(full(1:2)) mean(full(3:4))], ...
                'AbsTol', 0.02 * W(1), 'about the pointer');
            tc.verifyEqual(app.previewLimits(2), L, 'the pages zoom together');
            q = [mean(L(1:2)) mean(L(3:4))];
            tc.drag(a1, q, q + [4 2]);
            L2 = app.previewLimits(1);
            tc.verifyEqual(L2 - L, [-4 -4 -2 -2], 'AbsTol', 1, 'the drag panned');
        end

        function keysAndDoubleClicksReachTheSeams(tc)
            % uitest has no gesture for a key press or a table double-click: the handlers are called
            % with the event data MATLAB passes them.
            [app, U] = tc.open();
            f = app.Figure;
            rowB = find(strcmp({app.Datasets(app.View).Base}, char(tManagerGui.B + "_proj")));
            U.Datasets.DoubleClickedFcn(U.Datasets, struct('InteractionInformation', struct('Row', rowB, 'Column', 3)));
            tc.verifyEqual(string(app.selectedDataset().Base), tManagerGui.B + "_proj", 'a double-click selects the row');
            tc.verifyEqual(app.LastLaunch.Tool, 'curator', 'and opens it');
            U.Sources.DoubleClickedFcn(U.Sources, struct('InteractionInformation', struct('Row', 2, 'Column', 1)));
            tc.verifyEqual(app.LastLaunch.Key, 'PV2', 'a double-click on a source opens that source');
            U.Datasets.DoubleClickedFcn(U.Datasets, struct('InteractionInformation', struct('Row', [], 'Column', [])));
            tc.verifyEqual(app.LastLaunch.Key, 'PV2', 'a double-click on a header does nothing');

            app.selectDataset(tManagerGui.C + "_proj");
            U.Datasets.KeyPressFcn(U.Datasets, struct('Key', 'return', 'Modifier', {{}}));
            tc.verifyEqual(string(app.LastLaunch.Base), tManagerGui.C + "_proj", 'Enter in the list opens the dataset');
            asked = app.LastLaunch;
            f.WindowKeyPressFcn(f, struct('Key', 'return', 'Modifier', {{}}));
            tc.verifyEqual(app.LastLaunch, asked, 'Enter elsewhere in the window (a text field) is not a launch');
            app.selectDataset(tManagerGui.A + "_proj");
            f.WindowKeyPressFcn(f, struct('Key', 'e', 'Modifier', {{'control'}}));
            tc.verifyNotEqual(string(app.selectedDataset().Base), tManagerGui.A + "_proj", 'Ctrl+E went to the next to curate');
            f.WindowKeyPressFcn(f, struct('Key', 'f5', 'Modifier', {{}}));
            tc.verifyEmpty(app.selectedDataset(), 'F5 scanned again');
        end
    end
end

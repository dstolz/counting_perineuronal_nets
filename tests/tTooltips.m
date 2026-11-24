classdef tTooltips < matlab.unittest.TestCase
    %tTooltips  CellCurator's wording: every interactive control has a tooltip (and a disabled one
    %   says why), buttons show their shortcut, every key of curation.UiText.keymap is in the cheat
    %   sheet and is handled by CellCurator.handleKey (no dead documentation), and no two controls
    %   share a tooltip.
    %
    %   Run on the hidden desktop: tools\Run-Tests.ps1 tTooltips

    properties (Constant)
        Interactive = ["matlab.ui.control.Button" "matlab.ui.control.StateButton" ...
            "matlab.ui.control.DropDown" "matlab.ui.control.CheckBox" "matlab.ui.control.Slider" ...
            "matlab.ui.control.Spinner" "matlab.ui.control.EditField" "matlab.ui.control.NumericEditField" ...
            "matlab.ui.control.ListBox" "matlab.ui.control.Table" "matlab.ui.container.Tab" ...
            "matlab.ui.control.TextArea" "matlab.ui.control.ToggleButton" "matlab.ui.control.RadioButton"]
    end

    properties
        Folder
    end

    methods (TestMethodSetup)
        function makeFixture(tc)
            fx = tc.applyFixture(matlab.unittest.fixtures.TemporaryFolderFixture);
            tc.Folder = makeSyntheticDataset(fullfile(fx.Folder, 'ds'));
        end
    end

    methods
        function app = openApp(tc, withFolder)
            app = CellCurator('UseSettings', false, 'PrepareNext', false, 'Assist', false, 'ConfirmAudit', false);
            tc.addTeardown(@() tTooltips.closeApp(app));
            if nargin < 2 || withFolder
                app.openParent(tc.Folder, '', 'ECM1');
                app.waitForLayout();
                pause(0.3);
                drawnow;
            end
        end
    end

    methods (Static)
        function closeApp(app)
            if ~isempty(app) && isvalid(app)
                delete(app);
            end
        end

        function [h, tips, names] = controls(app)
            %controls  Every interactive component of the window, its tooltip and a readable name.
            all = findall(app.Figure);
            keep = false(numel(all), 1);
            for i = 1:numel(all)
                keep(i) = any(class(all(i)) == tTooltips.Interactive);
            end
            h = all(keep);
            tips = strings(numel(h), 1);
            names = strings(numel(h), 1);
            for i = 1:numel(h)
                tips(i) = strjoin(string(h(i).Tooltip), " ");
                nm = string(class(h(i)));
                if isprop(h(i), 'Tag') && strlength(string(h(i).Tag)) > 0, nm = nm + " " + string(h(i).Tag); end
                if isprop(h(i), 'Text'), nm = nm + " '" + string(h(i).Text) + "'"; end
                if isprop(h(i), 'Title'), nm = nm + " '" + string(h(i).Title) + "'"; end
                names(i) = nm;
            end
        end
    end

    methods (Test)
        function everyInteractiveControlHasATooltip(tc)
            for withFolder = [false true]
                app = tc.openApp(withFolder);
                [h, tips, names] = tTooltips.controls(app);
                tc.verifyGreaterThan(numel(h), 20, 'the window has its controls');
                for i = 1:numel(h)
                    tc.verifyGreaterThan(strlength(strip(tips(i))), 10, names(i) + " has no tooltip");
                end
                delete(app);
            end
        end

        function disabledControlsSayWhy(tc)
            app = tc.openApp(false);
            undo = findall(app.Figure, 'Tag', 'btn:undo');
            tc.verifyFalse(logical(undo.Enable));
            tc.verifySubstring(undo.Tooltip, 'unavailable now: no source is open yet');
            good = findall(app.Figure, 'Tag', 'btn:good');
            tc.verifyFalse(logical(good.Enable));
            tc.verifySubstring(good.Tooltip, 'Label Good [g]');
            tc.verifySubstring(good.Tooltip, 'no source is open yet');
            delete(app);
            app = tc.openApp(true);
            undo = findall(app.Figure, 'Tag', 'btn:undo');
            tc.verifySubstring(undo.Tooltip, 'nothing to undo yet');
            app.galleryClick(1, 'normal');
            pause(0.3); drawnow;
            tc.verifyTrue(logical(undo.Enable));
            tc.verifyEqual(undo.Tooltip, curation.UiText.tip('undo'), 'enabled: the plain tooltip');
            tc.verifyTrue(logical(findall(app.Figure, 'Tag', 'btn:good').Enable));
        end

        function buttonsShowTheirShortcut(tc)
            app = tc.openApp(true);
            T = curation.UiText.keymap();
            alias = struct('openNext', "nextSource");
            b = [findall(app.Figure, 'Type', 'uibutton'); findall(app.Figure, 'Type', 'uistatebutton')];
            tc.verifyNotEmpty(b);
            nChecked = 0;
            for i = 1:numel(b)
                tag = string(b(i).Tag);
                if ~startsWith(tag, "btn:"), continue; end
                act = extractAfter(tag, "btn:");
                if isfield(alias, act), act = alias.(act); end
                rows = T(T.Action == act, :);
                if isempty(rows), continue; end
                shown = any(contains(string(b(i).Text), "[" + rows.Label + "]"));
                tc.verifyTrue(shown, sprintf('button "%s" (%s) should show its key: [%s]', b(i).Text, tag, ...
                    strjoin(rows.Label, "] or [")));
                nChecked = nChecked + 1;
            end
            tc.verifyGreaterThanOrEqual(nChecked, 12, 'the shortcut buttons were found');
            tc.verifyEqual(findall(app.Figure, 'Tag', 'btn:confirm').Text, 'Confirm page [Enter]');
            tc.verifyEqual(findall(app.Figure, 'Tag', 'btn:undo').Text, 'Undo [Ctrl+Z]');
        end

        function keymapIsInTheCheatSheetAndHandled(tc)
            T = curation.UiText.keymap();
            cheat = string(curation.UiText.cheatSheet());
            flat = regexprep(cheat, '\s+', ' ');      % descriptions wrap under themselves
            tc.verifyTrue(all(T.Modifier == "" | T.Modifier == "shift" | T.Modifier == "control"));
            for i = 1:height(T)
                tc.verifySubstring(cheat, "  " + T.Label(i) + " ", "cheat sheet lacks the key " + T.Label(i));
                tc.verifySubstring(flat, regexprep(T.Description(i), '\s+', ' '), ...
                    "cheat sheet lacks: " + T.Description(i));
            end
            tc.verifyLessThanOrEqual(max(strlength(splitlines(cheat))), 48, 'cheat sheet lines fit the panel');
            [~, ia] = unique(T.Key + "|" + T.Modifier);
            tc.verifyEqual(numel(ia), height(T), 'no key is mapped twice');
            app = tc.openApp(true);
            shown = string(findall(app.Figure, 'Tag', 'lbl:cheat').Text);
            tc.verifyEqual(strjoin(shown, newline), cheat, 'the window shows the same cheat sheet');
            for i = 1:height(T)
                mods = T.Modifier(i);
                if mods == "", mods = strings(1, 0); end
                handled = app.handleKey(T.Key(i), mods);
                tc.verifyTrue(handled, "handleKey ignores " + T.Label(i));
                if T.Key(i) == "c", app.handleKeyRelease("c"); end
            end
            % and the names MATLAB gives the punctuation keys map to the same actions
            for k = ["leftbracket" "rightbracket" "semicolon" "quote" "equal" "hyphen" "slash" "enter"]
                tc.verifyTrue(app.handleKey(k, strings(1, 0)), "handleKey ignores the key named " + k);
                if k == "slash", app.handleKey("escape", strings(1, 0)); end
            end
            tc.verifyFalse(app.handleKey("q", strings(1, 0)), 'an unmapped key does nothing');
        end

        function noTooltipIsShared(tc)
            app = tc.openApp(true);
            [h, tips, names] = tTooltips.controls(app);
            [u, ~, j] = unique(tips);
            for k = 1:numel(u)
                who = names(j == k);
                tc.verifyEqual(numel(who), 1, "these controls share a tooltip: " + strjoin(who, " | ") + ...
                    newline + "tooltip: " + u(k));
            end
            tc.verifyGreaterThan(numel(h), 20);
        end

        function mapControlsHaveTooltips(tc)
            % every control of the map (tool bar, action bars, locator) and of the finish checklist
            app = tc.openApp(true);
            app.showCentre("map");              % creates the map and its action bars
            app.showRightTab("map");            % and the locator
            app.showQueue('sweep');             % the sweep bar shows
            drawnow;
            [h, tips, names] = tTooltips.controls(app);
            for i = 1:numel(h)
                tc.verifyGreaterThan(strlength(strip(tips(i))), 10, names(i) + " has no tooltip");
            end
            [u, ~, j] = unique(tips);
            for k = 1:numel(u)
                who = names(j == k);
                tc.verifyEqual(numel(who), 1, "these controls share a tooltip: " + strjoin(who, " | "));
            end
            want = struct( ...
                'btn_toggleView', "[Tab]", 'btn_showOnMap', "[.]", 'btn_toolSelect', "[s]", 'btn_toolAdd', "[a]", ...
                'btn_toolMove', "[m]", 'btn_toolLasso', "[l]", 'cb_snap', "snapToCellCentroid", ...
                'btn_fitMap', "whole section", 'btn_lassoGood', "[g]", 'btn_lassoBad', "[b]", ...
                'btn_lassoUncertain', "[u]", 'btn_lassoExclude', "[e]", 'btn_lassoMerge', "[j]", ...
                'btn_lassoCancel', "[Esc]", 'btn_regionRemove', "[Del]", 'btn_regionKeep', "[Esc]", ...
                'btn_pairAccept', "[Enter]", 'btn_pairOther', "[k]", 'btn_pairSkip', "[" + curation.UiText.RIGHT + "]", ...
                'btn_pairBack', "[" + curation.UiText.LEFT + "]", 'btn_sweepPrev', "[Backspace]", ...
                'btn_sweepNext', "[Space]", 'ef_sweepWidth', "micrometres", 'btn_finishFlagged', "Flagged", ...
                'btn_finishPairs', "close pairs", 'btn_finishVanished', "Vanished good", ...
                'btn_finishSweep', "only needed if this section will be used to train the detector", ...
                'btn_finishComplete', "[Enter]", 'btn_finishNext', "[n]", 'tab_map', "Click a place");
            for f = string(fieldnames(want))'
                tag = regexprep(f, '_', ':', 'once');
                c = findall(app.Figure, 'Tag', tag);
                tc.assertNotEmpty(c, "no control " + tag);
                tc.verifySubstring(lower(strjoin(string(c(1).Tooltip), " ")), lower(want.(f)), ...
                    "the tooltip of " + tag + " should mention " + want.(f));
            end
            % the new keys are mapped, and in the cheat sheet (keymapIsInTheCheatSheetAndHandled
            % checks that every mapped key is handled)
            T = curation.UiText.keymap();
            for k = ["tab" "v" "." "s" "a" "m" "l" "e" "j" "k" "delete"]
                tc.verifyTrue(any(T.Key == k & T.Modifier == ""), "the key map lacks " + k);
            end
            delete(app);
            % without a source the map controls are off and say why
            app = tc.openApp(false);
            for tag = ["btn:toolSelect" "btn:toolAdd" "btn:toggleView" "btn:showOnMap" "cb:snap"]
                c = findall(app.Figure, 'Tag', tag);
                tc.verifyFalse(logical(c.Enable), tag + " should be off without a source");
                tc.verifySubstring(c.Tooltip, 'unavailable now: no source is open yet');
            end
        end

        function assistAuditAndDatabaseControls(tc)
            % the controls of integration pass B: the Assist block, the audit report, the audit row of
            % the finish checklist, the lab database at the right end of the status bar
            app = tc.openApp(true);
            want = struct('btn_auditReport', "audit tab", 'btn_saveReport', "unavailable now", ...
                'tab_audit', "blind audit tiles", 'ta_audit', "save report", 'lbl_assistSource', "200 labels", ...
                'lbl_assistAccuracy', "out-of-fold auc", 'lbl_assistAgreement', "audit tiles only", ...
                'btn_finishAudit', "grey border");
            for f = string(fieldnames(want))'
                tag = regexprep(f, '_', ':', 'once');
                c = findall(app.Figure, 'Tag', tag);
                tc.assertNotEmpty(c, "no control " + tag);
                tc.verifySubstring(lower(strjoin(string(c(1).Tooltip), " ")), lower(want.(f)), ...
                    "the tooltip of " + tag + " should mention " + want.(f));
            end
            tc.verifyEqual(findall(app.Figure, 'Tag', 'btn:auditReport').Text, curation.UiText.label('auditReport'));
            if ~isempty(which('celldb.addLamp'))
                db = findall(app.Figure, 'Tag', 'btn:database');
                tc.assertNotEmpty(db, 'a Database... button in the status bar');
                tc.verifySubstring(lower(db.Tooltip), 'lab database');
                sb = findall(app.Figure, 'Tag', 'gl:status');
                tc.verifyGreaterThanOrEqual(numel(sb.Children), 3, 'and the lamp beside it');
            end
            % blind tiles: their colour is in the legend
            C = curation.UiText.colors();
            sw = findall(app.Figure, 'Tag', 'legend:blind:1');
            tc.assertNumElements(sw, 1);
            tc.verifyEqual(round(255 * sw.BorderColor), C.Blind);
            tc.verifyEqual(curation.UiText.bandLabel('blind'), 'Blind tiles', 'the band "blind" has a name');
        end

        function passCControlsAndKeys(tc)
            % integration pass C: the rescore controls, the Training button and tab (every control of
            % the tab), the reset-display key; the Database button's message without the client
            app = tc.openApp(true);
            app.showTraining();
            drawnow;
            want = struct('btn_training', "training tab", 'btn_rescoreEdited', "added or moved", ...
                'btn_finishRescore', "_final.csv carries it", 'tab_training', "exports", ...
                'btn_trainExport2', "empty folder", 'btn_trainExport1', "complete and swept", ...
                'btn_trainExportObs', "observation format", 'ta_trainSummary', "assumed", ...
                'btn_trainFineTune', "fine-tunes the shipped ordinal scorer", 'lbl_trainState', "fine-tune", ...
                'ta_trainLog', "curation_trainer.log", 'btn_trainCopyCmd', "clipboard", ...
                'ta_trainCommand', "paste it", 'sl_gain', "0 back to the default", 'sl_gamma', "0 back to the default");
            for f = string(fieldnames(want))'
                tag = regexprep(f, '_', ':', 'once');
                c = findall(app.Figure, 'Tag', tag);
                tc.assertNotEmpty(c, "no control " + tag);
                tc.verifySubstring(lower(strjoin(string(c(1).Tooltip), " ")), lower(want.(f)), ...
                    "the tooltip of " + tag + " should mention " + want.(f));
            end
            % the rescore tooltips name the scorer and say why the score matters
            t = string(findall(app.Figure, 'Tag', 'btn:finishRescore').Tooltip);
            tc.verifySubstring(t, 'ordinal');
            tc.verifySubstring(t, 'Optional');
            tc.verifySubstring(t, 'proposals and the assist model');
            % the training tab says what a fine-tuned scorer does to rescore
            tc.verifySubstring(string(findall(app.Figure, 'Tag', 'lbl:trainMeaning').Text), 'changes the meaning of rescore');
            % the reset-display key
            T = curation.UiText.keymap();
            tc.verifyTrue(any(T.Key == "0" & T.Action == "resetDisplay"));
            tc.verifySubstring(string(curation.UiText.cheatSheet()), "  0 ");
            app.handleKey(']', {});
            tc.verifyGreaterThan(app.Gain, 1);
            tc.verifyTrue(app.handleKey('0', {}));
            tc.verifyEqual([app.Gain app.Gamma], [1 1], 'back to the default of the source');
            tc.verifySubstring(char(app.StatusText), 'default of');
            % the Database... button: without the client the reason is in the status bar, no dialog
            db = findall(app.Figure, 'Tag', 'btn:database');
            if ~isempty(db) && ~celldb.available()
                db.ButtonPushedFcn(db, []);
                drawnow;
                tc.verifySubstring(char(app.StatusText), 'lab database client is not here', ...
                    'the reason in the status bar (celldb.openWindow would show a uialert)');
            end
        end

        function noAutoRejectWordingOrQueue(tc)
            % the app never rejects a detection unseen: no queue, legend, label or tooltip says so
            tc.verifyFalse(any(CellCurator.QUEUES == "browseAuto"), 'no auto-rejected queue');
            app = tc.openApp(true);
            app.showCentre("map");
            app.showRightTab("audit");
            drawnow;
            all = findall(app.Figure);
            words = strings(0, 1);
            for i = 1:numel(all)
                for p = ["Text" "Tooltip" "Items" "Title" "Value"]
                    if isprop(all(i), p)
                        v = all(i).(p);
                        if ischar(v) || isstring(v) || iscellstr(v), words = [words; string(v(:))]; end %#ok<AGROW>
                    end
                end
            end
            words = [words; string(curation.UiText.cheatSheet()); string({curation.UiText.legendItems().Text})'; ...
                string({curation.UiText.mapLegendItems().Text})'];
            bad = words(~cellfun(@isempty, regexpi(cellstr(words), 'auto[- ]?reject|rejected (unseen|automatically)', 'once')));
            tc.verifyEmpty(bad, "auto-reject wording: " + strjoin(bad, " | "));
            tc.verifyFalse(isfield(curation.UiText.colors(), 'AutoRejected'));
        end

        function cheatSheetScrolls(tc)
            % the cheat sheet is longer than the panel: its grid scrolls, and the text row is as tall
            % as the text, so the last line can be reached
            app = tc.openApp(false);
            g = findall(app.Figure, 'Tag', 'gl:cheat');
            tc.assertNumElements(g, 1);
            tc.verifyEqual(char(g.Scrollable), 'on');
            n = numel(splitlines(string(curation.UiText.cheatSheet())));
            tc.verifyGreaterThanOrEqual(g.RowHeight{2}, 12 * n, 'the text row holds every line');
        end

        function legendMatchesTheTileColours(tc)
            % the legend's swatches are drawn in the colours the tiles use (curation.UiText.colors;
            % tCuratorGestures checks the tile borders against the same values)
            C = curation.UiText.colors();
            app = tc.openApp(false);
            want = struct('good', C.Good, 'bad', C.Bad, 'uncertain', C.Uncertain, ...
                'proposed', [C.ProposedGood; C.ProposedBad], 'blind', C.Blind, 'cursor', C.Cursor, ...
                'selection', C.Selection);
            for f = string(fieldnames(want))'
                cols = want.(f);
                for j = 1:size(cols, 1)
                    sw = findall(app.Figure, 'Tag', sprintf('legend:%s:%d', f, j));
                    tc.assertNumElements(sw, 1, "legend swatch " + f);
                    tc.verifyEqual(round(255 * sw.BorderColor), cols(j, :), "legend colour of " + f);
                end
            end
            badge = findall(app.Figure, 'Tag', 'legend:flag:1:badge');
            tc.assertNumElements(badge, 1);
            tc.verifyEqual(round(255 * badge.BackgroundColor), C.Flag, 'legend colour of the flag badge');
            items = curation.UiText.legendItems();
            tc.verifyEqual(numel(items), 8);
            tc.verifyEqual(C.Good, [0 158 115]);
            tc.verifyEqual(C.Bad, [213 94 0]);
            tc.verifyEqual(C.Uncertain, [240 228 66]);
            tc.verifyEqual(C.Flag, [204 121 167]);
            tc.verifyEqual(C.Blind, [140 140 140]);
            tc.verifyFalse(isfield(C, 'AutoRejected'), 'no auto-reject colour: the app never rejects unseen');
            tc.verifyEqual(C.Cursor, [255 255 255]);
            tc.verifyEqual(C.Selection, [86 180 233]);
        end
    end
end

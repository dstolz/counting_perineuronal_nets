classdef tCuratorBlind < matlab.unittest.TestCase
    %tCuratorBlind  Audit (blind) tiles in CellCurator, through its seams and the store: a blind tile
    %   wears the neutral border, never gets the page default, holds the page until it is decided with
    %   g/b/u (LabelSource "blind"), hides its scores in the inspector, survives undo/redo; the confirm
    %   audit comes back as blind pages after the ordinary queue runs out and gates completion; the
    %   holdout list is written once per project, applied to a source when it opens, kept off the page
    %   on screen, and is no undo step. A confirm audit drawn between pages is no undo step either;
    %   undoing the confirmations it was drawn from clears its roles (no orphan audit tile).
    %
    %   Run on the hidden desktop: tools\Run-Tests.ps1 tCuratorBlind

    properties
        Folder
        Truth
    end

    methods (TestMethodSetup)
        function makeFixture(tc)
            fx = tc.applyFixture(matlab.unittest.fixtures.TemporaryFolderFixture);
            [tc.Folder, tc.Truth] = makeSyntheticDataset(fullfile(fx.Folder, 'ds'), 'Variants', false);
        end
    end

    methods
        function app = openApp(tc, varargin)
            app = CellCurator('UseSettings', false, 'PrepareNext', false, 'Assist', false, ...
                'ConfirmAudit', false, varargin{:});
            tc.addTeardown(@() tCuratorBlind.closeApp(app));
            app.openParent(tc.Folder, '', 'ECM1');
            app.waitForLayout();
            tc.assertEqual(app.Page.Kind, "active", app.StatusText);
        end
    end

    methods (Static)
        function closeApp(app)
            if ~isempty(app) && isvalid(app)
                delete(app);
            end
        end

        function px = border(app, k)
            %border  The color of tile K's left border in the shown mosaic.
            r = app.Gallery.Layout.Rect(k, :);
            px = double(squeeze(app.Gallery.Mosaic(r(2) + round(r(4) / 2), r(1), :)))';
        end

        function s = opposite(label)
            if label == "Good", s = "Bad"; else, s = "Good"; end
        end

        function makeHoldout(app, n)
            %makeHoldout  Give N unreviewed rows from the END of the review queue the role holdout and
            %   show the review again (blind tiles are front-loaded: they come on page 1).
            st = app.Store;
            ids = st.get('CellID');
            free = ids(st.get('State') == "active" & ~st.get('Reviewed') & st.get('Label') == "");
            pick = free(end - n + 1:end);
            st.setAuditRole(pick, "holdout");
            app.showQueue('review');
        end
    end

    methods (Test)
        function blindTilesNeverGetTheDefaultAndHoldThePage(tc)
            app = tc.openApp();
            st = app.Store;
            C = curation.UiText.colors();
            tCuratorBlind.makeHoldout(app, 4);
            P = app.Page;
            tc.assertEqual(P.Kind, "active");
            b = find(P.Blind);
            tc.assertEqual(numel(b), 4, 'the blind tiles are on the first page');
            o = find(~P.Blind);
            tc.verifyEqual(st.get('AuditRole', P.Ids(b)), repmat("holdout", 4, 1));
            % neutral border, not the default's; not untouched; the context line says what they need
            tc.verifyEqual(tCuratorBlind.border(app, b(1)), C.Blind, 'a blind tile wears the neutral gray');
            tc.verifyNotEqual(tCuratorBlind.border(app, o(1)), C.Blind);
            tc.verifyEqual(nnz(app.Page.Untouched), numel(o), 'blind tiles are not untouched tiles');
            tc.verifySubstring(char(app.ContextText), sprintf('Enter: mark the %d untouched', numel(o)));
            tc.verifySubstring(char(app.ContextText), 'and 4 audit tiles (gray border) need g, b or u');
            % the P range shown is the ordinary tiles' only
            Po = P.P(~P.Blind);
            tc.verifySubstring(char(app.ContextText), sprintf('P %.2f', min(Po)));
            % the inspector hides the scores of a waiting blind tile
            app.hoverTile(b(1));
            pause(0.3); drawnow;
            f = string(findall(app.Figure, 'Tag', 'lbl:fields').Text);
            tc.verifySubstring(f, 'audit tile');
            tc.verifyEmpty(regexp(f, '(score|P\(Good\))\s+-?[\d.]', 'once'), 'no score, rescore or P');
            % a left click does not decide it; x has nothing to clear; a drag passes over it
            app.galleryClick(b(1), 'normal');
            tc.verifyEqual(st.get('Label', P.Ids(b(1))), "", 'a click does not cycle a blind tile');
            tc.verifyEqual(app.Cursor, b(1), 'it puts the cursor on it');
            tc.verifySubstring(char(app.StatusText), 'Audit tile: press g, b or u');
            app.handleKey('x', {});
            tc.verifySubstring(char(app.StatusText), 'nothing to clear');
            % Enter: the default goes to the ordinary untouched tiles only; the page stays
            app.hoverTile(0);
            app.handleKey('return', {});
            tc.verifyTrue(all(st.get('Label', P.Ids(o)) == P.Default));
            tc.verifyTrue(all(st.get('LabelSource', P.Ids(o)) == "confirmed"));
            tc.verifyEqual(st.get('Label', P.Ids(b)), repmat("", 4, 1), 'blind tiles never get the default');
            tc.verifyEqual(app.Page.PageId, P.PageId, 'the page stays while a blind tile is undecided');
            tc.verifyEqual(app.Cursor, b(1), 'the cursor goes to the first one');
            tc.verifySubstring(char(app.StatusText), '4 audit tiles (gray border) still need g, b or u');
            tc.verifySubstring(char(app.ContextText), '4 audit tiles (gray border) need g, b or u before the next page');
            % decide them: keys, a label button, a right-click; LabelSource blind, no ProposalP
            app.hoverTile(b(1)); app.handleKey('b', {});
            app.hoverTile(b(2)); app.handleKey('g', {});
            app.hoverTile(0);
            app.galleryClick(b(3), 'alt');
            tc.verifyEqual(st.get('Label', P.Ids(b(1:3))), ["Bad"; "Good"; "Uncertain"]);
            tc.verifyEqual(st.get('LabelSource', P.Ids(b(1:3))), repmat("blind", 3, 1));
            tc.verifyTrue(all(isnan(st.get('ProposalP', P.Ids(b(1:3))))), 'no proposal was shown');
            tc.verifyEqual(tCuratorBlind.border(app, b(1)), C.Bad, 'decided: its label color');
            app.handleKey('return', {});
            tc.verifyEqual(app.Page.PageId, P.PageId, 'one is still undecided');
            app.hoverTile(b(4)); app.handleKey('u', {});
            app.hoverTile(0);
            % undo and redo restore a blind decision like any other
            app.handleKey('z', {'control'});
            tc.verifyEqual(st.get('LabelSource', P.Ids(b(4))), "", 'undo: waiting again');
            tc.verifyEqual(tCuratorBlind.border(app, b(4)), C.Blind);
            app.handleKey('y', {'control'});
            tc.verifyEqual(st.get('LabelSource', P.Ids(b(4))), "blind", 'redo: decided blind again');
            tc.verifyEqual(st.get('Label', P.Ids(b(4))), "Uncertain");
            app.handleKey('return', {});
            tc.verifyNotEqual(app.Page.PageId, P.PageId, 'all decided: Enter moves on');
            % the journal holds the blind decisions
            R = curation.Journal.read(st.Paths.journal, 0);
            hit = R.Field == "LabelSource" & R.New == "blind";
            tc.verifyGreaterThanOrEqual(nnz(hit), 4);
        end

        function dragAndBrowseLeaveBlindTilesAlone(tc)
            app = tc.openApp();
            st = app.Store;
            tCuratorBlind.makeHoldout(app, 3);
            P = app.Page;
            b = find(P.Blind, 1);
            tc.assumeGreaterThan(b, 1, 'a blind tile after the first tile');
            g = app.Gallery;
            g.onButtonDown(struct('AxesPoint', g.tileCenter(1), 'SelectionType', 'normal'));
            for k = 2:b
                g.onMotion(struct('AxesPoint', g.tileCenter(k)));
            end
            g.onButtonUp(struct('AxesPoint', g.tileCenter(b)));
            tc.verifyEqual(st.get('Label', P.Ids(b)), "", 'a drag never decides a blind tile');
            tc.verifyEqual(st.get('Label', P.Ids(1)), tCuratorBlind.opposite(P.Default));
            % the Browse queues never show a waiting confirm-audit tile (its label would show)
            ids = st.get('CellID');
            st.setLabel(ids(end - 30:end - 21), "Good", "confirmed");
            st.setAuditRole(ids(end - 30:end - 26), "confirm-audit");
            app.showQueue('browseGood');
            tc.verifyEmpty(intersect(app.Page.Ids, ids(end - 30:end - 26)), 'waiting audit tiles are not browsed');
            tc.verifyNotEmpty(intersect(app.Page.Ids, ids(end - 25:end - 21)));
        end

        function confirmAuditComesBackBlindAndGatesCompletion(tc)
            app = tc.openApp('ConfirmAudit', true);
            st = app.Store;
            C = curation.UiText.colors();
            for k = 1:100
                if app.Page.Kind ~= "active" || app.Page.Band == "blind", break; end
                last = app.Page;
                app.handleKey('return', {});
            end
            tc.assertEqual(app.Page.Band, "blind", 'blind pages follow the last ordinary page');
            ids = st.get('CellID');
            role = st.get('AuditRole');
            a = ids(role == "confirm-audit");
            nConf = nnz(st.get('LabelSource') == "confirmed" | role == "confirm-audit");
            tc.verifyEqual(numel(a), max(5, ceil(0.02 * nConf)), '2% of the confirmed tiles, at least 5');
            tc.verifyEqual(sort(app.Page.Ids), sort(a), 'they are the blind page');
            tc.verifyEqual(app.Page.Default, "", 'a blind page has no default');
            tc.verifySubstring(char(app.ContextText), 'Blind tiles');
            tc.verifySubstring(char(app.ContextText), 'judge each tile: g, b or u');
            tc.verifyEqual(tCuratorBlind.border(app, 1), C.Blind, 'the earlier label does not show');
            confirmedAs = st.get('Label', app.Page.Ids);
            tc.verifyTrue(all(confirmedAs ~= ""), 'each still carries the label it was confirmed with');
            % the confirm and the audit draw are one undo step
            app.handleKey('z', {'control'});
            tc.verifyEqual(nnz(st.get('AuditRole') == "confirm-audit"), 0, 'undo takes the audit draw back too');
            tc.verifyEqual(app.Page.PageId, last.PageId, 'and brings the last ordinary page back');
            app.handleKey('y', {'control'});
            tc.verifyEqual(nnz(st.get('AuditRole') == "confirm-audit"), numel(a));
            tc.verifyEqual(app.Page.Band, "blind");
            % completion waits for them
            app.markComplete();
            tc.verifyFalse(logical(st.Meta.Complete));
            tc.verifySubstring(char(app.StatusText), 'to judge');
            % judge them: the first one against its confirmed label
            P = app.Page;
            for k = 1:numel(P.Ids)
                app.hoverTile(k);
                if k == 1
                    app.handleKey(lower(extractBefore(tCuratorBlind.opposite(confirmedAs(1)), 2)), {});
                else
                    app.handleKey(lower(extractBefore(confirmedAs(k), 2)), {});
                end
            end
            app.hoverTile(0);
            tc.verifyEqual(st.get('LabelSource', P.Ids), repmat("blind", numel(P.Ids), 1));
            tc.verifyEqual(st.get('Label', P.Ids(1)), tCuratorBlind.opposite(confirmedAs(1)), 'the blind decision replaces it');
            R = curation.Journal.read(st.Paths.journal, 0);
            hit = R.CellID == string(P.Ids(1)) & R.Field == "Label" & R.Old == confirmedAs(1);
            tc.verifyTrue(any(hit), 'the confirmed label stays recoverable from the journal');
            app.handleKey('return', {});
            tc.verifyEqual(app.Page.Kind, "empty", 'then the finish checklist');
            pause(0.3); drawnow;
            fa = findall(app.Figure, 'Tag', 'btn:finishAudit');
            tc.verifySubstring(fa.Text, 'Audit tiles to judge: 0');
            tc.verifySubstring(fa.Text, 'nothing to do');
            tc.verifyTrue(logical(fa.Enable), 'a satisfied row stays readable (not a grayed-out button)');
            tc.verifyGreaterThan(mean(fa.FontColor), 0.8, 'light text');
            tc.verifyLessThan(mean(fa.BackgroundColor), 0.4, 'on the dark "done" color');
            % drawn once per source
            tc.verifyEqual(nnz(st.get('AuditRole') == "confirm-audit"), numel(a));
        end
    end

    methods (Test)
        function idleConfirmAuditIsNoUndoStepAndLeavesNoOrphans(tc)
            % (pass C, 3a) the queue runs out without an Enter (the last tiles labeled by hand): the
            % confirm audit is drawn between pages with the store's system form. Ctrl+Z undoes the
            % reviewer's own last label, never the draw; undoing the confirmations it was drawn from
            % clears those roles, so no unconfirmed row is ever shown as a confirm-audit tile.
            app = tc.openApp('ConfirmAudit', true);
            st = app.Store;
            for guard = 1:50
                P = app.Page;
                if P.Kind ~= "active", break; end
                left = nnz(st.get('State') == "active" & ~st.get('Reviewed') & st.get('Label') == "" & ...
                    st.get('Flag') == "" & st.get('AuditRole') == "");
                if left > numel(P.Ids)
                    app.handleKey('return', {});
                    continue
                end
                key = lower(extractBefore(P.Default, 2));
                for k = 1:numel(P.Ids)
                    app.hoverTile(k);
                    app.handleKey(char(key), {});
                end
                break
            end
            t0 = tic;
            while toc(t0) < 5 && ~any(st.get('AuditRole') == "confirm-audit")
                pause(0.2); drawnow;
            end
            drawn = st.get('CellID');
            drawn = drawn(st.get('AuditRole') == "confirm-audit");
            tc.assertNotEmpty(drawn, 'the confirm audit was drawn between pages');
            lastId = P.Ids(end);
            app.hoverTile(0);
            app.handleKey('z', {'control'});
            tc.verifyEqual(st.get('Label', lastId), "", 'Ctrl+Z undid the last label');
            tc.verifyEqual(nnz(st.get('AuditRole') == "confirm-audit"), numel(drawn), 'the draw is no undo step');
            for i = 1:200
                if ~st.CanUndo, break; end
                app.handleKey('z', {'control'});
                tc.verifyEmpty(curation.BlindTiles.orphanConfirmAudit(st.T), 'no orphan role at any step');
            end
            tc.verifyFalse(any(st.get('LabelSource') == "confirmed"), 'every confirmation undone');
            tc.verifyEqual(nnz(st.get('AuditRole') == "confirm-audit"), 0, 'and with them the roles drawn from them');
        end
    end

    methods (Test, TestTags = {'Slow'})
        function holdoutIsStableAndAppliedOnOpen(tc)
            % a project of two sections; the holdout is chosen in the background after the first page
            fx = tc.applyFixture(matlab.unittest.fixtures.TemporaryFolderFixture);
            proj = fullfile(fx.Folder, 'proj');
            makeSyntheticDataset(fullfile(proj, 'SUBJ-ID-9001'), 'BaseName', "SUBJ-ID-9001IHC_sec1", 'Variants', false);
            makeSyntheticDataset(fullfile(proj, 'SUBJ-ID-9002'), 'BaseName', "SUBJ-ID-9002IHC_sec1", ...
                'Seed', 2, 'Variants', false);
            o = struct('RefreshSec', 0, 'CacheDir', fullfile(fx.Folder, 'cache'));
            app = CellCurator('UseSettings', false, 'PrepareNext', false, 'Assist', true, 'ConfirmAudit', false, ...
                'AssistOptions', o);
            tc.addTeardown(@() tCuratorBlind.closeApp(app));
            app.openParent(proj, '', 'ECM1');
            app.waitForLayout();
            onScreen = app.Page.Ids;
            app.waitForAssist(180);
            f = curation.BlindTiles.holdoutPath(proj, "pnn");
            tc.assertTrue(isfile(f), app.StatusText);
            tc.verifyTrue(isfile(curation.BlindTiles.holdoutPath(proj, "pv")));
            bytes0 = fileread(f);
            L = curation.BlindTiles.readHoldout(proj, "pnn");
            st = app.Store;
            mine = L.CellID(L.SourceId == app.Session.SourceId);
            tc.assertNotEmpty(mine, 'the source on screen has holdout rows');
            off = ismember(mine, onScreen);
            tc.verifyEqual(st.get('AuditRole', mine(~off)), repmat("holdout", nnz(~off), 1), 'applied to the open source');
            % never under a tile on screen: on the page on screen a cell has the role exactly when its
            % tile is an audit tile (with a warm thread pool the list can come during waitForLayout,
            % before its repage: that page is then made with those audit tiles from the start)
            P = app.Page;
            tc.assertEqual(P.Ids, onScreen, 'the first page is still on screen');
            tc.verifyEqual(st.get('AuditRole', P.Ids) == "holdout", logical(P.Blind(:)), ...
                sprintf('never on an ordinary tile on screen (%d of its cells in the list; %s)', nnz(off), app.StatusText));
            % the roles set between pages are no undo step (pass C: the store's system form)
            app.handleKey('z', {'control'});
            tc.verifySubstring(char(app.StatusText), 'Nothing to undo');
            tc.verifyEqual(st.get('AuditRole', mine(~off)), repmat("holdout", nnz(~off), 1));
            % the other section, opened now: its rows get the role before its first page
            locs2 = fullfile(proj, 'SUBJ-ID-9002', 'SUBJ-ID-9002IHC_sec1_proj_ECM1_locs.csv');
            app.openSource(locs2);
            tc.assertTrue(contains(app.Session.SourceId, "9002"));
            mine2 = L.CellID(L.SourceId == app.Session.SourceId);
            tc.verifyEqual(app.Store.get('AuditRole', mine2), repmat("holdout", numel(mine2), 1), 'applied on open');
            tc.verifySubstring(char(app.StatusText), 'blind holdout');
            tc.verifyTrue(any(app.Page.Blind), 'and they come on the first page');
            delete(app);
            % the next session: the same list, nothing chosen again, nothing new to apply
            app2 = CellCurator('UseSettings', false, 'PrepareNext', false, 'Assist', true, 'ConfirmAudit', false, ...
                'AssistOptions', o);
            tc.addTeardown(@() tCuratorBlind.closeApp(app2));
            app2.openParent(proj, '', 'ECM1');
            app2.waitForLayout();
            app2.waitForAssist(180);
            tc.verifyEqual(fileread(f), bytes0, 'the holdout list never changes once chosen');
            tc.verifyLessThanOrEqual(app2.Counters.HoldoutApplied, nnz(off), ...
                'only rows kept off the earlier page on screen are new');
            tc.verifyEqual(app2.Store.get('AuditRole', mine(~off)), repmat("holdout", nnz(~off), 1), 'kept in the store');
        end
    end
end

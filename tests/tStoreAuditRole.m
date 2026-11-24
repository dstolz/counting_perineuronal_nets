classdef tStoreAuditRole < matlab.unittest.TestCase
%tStoreAuditRole  curation.Store.setAuditRole in its two forms (integration pass C, defect 3a):
%     the person's form (default): an undoable user transaction that joins an open batch
%     the app's form, setAuditRole(ids, role, struct('System', true)): bookkeeping, not a user
%       action: no undo step (Ctrl+Z still undoes the person's last own action, and the redo stack
%       is kept), Changed Kind "audit", journaled as its own transaction (Action "setAuditRole"),
%       replayed after a crash, saved with the snapshot; validated before anything is written;
%       curation:Store:inBatch inside a batch
%
%   Run: pwsh -File tools\Run-Tests.ps1 tStoreAuditRole

    properties
        Dir char = ''
        Events cell = {}
    end

    methods (TestClassSetup)
        function addPaths(tc)
            here = fileparts(mfilename('fullpath'));
            tc.applyFixture(matlab.unittest.fixtures.PathFixture(fullfile(fileparts(here), 'customizations')));
        end
    end

    methods (TestMethodSetup)
        function makeDir(tc)
            tmp = tc.applyFixture(matlab.unittest.fixtures.TemporaryFolderFixture);
            tc.Dir = tmp.Folder;
            tc.Events = {};
        end
    end

    methods (Test)
        function systemRolesAreNotUndoSteps(tc)
            s = tc.mem(mkLocs(6));
            s.setLabel(1, "Good", "human");                       % the person's last own action
            lh = addlistener(s, 'Changed', @(~, e) tc.note(e));
            tc.addTeardown(@() delete(lh));
            rev = s.Meta.Revision;
            s.setAuditRole([2 3], "holdout", struct('System', true, 'Queue', "audit"));
            tc.verifyEqual(s.get('AuditRole', [2 3]), ["holdout"; "holdout"]);
            tc.verifyGreaterThan(s.Meta.Revision, rev, 'a new revision: saved with the next snapshot');
            tc.assertNumElements(tc.Events, 1, 'one Changed event');
            e = tc.Events{1};
            tc.verifyEqual(e.Kind, "audit", 'a Kind the window tells from a user action');
            tc.verifyEqual(sort(e.CellIDs), uint32([2; 3]));
            tc.verifyEqual(e.Fields, "AuditRole");
            tc.verifyEqual(e.ChangeSet.Action, "setAuditRole");
            % Ctrl+Z undoes the label, not the roles
            tc.verifyTrue(s.undo());
            tc.verifyEqual(s.get('Label', 1), "", 'undo reverted the person''s label');
            tc.verifyEqual(s.get('AuditRole', [2 3]), ["holdout"; "holdout"], 'the roles stay');
            tc.verifyFalse(s.CanUndo, 'the system roles left no undo step of their own');
            % a system call between an undo and a redo keeps the redo
            s.setAuditRole(4, "confirm-audit", struct('System', true));
            tc.verifyTrue(s.CanRedo, 'the redo stack is kept');
            tc.verifyTrue(s.redo());
            tc.verifyEqual(s.get('Label', 1), "Good");
            tc.verifyEqual(s.get('AuditRole', 4), "confirm-audit");
            % clearing is the same form
            s.setAuditRole(4, "", struct('System', true));
            tc.verifyEqual(s.get('AuditRole', 4), "");
            % nothing to change: no revision, no event
            rev = s.Meta.Revision; n = numel(tc.Events);
            s.setAuditRole([2 3], "holdout", struct('System', true));
            s.setAuditRole([], "holdout", struct('System', true));
            tc.verifyEqual(s.Meta.Revision, rev);
            tc.verifyEqual(numel(tc.Events), n);
        end

        function thePersonsFormStaysUndoable(tc)
            s = tc.mem(mkLocs(4));
            s.setAuditRole(2, "catch");
            tc.verifyTrue(s.CanUndo);
            s.undo();
            tc.verifyEqual(s.get('AuditRole', 2), "");
            s.beginBatch("page");
            s.setLabel(1, "Good", "confirmed");
            s.setAuditRole(1, "confirm-audit", struct('System', false));
            s.endBatch();
            tc.verifyEqual(s.get('AuditRole', 1), "confirm-audit");
            s.undo();
            tc.verifyEqual([s.get('Label', 1) s.get('AuditRole', 1)], ["" ""], 'one undo step for the batch');
        end

        function systemFormValidatesAndRefusesABatch(tc)
            s = tc.mem(mkLocs(4));
            T0 = s.T; rev = s.Meta.Revision;
            sys = struct('System', true);
            tc.verifyError(@() s.setAuditRole([1 99], "holdout", sys), 'curation:Store:unknownId');
            tc.verifyError(@() s.setAuditRole(1, "bogus", sys), 'curation:Store:badArgument');
            s.beginBatch("page");
            tc.verifyError(@() s.setAuditRole(1, "holdout", sys), 'curation:Store:inBatch');
            s.endBatch();
            tc.verifyEqual(s.T, T0, 'nothing was written');
            tc.verifyEqual(s.Meta.Revision, rev);
            path = writeLocs(tc.Dir, 'secV_proj_ECM1', mkLocs(3));
            w = tc.openP(path);
            r = tc.openP(path);
            tc.assertTrue(r.ReadOnly);
            tc.verifyError(@() r.setAuditRole(1, "holdout", sys), 'curation:Store:readOnly');
            w.close();
            tc.verifyError(@() w.setAuditRole(1, "holdout", sys), 'curation:Store:closed');
        end

        function systemRolesSurviveACrash(tc)
            name = 'secA_proj_ECM1';
            path = writeLocs(tc.Dir, name, mkLocs(8));
            s = tc.openP(path);
            s.setLabel(1, "Good");
            s.flush();
            s.setAuditRole([2 3 4], "holdout", struct('System', true, 'Queue', "audit"));
            s.setLabel(5, "Bad");
            s.setAuditRole(6, "confirm-audit", struct('System', true));
            s.setAuditRole(3, "", struct('System', true));
            T1 = s.T;
            tc.verifyTrue(s.Dirty, 'precondition: the snapshot is older than the journal');
            crash = crashCopy(tc.Dir);
            s.close();
            c = tc.openP(fullfile(crash, [name '_locs.csv']));
            tc.verifyFalse(c.ReadOnly);
            tc.verifyEqual(c.get('AuditRole', 1:8), ["" "holdout" "" "holdout" "" "confirm-audit" "" ""]');
            tc.verifyEqual(c.T.Label, T1.Label);
            R = curation.Journal.read(c.Paths.journal, 0);
            k = R.Action == "setAuditRole" & R.Field == "AuditRole";
            tc.verifyEqual(sort(str2double(R.CellID(k))), [2; 3; 3; 4; 6], ...
                'each system call is journaled as its own transaction');
            tc.verifyTrue(all(R.Queue(k & R.CellID == "2") == "audit"), 'with its context');
            % and the snapshot keeps them too
            c.flush();
            c.close();
            d = tc.openP(fullfile(crash, [name '_locs.csv']));
            tc.verifyEqual(d.get('AuditRole', [2 4 6]), ["holdout"; "holdout"; "confirm-audit"]);
            tc.verifyFalse(d.CanUndo, 'a reopened store has nothing to undo');
        end
    end

    methods (Access = private)
        function note(tc, e)
            tc.Events{end + 1} = e;
        end

        function s = mem(tc, L)
            s = curation.Store.fromTable(L, struct('Key', 'ECM1', 'UmPerPixel', 0.645, 'Reviewer', 'tester'));
            tc.addTeardown(@() delete(s));
        end

        function s = openP(tc, path, opts)
            if nargin < 3, opts = struct(); end
            if ~isfield(opts, 'AutosaveDelay'), opts.AutosaveDelay = 0; end
            if ~isfield(opts, 'Reviewer'), opts.Reviewer = 'tester'; end
            s = curation.Store.openCsv(path, opts);
            tc.addTeardown(@() closeQuiet(s));
        end
    end
end

function L = mkLocs(n)
x = 100 * (1:n)';
L = table(x, 100 + 0 * x, zeros(n, 1), linspace(0.5, 0.9, n)', repmat("img.tif", n, 1), zeros(n, 1), ...
    (1:n)' + 0.5, 'VariableNames', {'X', 'Y', 'class', 'score', 'imgName', 'thr', 'rescore'});
end

function path = writeLocs(folder, stem, L)
path = fullfile(folder, [stem '_locs.csv']);
writetable(L, path);
end

function crash = crashCopy(folder)
% The files as they are on disk now (a crash: the snapshot older than the journal).
crash = fullfile(folder, 'crash');
mkdir(crash);
f = dir(folder);
f = f(~[f.isdir]);
for k = 1:numel(f)
    copyfile(fullfile(folder, f(k).name), fullfile(crash, f(k).name));
end
end

function closeQuiet(s)
try
    if isvalid(s), s.close(); end
catch
end
end

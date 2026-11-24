classdef ChangeSet
%CHANGESET  One user action (one transaction) on a curation.Store: the single record behind
%   undo, redo, the journal lines and the Changed event.
%
%   A ChangeSet is a value object, complete once the Store commits it. Its Entries are applied in
%   order to redo and in reverse order (with Old instead of New) to undo.
%
%   Properties
%     Desc      string   human description, e.g. "Label 118 cells Good"
%     Action    string   the Store method that made it: setLabel, setFlag, setNote, setExcluded,
%                        setAuditRole, addCell, moveCell, mergeCells, unmerge, keepBoth,
%                        setSweepDone, setComplete, addRegion, removeRegion, batch, ... (also
%                        undo/redo for journal-only copies; reconcile, legacy-import and regions
%                        for the structural transactions the store makes itself, and setRescore
%                        (Stage-2 scores stored for the cells' positions), which are journaled but
%                        never undoable; reloadRegions, lockLost, model on events)
%     Kind      string   how the event came about: "do" | "undo" | "redo" | "reconcile" |
%                        "legacy-import" | "model" | "rescore" | "regions" | "lockLost" | "load" |
%                        "replay"
%     Entries   struct array, fields
%                 Kind    'set' | 'add' | 'meta' | 'region' ('remove' only in the journal copy
%                         of an undo of an add, and in structural transactions: rows a
%                         reconcile purged)
%                 Field   column name (set), meta name (meta: KeptPairs, SweepDone, Complete,
%                         AutoReject; in journal copies and structural transactions also
%                         NextCellId, LocsFingerprint, LegacyImported), 'Regions' (region),
%                         '' (add/remove)
%                 CellID  uint32 column of the cells touched ([] for meta)
%                 Old     set: typed column (same type as the store column) of previous values
%                         meta: previous value; add: []; remove: struct of columns (the rows);
%                         region: the region before ([] when it is being added)
%                 New     set: typed column of new values; meta: new value;
%                         add: struct of columns (one row per CellID), the full added rows;
%                         remove: []; region: the region after ([] when it is being removed)
%     Queue, PageId  string, DwellMs double   context the GUI passed (journaled on every line)
%     Revision  double   store revision after the commit
%     Seq       double   transaction number within the writing session
%     Time      string   ISO 8601 commit time
%     Reviewer  string
%
%   Methods
%     ids = cs.cellIds()        unique CellIDs touched (uint32 column)
%     f   = cs.fields()         unique column/meta names touched (string row)
%     tf  = cs.touches(field)   true when FIELD is among fields()
%     tf  = cs.isEmpty()        no entries
%     n   = cs.numLines()       journal lines this change set makes (one per changed field
%                               per cell, one per added row, one per meta change)

    properties
        Desc string = ""
        Action string = ""
        Kind string = "do"
        Entries struct = curation.ChangeSet.emptyEntries()
        Queue string = ""
        PageId string = ""
        DwellMs double = NaN
        Revision double = NaN
        Seq double = NaN
        Time string = ""
        Reviewer string = ""
    end

    methods
        function cs = ChangeSet(desc, action, entries)
            % cs = curation.ChangeSet(desc, action[, entries])
            if nargin >= 1 && ~isempty(desc), cs.Desc = string(desc); end
            if nargin >= 2 && ~isempty(action), cs.Action = string(action); end
            if nargin >= 3 && ~isempty(entries), cs.Entries = entries; end
        end

        function ids = cellIds(cs)
            % Unique CellIDs touched by this change set (uint32 column).
            if isempty(cs.Entries)
                ids = zeros(0, 1, 'uint32');
                return;
            end
            c = {cs.Entries.CellID};
            ids = unique(uint32(vertcat(c{:})));
            ids = ids(:);
        end

        function f = fields(cs)
            % Unique column / meta names touched (string row vector; '' for row additions is
            % reported as "+row").
            if isempty(cs.Entries)
                f = strings(1, 0);
                return;
            end
            f = string({cs.Entries.Field});
            f(strlength(f) == 0) = "+row";
            f = unique(f);
        end

        function tf = touches(cs, field)
            tf = any(cs.fields() == string(field));
        end

        function tf = isEmpty(cs)
            tf = isempty(cs.Entries);
        end

        function n = numLines(cs)
            n = 0;
            for k = 1:numel(cs.Entries)
                e = cs.Entries(k);
                if strcmp(e.Kind, 'meta')
                    n = n + 1;
                elseif strcmp(e.Kind, 'region')
                    n = n + ~isempty(e.Old) + ~isempty(e.New);
                else
                    n = n + numel(e.CellID);
                end
            end
        end
    end

    methods (Static)
        function e = emptyEntries()
            % 0x1 entry struct with the fields Kind, Field, CellID, Old, New.
            e = struct('Kind', {}, 'Field', {}, 'CellID', {}, 'Old', {}, 'New', {});
            e = reshape(e, 0, 1);
        end

        function e = entry(kind, field, cellId, oldVal, newVal)
            % One entry struct (see the class help for the field contract).
            e = struct('Kind', char(kind), 'Field', char(field), ...
                'CellID', uint32(cellId(:)), 'Old', {oldVal}, 'New', {newVal});
        end
    end
end

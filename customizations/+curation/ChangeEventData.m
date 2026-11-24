classdef ChangeEventData < event.EventData
%CHANGEEVENTDATA  Event data of curation.Store's Changed event.
%
%   Properties
%     ChangeSet  curation.ChangeSet  what changed. For Kind "undo" it is the ORIGINAL change set
%                                    being reverted (its Old values are now current); for "redo"
%                                    the original one re-applied (the Excluded flags the regions
%                                    require now may differ: FullRefresh is then true). Empty
%                                    entries for whole-store events ("reconcile",
%                                    "legacy-import", "load", "lockLost").
%     Kind       string   "do" | "undo" | "redo" | "reconcile" | "legacy-import" | "model" |
%                         "rescore" (Store.setRescore: Stage-2 scores stored; not undoable) |
%                         "audit" (Store.setAuditRole with ctx.System: audit roles set by the app;
%                         not undoable) |
%                         "regions" (regions reloaded, or the Excluded flags they imply) |
%                         "lockLost" (another session took this source over: the store is now
%                         read-only, see Store.LockInfo.Message) | "load"
%     CellIDs    uint32 column  cells touched (empty: refresh everything)
%     Fields     string row     columns/meta touched (empty: refresh everything)
%     FullRefresh logical       true when a view should redraw everything (rows were added,
%                               removed or re-ordered, or a whole-store event)

    properties
        ChangeSet
        Kind string = "do"
        CellIDs uint32 = zeros(0, 1, 'uint32')
        Fields string = strings(1, 0)
        FullRefresh logical = false
    end

    methods
        function ed = ChangeEventData(cs, kind, fullRefresh)
            if nargin < 1 || isempty(cs), cs = curation.ChangeSet(); end
            if nargin < 2 || isempty(kind), kind = cs.Kind; end
            if nargin < 3, fullRefresh = false; end
            ed.ChangeSet = cs;
            ed.Kind = string(kind);
            ed.CellIDs = cs.cellIds();
            ed.Fields = cs.fields();
            ed.FullRefresh = logical(fullRefresh) || cs.isEmpty() || any(ed.Fields == "+row");
        end
    end
end

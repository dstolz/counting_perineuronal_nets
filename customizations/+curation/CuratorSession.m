classdef CuratorSession < handle
%CURATORSESSION  One source opened in CellCurator: its curation store, its crop cache and the
%   pages reviewed in it this session. CellCurator keeps the two most recent ones in memory, so
%   switching back to a source is immediate.
%
%   s.close()   record the source to the manifest (when writable), close and delete the store,
%               drop the listener. Safe to call twice; delete(s) calls it.

    properties
        Id string = ""             % lower(folder|base|key)
        Folder char = ''
        Base char = ''
        Key char = ''
        DatasetIndex double = 0
        SourceIndex double = 0
        Mf = []                    % CellDatasetManifest
        Store = []                 % curation.Store
        Cache = []                 % curation.CropCache
        ImagePath char = ''
        TargetPage double = 1
        CompanionPage double = NaN
        CompanionKey char = ''
        PageT = []                 % the target page (for the map and for snapping), as read
        PageC = []                 % the companion page ([] = none)
        Reference = []             % the reference ROI drawn on the map (region struct, [] = none)
        SweepField double = 0      % the missed-cell sweep field reached (0 = not started)
        NearKept uint32 = zeros(0, 2, 'uint32')   % [new CellID, reviewed CellID] of the reconcile at open
        ReconcileText string = ""  % what the reconcile at open did, in plain words ("" = none ran)
        History = []               % pages left behind (struct array), oldest first
        PagesDone double = 0       % review pages confirmed in this session
        PaceLog double = zeros(0, 2)   % [tiles seconds] per confirmed page
        LastChange = []            % the last curation.ChangeEventData of the store
        SourceId string = ""       % the project's id of this source (curation.BlindTiles.sourceId)
        Kind string = ""           % "pnn" | "pv" | "unknown" (curation.Proposals.kindOf)
        Registered logical = false % handed to the assist runner (features, predictions)
        ModelNumber double = 0     % the model whose predictions were applied last (0 = none)
        Display = []               % curation.DisplayDefaults.fromCache of its crops: the default display
        FinalSig string = ""       % the kept cells _final.csv was written for (CellCurator.keptSignature)
        Listener = []
        Messages string = strings(0, 1)   % warnings from opening (shown in the status bar)
        Closed logical = false
    end

    methods
        function close(s, recordFcn)
            %CLOSE  RECORDFCN(s) (optional) runs first, while the store is still open.
            if s.Closed, return; end
            s.Closed = true;
            if nargin >= 2 && ~isempty(recordFcn)
                try recordFcn(s); catch, end
            end
            if ~isempty(s.Listener)
                try delete(s.Listener); catch, end
                s.Listener = [];
            end
            if ~isempty(s.Store)
                try s.Store.close(); catch, end
                try delete(s.Store); catch, end
                s.Store = [];
            end
            s.Cache = [];
            s.PageT = [];
            s.PageC = [];
        end

        function delete(s)
            try s.close(); catch, end
        end
    end
end

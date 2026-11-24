classdef BlindTiles
%BLINDTILES  Which tiles CellCurator shows blind (static; no GUI code): the holdout of each channel
%   kind, chosen once per project and kept with the data, and the confirm audit of each source.
%
%   A blind tile is shown with a neutral border and without its P(Good), the page default or any
%   proposal; only an explicit g / b / u (or the Good / Bad / Uncertain buttons) decides it, with
%   LabelSource "blind" (curation.Queues: BLIND TILES). Blind decisions are the only evidence
%   curation.Audit uses for the model's accuracy (holdout) and the reviewer's consistency
%   (confirm audit).
%
%   HOLDOUT (per project and channel kind)
%   p = curation.BlindTiles.holdoutPath(parentDir, kind)
%       <parentDir>\.cellcuration\holdout_<kind>.csv: with the data, so the list is the same in every
%       session and on every computer that opens the folder
%   L = curation.BlindTiles.readHoldout(parentDir, kind)
%       table SourceId (string), CellID (uint32), Stratum, score; 0 rows when there is no list
%   n = curation.BlindTiles.holdoutSize(nCandidates, opts)
%       min(Target 400, round(MaxFraction 5% of the candidates)): a small project is not turned
%       into a blind one
%   L = curation.BlindTiles.sampleHoldout(index, kind, opts)
%       curation.Audit.sampleHoldout with N = holdoutSize (rows already reviewed are never chosen:
%       a reviewed row can no longer be judged blind)
%   [L, written] = curation.BlindTiles.writeHoldout(parentDir, kind, L)
%       writes the list unless one exists already (then that one is read and returned: the first
%       list written wins, so the holdout never changes once chosen)
%   sid = curation.BlindTiles.sourceId(parentDir, folder, base, key)
%       the source id curation.ProjectIndex uses: "<folder/base relative to parentDir>|<key>"
%   rep = curation.BlindTiles.applyHoldout(store, sid, L)
%       store.setAuditRole(ids, "holdout", System=true: not an undo step) for the listed rows of
%       source SID that exist, are active, carry no audit role and were not reviewed (idempotent;
%       curation:Store:inBatch while a batch is open: apply between pages). rep: Ids (newly set), Applied,
%       Already (holdout before), Gone (listed rows no longer in the store), Reviewed (reviewed
%       since they were chosen: left ordinary), Other (another audit role or not active), Listed
%
%   CONFIRM AUDIT (per source, once)
%   tf  = curation.BlindTiles.needsConfirmAudit(T, complete)
%       the source's ordinary review queue is empty, it has rows confirmed in bulk, none of its rows
%       has the role confirm-audit yet, and it is not complete
%   ids = curation.BlindTiles.confirmAuditIds(T, sid, opts)
%       curation.Audit.sampleConfirmAudit: Fraction 2% of the confirmed-by-default rows, at least
%       Min 5 when the source has that many; a random stream of its own per source (SID)
%   ids = curation.BlindTiles.orphanConfirmAudit(T)
%       confirm-audit rows that lost the confirmed label they were drawn for (an undo): CellCurator
%       clears their role (system form) so no unconfirmed row is shown as a confirm-audit tile.
%   WHO SETS THE ROLES (CellCurator): the confirm audit drawn by the Enter that empties the queue
%   is part of that Enter's own transaction (undoing the Enter removes the roles with it; redo
%   brings them back); drawn between pages it is the store's system form, as the holdout is.
%
%   HELPERS
%   m = curation.BlindTiles.roleMask(roles)       AuditRole is holdout or confirm-audit (decided or not)
%   m = curation.BlindTiles.pendingMask(T)        pending blind tiles (curation.Queues.blindMask)
%   n = curation.BlindTiles.ordinaryLeft(T)       rows the ordinary review queue still holds
%
%   T is a table with the curation columns (CellID, State, Reviewed, Excluded, Label, Flag,
%   LabelSource, AuditRole; curation.Store column names).
%
%   See also curation.Audit, curation.Queues, curation.Store, curation.ProjectIndex.

    properties (Constant)
        ROLES = ["holdout" "confirm-audit"]
        HOLDOUT_TARGET = 400
        HOLDOUT_FRACTION = 0.05
        CONFIRM_FRACTION = 0.02
        CONFIRM_MIN = 5
    end

    methods (Static)
        %% ------------------------------------------------------------------ holdout
        function p = holdoutPath(parentDir, kind)
            p = fullfile(char(parentDir), '.cellcuration', ['holdout_' char(kind) '.csv']);
        end

        function L = readHoldout(parentDir, kind)
            L = curation.BlindTiles.emptyList();
            p = curation.BlindTiles.holdoutPath(parentDir, kind);
            if ~isfile(p), return; end
            fid = fopen(p, 'r', 'n', 'UTF-8');
            if fid < 0, return; end
            c = onCleanup(@() fclose(fid));
            hdr = fgetl(fid);
            if ~ischar(hdr) || ~startsWith(strtrim(strrep(hdr, char(65279), '')), 'SourceId,CellID')
                return
            end
            D = textscan(fid, '%q%f%f%f', 'Delimiter', ',', 'EmptyValue', NaN);
            if isempty(D{1}), return; end
            n = min(cellfun(@numel, D));
            L = table(string(D{1}(1:n)), uint32(D{2}(1:n)), D{3}(1:n), D{4}(1:n), ...
                'VariableNames', {'SourceId', 'CellID', 'Stratum', 'score'});
        end

        function n = holdoutSize(nCandidates, opts)
            if nargin < 2 || isempty(opts), opts = struct(); end
            target = curation.BlindTiles.opt(opts, 'Target', curation.BlindTiles.HOLDOUT_TARGET);
            frac = curation.BlindTiles.opt(opts, 'MaxFraction', curation.BlindTiles.HOLDOUT_FRACTION);
            n = max(0, min(target, round(frac * double(nCandidates))));
        end

        function L = sampleHoldout(index, kind, opts)
            %SAMPLEHOLDOUT  New holdout rows of KIND (see the class help). Pure: nothing is written.
            if nargin < 3 || isempty(opts), opts = struct(); end
            T = index.table(kind);
            act = T.State == "active" & ~T.Excluded;
            n = curation.BlindTiles.holdoutSize(nnz(act), opts);
            L = curation.BlindTiles.emptyList();
            if n == 0, return; end
            S = curation.Audit.sampleHoldout(T, kind, struct('Target', n, ...
                'Seed', curation.BlindTiles.opt(opts, 'Seed', 1)));
            if isempty(S) || height(S) == 0, return; end
            sc = nan(height(S), 1);
            st = nan(height(S), 1);
            if ismember('score', S.Properties.VariableNames), sc = double(S.score); end
            if ismember('Stratum', S.Properties.VariableNames), st = double(S.Stratum); end
            L = table(string(S.SourceId), uint32(S.CellID), st, sc, ...
                'VariableNames', {'SourceId', 'CellID', 'Stratum', 'score'});
        end

        function [L, written] = writeHoldout(parentDir, kind, L)
            written = false;
            p = curation.BlindTiles.holdoutPath(parentDir, kind);
            if isfile(p)
                L = curation.BlindTiles.readHoldout(parentDir, kind);
                return
            end
            folder = fileparts(p);
            if ~isfolder(folder), mkdir(folder); end
            lines = strings(height(L) + 1, 1);
            lines(1) = "SourceId,CellID,Stratum,score";
            for i = 1:height(L)
                lines(i + 1) = sprintf('"%s",%d,%g,%.10g', strrep(L.SourceId(i), '"', '""'), L.CellID(i), ...
                    L.Stratum(i), L.score(i));
            end
            [~, tok] = fileparts(tempname);
            tmp = [p '.' tok '.tmp'];
            fid = fopen(tmp, 'w', 'n', 'UTF-8');
            if fid < 0
                error('curation:BlindTiles:writeFailed', 'Cannot write %s.', tmp);
            end
            fprintf(fid, '%s\n', lines);
            fclose(fid);
            if isfile(p)                         % another session wrote it meanwhile: that one wins
                delete(tmp);
                L = curation.BlindTiles.readHoldout(parentDir, kind);
                return
            end
            movefile(tmp, p, 'f');
            written = true;
        end

        function sid = sourceId(parentDir, folder, base, key)
            rel = strrep(CellToolkit.makeRelativePath(fullfile(char(folder), char(base)), char(parentDir)), '\', '/');
            sid = string(rel) + "|" + string(key);
        end

        function rep = applyHoldout(store, sid, L)
            rep = struct('Ids', zeros(0, 1, 'uint32'), 'Applied', 0, 'Already', 0, 'Gone', 0, ...
                'Reviewed', 0, 'Other', 0, 'Listed', 0);
            if isempty(L) || height(L) == 0 || isempty(store) || store.ReadOnly, return; end
            mine = lower(L.SourceId) == lower(string(sid));
            ids = unique(uint32(L.CellID(mine)));
            rep.Listed = numel(ids);
            if isempty(ids), return; end
            have = store.get('CellID');
            present = ismember(ids, have);
            rep.Gone = nnz(~present);
            ids = ids(present);
            if isempty(ids), return; end
            role = store.get('AuditRole', ids);
            reviewed = store.get('Reviewed', ids) | ...
                ismember(store.get('LabelSource', ids), curation.Store.PERSON_SOURCES);
            active = store.get('State', ids) == "active";
            rep.Already = nnz(role == "holdout");
            rep.Reviewed = nnz(role == "" & reviewed);
            rep.Other = nnz(role ~= "" & role ~= "holdout") + nnz(role == "" & ~reviewed & ~active);
            take = role == "" & ~reviewed & active;
            rep.Ids = ids(take);
            rep.Applied = numel(rep.Ids);
            if rep.Applied > 0
                % the app's bookkeeping, not the reviewer's action: no undo step (Store, System)
                store.setAuditRole(rep.Ids, "holdout", struct('Queue', "audit", 'System', true));
            end
        end

        function ids = orphanConfirmAudit(T)
            %ORPHANCONFIRMAUDIT  Rows whose role is confirm-audit but that no longer carry the label
            %   they were drawn for (confirmed by default, or since judged blind): an undo took the
            %   confirmed label away. Their role is to be cleared (CellCurator does so after an undo,
            %   with the system form), so a row the reviewer has not confirmed is never shown as a
            %   confirm-audit tile.
            role = curation.BlindTiles.textCol(T, 'AuditRole');
            src = curation.BlindTiles.textCol(T, 'LabelSource');
            m = role == "confirm-audit" & ~ismember(src, ["confirmed" "blind"]);
            ids = uint32(T.CellID(m));
        end

        %% ------------------------------------------------------------------ confirm audit
        function tf = needsConfirmAudit(T, complete)
            if nargin < 2, complete = false; end
            tf = false;
            if complete || height(T) == 0, return; end
            role = curation.BlindTiles.textCol(T, 'AuditRole');
            if any(role == "confirm-audit"), return; end
            if curation.BlindTiles.ordinaryLeft(T) > 0, return; end
            act = curation.BlindTiles.textCol(T, 'State') == "active";
            tf = any(act & logical(T.Reviewed) & curation.BlindTiles.textCol(T, 'LabelSource') == "confirmed" ...
                & role == "");
        end

        function ids = confirmAuditIds(T, sid, opts)
            if nargin < 3 || isempty(opts), opts = struct(); end
            o = struct('Fraction', curation.BlindTiles.opt(opts, 'Fraction', curation.BlindTiles.CONFIRM_FRACTION), ...
                'Min', curation.BlindTiles.opt(opts, 'Min', curation.BlindTiles.CONFIRM_MIN), ...
                'Seed', curation.BlindTiles.opt(opts, 'Seed', 1));
            T.SourceId = repmat(string(sid), height(T), 1);
            ids = curation.Audit.sampleConfirmAudit(T, o);
            if istable(ids), ids = ids.CellID; end
            ids = uint32(ids(:));
        end

        %% ------------------------------------------------------------------ helpers
        function m = roleMask(roles)
            m = ismember(string(roles), curation.BlindTiles.ROLES);
            m = m(:);
        end

        function m = pendingMask(T)
            m = curation.Queues.blindMask(T, struct('BlindRoles', curation.BlindTiles.ROLES));
        end

        function n = ordinaryLeft(T)
            m = curation.BlindTiles.textCol(T, 'State') == "active" & ~logical(T.Reviewed) & ...
                ~logical(T.Excluded) & curation.BlindTiles.textCol(T, 'Label') == "" & ...
                curation.BlindTiles.textCol(T, 'Flag') == "" & curation.BlindTiles.textCol(T, 'AuditRole') == "";
            n = nnz(m);
        end
    end

    methods (Static, Access = private)
        function L = emptyList()
            L = table(strings(0, 1), zeros(0, 1, 'uint32'), zeros(0, 1), zeros(0, 1), ...
                'VariableNames', {'SourceId', 'CellID', 'Stratum', 'score'});
        end

        function v = opt(s, name, d)
            v = d;
            if isstruct(s) && isfield(s, name) && ~isempty(s.(name)), v = s.(name); end
        end

        function s = textCol(T, name)
            if ~ismember(name, T.Properties.VariableNames)
                s = strings(height(T), 1);
                return
            end
            s = string(T.(name));
            s = s(:);
            s(ismissing(s)) = "";
        end
    end
end

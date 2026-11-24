classdef Reconciler
%RECONCILER  Position matching between stored curation rows and (re)generated detections.
%   Pure functions, no state, no file writes. curation.Store.reconcile and
%   curation.LegacyImport use them.
%
%   [iOld, iNew, dist] = curation.Reconciler.match(oldXY, newXY, tolPx)
%       One-to-one matching of two point sets within tolPx (inclusive), greedy by ascending
%       distance: the closest remaining pair is accepted first, so every accepted pair is a
%       mutual nearest neighbour among the points still unmatched at that moment. Ties are
%       broken by iOld, then iNew (deterministic). Points with a non-finite coordinate never
%       match. Returns column vectors in acceptance order; dist in pixels.
%
%   P = curation.Reconciler.plan(S, newXY, tolPx, exactPx)
%       The reconcile passes over store rows S (struct of columns with DET_X, DET_Y, X, Y,
%       State, PosSource, Origin, Reviewed, CellID, MergedInto) against new detections newXY
%       (m x 2). Each pass is one-to-one, nearest first (match), and only sees what earlier passes
%       left unmatched. A row "a person decided or touched" (PERSON) is: not merged, and Reviewed,
%       or PosSource human/snap, or Origin added/merged, or the keeper of a merged row.
%         1  exact (<= exactPx, default 0.01 px) on DET_X/DET_Y                every row
%         2  within tolPx on DET_X/DET_Y                                        PERSON rows
%         3  within tolPx on effective X/Y (added and moved cells)              PERSON rows
%         4  within tolPx on DET_X/DET_Y (X/Y when DET is NaN)                   State "merged"
%            (a re-detected duplicate links back to its merged-away row)
%         5  within tolPx on DET_X/DET_Y                                        all other rows
%            (unreviewed, auto-rejected, stale)
%         6  safety net: a detection still unmatched within tolPx (DET or X/Y) of an active
%            Reviewed row that is still unmatched is linked to it
%       So a person's cell always gets its detection before an unreviewed neighbour can take it,
%       and a cell is never left "vanished" while its re-detection becomes a second candidate.
%       P fields: RowNew (n x 1 index into newXY, 0 = unmatched), DistPx (n x 1, NaN when
%       unmatched), Pass (n x 1, 0 = unmatched), NewUnmatched (indices of unmatched detections),
%       NearKept (k x 2 [detection index, row index]: unmatched detections within tolPx of an
%       active Reviewed row, which matched another detection; the store appends them and reports
%       them), Counts (struct: exact, nearDet (passes 2 and 5), nearHuman (3), merged (merged rows
%       matched in any pass), nearPerson (2 and 3), nearUnreviewed (5), linked (6)).
%
%   [i, j, d] = curation.Reconciler.candidatePairs(oldXY, newXY, tolPx)
%       Every pair within tolPx (brute force in blocks; no toolbox needed).
%
%   fp = curation.Reconciler.fingerprint(file, nRows)
%       'bytes=<n>;mtime=<yyyy-mm-ddTHH:MM:SS>Z;rows=<n>' of a locs file ('' when missing); the
%       modification time in UTC, so a daylight-saving change never alters it. (Fingerprints
%       written before carry local time without the Z; sameStamp and equivalent accept both.)
%   fp = curation.Reconciler.tableFingerprint(T)
%       'table:rows=<n>;sx=<sum X>;sy=<sum Y>' for an in-memory locs table.
%   tf = curation.Reconciler.sameStamp(fp, file)
%       true when the file's size and modification time equal those recorded in fp (rows are
%       not read), i.e. the file has not changed since fp was taken.
%   tf = curation.Reconciler.equivalent(fpA, fpB)
%       true when two fingerprints describe the same file state (equal text, or the same bytes,
%       rows and modification time with one of them in the older local-time form).

    methods (Static)

        function [iOld, iNew, dist] = match(oldXY, newXY, tolPx)
            iOld = zeros(0, 1); iNew = zeros(0, 1); dist = zeros(0, 1);
            if isempty(oldXY) || isempty(newXY) || ~(tolPx >= 0)
                return;
            end
            [i, j, d] = curation.Reconciler.candidatePairs(oldXY, newXY, tolPx);
            if isempty(i), return; end
            [~, ord] = sortrows([d, i, j]);
            i = i(ord); j = j(ord); d = d(ord);
            takenO = false(size(oldXY, 1), 1);
            takenN = false(size(newXY, 1), 1);
            keep = false(numel(i), 1);
            for k = 1:numel(i)
                a = i(k); b = j(k);
                if ~takenO(a) && ~takenN(b)
                    takenO(a) = true;
                    takenN(b) = true;
                    keep(k) = true;
                end
            end
            iOld = i(keep); iNew = j(keep); dist = d(keep);
        end

        function [i, j, d] = candidatePairs(oldXY, newXY, tolPx)
            ox = double(oldXY(:, 1)); oy = double(oldXY(:, 2));
            nx = double(newXY(:, 1)); ny = double(newXY(:, 2));
            okO = find(isfinite(ox) & isfinite(oy));
            okN = find(isfinite(nx) & isfinite(ny));
            i = zeros(0, 1); j = zeros(0, 1); d = zeros(0, 1);
            if isempty(okO) || isempty(okN), return; end
            ox = ox(okO); oy = oy(okO); nx = nx(okN); ny = ny(okN);
            tol2 = tolPx ^ 2;
            % Sort the new points by x so each block only meets old points in its x range.
            [nx, ordN] = sort(nx); ny = ny(ordN); okN = okN(ordN);
            [ox, ordO] = sort(ox); oy = oy(ordO); okO = okO(ordO);
            blk = max(1, floor(2e6 / numel(ox)));
            I = {}; J = {}; D = {};
            for s = 1:blk:numel(nx)
                e = min(numel(nx), s + blk - 1);
                lo = find(ox >= nx(s) - tolPx, 1, 'first');
                hi = find(ox <= nx(e) + tolPx, 1, 'last');
                if isempty(lo) || isempty(hi) || hi < lo, continue; end
                bx = nx(s:e)'; by = ny(s:e)';
                d2 = (ox(lo:hi) - bx) .^ 2 + (oy(lo:hi) - by) .^ 2;
                [a, b] = find(d2 <= tol2);
                if isempty(a), continue; end
                lin = sub2ind(size(d2), a, b);
                I{end + 1} = okO(lo - 1 + a); %#ok<AGROW>
                J{end + 1} = okN(s - 1 + b); %#ok<AGROW>
                D{end + 1} = sqrt(d2(lin)); %#ok<AGROW>
            end
            if isempty(I), return; end
            i = vertcat(I{:}); j = vertcat(J{:}); d = vertcat(D{:});
            i = i(:); j = j(:); d = d(:);
        end

        function P = plan(S, newXY, tolPx, exactPx)
            if nargin < 4 || isempty(exactPx), exactPx = 0.01; end
            n = numel(S.X);
            m = size(newXY, 1);
            P = struct('RowNew', zeros(n, 1), 'DistPx', nan(n, 1), 'Pass', zeros(n, 1), ...
                'NewUnmatched', zeros(0, 1), 'NearKept', zeros(0, 2), ...
                'Counts', struct('exact', 0, 'nearDet', 0, 'nearHuman', 0, 'merged', 0, ...
                'nearPerson', 0, 'nearUnreviewed', 0, 'linked', 0));
            taken = false(m, 1);
            st = string(S.State(:));
            isMerged = st == "merged";
            pos = string(S.PosSource(:));
            org = string(S.Origin(:));
            rev = false(n, 1);
            if isfield(S, 'Reviewed'), rev = logical(S.Reviewed(:)); end
            isKeeper = false(n, 1);
            if isfield(S, 'MergedInto') && isfield(S, 'CellID')
                keepers = unique(double(S.MergedInto(isMerged & double(S.MergedInto(:)) > 0)));
                isKeeper = ismember(double(S.CellID(:)), keepers);
            end
            person = ~isMerged & (rev | pos == "human" | pos == "snap" | org == "added" ...
                | org == "merged" | isKeeper);
            det = [double(S.DET_X(:)), double(S.DET_Y(:))];
            eff = [double(S.X(:)), double(S.Y(:))];
            mergedRef = det;
            noDet = ~all(isfinite(det), 2);
            mergedRef(noDet, :) = eff(noDet, :);
            passes = { ...
                true(n, 1),            det,       exactPx, 1; ...
                person,                det,       tolPx,   2; ...
                person,                eff,       tolPx,   3; ...
                isMerged,              mergedRef, tolPx,   4; ...
                ~isMerged & ~person,   det,       tolPx,   5};
            for k = 1:size(passes, 1)
                [P, taken] = curation.Reconciler.runPass(P, taken, passes{k, 1}, passes{k, 2}, ...
                    newXY, passes{k, 3}, passes{k, 4});
            end
            % 6: a detection next to a reviewed row that is still unmatched belongs to it
            active = st == "active" & rev;
            for ref = {det, eff}
                [P, taken] = curation.Reconciler.runPass(P, taken, active, ref{1}, newXY, tolPx, 6);
            end
            % detections next to a reviewed row that matched another one: reported, not silent
            un = find(~taken);
            rv = find(active);
            if ~isempty(un) && ~isempty(rv)
                best = inf(numel(un), 1);
                who = zeros(numel(un), 1);
                for ref = {det, eff}
                    [i, j, d] = curation.Reconciler.candidatePairs(newXY(un, :), ref{1}(rv, :), tolPx);
                    for q = 1:numel(i)
                        if d(q) < best(i(q))
                            best(i(q)) = d(q);
                            who(i(q)) = rv(j(q));
                        end
                    end
                end
                hit = who > 0;
                P.NearKept = [un(hit), who(hit)];
            end
            P.NewUnmatched = find(~taken);
            P.Counts.exact = nnz(P.Pass == 1);
            P.Counts.nearDet = nnz(P.Pass == 2 | P.Pass == 5);
            P.Counts.nearHuman = nnz(P.Pass == 3);
            P.Counts.merged = nnz(isMerged & P.Pass > 0);
            P.Counts.nearPerson = nnz(P.Pass == 2 | P.Pass == 3);
            P.Counts.nearUnreviewed = nnz(P.Pass == 5);
            P.Counts.linked = nnz(P.Pass == 6);
        end

        function fp = fingerprint(file, nRows)
            fp = '';
            d = dir(char(file));
            if isempty(d), return; end
            fp = sprintf('bytes=%d;mtime=%s;rows=%d', d(1).bytes, ...
                curation.Reconciler.mtimeUtcText(char(file), d(1)), round(nRows));
        end

        function fp = tableFingerprint(T)
            x = 0; y = 0;
            names = string(T.Properties.VariableNames);
            ix = find(strcmpi(names, "X"), 1);
            iy = find(strcmpi(names, "Y"), 1);
            if ~isempty(ix), x = sum(double(T.(char(names(ix)))), 'omitnan'); end
            if ~isempty(iy), y = sum(double(T.(char(names(iy)))), 'omitnan'); end
            fp = sprintf('table:rows=%d;sx=%.10g;sy=%.10g', height(T), x, y);
        end

        function tf = sameStamp(fp, file)
            tf = false;
            fp = char(fp);
            if isempty(fp) || startsWith(fp, 'table:'), return; end
            d = dir(char(file));
            if isempty(d), return; end
            tok = regexp(fp, 'bytes=(\d+);mtime=([^;]*);', 'tokens', 'once');
            if isempty(tok), return; end
            if str2double(tok{1}) ~= d(1).bytes, return; end
            if endsWith(tok{2}, 'Z')
                tf = strcmp(tok{2}, curation.Reconciler.mtimeUtcText(char(file), d(1)));
            else
                tf = strcmp(tok{2}, curation.Reconciler.mtimeText(d(1).datenum));   % older local form
            end
        end

        function tf = equivalent(a, b)
            a = char(a); b = char(b);
            tf = strcmp(a, b);
            if tf || isempty(a) || isempty(b) || startsWith(a, 'table:') || startsWith(b, 'table:')
                return;
            end
            pa = regexp(a, '^bytes=(\d+);mtime=([^;]*);rows=(\d+)$', 'tokens', 'once');
            pb = regexp(b, '^bytes=(\d+);mtime=([^;]*);rows=(\d+)$', 'tokens', 'once');
            if isempty(pa) || isempty(pb) || ~strcmp(pa{1}, pb{1}) || ~strcmp(pa{3}, pb{3})
                return;
            end
            za = endsWith(pa{2}, 'Z'); zb = endsWith(pb{2}, 'Z');
            if za == zb
                tf = strcmp(pa{2}, pb{2});
                return;
            end
            if za, [u, l] = deal(pa{2}, pb{2}); else, [u, l] = deal(pb{2}, pa{2}); end
            try
                t = datetime(u(1:end - 1), 'InputFormat', 'yyyy-MM-dd''T''HH:mm:ss', 'TimeZone', 'UTC');
                t.TimeZone = 'local';
                tf = strcmp(char(t, 'yyyy-MM-dd''T''HH:mm:ss'), l);
            catch
            end
        end
    end

    methods (Static, Access = private)
        function [P, taken] = runPass(P, taken, mask, ref, newXY, tol, passNo)
            r = find(mask & P.RowNew == 0 & all(isfinite(ref), 2));
            c = find(~taken);
            if isempty(r) || isempty(c), return; end
            [a, b, d] = curation.Reconciler.match(ref(r, :), newXY(c, :), tol);
            if isempty(a), return; end
            rows = r(a); cols = c(b);
            P.RowNew(rows) = cols;
            P.DistPx(rows) = d;
            P.Pass(rows) = passNo;
            taken(cols) = true;
        end

        function s = mtimeUtcText(file, d)
            % 'yyyy-mm-ddTHH:MM:SSZ': the file's last write time in UTC.
            t = NaT;
            try
                ms = java.io.File(file).lastModified();
                if ms > 0
                    t = datetime(double(ms) / 1000, 'ConvertFrom', 'posixtime', 'TimeZone', 'UTC');
                end
            catch
            end
            if isnat(t)
                try
                    u = System.IO.File.GetLastWriteTimeUtc(file);
                    t = datetime(double(u.Year), double(u.Month), double(u.Day), double(u.Hour), ...
                        double(u.Minute), double(u.Second), 'TimeZone', 'UTC');
                catch
                end
            end
            if isnat(t)
                t = datetime(d.datenum, 'ConvertFrom', 'datenum', 'TimeZone', 'local');
                t.TimeZone = 'UTC';
            end
            s = [char(t, 'yyyy-MM-dd''T''HH:mm:ss') 'Z'];
        end

        function s = mtimeText(dn)
            s = char(datetime(dn, 'ConvertFrom', 'datenum', 'Format', 'yyyy-MM-dd''T''HH:mm:ss'));
        end
    end
end

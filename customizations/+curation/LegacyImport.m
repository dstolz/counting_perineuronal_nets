classdef LegacyImport
%LEGACYIMPORT  One-time import of the decisions the two legacy apps stored, into curation rows.
%   Pure functions over a store's column struct (see curation.Store, "Column schema"); they never
%   read or write the legacy files themselves except reading the QC CSV in readQc, and never
%   modify or delete them. curation.Store runs this once per source (Meta.LegacyImported).
%
%   [C, rep] = curation.LegacyImport.apply(C, L, Q, opts)
%       C     store columns (rows created from the locs table L, or an older store)
%       L     the detector locs table as read from '<stem>_locs.csv' (may carry the resolver's
%             CURATED_X/CURATED_Y/NeighborPairID/NeighborResolvedStatus columns)
%       Q     the legacy QC table ('<locs>_QC.csv') or [] when there is none
%       opts  TolPx        position tolerance in pixels (Store: TolUm / umPerPixel)
%             OrphanMergePx  see rule A5 below (default 10 = the resolver's default pair
%                          distance; 0 = the literal "unpaired NaN row -> Bad" rule)
%             QcScale      QC coordinates = full-resolution coordinates * QcScale (1, or the
%                          detection resize factor for a '*_locs_resized_QC.csv')
%             LocsTime     ISO time stamped on resolver-derived labels (locs file time)
%             NOrig        rows the detector wrote, from independent evidence (NaN = unknown;
%                          the store passes the pristine resized twin's row count, or the
%                          manifest's detection count when it is below the file's)
%             NOrigSource  where NOrig came from ("resized", "manifest", "full-resolution locs")
%             FromResized  true when L is resolver work saved to the resized CSV, scaled to full
%                          resolution by the store (reported only)
%             Protected    logical per row of C: rows a person decided (label source human/
%                          confirmed/blind, PosSource human/snap, merged or unmerged by a person).
%                          No resolver rule and no QC move changes them (a forced re-import).
%       rep   struct: resolver (counts per rule, nOrig, nOrigSource, fromResized,
%             nProtectedSkipped), qc (counts, unmatched rows), keptPairs (N x 2 uint32 CellIDs,
%             sorted rows), warnings (string column)
%
%   Row mapping. Each locs row is mapped to a store row by position before anything changes:
%   exact match of the locs X/Y against DET_X/DET_Y (<= 0.01 px), then within TolPx. On a store
%   created from L this is the identity.
%
%   A. Resolver (CellNeighborResolution.saveResolved) - only when L has CURATED_X.
%     The resolver keeps every original row in place, blanks CURATED_X/Y (NaN) of rows it
%     deleted or merged away, appends one row per "Merged" pair (a copy of row A with the merged
%     position) and appends hand-added points (copies of the nearest live row). Pair labels are
%     "<rowA>-<rowB>" (1-based rows of that CSV), ';'-joined in NeighborPairID with the matching
%     ';'-joined NeighborResolvedStatus tokens ("Keep A", "Keep B", "Keep Both", "Merged",
%     "Skipped", "Unresolved").
%     Appended rows: rows after the original detections. Their start is the earliest of (a) a
%     merged-result row (a row carrying a "Merged" pair label a-b with row > a,b) and (b) the
%     detector's row count NOrig when independent evidence gives it, else (heuristic, reported
%     in a warning and as nOrigSource "heuristic") the start of the trailing block of rows that
%     are template copies: they repeat the (score, rescore, class) of an earlier row that is
%     live, or of a deleted row lying within the pair distance (OrphanMergePx, 10 when 0). A
%     genuine detection that only shares its score with a far deleted row is not a copy. Without
%     a score column only (a) applies.
%     A1 "Merged" pair with its appended result row r: r becomes Origin=merged, PosSource=human,
%        DET_X/Y=NaN, X/Y = MEAN of the parents' positions (the stored position of appended
%        merged rows is unreliable: a legacy bug wrote every merged row of a session at the first
%        merge's position); both parents State=merged, MergedInto=CellID(r). Processed in row
%        order, so a merge of an earlier merge result uses that result's corrected position.
%     A2 NaN rows sharing a pair label with a kept (non-NaN) row -> State=merged, MergedInto =
%        the kept partner (the one a "Keep A"/"Keep B" status names, else the nearest).
%     A3 Re-saved files lose the pair labels of deleted rows (legacy bug). An appended live row
%        without a pair label whose (score, rescore, class) equals exactly one unclaimed NaN row
%        A lying within the pair distance of it is taken as A's merge result: like A1 with
%        parents A and the nearest other unclaimed NaN row within OrphanMergePx (if any). A
%        recovered merge always needs that proximity.
%     A4 Appended live rows that are not merge results -> Origin=added, PosSource=human,
%        DET_X/Y=NaN.
%     A5 Remaining NaN rows (no usable pair): if a live row lies within OrphanMergePx, the row is
%        taken as a duplicate deleted directly (or whose pair label a re-save lost) -> State=
%        merged into the nearest live row; otherwise Label=Bad, LabelSource=legacy-resolver,
%        Reviewed=true, ReviewedAt=LocsTime, and a note "legacy resolver: deleted, no partner
%        within <d> px" so later consumers can tell it from a person's Bad. (OrphanMergePx = 0
%        gives the literal rule.)
%     A6 "Keep Both" pairs -> rep.keptPairs.
%     A7 Live rows whose CURATED_X/Y differ from X/Y by more than 1e-6 px -> X/Y = CURATED,
%        PosSource=human. (The resolver overwrote X/Y itself on relocation, so a relocated row's
%        original detector position is not recoverable; its DET_X/Y is the relocated one.)
%
%   Every rule above skips Protected rows (it neither changes them nor merges them away).
%
%   B. QC (CellQualityControl.saveCurrentQC) - QC rows are matched to store rows by the QC file's
%     own X/Y (scaled by 1/QcScale), never by QCSourceRow. Passes, one-to-one, cumulative:
%     exact (<= 0.01 px) against the position the legacy files gave the row (CURATED_X/Y when
%     finite, else X/Y), exact against the raw locs X/Y, then within TolPx against the current
%     effective X/Y, then within TolPx against DET_X/Y. Only when height(Q) == height(L) and at
%     least 95% of QC rows matched their own row index (QC row i -> locs row i) are the
%     remaining unmatched QC rows assigned by row index; those carry a QC re-centring and their
%     QC X/Y is imported as a move (X/Y, PosSource=human) when it differs by more than 0.01 px.
%     Imported rows: QCReviewed true (non-empty QCLabel when there is no QCReviewed column).
%       Good/Bad/Uncertain (any case) -> Label, LabelSource=legacy-qc, Reviewed=true, Reviewer=
%         QCReviewer, ReviewedAt=QCTimestamp (ISO 8601), Notes += QCNotes. Overwrites only labels
%         whose source is "", "auto" or "legacy-resolver"; a QC label that disagrees with a
%         legacy-resolver Bad also gets Flag=recheck (counted as a conflict).
%       Ignore and any custom category -> no label, Flag=later (if empty), Notes += "legacy QC
%         label: <name>".
%     QCNotes of matched rows are imported even when the row was not reviewed.

    methods (Static)

        function [C, rep] = apply(C, L, Q, opts)
            if nargin < 3, Q = []; end
            if nargin < 4, opts = struct(); end
            opts = curation.LegacyImport.fillOpts(opts);
            rep = struct('resolver', curation.LegacyImport.emptyResolverReport(), ...
                'qc', curation.LegacyImport.emptyQcReport(), ...
                'keptPairs', zeros(0, 2, 'uint32'), 'warnings', strings(0, 1));
            if isempty(L) || ~istable(L)
                L = table();
            end
            [lx, ly] = curation.LegacyImport.xyOf(L);
            map = curation.LegacyImport.mapLocsRows(C, lx, ly, opts.TolPx);
            prot = false(numel(C.CellID), 1);
            if ~isempty(opts.Protected)
                prot(:) = logical(opts.Protected(:));
            end
            opts.Protected = prot;
            legacyXY = [lx, ly];
            names = string(L.Properties.VariableNames);
            if any(strcmpi(names, "CURATED_X"))
                [C, rr, kp, legacyXY] = curation.LegacyImport.applyResolver(C, L, map, opts);
                rep.resolver = rr;
                rep.keptPairs = kp;
                rep.warnings = [rep.warnings; rr.warnings];
            end
            if ~isempty(Q) && istable(Q) && height(Q) > 0
                [C, rq] = curation.LegacyImport.applyQc(C, Q, map, [lx, ly], legacyXY, height(L), opts);
                rep.qc = rq;
                rep.warnings = [rep.warnings; rq.warnings];
            end
        end

        function Q = readQc(path)
            %READQC  The legacy QC table (strings as string), or [] when missing/unreadable.
            Q = [];
            path = char(path);
            if isempty(path) || ~isfile(path), return; end
            try
                Q = curation.LegacyImport.readCsv(path, ["QCLabel", "QCReviewer", "QCNotes", ...
                    "imgName", "NeighborPairID", "NeighborResolvedStatus"]);
            catch
                Q = [];
            end
        end

        function T = readCsv(path, textCols)
            %READCSV  readtable with detected types, except that the named columns (when present)
            %   are always read as string (pair labels like "1-2" must not become dates, and an
            %   all-empty text column must not become NaN).
            o = detectImportOptions(char(path), 'TextType', 'string', ...
                'VariableNamingRule', 'preserve', 'Delimiter', ',');
            names = string(o.VariableNames);
            hit = names(ismember(lower(names), lower(string(textCols))));
            if ~isempty(hit)
                o = setvartype(o, cellstr(hit), 'string');
                o = setvaropts(o, cellstr(hit), 'FillValue', "");
            end
            T = readtable(char(path), o);
        end

        function map = mapLocsRows(C, lx, ly, tolPx)
            %MAPLOCSROWS  Store row of each locs row (0 = none), by exact then near position.
            n = numel(lx);
            map = zeros(n, 1);
            if n == 0 || isempty(C.CellID), return; end
            det = [double(C.DET_X), double(C.DET_Y)];
            freeS = true(numel(C.CellID), 1);
            for tol = [0.01, tolPx]
                r = find(map == 0);
                s = find(freeS);
                if isempty(r) || isempty(s), break; end
                [a, b] = curation.Reconciler.match([lx(r), ly(r)], det(s, :), tol);
                map(r(a)) = s(b);
                freeS(s(b)) = false;
            end
        end
    end

    %% ---------------------------------------------------------------- resolver
    methods (Static, Access = private)

        function [C, rep, keptPairs, legacyXY] = applyResolver(C, L, map, opts)
            rep = curation.LegacyImport.emptyResolverReport();
            rep.present = true;
            prot = opts.Protected;   % rows a person decided: no rule touches them
            nL = height(L);
            rep.nRows = nL;
            names = string(L.Properties.VariableNames);
            [lx, ly] = curation.LegacyImport.xyOf(L);
            cx = curation.LegacyImport.numCol(L, names, "CURATED_X", nL);
            cy = curation.LegacyImport.numCol(L, names, "CURATED_Y", nL);
            if all(isnan(cy)) && ~all(isnan(cx)), cy(~isnan(cx)) = ly(~isnan(cx)); end
            isNaN = isnan(cx) | isnan(cy);
            live = ~isNaN;
            legacyXY = [lx, ly];
            legacyXY(live, :) = [cx(live), cy(live)];
            pid = curation.LegacyImport.strCol(L, names, "NeighborPairID", nL);
            pst = curation.LegacyImport.strCol(L, names, "NeighborResolvedStatus", nL);
            keptPairs = zeros(0, 2, 'uint32');

            % ---- pair tokens: (row, a, b, status) ---------------------------------
            tokRow = zeros(0, 1); tokA = zeros(0, 1); tokB = zeros(0, 1); tokSt = strings(0, 1);
            for r = find(strlength(pid) > 0)'
                ids = strtrim(split(pid(r), ";"));
                sts = strtrim(split(pst(r), ";"));
                for t = 1:numel(ids)
                    ab = regexp(char(ids(t)), '^\s*(\d+)\s*-\s*(\d+)\s*$', 'tokens', 'once');
                    if isempty(ab), continue; end
                    st = "";
                    if t <= numel(sts), st = sts(t); end
                    tokRow(end + 1, 1) = r; %#ok<AGROW>
                    tokA(end + 1, 1) = str2double(ab{1}); %#ok<AGROW>
                    tokB(end + 1, 1) = str2double(ab{2}); %#ok<AGROW>
                    tokSt(end + 1, 1) = st; %#ok<AGROW>
                end
            end
            validTok = tokA >= 1 & tokA <= nL & tokB >= 1 & tokB <= nL & tokA ~= tokB;
            tokRow = tokRow(validTok); tokA = tokA(validTok); tokB = tokB(validTok); tokSt = tokSt(validTok);
            if ~isempty(tokA)
                [pairs, ~, pidx] = unique([tokA, tokB], 'rows', 'stable');
                pairStatus = strings(size(pairs, 1), 1);
                for k = 1:numel(tokSt)
                    if strlength(pairStatus(pidx(k))) == 0 && strlength(tokSt(k)) > 0
                        pairStatus(pidx(k)) = tokSt(k);
                    end
                end
            else
                pairs = zeros(0, 2); pidx = zeros(0, 1); pairStatus = strings(0, 1);
            end
            rep.nPairs = size(pairs, 1);
            isMergedSt = lower(pairStatus) == "merged";

            % ---- appended rows ------------------------------------------------------
            pairPx = opts.OrphanMergePx;
            if ~(pairPx > 0), pairPx = 10; end
            sigCols = ["score", "rescore", "class"];
            sig = nan(nL, 0);
            for c = sigCols
                if any(strcmpi(names, c))
                    sig(:, end + 1) = curation.LegacyImport.numCol(L, names, c, nL); %#ok<AGROW>
                end
            end
            twinBefore = false(nL, 1);
            hasScore = any(strcmpi(names, "score"));
            if hasScore && nL > 0
                key = sig;
                key(isnan(key)) = -Inf;   % rescore may be absent/NaN; score must be finite
                okSig = isfinite(sig(:, 1));
                [~, ~, g] = unique(key, 'rows', 'stable');
                for grp = reshape(find(accumarray(g, 1) > 1), 1, [])
                    mem = find(g == grp & okSig);
                    for q = 2:numel(mem)
                        r = mem(q);
                        prev = mem(1:q - 1);
                        % a template copy repeats a live row, or a deleted row lying near it
                        near = hypot(lx(prev) - lx(r), ly(prev) - ly(r)) <= pairPx;
                        twinBefore(r) = any(live(prev) | near);
                    end
                end
            else
                rep.warnings(end + 1, 1) = "No score column: hand-added rows can only be told apart from detections by merge pair labels.";
            end
            if isfinite(opts.NOrig) && opts.NOrig >= 0 && opts.NOrig <= nL
                nOrig = round(opts.NOrig);
                rep.nOrigSource = string(opts.NOrigSource);
                if strlength(rep.nOrigSource) == 0, rep.nOrigSource = "given"; end
            else
                suffixStart = nL + 1;
                while suffixStart > 1 && twinBefore(suffixStart - 1)
                    suffixStart = suffixStart - 1;
                end
                nOrig = suffixStart - 1;
                rep.nOrigSource = "heuristic";
                rep.warnings(end + 1, 1) = ['The detector''s row count is not recorded (no pristine ' ...
                    '*_locs_resized.csv twin, no manifest count): the rows the resolver appended were ' ...
                    'inferred from repeated scores near their templates.'];
            end
            % merged-result rows from labels: row r carrying a Merged label a-b with r > a, b
            isResultTok = isMergedSt(pidx) & tokRow ~= tokA & tokRow ~= tokB ...
                & tokRow > max(tokA, tokB);
            resultRowsLabelled = unique(tokRow(isResultTok));
            if ~isempty(resultRowsLabelled)
                nOrig = min(nOrig, min(resultRowsLabelled) - 1);
            end
            appended = (1:nL)' > nOrig;
            rep.nOrig = nOrig;
            rep.nAppended = nnz(appended);
            rep.fromResized = logical(opts.FromResized);

            % store row helpers
            sr = map;            % locs row -> store row (0 = not in store)
            claimed = false(nL, 1);   % NaN rows already assigned
            isResult = false(nL, 1);

            % ---- A1: Merged pairs with their result rows ---------------------------
            mergedPairs = find(isMergedSt);
            resOfPair = zeros(size(pairs, 1), 1);
            for p = mergedPairs'
                cand = tokRow(pidx == p & isResultTok);
                cand = cand(appended(cand));
                if ~isempty(cand)
                    resOfPair(p) = min(cand);
                end
            end
            rep.nMergedPairs = numel(mergedPairs);
            [~, ordP] = sort(resOfPair);
            for p = ordP'
                r = resOfPair(p);
                if r == 0 || sr(r) == 0, continue; end
                if prot(sr(r)), rep.nProtectedSkipped = rep.nProtectedSkipped + 1; continue; end
                parents = pairs(p, :);
                parents = parents(sr(parents) > 0);
                parents = parents(~prot(sr(parents)));
                if isempty(parents), continue; end
                C = curation.LegacyImport.makeMergeResult(C, sr(r), sr(parents));
                isResult(r) = true;
                claimed(parents(isNaN(parents))) = true;
                rep.nMergeResults = rep.nMergeResults + 1;
            end

            % ---- A2: NaN rows sharing a pair with a kept row -----------------------
            for r = find(isNaN & ~claimed & sr > 0)'
                inPair = find(pairs(:, 1) == r | pairs(:, 2) == r);
                if isempty(inPair), continue; end
                if prot(sr(r))
                    claimed(r) = true;
                    rep.nProtectedSkipped = rep.nProtectedSkipped + 1;
                    continue;
                end
                partners = zeros(0, 1); preferred = zeros(0, 1);
                for p = inPair'
                    other = pairs(p, 1);
                    if other == r, other = pairs(p, 2); end
                    if ~live(other) || sr(other) == 0, continue; end
                    partners(end + 1, 1) = other; %#ok<AGROW>
                    st = lower(pairStatus(p));
                    keptIsA = st == "keep a" && pairs(p, 1) == other;
                    keptIsB = st == "keep b" && pairs(p, 2) == other;
                    if keptIsA || keptIsB
                        preferred(end + 1, 1) = other; %#ok<AGROW>
                    end
                end
                if isempty(partners), continue; end
                if ~isempty(preferred), partners = preferred; end
                d = hypot(lx(partners) - lx(r), ly(partners) - ly(r));
                [~, k] = min(d);
                keeper = partners(k);
                C = curation.LegacyImport.mergeInto(C, sr(r), sr(keeper));
                claimed(r) = true;
                rep.nMergedIntoKept = rep.nMergedIntoKept + 1;
            end

            % ---- A3: appended live rows that copy a deleted row's signature --------
            if hasScore
                pairedRows = unique([tokRow; tokA; tokB]);
                for r = find(appended & live & ~isResult & sr > 0)'
                    if ismember(r, pairedRows), continue; end
                    if prot(sr(r)), continue; end
                    twins = find(all(sig(1:r - 1, :) == sig(r, :) | (isnan(sig(1:r - 1, :)) & isnan(sig(r, :))), 2));
                    twins = twins(isNaN(twins) & ~claimed(twins) & sr(twins) > 0);
                    % a recovered merge needs the result next to its parent (finding 7)
                    twins = twins(hypot(lx(twins) - cx(r), ly(twins) - cy(r)) <= pairPx);
                    twins = twins(~prot(sr(twins)));
                    if numel(twins) ~= 1, continue; end
                    a = twins;
                    parents = a;
                    if opts.OrphanMergePx > 0
                        others = find(isNaN & ~claimed & sr > 0);
                        others = others(others ~= a & ~prot(sr(others)));
                        if ~isempty(others)
                            d = hypot(lx(others) - lx(a), ly(others) - ly(a));
                            [dm, k] = min(d);
                            if dm <= opts.OrphanMergePx
                                parents = [a; others(k)];
                            end
                        end
                    end
                    C = curation.LegacyImport.makeMergeResult(C, sr(r), sr(parents));
                    isResult(r) = true;
                    claimed(parents) = true;
                    rep.nRecoveredMerges = rep.nRecoveredMerges + 1;
                end
            end

            % ---- A4: appended live rows that are not merge results -> added ---------
            for r = find(appended & live & ~isResult & sr > 0)'
                s = sr(r);
                if prot(s), rep.nProtectedSkipped = rep.nProtectedSkipped + 1; continue; end
                C.Origin(s) = "added";
                C.PosSource(s) = "human";
                C.DET_X(s) = NaN; C.DET_Y(s) = NaN;
                C.X(s) = cx(r); C.Y(s) = cy(r);
                rep.nAdded = rep.nAdded + 1;
            end

            % ---- A5: remaining NaN rows ---------------------------------------------
            orphans = find(isNaN & ~claimed & sr > 0);
            if ~isempty(orphans)
                liveRows = find(live & sr > 0);
                liveRows = liveRows(C.State(sr(liveRows)) ~= "merged");
                orphans = orphans(:);
                target = zeros(numel(orphans), 1);
                if opts.OrphanMergePx > 0 && ~isempty(liveRows)
                    [i, j, d] = curation.Reconciler.candidatePairs([lx(orphans), ly(orphans)], ...
                        legacyXY(liveRows, :), opts.OrphanMergePx);
                    if ~isempty(i)
                        [~, ord] = sortrows([i, d]);
                        i = i(ord); j = j(ord);
                        [ui, firstIdx] = unique(i, 'stable');
                        target(ui) = liveRows(j(firstIdx));
                    end
                end
                for k = 1:numel(orphans)
                    r = orphans(k);
                    if prot(sr(r))
                        claimed(r) = true;
                        rep.nProtectedSkipped = rep.nProtectedSkipped + 1;
                        continue;
                    end
                    if target(k) > 0
                        C = curation.LegacyImport.mergeInto(C, sr(r), sr(target(k)));
                        rep.nOrphanMerged = rep.nOrphanMerged + 1;
                    else
                        s = sr(r);
                        C.Label(s) = "Bad";
                        C.LabelSource(s) = "legacy-resolver";
                        C.Reviewed(s) = true;
                        C.Reviewer(s) = "";
                        C.ReviewedAt(s) = string(opts.LocsTime);
                        C.Notes(s) = curation.LegacyImport.joinNote(C.Notes(s), ...
                            sprintf("legacy resolver: deleted, no partner within %g px", opts.OrphanMergePx));
                        rep.nBad = rep.nBad + 1;
                    end
                    claimed(r) = true;
                end
            end

            % ---- A6: Keep Both ------------------------------------------------------
            kb = find(lower(pairStatus) == "keep both");
            for p = kb'
                a = pairs(p, 1); b = pairs(p, 2);
                if sr(a) > 0 && sr(b) > 0
                    keptPairs(end + 1, :) = sort(uint32([C.CellID(sr(a)), C.CellID(sr(b))])); %#ok<AGROW>
                end
            end
            keptPairs = unique(keptPairs, 'rows');
            rep.nKeepBoth = size(keptPairs, 1);

            % ---- A7: moves ----------------------------------------------------------
            moved = find(live & ~appended & ~isResult & sr > 0 & ...
                (abs(cx - lx) > 1e-6 | abs(cy - ly) > 1e-6));
            pm = prot(sr(moved));
            rep.nProtectedSkipped = rep.nProtectedSkipped + nnz(pm);
            moved = moved(~pm);
            for r = moved'
                s = sr(r);
                C.X(s) = cx(r); C.Y(s) = cy(r);
                C.PosSource(s) = "human";
            end
            rep.nMoved = numel(moved);
            rep.nMergedAway = nnz(C.State == "merged");
        end

        function C = makeMergeResult(C, sRes, sParents)
            % Row sRes becomes the merged result of parents sParents (store rows).
            sParents = sParents(:);
            sParents = sParents(sParents ~= sRes);
            if ~isempty(sParents)
                C.X(sRes) = mean(double(C.X(sParents)));
                C.Y(sRes) = mean(double(C.Y(sParents)));
            end
            C.Origin(sRes) = "merged";
            C.PosSource(sRes) = "human";
            C.DET_X(sRes) = NaN; C.DET_Y(sRes) = NaN;
            for s = sParents'
                C = curation.LegacyImport.mergeInto(C, s, sRes);
            end
        end

        function C = mergeInto(C, sChild, sKeeper)
            C.State(sChild) = "merged";
            C.MergedInto(sChild) = C.CellID(sKeeper);
            % anything already merged into the child follows it to the keeper
            C.MergedInto(C.MergedInto == C.CellID(sChild)) = C.CellID(sKeeper);
        end
    end

    %% ---------------------------------------------------------------------- QC
    methods (Static, Access = private)

        function [C, rep] = applyQc(C, Q, map, rawXY, legacyXY, nL, opts)
            rep = curation.LegacyImport.emptyQcReport();
            rep.present = true;
            nQ = height(Q);
            rep.nRows = nQ;
            names = string(Q.Properties.VariableNames);
            if ~all(ismember(["X", "Y"], names))
                rep.warnings(end + 1, 1) = "QC file has no X/Y columns; nothing imported.";
                return;
            end
            scale = opts.QcScale;
            if ~(scale > 0), scale = 1; end
            qx = curation.LegacyImport.numCol(Q, names, "X", nQ) / scale;
            qy = curation.LegacyImport.numCol(Q, names, "Y", nQ) / scale;
            lab = curation.LegacyImport.strCol(Q, names, "QCLabel", nQ);
            if any(names == "QCReviewed")
                sel = curation.LegacyImport.logicalCol(Q.QCReviewed);
            else
                sel = strlength(lab) > 0;
            end
            reviewer = curation.AtomicIO.cleanText(curation.LegacyImport.strCol(Q, names, "QCReviewer", nQ));
            lab = curation.AtomicIO.cleanText(lab);
            notes = curation.AtomicIO.cleanText(curation.LegacyImport.strCol(Q, names, "QCNotes", nQ));
            when = strings(nQ, 1);
            if any(names == "QCTimestamp")
                when = curation.LegacyImport.isoTimes(Q.QCTimestamp);
            end
            rep.nSelected = nnz(sel);

            % ---- reference positions per store row ---------------------------------
            nS = numel(C.CellID);
            legRef = nan(nS, 2); rawRef = nan(nS, 2);
            ok = map > 0;
            legRef(map(ok), :) = legacyXY(ok, :);
            rawRef(map(ok), :) = rawXY(ok, :);
            noLoc = ~any(isfinite(legRef), 2);
            legRef(noLoc, :) = [C.X(noLoc), C.Y(noLoc)];
            effRef = [double(C.X), double(C.Y)];
            detRef = [double(C.DET_X), double(C.DET_Y)];
            q2s = zeros(nQ, 1);
            takenS = false(nS, 1);
            passes = {legRef, 0.01, 1; rawRef, 0.01, 1; effRef, opts.TolPx, 2; detRef, opts.TolPx, 2};
            how = zeros(nQ, 1);
            for k = 1:size(passes, 1)
                q = find(q2s == 0 & isfinite(qx) & isfinite(qy));
                s = find(~takenS);
                if isempty(q) || isempty(s), break; end
                [a, b] = curation.Reconciler.match([qx(q), qy(q)], passes{k, 1}(s, :), passes{k, 2});
                q2s(q(a)) = s(b);
                takenS(s(b)) = true;
                how(q(a)) = passes{k, 3};
            end
            rep.nMatchedExact = nnz(how == 1);
            rep.nMatchedNear = nnz(how == 2);

            % ---- row index for the remainder (only when clearly in place) ----------
            byIndex = false(nQ, 1);
            if nQ == nL && nQ > 0
                inPlace = false(nQ, 1);
                okm = q2s > 0 & map(1:nQ) > 0;
                inPlace(okm) = q2s(okm) == map(okm);
                rep.inPlaceFraction = nnz(inPlace) / nQ;
                if rep.inPlaceFraction >= 0.95
                    for q = find(q2s == 0)'
                        s = map(q);
                        if s > 0 && ~takenS(s)
                            q2s(q) = s;
                            takenS(s) = true;
                            byIndex(q) = true;
                        end
                    end
                end
            end
            rep.nByIndex = nnz(byIndex);
            for q = find(byIndex)'
                s = q2s(q);
                if opts.Protected(s), continue; end
                if isfinite(qx(q)) && isfinite(qy(q)) && hypot(qx(q) - C.X(s), qy(q) - C.Y(s)) > 0.01
                    C.X(s) = qx(q); C.Y(s) = qy(q);
                    C.PosSource(s) = "human";
                    rep.nMoves = rep.nMoves + 1;
                end
            end

            % ---- labels, flags, notes -----------------------------------------------
            canon = ["Good", "Bad", "Uncertain"];
            overwritable = ["", "auto", "legacy-resolver"];
            for q = find(q2s > 0)'
                s = q2s(q);
                if strlength(notes(q)) > 0 && ~contains(C.Notes(s), notes(q))
                    C.Notes(s) = curation.LegacyImport.joinNote(C.Notes(s), notes(q));
                end
                if ~sel(q), continue; end
                lb = strtrim(lab(q));
                ci = find(strcmpi(canon, lb), 1);
                if ~isempty(ci)
                    if ~ismember(C.LabelSource(s), overwritable)
                        rep.nSkippedHuman = rep.nSkippedHuman + 1;
                        continue;
                    end
                    newLab = canon(ci);
                    if C.LabelSource(s) == "legacy-resolver" && C.Label(s) ~= newLab
                        if strlength(C.Flag(s)) == 0, C.Flag(s) = "recheck"; end
                        rep.nConflicts = rep.nConflicts + 1;
                    end
                    C.Label(s) = newLab;
                    C.LabelSource(s) = "legacy-qc";
                    C.Reviewed(s) = true;
                    C.Reviewer(s) = reviewer(q);
                    C.ReviewedAt(s) = when(q);
                    rep.(lower(newLab)) = rep.(lower(newLab)) + 1;
                    if C.State(s) == "merged", rep.nOnMerged = rep.nOnMerged + 1; end
                elseif strlength(lb) > 0
                    if strlength(C.Flag(s)) == 0, C.Flag(s) = "later"; end
                    C.Notes(s) = curation.LegacyImport.joinNote(C.Notes(s), "legacy QC label: " + lb);
                    rep.nOtherCategory = rep.nOtherCategory + 1;
                else
                    rep.nReviewedNoLabel = rep.nReviewedNoLabel + 1;
                end
            end
            un = find(sel & q2s == 0);
            rep.nUnmatched = numel(un);
            rep.unmatched = table(un, qx(un), qy(un), lab(un), ...
                'VariableNames', {'QcRow', 'X', 'Y', 'QCLabel'});
            if rep.nUnmatched > 0
                rep.warnings(end + 1, 1) = sprintf('%d reviewed QC row(s) matched no detection by position.', rep.nUnmatched);
            end
        end

        function s = joinNote(a, b)
            a = string(a); b = string(b);
            if strlength(a) == 0
                s = b;
            elseif strlength(b) == 0
                s = a;
            else
                s = a + " | " + b;
            end
        end

        function s = isoTimes(v)
            n = numel(v);
            s = strings(n, 1);
            try
                if isdatetime(v)
                    s = curation.AtomicIO.isoFromDatetime(v);
                    return;
                end
                v = string(v);
                v(ismissing(v)) = "";
                has = strlength(strtrim(v)) > 0;
                if ~any(has), return; end
                try
                    t = datetime(v(has));
                    s(has) = curation.AtomicIO.isoFromDatetime(t);
                catch
                    s(has) = v(has);   % keep the text as written
                end
            catch
            end
        end
    end

    %% ------------------------------------------------------------------ helpers
    methods (Static, Access = private)

        function opts = fillOpts(opts)
            d = struct('TolPx', 8 / 0.645, 'OrphanMergePx', 10, 'QcScale', 1, 'LocsTime', "", ...
                'NOrig', NaN, 'NOrigSource', "", 'FromResized', false, 'Protected', []);
            f = fieldnames(d);
            for k = 1:numel(f)
                if ~isfield(opts, f{k}) || isempty(opts.(f{k}))
                    opts.(f{k}) = d.(f{k});
                end
            end
        end

        function [x, y] = xyOf(T)
            n = height(T);
            if n == 0 || width(T) == 0
                x = zeros(n, 1); y = zeros(n, 1);
                return;
            end
            names = string(T.Properties.VariableNames);
            x = curation.LegacyImport.numCol(T, names, "X", n);
            y = curation.LegacyImport.numCol(T, names, "Y", n);
        end

        function v = numCol(T, names, name, n)
            k = find(strcmpi(names, name), 1);
            if isempty(k)
                v = nan(n, 1);
                return;
            end
            v = T.(char(names(k)));
            if isnumeric(v) || islogical(v)
                v = double(v);
            elseif isdatetime(v) || isduration(v)
                v = nan(n, 1);
            else
                v = str2double(string(v));
            end
            v = v(:);
        end

        function v = strCol(T, names, name, n)
            k = find(strcmpi(names, name), 1);
            if isempty(k)
                v = strings(n, 1);
                return;
            end
            v = T.(char(names(k)));
            if isnumeric(v) && all(isnan(double(v(:))))
                v = strings(n, 1);   % an all-empty text column read back as NaN
            else
                v = string(v);
            end
            v(ismissing(v)) = "";
            v = v(:);
        end

        function v = logicalCol(x)
            if islogical(x)
                v = x(:);
            elseif isnumeric(x)
                v = x(:) ~= 0 & ~isnan(x(:));
            else
                s = lower(strtrim(string(x(:))));
                v = s == "true" | s == "1" | s == "yes";
            end
        end

        function r = emptyResolverReport()
            r = struct('present', false, 'nRows', 0, 'nOrig', 0, 'nAppended', 0, 'nPairs', 0, ...
                'nMergedPairs', 0, 'nMergeResults', 0, 'nMergedIntoKept', 0, ...
                'nRecoveredMerges', 0, 'nOrphanMerged', 0, 'nBad', 0, 'nAdded', 0, ...
                'nMoved', 0, 'nKeepBoth', 0, 'nMergedAway', 0, 'nOrigSource', "", ...
                'fromResized', false, 'nProtectedSkipped', 0, 'warnings', strings(0, 1));
        end

        function r = emptyQcReport()
            r = struct('present', false, 'path', "", 'nRows', 0, 'nSelected', 0, ...
                'nMatchedExact', 0, 'nMatchedNear', 0, 'nByIndex', 0, 'inPlaceFraction', NaN, ...
                'good', 0, 'bad', 0, 'uncertain', 0, 'nOtherCategory', 0, 'nReviewedNoLabel', 0, ...
                'nConflicts', 0, 'nSkippedHuman', 0, 'nOnMerged', 0, 'nMoves', 0, ...
                'nUnmatched', 0, 'unmatched', table(zeros(0, 1), zeros(0, 1), zeros(0, 1), ...
                strings(0, 1), 'VariableNames', {'QcRow', 'X', 'Y', 'QCLabel'}), ...
                'warnings', strings(0, 1));
        end
    end
end

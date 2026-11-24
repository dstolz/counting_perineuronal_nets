classdef Queues
%QUEUES  Review queues cut into homogeneous pages (pure data in, data out).
%
%   pages = curation.Queues.review(T, p, opts)
%   pages = curation.Queues.flagged(T, opts)
%   pages = curation.Queues.vanishedGood(T, opts)
%   pages = curation.Queues.browse(T, p, filter, opts)
%   s     = curation.Queues.summary(T, p, opts)
%   ids   = curation.Queues.eligible(T, opts)
%
%   A page is a struct with fields
%     Ids     K x 1 uint32, display order
%     P       K x 1 double, P(Good) of each id (for a blind tile: recorded, NEVER shown)
%     Default string "Good" | "Bad" | ""  (what Enter applies to untouched ORDINARY tiles; never
%             to a blind tile)
%     Band    string "middle-high" | "middle-low" | "good" | "bad" | "blind" | queue name
%     Blind   K x 1 logical: true for a blind tile (see BLIND TILES)
%     Title   short human-readable title
%     Queue   string "review" | "flagged" | "vanishedGood" | "browse"
%     PageId  string, stable for a given queue and page content (for journaling)
%   Page arrays are N x 1 struct arrays; with nothing to show they are 0 x 1
%   with the same fields.
%
%   opts fields: PageSize (required), Bands = [0.15 0.5 0.85],
%   Order = ["middle" "good" "bad"], Raw = [] (N x 1 raw model score: breaks ties in P, see
%   ORDER), MaxBlindFraction = 0.15, BlindRoles = ["holdout" "confirm-audit"].
%
%   ORDER. Inside a band (and in the list queues) rows are sorted by P, ties in P by opts.Raw
%   (the uncalibrated score of curation.AssistModel.predict, same direction as P), and only then
%   by CellID. P from AssistModel.predict already keeps the order of its raw score (it is strictly
%   increasing in it), so opts.Raw matters only for P from elsewhere; NaN Raw takes the row's P.
%
%   BLIND TILES (review queue only). A row whose AuditRole is one of opts.BlindRoles and that
%   has not been decided blind yet (LabelSource ~= "blind"; State active, not Excluded, Flag "")
%   is a blind tile, whatever its Reviewed / Label: holdout rows (unlabelled) and confirm-audit
%   rows (labelled earlier by bulk confirmation) alike. Rows with any other non-empty AuditRole
%   are never ordinary tiles. Blind tiles are interleaved into the ordinary pages, front-loaded
%   (the first pages of the queue take them first, so the audit fills early), at most
%   floor(MaxBlindFraction * PageSize) per page and never more than MaxBlindFraction of a page,
%   at positions that are pseudo-random but deterministic given the ids (the same input in any
%   row order gives the same pages). Which blind tiles come first is also a deterministic hash
%   of the CellID. Blind tiles left over when the ordinary rows run out fill blind-only pages
%   (Band "blind", Default "").
%   THE GUI MUST: show a blind tile with a neutral border and no proposal (neither P nor the
%   page default), require an explicit key for it (Enter must NOT apply the page Default to it),
%   write its decision with LabelSource "blind" (setLabel(id, label, "blind")), and not advance
%   past a page while one of its blind tiles is undecided. A blind tile's decision overwrites
%   its label; the earlier label of a confirm-audit row is recovered from the journal for the
%   report (curation.ProjectIndex: PriorLabel, PriorProposalP). The GUI's queue table must carry
%   the AuditRole column; without it no row is blind (and holdout rows look ordinary).
%
%   See also curation.Proposals, curation.Audit, curation.AssistModel.

    properties (Constant)
        BLIND_ROLES = ["holdout" "confirm-audit"]
    end

    methods (Static)

        function pages = review(T, p, opts)
        %REVIEW  Pages of the review queue.
        %   Ordinary rows: State "active", not Reviewed, not Excluded, Label "", Flag "" and
        %   AuditRole "" (when the column exists). p is the N x 1 P(Good) aligned with the rows
        %   of T. Bands by P: bad < Bands(1); middle-low [Bands(1),Bands(2)); middle-high
        %   [Bands(2),Bands(3)); good >= Bands(3). A page never holds more than PageSize ids and
        %   never crosses a band edge; its Default is Good for good and middle-high, Bad for bad
        %   and middle-low. Page order follows opts.Order ("middle" = middle-high then
        %   middle-low). Sort inside a band: middle-high and good by P descending, middle-low and
        %   bad by P ascending, ties by opts.Raw (same direction), then CellID. If a band's last
        %   page would hold fewer than 25% of PageSize and the band has at least two pages, the
        %   ids of its last two pages are split evenly between them. Blind tiles: see the class
        %   help. Vectorised; ~ms for 3,000 rows.
            opts = curation.Queues.fillOpts(opts);
            ps = opts.PageSize;
            b = opts.Bands(:)';
            n = height(T);
            p = double(p(:));
            p(isnan(p)) = 0.5;
            raw = curation.Queues.rawKey(opts, p, n);
            [m, bm] = curation.Queues.masks(T, opts);
            ids = T.CellID(m);
            P = p(m);
            Rw = raw(m);
            % blind tiles: deterministic pseudo-random order by CellID
            bIds = uint32(T.CellID(bm));
            bIds = bIds(:);
            bP = p(bm);
            [~, o] = sort(curation.Queues.hash01(bIds, 0));
            bIds = bIds(o); bP = bP(o);
            nB = numel(bIds);
            f = opts.MaxBlindFraction;
            capB = floor(f * ps);

            bandMask = struct( ...
                'mh', P >= b(2) & P < b(3), ...
                'ml', P >= b(1) & P < b(2), ...
                'good', P >= b(3), ...
                'bad', P < b(1));
            spec = struct( ...
                'mh',   {{"middle-high", "Good", -1, "Middle, leaning good"}}, ...
                'ml',   {{"middle-low",  "Bad",   1, "Middle, leaning bad"}}, ...
                'good', {{"good",        "Good", -1, "Likely good"}}, ...
                'bad',  {{"bad",         "Bad",   1, "Likely bad"}});

            keys = strings(1, 0);
            for t = reshape(string(opts.Order), 1, [])
                switch lower(t)
                    case "middle", keys = [keys, "mh", "ml"]; %#ok<AGROW>
                    case "good",   keys = [keys, "good"]; %#ok<AGROW>
                    case "bad",    keys = [keys, "bad"]; %#ok<AGROW>
                    otherwise
                        error('curation:Queues:badOrder', 'Unknown Order entry "%s".', t);
                end
            end

            % pass 1: sort each band and cut it into pages (ordinary count + blind count each)
            ng = numel(keys);
            grp = cell(ng, 1);
            total = 0;
            bLeft = nB;
            for g = 1:ng
                k = char(keys(g));
                sp = spec.(k);
                idx = find(bandMask.(k));
                if isempty(idx), continue; end
                [~, o] = sortrows([sp{3} * P(idx), sp{3} * Rw(idx), double(ids(idx))]);
                idx = idx(o);
                [sz, nb] = curation.Queues.cutBand(numel(idx), ps, capB, f, bLeft);
                bLeft = bLeft - sum(nb);
                grp{g} = struct('idx', idx, 'sizes', sz, 'blind', nb);
                total = total + numel(sz);
            end
            nOnly = ceil(bLeft / ps);           % blind tiles left over: blind-only pages
            total = total + nOnly;

            % pass 2: build the pages
            pages = curation.Queues.emptyPages();
            cell_ = cell(total, 1);
            page = 0;
            bi = 0;
            for g = 1:ng
                if isempty(grp{g}), continue; end
                sp = spec.(char(keys(g)));
                idx = grp{g}.idx;
                sz = grp{g}.sizes;
                nb = grp{g}.blind;
                pos = 0;
                for j = 1:numel(sz)
                    page = page + 1;
                    sel = idx(pos + (1:sz(j)));
                    pos = pos + sz(j);
                    if nb(j) == 0
                        cell_{page} = curation.Queues.makePage(ids(sel), P(sel), ...
                            sp{2}, sp{1}, "review", sp{4}, page, total);
                    else
                        bsel = bi + (1:nb(j));
                        bi = bi + nb(j);
                        [pid, pP, pB] = curation.Queues.interleave(uint32(ids(sel)), P(sel), ...
                            bIds(bsel), bP(bsel));
                        cell_{page} = curation.Queues.makePage(pid, pP, sp{2}, sp{1}, "review", ...
                            sp{4}, page, total, pB);
                    end
                end
            end
            for j = 1:nOnly
                page = page + 1;
                bsel = bi + 1:min(nB, bi + ps);
                bi = bsel(end);
                cell_{page} = curation.Queues.makePage(bIds(bsel), bP(bsel), "", "blind", "review", ...
                    "Blind tiles", page, total, true(numel(bsel), 1));
            end
            if total > 0, pages = vertcat(cell_{:}); end
        end

        function pages = flagged(T, opts)
        %FLAGGED  Pages of rows with a non-empty Flag (State active, not Excluded).
        %   Default is "" (Enter applies nothing). Sorted by P descending, then opts.Raw, then
        %   CellID; paged by opts.PageSize. P is ModelP where finite, else the cold-start
        %   proposal. A flagged row that is a pending blind tile (class help) has Blind true.
            m = curation.Queues.activeMask(T) & curation.Queues.str(T, 'Flag') ~= "";
            opts = curation.Queues.fillOpts(opts);
            bl = curation.Queues.pendingBlind(T, opts);
            pages = curation.Queues.listQueue(T, m, "flagged", "Flagged", opts, [], bl);
        end

        function pages = vanishedGood(T, opts)
        %VANISHEDGOOD  Pages of kept Good cells whose detection has vanished.
        %   Rows: State active, Label Good, Reviewed, ~InLocs, Origin detected.
        %   Default is "". Sorted by P descending, then opts.Raw, then CellID.
            m = curation.Queues.activeMask(T) & curation.Queues.str(T, 'Label') == "Good" ...
                & logical(T.Reviewed(:)) & ~logical(T.InLocs(:)) ...
                & curation.Queues.str(T, 'Origin') == "detected";
            pages = curation.Queues.listQueue(T, m, "vanishedGood", "Vanished good", opts);
        end

        function pages = browse(T, p, filter, opts)
        %BROWSE  Pages of already-reviewed rows for re-inspection.
        %   filter: "Good" | "Bad" | "Uncertain" (Reviewed rows with that Label),
        %   "auto" (rows with LabelSource "auto", reviewed or not), "all" (reviewed
        %   rows and auto rows). Only State active rows. Default is "". p is the
        %   N x 1 P(Good) used for sorting (descending, then opts.Raw, then CellID).
            filter = string(filter);
            act = curation.Queues.activeMask(T);
            rev = logical(T.Reviewed(:));
            auto = curation.Queues.str(T, 'LabelSource') == "auto";
            switch lower(filter)
                case "auto", m = act & auto;
                case "all",  m = act & (rev | auto);
                case {"good", "bad", "uncertain"}
                    m = act & rev & lower(curation.Queues.str(T, 'Label')) == lower(filter);
                otherwise
                    error('curation:Queues:badFilter', 'Unknown filter "%s".', filter);
            end
            pages = curation.Queues.listQueue(T, m, "browse", "Browse " + filter, opts, p);
        end

        function s = summary(T, p, opts)
        %SUMMARY  Counts remaining per queue, for the GUI's queue list.
        %   Fields: reviewRemaining (ordinary + blind tiles), bands (struct bad, middleLow,
        %   middleHigh, good: ordinary rows per band; blind: blind tiles), blind (blind tiles
        %   pending), flagged, vanishedGood, reviewed, total, pagesRemaining (number of review
        %   pages for opts.PageSize).
            opts = curation.Queues.fillOpts(opts);
            b = opts.Bands(:)';
            p = double(p(:));
            p(isnan(p)) = 0.5;
            [m, bm] = curation.Queues.masks(T, opts);
            nBlind = nnz(bm);
            P = p(m);
            s = struct();
            s.reviewRemaining = nnz(m) + nBlind;
            s.bands = struct( ...
                'bad', nnz(P < b(1)), ...
                'middleLow', nnz(P >= b(1) & P < b(2)), ...
                'middleHigh', nnz(P >= b(2) & P < b(3)), ...
                'good', nnz(P >= b(3)), ...
                'blind', nBlind);
            s.blind = nBlind;
            s.flagged = nnz(curation.Queues.activeMask(T) & curation.Queues.str(T, 'Flag') ~= "");
            s.vanishedGood = nnz(curation.Queues.activeMask(T) ...
                & curation.Queues.str(T, 'Label') == "Good" & logical(T.Reviewed(:)) ...
                & ~logical(T.InLocs(:)) & curation.Queues.str(T, 'Origin') == "detected");
            s.reviewed = nnz(logical(T.Reviewed(:)));
            s.total = height(T);
            s.pagesRemaining = numel(curation.Queues.review(T, p, opts));
        end

        function ids = eligible(T, opts)
        %ELIGIBLE  CellIDs (uint32 column, in row order) the review queue will ever show: the
        %   ordinary rows (State "active", not Reviewed, not Excluded, Label "", Flag "",
        %   AuditRole "") and the pending blind tiles (class help). opts: BlindRoles (optional).
            if nargin < 2 || isempty(opts), opts = struct(); end
            if ~isfield(opts, 'BlindRoles') || isempty(opts.BlindRoles)
                opts.BlindRoles = curation.Queues.BLIND_ROLES;
            end
            m = curation.Queues.reviewMask(T) | curation.Queues.blindMask(T, opts);
            ids = uint32(T.CellID(m));
            ids = ids(:);
        end

        function m = blindMask(T, opts)
        %BLINDMASK  Rows that are pending blind tiles of the review queue (class help).
            if nargin < 2 || isempty(opts), opts = struct(); end
            roles = curation.Queues.BLIND_ROLES;
            if isfield(opts, 'BlindRoles') && ~isempty(opts.BlindRoles), roles = string(opts.BlindRoles); end
            m = curation.Queues.str(T, 'State') == "active" & ~logical(T.Excluded(:)) ...
                & curation.Queues.str(T, 'Flag') == "" ...
                & ismember(curation.Queues.str(T, 'AuditRole'), roles) ...
                & curation.Queues.str(T, 'LabelSource') ~= "blind";
        end

    end

    methods (Static, Access = private)

        function s = str(T, name)
            if ~ismember(name, T.Properties.VariableNames)
                s = strings(height(T), 1);
                return;
            end
            s = string(T.(name));
            s = s(:);
            s(ismissing(s)) = "";
        end

        function m = activeMask(T)
            m = curation.Queues.str(T, 'State') == "active" & ~logical(T.Excluded(:));
        end

        function [m, bm] = masks(T, opts)
            % Ordinary review rows and pending blind tiles, reading each column once.
            st = curation.Queues.str(T, 'State') == "active" & ~logical(T.Excluded(:)) ...
                & curation.Queues.str(T, 'Flag') == "";
            role = curation.Queues.str(T, 'AuditRole');
            m = st & ~logical(T.Reviewed(:)) & curation.Queues.str(T, 'Label') == "" & role == "";
            bm = st & ismember(role, string(opts.BlindRoles)) ...
                & curation.Queues.str(T, 'LabelSource') ~= "blind";
        end

        function m = reviewMask(T)
            m = curation.Queues.str(T, 'State') == "active" ...
                & ~logical(T.Reviewed(:)) & ~logical(T.Excluded(:)) ...
                & curation.Queues.str(T, 'Label') == "" ...
                & curation.Queues.str(T, 'Flag') == "" ...
                & curation.Queues.str(T, 'AuditRole') == "";
        end

        function m = pendingBlind(T, opts)
            % blind role, not yet decided blind (whatever the flag)
            m = ismember(curation.Queues.str(T, 'AuditRole'), string(opts.BlindRoles)) ...
                & curation.Queues.str(T, 'LabelSource') ~= "blind";
        end

        function opts = fillOpts(opts)
            if ~isfield(opts, 'PageSize') || isempty(opts.PageSize) || opts.PageSize < 1
                error('curation:Queues:noPageSize', 'opts.PageSize is required (>= 1).');
            end
            if ~isfield(opts, 'Bands') || isempty(opts.Bands), opts.Bands = [0.15 0.5 0.85]; end
            if ~isfield(opts, 'Order') || isempty(opts.Order), opts.Order = ["middle" "good" "bad"]; end
            if ~isfield(opts, 'Raw'), opts.Raw = []; end
            if ~isfield(opts, 'MaxBlindFraction') || isempty(opts.MaxBlindFraction)
                opts.MaxBlindFraction = 0.15;
            end
            if ~isfield(opts, 'BlindRoles') || isempty(opts.BlindRoles)
                opts.BlindRoles = curation.Queues.BLIND_ROLES;
            end
            opts.MaxBlindFraction = min(max(double(opts.MaxBlindFraction), 0), 1);
        end

        function raw = rawKey(opts, p, n)
            % Tie-break key: opts.Raw (NaN -> the row's P), else zeros.
            if isempty(opts.Raw)
                raw = zeros(n, 1);
                return;
            end
            raw = double(opts.Raw(:));
            if numel(raw) ~= n
                error('curation:Queues:badRaw', 'opts.Raw needs one entry per row of T (%d, not %d).', ...
                    n, numel(raw));
            end
            bad = isnan(raw);
            raw(bad) = p(bad);
        end

        function [sz, nb] = cutBand(r, ps, capB, f, bLeft)
            % Page sizes (ordinary tiles) and blind tiles per page for a band of r ordinary rows:
            % each page takes min(capB, blind left) blind tiles, ordinary rows fill the rest; a
            % last page under 25% of ps is balanced with the one before; a page's blind tiles
            % never exceed the fraction f of the page.
            sz = zeros(0, 1);
            nb = zeros(0, 1);
            pos = 0;
            while pos < r
                b = min(capB, bLeft);
                cap = ps - b;
                rem = r - pos;
                if rem <= cap
                    take = rem;
                elseif rem < cap + 0.25 * ps
                    take = ceil(rem / 2);
                else
                    take = cap;
                end
                if b > 0 && f < 1
                    b = min(b, floor(f / (1 - f) * take + 1e-9));
                end
                sz(end + 1, 1) = take; %#ok<AGROW>
                nb(end + 1, 1) = b; %#ok<AGROW>
                pos = pos + take;
                bLeft = bLeft - b;
            end
        end

        function [ids, P, B] = interleave(oIds, oP, bIds, bP)
            % Ordinary tiles keep their order at positions (j - 0.5) / k; each blind tile goes to
            % a pseudo-random position given by a hash of its id and of the page's ordinary ids.
            k = numel(oIds);
            salt = mod(sum(double(oIds)), 2 ^ 32);
            u = curation.Queues.hash01(bIds, salt);
            [~, o] = sort([((1:k)' - 0.5) / k; u(:)]);      % stable: an ordinary tile first on a tie
            ids = [oIds(:); bIds(:)];
            P = [oP(:); bP(:)];
            B = [false(k, 1); true(numel(bIds), 1)];
            ids = ids(o); P = P(o); B = B(o);
        end

        function u = hash01(ids, salt)
            % Deterministic pseudo-random number in [0, 1) per id (multiplicative hash).
            x = mod(double(ids(:)) * 2654435761 + salt, 2 ^ 32);
            x = mod(x * 40503 + 12345, 2 ^ 32);
            u = x / 2 ^ 32;
        end

        function pages = listQueue(T, m, queue, label, opts, p, blind)
            opts = curation.Queues.fillOpts(opts);
            if nargin < 6 || isempty(p)
                p = curation.Proposals.current(T, "");
            end
            p = double(p(:));
            p(isnan(p)) = 0.5;
            n = height(T);
            raw = curation.Queues.rawKey(opts, p, n);
            if nargin < 7 || isempty(blind), blind = false(n, 1); end
            ids = T.CellID(m);
            P = p(m);
            Rw = raw(m);
            B = blind(m);
            nn = numel(ids);
            if nn == 0, pages = curation.Queues.emptyPages(); return; end
            [~, o] = sortrows([-P, -Rw, double(ids)]);
            ids = ids(o); P = P(o); B = B(o);
            sz = curation.Queues.chunkSizes(nn, opts.PageSize);
            np = numel(sz);
            c = cell(np, 1);
            pos = 0;
            for j = 1:np
                sel = pos + (1:sz(j));
                pos = pos + sz(j);
                c{j} = curation.Queues.makePage(ids(sel), P(sel), "", queue, queue, label, j, np, B(sel));
            end
            pages = vertcat(c{:});
        end

        function sz = chunkSizes(n, ps)
            % Page sizes for n ids: full pages, a short last page balanced with
            % the one before when it holds < 25% of ps and there are >= 2 pages.
            np = ceil(n / ps);
            sz = repmat(ps, np, 1);
            sz(end) = n - ps * (np - 1);
            if np >= 2 && sz(end) < 0.25 * ps
                t = sz(end - 1) + sz(end);
                sz(end - 1) = ceil(t / 2);
                sz(end) = floor(t / 2);
            end
        end

        function pg = makePage(ids, P, default, band, queue, label, k, total, blind)
            ids = uint32(ids(:));
            P = P(:);
            if nargin < 9 || isempty(blind), blind = false(numel(ids), 1); end
            blind = logical(blind(:));
            dash = char(8211);
            dot = char(183);
            Po = P(~blind);
            if isempty(Po)
                title = sprintf('%s %s page %d of %d', char(label), dot, k, total);
            else
                title = sprintf('%s %s P %.2f%s%.2f %s page %d of %d', ...
                    char(label), dot, min(Po), dash, max(Po), dot, k, total);
            end
            pg = struct( ...
                'Ids', ids, ...
                'P', P, ...
                'Default', string(default), ...
                'Band', string(band), ...
                'Blind', blind, ...
                'Title', string(title), ...
                'Queue', string(queue), ...
                'PageId', curation.Queues.pageId(queue, ids));
        end

        function id = pageId(queue, ids)
            % Short deterministic hash of the queue name and the ordered ids.
            K = numel(ids);
            d = double(ids(:));
            r = (1:K)';
            h1 = mod(sum(mod(d, 65521) .* mod(r * 40503 + 17, 65521)), 65521);
            h2 = mod(sum(mod(d, 65537) .* mod(r * 9973 + 31, 65537)), 65537);
            h3 = mod(sum(d .* mod(r * 7 + 1, 1021)), 2^32);
            id = string(sprintf('%s-%04x%05x%08x-%d', char(queue), h1, h2, h3, K));
        end

        function s = emptyPages()
            s = struct('Ids', {}, 'P', {}, 'Default', {}, 'Band', {}, 'Blind', {}, ...
                'Title', {}, 'Queue', {}, 'PageId', {});
            s = reshape(s, 0, 1);
        end

    end
end

classdef Pairs
%PAIRS  Groups of kept cells so close they may be one cell detected twice (pure data).
%
%   clusters = curation.Pairs.find(T, umPerPx, opts)
%   n        = curation.Pairs.count(T, umPerPx, opts)
%   K        = curation.Pairs.normalizeKeptPairs(x)
%
%   Pixel coordinates in T (X, Y) are converted to micrometers with umPerPx.

    methods (Static)

        function clusters = find(T, umPerPx, opts)
        %FIND  Clusters of cells linked by distance <= opts.RadiusUm (connected components).
        %   T       curation table: CellID, X, Y, score, rescore, State, Label, Reviewed,
        %           Excluded (missing score/rescore/Excluded columns are tolerated).
        %   umPerPx micrometers per pixel.
        %   opts    struct, all optional:
        %     RadiusUm     16.6   link two cells when their distance is <= this
        %     MergeBelowUm 8.3    Proposal "merge" when MinDistUm < this, else "keepBoth"
        %     Subset       "good" "good": State "active" & Label "Good" & Reviewed & ~Excluded;
        %                  "active": State "active" & ~Excluded
        %     KeptPairs    []     K x 2 CellIDs the reviewer judged separate cells; those
        %                  edges are removed before grouping (a cluster is then split)
        %   Returns an N x 1 struct array (0 x 1 with the same fields when none), sorted by
        %   MinDistUm ascending, ties by lowest CellID, with fields
        %     Ids        uint32, sorted
        %     XY         n x 2 pixel positions in Ids order
        %     Centroid   1 x 2 mean of XY (pixels)
        %     MinDistUm  shortest linked edge, um
        %     MaxDistUm  largest pairwise distance among the cells, um (can exceed the radius)
        %     Proposal   "merge" | "keepBoth"
        %     KeeperId   uint32; highest finite rescore, then highest score, then lowest id
        %     Edges      E x 2 uint32 CellIDs actually linked (each row sorted)
        %     Title      e.g. "2 cells 6.4 µm apart" or "3 cells, closest 5.1 µm"
            if nargin < 3 || isempty(opts), opts = struct(); end
            radius = curation.Pairs.opt(opts, 'RadiusUm', 16.6);
            mergeBelow = curation.Pairs.opt(opts, 'MergeBelowUm', 8.3);
            subset = lower(string(curation.Pairs.opt(opts, 'Subset', "good")));
            kept = curation.Pairs.normalizeKeptPairs(curation.Pairs.opt(opts, 'KeptPairs', []));
            clusters = curation.Pairs.emptyClusters();
            n = height(T);
            if n < 2, return; end

            ok = curation.Pairs.str(T, 'State') == "active";
            if subset == "good"
                ok = ok & curation.Pairs.str(T, 'Label') == "Good" & curation.Pairs.flag(T, 'Reviewed', false);
            elseif subset ~= "active"
                error('curation:Pairs:badInput', 'Subset must be "good" or "active".');
            end
            ok = ok & ~curation.Pairs.flag(T, 'Excluded', true);
            x = double(T.X); y = double(T.Y);
            ok = ok & isfinite(x) & isfinite(y);
            idx = find(ok);
            if numel(idx) < 2, return; end

            % Sweep over x-sorted points: only neighbors within the x window are compared.
            px = x(idx); py = y(idx);
            rpx = radius / umPerPx * (1 + 1e-9);
            [px, ord] = sort(px); py = py(ord); idx = idx(ord);
            m = numel(px);
            ei = zeros(0, 1); ej = zeros(0, 1);
            for k = 1:m - 1
                dx = px(1 + k:m) - px(1:m - k);
                if all(dx > rpx), break; end
                cand = find(dx <= rpx);
                dy = py(cand + k) - py(cand);
                hit = (dx(cand) .^ 2 + dy .^ 2) <= rpx ^ 2;
                ei = [ei; cand(hit)]; %#ok<AGROW>
                ej = [ej; cand(hit) + k]; %#ok<AGROW>
            end
            if isempty(ei), return; end
            ids = uint32(T.CellID(idx));
            if ~isempty(kept)
                keepMask = ~ismember([ids(ei), ids(ej)], kept, 'rows') & ...
                    ~ismember([ids(ej), ids(ei)], kept, 'rows');
                ei = ei(keepMask); ej = ej(keepMask);
            end
            if isempty(ei), return; end

            nodes = unique([ei; ej]);
            [~, a] = ismember(ei, nodes); [~, b] = ismember(ej, nodes);
            comp = conncomp(graph(a, b, [], numel(nodes)));
            nc = max(comp);
            nodeComp = comp(:); edgeComp = nodeComp(a);
            nIds = ids(nodes); nX = x(idx(nodes)); nY = y(idx(nodes));
            nR = -inf(numel(nodes), 1); nS = nR;
            if ismember('rescore', T.Properties.VariableNames)
                v = double(T.rescore(idx(nodes))); f = isfinite(v); nR(f) = v(f);
            end
            if ismember('score', T.Properties.VariableNames)
                v = double(T.score(idx(nodes))); f = isfinite(v); nS(f) = v(f);
            end
            dEdgeAll = hypot(px(ei) - px(ej), py(ei) - py(ej)) * umPerPx;
            [~, eo] = sort(edgeComp); eStart = [1; find(diff(edgeComp(eo)) ~= 0) + 1; numel(eo) + 1];
            [~, no] = sort(nodeComp); nStart = [1; find(diff(nodeComp(no)) ~= 0) + 1; numel(no) + 1];
            blank = curation.Pairs.blankCluster();
            out = repmat(blank, nc, 1);
            minKey = zeros(nc, 1); idKey = zeros(nc, 1);
            mu = char(181);
            for c = 1:nc
                mem = no(nStart(c):nStart(c + 1) - 1);
                [cid, so] = sort(nIds(mem)); mem = mem(so);
                xyc = [nX(mem), nY(mem)];
                em = eo(eStart(c):eStart(c + 1) - 1);
                minD = min(dEdgeAll(em));
                dx = xyc(:, 1) - xyc(:, 1)'; dy = xyc(:, 2) - xyc(:, 2)';
                maxD = sqrt(max(dx(:) .^ 2 + dy(:) .^ 2)) * umPerPx;
                s = blank;
                s.Ids = cid;
                s.XY = xyc;
                s.Centroid = mean(xyc, 1);
                s.MinDistUm = minD;
                s.MaxDistUm = maxD;
                if minD < mergeBelow, s.Proposal = "merge"; else, s.Proposal = "keepBoth"; end
                kk = sortrows([-nR(mem), -nS(mem), double(cid)]);
                s.KeeperId = uint32(kk(1, 3));
                ed = [ids(ei(em)), ids(ej(em))];
                ed = sortrows([min(ed, [], 2), max(ed, [], 2)]);
                s.Edges = ed;
                if numel(cid) == 2
                    s.Title = string(sprintf('2 cells %.1f %sm apart', minD, mu));
                else
                    s.Title = string(sprintf('%d cells, closest %.1f %sm', numel(cid), minD, mu));
                end
                out(c) = s;
                minKey(c) = minD; idKey(c) = double(cid(1));
            end
            [~, o] = sortrows([minKey, idKey]);
            clusters = out(o);
            clusters = clusters(:);
        end

        function n = count(T, umPerPx, opts)
        %COUNT  Number of clusters find would return (same arguments); for a queue badge.
            if nargin < 3, opts = struct(); end
            n = numel(curation.Pairs.find(T, umPerPx, opts));
        end

        function K = normalizeKeptPairs(x)
        %NORMALIZEKEPTPAIRS  K x 2 uint32, each row sorted ascending, unique rows.
        %   Accepts [] , a 1 x 2 (or 2 x 1) pair, a K x 2 matrix, or a cell array of pairs
        %   (the shapes jsondecode returns). Rows with a non-finite id or two equal ids are
        %   dropped. Returns a 0 x 2 uint32 when nothing is left.
            K = zeros(0, 2, 'uint32');
            if isempty(x), return; end
            if iscell(x)
                rows = cell(numel(x), 1);
                for i = 1:numel(x)
                    rows{i} = reshape(double(curation.Pairs.flatten(x{i})), 1, []);
                end
                x = vertcat(rows{:});
            end
            x = double(x);
            if size(x, 2) ~= 2
                if numel(x) == 2, x = x(:)'; else, x = reshape(x, [], 2); end
            end
            x = x(all(isfinite(x), 2) & x(:, 1) ~= x(:, 2) & all(x >= 0, 2), :);
            if isempty(x), return; end
            K = unique(uint32(sort(x, 2)), 'rows');
        end

    end

    methods (Static, Access = private)

        function v = opt(opts, name, default)
            if isfield(opts, name) && ~isempty(opts.(name)), v = opts.(name); else, v = default; end
        end

        function s = str(T, name)
            if ismember(name, T.Properties.VariableNames)
                s = string(T.(name));
            else
                s = strings(height(T), 1);
            end
            s = s(:);
        end

        function f = flag(T, name, default)
            if ismember(name, T.Properties.VariableNames)
                f = logical(T.(name));
            else
                f = repmat(default, height(T), 1);
            end
            f = f(:);
            f(isnan(double(f))) = default;
        end

        function v = flatten(c)
            if iscell(c), v = cell2mat(cellfun(@(q) double(q(:))', c(:)', 'UniformOutput', false)); else, v = c; end
        end

        function s = blankCluster()
            s = struct('Ids', zeros(0, 1, 'uint32'), 'XY', zeros(0, 2), 'Centroid', [NaN NaN], ...
                'MinDistUm', NaN, 'MaxDistUm', NaN, 'Proposal', "keepBoth", ...
                'KeeperId', uint32(0), 'Edges', zeros(0, 2, 'uint32'), 'Title', "");
        end

        function c = emptyClusters()
            c = repmat(curation.Pairs.blankCluster(), 0, 1);
        end

    end
end

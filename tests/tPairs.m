classdef tPairs < matlab.unittest.TestCase
    % Tests for curation.Pairs (pure data in, data out).

    methods (Static)
        function T = tbl(xy, varargin)
            % tbl(xy, 'rescore', v, 'score', v, 'Label', s, 'Reviewed', l, 'State', s, 'Excluded', l)
            n = size(xy, 1);
            p = inputParser;
            p.addParameter('rescore', zeros(n, 1));
            p.addParameter('score', 0.5 * ones(n, 1));
            p.addParameter('Label', repmat("Good", n, 1));
            p.addParameter('Reviewed', true(n, 1));
            p.addParameter('State', repmat("active", n, 1));
            p.addParameter('Excluded', false(n, 1));
            p.addParameter('CellID', uint32((1:n)'));
            p.parse(varargin{:});
            r = p.Results;
            T = table(uint32(r.CellID(:)), xy(:, 1), xy(:, 2), r.score(:), r.rescore(:), ...
                string(r.State(:)), string(r.Label(:)), logical(r.Reviewed(:)), logical(r.Excluded(:)), ...
                'VariableNames', {'CellID', 'X', 'Y', 'score', 'rescore', 'State', 'Label', 'Reviewed', 'Excluded'});
        end
    end

    methods (Test)
        function noPairs(tc)
            T = tPairs.tbl([0 0; 100 0; 0 100]);
            c = curation.Pairs.find(T, 1);
            tc.verifyEmpty(c);
            tc.verifyEqual(size(c), [0 1]);
            tc.verifyTrue(all(ismember({'Ids','XY','Centroid','MinDistUm','MaxDistUm','Proposal','KeeperId','Edges','Title'}, fieldnames(c))));
            tc.verifyEmpty(curation.Pairs.find(T(1, :), 1));
            tc.verifyEmpty(curation.Pairs.find(T([], :), 1));
        end

        function oneCloseAndOneMerge(tc)
            % umPerPx = 1: 6.4 um apart -> merge, 12 um apart -> keepBoth
            c = curation.Pairs.find(tPairs.tbl([0 0; 6.4 0; 500 500]), 1);
            tc.verifyEqual(numel(c), 1);
            tc.verifyEqual(c.Ids, uint32([1; 2]));
            tc.verifyEqual(c.Proposal, "merge");
            tc.verifyEqual(c.MinDistUm, 6.4, 'AbsTol', 1e-9);
            tc.verifyEqual(c.Edges, uint32([1 2]));
            tc.verifyEqual(c.Centroid, [3.2 0], 'AbsTol', 1e-9);
            tc.verifyEqual(c.XY, [0 0; 6.4 0]);
            tc.verifyEqual(c.Title, string(sprintf('2 cells 6.4 %sm apart', char(181))) );
            c2 = curation.Pairs.find(tPairs.tbl([0 0; 12 0]), 1);
            tc.verifyEqual(c2.Proposal, "keepBoth");
            % exactly at the radius is linked; just beyond is not
            tc.verifyEqual(numel(curation.Pairs.find(tPairs.tbl([0 0; 16.6 0]), 1)), 1);
            tc.verifyEmpty(curation.Pairs.find(tPairs.tbl([0 0; 16.7 0]), 1));
            % custom options
            c3 = curation.Pairs.find(tPairs.tbl([0 0; 12 0]), 1, struct('MergeBelowUm', 20));
            tc.verifyEqual(c3.Proposal, "merge");
            tc.verifyEmpty(curation.Pairs.find(tPairs.tbl([0 0; 12 0]), 1, struct('RadiusUm', 10)));
        end

        function chainIsOneCluster(tc)
            % A-B-C: A to C is 24 um (> radius) but each step is 12 um
            c = curation.Pairs.find(tPairs.tbl([0 0; 12 0; 24 0; 300 300]), 1);
            tc.verifyEqual(numel(c), 1);
            tc.verifyEqual(c.Ids, uint32([1; 2; 3]));
            tc.verifyEqual(c.MinDistUm, 12, 'AbsTol', 1e-9);
            tc.verifyEqual(c.MaxDistUm, 24, 'AbsTol', 1e-9);
            tc.verifyEqual(size(c.Edges), [2 2]);
            tc.verifyEqual(c.Title, string(sprintf('3 cells, closest 12.0 %sm', char(181))));
        end

        function twoClustersOrdered(tc)
            % cluster of ids 1,2 is 9 um apart; ids 3,4 are 4 um apart; ids 5,6 4 um apart too
            xy = [0 0; 9 0; 200 0; 204 0; 400 0; 404 0];
            c = curation.Pairs.find(tPairs.tbl(xy), 1);
            tc.verifyEqual(numel(c), 3);
            tc.verifyEqual(c(1).Ids, uint32([3; 4]));   % tie 4 um: lowest CellID first
            tc.verifyEqual(c(2).Ids, uint32([5; 6]));
            tc.verifyEqual(c(3).Ids, uint32([1; 2]));
            tc.verifyEqual([c.MinDistUm], [4 4 9], 'AbsTol', 1e-9);
            tc.verifyEqual(c(1).Proposal, "merge");
            tc.verifyEqual(c(3).Proposal, "keepBoth");
        end

        function keptPairsRemoveEdges(tc)
            T = tPairs.tbl([0 0; 5 0; 100 0; 105 0]);
            tc.verifyEqual(numel(curation.Pairs.find(T, 1)), 2);
            o = struct('KeptPairs', uint32([2 1]));            % reversed order still matches
            c = curation.Pairs.find(T, 1, o);
            tc.verifyEqual(numel(c), 1);
            tc.verifyEqual(c.Ids, uint32([3; 4]));
            % chain 1-2-3, keep the middle edge: 1-2 removed -> only 2-3 remains (a pair)
            T3 = tPairs.tbl([0 0; 12 0; 24 0]);
            c = curation.Pairs.find(T3, 1, struct('KeptPairs', [1 2]));
            tc.verifyEqual(numel(c), 1);
            tc.verifyEqual(c.Ids, uint32([2; 3]));
            % removing both edges leaves nothing
            c = curation.Pairs.find(T3, 1, struct('KeptPairs', [1 2; 2 3]));
            tc.verifyEmpty(c);
            % keeping the edge of a 3-chain's other end splits into a pair as well
            c = curation.Pairs.find(T3, 1, struct('KeptPairs', [2 3]));
            tc.verifyEqual(c.Ids, uint32([1; 2]));
            % a triangle stays one cluster when a single edge is kept
            Tt = tPairs.tbl([0 0; 8 0; 4 6]);
            c = curation.Pairs.find(Tt, 1, struct('KeptPairs', [1 2]));
            tc.verifyEqual(c.Ids, uint32([1; 2; 3]));
            tc.verifyEqual(size(c.Edges), [2 2]);
        end

        function keeperChoice(tc)
            xy = [0 0; 3 0; 6 0];
            c = curation.Pairs.find(tPairs.tbl(xy, 'rescore', [0.1; 0.9; 0.5]), 1);
            tc.verifyEqual(c.KeeperId, uint32(2));
            % NaN rescore falls back to score
            c = curation.Pairs.find(tPairs.tbl(xy, 'rescore', [NaN; NaN; NaN], 'score', [0.2; 0.3; 0.9]), 1);
            tc.verifyEqual(c.KeeperId, uint32(3));
            % finite rescore beats a NaN rescore with higher score
            c = curation.Pairs.find(tPairs.tbl(xy, 'rescore', [NaN; -2; NaN], 'score', [0.9; 0.1; 0.9]), 1);
            tc.verifyEqual(c.KeeperId, uint32(2));
            % rescore tie -> higher score
            c = curation.Pairs.find(tPairs.tbl(xy, 'rescore', [1; 1; 0], 'score', [0.2; 0.8; 0.9]), 1);
            tc.verifyEqual(c.KeeperId, uint32(2));
            % full tie -> lowest CellID
            c = curation.Pairs.find(tPairs.tbl(xy, 'rescore', [1; 1; 1], 'score', [0.5; 0.5; 0.5], ...
                'CellID', uint32([30; 10; 20])), 1);
            tc.verifyEqual(c.KeeperId, uint32(10));
            tc.verifyEqual(c.Ids, uint32([10; 20; 30]));
            % ids are not row numbers: XY follows sorted Ids
            tc.verifyEqual(c.XY, [3 0; 6 0; 0 0]);
        end

        function subsets(tc)
            xy = [0 0; 3 0; 6 0; 9 0; 12 0];
            T = tPairs.tbl(xy);
            T.Reviewed(2) = false;          % unreviewed
            T.Label(3) = "Bad";
            T.State(4) = "merged";
            T.Excluded(5) = true;
            tc.verifyEmpty(curation.Pairs.find(T, 1));            % only id 1 left in "good"
            T.Label(3) = "Good";
            c = curation.Pairs.find(T, 1, struct('Subset', "good"));
            tc.verifyEqual(c.Ids, uint32([1; 3]));                 % 6 um apart, 2 and 4 ignored
            ca = curation.Pairs.find(T, 1, struct('Subset', "active"));
            tc.verifyEqual(ca.Ids, uint32([1; 2; 3]));             % unreviewed counts, merged and excluded do not
            T.Label(3) = "Bad";
            ca = curation.Pairs.find(T, 1, struct('Subset', "active"));
            tc.verifyEqual(ca.Ids, uint32([1; 2; 3]));             % Bad counts in active
            tc.verifyError(@() curation.Pairs.find(T, 1, struct('Subset', "nope")), 'curation:Pairs:badInput');
        end

        function scalesWithUmPerPx(tc)
            T = tPairs.tbl([0 0; 10 0]);           % 10 px
            tc.verifyEqual(numel(curation.Pairs.find(T, 1.0)), 1);        % 10 um <= 16.6
            tc.verifyEmpty(curation.Pairs.find(T, 2.0));                  % 20 um
            c = curation.Pairs.find(T, 0.645);
            tc.verifyEqual(c.MinDistUm, 6.45, 'AbsTol', 1e-9);
            tc.verifyEqual(c.Proposal, "merge");
            c = curation.Pairs.find(T, 1.5);
            tc.verifyEqual(c.MinDistUm, 15, 'AbsTol', 1e-9);
            tc.verifyEqual(c.Proposal, "keepBoth");
        end

        function normalizeShapes(tc)
            e = zeros(0, 2, 'uint32');
            tc.verifyEqual(curation.Pairs.normalizeKeptPairs([]), e);
            tc.verifyEqual(curation.Pairs.normalizeKeptPairs(zeros(0, 2)), e);
            tc.verifyEqual(curation.Pairs.normalizeKeptPairs([5 3]), uint32([3 5]));
            tc.verifyEqual(curation.Pairs.normalizeKeptPairs([5; 3]), uint32([3 5]));
            tc.verifyEqual(curation.Pairs.normalizeKeptPairs([5 3; 1 2; 3 5]), uint32([1 2; 3 5]));
            tc.verifyEqual(curation.Pairs.normalizeKeptPairs({[5 3], [1 2]}), uint32([1 2; 3 5]));
            tc.verifyEqual(curation.Pairs.normalizeKeptPairs({[5 3]}), uint32([3 5]));
            tc.verifyEqual(class(curation.Pairs.normalizeKeptPairs([1 2])), 'uint32');
            % through jsondecode
            tc.verifyEqual(curation.Pairs.normalizeKeptPairs(jsondecode('[]')), e);
            tc.verifyEqual(curation.Pairs.normalizeKeptPairs(jsondecode('[[4,2]]')), uint32([2 4]));
            tc.verifyEqual(curation.Pairs.normalizeKeptPairs(jsondecode('[[4,2],[7,1]]')), uint32([1 7; 2 4]));
            tc.verifyEqual(curation.Pairs.normalizeKeptPairs(jsondecode('[4,2]')), uint32([2 4]));
            tc.verifyEqual(curation.Pairs.normalizeKeptPairs(jsondecode(jsonencode(uint32([1 2; 3 4])))), uint32([1 2; 3 4]));
        end

        function countMatchesFind(tc)
            rng(3);
            xy = rand(400, 2) * 400;
            T = tPairs.tbl(xy);
            for o = {struct(), struct('RadiusUm', 5), struct('Subset', "active")}
                tc.verifyEqual(curation.Pairs.count(T, 1, o{1}), numel(curation.Pairs.find(T, 1, o{1})));
            end
            tc.verifyGreaterThan(curation.Pairs.count(T, 1), 5);
            tc.verifyEqual(curation.Pairs.count(tPairs.tbl([0 0; 100 100]), 1), 0);
        end

        function matchesBruteForce(tc)
            rng(11);
            xy = rand(300, 2) * 120;
            T = tPairs.tbl(xy);
            c = curation.Pairs.find(T, 0.8);
            D = squareform(pdist(xy)) * 0.8;
            A = D <= 16.6 & ~eye(300);
            comp = conncomp(graph(A));
            sz = accumarray(comp(:), 1);
            tc.verifyEqual(sort(arrayfun(@(s) numel(s.Ids), c)), sort(sz(sz > 1)));
        end

        function timing3000(tc)
            rng(7);
            n = 3000;
            xy = rand(n, 2) * [6000 0; 0 6000];     % ~ sparse section; a few close pairs
            T = tPairs.tbl(xy, 'rescore', randn(n, 1));
            curation.Pairs.find(T, 0.645);          % warm up
            t = zeros(1, 15);
            for i = 1:numel(t)
                tic; curation.Pairs.find(T, 0.645); t(i) = toc * 1000;
            end
            fprintf('tPairs timing: find on %d rows: median %.1f ms, max %.1f ms\n', n, median(t), max(t));
            tc.verifyLessThan(median(t), 60);
        end
    end
end

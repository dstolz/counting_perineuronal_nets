classdef tProposals < matlab.unittest.TestCase
    % Tests for curation.Proposals (pure data in, data out).

    methods (Static)
        function T = tbl(resc, sc, modelP)
            n = numel(resc);
            if nargin < 3, modelP = nan(n, 1); end
            T = table(uint32((1:n)'), resc(:), sc(:), modelP(:), ...
                'VariableNames', {'CellID', 'rescore', 'score', 'ModelP'});
        end
    end

    methods (Test)
        function formulaPnn(tc)
            r = [-0.170; 0; 2; -5; 9];
            p = curation.Proposals.coldStart(tProposals.tbl(r, zeros(5, 1)), "ECM1");
            tc.verifyEqual(p, 1 ./ (1 + exp(-(r + 0.170))), 'AbsTol', 1e-12);
            tc.verifyEqual(p(1), 0.5, 'AbsTol', 1e-12);
        end

        function formulaPv(tc)
            r = [-0.401; 1; -3];
            p = curation.Proposals.coldStart(tProposals.tbl(r, zeros(3, 1)), "PV2");
            tc.verifyEqual(p, 1 ./ (1 + exp(-(r + 0.401))), 'AbsTol', 1e-12);
            tc.verifyEqual(p(1), 0.5, 'AbsTol', 1e-12);
        end

        function formulaUnknown(tc)
            r = [0; 3];
            p = curation.Proposals.coldStart(tProposals.tbl(r, zeros(2, 1)), "DAPI1");
            tc.verifyEqual(p, 1 ./ (1 + exp(-r)), 'AbsTol', 1e-12);
        end

        function nanFallback(tc)
            T = tProposals.tbl([NaN; NaN; NaN; 1], [0.7; NaN; Inf; 0.2]);
            p = curation.Proposals.coldStart(T, "WFA1");
            tc.verifyEqual(p(1), 0.7, 'AbsTol', 1e-12);
            tc.verifyEqual(p(2), 0.5);
            tc.verifyEqual(p(3), 0.5);
            tc.verifyEqual(p(4), 1 ./ (1 + exp(-(1 + 0.170))), 'AbsTol', 1e-12);
        end

        function clamping(tc)
            T = tProposals.tbl([NaN; NaN], [1.5; -0.3]);
            p = curation.Proposals.coldStart(T, "PV1");
            tc.verifyEqual(p, [1; 0]);
        end

        function outputInRange(tc)
            T = tProposals.tbl([-700; 700; 0], [0; 0; 0]);
            p = curation.Proposals.coldStart(T, "ECM1");
            tc.verifyGreaterThanOrEqual(p, 0);
            tc.verifyLessThanOrEqual(p, 1);
            tc.verifySize(p, [3 1]);
        end

        function kindOf(tc)
            K = @curation.Proposals.kindOf;
            tc.verifyEqual(K("ECM1"), "pnn");
            tc.verifyEqual(K("pnn3"), "pnn");
            tc.verifyEqual(K("WFA1"), "pnn");
            tc.verifyEqual(K("PV2"), "pv");
            tc.verifyEqual(K('pv12'), "pv");
            tc.verifyEqual(K("DAPI1"), "unknown");
        end

        function cutpoints(tc)
            tc.verifyEqual(curation.Proposals.cutpoint("pnn"), -0.170);
            tc.verifyEqual(curation.Proposals.cutpoint("pv"), -0.401);
            tc.verifyEqual(curation.Proposals.cutpoint("unknown"), 0);
        end

        function currentPrefersModelP(tc)
            T = tProposals.tbl([0; 0; 0], [0.5; 0.5; 0.5], [0.9; NaN; 0.1]);
            p = curation.Proposals.current(T, "DAPI1");
            tc.verifyEqual(p, [0.9; 0.5; 0.1], 'AbsTol', 1e-12);
        end
    end
end

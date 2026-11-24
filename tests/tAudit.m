classdef tAudit < matlab.unittest.TestCase
    %TAUDIT  curation.Audit: interval functions against known values, the gates and their reason
    %   texts, the reject threshold (deterministic cases, NaN when nothing passes, and a seeded
    %   simulation with a KNOWN miss rate, tagged Slow), the auto-reject mask, the audit samplers,
    %   the suspension rule at its boundary, the evidence helper and the report arithmetic.
    %   Run: pwsh -File tools\Run-Tests.ps1 tAudit [-IncludeSlow for the simulation]

    methods (Static)
        function T = rows(n, varargin)
            % n rows with State active and the given column values (scalars expand).
            T = table(uint32((1:n)'), 'VariableNames', {'CellID'});
            d = struct('State', "active", 'Reviewed', false, 'Label', "", 'LabelSource', "", ...
                'AuditRole', "", 'Excluded', false, 'Reviewer', "", 'ModelP', NaN, 'rescore', NaN, ...
                'score', NaN, 'PriorLabel', "", 'PriorProposalP', NaN);
            for i = 1:2:numel(varargin)
                d.(varargin{i}) = varargin{i + 1};
            end
            f = fieldnames(d);
            for i = 1:numel(f)
                v = d.(f{i});
                if isscalar(v), v = repmat(v, n, 1); end
                T.(f{i}) = v(:);
            end
        end

        function T = catRows(varargin)
            T = vertcat(varargin{:});
            T.CellID = uint32((1:height(T))');
        end

        function [m, F, ids] = smallModel()
            % A small model trained on rows 1..500 (Ids "S|1".."S|500"); rows 501..600 never seen.
            rs = RandStream('mt19937ar', 'Seed', 2);
            n = 600;
            F = randn(rs, n, 4);
            y = rand(rs, n, 1) < 1 ./ (1 + exp(-2 * F(:, 1)));
            ids = "S|" + string((1:n)');
            m = curation.AssistModel.fit(F(1:500, :), y(1:500), "g" + string(mod((1:500)', 5)), ...
                struct('Ids', ids(1:500), 'CVTrees', 10, 'NumTrees', 20));
        end

        function T = consistencyIndex()
            % pnn, sections S1 (source A) and S2 (source B). Every number is in the report tests.
            R = @tAudit.rows;
            ca = {'Reviewed', true, 'LabelSource', "blind", 'AuditRole', "confirm-audit"};
            A = [ ...
                R(10, ca{:}, 'Label', [repmat("Good", 9, 1); "Bad"], 'PriorLabel', "Good", 'PriorProposalP', 0.9, 'Reviewer', "ann"); ...
                R(5, ca{:}, 'Label', ["Good"; "Good"; "Good"; "Bad"; "Bad"], 'PriorLabel', "Good", 'PriorProposalP', 0.6, 'Reviewer', "bob"); ...
                R(1, ca{:}, 'Label', "Good", 'PriorLabel', "", 'Reviewer', "bob"); ...
                R(3, 'Reviewed', true, 'Label', "Bad", 'LabelSource', "confirmed", 'AuditRole', "confirm-audit", 'Reviewer', "ann"); ...
                R(100, 'Reviewed', true, 'Label', "Good", 'LabelSource', "confirmed", 'Reviewer', "ann"); ...
                R(12, 'Reviewed', true, 'Label', "Good", 'LabelSource', "blind", 'AuditRole', "holdout", 'Reviewer', "ann", ...
                    'ModelP', linspace(0.3, 0.95, 12)', 'rescore', [linspace(-1, 2, 11)'; -3]); ...
                R(12, 'Reviewed', true, 'Label', "Bad", 'LabelSource', "blind", 'AuditRole', "holdout", 'Reviewer', "ann", ...
                    'ModelP', linspace(0.05, 0.7, 12)', 'rescore', linspace(-2, 1.5, 12)'); ...
                R(4, 'AuditRole', "holdout"); ...
                R(2, 'Reviewed', true, 'Label', "Good", 'LabelSource', "confirmed", 'AuditRole', "holdout", 'Reviewer', "ann", ...
                    'ModelP', 0.1, 'rescore', -5)];
            A.SourceId = repmat("A", height(A), 1); A.Section = repmat("S1", height(A), 1);
            B = [ ...
                R(20, ca{:}, 'Label', [repmat("Bad", 18, 1); "Good"; "Good"], 'PriorLabel', "Bad", 'PriorProposalP', 0.05, 'Reviewer', "carl"); ...
                R(4, ca{:}, 'Label', ["Bad"; "Bad"; "Good"; "Uncertain"], 'PriorLabel', "Bad", 'PriorProposalP', 0.3, 'Reviewer', "carl"); ...
                R(300, 'Reviewed', true, 'Label', "Bad", 'LabelSource', "confirmed", 'Reviewer', "bob"); ...
                R(10, 'Reviewed', true, 'Label', "Good", 'LabelSource', "human", 'Reviewer', "carl"); ...
                R(10, 'Reviewed', true, 'Label', "Bad", 'LabelSource', "human", 'Reviewer', "carl"); ...
                R(30)];
            B.SourceId = repmat("B", height(B), 1); B.Section = repmat("S2", height(B), 1);
            T = [A; B];
            T.Kind = repmat("pnn", height(T), 1);
            T.CellID = uint32((1:height(T))');
        end
    end

    methods (Test)
        function intervalsAgainstKnownValues(tc)
            bi = @curation.Audit.binomialInterval;
            tc.verifyEqual(bi(0, 10), [0 0.308497], 'AbsTol', 1e-6);
            tc.verifyEqual(bi(5, 10), [0.187086 0.812914], 'AbsTol', 1e-6);
            tc.verifyEqual(bi(10, 10), [0.691503 1], 'AbsTol', 1e-6);
            tc.verifyEqual(bi(5, 10, 0.95, "wilson"), [0.236593 0.763407], 'AbsTol', 1e-6);
            tc.verifyEqual(bi(0, 10, 0.95, "wilson"), [0 0.277533], 'AbsTol', 1e-6);
            tc.verifyEqual(bi(0, 0), [0 1]);
            tc.verifyEqual(bi([0; 5], [10; 10]), [0 0.308497; 0.187086 0.812914], 'AbsTol', 1e-6);
            % one-sided: rule of three, and the 299-row requirement for a 1% bound
            ub = @curation.Audit.upperBound;
            tc.verifyEqual(ub(0, 299), 1 - 0.05 ^ (1 / 299), 'AbsTol', 1e-12);
            tc.verifyLessThanOrEqual(ub(0, 299), 0.01);
            tc.verifyGreaterThan(ub(0, 298), 0.01);
            tc.verifyEqual(ub(3, 20), bi(3, 20, 0.90) * [0; 1], 'AbsTol', 1e-12);
            tc.verifyEqual(curation.Audit.lowerBound(3, 20), bi(3, 20, 0.90) * [1; 0], 'AbsTol', 1e-12);
            tc.verifyEqual(ub(2, 100, 0.95, "wilson"), bi(2, 100, 0.90, "wilson") * [0; 1], 'AbsTol', 1e-12);
            tc.verifyError(@() bi(1, 2, 0.95, "nope"), 'curation:Audit:badArgument');
        end

        function gatesSayWhichFailed(tc)
            rs = RandStream('mt19937ar', 'Seed', 1);
            n = 640;
            p = rand(rs, n, 1);
            g = double(rand(rs, n, 1) < p);
            sec = "s" + string(randi(rs, 3, n, 1));
            blind = false(n, 1); blind(1:57) = true;
            [tau, info] = curation.Audit.rejectThreshold(p, g, blind, sec);
            tc.verifyTrue(isnan(tau));
            tc.verifyEqual(info.Reason, "Auto-reject needs 1,500 labels from 8 sections; you have 640 from 3. " + ...
                "Auto-reject needs 200 blind labels; you have 57.");
            tc.verifyEqual(info.Gate, "labels+blind");
            % enough labels, too few blind
            n = 2000;
            p = rand(rs, n, 1); g = double(rand(rs, n, 1) < p); sec = "s" + string(randi(rs, 10, n, 1));
            blind = false(n, 1); blind(1:199) = true;
            [tau, info] = curation.Audit.rejectThreshold(p, g, blind, sec);
            tc.verifyTrue(isnan(tau));
            tc.verifyEqual(info.Reason, "Auto-reject needs 200 blind labels; you have 199.");
            tc.verifyEqual(info.Gate, "blind");
            tc.verifyEqual([info.NumLabels info.NumLabelSections info.NumBlind], [2000 10 199]);
            % enough blind, too few sections
            sec2 = "s" + string(randi(rs, 7, n, 1));
            blind(1:400) = true;
            [~, info] = curation.Audit.rejectThreshold(p, g, blind, sec2);
            tc.verifyEqual(info.Reason, "Auto-reject needs 1,500 labels from 8 sections; you have 2,000 from 7.");
            tc.verifyEqual(info.Gate, "labels");
            % unlabelled rows (NaN) do not count as labels
            g2 = g; g2(1:600) = NaN;
            [~, info] = curation.Audit.rejectThreshold(p, g2, false(n, 1), sec);
            tc.verifyEqual(info.NumLabels, 1400);
            tc.verifyEqual(info.NumBlind, 0);
        end

        function thresholdOnACleanCase(tc)
            % 1,000 blind non-cells below 0.4, 500 blind cells above 0.6, in 10 sections.
            p = [linspace(0.001, 0.4, 1000)'; linspace(0.6, 1, 500)'];
            g = [false(1000, 1); true(500, 1)];
            sec = "s" + string(mod((1:1500)', 10));
            for bound = ["binomial" "clustered"]
                [tau, info] = curation.Audit.rejectThreshold(p, g, true(1500, 1), sec, struct('Bound', bound));
                tc.verifyEqual(tau, 0.6, 'AbsTol', 1e-12, 'the largest safe threshold: the first cell');
                tc.verifyEqual(info.NBelow, 1000);
                tc.verifyEqual(info.GoodBelow, 0);
                tc.verifyEqual(info.MissRate, 0);
                tc.verifyEqual(info.UpperBinomial, 1 - 0.05 ^ (1 / 1000), 'AbsTol', 1e-9);
                tc.verifyGreaterThanOrEqual(info.UpperClustered, info.UpperBinomial - 1e-12);
                tc.verifyEqual(info.GoodLost, 0);
                tc.verifyEqual(info.FracRejected, 1000 / 1500, 'AbsTol', 1e-12);
                tc.verifyEqual(info.Reason, "");
                C = info.Curve;
                tc.verifyTrue(all(diff(C.Threshold) > 0));
                tc.verifyTrue(all(C.UpperClustered >= C.UpperBinomial - 1e-12), 'clustered never below binomial');
                tc.verifyTrue(all(C.Deff >= 1));
            end
            % unlabelled candidates spread like the blind rows: FracRejected is over them, and the
            % post-stratification weights are about equal, so the answer is the same
            pc = [linspace(0.0005, 0.4, 2000)'; linspace(0.6, 1, 1000)'];
            P = [p; pc];
            G = [double(g); nan(3000, 1)];
            B = [true(1500, 1); false(3000, 1)];
            S = [sec; repmat("s1", 3000, 1)];
            [tau, info] = curation.Audit.rejectThreshold(P, G, B, S);
            tc.verifyEqual(tau, 0.6, 'AbsTol', 1e-12);
            tc.verifyEqual(info.NRejected, 2000);
            tc.verifyEqual(info.FracRejected, 2000 / 3000, 'AbsTol', 1e-12);
            tc.verifyEqual(info.Weighting, "poststrat");
            tc.verifyLessThanOrEqual(info.NEff, 1000 + 1e-9, 'unequal weights never add information');
            tc.verifyGreaterThan(info.NEff, 900);
            % 600 candidates in a band (0.4 - 0.6) where there is almost no blind evidence: the
            % post-stratified estimate refuses to reject across the band; unweighted would not
            pg = [pc(1:2000); linspace(0.401, 0.599, 600)'; pc(2001:end)];
            P = [p; pg];
            G = [double(g); nan(3600, 1)];
            B = [true(1500, 1); false(3600, 1)];
            S = [sec; repmat("s1", 3600, 1)];
            tauPS = curation.Audit.rejectThreshold(P, G, B, S);
            tauNone = curation.Audit.rejectThreshold(P, G, B, S, struct('Weighting', "none"));
            tc.verifyEqual(tauNone, 0.6, 'AbsTol', 1e-12);
            tc.verifyLessThan(tauPS, 0.4, 'the uncovered band is not auto-rejected');
        end

        function thresholdNaNWhenNothingPasses(tc)
            rs = RandStream('mt19937ar', 'Seed', 3);
            n = 2000;
            p = rand(rs, n, 1);
            g = rand(rs, n, 1) < 0.1;                     % 10% cells at every P
            sec = "s" + string(randi(rs, 12, n, 1));
            [tau, info] = curation.Audit.rejectThreshold(p, g, true(n, 1), sec);
            tc.verifyTrue(isnan(tau));
            tc.verifyEqual(info.Gate, "bound");
            tc.verifyTrue(startsWith(info.Reason, "No threshold meets the limits"));
            tc.verifySubstring(char(info.Reason), '299 blind tiles below the threshold are needed');
            tc.verifyFalse(any(info.Curve.OK));
            % too few blind rows below any threshold: 250 all-Bad blind rows cannot reach 1%
            p = [linspace(0, 0.3, 250)'; linspace(0.5, 1, 1500)'];
            g = [false(250, 1); true(1500, 1)];
            sec = "s" + string(mod((1:1750)', 9));
            [tau, info] = curation.Audit.rejectThreshold(p, g, true(1750, 1), sec);
            tc.verifyTrue(isnan(tau), '250 < 299: the bound cannot be met');
            tc.verifyEqual(info.NBelow, 250);
        end

        function autoRejectNeverTouchesPersonLabels(tc)
            R = @tAudit.rows;
            T = tAudit.catRows( ...
                R(1), ...                                                        % 1 yes
                R(1, 'Label', "Bad", 'LabelSource', "auto"), ...                  % 2 yes (already auto)
                R(1, 'Reviewed', true, 'Label', "Good", 'LabelSource', "human"), ...
                R(1, 'Reviewed', true, 'Label', "Bad", 'LabelSource', "human"), ...
                R(1, 'Reviewed', true, 'Label', "Good", 'LabelSource', "confirmed"), ...
                R(1, 'Reviewed', true, 'Label', "Bad", 'LabelSource', "blind"), ...
                R(1, 'Reviewed', true, 'Label', "Good", 'LabelSource', "legacy-qc"), ...
                R(1, 'Reviewed', true, 'Label', "Bad", 'LabelSource', "legacy-resolver"), ...
                R(1, 'Reviewed', true, 'Label', "Uncertain", 'LabelSource', "human"), ...
                R(1, 'Label', "Good", 'LabelSource', "human"), ...                % person source, not reviewed
                R(1, 'AuditRole', "holdout"), ...
                R(1, 'AuditRole', "reject-audit", 'Label', "Bad", 'LabelSource', "auto"), ...
                R(1, 'Excluded', true), ...
                R(1, 'State', "merged"), ...
                R(1, 'State', "stale"), ...
                R(1), ...                                                        % 16: p NaN
                R(1));                                                           % 17: p >= tau
            p = [repmat(0.01, 15, 1); NaN; 0.5];
            expected = false(17, 1); expected([1 2]) = true;
            tc.verifyEqual(curation.Audit.autoRejectMask(T, p, 0.2), expected);
            tc.verifyFalse(any(curation.Audit.autoRejectMask(T, p, NaN)), 'no threshold: nothing');
            % and the Store agrees: an auto label never lands on a row a person labelled
            L = table((1:4)', (1:4)', rand(4, 1), 'VariableNames', {'X', 'Y', 'score'});
            s = curation.Store.fromTable(L, struct('UmPerPixel', 1));
            s.setLabel(1, "Good", "human");
            s.setLabel(2, "Bad", "confirmed");
            m = curation.Audit.autoRejectMask(s.T, zeros(4, 1), 0.5);
            tc.verifyEqual(m, [false; false; true; true]);
            s.setLabel([1 2 3 4], "Bad", "auto");
            tc.verifyEqual(s.T.LabelSource, ["human"; "confirmed"; "auto"; "auto"]);
        end

        function rejectAuditSampling(tc)
            R = @tAudit.rows;
            a = R(100, 'Label', "Bad", 'LabelSource', "auto");
            a.SourceId = repmat("A", 100, 1);
            b = R(1000, 'Label', "Bad", 'LabelSource', "auto");
            b.SourceId = repmat("B", 1000, 1);
            c = R(8, 'Label', "Bad", 'LabelSource', "auto");
            c.SourceId = repmat("C", 8, 1);
            h = R(50, 'Reviewed', true, 'Label', "Good", 'LabelSource', "human");   % never sampled
            h.SourceId = repmat("A", 50, 1);
            T = [a; b; c; h];
            T.CellID = uint32((1:height(T))');
            ids = curation.Audit.sampleRejectAudit(T);
            tc.verifyClass(ids, 'table');
            cnt = groupcounts(ids, 'SourceId');
            tc.verifyEqual(cnt.SourceId, ["A"; "B"; "C"]);
            tc.verifyEqual(cnt.GroupCount, [15; 50; 8], 'max(15, 5%), all of a small source');
            tc.verifyTrue(all(T.LabelSource(ids.CellID) == "auto"));
            tc.verifyEqual(ids, curation.Audit.sampleRejectAudit(T), 'deterministic');
            other = curation.Audit.sampleRejectAudit(T, struct('Seed', 2));
            tc.verifyNotEqual(other.CellID, ids.CellID, 'another seed, another sample');
            % rows with a role are never returned, and existing audits count toward the target
            T.AuditRole(ids.CellID(ids.SourceId == "A")) = "reject-audit";
            ids2 = curation.Audit.sampleRejectAudit(T);
            tc.verifyFalse(any(ismember(ids2.CellID, ids.CellID(ids.SourceId == "A"))));
            tc.verifyEqual(nnz(ids2.SourceId == "A"), 0, 'A already holds its 15');
            T.AuditRole(find(T.SourceId == "A" & T.AuditRole == "reject-audit", 5)) = "";
            ids3 = curation.Audit.sampleRejectAudit(T);
            tc.verifyEqual(nnz(ids3.SourceId == "A"), 5, 'tops up to 15');
            % a one-source table gives CellIDs
            one = curation.Audit.sampleRejectAudit(b);
            tc.verifyClass(one, 'uint32');
            tc.verifyNumElements(one, 50);
            tc.verifyTrue(issorted(one));
        end

        function confirmAuditNeedsItsSource(tc)
            % (integration pass C, defect 3d) a one-source table without a SourceId column drew its
            % sample from a stream seeded with an empty id: every source the same rows
            R = @tAudit.rows;
            T = R(1000, 'Reviewed', true, 'Label', "Good", 'LabelSource', "confirmed");
            a = curation.Audit.sampleConfirmAudit(T, struct('SourceId', "secA/x|ECM1"));
            b = curation.Audit.sampleConfirmAudit(T, struct('SourceId', "secB/x|ECM1"));
            tc.verifyNumElements(a, 20);
            tc.verifyNumElements(b, 20);
            tc.verifyNotEqual(a, b, 'each source draws from a stream of its own');
            tc.verifyError(@() curation.Audit.sampleConfirmAudit(T), 'curation:Audit:noSourceId');
            T.SourceKey = repmat("ECM1", height(T), 1);           % a channel key is no source id
            tc.verifyError(@() curation.Audit.sampleConfirmAudit(T), 'curation:Audit:noSourceId');
            r = R(400, 'Label', "Bad", 'LabelSource', "auto");
            tc.verifyError(@() curation.Audit.sampleRejectAudit(r), 'curation:Audit:noSourceId');
            % the column and the option are the same thing
            T.SourceId = repmat("secA/x|ECM1", height(T), 1);
            tc.verifyEqual(curation.Audit.sampleConfirmAudit(T), a);
            T.Section = repmat("secA/x", height(T), 1);           % Section + SourceKey also name it
            tc.verifyEqual(curation.Audit.sampleConfirmAudit(removevars(T, 'SourceId')), a);
            % curation.BlindTiles passes the source id of the store
            U = removevars(T, {'SourceId', 'Section', 'SourceKey'});
            tc.verifyEqual(curation.BlindTiles.confirmAuditIds(U, "secA/x|ECM1"), ...
                curation.Audit.sampleConfirmAudit(U, struct('SourceId', "secA/x|ECM1", 'Min', 5)));
            tc.verifyNotEqual(curation.BlindTiles.confirmAuditIds(U, "secA/x|ECM1"), ...
                curation.BlindTiles.confirmAuditIds(U, "secB/x|ECM1"));
        end

        function confirmAuditSampling(tc)
            R = @tAudit.rows;
            T = R(1000, 'Reviewed', true, 'Label', "Good", 'LabelSource', "confirmed");
            T = [T; R(200, 'Reviewed', true, 'Label', "Bad", 'LabelSource', "human")];
            T.CellID = uint32((1:height(T))');
            T.SourceId = repmat("sec|ECM1", height(T), 1);
            ids = curation.Audit.sampleConfirmAudit(T);
            tc.verifyNumElements(ids, 20, '2% of 1,000 confirmed rows');
            tc.verifyTrue(all(ids <= 1000), 'only confirmed rows');
            tc.verifyEqual(ids, curation.Audit.sampleConfirmAudit(T));
            T.AuditRole(1:5) = "confirm-audit";
            ids2 = curation.Audit.sampleConfirmAudit(T);
            tc.verifyNumElements(ids2, 15, 'ceil(2% of 995 + 5) = 20, 5 already there');
            tc.verifyFalse(any(ids2 <= 5));
        end

        function holdoutSampling(tc)
            rs = RandStream('mt19937ar', 'Seed', 5);
            R = @tAudit.rows;
            parts = cell(3, 1);
            for s = 1:3
                q = R(1000 * s, 'score', rand(rs, 1000 * s, 1));
                q.Section = repmat("sec" + s, height(q), 1);
                q.SourceKey = repmat("ECM1", height(q), 1);
                q.SourceId = q.Section + "|ECM1";
                parts{s} = q;
            end
            T = vertcat(parts{:});
            T.CellID = uint32((1:height(T))');
            T.Reviewed(1:100) = true;                 % reviewed rows are never held out
            T.AuditRole(101:110) = "reject-audit";
            pv = R(500, 'score', rand(rs, 500, 1));
            pv.Section = repmat("sec1", 500, 1); pv.SourceKey = repmat("PV2", 500, 1); pv.SourceId = pv.Section + "|PV2";
            T = [T; pv];
            H = curation.Audit.sampleHoldout(T, "pnn");
            tc.verifyEqual(height(H), 400);
            tc.verifyTrue(all(H.SourceKey == "ECM1"), 'one kind only');
            rows = double(H.CellID);
            tc.verifyFalse(any(rows <= 110), 'never reviewed rows or rows with a role');
            tc.verifyEqual(numel(unique(rows)), 400);
            cnt = accumarray(H.Stratum, 1, [11 1]);
            tc.verifyEqual(cnt(1:10), repmat(40, 10, 1), 'proportional to equal-size score deciles');
            share = [nnz(H.Section == "sec1") nnz(H.Section == "sec2") nnz(H.Section == "sec3")] / 400;
            tc.verifyEqual(share, [1 2 3] / 6, 'AbsTol', 0.02, 'spread across sections by size');
            tc.verifyEqual(curation.Audit.sampleHoldout(T, "pnn"), H, 'deterministic');
            % existing holdout rows count toward the target of 400
            T.AuditRole(double(H.CellID(1:100))) = "holdout";
            H2 = curation.Audit.sampleHoldout(T, "pnn");
            tc.verifyEqual(height(H2), 300);
            tc.verifyFalse(any(ismember(H2.CellID, H.CellID(1:100))));
            H3 = curation.Audit.sampleHoldout(T, "pnn", struct('N', 25, 'Seed', 9));
            tc.verifyEqual(height(H3), 25);
        end

        function suspensionIsMonotone(tc)
            % Finding 11 (cut down): the old rule switched from "lower bound > limit" below 149
            % audited rows to "upper bound > limit" from 149 on, so 6 cells in 148 did not suspend
            % but 1 cell in 149 did. Suspension must never come from MORE audits with the same cells
            % found, and must be monotone in the cells found for a fixed number audited.
            cs = @curation.Audit.checkSuspend;
            S = false(400, 13);
            for n = 1:400
                for k = 0:min(n, 12)
                    S(n, k + 1) = cs(n, k);
                end
            end
            for n = 1:400
                kk = 0:min(n, 12);
                tc.verifyTrue(issorted(double(S(n, kk + 1))), sprintf('not monotone in k at n = %d', n));
            end
            nonIncr = true;
            for k = 0:12
                s = double(S(max(k, 1):400, k + 1));
                if any(diff(s) > 0), nonIncr = false; break; end
            end
            tc.verifyTrue(nonIncr, sprintf(['more audited rejects with the same %d cell(s) found turned ' ...
                'a suspension on'], k));
            [s1, st1] = cs(149, 1);
            tc.verifyFalse(s1, '1 cell in 149 audited is not evidence that the miss rate exceeds 2%');
            tc.verifyEqual(st1.State, "not-enough-evidence");
            [s6, st6] = cs(148, 6);
            tc.verifyEqual(s6, st6.Lower > 0.02);
            % the three states
            [s, st] = cs(300, 0);
            tc.verifyFalse(s);
            tc.verifyEqual(st.State, "ok", 'upper bound below the limit: the claim is supported');
            tc.verifyLessThanOrEqual(st.Upper, 0.02);
            [s, st] = cs(15, 0);
            tc.verifyFalse(s);
            tc.verifyEqual(st.State, "not-enough-evidence");
            tc.verifySubstring(char(st.Text), 'not enough evidence');
            [s, st] = cs(15, 3);
            tc.verifyTrue(s);
            tc.verifyEqual(st.State, "suspended");
            tc.verifyGreaterThan(st.Lower, 0.02);
            [~, st] = cs(0, 0);
            tc.verifyTrue(isnan(st.Rate));
            tc.verifyEqual(st.State, "not-enough-evidence");
            tc.verifyError(@() cs(3, 4), 'curation:Audit:badArgument');
        end

        function autoRejectIsMarkedExperimental(tc)
            % Scope: CellCurator does not auto-reject. The functions that would are labelled so.
            for f = ["rejectThreshold" "checkSuspend" "sampleRejectAudit" "autoRejectMask"]
                h = evalc(sprintf('help curation.Audit.%s', f));
                tc.verifySubstring(h, 'EXPERIMENTAL', f);
                tc.verifySubstring(h, 'not used by CellCurator', f);
                tc.verifySubstring(h, 'per section', f);
            end
        end

        function evidenceIsOnlyRandomSamples(tc)
            % Finding 8 (cut down): confirm-audit rows are drawn from tiles left at their page
            % default (selected by the label), catch tiles are known non-cells and blind re-asks are
            % chosen by disagreement: none is a random sample of the candidates.
            R = @tAudit.rows;
            T = tAudit.catRows( ...
                R(1, 'Reviewed', true, 'Label', "Good", 'LabelSource', "blind", 'AuditRole', "holdout"), ...
                R(1, 'Reviewed', true, 'Label', "Bad", 'LabelSource', "blind", 'AuditRole', "reject-audit"), ...
                R(1, 'Reviewed', true, 'Label', "Bad", 'LabelSource', "blind", 'AuditRole', "confirm-audit"), ...
                R(1, 'Reviewed', true, 'Label', "Bad", 'LabelSource', "blind", 'AuditRole', "catch"), ...
                R(1, 'Reviewed', true, 'Label', "Good", 'LabelSource', "blind"));
            tc.verifyEqual(curation.Audit.evidenceMask(T), [true; true; false; false; false]);
            tc.verifyEqual(curation.Audit.RANDOM_ROLES, ["holdout" "reject-audit"]);
        end

        function degenerateThresholdIsNaN(tc)
            % Finding 9 (cut down): with no cell among the blind rows every threshold had
            % GoodLost = 0, and the reject-everything threshold (above the largest blind P) passed.
            p = linspace(0.001, 0.9, 1600)';
            g = false(1600, 1);
            sec = "s" + string(mod((1:1600)', 10));
            [tau, info] = curation.Audit.rejectThreshold(p, g, true(1600, 1), sec);
            tc.verifyTrue(isnan(tau), sprintf('no blind tile is a cell: tau must be NaN (got %g)', tau));
            tc.verifyEqual(info.Gate, "goods");
            tc.verifySubstring(char(info.Reason), 'no blind tile labelled Good');
            % a passing case never offers a threshold above the largest blind P
            p = [linspace(0.001, 0.4, 1000)'; linspace(0.6, 1, 500)'];
            g = [false(1000, 1); true(500, 1)];
            sec = "s" + string(mod((1:1500)', 10));
            [tau, info] = curation.Audit.rejectThreshold(p, g, true(1500, 1), sec);
            tc.verifyLessThanOrEqual(max(info.Curve.Threshold), max(p), 'no threshold above the largest blind P');
            tc.verifyEqual(tau, 0.6, 'AbsTol', 1e-12);
        end

        function evidenceNeedsRowIds(tc)
            % Finding 7: without a RowId column evidence() matched CellID against the model's
            % "<SourceId>|<CellID>" ids, which never matches, and silently used in-sample P.
            [m, F, ids] = tAudit.smallModel();
            R = @tAudit.rows;
            T = R(4, 'Reviewed', true, 'Label', "Bad", 'LabelSource', "blind", 'AuditRole', "holdout");
            tc.verifyError(@() curation.Audit.evidence(T, F(1:4, :), m), 'curation:Audit:noRowId');
            T.RowId = ids(1:4);
            E = curation.Audit.evidence(T, F(1:4, :), m);
            tc.verifyEqual(E.p, m.Stats.OofP(1:4), 'rows the model trained on: out-of-fold P');
            m0 = curation.AssistModel.fit(F(1:200, :), F(1:200, 1) > 0, "g" + string(mod((1:200)', 5)), ...
                struct('CVTrees', 5, 'NumTrees', 5));
            tc.verifyError(@() curation.Audit.evidence(T, F(1:4, :), m0), 'curation:Audit:noModelIds', ...
                'a model fitted without Ids cannot tell which rows it trained on');
        end

        function evidenceRefusesForeignModelP(tc)
            % Finding 7: a stored ModelP from another model version was used; rows without
            % features were dropped without a word.
            [m, F, ids] = tAudit.smallModel();
            R = @tAudit.rows;
            T = tAudit.catRows(R(3), R(1, 'ModelP', 0.2), R(1, 'ModelP', 0.3), ...
                R(1, 'Reviewed', true, 'Label', "Good", 'LabelSource', "blind", 'AuditRole', "holdout"));
            T.RowId = ids(501:506);
            T.ModelVersion = ["", "", "", "old-model", m.Version, ""]';
            Fq = F(501:506, :);
            Fq(4:6, :) = NaN;
            E = curation.Audit.evidence(T, Fq, m);
            tc.verifyTrue(isnan(E.p(4)), 'ModelP of another model version is refused');
            tc.verifyEqual(E.p(5), 0.3, 'ModelP of this model version is used');
            tc.verifyEqual(E.NoP, [false; false; false; true; false; true], ...
                'rows left without a P are reported');
            tc.verifyTrue(any(contains(E.Warnings, "another model")), 'and said so');
            tc.verifyTrue(any(contains(E.Warnings, "no features")));
        end

        function holdoutAccuracyUsesBlindLabelsOnly(tc)
            % Finding 5: holdout AUC accepted labels a person confirmed by default (a no-skill
            % model scored 1.000 against them); every accuracy number must use blind labels only.
            R = @tAudit.rows;
            T = tAudit.catRows( ...
                R(20, 'Reviewed', true, 'Label', "Good", 'LabelSource', "confirmed", 'AuditRole', "holdout", ...
                    'ModelP', linspace(0.6, 0.9, 20)'), ...
                R(20, 'Reviewed', true, 'Label', "Bad", 'LabelSource', "confirmed", 'AuditRole', "holdout", ...
                    'ModelP', linspace(0.1, 0.4, 20)'), ...
                R(3, 'Reviewed', true, 'Label', "Good", 'LabelSource', "blind", 'AuditRole', "holdout", 'ModelP', 0.2), ...
                R(3, 'Reviewed', true, 'Label', "Bad", 'LabelSource', "blind", 'AuditRole', "holdout", 'ModelP', 0.8), ...
                R(10, 'Reviewed', true, 'Label', "Good", 'LabelSource', "human", 'AuditRole', "reject-audit"), ...
                R(10, 'Label', "Bad", 'LabelSource', "auto"));
            T.SourceId = repmat("A", height(T), 1);
            T.Section = repmat("S1", height(T), 1);
            T.Kind = repmat("pnn", height(T), 1);
            s = curation.Audit.report(T).Kinds(1);
            tc.verifyTrue(isnan(s.HoldoutAUCModel), sprintf(['holdout AUC from non-blind labels: %.3f ' ...
                '(only 6 blind holdout labels exist)'], s.HoldoutAUCModel));
            tc.verifyEqual(s.HoldoutN, 6, 'only blind holdout labels count');
            tc.verifySubstring(char(s.HoldoutNote), 'too few');
            tc.verifyEqual(s.RejectAuditN, 0, 'a reject-audit row labelled openly is not audit evidence');
            % with enough blind labels the AUC is theirs alone (here the model is always wrong)
            T.LabelSource(1:40) = "blind";
            s = curation.Audit.report(T).Kinds(1);
            tc.verifyEqual(s.HoldoutN, 46);
            tc.verifyEqual(s.HoldoutAUCModel, curation.AssistModel.auc(T.ModelP(1:46), T.Label(1:46) == "Good"), ...
                'AbsTol', 1e-12);
        end

        function exportExclusionMaskMarksEvidence(tc)
            % One place to ask which rows may never train any model (assist, Stage 1, Stage 2).
            R = @tAudit.rows;
            T = tAudit.catRows( ...
                R(1, 'AuditRole', "holdout"), ...
                R(1, 'Reviewed', true, 'Label', "Good", 'LabelSource', "blind", 'AuditRole', "holdout"), ...
                R(1, 'Label', "Bad", 'LabelSource', "auto", 'AuditRole', "reject-audit"), ...
                R(1, 'Reviewed', true, 'Label', "Bad", 'LabelSource', "blind", 'AuditRole', "catch"), ...
                R(1, 'Reviewed', true, 'Label', "Good", 'LabelSource', "blind", 'AuditRole', "confirm-audit"), ...
                R(1, 'Reviewed', true, 'Label', "Good", 'LabelSource', "blind"), ...
                R(1, 'Reviewed', true, 'Label', "Bad", 'LabelSource', "human"));
            tc.verifyEqual(curation.Audit.exportExclusionMask(T), [true; true; true; true; false; false; false]);
            tc.verifyFalse(any(curation.Audit.exportExclusionMask(T) & curation.AssistModel.trainingMask(T)), ...
                'the assist model never trains on an excluded row');
        end

        function reportReviewerConsistency(tc)
            % Confirm audit: tiles first confirmed by default and later judged blind, split by the
            % default they were confirmed under and by the band of their page.
            T = tAudit.consistencyIndex();
            r = curation.Audit.report(T);
            s = r.Kinds(1);
            tc.verifyEqual([s.ConfirmAuditN s.ConfirmAuditDisagree s.ConfirmAuditPending s.ConfirmAuditUnknown], ...
                [39 7 3 1]);
            tc.verifyEqual([s.ConfirmGoodDefaultN s.ConfirmGoodDefaultChanged], [15 3]);
            tc.verifyEqual([s.ConfirmBadDefaultN s.ConfirmBadDefaultChanged], [24 4]);
            ci = curation.Audit.binomialInterval(4, 24);
            tc.verifyEqual([s.ConfirmBadDefaultRate s.ConfirmBadDefaultLo s.ConfirmBadDefaultHi], ...
                [4 / 24 ci], 'AbsTol', 1e-12);
            tc.verifyEqual(s.ConfirmedBadUnaudited, 303, '300 confirmed Bad + 3 pending audit rows');
            tc.verifyEqual(s.EstCellsLeftBad, 4 / 24 * 303, 'AbsTol', 1e-9);
            tc.verifyEqual([s.EstCellsLeftBadLo s.EstCellsLeftBadHi], ci * 303, 'AbsTol', 1e-9);
            tc.verifyEqual(s.ConfirmedGoodUnaudited, 102, '100 confirmed Good + 2 holdout rows confirmed openly');
            tc.verifyEqual(s.EstNonCellsKeptGood, 3 / 15 * 102, 'AbsTol', 1e-9);
            B = s.ConfirmByBand;
            tc.verifyEqual(B.Band, ["good"; "middle-high"; "middle-low"; "bad"]);
            tc.verifyEqual(B.Default, ["Good"; "Good"; "Bad"; "Bad"]);
            tc.verifyEqual([B.N B.Changed], [10 1; 5 2; 4 2; 20 2]);
            tc.verifyEqual(B.Rate, [0.1; 0.4; 0.5; 0.1], 'AbsTol', 1e-12);
            txt = curation.Audit.reportText(r);
            tc.verifySubstring(char(txt(1)), 'first confirmed by default and later shown again blind');
            tc.verifySubstring(char(txt(1)), 'on Bad-default pages 4 of 24');
            tc.verifySubstring(char(txt(1)), 'on Good-default pages 3 of 15');
            fprintf('\n[report text, consistency]\n%s\n', txt(1));
        end

        function reportModelAccuracyOnHoldout(tc)
            % Model accuracy on blind holdout labels against the raw rescore baseline (DeLong).
            T = tAudit.consistencyIndex();
            s = curation.Audit.report(T).Kinds(1);
            ho = T.AuditRole == "holdout" & T.LabelSource == "blind";
            y = T.Label(ho) == "Good";
            tc.verifyEqual(s.HoldoutN, nnz(ho));
            tc.verifyEqual(s.HoldoutPending, 6, '4 unlabelled + 2 labelled openly: all still to be judged blind');
            tc.verifyEqual(s.HoldoutAUCModel, curation.AssistModel.auc(T.ModelP(ho), y), 'AbsTol', 1e-12);
            tc.verifyEqual(s.HoldoutAUCRescore, curation.AssistModel.auc(T.rescore(ho), y), 'AbsTol', 1e-12);
            % DeLong variance by brute force
            [a, V] = curation.Audit.aucDeLong([T.ModelP(ho) T.rescore(ho)], y);
            X = [T.ModelP(ho) T.rescore(ho)];
            Xp = X(y, :); Xn = X(~y, :);
            m = nnz(y); n = nnz(~y);
            V10 = zeros(m, 2); V01 = zeros(n, 2);
            for c = 1:2
                psi = double(Xp(:, c) > Xn(:, c)') + 0.5 * double(Xp(:, c) == Xn(:, c)');
                V10(:, c) = mean(psi, 2);
                V01(:, c) = mean(psi, 1)';
            end
            tc.verifyEqual(a, mean(V10)', 'AbsTol', 1e-12);
            tc.verifyEqual(V, cov(V10) / m + cov(V01) / n, 'AbsTol', 1e-12);
            d = a(1) - a(2);
            se = sqrt(V(1, 1) + V(2, 2) - 2 * V(1, 2));
            tc.verifyEqual(s.HoldoutAUCDiff, d, 'AbsTol', 1e-12);
            tc.verifyEqual([s.HoldoutAUCDiffLo s.HoldoutAUCDiffHi], d + [-1 1] * 1.959963984540054 * se, 'AbsTol', 1e-9);
            tc.verifyEqual(s.HoldoutMeanP, mean(T.ModelP(ho)), 'AbsTol', 1e-12);
            tc.verifyEqual(s.HoldoutObservedGood, mean(y), 'AbsTol', 1e-12);
            txt = curation.Audit.reportText(curation.Audit.report(T));
            tc.verifySubstring(char(txt(1)), sprintf('held-out tiles judged blind'));
        end

        function reportPerSectionAndReviewer(tc)
            T = tAudit.consistencyIndex();
            s = curation.Audit.report(T).Kinds(1);
            tc.verifyEqual(s.Sections, 2, 'Sections stays the count');
            S = s.BySection;
            tc.verifyEqual(S.Section, ["S1"; "S2"]);
            tc.verifyEqual(S.Candidates, [nnz(T.Section == "S1") ; nnz(T.Section == "S2")]);
            tc.verifyEqual(sum(S.Reviewed), s.Reviewed);
            tc.verifyEqual(sum(S.Confirmed), s.Confirmed);
            tc.verifyEqual(sum(S.ConfirmAuditN), s.ConfirmAuditN);
            tc.verifyEqual(sum(S.ConfirmAuditChanged), s.ConfirmAuditDisagree);
            tc.verifyEqual(sum(S.HoldoutN), s.HoldoutN);
            Rv = s.Reviewers;
            tc.verifyTrue(all(ismember(["Reviewer" "Reviewed" "Confirmed" "Blind"], string(Rv.Properties.VariableNames))));
            tc.verifyEqual(sum(Rv.Reviewed), s.Reviewed);
            tc.verifyEqual(sum(Rv.Confirmed), s.Confirmed);
        end

        function confirmAuditSizeHelper(tc)
            % How many confirm-audit tiles the change rate's 95% interval needs to reach a half-width.
            sz = @curation.Audit.confirmAuditSize;
            n = sz(0.02, 0.05);
            hw = @(k, n) diff(curation.Audit.binomialInterval(k, n)) / 2;
            tc.verifyLessThanOrEqual(hw(round(0.05 * n), n), 0.02);
            tc.verifyGreaterThan(hw(round(0.05 * (n - 1)), n - 1), 0.02, 'the smallest such n');
            tc.verifyGreaterThan(sz(0.01, 0.05), n, 'a narrower interval costs more');
            tc.verifyLessThan(sz(0.02, 0.01), n, 'a rarer change needs fewer tiles');
            tc.verifyEqual(size(sz([0.02; 0.05], 0.1)), [2 1]);
        end

        function evidenceUsesOutOfFoldOrNeverTrainedP(tc)
            rs = RandStream('mt19937ar', 'Seed', 2);
            n = 600;
            F = randn(rs, n, 4);
            y = rand(rs, n, 1) < 1 ./ (1 + exp(-2 * F(:, 1)));
            ids = "S|" + string((1:n)');
            m = curation.AssistModel.fit(F(1:500, :), y(1:500), "g" + string(mod((1:500)', 5)), ...
                struct('Ids', ids(1:500), 'CVTrees', 10, 'NumTrees', 20));
            R = @tAudit.rows;
            T = tAudit.catRows( ...
                R(2, 'Reviewed', true, 'Label', "Good", 'LabelSource', "human"), ...         % trained, not evidence
                R(2, 'Reviewed', true, 'Label', "Bad", 'LabelSource', "blind", 'AuditRole', "reject-audit"), ... % trained, evidence
                R(2, 'Reviewed', true, 'Label', "Good", 'LabelSource', "blind", 'AuditRole', "holdout"), ...     % never trained
                R(2, 'Reviewed', true, 'Label', "Bad", 'LabelSource', "blind", 'AuditRole', "catch"), ...        % not evidence
                R(3), ...                                                                    % candidates
                R(1, 'ModelP', 0.123));                                                       % candidate, no features
            T.RowId = ids([1 2 3 4 501 502 5 6 503 504 505 506]');
            T.ModelVersion = repmat("", 12, 1);
            T.ModelVersion(12) = m.Version;           % a stored ModelP counts only from this model
            Fq = F([1 2 3 4 501 502 5 6 503 504 505 506], :);
            Fq(12, :) = NaN;
            E = curation.Audit.evidence(T, Fq, m);
            tc.verifyTrue(all(isnan(E.p([1 2 7 8]))), 'neither evidence nor candidate: no P');
            tc.verifyEqual(E.p(3:4), m.Stats.OofP(3:4), 'trained blind rows: out-of-fold P');
            tc.verifyEqual(E.p(5:6), m.predict(F(501:502, :)), 'never-trained rows: the model');
            tc.verifyEqual(E.p(9:11), m.predict(F(503:505, :)));
            tc.verifyEqual(E.p(12), 0.123, 'no features: the stored ModelP');
            tc.verifyEqual(E.isBlind, [false; false; true; true; true; true; false(6, 1)]);
            tc.verifyEqual(E.isGood([1 3 5 7 9]), [1; 0; 1; 0; NaN]);
        end

        function reportArithmetic(tc)
            T = tAudit.handMadeIndex();
            r = curation.Audit.report(T, struct('MinHoldoutPerClass', 2));   % 2 + 2 blind holdout tiles
            tc.verifyEqual(r.Table.Kind, ["pnn"; "pv"]);
            s = r.Kinds(1);
            tc.verifyEqual([s.Sources s.Sections s.Candidates s.Reviewed s.Kept], [2 2 86 46 17]);
            tc.verifyEqual([s.Good s.Bad s.Uncertain], [17 26 3]);
            tc.verifyEqual([s.Confirmed s.HumanDecided s.AutoRejected s.ToReview], [10 36 32 7]);
            tc.verifyEqual([s.RejectAuditN s.RejectAuditPending s.RejectAuditGood], [14 2 2]);
            tc.verifyEqual(s.RejectAuditRate, 2 / 14, 'AbsTol', 1e-15);
            ci = curation.Audit.binomialInterval(2, 14);
            tc.verifyEqual([s.RejectAuditLo s.RejectAuditHi], ci, 'AbsTol', 1e-15);
            tc.verifyEqual(s.RejectAuditUpper95, curation.Audit.upperBound(2, 14), 'AbsTol', 1e-15);
            tc.verifyEqual(s.EstCellsLost, 12 * (1 / 4) + 20 * (1 / 10), 'AbsTol', 1e-12, ...
                'per source: auto-rejected x audit rate');
            tc.verifyEqual(s.EstCellsLostUpper, curation.Audit.upperBound(2, 14) * 32, 'AbsTol', 1e-12);
            tc.verifyEqual([s.ConfirmAuditN s.ConfirmAuditDisagree], [3 1]);
            tc.verifyEqual(s.ConfirmAuditRate, 1 / 3, 'AbsTol', 1e-15);
            tc.verifyEqual([s.CatchN s.CatchHits s.CatchHitRate], [2 1 0.5]);
            tc.verifyEqual([s.HoldoutN s.HoldoutGood], [4 2]);
            tc.verifyEqual(s.HoldoutAUCModel, 1);
            tc.verifyEqual(s.HoldoutAUCRescore, 0.75);
            tc.verifyEqual(s.ReviewerCounts, "ann: 28; bob: 15; carl: 3");
            tc.verifyEqual(s.Reviewers.Reviewed, [28; 15; 3]);
            tc.verifyEqual(sum(s.Reviewers.Reviewed), s.Reviewed);
            p = r.Kinds(2);
            tc.verifyEqual([p.Candidates p.Reviewed p.Kept p.AutoRejected p.RejectAuditN], [3 2 2 1 0]);
            tc.verifyTrue(isnan(p.RejectAuditRate) && isnan(p.EstCellsLost));
            tc.verifyTrue(isnan(p.HoldoutAUCModel));
            % writetable-ready, and the text states the numbers
            f = [tempname '.csv'];
            writetable(r.Table, f);
            tc.addTeardown(@() delete(f));
            tc.verifyTrue(isfile(f));
            txt = curation.Audit.reportText(r);
            tc.verifyNumElements(txt, 2);
            tc.verifySubstring(char(txt(1)), 'PNN (WFA): 86 candidates in 2 sources (2 sections)');
            tc.verifySubstring(char(txt(1)), 'auto-reject (not part of CellCurator) removed 32 candidates without anyone seeing them');
            tc.verifySubstring(char(txt(1)), 'showed 14 of the rejects blind: 2 were cells or possibly cells (14.3%');
            tc.verifySubstring(char(txt(2)), 'PV: 3 candidates in 1 source (1 section)');
            tc.verifySubstring(char(txt(2)), 'removed 1 candidate without');
            tc.verifySubstring(char(txt(1)), 'an estimated 5 cells');
            tc.verifySubstring(char(txt(1)), 'of 3 tiles first confirmed by default and later shown again blind, 1 got a different label');
            tc.verifySubstring(char(txt(1)), '1 of 2 known non-cells');
            tc.verifySubstring(char(txt(1)), 'AUC 1.000 (95% CI 1.000 to 1.000), raw rescore 0.750');
            tc.verifySubstring(char(txt(2)), 'No audited reject has been labelled yet');
            fprintf('\n[report text]\n%s\n%s\n', txt(1), txt(2));
        end
    end

    methods (Test, TestTags = {'Slow'})
        function simulationRespectsTheBound(tc)
            % A KNOWN true miss rate: population p ~ U(0,1), P(cell | p) = 0.6 p^2 (so the share
            % of cells below t is 0.2 t^2, 1% at t = 0.224). 3,000 random blind tiles out of
            % 20,000 candidates in 30 sections; 300 seeded repetitions. Scenario 2 adds a
            % section effect (cells cluster by section, log-normal factor, sigma 1).
            reps = 300;
            res = struct();
            for scen = ["independent" "clustered"]
                ok = struct('binomial', 0, 'clustered', 0);
                nan_ = struct('binomial', 0, 'clustered', 0);
                rejected = struct('binomial', [], 'clustered', []);
                for r = 1:reps
                    rs = RandStream('mt19937ar', 'Seed', 1000 + r);
                    N = 20000;
                    p = rand(rs, N, 1);
                    sec = randi(rs, 30, N, 1);
                    pi0 = 0.6 * p .^ 2;
                    if scen == "clustered"
                        eff = exp(randn(rs, 30, 1) - 0.5);
                        pi0 = min(1, pi0 .* eff(sec));
                    end
                    cell_ = rand(rs, N, 1) < pi0;
                    blind = false(N, 1);
                    blind(randperm(rs, N, 3000)) = true;
                    g = nan(N, 1);
                    g(blind) = cell_(blind);
                    for bound = ["binomial" "clustered"]
                        [tau, info] = curation.Audit.rejectThreshold(p, g, blind, "s" + string(sec), ...
                            struct('Bound', bound, 'Bootstrap', 400, 'Seed', r));
                        if isnan(tau)
                            nan_.(bound) = nan_.(bound) + 1;
                            ok.(bound) = ok.(bound) + 1;
                            continue;
                        end
                        below = p < tau;
                        trueMiss = mean(pi0(below));          % expected share of cells below tau
                        ok.(bound) = ok.(bound) + (trueMiss <= 0.01);
                        rejected.(bound)(end + 1) = info.FracRejected;
                    end
                end
                res.(scen) = struct('ok', ok, 'nan', nan_, 'rejected', rejected);
                for bound = ["binomial" "clustered"]
                    fprintf('\n[simulation %s, %s bound] %d reps: true miss rate <= 1%% in %.1f%% (tau NaN in %d); median share auto-rejected %.1f%%\n', ...
                        scen, bound, reps, 100 * ok.(bound) / reps, nan_.(bound), 100 * median(rejected.(bound)));
                end
            end
            tc.verifyGreaterThanOrEqual(res.independent.ok.binomial / reps, 0.95);
            tc.verifyGreaterThanOrEqual(res.independent.ok.clustered / reps, 0.95);
            tc.verifyGreaterThanOrEqual(res.clustered.ok.clustered / reps, 0.95, ...
                'the default (clustered) bound holds when cells cluster by section');
            tc.verifyLessThan(res.independent.nan.clustered, reps, 'the threshold is usable at all');
        end
    end

    methods (Static)
        function T = handMadeIndex()
            % pnn: sources A (section S1) and B (S2); pv: source C. Every number is in reportArithmetic.
            R = @tAudit.rows;
            A = [ ...
                R(5, 'Reviewed', true, 'Label', "Good", 'LabelSource', "human", 'Reviewer', "ann"); ...
                R(3, 'Reviewed', true, 'Label', "Bad", 'LabelSource', "human", 'Reviewer', "ann"); ...
                R(2, 'Reviewed', true, 'Label', "Uncertain", 'LabelSource', "human", 'Reviewer', "bob"); ...
                R(4, 'Reviewed', true, 'Label', "Good", 'LabelSource', "confirmed", 'Reviewer', "bob"); ...
                R(6, 'Reviewed', true, 'Label', "Bad", 'LabelSource', "confirmed", 'Reviewer', "bob"); ...
                R(10, 'Label', "Bad", 'LabelSource', "auto"); ...
                R(1, 'Reviewed', true, 'Label', "Good", 'LabelSource', "blind", 'AuditRole', "reject-audit", 'Reviewer', "ann"); ...
                R(3, 'Reviewed', true, 'Label', "Bad", 'LabelSource', "blind", 'AuditRole', "reject-audit", 'Reviewer', "ann"); ...
                R(2, 'Label', "Bad", 'LabelSource', "auto", 'AuditRole', "reject-audit"); ...
                R(1, 'Reviewed', true, 'Label', "Good", 'LabelSource', "blind", 'AuditRole', "confirm-audit", 'Reviewer', "bob", 'PriorLabel', "Good"); ...
                R(1, 'Reviewed', true, 'Label', "Bad", 'LabelSource', "blind", 'AuditRole', "confirm-audit", 'Reviewer', "bob", 'PriorLabel', "Good"); ...
                R(1, 'Reviewed', true, 'Label', "Bad", 'LabelSource', "blind", 'AuditRole', "confirm-audit", 'Reviewer', "bob", 'PriorLabel', "Bad"); ...
                R(1, 'Reviewed', true, 'Label', "Bad", 'LabelSource', "blind", 'AuditRole', "catch", 'Reviewer', "ann"); ...
                R(1, 'Reviewed', true, 'Label', "Good", 'LabelSource', "blind", 'AuditRole', "catch", 'Reviewer', "ann"); ...
                R(2, 'Reviewed', true, 'Label', "Good", 'LabelSource', "blind", 'AuditRole', "holdout", 'Reviewer', "ann", ...
                    'ModelP', [0.9; 0.7], 'rescore', [2; -1]); ...
                R(2, 'Reviewed', true, 'Label', "Bad", 'LabelSource', "blind", 'AuditRole', "holdout", 'Reviewer', "ann", ...
                    'ModelP', [0.2; 0.4], 'rescore', [1; -2]); ...
                R(7); ...
                R(1, 'State', "merged", 'Reviewed', true, 'Label', "Good", 'LabelSource', "human", 'Reviewer', "ann"); ...
                R(1, 'Excluded', true)];
            A.SourceId = repmat("A", height(A), 1); A.Section = repmat("S1", height(A), 1);
            B = [ ...
                R(20, 'Label', "Bad", 'LabelSource', "auto"); ...
                R(9, 'Reviewed', true, 'Label', "Bad", 'LabelSource', "blind", 'AuditRole', "reject-audit", 'Reviewer', "ann"); ...
                R(1, 'Reviewed', true, 'Label', "Uncertain", 'LabelSource', "blind", 'AuditRole', "reject-audit", 'Reviewer', "ann"); ...
                R(3, 'Reviewed', true, 'Label', "Good", 'LabelSource', "human", 'Reviewer', "carl")];
            B.SourceId = repmat("B", height(B), 1); B.Section = repmat("S2", height(B), 1);
            P = [ ...
                R(2, 'Reviewed', true, 'Label', "Good", 'LabelSource', "human", 'Reviewer', "dan"); ...
                R(1, 'Label', "Bad", 'LabelSource', "auto")];
            P.SourceId = repmat("C", height(P), 1); P.Section = repmat("S1", height(P), 1);
            A.Kind = repmat("pnn", height(A), 1);
            B.Kind = repmat("pnn", height(B), 1);
            P.Kind = repmat("pv", height(P), 1);
            T = [A; B; P];
            T.CellID = uint32((1:height(T))');
        end
    end
end

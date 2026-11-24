classdef tQueues < matlab.unittest.TestCase
    % Tests for curation.Queues (pure data in, data out).

    methods (Static)
        function T = makeT(n)
            T = table(uint32((1:n)'), zeros(n, 1), zeros(n, 1), ...
                repmat("active", n, 1), repmat("", n, 1), false(n, 1), ...
                repmat("", n, 1), false(n, 1), true(n, 1), repmat("detected", n, 1), ...
                nan(n, 1), ...
                'VariableNames', {'CellID', 'X', 'Y', 'State', 'Label', 'Reviewed', ...
                'Flag', 'Excluded', 'InLocs', 'Origin', 'ModelP'});
            T.LabelSource = repmat("", n, 1);
            T.score = 0.5 * ones(n, 1);
            T.rescore = zeros(n, 1);
            T.AuditRole = repmat("", n, 1);
        end

        function ids = allIds(pages)
            ids = zeros(0, 1);
            for k = 1:numel(pages), ids = [ids; double(pages(k).Ids(:))]; end %#ok<AGROW>
        end

        function opts = o(ps)
            opts = struct('PageSize', ps, 'Bands', [0.15 0.5 0.85], ...
                'Order', ["middle" "good" "bad"]);
        end
    end

    methods (Test)
        function eligibilityEachCondition(tc)
            T = tQueues.makeT(6);
            tc.verifyEqual(curation.Queues.eligible(T), uint32((1:6)'));
            T.State(2) = "merged";
            T.State(3) = "stale";
            T.Reviewed(4) = true;
            T.Excluded(5) = true;
            tc.verifyEqual(curation.Queues.eligible(T), uint32([1; 6]));
            T = tQueues.makeT(6);
            T.Label(1) = "Bad";       % auto-rejected or labelled
            T.Flag(2) = "later";
            tc.verifyEqual(curation.Queues.eligible(T), uint32((3:6)'));
            tc.verifyClass(curation.Queues.eligible(T), 'uint32');
        end

        function reviewShowsOnlyEligible(tc)
            T = tQueues.makeT(8);
            T.Reviewed(1) = true; T.Flag(2) = "recheck"; T.Label(3) = "Bad";
            T.State(4) = "merged"; T.Excluded(5) = true;
            p = linspace(0.05, 0.95, 8)';
            pages = curation.Queues.review(T, p, tQueues.o(5));
            tc.verifyEqual(sort(tQueues.allIds(pages)), [6; 7; 8]);
        end

        function bandsDefaultsAndStraddle(tc)
            rng(1);
            n = 600;
            T = tQueues.makeT(n);
            p = rand(n, 1);
            pages = curation.Queues.review(T, p, tQueues.o(20));
            for k = 1:numel(pages)
                pg = pages(k);
                tc.verifyLessThanOrEqual(numel(pg.Ids), 20);
                switch pg.Band
                    case "middle-high"
                        tc.verifyTrue(all(pg.P >= 0.5 & pg.P < 0.85));
                        tc.verifyEqual(pg.Default, "Good");
                    case "middle-low"
                        tc.verifyTrue(all(pg.P >= 0.15 & pg.P < 0.5));
                        tc.verifyEqual(pg.Default, "Bad");
                    case "good"
                        tc.verifyTrue(all(pg.P >= 0.85));
                        tc.verifyEqual(pg.Default, "Good");
                    case "bad"
                        tc.verifyTrue(all(pg.P < 0.15));
                        tc.verifyEqual(pg.Default, "Bad");
                    otherwise
                        tc.verifyFail("unexpected band " + pg.Band);
                end
                tc.verifyEqual(pg.Queue, "review");
                tc.verifyFalse(any(pg.Blind));
                tc.verifyEqual(numel(pg.P), numel(pg.Ids));
                % P matches the input
                tc.verifyEqual(pg.P, p(double(pg.Ids)));
            end
        end

        function edgeValuesFallInUpperBand(tc)
            T = tQueues.makeT(4);
            p = [0.15; 0.5; 0.85; 0.1499];
            pages = curation.Queues.review(T, p, tQueues.o(10));
            band = containers.Map('KeyType', 'double', 'ValueType', 'char');
            for k = 1:numel(pages)
                for id = pages(k).Ids', band(double(id)) = char(pages(k).Band); end
            end
            tc.verifyEqual(band(1), 'middle-low');
            tc.verifyEqual(band(2), 'middle-high');
            tc.verifyEqual(band(3), 'good');
            tc.verifyEqual(band(4), 'bad');
        end

        function pageAndWithinPageOrder(tc)
            rng(2);
            n = 400;
            T = tQueues.makeT(n);
            p = rand(n, 1);
            pages = curation.Queues.review(T, p, tQueues.o(15));
            bands = string({pages.Band});
            % band sequence: middle-high, middle-low, good, bad
            [~, firstIdx] = unique(bands, 'stable');
            tc.verifyEqual(bands(sort(firstIdx)), ["middle-high" "middle-low" "good" "bad"]);
            tc.verifyEqual(issorted(double(arrayfun(@(b) find(["middle-high" "middle-low" "good" "bad"] == b), bands))), true);
            for b = ["middle-high" "good"]
                v = vertcat(pages(bands == b).P);
                tc.verifyTrue(issorted(-v), char(b + " descending"));
            end
            for b = ["middle-low" "bad"]
                v = vertcat(pages(bands == b).P);
                tc.verifyTrue(issorted(v), char(b + " ascending"));
            end
        end

        function orderOptionHonoured(tc)
            T = tQueues.makeT(4);
            p = [0.95; 0.6; 0.3; 0.05];
            opts = tQueues.o(10);
            opts.Order = ["bad" "good" "middle"];
            pages = curation.Queues.review(T, p, opts);
            tc.verifyEqual(string({pages.Band}), ["bad" "good" "middle-high" "middle-low"]);
        end

        function lastTwoPagesBalanced(tc)
            % 21 good ids, PageSize 10: 10,10,1 -> last < 25% -> 10,6,5
            T = tQueues.makeT(21);
            p = linspace(0.99, 0.9, 21)';
            pages = curation.Queues.review(T, p, tQueues.o(10));
            tc.verifyEqual(arrayfun(@(x) numel(x.Ids), pages)', [10 6 5]);
            % sort order kept across the balanced pages
            v = vertcat(pages.P);
            tc.verifyTrue(issorted(-v));
            % 23 ids: last page 3 >= 2.5 stays
            T = tQueues.makeT(23);
            p = linspace(0.99, 0.9, 23)';
            pages = curation.Queues.review(T, p, tQueues.o(10));
            tc.verifyEqual(arrayfun(@(x) numel(x.Ids), pages)', [10 10 3]);
            % 11 ids: 10,1 -> 6,5
            T = tQueues.makeT(11);
            p = linspace(0.99, 0.9, 11)';
            pages = curation.Queues.review(T, p, tQueues.o(10));
            tc.verifyEqual(arrayfun(@(x) numel(x.Ids), pages)', [6 5]);
        end

        function singleShortPageStays(tc)
            T = tQueues.makeT(1);
            pages = curation.Queues.review(T, 0.95, tQueues.o(100));
            tc.verifyEqual(numel(pages), 1);
            tc.verifyEqual(numel(pages(1).Ids), 1);
        end

        function everyIdExactlyOnce(tc)
            rng(3);
            n = 777;
            T = tQueues.makeT(n);
            p = rand(n, 1);
            for ps = [7 50 126]
                pages = curation.Queues.review(T, p, tQueues.o(ps));
                ids = tQueues.allIds(pages);
                tc.verifyEqual(sort(ids), (1:n)');
                tc.verifyLessThanOrEqual(max(arrayfun(@(x) numel(x.Ids), pages)), ps);
            end
        end

        function deterministicWithTies(tc)
            n = 60;
            T = tQueues.makeT(n);
            p = 0.9 * ones(n, 1);
            p(1:20) = 0.3;
            a = curation.Queues.review(T, p, tQueues.o(8));
            perm = [n:-1:1]';
            Tp = T(perm, :);
            b = curation.Queues.review(Tp, p(perm), tQueues.o(8));
            tc.verifyEqual(tQueues.allIds(a), tQueues.allIds(b));
            tc.verifyEqual(string({a.PageId}), string({b.PageId}));
            % ties broken by ascending CellID
            ids = tQueues.allIds(a(string({a.Band}) == "good"));
            tc.verifyEqual(ids, (21:60)');
        end

        function emptyInput(tc)
            T = tQueues.makeT(3);
            T.Reviewed(:) = true;
            want = {'Ids', 'P', 'Default', 'Band', 'Blind', 'Title', 'Queue', 'PageId'};
            pages = curation.Queues.review(T, [0.5; 0.5; 0.5], tQueues.o(10));
            tc.verifySize(pages, [0 1]);
            tc.verifyEqual(sort(fieldnames(pages))', sort(want));
            f = curation.Queues.flagged(T, tQueues.o(10));
            tc.verifySize(f, [0 1]);
            tc.verifyEqual(sort(fieldnames(f))', sort(want));
            v = curation.Queues.vanishedGood(T, tQueues.o(10));
            tc.verifySize(v, [0 1]);
            T0 = tQueues.makeT(0);
            pages = curation.Queues.review(T0, zeros(0, 1), tQueues.o(10));
            tc.verifySize(pages, [0 1]);
        end

        function pageIdStability(tc)
            T = tQueues.makeT(30);
            p = linspace(0.99, 0.9, 30)';
            a = curation.Queues.review(T, p, tQueues.o(10));
            b = curation.Queues.review(T, p, tQueues.o(10));
            tc.verifyEqual(string({a.PageId}), string({b.PageId}));
            tc.verifyEqual(numel(unique(string({a.PageId}))), numel(a));
            % different content, different id
            T2 = T(2:end, :);
            c = curation.Queues.review(T2, p(2:end), tQueues.o(10));
            tc.verifyNotEqual(a(1).PageId, c(1).PageId);
        end

        function flaggedVanishedBrowse(tc)
            n = 10;
            T = tQueues.makeT(n);
            T.rescore = (1:n)' / 2;     % flagged() derives P from rescore
            T.Flag([2 5 7]) = ["later" "recheck" "later"];
            T.Reviewed([3 4 6]) = true;
            T.Label([3 4 6]) = ["Good" "Good" "Bad"];
            T.InLocs(4) = false;          % vanished Good
            T.Origin(6) = "added";
            T.LabelSource(8) = "auto"; T.Label(8) = "Bad";
            p = (1:n)' / 11;
            f = curation.Queues.flagged(T, tQueues.o(2));
            tc.verifyEqual(tQueues.allIds(f), [7; 5; 2]);   % P descending
            tc.verifyTrue(all([f.Default] == ""));
            tc.verifyEqual(f(1).Queue, "flagged");
            v = curation.Queues.vanishedGood(T, tQueues.o(5));
            tc.verifyEqual(tQueues.allIds(v), 4);
            br = curation.Queues.browse(T, p, "Good", tQueues.o(5));
            tc.verifyEqual(tQueues.allIds(br), [4; 3]);
            br = curation.Queues.browse(T, p, "Bad", tQueues.o(5));
            tc.verifyEqual(tQueues.allIds(br), 6);
            br = curation.Queues.browse(T, p, "auto", tQueues.o(5));
            tc.verifyEqual(tQueues.allIds(br), 8);
            br = curation.Queues.browse(T, p, "all", tQueues.o(5));
            tc.verifyEqual(sort(tQueues.allIds(br)), [3; 4; 6; 8]);
            tc.verifyEqual(br(1).Default, "");
        end

        function summaryConsistent(tc)
            rng(4);
            n = 500;
            T = tQueues.makeT(n);
            T.Reviewed(1:40) = true;
            T.Flag(41:50) = "later";
            T.Label(51:60) = "Bad";
            p = rand(n, 1);
            opts = tQueues.o(30);
            s = curation.Queues.summary(T, p, opts);
            pages = curation.Queues.review(T, p, opts);
            tc.verifyEqual(s.reviewRemaining, numel(tQueues.allIds(pages)));
            tc.verifyEqual(s.pagesRemaining, numel(pages));
            tc.verifyEqual(s.bands.bad + s.bands.middleLow + s.bands.middleHigh + s.bands.good, ...
                s.reviewRemaining);
            for b = ["good" "bad" "middle-high" "middle-low"]
                cnt = sum(arrayfun(@(x) numel(x.Ids), pages(string({pages.Band}) == b)));
                fld = struct('good', 'good', 'bad', 'bad', 'middle_high', 'middleHigh', ...
                    'middle_low', 'middleLow');
                tc.verifyEqual(s.bands.(fld.(strrep(char(b), '-', '_'))), cnt);
            end
            tc.verifyEqual(s.flagged, 10);
            tc.verifyEqual(s.reviewed, 40);
            tc.verifyEqual(s.total, n);
            tc.verifyEqual(s.vanishedGood, 0);
        end

        function auditRowsAreBlindTiles(tc)
            % Finding 4: a holdout row was an ordinary tile with a default (Enter turned it into a
            % confirmed label and the holdout silently shrank) and a confirm-audit row (already
            % confirmed) could never be shown again.
            n = 300;
            T = tQueues.makeT(n);
            T.AuditRole(1:12) = "holdout";                          % never shown yet
            T.AuditRole(13:20) = "confirm-audit";                   % confirmed by default earlier
            T.Reviewed(13:20) = true; T.Label(13:20) = "Good"; T.LabelSource(13:20) = "confirmed";
            T.AuditRole(21:22) = "confirm-audit";                   % already judged blind: done
            T.Reviewed(21:22) = true; T.Label(21:22) = "Bad"; T.LabelSource(21:22) = "blind";
            T.AuditRole(23) = "holdout";                            % already judged blind: done
            T.Reviewed(23) = true; T.Label(23) = "Good"; T.LabelSource(23) = "blind";
            rs = RandStream('mt19937ar', 'Seed', 7);
            p = rand(rs, n, 1);
            opts = tQueues.o(40);
            pages = curation.Queues.review(T, p, opts);
            ids = tQueues.allIds(pages);
            blind = vertcat(pages.Blind);
            tc.verifyEqual(sort(ids(blind)), (1:20)', ...
                'pending holdout and confirm-audit rows are blind tiles');
            tc.verifyFalse(any(ismember(ids, 21:23)), 'rows already judged blind are done');
            tc.verifyEqual(sort(ids(~blind)), (24:n)', 'every other eligible row is an ordinary tile');
            cap = floor(0.15 * 40);
            for k = 1:numel(pages)
                pg = pages(k);
                tc.verifyLessThanOrEqual(numel(pg.Ids), 40);
                tc.verifyEqual(size(pg.Blind), size(pg.Ids));
                if any(~pg.Blind)
                    tc.verifyLessThanOrEqual(nnz(pg.Blind), cap, 'at most 15% of a page is blind');
                end
            end
            % interleaved at positions that are not simply the start or the end of the page
            pos = [];
            for k = 1:numel(pages)
                f = find(pages(k).Blind);
                pos = [pos; f / numel(pages(k).Ids)]; %#ok<AGROW>
            end
            tc.verifyGreaterThan(std(pos), 0.1, 'blind tiles are spread over the page');
            tc.verifyEqual(sort(curation.Queues.eligible(T)), uint32([(1:20)'; (24:n)']));
            s = curation.Queues.summary(T, p, opts);
            tc.verifyEqual(s.reviewRemaining, numel(ids));
            tc.verifyEqual(s.blind, 20);
            tc.verifyEqual(s.pagesRemaining, numel(pages));
            % deterministic given the ids: row order does not matter
            perm = n:-1:1;
            b = curation.Queues.review(T(perm, :), p(perm), opts);
            tc.verifyEqual(tQueues.allIds(b), ids);
            tc.verifyEqual(vertcat(b.Blind), blind);
            % no ordinary rows left: pages of blind tiles only, with no default
            T2 = T;
            T2.Reviewed(24:end) = true; T2.Label(24:end) = "Bad"; T2.LabelSource(24:end) = "human";
            pg2 = curation.Queues.review(T2, p, opts);
            tc.verifyEqual(sort(tQueues.allIds(pg2)), (1:20)');
            tc.verifyTrue(all(vertcat(pg2.Blind)));
            tc.verifyTrue(all([pg2.Default] == ""), 'a blind-only page has no default');
            % the GUI's table has no AuditRole column: no error, nothing blind
            T3 = removevars(tQueues.makeT(50), 'AuditRole');
            pg3 = curation.Queues.review(T3, rand(rs, 50, 1), opts);
            tc.verifyFalse(any(vertcat(pg3.Blind)));
        end

        function tiesInPBrokenByRawScore(tc)
            % Finding 2: within a flat block of the calibration map rows tie in P; the order must
            % then follow the raw score (opts.Raw), not CellID.
            n = 60;
            T = tQueues.makeT(n);
            raw = mod((1:n)' * 37, 61) / 61;           % a permutation of distinct values
            opts = tQueues.o(100);
            opts.Raw = raw;
            pages = curation.Queues.review(T, repmat(0.05, n, 1), opts);    % bad band: ascending
            tc.verifyEqual(raw(tQueues.allIds(pages)), sort(raw), 'likely bad: lowest raw first');
            pages = curation.Queues.review(T, repmat(0.95, n, 1), opts);    % good band: descending
            tc.verifyEqual(raw(tQueues.allIds(pages)), sort(raw, 'descend'), 'likely good: highest raw first');
            Tr = T;
            Tr.Reviewed(:) = true;
            br = curation.Queues.browse(Tr, repmat(0.5, n, 1), "all", opts);
            tc.verifyEqual(raw(tQueues.allIds(br)), sort(raw, 'descend'), 'browse: P then raw descending');
        end

        function timing3000(tc)
            rng(5);
            n = 3000;
            T = tQueues.makeT(n);
            T.Reviewed(1:200) = true;
            p = rand(n, 1);
            opts = tQueues.o(126);
            curation.Queues.review(T, p, opts);      % warm up
            reps = 15;
            t = zeros(reps, 1);
            for k = 1:reps
                tic; curation.Queues.review(T, p, opts); t(k) = 1000 * toc;
            end
            fprintf('tQueues.timing3000: review on %d rows, median %.2f ms, max %.2f ms\n', ...
                n, median(t), max(t));
            tc.verifyLessThan(median(t), 20);
            % with blind tiles (60 holdout + 40 confirm-audit rows) and a raw tie-break key
            T.AuditRole(201:260) = "holdout";
            T.AuditRole(1:40) = "confirm-audit";
            T.Label(1:40) = "Good"; T.LabelSource(1:40) = "confirmed";
            opts.Raw = rand(n, 1);
            curation.Queues.review(T, p, opts);
            for k = 1:reps
                tic; pages = curation.Queues.review(T, p, opts); t(k) = 1000 * toc;
            end
            fprintf('tQueues.timing3000: with 100 blind tiles and Raw, median %.2f ms, max %.2f ms (%d pages)\n', ...
                median(t), max(t), numel(pages));
            tc.verifyEqual(nnz(vertcat(pages.Blind)), 100);
            tc.verifyLessThan(median(t), 20);
        end
    end
end

classdef (TestTags = {'Slow', 'RealData'}) tDisplayCandidates < matlab.unittest.TestCase
    %tDisplayCandidates  Integration pass C, item 2: candidate default displays of the gallery tiles
    %   on the real sections (a temporary copy of %LOCALAPPDATA%\counting_perineuronal_nets\
    %   real_sections; skipped without it), side by side, for a person to look at: one PNG per
    %   source (24 middle-band candidates, then the 8 most likely cells; candidates stacked top to
    %   bottom in the order printed) in the folder CURATOR_DISPLAY_OUT names (default tempdir), and
    %   the numbers. Checks that the chosen default (curation.DisplayDefaults, "chosen") shows the
    %   middle-band cells' centres at least half bright without saturating any more pixels than the
    %   page limits did.

    properties
        Folder
    end

    methods (TestClassSetup)
        function copyRealSections(tc)
            master = fullfile(getenv('LOCALAPPDATA'), 'counting_perineuronal_nets', 'real_sections');
            tc.assumeTrue(isfolder(master), 'no local copy of real sections here');
            fx = tc.applyFixture(matlab.unittest.fixtures.TemporaryFolderFixture);
            tc.Folder = fullfile(fx.Folder, 'real_sections');
            copyfile(master, tc.Folder);
        end
    end

    methods (Test)
        function candidates(tc)
            out = getenv('CURATOR_DISPLAY_OUT');
            if isempty(out), out = tempdir; end
            if ~isfolder(out), mkdir(out); end
            tifs = dir(fullfile(tc.Folder, '**', '*_proj.tif'));
            tc.assertNotEmpty(tifs);
            % candidate: name, Target of curation.DisplayDefaults ([] = fixed gamma), fixed gamma
            C = {"A page limits, gamma 1 (before)", [], 1
                "F page limits, gamma 0.6 (fixed)", [], 0.6
                "G adaptive gamma, target 0.55", 0.55, NaN
                "H adaptive gamma, target 0.60 (chosen)", 0.6, NaN
                "I adaptive gamma, target 0.65", 0.65, NaN};
            fprintf('\n[display] candidates (top to bottom in every PNG):\n');
            for c = 1:size(C, 1), fprintf('[display]   %s\n', C{c, 1}); end
            um = 1.657;
            for t = 1:numel(tifs)
                tif = fullfile(tifs(t).folder, tifs(t).name);
                stem = erase(tifs(t).name, '.tif');
                pages = {imread(tif, 1), imread(tif, 2)};
                keys = ["ECM1" "PV2"];
                for ch = 1:2
                    L = readtable(fullfile(tifs(t).folder, stem + "_" + keys(ch) + "_locs.csv"));
                    pT = pages{ch}; pC = pages{3 - ch};
                    ids = uint32((1:height(L))');
                    c = curation.CropCache.build(pT, pC, ids, [L.X L.Y], um);
                    p = curation.Proposals.coldStart(L, keys(ch));
                    mid = find(p > 0.15 & p < 0.85);
                    good = find(p >= 0.85);
                    rs = RandStream('mt19937ar', 'Seed', 7);
                    mid = mid(sort(randperm(rs, numel(mid), min(24, numel(mid)))));
                    [~, o] = sort(p(good), 'descend');
                    good = good(o(1:min(8, numel(o))));
                    [~, o] = sort(p(mid));
                    show = [mid(o); good];
                    % crop pixel statistics (uint8 at the page limits)
                    A = c.Crops;
                    v = double(A(1:3:end));
                    q = prctile(v, [50 90 99 99.5 99.8 99.9]);
                    lim = c.Limits(1, :);
                    toPage = @(u) lim(1) + u / 255 * diff(lim);
                    T = c.TilePx; [xx, yy] = meshgrid(1:T, 1:T);
                    disc = hypot(xx - (T + 1) / 2, yy - (T + 1) / 2) <= 15 * T / c.WindowUm;   % 15 um radius
                    cen = @(k) double(reshape(A(:, :, k), [], 1));
                    midC = arrayfun(@(k) prctile(cen(k), 95), mid);
                    goodC = arrayfun(@(k) prctile(cen(k), 95), good);
                    fprintf(['\n[display] %s %s: %d cells, page limits [%.1f %.1f] (page units); crop pixels p50 %.0f ' ...
                        'p90 %.0f p99 %.0f p99.5 %.0f p99.8 %.0f p99.9 %.0f (of 255) = page %.1f/%.1f/%.1f/%.1f/%.1f/%.1f; ' ...
                        'centre p95 of the shown middle-band cells: median %.0f; of the likely-good: median %.0f\n'], ...
                        stem, keys(ch), height(L), lim, q, toPage(q), median(midC), median(goodC));
                    rows = {};
                    for k = 1:size(C, 1)
                        if isempty(C{k, 2})
                            g = 1; gam = C{k, 3};
                        else
                            dd = curation.DisplayDefaults.fromCache(c, struct('Ids', uint32(find(p > 0.15 & p < 0.85)), ...
                                'Target', C{k, 2}));
                            g = dd.Gain(1); gam = dd.Gamma(1);
                        end
                        st = struct('Mode', "target", 'Gain', g, 'Gamma', gam, 'BorderPx', 0, 'Gap', 2, ...
                            'Background', [60 60 60]);
                        M = c.compose(uint32(show), 4, 8, st);
                        rows{end + 1} = M; %#ok<AGROW>
                        rows{end + 1} = 255 * ones(6, size(M, 2), 3, 'uint8'); %#ok<AGROW>
                        lut = 255 * min(1, (0:255)' / 255 * g) .^ gam;
                        dm = median(lut(round(midC) + 1));
                        sat = mean(arrayfun(@(kk) mean(lut(cen(kk) + 1) >= 254.5), good));
                        fprintf('[display]   %-40s gain %.2f gamma %.2f: middle-band centre p95 shown at %.0f/255; likely-good centres saturated %.1f%%\n', ...
                            C{k, 1}, g, gam, dm, 100 * sat);
                        if k == 1, satBefore = sat; end
                        if contains(C{k, 1}, "(chosen)")
                            tc.verifyGreaterThanOrEqual(dm, 128, sprintf('%s %s: middle-band cells at least half bright', stem, keys(ch)));
                            tc.verifyLessThanOrEqual(sat, satBefore + 1e-9, 'no more saturated pixels than the page limits');
                        end
                    end
                    img = vertcat(rows{:});
                    file = fullfile(out, sprintf('%s_%s.png', regexprep(stem, '^SUBJ-ID-(\d+)IHC_ECM26A260519S2_(\w\w).*$', 'S$1_$2'), keys(ch)));
                    imwrite(img, file);
                    fprintf('[display]   -> %s\n', file);
                end
            end
        end
    end
end

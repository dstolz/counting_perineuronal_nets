classdef Stats
%STATS  Grouped distributions of the cell measurements (static, pure: tables in, numbers out).
%
%   C is the long cell table of cellanalysis.Project.load (one row per cell, with the section's
%   tags); METRIC a column of it; GROUPBY a column that names the group of each cell ("" = one
%   group, "All"); UNIT what one observation is:
%       "cells"    every cell counts once (sections with many cells weigh more)
%       "section"  one value per section: the median of its cells (the mean for a 0/1 metric
%                  such as Colocalized, i.e. the fraction)
%       "subject"  one value per subject, the same way, over all of the subject's cells
%   Cells whose metric is not finite are left out everywhere; a cell without a group value is in
%   the group "(none)".
%
%   [v, g, names, n] = cellanalysis.Stats.values(C, metric, groupBy, unit)
%       v      observations (column)
%       g      group index of each observation (into names)
%       names  group names (string column), sorted
%       n      cells behind each observation
%   [x, y, g, names, n] = cellanalysis.Stats.pairs(C, xMetric, yMetric, groupBy, unit)
%       Two metrics of the same observations, for a scatter plot: only the cells where both are
%       finite; with "section" or "subject" one point per section or subject (each metric
%       summarized as VALUES does). A value that is the same for all cells of a subject (a lab
%       database variable) is that value.
%   R = cellanalysis.Stats.summary(C, metric, groupBy, unit)
%       table Group, N (observations), Cells, Mean, SD, SEM, Median, Q1, Q3, Min, Max
%   H = cellanalysis.Stats.histogram(C, metric, groupBy, unit, opts)
%       struct Edges, Centers, Names, Counts (groups x bins), Share (each group sums to 1), N.
%       opts.Bins (default automatic, 10..60), opts.Limits [lo hi] (default: 0.5th..99.5th
%       percentile, so one wild value does not flatten the plot; values outside are counted in
%       the end bins).
%   E = cellanalysis.Stats.cdf(C, metric, groupBy, unit)
%       struct Names, X {per group}, F {per group} (empirical cumulative distribution), N
%   D = cellanalysis.Stats.depthProfile(C, S, metric, groupBy, opts)
%       How a metric, or the density of cells, changes with the distance from the brain surface.
%       Each section gives one profile; a group's profile is the mean of its sections.
%       S: the sources table (its JsonPath gives the tissue area per depth of each section).
%       metric "" or "Density": cells per mm^2 of tissue in each depth bin; else the mean of the
%       metric over the cells of the bin. opts.BinUm (50; rounded to a multiple of 25),
%       opts.MaxUm (default: the depth holding 99% of the cells), opts.MinCells (3: a bin of a
%       section with fewer cells gives no metric value), opts.MinAreaUm2 (5000: a bin of a
%       section with less tissue gives no density), opts.MinDepthUm (0: the cells closer than
%       this to the surface are rejected, and so is the tissue there, so a bin within the band
%       has no value and a bin across its border counts only the tissue beyond it).
%       struct Edges, Centers, Names, Mean (groups x bins), Sem, N (sections behind each value),
%       Sections (string), SectionGroup (index), PerSection (sections x bins), IsDensity, Unit
%
%   a = cellanalysis.Stats.areaBeyond(edges, area, minUm)
%       The tissue area of each depth bin [edges(k), edges(k+1)) that lies at minUm or deeper,
%       taking the area as spread evenly over the depths of its bin (the record keeps 25 um
%       bins). minUm <= 0 leaves the area as it is.
%
%   K = cellanalysis.Stats.colocalization(C, Sec, groupBy)
%       How many cells of the analyzed channel are paired with a cell of the other channel, and
%       the reverse, per section and per group. C: the cells (their Colocalized and ColocChance
%       columns); Sec: the second output of cellanalysis.Project.load (the other channel's cell
%       count of each section). Sections without another channel are left out. A grouping by a
%       property of single cells (Colocalized) is ignored.
%       struct Sections (table SourceRow, Group, Cells, OtherCells, Pairs, PctThis = 100 *
%       Pairs / Cells, PctOther = 100 * Pairs / OtherCells, PctChance = 100 * mean(ColocChance),
%       Enrichment = PctThis / PctChance, ThisPerMm2, OtherPerMm2), Names, Group (index per
%       section), Summary (table Group, Sections, Cells, OtherCells, Pairs, PctThis, SEM,
%       PctOther, SEMOther, PctChance, Enrichment: the percentages are means of the sections).
%
%   See also cellanalysis.Project, cellanalysis.Plots.

    methods (Static)

        function [v, g, names, n] = values(C, metric, groupBy, unit)
            %VALUES  The observations of a metric and their groups (see the class help).
            if nargin < 3, groupBy = ""; end
            if nargin < 4 || strlength(string(unit)) == 0, unit = "cells"; end
            unit = lower(string(unit));
            v = zeros(0, 1); g = zeros(0, 1); names = strings(0, 1); n = zeros(0, 1);
            if isempty(C) || ~ismember(char(metric), C.Properties.VariableNames), return; end
            x = double(C.(char(metric)));
            grp = cellanalysis.Stats.groupOf(C, groupBy);
            ok = isfinite(x);
            x = x(ok); grp = grp(ok);
            if isempty(x), return; end
            switch unit
                case "cells"
                    v = x;
                    n = ones(numel(x), 1);
                    gv = grp;
                case {"section", "subject"}
                    who = cellanalysis.Stats.whoOf(C, ok, unit);
                    [~, ~, j] = unique(who + char(31) + grp);
                    v = cellanalysis.Stats.perUnit(x, j, metric);
                    n = accumarray(j, 1);
                    first = accumarray(j, (1:numel(j))', [], @min);
                    gv = grp(first);
                otherwise
                    error('cellanalysis:Stats:badUnit', 'unit must be "cells", "section" or "subject".');
            end
            [names, ~, g] = unique(gv);
            names = names(:);
        end

        function [x, y, g, names, n] = pairs(C, xMetric, yMetric, groupBy, unit)
            %PAIRS  Two metrics of the same observations (see the class help).
            if nargin < 4, groupBy = ""; end
            if nargin < 5 || strlength(string(unit)) == 0, unit = "cells"; end
            unit = lower(string(unit));
            x = zeros(0, 1); y = zeros(0, 1); g = zeros(0, 1); names = strings(0, 1); n = zeros(0, 1);
            if isempty(C) || ~all(ismember({char(xMetric), char(yMetric)}, C.Properties.VariableNames)), return; end
            xa = double(C.(char(xMetric)));
            ya = double(C.(char(yMetric)));
            grp = cellanalysis.Stats.groupOf(C, groupBy);
            ok = isfinite(xa) & isfinite(ya);
            xa = xa(ok); ya = ya(ok); grp = grp(ok);
            if isempty(xa), return; end
            switch unit
                case "cells"
                    x = xa; y = ya; gv = grp;
                    n = ones(numel(xa), 1);
                case {"section", "subject"}
                    who = cellanalysis.Stats.whoOf(C, ok, unit);
                    [~, ~, j] = unique(who + char(31) + grp);
                    x = cellanalysis.Stats.perUnit(xa, j, xMetric);
                    y = cellanalysis.Stats.perUnit(ya, j, yMetric);
                    n = accumarray(j, 1);
                    first = accumarray(j, (1:numel(j))', [], @min);
                    gv = grp(first);
                otherwise
                    error('cellanalysis:Stats:badUnit', 'unit must be "cells", "section" or "subject".');
            end
            [names, ~, g] = unique(gv);
            names = names(:);
        end

        function R = summary(C, metric, groupBy, unit)
            %SUMMARY  One row of descriptive statistics per group.
            if nargin < 3, groupBy = ""; end
            if nargin < 4, unit = "cells"; end
            [v, g, names, n] = cellanalysis.Stats.values(C, metric, groupBy, unit);
            k = numel(names);
            Group = names;
            [N, Cells, Mean, SD, SEM, Median, Q1, Q3, Min, Max] = deal(nan(k, 1));
            for i = 1:k
                x = v(g == i);
                N(i) = numel(x);
                Cells(i) = sum(n(g == i));
                Mean(i) = mean(x);
                SD(i) = std(x);
                SEM(i) = SD(i) / sqrt(N(i));
                q = prctile(x, [25 50 75]);
                Q1(i) = q(1); Median(i) = q(2); Q3(i) = q(3);
                Min(i) = min(x); Max(i) = max(x);
            end
            R = table(Group, N, Cells, Mean, SD, SEM, Median, Q1, Q3, Min, Max);
        end

        function H = histogram(C, metric, groupBy, unit, opts)
            %HISTOGRAM  Counts and shares per bin and group, on bins common to every group.
            if nargin < 3, groupBy = ""; end
            if nargin < 4, unit = "cells"; end
            if nargin < 5 || isempty(opts), opts = struct(); end
            [v, g, names] = cellanalysis.Stats.values(C, metric, groupBy, unit);
            H = struct('Edges', [0 1], 'Centers', 0.5, 'Names', names, 'Counts', zeros(numel(names), 1), ...
                'Share', zeros(numel(names), 1), 'N', zeros(numel(names), 1));
            if isempty(v), return; end
            if isfield(opts, 'Limits') && numel(opts.Limits) == 2 && opts.Limits(2) > opts.Limits(1)
                lim = double(opts.Limits);
            else
                lim = prctile(v, [0.5 99.5]);
                if all(v == 0 | v == 1), lim = [0 1]; end
                if ~(lim(2) > lim(1)), lim = [min(v), max(v)]; end
                if ~(lim(2) > lim(1)), lim = lim(1) + [-0.5 0.5]; end
            end
            if isfield(opts, 'Bins') && ~isempty(opts.Bins) && opts.Bins >= 1
                nb = round(opts.Bins);
            else
                per = accumarray(g, 1);
                nb = min(60, max(10, round(2 * median(per)^(1 / 3))));
                if numel(unique(v)) <= 12, nb = max(numel(unique(v)), 2); end
            end
            edges = linspace(lim(1), lim(2), nb + 1);
            counts = zeros(numel(names), nb);
            for i = 1:numel(names)
                x = min(max(v(g == i), lim(1)), lim(2));
                counts(i, :) = histcounts(x, edges);
            end
            H.Edges = edges;
            H.Centers = (edges(1:end - 1) + edges(2:end)) / 2;
            H.Counts = counts;
            H.N = sum(counts, 2);
            H.Share = counts ./ max(H.N, 1);
        end

        function E = cdf(C, metric, groupBy, unit)
            %CDF  Empirical cumulative distribution per group.
            if nargin < 3, groupBy = ""; end
            if nargin < 4, unit = "cells"; end
            [v, g, names] = cellanalysis.Stats.values(C, metric, groupBy, unit);
            E = struct('Names', names, 'X', {cell(numel(names), 1)}, 'F', {cell(numel(names), 1)}, ...
                'N', zeros(numel(names), 1));
            for i = 1:numel(names)
                x = sort(v(g == i));
                E.X{i} = x;
                E.F{i} = (1:numel(x))' / numel(x);
                E.N(i) = numel(x);
            end
        end

        function D = depthProfile(C, S, metric, groupBy, opts)
            %DEPTHPROFILE  A metric or the cell density against the distance from the surface.
            if nargin < 4, groupBy = ""; end
            if nargin < 5 || isempty(opts), opts = struct(); end
            o = struct('BinUm', 50, 'MaxUm', NaN, 'MinCells', 3, 'MinAreaUm2', 5000, 'MinDepthUm', 0);
            for f = string(fieldnames(opts))'
                if isfield(o, f) && ~isempty(opts.(f)), o.(f) = opts.(f); end
            end
            if ~(isfinite(o.MinDepthUm) && o.MinDepthUm > 0), o.MinDepthUm = 0; end
            step = cellanalysis.Project.DEPTH_STEP_UM;
            o.BinUm = max(step, round(o.BinUm / step) * step);
            metric = string(metric);
            isDensity = metric == "" || lower(metric) == "density";
            D = struct('Edges', [0 o.BinUm], 'Centers', o.BinUm / 2, 'Names', strings(0, 1), 'Mean', zeros(0, 1), ...
                'Sem', zeros(0, 1), 'N', zeros(0, 1), 'Sections', strings(0, 1), 'SectionGroup', zeros(0, 1), ...
                'PerSection', zeros(0, 1), 'IsDensity', isDensity, 'Unit', "");
            if isempty(C) || ~ismember('SurfaceDistUm', C.Properties.VariableNames), return; end
            d = double(C.SurfaceDistUm);
            use = isfinite(d) & ~(d < o.MinDepthUm);
            if isDensity
                if ismember('InAnalysis', C.Properties.VariableNames), use = use & C.InAnalysis; end
                x = ones(height(C), 1);
            else
                if ~ismember(char(metric), C.Properties.VariableNames), return; end
                x = double(C.(char(metric)));
                use = use & isfinite(x);
            end
            if ~any(use), return; end
            if ~isfinite(o.MaxUm) || o.MaxUm <= 0
                o.MaxUm = prctile(d(use), 99);
            end
            nb = max(1, ceil(o.MaxUm / o.BinUm));
            edges = (0:nb) * o.BinUm;
            grp = cellanalysis.Stats.groupOf(C, groupBy);
            src = double(C.SourceRow);
            rows = unique(src(use));
            per = nan(numel(rows), nb);
            secGroup = strings(numel(rows), 1);
            for q = 1:numel(rows)
                m = use & src == rows(q);
                b = discretize(d(m), edges);
                inb = isfinite(b);
                xb = x(m);
                cnt = accumarray(b(inb), 1, [nb 1])';
                if isDensity
                    area = cellanalysis.Stats.areaPerBin(S, rows(q), edges, o.MinDepthUm);
                    val = cnt ./ area * 1e6;
                    val(~(area >= o.MinAreaUm2)) = NaN;
                else
                    val = accumarray(b(inb), xb(inb), [nb 1], @mean, NaN)';
                    val(cnt < o.MinCells) = NaN;
                end
                per(q, :) = val;
                gq = unique(grp(m));
                % a section whose cells fall in several groups (a cell-level grouping) is
                % split: one profile per group of that section
                secGroup(q) = gq(1);
                if numel(gq) > 1, secGroup(q) = "(mixed)"; end
            end
            if any(secGroup == "(mixed)")
                % cell-level grouping: redo per (section, group)
                [per, secGroup, rows] = cellanalysis.Stats.splitByCellGroup(C, S, x, d, use, grp, src, edges, o, isDensity);
            end
            [names, ~, gi] = unique(secGroup);
            k = numel(names);
            Mean = nan(k, nb); Sem = nan(k, nb); N = zeros(k, nb);
            for i = 1:k
                P = per(gi == i, :);
                N(i, :) = sum(isfinite(P), 1);
                Mean(i, :) = mean(P, 1, 'omitnan');
                Sem(i, :) = std(P, 0, 1, 'omitnan') ./ sqrt(max(N(i, :), 1));
                Sem(i, N(i, :) < 2) = NaN;
            end
            D.Edges = edges;
            D.Centers = (edges(1:end - 1) + edges(2:end)) / 2;
            D.Names = names(:);
            D.Mean = Mean; D.Sem = Sem; D.N = N;
            D.Sections = S.Section(rows);
            D.SectionGroup = gi(:);
            D.PerSection = per;
            if isDensity, D.Unit = "cells/mm^2"; end
        end

        function K = colocalization(C, Sec, groupBy)
            %COLOCALIZATION  Colocalization per section and per group (see the class help).
            if nargin < 3, groupBy = ""; end
            if string(groupBy) == "Colocalized", groupBy = ""; end
            blank = table(zeros(0, 1), strings(0, 1), zeros(0, 1), zeros(0, 1), zeros(0, 1), zeros(0, 1), zeros(0, 1), ...
                zeros(0, 1), zeros(0, 1), zeros(0, 1), zeros(0, 1), 'VariableNames', {'SourceRow', 'Group', 'Cells', ...
                'OtherCells', 'Pairs', 'PctThis', 'PctOther', 'PctChance', 'Enrichment', 'ThisPerMm2', 'OtherPerMm2'});
            K = struct('Sections', blank, 'Names', strings(0, 1), 'Group', zeros(0, 1), 'Summary', table());
            if isempty(C) || isempty(Sec) || ~ismember('Colocalized', C.Properties.VariableNames), return; end
            grp = cellanalysis.Stats.groupOf(C, groupBy);
            rows = unique(C.SourceRow, 'stable');
            T = blank;
            for q = 1:numel(rows)
                m = C.SourceRow == rows(q);
                k = find(Sec.SourceRow == rows(q), 1);
                if isempty(k) || strlength(Sec.OtherKey(k)) == 0, continue; end
                n = nnz(m);
                pairs = nnz(C.Colocalized(m) == 1);
                no = Sec.OtherCells(k);
                chance = 100 * mean(C.ColocChance(m), 'omitnan');
                g = unique(grp(m));
                T(end + 1, :) = {rows(q), g(1), n, no, pairs, 100 * pairs / max(n, 1), 100 * pairs / no, chance, ...
                    (100 * pairs / max(n, 1)) / chance, n / Sec.TissueMm2(k), no / Sec.TissueMm2(k)}; %#ok<AGROW>
                if no == 0, T.PctOther(end) = NaN; end
                if ~(chance > 0), T.Enrichment(end) = NaN; end
            end
            if isempty(T), return; end
            [names, ~, gi] = unique(T.Group);
            k = numel(names);
            Group = names(:);
            [Sections, Cells, OtherCells, Pairs, PctThis, SEM, PctOther, SEMOther, PctChance, Enrichment] = deal(nan(k, 1));
            sem = @(x) std(x, 'omitnan') / sqrt(max(nnz(isfinite(x)), 1));
            for i = 1:k
                m = gi == i;
                Sections(i) = nnz(m);
                Cells(i) = sum(T.Cells(m));
                OtherCells(i) = sum(T.OtherCells(m));
                Pairs(i) = sum(T.Pairs(m));
                PctThis(i) = mean(T.PctThis(m), 'omitnan');
                PctOther(i) = mean(T.PctOther(m), 'omitnan');
                PctChance(i) = mean(T.PctChance(m), 'omitnan');
                Enrichment(i) = mean(T.Enrichment(m), 'omitnan');
                if nnz(m) > 1
                    SEM(i) = sem(T.PctThis(m));
                    SEMOther(i) = sem(T.PctOther(m));
                end
            end
            K.Sections = T;
            K.Names = Group;
            K.Group = gi(:);
            K.Summary = table(Group, Sections, Cells, OtherCells, Pairs, PctThis, SEM, PctOther, SEMOther, PctChance, Enrichment);
        end

        function g = groupOf(C, groupBy)
            %GROUPOF  The group name of every row of C ("All" without a grouping).
            groupBy = string(groupBy);
            if strlength(groupBy) == 0 || lower(groupBy) == "none" || ~ismember(char(groupBy), C.Properties.VariableNames)
                g = repmat("All", height(C), 1);
                return
            end
            col = C.(char(groupBy));
            if groupBy == "Colocalized"
                g = repmat("(no other channel)", height(C), 1);
                g(col == 1) = "Colocalized";
                g(col == 0) = "Not colocalized";
                return
            end
            if islogical(col)
                g = repmat("No", height(C), 1);
                g(col) = "Yes";
                return
            end
            g = string(col);
            g(ismissing(g) | strlength(strtrim(g)) == 0) = "(none)";
        end

        function a = areaBeyond(edges, area, minUm)
            %AREABEYOND  The area of each depth bin at minUm or deeper (see the class help).
            a = double(area(:))';
            if nargin < 3 || ~(isscalar(minUm) && isfinite(minUm) && minUm > 0) || isempty(a), return; end
            e = double(edges(:))';
            lo = e(1:end - 1);
            hi = e(2:end);
            share = min(max((hi - minUm) ./ max(hi - lo, eps), 0), 1);
            a = a .* share;
        end

    end

    methods (Static, Access = private)

        function who = whoOf(C, ok, unit)
            %whoOf  The section or subject each of the cells C(ok, :) belongs to (text).
            if unit == "section" && ismember('SourceRow', C.Properties.VariableNames)
                who = string(C.SourceRow(ok));
            elseif unit == "section"
                who = C.Dataset(ok) + "|" + C.Key(ok);
            else
                who = string(C.Subject(ok));
                ds = C.Dataset(ok);
                blank = strlength(who) == 0;
                who(blank) = "(no subject) " + ds(blank);
            end
        end

        function v = perUnit(x, j, metric)
            %perUnit  One value per unit j: the median of its cells (the mean of a 0/1 metric).
            binary = all(x == 0 | x == 1) || any(string(metric) == ["Colocalized" "ColocChance"]);
            if binary
                v = accumarray(j, x, [], @mean);
            else
                v = accumarray(j, x, [], @median);
            end
        end

        function area = areaPerBin(S, row, edges, minUm)
            %areaPerBin  Tissue area (um^2) of a source in each depth bin, from its record; the
            %   tissue closer than minUm to the surface is left out.
            if nargin < 4, minUm = 0; end
            area = nan(1, numel(edges) - 1);
            try
                J = jsondecode(fileread(char(S.JsonPath(row))));
                rec = J.sources.(matlab.lang.makeValidName(char(S.Key(row))));
                e = double(rec.depthEdgesUm(:))';
                a = double(rec.depthAreaUm2(:))';
            catch
                return
            end
            if numel(e) ~= numel(a) + 1 || isempty(a), return; end
            a = cellanalysis.Stats.areaBeyond(e, a, minUm);
            c = (e(1:end - 1) + e(2:end)) / 2;
            b = discretize(c, edges);
            ok = isfinite(b);
            area = accumarray(b(ok)', a(ok)', [numel(edges) - 1, 1])';
        end

        function [per, secGroup, rows] = splitByCellGroup(C, S, x, d, use, grp, src, edges, o, isDensity) %#ok<INUSL>
            nb = numel(edges) - 1;
            [u, ~, j] = unique(string(src(use)) + char(31) + grp(use));
            idx = find(use);
            per = nan(numel(u), nb);
            secGroup = strings(numel(u), 1);
            rows = zeros(numel(u), 1);
            for q = 1:numel(u)
                m = idx(j == q);
                rows(q) = src(m(1));
                secGroup(q) = grp(m(1));
                b = discretize(d(m), edges);
                inb = isfinite(b);
                cnt = accumarray(b(inb), 1, [nb 1])';
                if isDensity
                    area = cellanalysis.Stats.areaPerBin(S, rows(q), edges, o.MinDepthUm);
                    val = cnt ./ area * 1e6;
                    val(~(area >= o.MinAreaUm2)) = NaN;
                else
                    xm = x(m);
                    val = accumarray(b(inb), xm(inb), [nb 1], @mean, NaN)';
                    val(cnt < o.MinCells) = NaN;
                end
                per(q, :) = val;
            end
        end

    end
end

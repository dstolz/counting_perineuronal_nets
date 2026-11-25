classdef Plots
%PLOTS  The distribution plots and the section map of the CellAnalysis window (static).
%   Every function draws into the axes it is given and returns a struct that says what it drew
%   (Kind, Names, N per group, XLabel, YLabel, Note), which is what the tests read.
%
%   P = cellanalysis.Plots.histogram(ax, H, lab)        H: cellanalysis.Stats.histogram
%   P = cellanalysis.Plots.cumulative(ax, E, lab)       E: cellanalysis.Stats.cdf
%   P = cellanalysis.Plots.boxes(ax, v, g, names, lab)  the observations of cellanalysis.Stats.values
%   P = cellanalysis.Plots.depth(ax, D, lab)            D: cellanalysis.Stats.depthProfile
%   P = cellanalysis.Plots.scatter(ax, x, y, g, names, lab)
%   P = cellanalysis.Plots.colocalization(ax, K, lab)   K: cellanalysis.Stats.colocalization;
%                                                       lab.ThisName, lab.OtherName, lab.ChanceNote
%   h = cellanalysis.Plots.map(ax, img, dispScale, Sf, xy, values, lab)   the section map
%
%   lab: struct XLabel, YLabel, Title, AllNames (every group name of the grouping, so a group
%   keeps its color when others are filtered out; default the names drawn), Mark (a value
%   marked by a dashed vertical line in histogram, cumulative and depth, with MarkLabel), and
%   for map ValueLabel, Limits, DepthLines (polylines drawn dashed in the surface's color: the
%   border of the band whose cells are rejected) and Rejected (K x 2 cells drawn as crosses).
%
%   COLOR. Groups take the eight colors of PALETTE in a fixed order (a validated
%   color-blind-safe sequence); they are never cycled: with more than eight groups every group
%   is drawn in one color and the summary table carries the identities. Two or more groups
%   always have a legend. Values on the map use one perceptually ordered color scale.
%
%   See also cellanalysis.Stats, CellAnalysis.

    properties (Constant)
        PALETTE = [42 120 214; 235 104 52; 27 175 122; 237 161 0; 232 123 164; 0 131 0; 98 80 214; 227 73 72] / 255
        MAX_GROUPS = 8
        INK = [0.13 0.13 0.13]
        MUTED = [0.42 0.42 0.42]
        GRID = [0.88 0.88 0.88]
        ONE = [42 120 214] / 255
        SURFACE = [1 0.35 0.25]          % the surface line on the map
        OTHER_EDGE = [0.35 0.75 1]       % empty areas that are not surface
    end

    methods (Static)

        function C = colors(names, allNames)
            %COLORS  One color per name: its slot in allNames (sorted), one color for all when
            %   there are more than MAX_GROUPS names in allNames.
            names = string(names(:));
            if nargin < 2 || isempty(allNames), allNames = names; end
            allNames = unique(string(allNames(:)));
            P = cellanalysis.Plots;
            C = repmat(P.ONE, numel(names), 1);
            if numel(allNames) > P.MAX_GROUPS || numel(allNames) < 2, return; end
            [~, slot] = ismember(names, allNames);
            slot(slot == 0) = 1;
            C = P.PALETTE(slot, :);
        end

        function P = histogram(ax, H, lab)
            %HISTOGRAM  One group: bars of counts. Several: outlines of each group's share.
            cellanalysis.Plots.prepare(ax);
            k = numel(H.Names);
            C = cellanalysis.Plots.colors(H.Names, cellanalysis.Plots.allNames(lab, H.Names));
            many = k > cellanalysis.Plots.MAX_GROUPS;
            if k <= 1
                y = H.Counts(1, :);
                if isempty(y), y = zeros(1, numel(H.Centers)); end
                bar(ax, H.Centers, y, 1, 'FaceColor', C(1, :), 'EdgeColor', 'w', 'LineWidth', 0.75);
                ylab = "Cells";
            else
                for i = 1:k
                    y = H.Share(i, :);
                    lw = 2; if many, lw = 0.75; end
                    stairs(ax, [H.Edges, H.Edges(end)], [y, y(end), 0], 'Color', C(i, :), 'LineWidth', lw, ...
                        'DisplayName', char(cellanalysis.Plots.legendName(H.Names(i), H.N(i))));
                end
                ylab = "Share of each group";
            end
            if isfield(lab, 'YUnit') && strlength(string(lab.YUnit)) > 0, ylab = replace(ylab, "Cells", string(lab.YUnit)); end
            cellanalysis.Plots.mark(ax, lab);
            cellanalysis.Plots.finish(ax, lab, lab.XLabel, ylab, k, many);
            P = struct('Kind', "histogram", 'Names', H.Names, 'N', H.N, 'XLabel', string(lab.XLabel), ...
                'YLabel', ylab, 'Note', cellanalysis.Plots.note(k));
        end

        function P = cumulative(ax, E, lab)
            %CUMULATIVE  Empirical cumulative distribution of each group.
            cellanalysis.Plots.prepare(ax);
            k = numel(E.Names);
            C = cellanalysis.Plots.colors(E.Names, cellanalysis.Plots.allNames(lab, E.Names));
            many = k > cellanalysis.Plots.MAX_GROUPS;
            for i = 1:k
                if isempty(E.X{i}), continue; end
                lw = 2; if many, lw = 0.75; end
                stairs(ax, [E.X{i}(1); E.X{i}], [0; E.F{i}], 'Color', C(i, :), 'LineWidth', lw, ...
                    'DisplayName', char(cellanalysis.Plots.legendName(E.Names(i), E.N(i))));
            end
            ylim(ax, [0 1]);
            cellanalysis.Plots.mark(ax, lab);
            cellanalysis.Plots.finish(ax, lab, lab.XLabel, "Cumulative share", k, many);
            P = struct('Kind', "cumulative", 'Names', E.Names, 'N', E.N, 'XLabel', string(lab.XLabel), ...
                'YLabel', "Cumulative share", 'Note', cellanalysis.Plots.note(k));
        end

        function P = boxes(ax, v, g, names, lab)
            %BOXES  A box per group (median, quartiles, whiskers to 1.5 IQR); the observations
            %   themselves are drawn on top when there are at most 400 of them.
            cellanalysis.Plots.prepare(ax);
            k = numel(names);
            C = cellanalysis.Plots.colors(names, cellanalysis.Plots.allNames(lab, names));
            N = zeros(k, 1);
            showPoints = numel(v) <= 400;
            for i = 1:k
                x = v(g == i);
                N(i) = numel(x);
                if isempty(x), continue; end
                b = boxchart(ax, repmat(i, numel(x), 1), x, 'BoxFaceColor', C(i, :), 'BoxFaceAlpha', 0.25, ...
                    'WhiskerLineColor', C(i, :), 'LineWidth', 1.25, 'BoxWidth', 0.5, 'MarkerStyle', '.', ...
                    'MarkerColor', C(i, :), 'HandleVisibility', 'off');
                if showPoints
                    b.MarkerStyle = 'none';
                    jit = (mod((1:numel(x))' * 0.6180339887, 1) - 0.5) * 0.3;
                    scatter(ax, i + jit, x, 22, C(i, :), 'filled', 'MarkerFaceAlpha', 0.75, ...
                        'MarkerEdgeColor', 'w', 'LineWidth', 0.5, 'HandleVisibility', 'off');
                end
            end
            xlim(ax, [0.4, max(k, 1) + 0.6]);
            xticks(ax, 1:k);
            xticklabels(ax, cellstr(names + " (" + N + ")"));
            if k > 6, xtickangle(ax, 35); else, xtickangle(ax, 0); end
            cellanalysis.Plots.finish(ax, lab, "", lab.YLabel, 1, false);
            P = struct('Kind', "box", 'Names', names, 'N', N, 'XLabel', "", 'YLabel', string(lab.YLabel), ...
                'Note', "");
        end

        function P = depth(ax, D, lab)
            %DEPTH  Mean of the sections of each group against the distance from the surface,
            %   with a band of +-1 SEM where a group has two or more sections.
            cellanalysis.Plots.prepare(ax);
            k = numel(D.Names);
            C = cellanalysis.Plots.colors(D.Names, cellanalysis.Plots.allNames(lab, D.Names));
            many = k > cellanalysis.Plots.MAX_GROUPS;
            nSec = zeros(k, 1);
            for i = 1:k
                m = D.Mean(i, :); e = D.Sem(i, :);
                nSec(i) = nnz(D.SectionGroup == i);
                ok = isfinite(m);
                if ~any(ok), continue; end
                be = ok & isfinite(e);
                if any(be) && ~many
                    xs = D.Centers(be);
                    fill(ax, [xs, fliplr(xs)], [m(be) - e(be), fliplr(m(be) + e(be))], C(i, :), ...
                        'FaceAlpha', 0.18, 'EdgeColor', 'none', 'HandleVisibility', 'off');
                end
                lw = 2; if many, lw = 0.75; end
                plot(ax, D.Centers(ok), m(ok), '-', 'Color', C(i, :), 'LineWidth', lw, ...
                    'DisplayName', sprintf('%s (%d section%s)', D.Names(i), nSec(i), char(repmat('s', 1, nSec(i) ~= 1))));
            end
            xlim(ax, [0, max(D.Edges(end), 1)]);
            cellanalysis.Plots.mark(ax, lab);
            cellanalysis.Plots.finish(ax, lab, "Distance from brain surface (um)", lab.YLabel, k, many);
            P = struct('Kind', "depth", 'Names', D.Names, 'N', nSec, 'XLabel', "Distance from brain surface (um)", ...
                'YLabel', string(lab.YLabel), 'Note', cellanalysis.Plots.note(k));
        end

        function P = scatter(ax, x, y, g, names, lab)
            %SCATTER  One metric against another; at most 20000 points are drawn (a regular
            %   subsample), the correlation in the title is of all of them.
            cellanalysis.Plots.prepare(ax);
            k = numel(names);
            C = cellanalysis.Plots.colors(names, cellanalysis.Plots.allNames(lab, names));
            many = k > cellanalysis.Plots.MAX_GROUPS;
            ok = isfinite(x) & isfinite(y);
            x = x(ok); y = y(ok); g = g(ok);
            n = numel(x);
            step = max(1, ceil(n / 20000));
            N = zeros(k, 1);
            for i = 1:k
                m = find(g == i);
                N(i) = numel(m);
                m = m(1:step:end);
                if isempty(m), continue; end
                scatter(ax, x(m), y(m), 14, C(i, :), 'filled', 'MarkerFaceAlpha', 0.45, ...
                    'DisplayName', char(cellanalysis.Plots.legendName(names(i), N(i))));
            end
            rho = NaN;
            if n >= 3
                rho = corr(x, y, 'Type', 'Spearman');
            end
            lab.Title = sprintf('%s   (Spearman r = %.2f, n = %d)', lab.Title, rho, n);
            cellanalysis.Plots.finish(ax, lab, lab.XLabel, lab.YLabel, k, many);
            P = struct('Kind', "scatter", 'Names', names, 'N', N, 'XLabel', string(lab.XLabel), ...
                'YLabel', string(lab.YLabel), 'Note', cellanalysis.Plots.note(k), 'Rho', rho);
        end

        function P = colocalization(ax, K, lab)
            %COLOCALIZATION  Per group: the share of the analyzed cells that are paired with a cell
            %   of the other channel, and the share of the other channel's cells that are paired
            %   with one of these. Bars are the mean of the sections, dots the sections, and a
            %   gray line the share that chance alone would give (the first measure).
            Pl = cellanalysis.Plots;
            Pl.prepare(ax);
            T = K.Sections;
            k = numel(K.Names);
            this = "these cells"; other = "the other channel";
            if isfield(lab, 'ThisName'), this = string(lab.ThisName); end
            if isfield(lab, 'OtherName'), other = string(lab.OtherName); end
            series = {T.PctThis, T.PctOther};
            names = [this + " with " + other, other + " with " + this];
            off = [-0.19 0.19];
            for j = 1:2
                mu = nan(k, 1);
                for i = 1:k, mu(i) = mean(series{j}(K.Group == i), 'omitnan'); end
                bar(ax, (1:k)' + off(j), mu, 0.34, 'FaceColor', Pl.PALETTE(j, :), 'FaceAlpha', 0.35, ...
                    'EdgeColor', Pl.PALETTE(j, :), 'LineWidth', 1.25, 'DisplayName', char(names(j)));
                if height(T) <= 400
                    jit = (mod((1:height(T))' * 0.6180339887, 1) - 0.5) * 0.2;
                    scatter(ax, K.Group + off(j) + jit, series{j}, 26, Pl.PALETTE(j, :), 'filled', ...
                        'MarkerEdgeColor', 'w', 'LineWidth', 0.5, 'HandleVisibility', 'off');
                end
            end
            shown = false;
            for i = 1:k
                c = mean(T.PctChance(K.Group == i), 'omitnan');
                if ~isfinite(c), continue; end
                h = plot(ax, i + off(1) + [-0.17 0.17], [c c], '-', 'Color', Pl.MUTED, 'LineWidth', 2, 'HandleVisibility', 'off');
                if ~shown
                    h.HandleVisibility = 'on';
                    note = "by chance";
                    if isfield(lab, 'ChanceNote'), note = string(lab.ChanceNote); end
                    h.DisplayName = char(this + " " + note);
                    shown = true;
                end
            end
            nSec = accumarray(K.Group, 1, [k 1]);
            xlim(ax, [0.4, max(k, 1) + 0.6]);
            ylim(ax, [0 100]);
            xticks(ax, 1:k);
            xticklabels(ax, cellstr(K.Names + " (" + nSec + ")"));
            if k > 6, xtickangle(ax, 35); else, xtickangle(ax, 0); end
            Pl.finish(ax, lab, "", "Colocalized (% of the cells)", 2, false);
            P = struct('Kind', "colocalization", 'Names', K.Names, 'N', nSec, 'XLabel', "", ...
                'YLabel', "Colocalized (% of the cells)", 'Note', "", 'Series', names);
        end

        function P = message(ax, txt)
            %MESSAGE  An empty plot that says why it is empty.
            cla(ax, 'reset');
            ax.Visible = 'off';
            text(ax, 0.5, 0.5, char(txt), 'Units', 'normalized', 'HorizontalAlignment', 'center', ...
                'Color', cellanalysis.Plots.MUTED, 'FontSize', 13, 'Interpreter', 'none');
            P = struct('Kind', "message", 'Names', strings(0, 1), 'N', zeros(0, 1), 'XLabel', "", 'YLabel', "", ...
                'Note', string(txt));
        end

        function h = map(ax, img, scale, Sf, xy, values, lab)
            %MAP  The section with its surface and its cells.
            %   img: the display image (gray, 0..1), SCALE display pixels per full-resolution
            %   pixel; Sf: cellanalysis.Surface struct ([] = none); xy: N x 2 cells (full-res
            %   pixels); values: N x 1 metric for the color ([] or all NaN = one color).
            %   lab.DepthLines, lab.Rejected: see the class help.
            %   h: struct Image, Cells, Surface (line handles), Other, Depth, Rejected, Colorbar.
            cla(ax, 'reset');
            hold(ax, 'on');
            h = struct('Image', [], 'Cells', [], 'Surface', gobjects(0), 'Other', gobjects(0), 'Depth', gobjects(0), ...
                'Rejected', [], 'Colorbar', []);
            h.Image = image(ax, 'XData', [1 size(img, 2)], 'YData', [1 size(img, 1)], ...
                'CData', repmat(img, 1, 1, 3));
            axis(ax, 'image');
            ax.YDir = 'reverse';
            ax.XTick = []; ax.YTick = [];
            ax.Box = 'on';
            toDisp = @(p) (p - 0.5) * scale + 0.5;
            if ~isempty(Sf)
                for i = 1:numel(Sf.OtherLines)
                    p = toDisp(Sf.OtherLines{i});
                    h.Other(end + 1) = plot(ax, p(:, 1), p(:, 2), ':', 'Color', cellanalysis.Plots.OTHER_EDGE, ...
                        'LineWidth', 1.25, 'HitTest', 'off', 'PickableParts', 'none');
                end
                for i = 1:numel(Sf.Lines)
                    p = toDisp(Sf.Lines{i});
                    h.Surface(end + 1) = plot(ax, p(:, 1), p(:, 2), '-', 'Color', cellanalysis.Plots.SURFACE, ...
                        'LineWidth', 2, 'HitTest', 'off', 'PickableParts', 'none');
                end
            end
            if isfield(lab, 'DepthLines')
                for i = 1:numel(lab.DepthLines)
                    p = toDisp(lab.DepthLines{i});
                    h.Depth(end + 1) = plot(ax, p(:, 1), p(:, 2), '--', 'Color', cellanalysis.Plots.SURFACE, ...
                        'LineWidth', 1.25, 'HitTest', 'off', 'PickableParts', 'none');
                end
            end
            if isfield(lab, 'Rejected') && ~isempty(lab.Rejected)
                p = toDisp(lab.Rejected);
                h.Rejected = scatter(ax, p(:, 1), p(:, 2), 30, cellanalysis.Plots.SURFACE, 'x', 'LineWidth', 1.1, ...
                    'HitTest', 'off', 'PickableParts', 'none');
            end
            if ~isempty(xy)
                p = toDisp(xy);
                values = double(values(:));
                if isempty(values) || ~any(isfinite(values))
                    h.Cells = scatter(ax, p(:, 1), p(:, 2), 16, [1 0.85 0.2], 'filled', ...
                        'MarkerEdgeColor', [0 0 0], 'LineWidth', 0.4, 'HitTest', 'off', 'PickableParts', 'none');
                else
                    lim = prctile(values(isfinite(values)), [2 98]);
                    if isfield(lab, 'Limits') && numel(lab.Limits) == 2 && lab.Limits(2) > lab.Limits(1)
                        lim = lab.Limits;
                    end
                    if ~(lim(2) > lim(1)), lim = lim(1) + [-0.5 0.5]; end
                    miss = ~isfinite(values);
                    if any(miss)
                        scatter(ax, p(miss, 1), p(miss, 2), 10, [0.6 0.6 0.6], 'HitTest', 'off', 'PickableParts', 'none');
                    end
                    h.Cells = scatter(ax, p(~miss, 1), p(~miss, 2), 18, values(~miss), 'filled', ...
                        'MarkerEdgeColor', [0 0 0], 'LineWidth', 0.4, 'HitTest', 'off', 'PickableParts', 'none');
                    colormap(ax, cellanalysis.Plots.scaleMap());
                    clim(ax, lim);
                    h.Colorbar = colorbar(ax);
                    h.Colorbar.Label.String = char(lab.ValueLabel);
                end
            end
            hold(ax, 'off');
            if isfield(lab, 'Title'), title(ax, char(lab.Title), 'Interpreter', 'none', 'FontWeight', 'normal'); end
        end

        function m = scaleMap()
            %SCALEMAP  The color scale of the map: dark violet to yellow, lightness rising all
            %   the way (readable on a gray micrograph and without color).
            a = [68 1 84; 59 82 139; 33 145 140; 94 201 98; 253 231 37] / 255;
            m = interp1(linspace(0, 1, size(a, 1)), a, linspace(0, 1, 256));
        end

    end

    methods (Static, Access = private)

        function prepare(ax)
            cla(ax, 'reset');
            ax.Visible = 'on';
            hold(ax, 'on');
        end

        function finish(ax, lab, xl, yl, k, many)
            P = cellanalysis.Plots;
            hold(ax, 'off');
            ax.Box = 'off';
            ax.TickDir = 'out';
            ax.XColor = P.INK; ax.YColor = P.INK;
            ax.GridColor = P.GRID; ax.GridAlpha = 1;
            ax.YGrid = 'on'; ax.XGrid = 'off';
            ax.Layer = 'bottom';
            ax.FontSize = 11;
            xlabel(ax, char(xl), 'Interpreter', 'none');
            ylabel(ax, char(yl), 'Interpreter', 'none');
            ttl = "";
            if isfield(lab, 'Title'), ttl = string(lab.Title); end
            if many
                ttl = ttl + sprintf("   (%d groups: too many to tell apart by color, see the table)", k);
            end
            title(ax, char(ttl), 'Interpreter', 'none', 'FontWeight', 'normal', 'FontSize', 12);
            legend(ax, 'off');
            if k >= 2 && ~many
                lg = legend(ax, 'Location', 'best', 'Interpreter', 'none', 'Box', 'off');
                lg.TextColor = P.INK;
            end
        end

        function mark(ax, lab)
            %mark  A dashed vertical line at lab.Mark (e.g. the colocalization distance).
            if ~isfield(lab, 'Mark') || isempty(lab.Mark) || ~isfinite(lab.Mark), return; end
            h = xline(ax, lab.Mark, '--', 'Color', cellanalysis.Plots.MUTED, 'LineWidth', 1.25, 'HandleVisibility', 'off');
            if isfield(lab, 'MarkLabel')
                h.Label = char(lab.MarkLabel);
                h.LabelOrientation = 'horizontal';
                h.FontSize = 10;
            end
        end

        function n = allNames(lab, names)
            n = names;
            if isfield(lab, 'AllNames') && ~isempty(lab.AllNames), n = lab.AllNames; end
        end

        function s = legendName(name, n)
            s = sprintf('%s (n = %d)', name, n);
        end

        function t = note(k)
            t = "";
            if k > cellanalysis.Plots.MAX_GROUPS
                t = sprintf("%d groups are drawn in one color.", k);
            end
        end

    end
end

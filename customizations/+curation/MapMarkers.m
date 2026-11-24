classdef MapMarkers
    %MAPMARKERS  How the points of the section map and the locator look: a colour and a symbol per
    %   cell state (static; no window code). The reviewer chooses them in curation.MarkerDialog
    %   (CellCurator: Markers... on the map's tool bar); CellCurator keeps them in its settings.
    %
    %   S = curation.MapMarkers.defaults()
    %       struct with one field per CLASSES entry (Unreviewed, Good, Bad, Uncertain, Flagged), each
    %       a struct Color (1 x 3, 0-255), Symbol (a SYMBOLS code: 'o', 's', 'd', ...) and Filled
    %       (logical; ignored for the line symbols + x *). Colours from curation.UiText.colors;
    %       labelled and flagged cells are open circles (the cell stays visible inside), cells to
    %       review are filled blue squares.
    %   S = curation.MapMarkers.validate(S)
    %       S with every missing or invalid part replaced by its default (settings of an older
    %       version, a hand-edited preference).
    %   [styles, layerOf] = curation.MapMarkers.layerStyles(S)
    %       the distinct styles (struct array Marker, Filled: curation.MapView.setMarkerStyles) and,
    %       per CLASSES entry, the index of its style. Classes that look alike share one scatter, so a
    %       relabel between them is only a colour change.
    %   [rgb, cls] = curation.MapMarkers.forCells(S, label, labelSource, flag, excluded, auditRole)
    %       per cell its colour (N x 3, 0-255) and class (index into CLASSES): Good, Bad,
    %       Uncertain; to review (also an audit tile waiting for its blind judgement, whatever label
    %       it had); a flag wins over the label. Excluded cells keep their symbol and DimFactor of
    %       their colour (curation.UiText.colors).
    %   g = curation.MapMarkers.glyph(symbol, filled)   the character a legend shows for a style
    %   img = curation.MapMarkers.swatch(s, bg, px)     a PX x PX x 3 uint8 picture of marker S (Symbol,
    %                                                   Filled, Color) on background BG (0-255):
    %                                                   the legend and the markers window (uiimage)
    %   tf = curation.MapMarkers.isLineSymbol(symbol)   + x * (no face to fill)
    %
    %   See also curation.MarkerDialog, curation.MapView, CellCurator.

    properties (Constant)
        CLASSES = ["Unreviewed" "Good" "Bad" "Uncertain" "Flagged"]   % layer order: later on top
        % code, name, glyph filled, glyph open
        SYMBOLS = { ...
            'o', 'circle',         char(11044), char(9711)      % the large circles: ● ○ draw small
            's', 'square',         char(9632),  char(9633)
            'd', 'diamond',        char(9670),  char(9671)
            '^', 'triangle up',    char(9650),  char(9651)
            'v', 'triangle down',  char(9660),  char(9661)
            '>', 'triangle right', char(9654),  char(9655)
            '<', 'triangle left',  char(9664),  char(9665)
            'p', 'star',           char(9733),  char(9734)
            'h', 'six-point star', char(10038), char(10017)
            '+', 'plus',           '+',         '+'
            'x', 'cross',          char(215),   char(215)
            '*', 'asterisk',       char(10035), char(10035)}
        LINE_SYMBOLS = '+x*'
    end

    methods (Static)
        function S = defaults()
            C = curation.UiText.colors();
            ring = @(c) struct('Color', c, 'Symbol', 'o', 'Filled', false);
            S = struct();
            S.Unreviewed = struct('Color', C.Unreviewed, 'Symbol', 's', 'Filled', true);
            S.Good = ring(C.Good);
            S.Bad = ring(C.Bad);
            S.Uncertain = ring(C.Uncertain);
            S.Flagged = ring(C.Flag);
        end

        function S = validate(S)
            D = curation.MapMarkers.defaults();
            if ~isstruct(S) || ~isscalar(S), S = D; return; end
            out = D;
            codes = curation.MapMarkers.SYMBOLS(:, 1);
            for c = curation.MapMarkers.CLASSES
                if ~isfield(S, c) || ~isstruct(S.(c)) || ~isscalar(S.(c)), continue; end
                s = S.(c);
                if isfield(s, 'Color')
                    v = double(s.Color);
                    if isequal(size(v), [1 3]) && all(isfinite(v)) && all(v >= 0 & v <= 255)
                        out.(c).Color = round(v);
                    end
                end
                if isfield(s, 'Symbol') && (ischar(s.Symbol) || isstring(s.Symbol)) && isscalar(string(s.Symbol)) ...
                        && any(strcmp(codes, char(s.Symbol)))
                    out.(c).Symbol = char(s.Symbol);
                end
                if isfield(s, 'Filled') && isscalar(s.Filled) && (islogical(s.Filled) || isnumeric(s.Filled))
                    out.(c).Filled = logical(s.Filled);
                end
            end
            S = out;
        end

        function [styles, layerOf] = layerStyles(S)
            S = curation.MapMarkers.validate(S);
            cls = curation.MapMarkers.CLASSES;
            styles = struct('Marker', {}, 'Filled', {});
            layerOf = zeros(1, numel(cls));
            for k = 1:numel(cls)
                s = S.(cls(k));
                filled = s.Filled && ~curation.MapMarkers.isLineSymbol(s.Symbol);
                j = find(strcmp({styles.Marker}, s.Symbol) & [styles.Filled] == filled, 1);
                if isempty(j)
                    styles(end + 1) = struct('Marker', s.Symbol, 'Filled', filled); %#ok<AGROW>
                    j = numel(styles);
                end
                layerOf(k) = j;
            end
        end

        function [rgb, cls] = forCells(S, lab, src, flg, exc, role)
            C = curation.UiText.colors();
            n = numel(lab);
            cls = ones(n, 1);                                         % Unreviewed
            pend = curation.BlindTiles.roleMask(role) & src ~= "blind";
            cls(lab == "Good" & ~pend) = 2;
            cls(lab == "Bad" & ~pend) = 3;
            cls(lab == "Uncertain" & ~pend) = 4;
            cls(flg ~= "") = 5;
            pal = zeros(numel(curation.MapMarkers.CLASSES), 3);
            for k = 1:size(pal, 1)
                pal(k, :) = S.(curation.MapMarkers.CLASSES(k)).Color;
            end
            rgb = pal(cls, :);
            e = logical(exc(:));
            rgb(e, :) = round(C.DimFactor * rgb(e, :) + (1 - C.DimFactor) * C.Background);
        end

        function g = glyph(symbol, filled)
            k = find(strcmp(curation.MapMarkers.SYMBOLS(:, 1), char(symbol)), 1);
            if isempty(k), k = 1; end
            if filled, g = curation.MapMarkers.SYMBOLS{k, 3}; else, g = curation.MapMarkers.SYMBOLS{k, 4}; end
        end

        function img = swatch(s, bg, px, radiusPx, lineWidthPx)
            %SWATCH  An anti-aliased PX x PX x 3 uint8 picture of marker S (struct Symbol, Filled,
            %   Color 0-255) on background BG (0-255), radius RADIUSPX, outline LINEWIDTHPX: what the
            %   legend and the markers window show (no font: every symbol the same size, as on the map;
            %   a filled marker has a thin dark edge, like the map's).
            if nargin < 3, px = 18; end
            if nargin < 4, radiusPx = 0.36 * px; end
            if nargin < 5, lineWidthPx = 1.5; end
            k = 4;                                          % supersampling
            n = px * k;
            [x, y] = meshgrid(((1:n) - 0.5) / k - px / 2);
            x = x / radiusPx;
            y = -y / radiusPx;                              % y up, as the shapes are written
            sym = char(s.Symbol);
            line = curation.MapMarkers.isLineSymbol(sym);
            filled = logical(s.Filled) && ~line;
            w = lineWidthPx / radiusPx;                     % line width in shape units
            if line
                segs = curation.MapMarkers.segments(sym);
                d = curation.MapMarkers.distToSegments(x, y, segs);
                fg = d <= w / 2 + 0.1 / radiusPx;           % the strokes a little bolder than a ring
                edge = false(size(fg));
            else
                P = curation.MapMarkers.polygon(sym);
                in = inpolygon(x, y, P(:, 1), P(:, 2));
                d = curation.MapMarkers.distToSegments(x, y, [P, circshift(P, -1)]);
                if filled
                    edge = d <= 0.6 / radiusPx;             % a dark band about 1 px wide on the outline
                    fg = in & ~edge;
                else
                    fg = d <= w / 2;
                    edge = false(size(fg));
                end
            end
            down = @(m) squeeze(mean(mean(reshape(double(m), k, px, k, px), 1), 3));
            a = down(fg);
            e = down(edge);
            img = zeros(px, px, 3);
            for c = 1:3
                img(:, :, c) = bg(c) * (1 - a - e) + s.Color(c) * a;   % the edge is black
            end
            img = uint8(round(min(max(img, 0), 255)));
        end

        function tf = isLineSymbol(symbol)
            tf = any(curation.MapMarkers.LINE_SYMBOLS == char(symbol));
        end
    end

    methods (Static, Access = private)
        function P = polygon(sym)
            %POLYGON  Outline (M x 2, y up, radius about 1) of a filled-able symbol, as MATLAB draws it.
            star = @(m, rin) curation.MapMarkers.star(m, rin);
            switch sym
                case 's', P = 0.8 * [-1 -1; 1 -1; 1 1; -1 1];
                case 'd', P = [0 1; 0.75 0; 0 -1; -0.75 0];
                case '^', P = [0 1; 0.95 -0.6; -0.95 -0.6];
                case 'v', P = [0 -1; 0.95 0.6; -0.95 0.6];
                case '>', P = [1 0; -0.6 0.95; -0.6 -0.95];
                case '<', P = [-1 0; 0.6 0.95; 0.6 -0.95];
                case 'p', P = star(5, 0.4);
                case 'h', P = star(6, 0.55);
                otherwise
                    t = linspace(0, 2 * pi, 49)';
                    P = [cos(t(1:end - 1)), sin(t(1:end - 1))];
            end
        end

        function P = star(m, rin)
            t = pi / 2 + (0:2 * m - 1)' * pi / m;
            r = repmat([1; rin], m, 1);
            P = [r .* cos(t), r .* sin(t)];
        end

        function S = segments(sym)
            %SEGMENTS  The strokes [x1 y1 x2 y2] of a line symbol (+ x *).
            plus = [-1 0 1 0; 0 -1 0 1];
            c = 0.75;
            cross = [-c -c c c; -c c c -c];
            switch sym
                case '+', S = plus;
                case 'x', S = cross;
                otherwise, S = [plus; cross];
            end
        end

        function d = distToSegments(x, y, S)
            %DISTTOSEGMENTS  Distance of every point (x, y) to the nearest segment of S (K x 4).
            d = inf(size(x));
            for i = 1:size(S, 1)
                ax = S(i, 1); ay = S(i, 2);
                vx = S(i, 3) - ax; vy = S(i, 4) - ay;
                L2 = vx^2 + vy^2;
                t = min(1, max(0, ((x - ax) * vx + (y - ay) * vy) / max(L2, eps)));
                d = min(d, hypot(x - ax - t * vx, y - ay - t * vy));
            end
        end
    end
end

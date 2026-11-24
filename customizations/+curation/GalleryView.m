classdef GalleryView < handle
    %GalleryView  A page of crop tiles drawn as ONE image object whose CData is replaced in place.
    %
    %   g = curation.GalleryView(parent, Name=Value)
    %       parent: a uigridlayout or uipanel of a uifigure. The view adds one borderless uipanel to it
    %       (g.Panel; set g.Panel.Layout to place it in a grid) holding one axes, one image, one line
    %       for the cursor and one line for the multi-selection. Nothing else is ever created: no cla,
    %       no per-tile objects, no new axes.
    %     Options
    %       TilePx          tile side used by capacity() before a cache is set (default 80)
    %       Zoom            screen pixels per mosaic pixel (default 1: pixel-exact, no resampling)
    %       Background      panel colour, [r g b] 0-1 (default [0.09 0.09 0.09])
    %       MaxPixels       largest mosaic capacity() offers, in pixels (default 1.5e6)
    %       MaxTiles        largest page capacity() offers (default Inf)
    %       AxesKind        "axes" (default) or "uiaxes"
    %       Interpolation   image interpolation, "nearest" (default) or "bilinear" (used when Zoom ~= 1)
    %       CursorColor, SelectionColor   [r g b] 0-1
    %
    %   g.setCache(cropCache)
    %   [nRows, nCols] = g.capacity()        tiles that fit the panel at the current size and zoom (for
    %                                         the current style's Mode and Gap); also the grid of pages
    %   [nRows, nCols] = g.capacity(style)    the same for another style (e.g. Mode "side")
    %   g.setGrid(nRows, nCols)               use a fixed page grid instead
    %   g.showPage(ids, style)                full page swap (uses the prefetched mosaic when it matches)
    %   g.prefetch(ids, style)                compose the next page ahead of time
    %   g.updateTiles(tileIdx, style)         restyle some tiles of the shown page (STYLE is the whole
    %                                         page's style; see curation.CropCache.compose)
    %   g.setCursor(k), g.setSelection(ks), g.setZoom(scale)
    %   k = g.hitTest([x y])                  tile under mosaic point [x y] (axes data units), 0 if none
    %   k = g.hitTest([x y], "figure")        the same for a point in figure pixels (fig.CurrentPoint)
    %
    %   The view never calls drawnow (FlushMode "none"): a callback's graphics are flushed when it
    %   returns. Set FlushMode to "drawnow" or "limitrate" to flush inside showPage/updateTiles.
    %
    %   Mouse events: the owning app keeps the figure's WindowButtonDown/Motion/UpFcn and routes them:
    %       consumed = g.onButtonDown(evt); consumed = g.onMotion(evt); consumed = g.onButtonUp(evt)
    %   CONSUMED is true when the event belongs to the gallery (the pointer is over its panel, or a drag
    %   started there). EVT is the figure's event data (the point is read from fig.CurrentPoint) or, for
    %   tests, a struct with AxesPoint ([x y] mosaic units) or FigurePoint ([x y] figure pixels) and
    %   optionally SelectionType and Modifier. g.installRouting() routes the figure's mouse callbacks to
    %   this view alone (for tests and standalone use).
    %   The view reports through function-handle properties, each called as fcn(g, info):
    %       TileClickFcn   button pressed on a tile
    %       TileDragFcn    while the button is held, each tile newly entered, once (tiles skipped by a
    %                      fast move are delivered in order); info.StartTile is the pressed tile
    %       DragEndFcn     button released after a press on a tile; info.Tiles lists every tile visited
    %       TileHoverFcn   pointer over a new tile (0 = left the tiles), at most every HoverInterval s
    %                      (the last one is always delivered)
    %       CapacityChangedFcn  fcn(g, nRows, nCols) after the panel was resized or zoomed and the
    %                      capacity changed (resizes are debounced by ResizeDebounce s)
    %   info: Tile, Id, SelectionType ('normal' | 'alt' | 'extend' | 'open'), Modifier (string array:
    %   "shift", "control", "alt"), StartTile, Point ([x y] mosaic units), Tiles.
    %
    %   See also curation.CropCache.

    properties (SetAccess = private)
        Panel                         % uipanel holding the axes
        Axes                          % the one axes
        Image                         % the one image (CData = the page mosaic)
        CursorLine                    % outline of the cursor tile
        SelectionLine                 % outlines of the selected tiles (one line, NaN-separated)
        Cache = []                    % curation.CropCache
        Layout = []                   % layout of the shown page (curation.CropCache.compose)
        Mosaic = []                   % CData of the shown page
        Ids = zeros(0, 1, 'uint32')   % ids of the shown page, one per tile
        Style = struct()              % style of the shown page
        Grid = [0 0]                  % [nRows nCols] of pages (set by capacity)
        Cursor = 0                    % cursor tile (0 = none)
        Selection = zeros(1, 0)       % selected tiles
        Zoom = 1
        LastTimings = struct('ComposeMs', NaN, 'Prefetched', false)
    end

    properties
        TileClickFcn = []
        TileDragFcn = []
        DragEndFcn = []
        TileHoverFcn = []
        CapacityChangedFcn = []
        HoverInterval (1,1) double {mustBeNonnegative} = 0.05
        ResizeDebounce (1,1) double {mustBeNonnegative} = 0.15
        MaxPixels (1,1) double {mustBePositive} = 1.5e6
        MaxTiles (1,1) double {mustBePositive} = Inf
        FlushMode (1,1) string {mustBeMember(FlushMode, ["none" "drawnow" "limitrate"])} = "none"
    end

    properties (Access = private)
        Fig
        DefaultTilePx = 80
        Prefetched = []
        Drag = []
        HoverTile = -1
        HoverTime = -Inf              % seconds on Clock of the last hover delivered
        Clock                         % tic of the constructor
        HoverPending = []
        HoverTimer = []
        ResizeTimer = []
        AxesPx = []
        PanelPx = []
        Notified = [0 0]
        Deleting = false
    end

    methods
        function obj = GalleryView(parent, opts)
            arguments
                parent
                opts.TilePx (1,1) double {mustBePositive} = 80
                opts.Zoom (1,1) double {mustBePositive} = 1
                opts.Background (1,3) double = [0.09 0.09 0.09]
                opts.MaxPixels (1,1) double {mustBePositive} = 1.5e6
                opts.MaxTiles (1,1) double {mustBePositive} = Inf
                opts.AxesKind (1,1) string {mustBeMember(opts.AxesKind, ["axes" "uiaxes"])} = "axes"
                opts.Interpolation (1,1) string {mustBeMember(opts.Interpolation, ["nearest" "bilinear"])} = "nearest"
                opts.CursorColor (1,3) double = [1 0.85 0]
                opts.SelectionColor (1,3) double = [0 0.85 1]
            end
            obj.Fig = ancestor(parent, 'figure');
            obj.Clock = tic;
            obj.DefaultTilePx = opts.TilePx;
            obj.Zoom = opts.Zoom;
            obj.MaxPixels = opts.MaxPixels;
            obj.MaxTiles = opts.MaxTiles;

            obj.Panel = uipanel(parent, 'BorderType', 'none', 'BackgroundColor', opts.Background, ...
                'AutoResizeChildren', 'off', 'Tag', 'GalleryView');
            if opts.AxesKind == "uiaxes"
                ax = uiaxes(obj.Panel);
            else
                ax = axes(obj.Panel);
            end
            set(ax, 'Units', 'pixels', 'XLim', [0.5 1.5], 'YLim', [0.5 1.5], 'YDir', 'reverse', ...
                'XTick', [], 'YTick', [], 'XColor', 'none', 'YColor', 'none', 'Color', opts.Background, ...
                'Box', 'off', 'TickLength', [0 0], 'SortMethod', 'childorder', 'NextPlot', 'add', ...
                'XLimMode', 'manual', 'YLimMode', 'manual', 'ZLimMode', 'manual', 'CLimMode', 'manual', ...
                'ALimMode', 'manual', 'HitTest', 'on', 'PickableParts', 'visible', 'Tag', 'GalleryAxes');
            ax.InnerPosition = [1 1 10 10];
            try ax.Toolbar = []; catch; end %#ok<*CTCH>
            try disableDefaultInteractivity(ax); catch; end
            try ax.Interactions = []; catch; end
            obj.Axes = ax;

            obj.Image = image('Parent', ax, 'CData', zeros(1, 1, 3, 'uint8'), 'XData', [1 1], 'YData', [1 1], ...
                'HitTest', 'off', 'PickableParts', 'none', 'Tag', 'GalleryImage');
            try obj.Image.Interpolation = opts.Interpolation; catch; end
            obj.SelectionLine = line(ax, NaN, NaN, 'Color', opts.SelectionColor, 'LineWidth', 2, ...
                'HitTest', 'off', 'PickableParts', 'none', 'Tag', 'GallerySelection');
            obj.CursorLine = line(ax, NaN, NaN, 'Color', opts.CursorColor, 'LineWidth', 2.5, ...
                'HitTest', 'off', 'PickableParts', 'none', 'Tag', 'GalleryCursor');

            obj.Panel.SizeChangedFcn = @(~, ~) obj.onSizeChanged();
            obj.Panel.DeleteFcn = @(~, ~) obj.delete();
        end

        function delete(obj)
            if obj.Deleting; return; end
            obj.Deleting = true;
            obj.killTimer('HoverTimer');
            obj.killTimer('ResizeTimer');
            if ~isempty(obj.Panel) && isvalid(obj.Panel) && strcmp(obj.Panel.BeingDeleted, 'off')
                delete(obj.Panel);
            end
        end

        % ---- content --------------------------------------------------------------------------------
        function setCache(obj, cache)
            %setCache  Use CACHE (a curation.CropCache) for the pages; clears the prefetch.
            if ~isa(cache, 'curation.CropCache')
                error('GalleryView:BadCache', 'setCache needs a curation.CropCache.');
            end
            obj.Cache = cache;
            obj.Prefetched = [];
        end

        function [nRows, nCols] = capacity(obj, style)
            %capacity  Tiles that fit at the current panel size and zoom; sets the page grid.
            if nargin < 2; style = obj.Style; end
            [nRows, nCols] = obj.fit(style);
            obj.Grid = [nRows nCols];
            obj.Notified = obj.Grid;
        end

        function setGrid(obj, nRows, nCols)
            %setGrid  Use an nRows x nCols page grid (until capacity is called again); drops the prefetch.
            obj.Grid = [max(1, round(nRows)) max(1, round(nCols))];
            obj.Prefetched = [];
        end

        function showPage(obj, ids, style)
            %showPage  Show the tiles of IDS (one per tile, row-major) with STYLE.
            if nargin < 3; style = obj.Style; end
            obj.requireCache();
            ids = uint32(ids(:));
            grid = obj.pageGrid(numel(ids), style);
            t0 = tic;
            P = obj.Prefetched;
            obj.Prefetched = [];
            hit = ~isempty(P) && P.Version == obj.Cache.Version && isequal(P.Grid, grid) && ...
                isequal(P.Ids, ids) && isequaln(P.Style, style);    % NaN colours mean "none"
            if hit
                mosaic = P.Mosaic;
                layout = P.Layout;
            else
                [mosaic, layout] = obj.Cache.compose(ids, grid(1), grid(2), style);
            end
            obj.LastTimings = struct('ComposeMs', 1000 * toc(t0), 'Prefetched', hit);
            resized = isempty(obj.Layout) || ~isequal(obj.Layout.Size, layout.Size);
            obj.Mosaic = mosaic;
            obj.Layout = layout;
            obj.Ids = ids;
            obj.Style = style;
            obj.Image.CData = mosaic;
            if resized
                set(obj.Image, 'XData', [1 layout.Size(2)], 'YData', [1 layout.Size(1)]);
                set(obj.Axes, 'XLim', [0.5 layout.Size(2) + 0.5], 'YLim', [0.5 layout.Size(1) + 0.5]);
                obj.placeAxes();
            end
            obj.Drag = [];
            obj.HoverTile = -1;
            if ~isempty(obj.Selection)
                obj.Selection = zeros(1, 0);
                set(obj.SelectionLine, 'XData', NaN, 'YData', NaN);
            end
            obj.Cursor = min(obj.Cursor, layout.K);
            obj.drawCursor();
            obj.flush();
        end

        function prefetch(obj, ids, style)
            %prefetch  Compose the page of IDS with STYLE now, so that showPage(ids, style) only pushes
            %   pixels. One page is kept; it is dropped when the cache or the grid changes.
            if nargin < 3; style = obj.Style; end
            obj.requireCache();
            ids = uint32(ids(:));
            grid = obj.pageGrid(numel(ids), style);
            [mosaic, layout] = obj.Cache.compose(ids, grid(1), grid(2), style);
            obj.Prefetched = struct('Ids', ids, 'Style', style, 'Grid', grid, 'Version', obj.Cache.Version, ...
                'Mosaic', mosaic, 'Layout', layout);
        end

        function updateTiles(obj, tileIdx, style)
            %updateTiles  Redraw tiles TILEIDX of the shown page with STYLE (the page's whole style).
            if isempty(obj.Layout); return; end
            obj.Mosaic = obj.Cache.repaint(obj.Mosaic, obj.Layout, tileIdx, style);
            obj.Style = style;
            obj.Image.CData = obj.Mosaic;
            obj.flush();
        end

        function setCursor(obj, k)
            %setCursor  Outline tile K (0 hides the cursor).
            obj.Cursor = max(0, round(double(k)));
            obj.drawCursor();
        end

        function setSelection(obj, tiles)
            %setSelection  Outline tiles TILES ([] clears).
            tiles = unique(round(double(tiles(:)')));
            if isempty(obj.Layout)
                tiles = zeros(1, 0);
            else
                tiles = tiles(tiles >= 1 & tiles <= obj.Layout.K);
            end
            obj.Selection = tiles;
            if isempty(tiles)
                set(obj.SelectionLine, 'XData', NaN, 'YData', NaN);
                return
            end
            [x, y] = obj.outline(tiles, obj.borderPx() + 4.5);   % inside the cursor's outline
            set(obj.SelectionLine, 'XData', x, 'YData', y);
        end

        function setZoom(obj, scale)
            %setZoom  Show the mosaic at SCALE screen pixels per mosaic pixel (1 = pixel-exact).
            obj.Zoom = scale;
            obj.AxesPx = [];
            obj.placeAxes();
            obj.checkCapacity();
        end

        % ---- geometry ---------------------------------------------------------------------------------
        function idx = hitTest(obj, pt, space)
            %hitTest  Tile under each point (rows of PT, [x y]); 0 outside the tiles.
            %   SPACE "axes" (default): mosaic/axes data units. "figure": figure pixels.
            if nargin > 2 && string(space) == "figure"
                pt = obj.figureToMosaic(pt);
            end
            idx = obj.tileAt(pt(:, 1), pt(:, 2));
        end

        function m = figureToMosaic(obj, fp)
            %figureToMosaic  Figure pixel points (rows [x y]) to mosaic coordinates.
            ap = obj.axesPixels();
            sz = obj.layoutSize();
            sx = ap(3) / sz(2);
            sy = ap(4) / sz(1);
            m = [(fp(:, 1) - ap(1) + 1) / sx + 0.5, (ap(2) + ap(4) - 1 - fp(:, 2)) / sy + 0.5];
        end

        function fp = mosaicToFigure(obj, m)
            %mosaicToFigure  Mosaic points (rows [x y]) to figure pixels (inverse of figureToMosaic).
            ap = obj.axesPixels();
            sz = obj.layoutSize();
            sx = ap(3) / sz(2);
            sy = ap(4) / sz(1);
            fp = [(m(:, 1) - 0.5) * sx + ap(1) - 1, ap(2) + ap(4) - 1 - (m(:, 2) - 0.5) * sy];
        end

        function c = tileCenter(obj, k)
            %tileCenter  Mosaic coordinates [x y] of the centre of tiles K.
            r = obj.Layout.Rect(k(:), :);
            c = [r(:, 1) + (r(:, 3) - 1) / 2, r(:, 2) + (r(:, 4) - 1) / 2];
        end

        % ---- mouse routing ----------------------------------------------------------------------------
        function consumed = onButtonDown(obj, evt)
            %onButtonDown  Route a WindowButtonDown event; true when it belongs to the gallery.
            obj.AxesPx = [];   % the panel may have moved without being resized
            obj.PanelPx = [];
            [pt, inPanel] = obj.eventPoint(evt);
            consumed = inPanel;
            obj.Drag = [];
            if ~inPanel || isempty(obj.Layout); return; end
            k = obj.tileAt(pt(1), pt(2));
            if k == 0; return; end
            [st, mods] = obj.eventKind(evt);
            visited = false(obj.Layout.S, 1);
            visited(k) = true;
            obj.Drag = struct('Start', k, 'Last', pt, 'Visited', visited, 'Order', k, ...
                'SelectionType', st, 'Modifier', mods);
            obj.cancelHover();
            obj.fire(obj.TileClickFcn, obj.info(k, pt, st, mods, k));
        end

        function consumed = onMotion(obj, evt)
            %onMotion  Route a WindowButtonMotion event: drag painting while a press is held, hover otherwise.
            [pt, inPanel] = obj.eventPoint(evt);
            if ~isempty(obj.Drag)
                consumed = true;
                obj.dragTo(pt);
                return
            end
            consumed = inPanel;
            k = 0;
            if inPanel && ~isempty(obj.Layout)
                k = obj.tileAt(pt(1), pt(2));
            end
            if k == obj.HoverTile && isempty(obj.HoverPending); return; end
            obj.hoverTo(k, pt);
        end

        function consumed = onButtonUp(obj, evt)
            %onButtonUp  Route a WindowButtonUp event; ends a drag that started on a tile.
            consumed = ~isempty(obj.Drag);
            if ~consumed; return; end
            pt = obj.eventPoint(evt);
            obj.dragTo(pt);                     % tiles crossed since the last motion event
            if isempty(obj.Drag); return; end   % a drag callback ended the drag
            D = obj.Drag;
            obj.Drag = [];
            in = obj.info(D.Order(end), pt, D.SelectionType, D.Modifier, D.Start);
            in.Tiles = D.Order(:)';
            obj.fire(obj.DragEndFcn, in);
        end

        function installRouting(obj)
            %installRouting  Route the figure's mouse callbacks to this view alone (tests, standalone use).
            f = obj.Fig;
            f.WindowButtonDownFcn = @(~, e) obj.onButtonDown(e);
            f.WindowButtonMotionFcn = @(~, e) obj.onMotion(e);
            f.WindowButtonUpFcn = @(~, e) obj.onButtonUp(e);
        end
    end

    % ------------------------------------------------------------------------------------------------
    methods (Access = private)
        function requireCache(obj)
            if isempty(obj.Cache)
                error('GalleryView:NoCache', 'Call setCache before showing pages.');
            end
        end

        function flush(obj)
            switch obj.FlushMode
                case "drawnow";   drawnow;
                case "limitrate"; drawnow limitrate;
            end
        end

        function grid = pageGrid(obj, K, style)
            grid = obj.Grid;
            if any(grid == 0)
                [r, c] = obj.capacity(style);
                grid = [r c];
            end
            if K > prod(grid)
                grid(1) = ceil(K / grid(2));      % more ids than fit: extra rows (clipped by the panel)
            end
        end

        function [nRows, nCols] = fit(obj, style)
            %fit  Rows and columns of tiles that fit the panel for STYLE's Mode and Gap.
            mode = "target";
            gap = 0;
            if isstruct(style) && isfield(style, 'Mode') && ~isempty(style.Mode); mode = string(style.Mode); end
            if isstruct(style) && isfield(style, 'Gap') && ~isempty(style.Gap); gap = double(style.Gap); end
            if isempty(obj.Cache)
                TH = obj.DefaultTilePx;
                TW = TH * (1 + (mode == "side"));
            else
                [TH, TW] = obj.Cache.tileSize(mode);
            end
            p = obj.panelPixels();
            avail = p(3:4) / obj.Zoom;
            nCols = max(1, floor((avail(1) + gap) / (TW + gap)));
            nRows = max(1, floor((avail(2) + gap) / (TH + gap)));
            while nRows * nCols > 1 && (nRows * nCols * TH * TW > obj.MaxPixels || nRows * nCols > obj.MaxTiles)
                if nCols * TW >= nRows * TH && nCols > 1
                    nCols = nCols - 1;
                else
                    nRows = nRows - 1;
                end
            end
        end

        function sz = layoutSize(obj)
            %layoutSize  [H W] of the shown mosaic ([1 1] before the first page).
            if isempty(obj.Layout)
                sz = [1 1];
            else
                sz = obj.Layout.Size;
            end
        end

        function placeAxes(obj)
            %placeAxes  Centre the mosaic in the panel at Zoom screen pixels per mosaic pixel (top-aligned
            %   when it is taller than the panel).
            p = obj.panelPixels();
            sz = obj.layoutSize() * obj.Zoom;
            w = max(1, round(sz(2)));
            h = max(1, round(sz(1)));
            left = floor(max(0, p(3) - w) / 2) + 1;
            if p(4) >= h
                bottom = floor((p(4) - h) / 2) + 1;
            else
                bottom = p(4) - h + 1;
            end
            pos = [left bottom w h];
            if ~isequal(obj.Axes.InnerPosition, pos)
                obj.Axes.InnerPosition = pos;
            end
            obj.AxesPx = [];
        end

        function p = panelPixels(obj)
            %panelPixels  The panel's position in figure pixels (cached until a resize or a press).
            if isempty(obj.PanelPx)
                obj.PanelPx = getpixelposition(obj.Panel, true);
            end
            p = obj.PanelPx;
        end

        function p = axesPixels(obj)
            %axesPixels  The axes' plot box in figure pixels (cached until a resize, zoom or press).
            if isempty(obj.AxesPx)
                pp = obj.panelPixels();
                ip = obj.Axes.InnerPosition;
                obj.AxesPx = [pp(1) + ip(1) - 1, pp(2) + ip(2) - 1, ip(3), ip(4)];
            end
            p = obj.AxesPx;
        end

        function onSizeChanged(obj)
            if obj.Deleting; return; end
            obj.PanelPx = [];
            obj.AxesPx = [];
            obj.placeAxes();
            if isempty(obj.CapacityChangedFcn); return; end
            if obj.ResizeDebounce <= 0
                obj.checkCapacity();
                return
            end
            if isempty(obj.ResizeTimer) || ~isvalid(obj.ResizeTimer)
                obj.ResizeTimer = timer('ExecutionMode', 'singleShot', 'ObjectVisibility', 'off', ...
                    'Name', 'GalleryView resize', 'TimerFcn', @(~, ~) obj.checkCapacity());
            end
            stop(obj.ResizeTimer);
            obj.ResizeTimer.StartDelay = round(obj.ResizeDebounce, 3);
            start(obj.ResizeTimer);
        end

        function checkCapacity(obj)
            %checkCapacity  Tell the app (CapacityChangedFcn) when the tiles that fit have changed.
            if obj.Deleting || ~isvalid(obj.Panel); return; end
            obj.PanelPx = [];
            [r, c] = obj.fit(obj.Style);
            if isequal([r c], obj.Notified); return; end
            obj.Notified = [r c];
            obj.fire(obj.CapacityChangedFcn, r, c);
        end

        function drawCursor(obj)
            k = obj.Cursor;
            if isempty(obj.Layout) || k < 1 || k > obj.Layout.K
                set(obj.CursorLine, 'XData', NaN, 'YData', NaN);
                return
            end
            [x, y] = obj.outline(k, obj.borderPx() + 1.5);       % just inside the painted label border
            set(obj.CursorLine, 'XData', x, 'YData', y);
        end

        function b = borderPx(obj)
            b = 0;
            if ~isempty(obj.Layout) && isfield(obj.Layout, 'BorderPx'); b = obj.Layout.BorderPx; end
        end

        function [x, y] = outline(obj, tiles, inset)
            %outline  Closed rectangles (NaN-separated) INSET pixels inside the edges of TILES.
            r = obj.Layout.Rect(tiles(:), :);
            x0 = r(:, 1) - 0.5 + inset;
            x1 = r(:, 1) + r(:, 3) - 0.5 - inset;
            y0 = r(:, 2) - 0.5 + inset;
            y1 = r(:, 2) + r(:, 4) - 0.5 - inset;
            nanc = NaN(numel(tiles), 1);
            x = reshape([x0 x1 x1 x0 x0 nanc]', 1, []);
            y = reshape([y0 y0 y1 y1 y0 nanc]', 1, []);
        end

        function k = tileAt(obj, x, y)
            %tileAt  Tile index under mosaic points (x, y) (column vectors); 0 outside the tiles.
            k = zeros(size(x));
            L = obj.Layout;
            if isempty(L); return; end
            sx = L.TileW + L.Gap;
            sy = L.TileH + L.Gap;
            px = x - 0.5;
            py = y - 0.5;
            c = floor(px / sx);
            r = floor(py / sy);
            ok = c >= 0 & c < L.NCols & r >= 0 & r < L.NRows & ...
                px - c * sx < L.TileW & py - r * sy < L.TileH & isfinite(x) & isfinite(y);
            k(ok) = r(ok) * L.NCols + c(ok) + 1;
            k(k > L.K) = 0;
        end

        function dragTo(obj, pt)
            %dragTo  Deliver (TileDragFcn) each tile newly entered on the way from the last point to PT.
            D = obj.Drag;
            ks = obj.tilesAlong(D.Last, pt);
            obj.Drag.Last = pt;
            for k = ks(:)'
                if obj.Drag.Visited(k); continue; end
                obj.Drag.Visited(k) = true;
                obj.Drag.Order(end + 1) = k;
                obj.fire(obj.TileDragFcn, obj.info(k, pt, D.SelectionType, D.Modifier, D.Start));
                if isempty(obj.Drag); return; end    % the callback ended the drag (e.g. a page change)
            end
        end

        function ks = tilesAlong(obj, p0, p1)
            %tilesAlong  Tiles entered along the segment P0 -> P1 (excluding P0's), in order, unique.
            d = p1 - p0;
            len = hypot(d(1), d(2));
            if isempty(obj.Layout) || ~all(isfinite([p0 p1]))
                ks = zeros(1, 0);
                return
            end
            stepLen = max(1, min(obj.Layout.TileW, obj.Layout.TileH) / 4);
            n = max(1, ceil(len / stepLen));
            t = (1:n)' / n;
            k = obj.tileAt(p0(1) + t * d(1), p0(2) + t * d(2));
            k = k(k > 0);
            [~, first] = unique(k, 'stable');
            ks = k(first)';
        end

        function [pt, inPanel] = eventPoint(obj, evt)
            %eventPoint  Mosaic point of a mouse event and whether it is over the gallery's panel.
            if isstruct(evt) && isfield(evt, 'AxesPoint')
                pt = double(evt.AxesPoint(1, 1:2));
                sz = obj.layoutSize();
                inPanel = all(isfinite(pt)) && pt(1) >= 0.5 && pt(1) <= sz(2) + 0.5 && ...
                    pt(2) >= 0.5 && pt(2) <= sz(1) + 0.5;
                return
            end
            if isstruct(evt) && isfield(evt, 'FigurePoint')
                fp = double(evt.FigurePoint(1, 1:2));
            else
                fp = double(obj.Fig.CurrentPoint(1, 1:2));
            end
            p = obj.panelPixels();     % pixel k of a Position spans [k-1, k] in CurrentPoint units
            inPanel = fp(1) >= p(1) - 1 && fp(1) <= p(1) - 1 + p(3) && fp(2) >= p(2) - 1 && fp(2) <= p(2) - 1 + p(4);
            pt = obj.figureToMosaic(fp);
        end

        function [st, mods] = eventKind(obj, evt)
            %eventKind  SelectionType and modifiers of a press (from the struct, else from the figure).
            if isstruct(evt) && isfield(evt, 'SelectionType')
                st = char(evt.SelectionType);
            else
                st = char(obj.Fig.SelectionType);
            end
            mods = strings(1, 0);
            if isstruct(evt) && isfield(evt, 'Modifier')
                mods = string(evt.Modifier);
            elseif isprop(obj.Fig, 'CurrentModifier')
                try mods = string(obj.Fig.CurrentModifier); catch; end
            end
            mods = reshape(mods, 1, []);
        end

        function in = info(obj, k, pt, st, mods, startTile)
            id = uint32(0);
            if k >= 1 && k <= numel(obj.Ids); id = obj.Ids(k); end
            in = struct('Tile', k, 'Id', id, 'SelectionType', st, 'Modifier', mods, ...
                'StartTile', startTile, 'Point', pt, 'Tiles', k);
        end

        function hoverTo(obj, k, pt)
            %hoverTo  Deliver hover tile K now, or at the end of the throttle interval (the latest wins).
            if isempty(obj.TileHoverFcn)
                obj.HoverTile = k;
                return
            end
            wait = obj.HoverInterval - (toc(obj.Clock) - obj.HoverTime);
            if wait <= 0
                obj.HoverPending = [];
                obj.deliverHover(k, pt);
                return
            end
            obj.HoverPending = struct('Tile', k, 'Point', pt);
            if isempty(obj.HoverTimer) || ~isvalid(obj.HoverTimer)
                obj.HoverTimer = timer('ExecutionMode', 'singleShot', 'ObjectVisibility', 'off', ...
                    'Name', 'GalleryView hover', 'TimerFcn', @(~, ~) obj.flushHover());
            end
            if strcmp(obj.HoverTimer.Running, 'off')
                obj.HoverTimer.StartDelay = max(0.001, round(wait, 3));
                start(obj.HoverTimer);
            end
        end

        function flushHover(obj)
            if obj.Deleting || isempty(obj.HoverPending); return; end
            p = obj.HoverPending;
            obj.HoverPending = [];
            if p.Tile ~= obj.HoverTile
                obj.deliverHover(p.Tile, p.Point);
            end
        end

        function deliverHover(obj, k, pt)
            obj.HoverTile = k;
            obj.HoverTime = toc(obj.Clock);
            obj.fire(obj.TileHoverFcn, obj.info(k, pt, '', strings(1, 0), 0));
        end

        function cancelHover(obj)
            obj.HoverPending = [];
            if ~isempty(obj.HoverTimer) && isvalid(obj.HoverTimer); stop(obj.HoverTimer); end
        end

        function fire(obj, fcn, varargin)
            if ~isempty(fcn)
                fcn(obj, varargin{:});
            end
        end

        function killTimer(obj, name)
            t = obj.(name);
            if ~isempty(t) && isvalid(t)
                stop(t);
                delete(t);
            end
            obj.(name) = [];
        end
    end
end

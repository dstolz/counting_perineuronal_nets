classdef MapView < handle
    %MapView  A whole tissue section with every detection as a coloured point: ONE image, ONE scatter.
    %
    %   m = curation.MapView(parent, Name=Value)
    %       parent: a uigridlayout or uipanel of a uifigure. The view adds one borderless uipanel to it
    %       (m.Panel; set m.Panel.Layout to place it in a grid) holding one plain axes (not uiaxes; toolbar
    %       and default interactions off) and a fixed set of graphics objects, all created here and only
    %       updated in place afterwards (no cla, no per-point objects, no new axes):
    %         Image          the page at full resolution as uint8 RGB, pushed once per source and per
    %                        (mode, gain, gamma); zoom and pan change only the axes limits
    %         RegionGroup    ExcludeFill (patch) + ExcludeHatch, AnalysisLine, ReferenceLine (dashed)
    %         SweepLine      outline of the shown sweep field
    %         Points         the scatter of marker layer 1 (all points while there is one marker style);
    %                        markers keep their screen size at every zoom. Layers: one scatter per
    %                        marker style (setMarkerStyles), in PointGroup; Points == Layers(1)
    %         HoverLine      ring on the point a click would hit
    %         SelectionLine  rings on the selected points
    %         DragLine       the point being moved (move tool): its old and new place, joined
    %         LassoLine      the lasso being drawn
    %     Options
    %       Background       panel colour [r g b] 0-1 (default [0.09 0.09 0.09])
    %       MarkerPx         point marker diameter in screen pixels (default 10)
    %       MarkerStyle      "ring" (default: the cell stays visible inside it) or "dot" (filled, dark edge)
    %       MarkerLineWidth  ring line width in points (default 1.5)
    %       Interpolation    "auto" (default: bilinear when zoomed out to >= 1.5 image pixels per screen
    %                        pixel, which softens the aliasing of the whole-section view; nearest at <= 1, so
    %                        single pixels stay sharp when zoomed in; in between the last one is kept, because
    %                        each switch sends the image to the browser again), "nearest", "bilinear"
    %       SelectionColor, HoverColor, DragColor, LassoColor, SweepColor, ExcludeColor, AnalysisColor,
    %       ReferenceColor   [r g b] 0-1
    %       HatchSpacingPx   spacing of the exclusion hatch in image pixels (default 30)
    %
    %   Image (X = column, Y = row, pixel centres at integers, Y axis reversed like an image)
    %     m.setImage(pageT, pageC, limits, umPerPx)   once per source: pageT target page, pageC companion
    %         page ([] = none), limits 2 x 2 [lo hi] (row 1 target, row 2 companion, as CropCache.Limits)
    %         or [] to compute them (page percentiles [1 99.9]). Fits the whole image; setImage(...,
    %         KeepView=true) keeps the view when the size is unchanged (a channel switch).
    %     m.setMode(mode)   "target" | "companion" | "overlay" (target green, companion magenta)
    %     m.setGain(g), m.setGamma(g)   display = min(1, g*v)^gamma on v in [0 1]; scalar or
    %         [target companion]; the same look-up table as curation.CropCache, so map and gallery agree
    %     m.setDisplay(mode, gain, gamma)   the three at once, with one image refresh
    %
    %   Points (ids uint32 N x 1, xy N x 2 [X Y] full-resolution pixels, rgb N x 3 or 1 x 3, 0-255,
    %   layer: the marker style of each point, an index into MarkerStyles, scalar or one per id)
    %     m.setPoints(ids, xy, rgb, layer)   replace all points (clears the selection and the hover);
    %                                    layer default 1
    %     m.updatePoints(ids, rgb, layer)    recolour points in place (and move them to another
    %                                    marker layer when LAYER is given)
    %     m.movePoints(ids, xy), m.addPoints(ids, xy, rgb, layer), m.removePoints(ids)
    %     m.setMarkerStyles(styles)      struct array Marker (a scatter marker: 'o', 's', 'd', '^', 'v',
    %                                    '>', '<', 'p', 'h', '+', 'x', '*') and Filled (logical; filled
    %                                    markers get a thin dark edge; + x * are always lines): one
    %                                    scatter per style, later styles drawn on top. Points of a style
    %                                    that no longer exists go to layer 1. Default: one style, from
    %                                    MarkerStyle
    %     m.setVisible(ids, tf)          tf scalar or one per id; hidden points are not drawn, picked,
    %                                    hovered or lassoed
    %     m.setSelection(ids)            rings on the selected (visible) points; [] clears
    %     m.setMarks(ids)                wider amber rings on points a task is about (a close pair),
    %                                    independent of the selection; [] clears
    %     id = m.pick(xy, maxDistPx)     nearest visible point within maxDistPx image pixels (default the
    %                                    pick radius, PickRadiusPx screen pixels at the current zoom); 0 if none
    %
    %   Regions: m.setRegions(regions)   struct array with fields xy (M x 2 polygon), kind ("exclude" |
    %       "analysis" | "reference") and id. exclude = translucent hatched orange; analysis = thin
    %       outline; reference = thin dashed outline. [] clears.
    %
    %   View
    %     m.fit()                        the whole image
    %     m.centerOn(xy, halfWidthUm)    centre on XY; with halfWidthUm, zoom so that the narrower side of
    %                                    the view spans 2*halfWidthUm (clamped to the image like any view)
    %     r = m.viewRect()               [xmin xmax ymin ymax] of the view (axes limits, image pixels)
    %     m.setViewRect(r)               show rectangle R as large as it fits
    %     m.zoomBy(factor, xy), m.panBy(dxPx, dyPx)   keyboard zoom (factor > 1 zooms in, about XY) and
    %                                    pan (screen pixels; positive moves the image right / up)
    %     Zoom is clamped between the whole image and MinSpanPx image pixels across the narrower side; the
    %     view never leaves the image (along an axis where the view is larger than the image, the image is
    %     centred).
    %
    %   Missed-cell sweep
    %     rects = m.sweepRects(fieldUm, overlapFrac)   fields of fieldUm across (height from the panel's
    %         aspect ratio) tiling the image row by row (serpentine: left to right, then right to left;
    %         Order="raster" for always left to right), neighbours overlapping by at least overlapFrac,
    %         none leaving the image. K x 4 [xmin xmax ymin ymax]; kept in m.SweepRects.
    %     m.showSweepRect(k)             zoom to field k and outline it; k = 0 clears the outline
    %
    %   Tools: m.Tool = "select" | "add" | "move" | "lasso" (the pointer shape over the map shows it)
    %     every tool   wheel zooms about the pointer (ZoomStep per notch); a middle-button drag pans;
    %                  a press on a point reports PointClickFcn
    %     select, add  a left drag that starts on empty space or on a point pans; a left click on empty
    %                  space (inside the image) reports EmptyClickFcn
    %     move         a left drag on a point moves it: the point follows the pointer (PointDragFcn each
    %                  frame) and on release inside the image the view moves it there and reports
    %                  PointDropFcn; Escape (cancelDrag) or a release outside the image snaps it back
    %     lasso        a left drag draws a freehand polygon; on release LassoDoneFcn reports it with the
    %                  visible points inside
    %
    %   Mouse and keys: the owning app keeps the figure's WindowButtonDown/Motion/Up, WindowScrollWheel and
    %   WindowKeyPress callbacks and routes them:
    %       consumed = m.onButtonDown(evt); consumed = m.onMotion(evt); consumed = m.onButtonUp(evt)
    %       consumed = m.onScroll(evt); consumed = m.onKeyPress(evt)   (Escape cancels a drag)
    %   CONSUMED is true when the event belongs to the map (the pointer is over its panel, or a press or
    %   drag started there), so the app can hand the others to the gallery. EVT is the figure's event data
    %   (the point is read from fig.CurrentPoint) or, for tests, a struct with AxesPoint ([x y] image
    %   pixels) or FigurePoint ([x y] figure pixels) and optionally SelectionType, Modifier,
    %   VerticalScrollCount, Key. m.installRouting() routes the figure's callbacks to this view alone.
    %   m.cancelDrag() ends any gesture in progress (a moved point snaps back, a lasso is dropped, a pan
    %   returns to where it started).
    %
    %   Callbacks (function-handle properties, called as fcn(m, info)):
    %       PointClickFcn   Id, XY (the point), PointerXY, SelectionType ('normal' | 'alt' | 'extend' |
    %                       'open'), Modifier (string array), Tool
    %       EmptyClickFcn   XY, SelectionType, Modifier, Tool (only inside the image)
    %       PointDragFcn    Id, XY (where it is now), FromXY
    %       PointDropFcn    Id, FromXY, ToXY (the view has already moved the point)
    %       LassoDoneFcn    Polygon (M x 2), Ids (visible points inside), SelectionType, Modifier
    %       HoverFcn        Id (0 = none), XY; at most every HoverInterval s, the last one always delivered
    %       ViewChangedFcn  Rect (viewRect), Scale (image pixels per screen pixel), IsFit
    %
    %   The view never calls drawnow (FlushMode "none"): a callback's graphics are flushed when it returns.
    %
    %   Layout (a view made or kept inside a hidden container)
    %     The view's geometry (Scale, the pick radius, figure <-> image conversion) follows the panel's
    %     real size. A hidden panel has no real size, and no resize arrives when a hidden ancestor is
    %     shown, so the view re-reads its size itself: when an ancestor uipanel (or the figure) is
    %     shown it re-checks a few times as the layout settles, and every press re-reads it; any public
    %     view call (fit, centerOn, setViewRect, zoomBy, panBy, sweepRects, showSweepRect) and the first
    %     hover or wheel event after a show re-read it too. A changed size keeps the view (a fitted
    %     view stays fitted; else the centre and the scale).
    %     m.refreshLayout()              re-read the panel size now and re-apply the view
    %   Construction while a timer runs: MATLAB processes timer callbacks while it loads a class, and a
    %   view constructed by such a callback while this class is being loaded fails ("... is used in
    %   its own class definition"). curation.MapView.preload() loads the class; call it once before any
    %   timer may construct a view (CellCurator does, in its constructor). Constructing views from a
    %   timer after that is safe, also while another view is being constructed.
    %
    %   Hover from code: m.setHover(id) rings point ID (0 clears) without calling HoverFcn; the next
    %   pointer motion takes the ring over again.
    %
    %   See also curation.GalleryView, curation.CropCache.

    properties (SetAccess = private)
        Panel                           % uipanel holding the axes
        Axes                            % the one axes
        Image                           % the one image
        Points                          % the scatter of marker layer 1 (Layers(1))
        Layers                          % one scatter per marker style
        PointGroup                      % hggroup holding the Layers (keeps them under the rings)
        MarkerStyles = struct('Marker', {'o'}, 'Filled', {false})
        SelectionLine
        MarkLine                        % dashed rings of setMarks (a task's cells)
        HoverLine
        DragLine
        LassoLine
        RegionGroup                     % hggroup of ExcludeFill, ExcludeHatch, AnalysisLine, ReferenceLine
        ExcludeFill
        ExcludeHatch
        AnalysisLine
        ReferenceLine
        SweepLine

        ImageSize = [0 0]               % [H W] of the page
        UmPerPx = 1
        Limits = NaN(2, 2)              % [lo hi] page units; row 1 target, row 2 companion
        HasCompanion = false
        Mode = "target"
        Gain = [1 1]                    % [target companion]
        Gamma = [1 1]

        Ids = zeros(0, 1, 'uint32')     % one row per point
        XY = zeros(0, 2)                % [X Y] of each point
        RGB = zeros(0, 3, 'uint8')      % colour of each point
        Layer = zeros(0, 1)             % marker layer of each point (index into MarkerStyles)
        Shown = false(0, 1)             % visible
        Selection = zeros(0, 1, 'uint32')
        Marks = zeros(0, 1, 'uint32')   % points ringed by setMarks (a task's cells)
        HoverId = uint32(0)
        Regions = struct('xy', {}, 'kind', {}, 'id', {})
        SweepRects = zeros(0, 4)
        SweepIndex = 0

        Center = [1 1]                  % view centre, image pixels
        Scale = 1                       % image pixels per screen pixel
        LastTimings = struct('BuildMs', NaN)
    end

    properties (Dependent)
        Tool                            % "select" | "add" | "move" | "lasso"
        N                               % number of points
        IsFit                           % the view shows the whole image
        Gesture                         % gesture in progress: "" | "pending" | "pan" | "move" | "lasso"
        Interpolation                   % the image's current interpolation
    end

    properties
        PointClickFcn = []
        EmptyClickFcn = []
        PointDragFcn = []
        PointDropFcn = []
        LassoDoneFcn = []
        HoverFcn = []
        ViewChangedFcn = []
        HoverInterval (1,1) double {mustBeNonnegative} = 0.05
        PickRadiusPx (1,1) double {mustBePositive} = 8          % screen pixels
        DragThresholdPx (1,1) double {mustBeNonnegative} = 4     % screen pixels before a press is a drag
        LassoStepPx (1,1) double {mustBeNonnegative} = 2         % screen pixels between lasso vertices
        ZoomStep (1,1) double {mustBeGreaterThan(ZoomStep, 1)} = 1.25
        MinSpanPx (1,1) double {mustBePositive} = 40             % image pixels across at the deepest zoom
        SweepMargin (1,1) double {mustBeNonnegative} = 0.04      % view margin around a sweep field
        FlushMode (1,1) string {mustBeMember(FlushMode, ["none" "drawnow" "limitrate"])} = "none"
    end

    properties (Access = private)
        Fig
        ToolValue = "select"
        XD = zeros(0, 1)                % displayed X (NaN = hidden)
        YD = zeros(0, 1)
        CD = zeros(0, 3)                % colours 0-1
        RowOfId = zeros(0, 1)
        DenseLookup = true
        Pages = {[], []}
        Base = {[], []}                 % uint8 pages at the fixed limits
        DisplayCache = struct('Key', {}, 'RGB', {})
        XL = [0.5 1.5]
        YL = [0.5 1.5]
        PanelPx = []
        Drag = []
        PressedHere = false
        Clock
        HoverTime = -Inf
        HoverPending = []
        HoverTimer = []
        HoverDelivered = uint32(0)
        PointerSet = ""
        FitNow = true                   % the last view applied showed the whole image
        InterpMode = "auto"
        InterpNow = ""
        MarkerPx = 10
        MarkerLineWidth = 1.5
        HatchSpacing = 30
        Deleting = false
        GeomPx = [NaN NaN]              % panel [width height] the view geometry was computed for
        LayoutDirty = true              % the panel may have a new size (made or shown while hidden)
        LayoutTimer = []                % re-checks the size while a shown panel's layout settles
        LayoutChecks = 0                % re-checks left
        Listeners = {}                  % Visible of the ancestors (a show marks the layout dirty)
    end

    properties (Constant, Access = private)
        PtPerPx = 0.75                  % points per screen pixel (96 px per inch)
        MaxDenseId = 1e7
        MaxDisplayCache = 3
    end

    methods
        function obj = MapView(parent, opts)
            arguments
                parent
                opts.Background (1,3) double = [0.09 0.09 0.09]
                opts.MarkerPx (1,1) double {mustBePositive} = 10
                opts.MarkerStyle (1,1) string {mustBeMember(opts.MarkerStyle, ["ring" "dot"])} = "ring"
                opts.MarkerLineWidth (1,1) double {mustBePositive} = 1.5
                opts.Interpolation (1,1) string {mustBeMember(opts.Interpolation, ["auto" "nearest" "bilinear"])} = "auto"
                opts.SelectionColor (1,3) double = [0 0.85 1]
                opts.MarkColor (1,3) double = [1 0.85 0.3]
                opts.HoverColor (1,3) double = [1 1 1]
                opts.DragColor (1,3) double = [1 0.85 0]
                opts.LassoColor (1,3) double = [1 1 1]
                opts.SweepColor (1,3) double = [240 228 66] / 255
                opts.ExcludeColor (1,3) double = [230 159 0] / 255
                opts.AnalysisColor (1,3) double = [86 180 233] / 255
                opts.ReferenceColor (1,3) double = [0.85 0.85 0.85]
                opts.HatchSpacingPx (1,1) double {mustBePositive} = 30
            end
            obj.Fig = ancestor(parent, 'figure');
            obj.Clock = tic;
            obj.MarkerPx = opts.MarkerPx;
            obj.MarkerLineWidth = opts.MarkerLineWidth;
            obj.InterpMode = opts.Interpolation;
            obj.HatchSpacing = opts.HatchSpacingPx;

            obj.Panel = uipanel(parent, 'BorderType', 'none', 'BackgroundColor', opts.Background, ...
                'AutoResizeChildren', 'off', 'Tag', 'MapView');
            ax = axes(obj.Panel);
            set(ax, 'Units', 'pixels', 'XLim', obj.XL, 'YLim', obj.YL, 'YDir', 'reverse', ...
                'XTick', [], 'YTick', [], 'XColor', 'none', 'YColor', 'none', 'Color', opts.Background, ...
                'Box', 'off', 'TickLength', [0 0], 'SortMethod', 'childorder', 'NextPlot', 'add', ...
                'XLimMode', 'manual', 'YLimMode', 'manual', 'ZLimMode', 'manual', 'CLimMode', 'manual', ...
                'ALimMode', 'manual', 'HitTest', 'on', 'PickableParts', 'visible', 'Tag', 'MapAxes');
            ax.InnerPosition = [1 1 10 10];
            try ax.Toolbar = []; catch; end %#ok<*CTCH>
            try disableDefaultInteractivity(ax); catch; end
            try ax.Interactions = []; catch; end
            obj.Axes = ax;

            none = {'HitTest', 'off', 'PickableParts', 'none'};
            obj.Image = image('Parent', ax, 'CData', zeros(1, 1, 3, 'uint8'), 'XData', [1 1], 'YData', [1 1], ...
                none{:}, 'Tag', 'MapImage');
            obj.setInterpolation("nearest");

            obj.RegionGroup = hggroup(ax, none{:}, 'Tag', 'MapRegions');
            obj.ExcludeFill = patch('Parent', obj.RegionGroup, 'Faces', zeros(0, 3), 'Vertices', zeros(0, 2), ...
                'FaceColor', opts.ExcludeColor, 'FaceAlpha', 0.22, 'EdgeColor', opts.ExcludeColor, ...
                'LineWidth', 1.5, none{:}, 'Tag', 'MapExcludeFill');
            obj.ExcludeHatch = line(NaN, NaN, 'Parent', obj.RegionGroup, 'Color', opts.ExcludeColor, ...
                'LineWidth', 0.75, none{:}, 'Tag', 'MapExcludeHatch');
            obj.AnalysisLine = line(NaN, NaN, 'Parent', obj.RegionGroup, 'Color', opts.AnalysisColor, ...
                'LineWidth', 1.25, none{:}, 'Tag', 'MapAnalysis');
            obj.ReferenceLine = line(NaN, NaN, 'Parent', obj.RegionGroup, 'Color', opts.ReferenceColor, ...
                'LineWidth', 1, 'LineStyle', '--', none{:}, 'Tag', 'MapReference');
            obj.SweepLine = line(ax, NaN, NaN, 'Color', opts.SweepColor, 'LineWidth', 2, none{:}, 'Tag', 'MapSweep');

            obj.PointGroup = hggroup(ax, none{:}, 'Tag', 'MapPointGroup');
            obj.MarkerStyles = struct('Marker', {'o'}, 'Filled', {opts.MarkerStyle == "dot"});
            obj.Layers = obj.newLayer(1);
            obj.Points = obj.Layers(1);
            obj.styleLayer(1);
            ring = @(px) px * obj.PtPerPx;
            obj.HoverLine = line(ax, NaN, NaN, 'LineStyle', 'none', 'Marker', 'o', ...
                'MarkerSize', ring(opts.MarkerPx + 6), 'Color', opts.HoverColor, 'LineWidth', 1, none{:}, ...
                'Tag', 'MapHover');
            obj.MarkLine = line(ax, NaN, NaN, 'LineStyle', 'none', 'Marker', 'o', ...
                'MarkerSize', ring(opts.MarkerPx + 16), 'Color', opts.MarkColor, 'LineWidth', 1.25, none{:}, ...
                'Tag', 'MapMarks');
            obj.SelectionLine = line(ax, NaN, NaN, 'LineStyle', 'none', 'Marker', 'o', ...
                'MarkerSize', ring(opts.MarkerPx + 9), 'Color', opts.SelectionColor, 'LineWidth', 2, none{:}, ...
                'Tag', 'MapSelection');
            obj.DragLine = line(ax, NaN, NaN, 'LineStyle', ':', 'Marker', 'o', 'MarkerSize', ring(opts.MarkerPx), ...
                'Color', opts.DragColor, 'LineWidth', 2, none{:}, 'Tag', 'MapDrag');
            obj.LassoLine = line(ax, NaN, NaN, 'Color', opts.LassoColor, 'LineWidth', 1.5, none{:}, 'Tag', 'MapLasso');

            obj.Panel.SizeChangedFcn = @(~, ~) obj.onSizeChanged();
            obj.Panel.DeleteFcn = @(~, ~) obj.delete();
            obj.placeAxes();
            obj.fit();
            obj.LayoutDirty = true;          % made now: the panel's real size may come later
            obj.watchAncestors();
        end

        function delete(obj)
            if obj.Deleting; return; end
            obj.Deleting = true;
            for t = {obj.HoverTimer, obj.LayoutTimer}
                if ~isempty(t{1}) && isvalid(t{1})
                    stop(t{1});
                    delete(t{1});
                end
            end
            for k = 1:numel(obj.Listeners)
                try delete(obj.Listeners{k}); catch; end
            end
            obj.Listeners = {};
            if obj.PointerSet ~= "" && ~isempty(obj.Fig) && isvalid(obj.Fig) && strcmp(obj.Fig.BeingDeleted, 'off')
                try obj.Fig.Pointer = 'arrow'; catch; end
            end
            if ~isempty(obj.Panel) && isvalid(obj.Panel) && strcmp(obj.Panel.BeingDeleted, 'off')
                delete(obj.Panel);
            end
        end

        % ---- dependent properties -------------------------------------------------------------------
        function t = get.Tool(obj)
            t = obj.ToolValue;
        end

        function set.Tool(obj, t)
            t = lower(string(t));
            if ~isscalar(t) || ~any(t == ["select" "add" "move" "lasso"])
                error('MapView:BadTool', 'Tool must be "select", "add", "move" or "lasso".');
            end
            if t == obj.ToolValue; return; end
            if ~isempty(obj.Drag); obj.cancelDrag(); end
            obj.ToolValue = t;
            if obj.PointerSet ~= ""          % the pointer is over the map: show the new tool at once
                obj.setPointer(obj.toolPointer());
            end
        end

        function n = get.N(obj)
            n = numel(obj.Ids);
        end

        function tf = get.IsFit(obj)
            tf = obj.FitNow;
        end

        function g = get.Gesture(obj)
            if isempty(obj.Drag); g = ""; else; g = obj.Drag.Kind; end
        end

        function v = get.Interpolation(obj)
            v = obj.InterpNow;
        end

        % ---- image ------------------------------------------------------------------------------------
        function setImage(obj, pageT, pageC, limits, umPerPx, opts)
            %setImage  Show a new source: target page, companion page ([] = none), fixed display limits
            %   (2 x 2 [lo hi], [] or NaN rows to compute) and the pixel size. Fits the whole image unless
            %   KeepView is true and the size is unchanged.
            arguments
                obj
                pageT {mustBeNumeric, mustBeReal}
                pageC {mustBeNumeric, mustBeReal} = []
                limits double = []
                umPerPx (1,1) double {mustBePositive, mustBeFinite} = 1
                opts.KeepView (1,1) logical = false
            end
            if ~ismatrix(pageT) || isempty(pageT)
                error('MapView:BadPage', 'The target page must be a non-empty H x W matrix.');
            end
            if ~isempty(pageC) && ~isequal(size(pageC), size(pageT))
                error('MapView:BadPage', 'The companion page must be [] or the size of the target page (%d x %d).', ...
                    size(pageT, 1), size(pageT, 2));
            end
            t0 = tic;
            lim = NaN(2, 2);
            if ~isempty(limits)
                if size(limits, 2) ~= 2 || size(limits, 1) > 2
                    error('MapView:BadLimits', 'limits must be [] or 1 x 2 / 2 x 2 [lo hi] rows (target; companion).');
                end
                lim(1:size(limits, 1), :) = limits;
            end
            if ~(all(isfinite(lim(1, :))) && lim(1, 2) > lim(1, 1))
                lim(1, :) = curation.CropCache.pageLimits(pageT, [1 99.9], 1e6);
            end
            if isempty(pageC)
                lim(2, :) = NaN;
            elseif ~(all(isfinite(lim(2, :))) && lim(2, 2) > lim(2, 1))
                lim(2, :) = curation.CropCache.pageLimits(pageC, [1 99.9], 1e6);
            end
            oldSize = obj.ImageSize;
            obj.cancelDrag();
            obj.Pages = {pageT, pageC};
            obj.HasCompanion = ~isempty(pageC);
            obj.Limits = lim;
            obj.Base = {curation.MapView.toBase(pageT, lim(1, :)), []};
            obj.DisplayCache = struct('Key', {}, 'RGB', {});
            obj.ImageSize = size(pageT);
            obj.UmPerPx = umPerPx;
            rgb = obj.displayImage();
            [H, W] = deal(obj.ImageSize(1), obj.ImageSize(2));
            set(obj.Image, 'CData', rgb, 'XData', [1 W], 'YData', [1 H]);
            obj.LastTimings.BuildMs = 1000 * toc(t0);
            if ~isequal(oldSize, obj.ImageSize)
                obj.SweepRects = zeros(0, 4);
                obj.SweepIndex = 0;
                set(obj.SweepLine, 'XData', NaN, 'YData', NaN);
            end
            if opts.KeepView && isequal(oldSize, obj.ImageSize)
                obj.applyView(obj.Center, obj.Scale);
            else
                obj.fit();
            end
            obj.flush();
        end

        function setMode(obj, mode)
            %setMode  "target" | "companion" | "overlay" (target green, companion magenta).
            mode = lower(string(mode));
            if ~isscalar(mode) || ~any(mode == ["target" "companion" "overlay"])
                error('MapView:BadMode', 'Mode must be "target", "companion" or "overlay".');
            end
            if mode == obj.Mode; return; end
            obj.Mode = mode;
            obj.refreshImage();
        end

        function setGain(obj, g)
            %setGain  Display gain, scalar or [target companion] (>= 0).
            g = curation.MapView.pair(g, 'Gain');
            if any(g < 0); error('MapView:BadGain', 'Gain must be >= 0.'); end
            if isequal(g, obj.Gain); return; end
            obj.Gain = g;
            obj.refreshImage();
        end

        function setGamma(obj, g)
            %setGamma  Display gamma, scalar or [target companion] (> 0; < 1 brightens).
            g = curation.MapView.pair(g, 'Gamma');
            if any(g <= 0); error('MapView:BadGamma', 'Gamma must be > 0.'); end
            if isequal(g, obj.Gamma); return; end
            obj.Gamma = g;
            obj.refreshImage();
        end

        function setDisplay(obj, mode, gain, gamma)
            %setDisplay  setMode + setGain + setGamma with ONE image refresh (when anything changed).
            mode = lower(string(mode));
            if ~isscalar(mode) || ~any(mode == ["target" "companion" "overlay"])
                error('MapView:BadMode', 'Mode must be "target", "companion" or "overlay".');
            end
            g = curation.MapView.pair(gain, 'Gain');
            y = curation.MapView.pair(gamma, 'Gamma');
            if any(g < 0); error('MapView:BadGain', 'Gain must be >= 0.'); end
            if any(y <= 0); error('MapView:BadGamma', 'Gamma must be > 0.'); end
            if mode == obj.Mode && isequal(g, obj.Gain) && isequal(y, obj.Gamma); return; end
            obj.Mode = mode;
            obj.Gain = g;
            obj.Gamma = y;
            obj.refreshImage();
        end

        % ---- points -----------------------------------------------------------------------------------
        function setPoints(obj, ids, xy, rgb, layer)
            %setPoints  Replace all points (clears the selection and the hover ring).
            [ids, xy, rgb] = curation.MapView.checkPoints(ids, xy, rgb);
            if numel(unique(ids)) ~= numel(ids)
                error('MapView:DuplicateIds', 'Point ids must be unique.');
            end
            if nargin < 5 || isempty(layer), layer = 1; end
            layer = obj.checkLayer(layer, numel(ids));
            obj.cancelDrag();
            obj.Ids = ids;
            obj.XY = xy;
            obj.RGB = rgb;
            obj.Layer = layer;
            obj.Shown = true(numel(ids), 1);
            obj.XD = xy(:, 1);
            obj.YD = xy(:, 2);
            obj.CD = double(rgb) / 255;
            obj.rebuildLookup();
            obj.pushPoints(true, true);
            obj.Selection = zeros(0, 1, 'uint32');
            set(obj.SelectionLine, 'XData', NaN, 'YData', NaN);
            obj.Marks = zeros(0, 1, 'uint32');
            set(obj.MarkLine, 'XData', NaN, 'YData', NaN);
            obj.HoverId = uint32(0);
            set(obj.HoverLine, 'XData', NaN, 'YData', NaN);
            obj.flush();
        end

        function updatePoints(obj, ids, rgb, layer)
            %updatePoints  Recolour points IDS (rgb N x 3 or 1 x 3, 0-255) in place; with LAYER (scalar
            %   or one per id) also move them to that marker layer.
            rows = obj.requireRows(ids);
            if isempty(rows); return; end
            rgb = curation.MapView.colours(rgb, numel(rows));
            obj.RGB(rows, :) = rgb;
            obj.CD(rows, :) = double(rgb) / 255;
            relayered = [];
            if nargin >= 4 && ~isempty(layer)
                layer = obj.checkLayer(layer, numel(rows));
                old = obj.Layer(rows);
                ch = old ~= layer;
                if any(ch)
                    relayered = unique([old(ch); layer(ch)]);
                    obj.Layer(rows) = layer;
                end
            end
            obj.pushPoints(false, true, rows, relayered);
            obj.flush();
        end

        function setMarkerStyles(obj, styles)
            %setMarkerStyles  One scatter per marker style (struct array Marker, Filled); see the
            %   class help. Scatters are reused, added or deleted; points keep their layer (a layer
            %   that is gone sends its points to layer 1).
            styles = curation.MapView.checkStyles(styles);
            K = numel(styles);
            for k = numel(obj.Layers) + 1:K
                obj.Layers(k) = obj.newLayer(k);
            end
            if numel(obj.Layers) > K
                delete(obj.Layers(K + 1:end));
                obj.Layers = obj.Layers(1:K);
            end
            obj.MarkerStyles = styles;
            for k = 1:K
                obj.styleLayer(k);
            end
            obj.Layer(obj.Layer > K) = 1;
            obj.pushPoints(true, true, [], 1:K);         % every layer from scratch
            obj.flush();
        end

        function movePoints(obj, ids, xy)
            %movePoints  Move points IDS to XY (N x 2).
            rows = obj.requireRows(ids);
            if isempty(rows); return; end
            [~, xy] = curation.MapView.checkXY(ids, xy);
            obj.cancelMoveOf(obj.Ids(rows));
            obj.XY(rows, :) = xy;
            sh = obj.Shown(rows);
            obj.XD(rows(sh)) = xy(sh, 1);
            obj.YD(rows(sh)) = xy(sh, 2);
            obj.pushPoints(true, false, rows);
            obj.refreshRings(obj.Ids(rows));
            obj.flush();
        end

        function addPoints(obj, ids, xy, rgb, layer)
            %addPoints  Add new points (ids not yet on the map); LAYER default 1.
            [ids, xy, rgb] = curation.MapView.checkPoints(ids, xy, rgb);
            if isempty(ids); return; end
            if numel(unique(ids)) ~= numel(ids) || any(obj.rowsOf(ids) > 0)
                error('MapView:DuplicateIds', 'Point ids must be new and unique (use movePoints to move a point).');
            end
            if nargin < 5 || isempty(layer), layer = 1; end
            layer = obj.checkLayer(layer, numel(ids));
            obj.Ids = [obj.Ids; ids];
            obj.XY = [obj.XY; xy];
            obj.RGB = [obj.RGB; rgb];
            obj.Layer = [obj.Layer; layer];
            obj.Shown = [obj.Shown; true(numel(ids), 1)];
            obj.XD = [obj.XD; xy(:, 1)];
            obj.YD = [obj.YD; xy(:, 2)];
            obj.CD = [obj.CD; double(rgb) / 255];
            obj.rebuildLookup();
            obj.pushPoints(true, true);
            obj.flush();
        end

        function removePoints(obj, ids)
            %removePoints  Remove points IDS (unknown ids are ignored).
            rows = obj.rowsOf(ids);
            rows = unique(rows(rows > 0));
            if isempty(rows); return; end
            gone = obj.Ids(rows);
            obj.cancelMoveOf(gone);
            keep = true(numel(obj.Ids), 1);
            keep(rows) = false;
            obj.Ids = obj.Ids(keep);
            obj.XY = obj.XY(keep, :);
            obj.RGB = obj.RGB(keep, :);
            obj.Layer = obj.Layer(keep);
            obj.Shown = obj.Shown(keep);
            obj.XD = obj.XD(keep);
            obj.YD = obj.YD(keep);
            obj.CD = obj.CD(keep, :);
            obj.rebuildLookup();
            obj.pushPoints(true, true);
            wasSelected = ismember(obj.Selection, gone);
            if any(wasSelected)
                obj.Selection = obj.Selection(~wasSelected);
                obj.drawSelection();
            end
            wasMarked = ismember(obj.Marks, gone);
            if any(wasMarked)
                obj.Marks = obj.Marks(~wasMarked);
                obj.drawMarks();
            end
            if ismember(obj.HoverId, gone)
                obj.HoverId = uint32(0);
                obj.drawHover();
            end
            obj.flush();
        end

        function setVisible(obj, ids, tf)
            %setVisible  Show (tf true) or hide points IDS; TF scalar or one per id. Unknown ids are ignored.
            ids = ids(:);
            tf = logical(tf(:));
            if isscalar(tf)
                tf = repmat(tf, numel(ids), 1);
            elseif numel(tf) ~= numel(ids)
                error('MapView:BadVisible', 'tf must be scalar or have one entry per id.');
            end
            rows = obj.rowsOf(ids);
            ok = rows > 0;
            rows = rows(ok);
            tf = tf(ok);
            if isempty(rows); return; end
            changed = obj.Shown(rows) ~= tf;
            if ~any(changed); return; end
            rows = rows(changed);
            tf = tf(changed);
            obj.cancelMoveOf(obj.Ids(rows(~tf)));
            obj.Shown(rows) = tf;
            obj.XD(rows) = obj.XY(rows, 1);
            obj.YD(rows) = obj.XY(rows, 2);
            obj.XD(rows(~tf)) = NaN;
            obj.YD(rows(~tf)) = NaN;
            obj.pushPoints(true, false, rows);
            if obj.HoverId ~= 0 && any(obj.Ids(rows(~tf)) == obj.HoverId)
                obj.HoverId = uint32(0);
                obj.drawHover();
            end
            obj.refreshRings(obj.Ids(rows));
            obj.flush();
        end

        function setSelection(obj, ids)
            %setSelection  Rings on points IDS ([] clears); ids not on the map are dropped.
            ids = uint32(ids(:));
            ids = ids(obj.rowsOf(ids) > 0);
            [~, first] = unique(ids, 'stable');
            obj.Selection = ids(first);
            obj.drawSelection();
            obj.flush();
        end

        function setMarks(obj, ids)
            %setMarks  Dashed rings on points IDS ([] clears), apart from the selection: what a task
            %   is about (CellCurator: the cells of the close pair on screen). Selecting, hovering and
            %   labelling are unaffected by them.
            ids = uint32(ids(:));
            ids = ids(obj.rowsOf(ids) > 0);
            obj.Marks = unique(ids, 'stable');
            obj.drawMarks();
            obj.flush();
        end

        function setHover(obj, id)
            %setHover  Ring point ID as hovered (0 or an id not shown clears the ring), from code:
            %   HoverFcn is not called; a pending pointer hover is dropped. The next pointer motion takes
            %   the ring over again.
            id = uint32(id(1));
            row = obj.rowsOf(id);
            if id ~= 0 && (row == 0 || ~obj.Shown(row)); id = uint32(0); end
            obj.cancelHover();
            obj.HoverDelivered = id;
            if id == obj.HoverId; return; end
            obj.HoverId = id;
            obj.drawHover();
            obj.flush();
        end

        function id = pick(obj, xy, maxDistPx)
            %pick  Id of the nearest visible point to XY within maxDistPx image pixels (0 if none).
            if nargin < 3 || isempty(maxDistPx); maxDistPx = obj.PickRadiusPx * obj.Scale; end
            row = obj.pickRow(double(xy(1, 1:2)), maxDistPx);
            if row > 0
                id = obj.Ids(row);
            else
                id = uint32(0);
            end
        end

        function rows = rowsOf(obj, ids)
            %rowsOf  Rows of IDS in Ids/XY/RGB (same shape as IDS; 0 where an id is not on the map).
            sz = size(ids);
            ids = double(ids(:));
            rows = zeros(numel(ids), 1);
            if obj.DenseLookup
                ok = ids >= 0 & ids < numel(obj.RowOfId) & ids == floor(ids);
                rows(ok) = obj.RowOfId(ids(ok) + 1);
            else
                [~, rows] = ismember(ids, double(obj.Ids));
            end
            rows = reshape(rows, sz);
        end

        % ---- regions and sweep ------------------------------------------------------------------------
        function setRegions(obj, regions)
            %setRegions  Draw REGIONS (struct array: xy M x 2, kind "exclude"|"analysis"|"reference", id).
            if isempty(regions)
                regions = struct('xy', {}, 'kind', {}, 'id', {});
            end
            if ~isstruct(regions) || ~all(isfield(regions, {'xy', 'kind'}))
                error('MapView:BadRegions', 'regions must be a struct array with fields xy and kind (and id).');
            end
            if ~isfield(regions, 'id'); [regions.id] = deal([]); end
            kinds = strings(numel(regions), 1);
            polys = cell(numel(regions), 1);
            for i = 1:numel(regions)
                kinds(i) = lower(string(regions(i).kind));
                if ~any(kinds(i) == ["exclude" "analysis" "reference"])
                    error('MapView:BadRegions', 'Region %d: kind must be "exclude", "analysis" or "reference" (got "%s").', ...
                        i, kinds(i));
                end
                p = double(regions(i).xy);
                if size(p, 2) ~= 2 || size(p, 1) < 2 || any(~isfinite(p), 'all')
                    error('MapView:BadRegions', 'Region %d: xy must be an M x 2 polygon of finite points.', i);
                end
                if size(p, 1) > 2 && isequal(p(1, :), p(end, :)); p(end, :) = []; end   % open form
                polys{i} = p;
                regions(i).kind = kinds(i);
            end
            obj.Regions = regions(:);

            ex = polys(kinds == "exclude");
            if isempty(ex)
                set(obj.ExcludeFill, 'Faces', zeros(0, 3), 'Vertices', zeros(0, 2));
                set(obj.ExcludeHatch, 'XData', NaN, 'YData', NaN);
            else
                m = cellfun(@(p) size(p, 1), ex);
                V = vertcat(ex{:});
                F = NaN(numel(ex), max(m));
                off = [0; cumsum(m(:))];
                for i = 1:numel(ex)
                    F(i, 1:m(i)) = off(i) + (1:m(i));
                end
                [hx, hy] = curation.MapView.hatch(ex, obj.HatchSpacing);
                set(obj.ExcludeFill, 'Faces', F, 'Vertices', V);
                set(obj.ExcludeHatch, 'XData', hx, 'YData', hy);
            end
            [x, y] = curation.MapView.outlines(polys(kinds == "analysis"));
            set(obj.AnalysisLine, 'XData', x, 'YData', y);
            [x, y] = curation.MapView.outlines(polys(kinds == "reference"));
            set(obj.ReferenceLine, 'XData', x, 'YData', y);
            obj.flush();
        end

        function rects = sweepRects(obj, fieldUm, overlapFrac, opts)
            %sweepRects  Viewport rectangles tiling the image row by row (see the class help).
            arguments
                obj
                fieldUm (1,1) double {mustBePositive, mustBeFinite}
                overlapFrac (1,1) double {mustBeGreaterThanOrEqual(overlapFrac, 0), mustBeLessThan(overlapFrac, 1)} = 0.1
                opts.Order (1,1) string {mustBeMember(opts.Order, ["serpentine" "raster"])} = "serpentine"
            end
            obj.checkGeometry(false);
            [W, H] = obj.imageWH();
            p = obj.panelPixels();
            fw = min(W, fieldUm / obj.UmPerPx);
            fh = min(H, fw * p(4) / p(3));
            [xs, fw] = curation.MapView.starts(W, fw, overlapFrac);
            [ys, fh] = curation.MapView.starts(H, fh, overlapFrac);
            rects = zeros(numel(xs) * numel(ys), 4);
            k = 0;
            for r = 1:numel(ys)
                cols = 1:numel(xs);
                if opts.Order == "serpentine" && mod(r, 2) == 0; cols = fliplr(cols); end
                for c = cols
                    k = k + 1;
                    rects(k, :) = [xs(c), xs(c) + fw, ys(r), ys(r) + fh];
                end
            end
            obj.SweepRects = rects;
            obj.SweepIndex = 0;
            set(obj.SweepLine, 'XData', NaN, 'YData', NaN);
            obj.flush();
        end

        function showSweepRect(obj, k)
            %showSweepRect  Zoom to sweep field K and outline it; K = 0 clears the outline.
            k = round(double(k));
            if k == 0
                obj.SweepIndex = 0;
                set(obj.SweepLine, 'XData', NaN, 'YData', NaN);
                obj.flush();
                return
            end
            if k < 1 || k > size(obj.SweepRects, 1)
                error('MapView:BadSweep', 'Sweep field %d does not exist (%d fields; call sweepRects first).', ...
                    k, size(obj.SweepRects, 1));
            end
            r = obj.SweepRects(k, :);
            obj.SweepIndex = k;
            set(obj.SweepLine, 'XData', r([1 2 2 1 1]), 'YData', r([3 3 4 4 3]));
            obj.checkGeometry(false);
            p = obj.panelPixels();
            s = max((r(2) - r(1)) / p(3), (r(4) - r(3)) / p(4)) * (1 + obj.SweepMargin);
            obj.applyView([mean(r(1:2)) mean(r(3:4))], s);
            obj.flush();
        end

        % ---- view -------------------------------------------------------------------------------------
        function refreshLayout(obj)
            %refreshLayout  Re-read the panel's size now and re-apply the view to it (a fitted view
            %   stays fitted, else the centre and the scale are kept). Cheap when nothing changed.
            if obj.Deleting; return; end
            obj.checkGeometry(true);
            obj.flush();
        end

        function fit(obj)
            %fit  Show the whole image.
            obj.checkGeometry(false);
            [~, sMax] = obj.scaleRange();
            [W, H] = obj.imageWH();
            obj.applyView([(W + 1) / 2, (H + 1) / 2], sMax);
            obj.flush();
        end

        function centerOn(obj, xy, halfWidthUm)
            %centerOn  Centre the view on XY; with halfWidthUm, the narrower side spans 2*halfWidthUm.
            obj.checkGeometry(false);
            s = obj.Scale;
            if nargin > 2 && ~isempty(halfWidthUm)
                p = obj.panelPixels();
                s = 2 * halfWidthUm / obj.UmPerPx / min(p(3), p(4));
            end
            obj.applyView(double(xy(1, 1:2)), s);
            obj.flush();
        end

        function r = viewRect(obj)
            %viewRect  [xmin xmax ymin ymax] of the view, image pixels.
            r = [obj.XL obj.YL];
        end

        function setViewRect(obj, r)
            %setViewRect  Show rectangle R ([xmin xmax ymin ymax]) as large as it fits.
            obj.checkGeometry(false);
            p = obj.panelPixels();
            s = max((r(2) - r(1)) / p(3), (r(4) - r(3)) / p(4));
            obj.applyView([mean(r(1:2)) mean(r(3:4))], s);
            obj.flush();
        end

        function zoomBy(obj, factor, xy)
            %zoomBy  Zoom in by FACTOR (> 1 in, < 1 out) keeping image point XY (default the centre) fixed.
            obj.checkGeometry(false);
            if nargin < 3 || isempty(xy); xy = obj.Center; end
            obj.zoomAbout(double(xy(1, 1:2)), factor);
            obj.flush();
        end

        function panBy(obj, dxPx, dyPx)
            %panBy  Move the image by [dxPx dyPx] screen pixels (positive: right, up).
            obj.checkGeometry(false);
            obj.applyView(obj.Center + [-dxPx, dyPx] * obj.Scale, obj.Scale);
            obj.flush();
        end

        function d = figureToData(obj, fp)
            %figureToData  Figure pixel points (rows [x y], fig.CurrentPoint units) to image pixels.
            p = obj.panelPixels();
            d = [obj.XL(1) + (fp(:, 1) - (p(1) - 1)) * (diff(obj.XL) / p(3)), ...
                obj.YL(1) + ((p(2) - 1 + p(4)) - fp(:, 2)) * (diff(obj.YL) / p(4))];
        end

        function fp = dataToFigure(obj, d)
            %dataToFigure  Image pixel points (rows [x y]) to figure pixels (inverse of figureToData).
            p = obj.panelPixels();
            fp = [(d(:, 1) - obj.XL(1)) * (p(3) / diff(obj.XL)) + p(1) - 1, ...
                (p(2) - 1 + p(4)) - (d(:, 2) - obj.YL(1)) * (p(4) / diff(obj.YL))];
        end

        % ---- mouse and key routing --------------------------------------------------------------------
        function consumed = onButtonDown(obj, evt)
            %onButtonDown  Route a WindowButtonDown event; true when it belongs to the map.
            obj.checkGeometry(true);   % the panel may have moved, or got its size while hidden
            if ~isempty(obj.Drag); obj.cancelDrag(); end    % a release was missed
            [fp, over] = obj.eventPoint(evt);
            consumed = over;
            obj.PressedHere = over;
            if ~over || ~obj.hasImage(); return; end
            [st, mods] = obj.eventKind(evt);
            p = obj.figureToData(fp);
            obj.cancelHover();
            tool = obj.ToolValue;
            if st == "extend" && ~any(mods == "shift")        % the middle button pans in every tool
                obj.beginPan(fp, p, st, mods, uint32(0));
                obj.Drag.Kind = "pan";
                obj.setPointer("hand");
                return
            end
            if tool == "lasso" && st == "normal"
                obj.Drag = struct('Kind', "lasso", 'Fp0', fp, 'P0', p, 'LastFp', fp, 'Poly', p, ...
                    'SelectionType', st, 'Modifier', mods);
                set(obj.LassoLine, 'XData', p(1), 'YData', p(2));
                obj.flush();
                return
            end
            row = obj.pickRow(p, obj.PickRadiusPx * obj.Scale);
            if row > 0
                id = obj.Ids(row);
                obj.fire(obj.PointClickFcn, struct('Id', id, 'XY', obj.XY(row, :), 'PointerXY', p, ...
                    'SelectionType', char(st), 'Modifier', mods, 'Tool', tool));
                if obj.Deleting || st ~= "normal"; return; end
                row = obj.rowsOf(id);                         % the callback may have changed the points
                if tool == "move" && row > 0 && obj.Shown(row)
                    obj.Drag = struct('Kind', "move", 'Fp0', fp, 'P0', p, 'Id', id, 'FromXY', obj.XY(row, :), ...
                        'Offset', obj.XY(row, :) - p, 'Moved', false, 'SelectionType', st, 'Modifier', mods);
                else
                    obj.beginPan(fp, p, st, mods, id);        % "pending": a drag pans
                end
                obj.flush();
                return
            end
            if st == "normal"
                obj.beginPan(fp, p, st, mods, uint32(0));     % "pending": a click reports EmptyClickFcn
            elseif obj.inImage(p)
                obj.fire(obj.EmptyClickFcn, struct('XY', p, 'SelectionType', char(st), 'Modifier', mods, 'Tool', tool));
            end
        end

        function consumed = onMotion(obj, evt)
            %onMotion  Route a WindowButtonMotion event: the gesture in progress, else hover and pointer.
            if isempty(obj.Drag); obj.checkGeometry(false); end
            [fp, over] = obj.eventPoint(evt);
            if ~isempty(obj.Drag)
                consumed = true;
                obj.dragTo(fp);
                obj.flush();
                return
            end
            consumed = over;
            id = uint32(0);
            p = [NaN NaN];
            if over && obj.hasImage()
                obj.setPointer(obj.toolPointer());
                p = obj.figureToData(fp);
                row = obj.pickRow(p, obj.PickRadiusPx * obj.Scale);
                if row > 0; id = obj.Ids(row); end
            else
                obj.setPointer("");
            end
            obj.hoverTo(id, p);
            obj.flush();
        end

        function consumed = onButtonUp(obj, evt)
            %onButtonUp  Route a WindowButtonUp event; ends the gesture of a press on the map.
            consumed = obj.PressedHere || ~isempty(obj.Drag);
            obj.PressedHere = false;
            if isempty(obj.Drag); return; end
            [fp, over] = obj.eventPoint(evt);
            obj.dragTo(fp);                                   % the stretch since the last motion event
            if isempty(obj.Drag); return; end
            D = obj.Drag;
            obj.Drag = [];
            switch D.Kind
                case "pending"
                    if D.Id == 0 && obj.inImage(D.P0)
                        obj.fire(obj.EmptyClickFcn, struct('XY', D.P0, 'SelectionType', char(D.SelectionType), ...
                            'Modifier', D.Modifier, 'Tool', obj.ToolValue));
                    end
                case "move"
                    obj.finishMove(D, fp);
                case "lasso"
                    obj.finishLasso(D, fp);
            end
            if ~obj.Deleting
                if over; obj.setPointer(obj.toolPointer()); else; obj.setPointer(""); end
                obj.flush();
            end
        end

        function consumed = onScroll(obj, evt)
            %onScroll  Route a WindowScrollWheel event: zoom about the pointer, ZoomStep per notch.
            if isempty(obj.Drag); obj.checkGeometry(false); end
            [fp, over] = obj.eventPoint(evt);
            consumed = over;
            if ~over || ~obj.hasImage(); return; end
            n = double(evt.VerticalScrollCount);
            if n == 0 || ~isfinite(n); return; end
            obj.zoomAbout(obj.figureToData(fp), obj.ZoomStep ^ (-n));   % wheel up (n < 0) zooms in
            if ~isempty(obj.Drag) && any(obj.Drag.Kind == ["pan" "pending"])   % a pan goes on from the new view
                obj.Drag.Fp0 = fp;
                obj.Drag.C0 = obj.Center;
                obj.Drag.S0 = obj.Scale;
            end
            obj.flush();
        end

        function consumed = onKeyPress(obj, evt)
            %onKeyPress  Route a WindowKeyPress event: Escape cancels a gesture (true when it did).
            consumed = false;
            if string(evt.Key) == "escape" && ~isempty(obj.Drag)
                consumed = obj.cancelDrag();
            end
        end

        function cancelled = cancelDrag(obj)
            %cancelDrag  End the gesture in progress: a moved point snaps back, a lasso is dropped, a pan
            %   returns to its start. True when there was one.
            D = obj.Drag;
            obj.Drag = [];
            cancelled = ~isempty(D);
            if ~cancelled; return; end
            switch D.Kind
                case "move"
                    if D.Moved; obj.restoreMoved(D.Id); end
                case "lasso"
                    set(obj.LassoLine, 'XData', NaN, 'YData', NaN);
                case "pan"
                    obj.applyView(D.C0, D.S0);
            end
            if obj.PointerSet ~= ""; obj.setPointer(obj.toolPointer()); end
            obj.flush();
        end

        function installRouting(obj)
            %installRouting  Route the figure's mouse, wheel and key callbacks to this view alone.
            f = obj.Fig;
            f.WindowButtonDownFcn = @(~, e) obj.onButtonDown(e);
            f.WindowButtonMotionFcn = @(~, e) obj.onMotion(e);
            f.WindowButtonUpFcn = @(~, e) obj.onButtonUp(e);
            f.WindowScrollWheelFcn = @(~, e) obj.onScroll(e);
            f.WindowKeyPressFcn = @(~, e) obj.onKeyPress(e);
        end
    end

    % ------------------------------------------------------------------------------------------------
    methods (Access = private)
        function flush(obj)
            switch obj.FlushMode
                case "drawnow";   drawnow;
                case "limitrate"; drawnow limitrate;
            end
        end

        function tf = hasImage(obj)
            tf = ~isempty(obj.Base{1});
        end

        function [W, H] = imageWH(obj)
            if obj.hasImage()
                H = obj.ImageSize(1);
                W = obj.ImageSize(2);
            else
                H = 1;
                W = 1;
            end
        end

        function tf = inImage(obj, p)
            [W, H] = obj.imageWH();
            tf = all(isfinite(p)) && p(1) >= 0.5 && p(1) <= W + 0.5 && p(2) >= 0.5 && p(2) <= H + 0.5;
        end

        % ---- display image ------------------------------------------------------------------------------
        function B = base(obj, k)
            %base  uint8 page K (1 target, 2 companion) at its fixed limits, built when first needed.
            if isempty(obj.Base{k})
                obj.Base{k} = curation.MapView.toBase(obj.Pages{k}, obj.Limits(k, :));
            end
            B = obj.Base{k};
        end

        function rgb = displayImage(obj)
            %displayImage  The uint8 RGB image for the current mode, gain and gamma (a few are kept).
            key = [find(obj.Mode == ["target" "companion" "overlay"]) obj.Gain obj.Gamma];
            for i = 1:numel(obj.DisplayCache)
                if isequal(obj.DisplayCache(i).Key, key)
                    rgb = obj.DisplayCache(i).RGB;
                    return
                end
            end
            switch obj.Mode
                case "target"
                    L = curation.MapView.applyLut(obj.base(1), obj.Gain(1), obj.Gamma(1));
                    rgb = cat(3, L, L, L);
                case "companion"
                    if obj.HasCompanion
                        L = curation.MapView.applyLut(obj.base(2), obj.Gain(2), obj.Gamma(2));
                    else
                        L = curation.MapView.applyLut(obj.base(1), obj.Gain(1), obj.Gamma(1));
                    end
                    rgb = cat(3, L, L, L);
                case "overlay"
                    T = curation.MapView.applyLut(obj.base(1), obj.Gain(1), obj.Gamma(1));
                    if obj.HasCompanion
                        C = curation.MapView.applyLut(obj.base(2), obj.Gain(2), obj.Gamma(2));
                    else
                        C = zeros(size(T), 'uint8');
                    end
                    rgb = cat(3, C, T, C);
            end
            obj.DisplayCache(end + 1) = struct('Key', key, 'RGB', rgb);
            if numel(obj.DisplayCache) > obj.MaxDisplayCache; obj.DisplayCache(1) = []; end
        end

        function refreshImage(obj)
            if ~obj.hasImage(); return; end
            t0 = tic;
            obj.Image.CData = obj.displayImage();
            obj.LastTimings.BuildMs = 1000 * toc(t0);
            obj.flush();
        end

        function setInterpolation(obj, v)
            if v == obj.InterpNow; return; end
            try
                obj.Image.Interpolation = v;
                obj.InterpNow = v;
            catch
                obj.InterpNow = "nearest";
            end
        end

        % ---- view geometry --------------------------------------------------------------------------------
        function p = panelPixels(obj)
            %panelPixels  The panel's position in figure pixels (cached until a resize or a press).
            if isempty(obj.PanelPx)
                p = getpixelposition(obj.Panel, true);
                p(3:4) = max(p(3:4), 1);
                obj.PanelPx = p;
            end
            p = obj.PanelPx;
        end

        function placeAxes(obj)
            p = obj.panelPixels();
            pos = [1 1 p(3) p(4)];
            if ~isequal(obj.Axes.InnerPosition, pos)
                obj.Axes.InnerPosition = pos;
            end
        end

        function [sMin, sMax] = scaleRange(obj)
            [W, H] = obj.imageWH();
            p = obj.panelPixels();
            sMax = max(W / p(3), H / p(4));
            sMin = min(sMax, obj.MinSpanPx / min(p(3), p(4)));
        end

        function applyView(obj, c, s)
            %applyView  Show centre C at scale S (clamped to the zoom range and to the image).
            [sMin, sMax] = obj.scaleRange();
            if ~isfinite(s) || s <= 0; s = sMax; end
            s = min(max(s, sMin), sMax);
            [W, H] = obj.imageWH();
            p = obj.panelPixels();
            obj.GeomPx = p(3:4);
            vw = p(3) * s;
            vh = p(4) * s;
            c = double(c);
            if ~all(isfinite(c)); c = [(W + 1) / 2, (H + 1) / 2]; end
            if vw >= W - 1e-9
                c(1) = (W + 1) / 2;
            else
                c(1) = min(max(c(1), 0.5 + vw / 2), W + 0.5 - vw / 2);
            end
            if vh >= H - 1e-9
                c(2) = (H + 1) / 2;
            else
                c(2) = min(max(c(2), 0.5 + vh / 2), H + 0.5 - vh / 2);
            end
            xl = c(1) + [-0.5 0.5] * vw;
            yl = c(2) + [-0.5 0.5] * vh;
            obj.Center = c;
            obj.Scale = s;
            obj.FitNow = s >= sMax * (1 - 1e-9);
            if isequal(xl, obj.XL) && isequal(yl, obj.YL); return; end
            set(obj.Axes, 'XLim', xl, 'YLim', yl);
            obj.XL = xl;
            obj.YL = yl;
            if obj.InterpMode == "auto"     % hysteresis: each switch sends the image again (~30-60 ms)
                if s <= 1
                    obj.setInterpolation("nearest");
                elseif s >= 1.5
                    obj.setInterpolation("bilinear");
                end
            else
                obj.setInterpolation(obj.InterpMode);
            end
            if ~isempty(obj.ViewChangedFcn)
                obj.fire(obj.ViewChangedFcn, struct('Rect', [xl yl], 'Scale', s, 'IsFit', obj.FitNow));
            end
        end

        function zoomAbout(obj, p, factor)
            %zoomAbout  Scale the view by 1/FACTOR keeping image point P under the same screen pixel.
            [sMin, sMax] = obj.scaleRange();
            s0 = obj.Scale;
            s = min(max(s0 / factor, sMin), sMax);
            if s == s0; return; end
            obj.applyView(p + (obj.Center - p) * (s / s0), s);
        end

        function onSizeChanged(obj)
            if obj.Deleting; return; end
            obj.checkGeometry(true);
        end

        function changed = checkGeometry(obj, reread)
            %checkGeometry  When REREAD (or the layout is dirty): read the panel's size again and, if
            %   it is not the size the view was computed for, place the axes and re-apply the view (a
            %   fitted view stays fitted, else the centre and the scale are kept). The layout stays
            %   dirty while the panel is not showing (a hidden panel's size means nothing).
            changed = false;
            if obj.Deleting || ~(reread || obj.LayoutDirty); return; end
            wasFit = obj.FitNow;             % with the old geometry
            obj.PanelPx = [];
            p = obj.panelPixels();
            if obj.LayoutDirty && obj.isShowing()
                obj.LayoutDirty = false;
            end
            if isequal(p(3:4), obj.GeomPx)
                return
            end
            changed = true;
            obj.placeAxes();
            if wasFit
                [~, sMax] = obj.scaleRange();
                [W, H] = obj.imageWH();
                obj.applyView([(W + 1) / 2, (H + 1) / 2], sMax);
            else
                obj.applyView(obj.Center, obj.Scale);
            end
        end

        function tf = isShowing(obj)
            %isShowing  The panel and every ancestor are visible (a tab: the selected one).
            tf = false;
            h = obj.Panel;
            while ~isempty(h) && isvalid(h)
                if isprop(h, 'Visible') && ~strcmp(char(h.Visible), 'on'); return; end
                if isa(h, 'matlab.ui.container.Tab')
                    g = h.Parent;
                    if ~isempty(g) && isprop(g, 'SelectedTab') && ~isequal(g.SelectedTab, h); return; end
                end
                if isa(h, 'matlab.ui.Figure'); break; end
                h = h.Parent;
            end
            tf = true;
        end

        function watchAncestors(obj)
            %watchAncestors  A show of an ancestor container (Visible of a panel turned on, the selected
            %   tab of a tab group) marks the layout dirty and re-checks it while the layout settles.
            %   The figure itself is not watched (a capture such as getframe may toggle it).
            h = obj.Panel.Parent;
            while ~isempty(h) && isvalid(h) && ~isa(h, 'matlab.ui.Figure')
                try
                    pr = findprop(h, 'Visible');
                    if ~isempty(pr) && pr.SetObservable
                        obj.Listeners{end + 1} = addlistener(h, 'Visible', 'PostSet', ...
                            @(~, e) obj.onAncestorVisible(e));
                    end
                catch
                end
                if isa(h, 'matlab.ui.container.TabGroup')
                    try
                        obj.Listeners{end + 1} = addlistener(h, 'SelectionChanged', @(~, ~) obj.markLayoutDirty());
                    catch
                    end
                end
                h = h.Parent;
            end
        end

        function onAncestorVisible(obj, e)
            try
                if strcmp(char(e.AffectedObject.Visible), 'on'), obj.markLayoutDirty(); end
            catch
            end
        end

        function markLayoutDirty(obj)
            if obj.Deleting; return; end
            obj.LayoutDirty = true;
            obj.PanelPx = [];
            if ~obj.isShowing(); return; end
            % shown: the browser lays the panel out moments later; look a few times until it has
            obj.LayoutChecks = 6;
            obj.armLayoutTimer();
        end

        function armLayoutTimer(obj)
            try
                t = obj.LayoutTimer;
                if isempty(t) || ~isvalid(t)
                    t = timer('ExecutionMode', 'singleShot', 'ObjectVisibility', 'off', ...
                        'Name', 'MapView layout', 'BusyMode', 'drop', 'TimerFcn', @(~, ~) obj.onLayoutTimer());
                    obj.LayoutTimer = t;
                end
                if strcmp(t.Running, 'off')
                    t.StartDelay = 0.08;
                    start(t);
                end
            catch
            end
        end

        function onLayoutTimer(obj)
            if obj.Deleting || isempty(obj.Panel) || ~isvalid(obj.Panel); return; end
            try
                if ~obj.isShowing(); return; end
                if obj.checkGeometry(true)
                    obj.flush();
                    obj.LayoutChecks = max(obj.LayoutChecks, 2);   % it moved: look again
                end
                obj.LayoutChecks = obj.LayoutChecks - 1;
                if obj.LayoutChecks > 0
                    obj.armLayoutTimer();
                end
            catch
            end
        end

        % ---- points -----------------------------------------------------------------------------------
        function rebuildLookup(obj)
            ids = double(obj.Ids);
            if isempty(ids)
                obj.RowOfId = zeros(0, 1);
                obj.DenseLookup = true;
            elseif max(ids) <= obj.MaxDenseId
                lk = zeros(max(ids) + 1, 1);
                lk(ids + 1) = 1:numel(ids);
                obj.RowOfId = lk;
                obj.DenseLookup = true;
            else
                obj.RowOfId = zeros(0, 1);
                obj.DenseLookup = false;
            end
        end

        function rows = requireRows(obj, ids)
            rows = obj.rowsOf(ids(:));
            if any(rows == 0)
                bad = ids(find(rows == 0, 1));
                error('MapView:UnknownId', 'Point %d is not on the map (use addPoints).', bad);
            end
        end

        function pushPoints(obj, xyChanged, colourChanged, rows, relayered)
            %pushPoints  Send the displayed positions and/or colours to the scatters (one set call
            %   each). ROWS: the rows that changed ([] = any: every layer is sent); RELAYERED: the
            %   layers that gained or lost points (sent whole). Every non-empty layer holds all N
            %   points, NaN where a point belongs to another layer, so its rows line up with Ids.
            if nargin < 4, rows = []; end
            if nargin < 5, relayered = []; end
            K = numel(obj.Layers);
            if isempty(obj.Ids)
                for k = 1:K
                    set(obj.Layers(k), 'XData', NaN, 'YData', NaN, 'CData', [1 1 1]);
                end
                return
            end
            if K == 1                                           % one style: the plain scatter
                h = obj.Layers(1);
                if (xyChanged && colourChanged) || ~isempty(relayered)
                    set(h, 'XData', obj.XD, 'YData', obj.YD, 'CData', obj.CD);
                elseif xyChanged
                    set(h, 'XData', obj.XD, 'YData', obj.YD);
                elseif colourChanged
                    h.CData = obj.CD;
                end
                return
            end
            if isempty(rows)
                touched = true(1, K);
            else
                touched = false(1, K);
                touched(unique(obj.Layer(rows))) = true;
            end
            for k = 1:K
                whole = any(relayered == k);
                doXY = whole || (xyChanged && touched(k));
                doC = whole || (colourChanged && touched(k));
                if ~doXY && ~doC; continue; end
                h = obj.Layers(k);
                in = obj.Layer == k;
                if ~any(in)
                    set(h, 'XData', NaN, 'YData', NaN, 'CData', [1 1 1]);
                elseif doXY
                    x = obj.XD;
                    y = obj.YD;
                    x(~in) = NaN;
                    y(~in) = NaN;
                    if doC
                        set(h, 'XData', x, 'YData', y, 'CData', obj.CD);
                    else
                        set(h, 'XData', x, 'YData', y);
                    end
                else
                    h.CData = obj.CD;
                end
            end
        end

        function h = newLayer(obj, k)
            %newLayer  An empty scatter for marker layer K, in PointGroup (above the earlier layers).
            sz = (obj.MarkerPx * obj.PtPerPx)^2;
            tag = 'MapPoints';
            if k > 1, tag = sprintf('MapPoints%d', k); end
            h = scatter(obj.PointGroup, NaN, NaN, sz, [1 1 1], 'o', 'HitTest', 'off', ...
                'PickableParts', 'none', 'Tag', tag);
        end

        function styleLayer(obj, k)
            %styleLayer  Marker, face and edge of layer K from MarkerStyles(K).
            s = obj.MarkerStyles(k);
            if s.Filled && ~any('+x*.' == s.Marker)
                set(obj.Layers(k), 'Marker', s.Marker, 'MarkerFaceColor', 'flat', ...
                    'MarkerEdgeColor', [0 0 0], 'LineWidth', 0.5);
            else
                set(obj.Layers(k), 'Marker', s.Marker, 'MarkerFaceColor', 'none', ...
                    'MarkerEdgeColor', 'flat', 'LineWidth', obj.MarkerLineWidth);
            end
        end

        function layer = checkLayer(obj, layer, n)
            %checkLayer  N x 1 marker layers (1..numel(MarkerStyles)) from a scalar or N values.
            layer = double(layer(:));
            if isscalar(layer); layer = repmat(layer, n, 1); end
            if numel(layer) ~= n || any(layer < 1 | layer > numel(obj.MarkerStyles) | layer ~= floor(layer))
                error('MapView:BadLayer', 'layer must be scalar or one per id, each 1 to %d (the marker styles).', ...
                    numel(obj.MarkerStyles));
            end
        end

        function row = pickRow(obj, p, r)
            row = 0;
            if isempty(obj.XD) || ~all(isfinite(p)); return; end
            d2 = (obj.XD - p(1)).^2 + (obj.YD - p(2)).^2;
            [m, i] = min(d2);
            if m <= r^2; row = i; end
        end

        function drawSelection(obj)
            rows = obj.rowsOf(obj.Selection);
            rows = rows(rows > 0);
            rows = rows(obj.Shown(rows));
            x = obj.XY(rows, 1);
            y = obj.XY(rows, 2);
            D = obj.Drag;
            if ~isempty(D) && D.Kind == "move" && D.Moved     % the dragged point's ring follows it
                j = obj.Ids(rows) == D.Id;
                if any(j)
                    q = obj.DragLine.XData;
                    x(j) = q(end);
                    q = obj.DragLine.YData;
                    y(j) = q(end);
                end
            end
            if isempty(x)
                set(obj.SelectionLine, 'XData', NaN, 'YData', NaN);
            else
                set(obj.SelectionLine, 'XData', x, 'YData', y);
            end
        end

        function drawHover(obj)
            row = obj.rowsOf(obj.HoverId);
            if obj.HoverId > 0 && row > 0 && obj.Shown(row)
                set(obj.HoverLine, 'XData', obj.XY(row, 1), 'YData', obj.XY(row, 2));
            else
                set(obj.HoverLine, 'XData', NaN, 'YData', NaN);
            end
        end

        function drawMarks(obj)
            rows = obj.rowsOf(obj.Marks);
            rows = rows(rows > 0);
            rows = rows(obj.Shown(rows));
            if isempty(rows)
                set(obj.MarkLine, 'XData', NaN, 'YData', NaN);
            else
                set(obj.MarkLine, 'XData', obj.XY(rows, 1), 'YData', obj.XY(rows, 2));
            end
        end

        function refreshRings(obj, ids)
            %refreshRings  Redraw the selection, mark and hover rings when points IDS changed.
            if any(ismember(obj.Marks, ids)); obj.drawMarks(); end
            if any(ismember(obj.Selection, ids)); obj.drawSelection(); end
            if obj.HoverId ~= 0 && any(ids == obj.HoverId); obj.drawHover(); end
        end

        % ---- gestures ---------------------------------------------------------------------------------
        function beginPan(obj, fp, p, st, mods, id)
            %beginPan  A "pending" press: becomes a pan once the pointer moves DragThresholdPx.
            obj.Drag = struct('Kind', "pending", 'Fp0', fp, 'P0', p, 'Id', id, 'C0', obj.Center, ...
                'S0', obj.Scale, 'SelectionType', st, 'Modifier', mods);
        end

        function dragTo(obj, fp)
            %dragTo  Advance the gesture in progress to figure point FP.
            D = obj.Drag;
            switch D.Kind
                case "pending"
                    if hypot(fp(1) - D.Fp0(1), fp(2) - D.Fp0(2)) < max(obj.DragThresholdPx, eps); return; end
                    obj.Drag.Kind = "pan";
                    obj.setPointer("hand");
                    obj.dragTo(fp);
                case "pan"
                    obj.applyView(D.C0 + [-(fp(1) - D.Fp0(1)), fp(2) - D.Fp0(2)] * D.S0, D.S0);
                case "move"
                    if ~D.Moved
                        if hypot(fp(1) - D.Fp0(1), fp(2) - D.Fp0(2)) < max(obj.DragThresholdPx, eps); return; end
                        obj.Drag.Moved = true;
                        row = obj.rowsOf(D.Id);
                        obj.XD(row) = NaN;                    % the scatter hides it; DragLine draws it
                        obj.YD(row) = NaN;
                        obj.pushPoints(true, false, row);
                        obj.HoverId = uint32(0);
                        set(obj.HoverLine, 'XData', NaN, 'YData', NaN);
                        obj.setPointer("fleur");
                    end
                    to = obj.figureToData(fp) + D.Offset;
                    set(obj.DragLine, 'XData', [D.FromXY(1) to(1)], 'YData', [D.FromXY(2) to(2)]);
                    if any(obj.Selection == D.Id); obj.drawSelection(); end
                    obj.fire(obj.PointDragFcn, struct('Id', D.Id, 'XY', to, 'FromXY', D.FromXY));
                case "lasso"
                    if hypot(fp(1) - D.LastFp(1), fp(2) - D.LastFp(2)) < obj.LassoStepPx; return; end
                    p = obj.figureToData(fp);
                    poly = [D.Poly; p];
                    obj.Drag.Poly = poly;
                    obj.Drag.LastFp = fp;
                    set(obj.LassoLine, 'XData', [poly(:, 1); poly(1, 1)], 'YData', [poly(:, 2); poly(1, 2)]);
            end
        end

        function finishMove(obj, D, fp)
            if ~D.Moved; return; end                          % a click in the move tool
            row = obj.rowsOf(D.Id);
            set(obj.DragLine, 'XData', NaN, 'YData', NaN);
            if row == 0; return; end
            to = obj.figureToData(fp) + D.Offset;
            if ~obj.inImage(to)
                obj.restoreMoved(D.Id);
                return
            end
            obj.XY(row, :) = to;
            obj.XD(row) = to(1);
            obj.YD(row) = to(2);
            obj.pushPoints(true, false, row);
            if any(obj.Selection == D.Id); obj.drawSelection(); end
            obj.fire(obj.PointDropFcn, struct('Id', D.Id, 'FromXY', D.FromXY, 'ToXY', to));
        end

        function restoreMoved(obj, id)
            %restoreMoved  Show point ID at its own place again after a cancelled move.
            set(obj.DragLine, 'XData', NaN, 'YData', NaN);
            row = obj.rowsOf(id);
            if row > 0 && obj.Shown(row)
                obj.XD(row) = obj.XY(row, 1);
                obj.YD(row) = obj.XY(row, 2);
                obj.pushPoints(true, false, row);
            end
            if any(obj.Selection == id); obj.drawSelection(); end
        end

        function cancelMoveOf(obj, ids)
            %cancelMoveOf  Cancel a move drag of one of IDS (the app changed that point meanwhile).
            if ~isempty(obj.Drag) && obj.Drag.Kind == "move" && any(ids == obj.Drag.Id)
                obj.cancelDrag();
            end
        end

        function finishLasso(obj, D, fp)
            set(obj.LassoLine, 'XData', NaN, 'YData', NaN);
            poly = D.Poly;
            if hypot(fp(1) - D.LastFp(1), fp(2) - D.LastFp(2)) > 0
                poly = [poly; obj.figureToData(fp)];
            end
            if size(unique(poly, 'rows'), 1) < 3; return; end
            in = obj.Shown & inpolygon(obj.XY(:, 1), obj.XY(:, 2), poly(:, 1), poly(:, 2));
            obj.fire(obj.LassoDoneFcn, struct('Polygon', poly, 'Ids', obj.Ids(in), ...
                'SelectionType', char(D.SelectionType), 'Modifier', D.Modifier));
        end

        function [fp, over] = eventPoint(obj, evt)
            %eventPoint  Figure point of a mouse event and whether it is over the map's panel.
            if isstruct(evt) && isfield(evt, 'AxesPoint')
                fp = obj.dataToFigure(double(evt.AxesPoint(1, 1:2)));
            elseif isstruct(evt) && isfield(evt, 'FigurePoint')
                fp = double(evt.FigurePoint(1, 1:2));
            else
                fp = double(obj.Fig.CurrentPoint(1, 1:2));
            end
            p = obj.panelPixels();     % pixel k of a Position spans [k-1, k] in CurrentPoint units
            over = all(isfinite(fp)) && fp(1) >= p(1) - 1 && fp(1) <= p(1) - 1 + p(3) && ...
                fp(2) >= p(2) - 1 && fp(2) <= p(2) - 1 + p(4);
        end

        function [st, mods] = eventKind(obj, evt)
            %eventKind  SelectionType and modifiers of a press (from the struct, else from the figure).
            if isstruct(evt) && isfield(evt, 'SelectionType')
                st = string(evt.SelectionType);
            else
                st = string(obj.Fig.SelectionType);
            end
            mods = strings(1, 0);
            if isstruct(evt) && isfield(evt, 'Modifier')
                mods = string(evt.Modifier);
            elseif isprop(obj.Fig, 'CurrentModifier')
                try mods = string(obj.Fig.CurrentModifier); catch; end
            end
            mods = reshape(mods, 1, []);
        end

        function ptr = toolPointer(obj)
            switch obj.ToolValue
                case "add";   ptr = "crosshair";
                case "move";  ptr = "fleur";
                case "lasso"; ptr = "cross";
                otherwise;    ptr = "arrow";
            end
        end

        function setPointer(obj, ptr)
            %setPointer  Put pointer PTR on the figure ("" gives back the arrow if this view changed it).
            if ptr == obj.PointerSet; return; end
            if ptr == ""
                try obj.Fig.Pointer = 'arrow'; catch; end
            else
                try obj.Fig.Pointer = char(ptr); catch; end
            end
            obj.PointerSet = ptr;
        end

        % ---- hover ------------------------------------------------------------------------------------
        function hoverTo(obj, id, p)
            %hoverTo  Ring the hovered point now; report it now or at the end of the throttle interval.
            if id ~= obj.HoverId
                obj.HoverId = id;
                obj.drawHover();
            end
            if isempty(obj.HoverFcn)
                obj.HoverDelivered = id;
                return
            end
            if id == obj.HoverDelivered && isempty(obj.HoverPending); return; end
            wait = obj.HoverInterval - (toc(obj.Clock) - obj.HoverTime);
            if wait <= 0
                obj.HoverPending = [];
                obj.deliverHover(id, p);
                return
            end
            obj.HoverPending = struct('Id', id, 'XY', p);
            if isempty(obj.HoverTimer) || ~isvalid(obj.HoverTimer)
                obj.HoverTimer = timer('ExecutionMode', 'singleShot', 'ObjectVisibility', 'off', ...
                    'Name', 'MapView hover', 'TimerFcn', @(~, ~) obj.flushHover());
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
            if p.Id ~= obj.HoverDelivered
                obj.deliverHover(p.Id, p.XY);
            end
        end

        function deliverHover(obj, id, p)
            obj.HoverDelivered = id;
            obj.HoverTime = toc(obj.Clock);
            obj.fire(obj.HoverFcn, struct('Id', id, 'XY', p));
        end

        function cancelHover(obj)
            obj.HoverPending = [];
            if ~isempty(obj.HoverTimer) && isvalid(obj.HoverTimer); stop(obj.HoverTimer); end
        end

        function fire(obj, fcn, info)
            if ~isempty(fcn)
                fcn(obj, info);
            end
        end
    end

    % ------------------------------------------------------------------------------------------------
    methods (Static)
        function preload()
            %preload  Load this class now. MATLAB runs timer callbacks while it loads a class, and a
            %   view constructed by such a callback while the class is still loading fails ("... is used
            %   in its own class definition"). Call once before any timer may construct a view.
        end
    end

    methods (Static, Access = private)
        function B = toBase(page, lim)
            %toBase  uint8 page: LIM(1) -> 0, LIM(2) -> 255 (double arithmetic: independent of the scale).
            B = uint8((double(page) - lim(1)) * (255 / (lim(2) - lim(1))));
        end

        function L = applyLut(B, gain, gamma)
            %applyLut  CropCache's display look-up table: 255 * min(1, gain*v)^gamma on v = B/255.
            if gain == 1 && gamma == 1
                L = B;
                return
            end
            x = (0:255)' / 255;
            lut = uint8(255 * min(1, max(0, x * gain)) .^ gamma);
            persistent haveIntlut
            if isempty(haveIntlut); haveIntlut = exist('intlut', 'file') > 0; end
            if haveIntlut
                L = intlut(B, lut);
            else
                L = reshape(lut(double(B) + 1), size(B));
            end
        end

        function g = pair(g, name)
            g = double(g(:)');
            if isscalar(g); g = [g g]; end
            if numel(g) ~= 2 || any(~isfinite(g))
                error(sprintf('MapView:Bad%s', name), '%s must be a finite scalar or [target companion].', name);
            end
        end

        function [ids, xy] = checkXY(ids, xy)
            ids = ids(:);
            if size(xy, 2) ~= 2 && numel(xy) == 2; xy = reshape(xy, 1, 2); end
            if size(xy, 2) ~= 2 || size(xy, 1) ~= numel(ids)
                error('MapView:BadPoints', 'xy must be N x 2 [X Y] with one row per id (%d ids, xy is %s).', ...
                    numel(ids), mat2str(size(xy)));
            end
            if any(~isfinite(xy), 'all')
                error('MapView:BadPoints', 'X and Y must be finite.');
            end
            xy = double(xy);
        end

        function [ids, xy, rgb] = checkPoints(ids, xy, rgb)
            if ~isnumeric(ids) || any(ids(:) < 0 | ids(:) ~= floor(ids(:)))
                error('MapView:BadPoints', 'Point ids must be non-negative integers.');
            end
            [ids, xy] = curation.MapView.checkXY(ids, xy);
            ids = uint32(ids);
            rgb = curation.MapView.colours(rgb, numel(ids));
        end

        function styles = checkStyles(styles)
            %checkStyles  K x 1 struct Marker (char), Filled (logical) from what setMarkerStyles got.
            if ~isstruct(styles) || isempty(styles) || ~all(isfield(styles, {'Marker', 'Filled'}))
                error('MapView:BadStyles', 'styles must be a non-empty struct array with fields Marker and Filled.');
            end
            ok = {'o', 's', 'd', '^', 'v', '>', '<', 'p', 'h', '+', 'x', '*', '.'};
            out = struct('Marker', cell(numel(styles), 1), 'Filled', false);
            for k = 1:numel(styles)
                m = char(styles(k).Marker);
                if ~any(strcmp(ok, m))
                    error('MapView:BadStyles', 'Marker "%s" is not one of %s.', m, strjoin(ok, ' '));
                end
                out(k).Marker = m;
                out(k).Filled = isscalar(styles(k).Filled) && logical(styles(k).Filled);
            end
            styles = out;
        end

        function rgb = colours(rgb, n)
            %colours  N x 3 uint8 colours from N x 3 or 1 x 3 values 0-255.
            if isequal(size(rgb), [1 3]); rgb = repmat(rgb, n, 1); end
            if ~isequal(size(rgb), [n 3])
                error('MapView:BadColour', 'rgb must be 1 x 3 or %d x 3 (0-255).', n);
            end
            if ~isa(rgb, 'uint8')
                rgb = double(rgb);
                if any(~isfinite(rgb), 'all') || any(rgb < 0 | rgb > 255, 'all')
                    error('MapView:BadColour', 'Colours are 0-255.');
                end
                rgb = uint8(rgb);
            end
        end

        function [s, f] = starts(L, f, ov)
            %starts  Left edges of fields of length F tiling [0.5, L + 0.5], overlapping by >= OV * F.
            if f >= L - 1e-9
                s = 0.5;
                f = L;
                return
            end
            n = ceil((L - f) / (f * (1 - ov)) - 1e-9) + 1;
            s = 0.5 + (0:n - 1) * ((L - f) / (n - 1));
        end

        function [x, y] = outlines(polys)
            %outlines  Closed outlines of POLYS as one NaN-separated line.
            if isempty(polys)
                x = NaN;
                y = NaN;
                return
            end
            c = cellfun(@(p) [p; p(1, :); NaN NaN], polys(:), 'UniformOutput', false);
            v = vertcat(c{:});
            x = v(:, 1);
            y = v(:, 2);
        end

        function [hx, hy] = hatch(polys, sp)
            %hatch  Diagonal hatch segments (lines y = x + b, b a multiple of SP) inside each polygon
            %   (even-odd rule), as one NaN-separated line.
            parts = {};
            for i = 1:numel(polys)
                x = polys{i}(:, 1);
                y = polys{i}(:, 2);
                x2 = circshift(x, -1);
                y2 = circshift(y, -1);
                b1 = y - x;
                b2 = y2 - x2;
                ks = ceil(min([b1; b2]) / sp):floor(max([b1; b2]) / sp);
                for k = ks
                    b = k * sp;
                    e = (b1 < b & b2 >= b) | (b2 < b & b1 >= b);
                    if nnz(e) < 2; continue; end
                    f = (b - b1(e)) ./ (b2(e) - b1(e));
                    xi = sort(x(e) + f .* (x2(e) - x(e)));
                    n = 2 * floor(numel(xi) / 2);
                    xa = xi(1:2:n);
                    xb = xi(2:2:n);
                    nanc = NaN(size(xa));
                    parts{end + 1} = [reshape([xa xb nanc]', [], 1), reshape([xa + b, xb + b, nanc]', [], 1)]; %#ok<AGROW>
                end
            end
            if isempty(parts)
                hx = NaN;
                hy = NaN;
            else
                v = vertcat(parts{:});
                hx = v(:, 1);
                hy = v(:, 2);
            end
        end
    end
end

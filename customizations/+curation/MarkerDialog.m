classdef MarkerDialog < handle
    %MARKERDIALOG  A small window to choose the map's markers: a colour and a symbol (filled or as an
    %   outline) for each cell state of curation.MapMarkers.CLASSES. Non-modal; every change is
    %   shown on the map at once (PreviewFcn); OK keeps the markers, Cancel or closing the window
    %   goes back to the markers it was opened with. Colours are chosen with uicolorpicker (inside the
    %   window: no blocking system dialog).
    %
    %   d = curation.MarkerDialog(S, Name=Value)
    %       S: the markers to start from (curation.MapMarkers struct; validated)
    %       PreviewFcn  fcn(S) after every change (and with the original markers on Cancel)
    %       DoneFcn     fcn(S, accepted) once, when the window closes: OK (accepted true, S the chosen
    %                   markers) or Cancel / the close box / Esc (accepted false, S the original ones)
    %       Near        a figure to centre the window over ([] = MATLAB's default place)
    %       Visible     'on' (default) | 'off' (tests)
    %
    %   Test seams (exactly what the controls call):
    %       d.setColor(cls, rgb)    rgb 0-255; cls a CLASSES name ("Unreviewed", "Good", ...)
    %       d.setSymbol(cls, code)  a curation.MapMarkers.SYMBOLS code ('o', 's', ...)
    %       d.setFilled(cls, tf)
    %       d.resetDefaults(), d.ok(), d.cancel(), d.handleKey(key)  ('return' | 'escape')
    %   Read-only: Figure, Styles (now), Original, Controls (per class: Color, Symbol, Filled, Preview)
    %
    %   See also curation.MapMarkers, CellCurator.

    properties (SetAccess = private)
        Figure = []
        Styles struct = struct()
        Original struct = struct()
        Controls struct = struct()
    end

    properties
        PreviewFcn = []
        DoneFcn = []
    end

    properties (Access = private)
        Done logical = false
    end

    methods
        function obj = MarkerDialog(S, opts)
            arguments
                S = curation.MapMarkers.defaults()
                opts.PreviewFcn = []
                opts.DoneFcn = []
                opts.Near = []
                opts.Visible = 'on'
            end
            obj.Styles = curation.MapMarkers.validate(S);
            obj.Original = obj.Styles;
            obj.PreviewFcn = opts.PreviewFcn;
            obj.DoneFcn = opts.DoneFcn;
            obj.build(opts.Near, opts.Visible);
        end

        function delete(obj)
            if ~isempty(obj.Figure) && isvalid(obj.Figure)
                obj.Figure.CloseRequestFcn = '';
                delete(obj.Figure);
            end
        end

        function setColor(obj, cls, rgb)
            cls = obj.checkClass(cls);
            rgb = round(double(rgb(:)'));
            if numel(rgb) ~= 3 || any(~isfinite(rgb) | rgb < 0 | rgb > 255)
                error('curation:MarkerDialog:badColor', 'A colour is [r g b], 0-255.');
            end
            obj.Styles.(cls).Color = rgb;
            obj.changed(cls);
        end

        function setSymbol(obj, cls, code)
            cls = obj.checkClass(cls);
            code = char(code);
            if ~any(strcmp(curation.MapMarkers.SYMBOLS(:, 1), code))
                error('curation:MarkerDialog:badSymbol', 'No marker symbol "%s".', code);
            end
            obj.Styles.(cls).Symbol = code;
            obj.changed(cls);
        end

        function setFilled(obj, cls, tf)
            cls = obj.checkClass(cls);
            obj.Styles.(cls).Filled = logical(tf);
            obj.changed(cls);
        end

        function resetDefaults(obj)
            obj.Styles = curation.MapMarkers.defaults();
            for c = curation.MapMarkers.CLASSES
                obj.syncRow(c);
            end
            obj.preview();
        end

        function ok(obj)
            obj.finish(true);
        end

        function cancel(obj)
            obj.finish(false);
        end

        function handled = handleKey(obj, key)
            handled = true;
            switch char(key)
                case {'return', 'enter'}, obj.ok();
                case 'escape',            obj.cancel();
                otherwise,                handled = false;
            end
        end
    end

    methods (Access = private)
        function build(obj, near, visible)
            U = @curation.UiText.label;
            T = @curation.UiText.tip;
            cls = curation.MapMarkers.CLASSES;
            W = 560;
            H = 120 + 38 * numel(cls);
            f = uifigure('Name', U('markerTitle'), 'Visible', 'off', 'Resize', 'off', 'Tag', 'fig:markers', ...
                'Position', [100 100 W H]);
            if ~isempty(near) && isvalid(near)
                p = near.Position;
                f.Position = [round(p(1) + (p(3) - W) / 2), round(p(2) + (p(4) - H) / 2), W, H];
            end
            f.CloseRequestFcn = @(~, ~) obj.cancel();
            f.KeyPressFcn = @(~, e) obj.handleKey(e.Key);
            obj.Figure = f;
            n = numel(cls);
            g = uigridlayout(f, [n + 3, 5], 'RowHeight', [{20}, repmat({30}, 1, n), {'fit'}, {30}], ...
                'ColumnWidth', {100, 70, 190, 60, '1x'}, 'Padding', [14 12 14 12], 'RowSpacing', 8, ...
                'ColumnSpacing', 12);
            heads = {'markerHeadClass', 'markerHeadColor', 'markerHeadSymbol', 'markerHeadFilled', 'markerHeadPreview'};
            for j = 1:numel(heads)
                h = uilabel(g, 'Text', U(heads{j}), 'FontWeight', 'bold');
                h.Layout.Row = 1; h.Layout.Column = j;
            end
            sym = curation.MapMarkers.SYMBOLS;
            items = strcat(sym(:, 3), {'  '}, sym(:, 2))';
            for k = 1:n
                c = cls(k);
                name = curation.UiText.markerClassLabel(c);
                r = k + 1;
                lb = uilabel(g, 'Text', name);
                lb.Layout.Row = r; lb.Layout.Column = 1;
                C.Color = uicolorpicker(g, 'Tag', char("cp:marker" + c), ...
                    'ValueChangedFcn', @(s, ~) obj.setColor(c, 255 * s.Value));
                C.Color.Layout.Row = r; C.Color.Layout.Column = 2;
                CellToolkit.setTooltip(C.Color, T('markerColor', lower(name)));
                C.Symbol = uidropdown(g, 'Items', items, 'ItemsData', sym(:, 1)', 'Tag', char("dd:marker" + c), ...
                    'ValueChangedFcn', @(s, ~) obj.setSymbol(c, s.Value));
                C.Symbol.Layout.Row = r; C.Symbol.Layout.Column = 3;
                CellToolkit.setTooltip(C.Symbol, T('markerSymbol', lower(name)));
                C.Filled = uicheckbox(g, 'Text', '', 'Tag', char("cb:marker" + c), ...
                    'ValueChangedFcn', @(s, ~) obj.setFilled(c, s.Value));
                C.Filled.Layout.Row = r; C.Filled.Layout.Column = 4;
                CellToolkit.setTooltip(C.Filled, T('markerFilled', lower(name)));
                C.Preview = uiimage(g, 'ScaleMethod', 'none', 'Tag', char("img:marker" + c));
                C.Preview.Layout.Row = r; C.Preview.Layout.Column = 5;
                obj.Controls.(c) = C;
                obj.syncRow(c);
            end
            note = uilabel(g, 'Text', U('markerNote'), 'WordWrap', 'on', 'FontColor', [0.35 0.35 0.35]);
            note.Layout.Row = n + 2; note.Layout.Column = [1 5];
            bg2 = uigridlayout(g, [1 4], 'ColumnWidth', {90, '1x', 90, 90}, 'Padding', [0 0 0 0], 'ColumnSpacing', 10);
            bg2.Layout.Row = n + 3; bg2.Layout.Column = [1 5];
            b = uibutton(bg2, 'Text', U('markerDefaults'), 'Tag', 'btn:markerDefaults', ...
                'ButtonPushedFcn', @(~, ~) obj.resetDefaults());
            b.Layout.Column = 1;
            CellToolkit.setTooltip(b, T('markerDefaults'));
            b = uibutton(bg2, 'Text', U('markerCancel'), 'Tag', 'btn:markerCancel', ...
                'ButtonPushedFcn', @(~, ~) obj.cancel());
            b.Layout.Column = 3;
            CellToolkit.setTooltip(b, T('markerCancel'));
            b = uibutton(bg2, 'Text', U('markerOk'), 'Tag', 'btn:markerOk', 'FontWeight', 'bold', ...
                'ButtonPushedFcn', @(~, ~) obj.ok());
            b.Layout.Column = 4;
            CellToolkit.setTooltip(b, T('markerOk'));
            f.Visible = visible;
        end

        function changed(obj, cls)
            obj.syncRow(cls);
            obj.preview();
        end

        function syncRow(obj, cls)
            %syncRow  The controls of one class from Styles (no callbacks fire on programmatic sets).
            if ~isfield(obj.Controls, cls), return; end
            C = obj.Controls.(cls);
            s = obj.Styles.(cls);
            if ~isvalid(C.Color), return; end
            col = s.Color / 255;
            if ~isequal(C.Color.Value, col), C.Color.Value = col; end
            if ~isequal(C.Symbol.Value, s.Symbol), C.Symbol.Value = s.Symbol; end
            line = curation.MapMarkers.isLineSymbol(s.Symbol);
            C.Filled.Value = s.Filled && ~line;
            C.Filled.Enable = matlab.lang.OnOffSwitchState(~line);
            C.Preview.ImageSource = curation.MarkerDialog.previewImage(s);
        end

        function preview(obj)
            if ~isempty(obj.PreviewFcn), obj.PreviewFcn(obj.Styles); end
        end

        function finish(obj, accepted)
            if obj.Done, return; end
            obj.Done = true;
            if accepted
                S = obj.Styles;
            else
                S = obj.Original;                % the map may show a change: back to the original
                obj.Styles = S;
                obj.preview();
            end
            fcn = obj.DoneFcn;
            delete(obj);
            if ~isempty(fcn), fcn(S, accepted); end
        end
    end

    methods (Static)
        function img = previewImage(s)
            %PREVIEWIMAGE  The Preview column's picture of marker S: the marker (larger than on the
            %   map, so its shape can be judged) in the middle of a dark strip of the map's background.
            bg = curation.UiText.colors().Background;
            sw = curation.MapMarkers.swatch(s, bg, 28, 9, 2);
            img = repmat(reshape(uint8(bg), 1, 1, 3), 28, 84);
            img(:, 29:56, :) = sw;
        end
    end

    methods (Static, Access = private)
        function c = checkClass(c)
            c = string(c);
            if ~any(curation.MapMarkers.CLASSES == c)
                error('curation:MarkerDialog:badClass', 'No marker class "%s" (one of %s).', c, ...
                    strjoin(curation.MapMarkers.CLASSES, ', '));
            end
            c = char(c);
        end
    end
end

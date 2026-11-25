classdef Regions
%REGIONS  Polygon regions of a curated dataset (pure data in, data out; no GUI).
%
%   A region is a struct with fields
%       id     double, unique within a dataset (0 = not yet assigned)
%       kind   string: "exclude" | "analysis" | "reference"
%       scope  string: "image" (every channel of the dataset) or a source key such as "ECM1"
%       xy     M x 2 polygon vertices [X Y], full-resolution image pixels in MATLAB's
%              convention (pixel centers at integers, first pixel = 1), not closed
%       note   string
%   A region list is an N x 1 struct array of these (0 x 1 when empty).
%
%   r       = curation.Regions.make(kind, xy, opts)
%   regions = curation.Regions.add(regions, r)
%   regions = curation.Regions.remove(regions, id)
%   regions = curation.Regions.normalize(decoded)
%   tf      = curation.Regions.contains(regions, xy)
%   tf      = curation.Regions.excluded(regions, xy, sourceKey)
%   tf      = curation.Regions.inAnalysis(regions, xy, sourceKey)
%   r       = curation.Regions.importImageJRoi(path, opts)
%   a       = curation.Regions.areaUm2(region, umPerPx)
%
%   ImageJ -> MATLAB coordinates: ImageJ coordinates are 0-based and continuous, pixel i
%   covering [i, i+1]; its center is i+0.5. MATLAB's pixel k has its center at k, so
%   x_matlab = x_imagej + 0.5 (same for y). A rect ROI left=10 width=20 therefore becomes
%   the polygon with x from 10.5 to 30.5, which in MATLAB covers pixel centers 11..30.

    methods (Static)

        function s = template()
        %TEMPLATE  The canonical 1 x 1 region struct (all fields, empty values).
            s = struct('id', 0, 'kind', "reference", 'scope', "image", ...
                'xy', zeros(0, 2), 'note', "");
        end

        function r = make(kind, xy, opts)
        %MAKE  Build one region struct.
        %   r = make(kind, xy)  or  make(kind, xy, opts) with opts a struct (or name-value
        %   cell is not supported) holding any of: scope (default "image"), note (default
        %   ""), id (default 0 = assigned by add). kind must be "exclude", "analysis" or
        %   "reference". xy is M x 2 numeric with M >= 3; a repeated closing vertex is
        %   dropped. Errors with id curation:Regions:badInput otherwise.
            if nargin < 3 || isempty(opts), opts = struct(); end
            kind = string(kind);
            if ~isscalar(kind) || ~ismember(kind, ["exclude" "analysis" "reference"])
                error('curation:Regions:badInput', ...
                    'kind must be "exclude", "analysis" or "reference".');
            end
            xy = curation.Regions.cleanXY(xy);
            r = curation.Regions.template();
            r.kind = kind;
            r.xy = xy;
            if isfield(opts, 'scope') && ~isempty(opts.scope), r.scope = string(opts.scope); end
            if isfield(opts, 'note') && ~isempty(opts.note), r.note = string(opts.note); end
            if isfield(opts, 'id') && ~isempty(opts.id), r.id = double(opts.id); end
        end

        function regions = add(regions, r)
        %ADD  Append region r. When r.id == 0 it gets max(existing ids, 0) + 1; a non-zero
        %   id is kept and must not already exist (error curation:Regions:duplicateId).
            regions = curation.Regions.normalize(regions);
            if r.id == 0
                if isempty(regions), r.id = 1; else, r.id = max([regions.id]) + 1; end
            elseif any([regions.id] == r.id)
                error('curation:Regions:duplicateId', 'Region id %g already exists.', r.id);
            end
            r = orderfields(r, curation.Regions.template());
            regions = [regions; r];
        end

        function regions = remove(regions, id)
        %REMOVE  Drop the region with this id (no error when it does not exist).
            regions = curation.Regions.normalize(regions);
            if isempty(regions), return; end
            regions = regions([regions.id] ~= id);
            regions = regions(:);
        end

        function regions = normalize(decoded)
        %NORMALIZE  Canonical N x 1 struct array from anything jsondecode may return for a
        %   regions array: [] (-> 0 x 1 struct with the right fields), a scalar struct, a
        %   struct array, or a cell array of structs whose fields or sizes differ. xy may
        %   be M x 2 numeric (a 2 x M array with M ~= 2 is transposed) or a cell of [x y]
        %   pairs. Missing fields get defaults. Idempotent.
            tmpl = curation.Regions.template();
            regions = repmat(tmpl, 0, 1);
            if isempty(decoded), return; end
            if iscell(decoded)
                items = decoded(:);
            elseif isstruct(decoded)
                items = num2cell(decoded(:));
            else
                error('curation:Regions:badInput', 'Cannot interpret a %s as regions.', class(decoded));
            end
            out = repmat(tmpl, numel(items), 1);
            for k = 1:numel(items)
                s = items{k};
                o = tmpl;
                if isfield(s, 'id') && ~isempty(s.id), o.id = double(s.id(1)); end
                if isfield(s, 'kind') && ~isempty(s.kind), o.kind = string(s.kind); end
                if isfield(s, 'scope') && ~isempty(s.scope), o.scope = string(s.scope); end
                if isfield(s, 'note') && ~isempty(s.note), o.note = string(s.note); end
                if isfield(s, 'xy') && ~isempty(s.xy)
                    o.xy = curation.Regions.xyFromDecoded(s.xy);
                end
                out(k) = o;
            end
            regions = out;
        end

        function tf = contains(regions, xy)
        %CONTAINS  N x K logical: point n (row of the N x 2 matrix xy) lies inside or on
        %   the edge of region k. K = numel(regions); with no regions the result is N x 0.
            regions = curation.Regions.normalize(regions);
            xy = reshape(double(xy), [], 2);
            n = size(xy, 1);
            tf = false(n, numel(regions));
            for k = 1:numel(regions)
                p = regions(k).xy;
                if size(p, 1) < 3 || n == 0, continue; end
                tf(:, k) = inpolygon(xy(:, 1), xy(:, 2), p(:, 1), p(:, 2));
            end
        end

        function tf = excluded(regions, xy, sourceKey)
        %EXCLUDED  N x 1 logical: the point is inside ANY "exclude" region whose scope is
        %   "image" or equals sourceKey.
            regions = curation.Regions.normalize(regions);
            sel = curation.Regions.applicable(regions, "exclude", sourceKey);
            tf = any(curation.Regions.contains(regions(sel), xy), 2);
        end

        function tf = inAnalysis(regions, xy, sourceKey)
        %INANALYSIS  N x 1 logical: true everywhere when no "analysis" region applies to
        %   sourceKey (scope "image" or sourceKey); otherwise true only inside at least
        %   one of those analysis regions.
            regions = curation.Regions.normalize(regions);
            sel = curation.Regions.applicable(regions, "analysis", sourceKey);
            if ~any(sel)
                tf = true(size(reshape(xy, [], 2), 1), 1);
            else
                tf = any(curation.Regions.contains(regions(sel), xy), 2);
            end
        end

        function r = importImageJRoi(path, opts)
        %IMPORTIMAGEJROI  Read one ImageJ .roi file into a region struct.
        %   opts (struct, optional): kind (default "reference"), scope (default "image"),
        %   note (default the file name), id (default 0). Supported: rect, oval (64-gon in
        %   the bounding box), polygon / freehand / traced, and a line with stroke width > 1,
        %   which becomes the rotated rectangle ("strip") of that width centered on the line
        %   (corner order: start+n, end+n, end-n, start-n with n = (-dy, dx)/length*width/2).
        %   Coordinates are converted to MATLAB's convention by adding 0.5 (see class help).
        %   A line of width <= 1, or any other type, raises curation:Regions:unsupportedRoi
        %   naming the ImageJ type; a bad file raises curation:Regions:badRoi.
            if nargin < 2 || isempty(opts), opts = struct(); end
            if isfield(opts, 'kind') && ~isempty(opts.kind), kind = opts.kind; else, kind = "reference"; end
            fid = fopen(path, 'r', 'ieee-be');
            if fid < 0
                error('curation:Regions:badRoi', 'Cannot open ROI file %s.', path);
            end
            cl = onCleanup(@() fclose(fid));
            b = fread(fid, Inf, '*uint8')';
            clear cl
            if numel(b) < 64 || ~isequal(char(b(1:4)), 'Iout')
                error('curation:Regions:badRoi', '%s is not an ImageJ ROI file.', path);
            end
            i16 = @(o) double(swapbytes(typecast(b(o+1:o+2), 'int16')));
            u16 = @(o) double(swapbytes(typecast(b(o+1:o+2), 'uint16')));
            f32 = @(o) double(swapbytes(typecast(b(o+1:o+4), 'single')));
            type = double(b(7));
            top = i16(8); left = i16(10); bottom = i16(12); right = i16(14);
            n = u16(16);
            names = containers.Map({0, 1, 2, 3, 4, 5, 7, 8, 10}, ...
                {'polygon', 'rect', 'oval', 'line', 'freeline', 'polyline', 'freehand', 'traced', 'point'});
            if names.isKey(type), tname = names(type); else, tname = sprintf('type %d', type); end
            switch type
                case 1
                    xy = [left top; right top; right bottom; left bottom];
                case 2
                    cx = (left + right) / 2; cy = (top + bottom) / 2;
                    rx = (right - left) / 2; ry = (bottom - top) / 2;
                    t = (0:63)' * 2 * pi / 64;
                    xy = [cx + rx * cos(t), cy + ry * sin(t)];
                case {0, 7, 8}
                    if n < 3 || numel(b) < 64 + 4 * n
                        error('curation:Regions:badRoi', '%s: truncated polygon ROI.', path);
                    end
                    xi = zeros(n, 1); yi = zeros(n, 1);
                    for k = 1:n
                        xi(k) = i16(64 + 2 * (k - 1));
                        yi(k) = i16(64 + 2 * n + 2 * (k - 1));
                    end
                    xy = [left + xi, top + yi];
                    if bitand(i16(50), 128) && numel(b) >= 64 + 4 * n + 8 * n
                        base = 64 + 4 * n;
                        xf = zeros(n, 1); yf = zeros(n, 1);
                        for k = 1:n
                            xf(k) = f32(base + 4 * (k - 1));
                            yf(k) = f32(base + 4 * n + 4 * (k - 1));
                        end
                        xy = [xf, yf];
                    end
                case 3
                    w = i16(34);
                    if w <= 1
                        error('curation:Regions:unsupportedRoi', ...
                            'ImageJ ROI type "line" with stroke width %d (<= 1) is not an area (%s).', w, path);
                    end
                    p1 = [f32(18) f32(22)]; p2 = [f32(26) f32(30)];
                    d = p2 - p1; len = hypot(d(1), d(2));
                    if len == 0
                        error('curation:Regions:badRoi', '%s: zero-length line.', path);
                    end
                    nv = [-d(2) d(1)] / len * (w / 2);
                    xy = [p1 + nv; p2 + nv; p2 - nv; p1 - nv];
                otherwise
                    error('curation:Regions:unsupportedRoi', ...
                        'ImageJ ROI type %d (%s) is not supported (%s).', type, tname, path);
            end
            xy = xy + 0.5;
            ropts = struct('scope', "image", 'note', "", 'id', 0);
            if isfield(opts, 'scope') && ~isempty(opts.scope), ropts.scope = opts.scope; end
            if isfield(opts, 'id') && ~isempty(opts.id), ropts.id = opts.id; end
            if isfield(opts, 'note') && ~isempty(opts.note)
                ropts.note = opts.note;
            else
                [~, nm, ex] = fileparts(path);
                ropts.note = string([nm ex]);
            end
            r = curation.Regions.make(kind, xy, ropts);
        end

        function a = areaUm2(region, umPerPx)
        %AREAUM2  Polygon area of one region in square micrometers: polyarea(xy) * umPerPx^2.
            a = polyarea(region.xy(:, 1), region.xy(:, 2)) * umPerPx^2;
        end

    end

    methods (Static, Access = private)

        function sel = applicable(regions, kind, sourceKey)
            if isempty(regions), sel = false(0, 1); return; end
            sel = ([regions.kind]' == kind) & ...
                ([regions.scope]' == "image" | [regions.scope]' == string(sourceKey));
        end

        function xy = cleanXY(xy)
            if ~isnumeric(xy) || size(xy, 2) ~= 2 || size(xy, 1) < 3
                error('curation:Regions:badInput', 'xy must be an M x 2 numeric array with M >= 3.');
            end
            xy = double(xy);
            if size(xy, 1) > 3 && isequal(xy(1, :), xy(end, :)), xy(end, :) = []; end
        end

        function xy = xyFromDecoded(v)
            if iscell(v)
                rows = cellfun(@(c) double(c(:))', v(:), 'UniformOutput', false);
                xy = vertcat(rows{:});
            else
                xy = double(v);
                if size(xy, 2) ~= 2 && size(xy, 1) == 2, xy = xy'; end
            end
            if size(xy, 2) ~= 2
                error('curation:Regions:badInput', 'Region xy must be M x 2.');
            end
        end

    end
end

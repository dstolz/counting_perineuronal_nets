classdef CellAnalysis < handle
% CELLANALYSIS  Measure the detected cells and look at their distributions, within and across sections.
%   For every cell of a section this window measures
%     * how far it is from the brain surface (found in the image, or traced by hand),
%     * its luminance (mean, background, contrast, signal to noise, integrated, the other
%       channel inside it, ...),
%     * its morphology (area, diameter, axes, aspect ratio, circularity, solidity, ...), and for
%       perineuronal nets the net's own measures (radius, wall thickness, ring contrast,
%       completeness, unevenness),
%     * its neighborhood (nearest neighbor, local density),
%     * its colocalization with the other channel: nets and PV cells are paired one to one
%       within a distance you set, with the share that chance alone would give, the other
%       channel's brightness inside each cell, and the partner's id in the export,
%   and draws histograms, cumulative distributions, box plots, depth profiles, a colocalization
%   summary and scatter plots of any of them: for one section, or across sections grouped by what the file names say
%   (subject, hemisphere, stain), by what the lab database knows about the subject (sex,
%   species, project, its tags and its variables), or by groups you give the sections yourself
%   (typed in the table, or imported from a spreadsheet). A number variable of the lab database
%   (the subject's age, a dose, ...) can also be plotted: as the metric, or on the horizontal
%   axis of the scatter plot against any measurement, one point per cell, section or subject.
%
%       CellAnalysis;                     % open empty, then Browse + Scan
%       app = CellAnalysis(parentDir);    % open and scan parentDir
%       CellAnalysis(parentDir, 'Scan', 'now')        scan before returning
%       CellAnalysis(..., 'UseSettings', false)       neither read nor write the saved settings
%
%   Which cells: by default the cells a person kept in Cell Curator ("Kept cells"); "All
%   detections" takes every candidate that is not merged, stale or inside an exclusion region.
%   "Reject near surface (um)" leaves out every cell closer than that to the brain surface (in
%   both channels, and the tissue there from the densities); sections without a surface keep
%   all their cells. Measurements are kept beside the data (<stem>_metrics.csv, <base>.cellanalysis.json), so a
%   section is measured once; "Measured" says "out of date" when its curation, image or surface
%   changed since. The curation files and the detector's locs are only read.
%
%   The metrics, how each is measured and what the files hold: cellanalysis.Measure,
%   cellanalysis.Surface, cellanalysis.Project. User guide: customizations/docs/CellAnalysis.md.
%
%   Seams for tests and scripts (the window's own actions, no dialogs) -----
%       app.scanFolder(parentDir)             scan now and show the result
%       app.setKind(kind)                     "pnn" | "pv" | a source key
%       app.setPopulation("kept" | "all"), app.setColocUm(um)
%       app.setMinDepthUm(um)                 reject the cells within um of the brain surface (0 = none)
%       app.setUse(rows, tf)                  rows of the table, or "all"
%       tf = app.selectSection(which)         a table row, or a dataset base
%       n = app.measure(which, force)         "selected" | "checked" | "all"; sources measured
%       app.setGroup(rows, name), rep = app.importGroups(file)
%       r = app.checkSubjects()               ask the lab database about the subjects (tags, variables)
%       n = app.useByTags(expr)               check the sections whose subject passes a tag filter
%       app.setPlot(name), app.setMetric(name), app.setXMetric(name), app.setGroupBy(name),
%       app.setUnit("cells" | "section" | "subject"), app.setScope("checked" | "selected"),
%       app.setBinUm(um)
%       app.showTab("Distributions" | "Section")
%       app.setSurfaceMode("auto" | "all" | "traced"), app.setSurfaceLine(xy),
%       tf = app.toggleSurfaceArea(xy)        xy in full-resolution pixels
%       file = app.exportCells(file), file = app.exportSummary(file), file = app.saveFigure(file)
%       app.handleKey(key, modifiers), app.waitForIdle(), app.addCloseListener(fcn)
%   Properties to read: Figure, ParentDirectory, Sources (cellanalysis.Project.sources plus the
%   groupings), DbColumns (the lab database's tag and variable columns of Sources:
%   cellanalysis.Project.databaseColumns), Rows (table row -> row of Sources), Use, Kind, Cells (every measured cell of the
%   kind), Sections (per section: cells, cells of the other channel, pairs, tissue area), View
%   (the cells behind the plot), PlotInfo, Summary, MapInfo, StatusText.
%
%   See also CELLDATASETMANAGER, CELLCURATOR, CELLANALYSIS.PROJECT, CELLANALYSIS.MEASURE.

    properties (Constant)
        PLOTS = {'Histogram', 'Cumulative', 'Box by group', 'Metric by depth', 'Cell density by depth', ...
            'Colocalization', 'Scatter'}
        UNIT_ITEMS = {'Cells', 'Sections', 'Subjects'}
        UNIT_DATA = {'cells', 'section', 'subject'}
        SCOPE_ITEMS = {'Checked sections', 'Selected section'}
        SCOPE_DATA = {'checked', 'selected'}
        POPULATION_ITEMS = {'Kept cells', 'All detections'}
        POPULATION_DATA = {'kept', 'all'}
        SURFACE_ITEMS = {'Automatic', 'Every empty area', 'Traced line'}
        SURFACE_DATA = {'auto', 'all', 'traced'}
        COLUMNS = {'Use', 'Subject', 'Section', 'Group', 'Cells', 'Measured', 'Surface'}
        MAP_MAX_DIM = 1400          % the section is shown with at most this many pixels a side
        MAP_CACHE = 4               % sections whose image and surface stay in memory
    end

    properties (SetAccess = private)
        Figure
        ParentDirectory char = ''
        Sources = cellanalysis.Project.emptySources()
        DbColumns = cellanalysis.Project.databaseColumns(table())   % the lab database's columns of Sources
        Rows double = zeros(0, 1)          % table row -> row of Sources
        Use logical = false(0, 1)          % per row of Sources: its cells take part
        Kind string = "pnn"
        Cells = table()                    % every measured cell of the kind (Project.load)
        Sections = table()                 % per source with cells: the second output of Project.load
        View = table()                     % the cells behind the plot
        PlotInfo struct = struct('Kind', "message", 'Names', strings(0, 1), 'N', zeros(0, 1), ...
            'XLabel', "", 'YLabel', "", 'Note', "")
        Summary = table()
        MapInfo struct = struct('Dataset', "", 'Key', "", 'SurfaceOk', false, 'Mode', "", 'Cells', 0, ...
            'Lines', 0, 'Rejected', 0, 'DepthLines', 0, 'Message', "")
        StatusText char = ''
        SelectedRows double = zeros(1, 0)  % rows of the table
    end

    properties (Access = private)
        UseSettings logical = true
        Groups = table(strings(0, 1), strings(0, 1), strings(0, 1), 'VariableNames', {'Dataset', 'Subject', 'Group'})
        Factors string = cellanalysis.Project.FIXED_FACTORS
        Catalog = cellanalysis.Measure.catalog()
        Population char = 'kept'
        ColocUm double = 10
        MinDepthUm double = 0              % cells closer to the brain surface are rejected (0 = none)
        Timers struct = struct()
        Pending struct = struct()
        Tips struct = struct()             % tag -> the control's tooltip when it is enabled
        MapCache struct = struct('Key', {}, 'Img', {}, 'Scale', {}, 'Surface', {})
        MapHandles struct = struct()
        PickAreas logical = false
        Busy logical = false
        DbState struct = struct('ok', false, 'why', 'the lab database client is not usable here.')

        ParentDirEdit
        BrowseButton
        ScanButton
        MeasureSelectedButton
        MeasureAllButton
        ExportCellsButton
        ExportSummaryButton
        SaveFigureButton
        KindDropDown
        PopulationDropDown
        ColocEdit
        MinDepthEdit
        SectionTable
        UseAllButton
        UseNoneButton
        SetGroupButton
        ImportGroupsButton
        CheckSubjectsButton
        UseTagsEdit
        DetailLabel
        Tabs
        DistTab
        SectionTab
        PlotDropDown
        MetricDropDown
        XMetricDropDown
        GroupByDropDown
        UnitDropDown
        ScopeDropDown
        BinEdit
        PlotAxes
        SummaryTable
        SurfaceDropDown
        TraceButton
        PickAreasButton
        MapAxes
        StatusLabel
    end

    %% ===================================================================
    %  Construction
    %  ===================================================================
    methods
        function obj = CellAnalysis(parentDir, opts)
            arguments
                parentDir {mustBeText} = ''
                opts.UseSettings (1,1) logical = true
                opts.Scan {mustBeMember(opts.Scan, {'deferred', 'now', 'none'})} = 'deferred'
            end
            obj.UseSettings = opts.UseSettings;
            obj.DbState = obj.databaseUsable();
            obj.buildUI();
            obj.loadPreferences();
            parentDir = char(parentDir);
            if isempty(parentDir) && obj.UseSettings
                parentDir = char(obj.ParentDirEdit.Value);
                opts.Scan = 'none';          % a remembered folder is shown, not scanned unasked
            end
            if ~isempty(parentDir) && isfolder(parentDir)
                obj.ParentDirEdit.Value = parentDir;
                obj.ParentDirectory = parentDir;
                switch char(opts.Scan)
                    case 'now'
                        obj.scanFolder(parentDir);
                    case 'deferred'
                        obj.setStatus('Opening... the scan starts in a moment.');
                        obj.defer('scan', 0.25, @() obj.scanFolder(parentDir));
                end
            end
            obj.updateControls();
            if height(obj.Sources) == 0
                obj.refreshPlot();
            end
        end

        function delete(obj)
            obj.cancelAllDeferred();
            cellanalysis.Project.clearCache();
            if ~isempty(obj.Figure) && isvalid(obj.Figure)
                try
                    delete(obj.Figure);
                catch
                end
            end
        end
    end

    %% ===================================================================
    %  Seams: the window's own actions, without dialogs
    %  ===================================================================
    methods

        function scanFolder(obj, parentDir)
            % Find the sections below parentDir, read what is measured, and show it.
            parentDir = char(parentDir);
            if isempty(parentDir) || ~isfolder(parentDir)
                obj.setStatus('Choose a folder that holds sections (Browse...).');
                return
            end
            obj.cancelDeferred('scan');
            obj.ParentDirectory = parentDir;
            obj.ParentDirEdit.Value = parentDir;
            obj.setStatus('Scanning...');
            drawnow;
            keepUse = containers.Map('KeyType', 'char', 'ValueType', 'logical');
            for i = 1:height(obj.Sources)
                keepUse(char(obj.Sources.Folder(i) + "|" + obj.Sources.Dataset(i) + "|" + obj.Sources.Key(i))) = obj.Use(i);
            end
            try
                S = cellanalysis.Project.sources(parentDir);
            catch ME
                obj.setStatus(['Could not scan: ' ME.message]);
                return
            end
            obj.DbState = obj.databaseUsable();
            obj.Groups = cellanalysis.Project.readGroups(parentDir);
            [S, obj.Factors] = cellanalysis.Project.applyGroups(S, obj.Groups);
            obj.Sources = S;
            obj.DbColumns = cellanalysis.Project.databaseColumns(S);
            obj.Use = true(height(S), 1);
            for i = 1:height(S)
                k = char(S.Folder(i) + "|" + S.Dataset(i) + "|" + S.Key(i));
                if isKey(keepUse, k), obj.Use(i) = keepUse(k); end
            end
            obj.MapCache(:) = [];
            obj.refreshKinds();
            obj.SelectedRows = zeros(1, 0);
            obj.reload();
            n = numel(unique(S.Folder + "|" + S.Dataset));
            if height(S) == 0
                obj.setStatus('No section with detections was found below this folder. Run Cell Discovery first.');
            else
                nNone = nnz(S.State == "none"); nStale = nnz(S.State == "stale");
                msg = sprintf('%d sections, %d sources.', n, height(S));
                if nNone > 0, msg = [msg sprintf(' %d not measured yet: Measure all.', nNone)]; end
                if nStale > 0, msg = [msg sprintf(' %d out of date.', nStale)]; end
                if obj.MinDepthUm > 0
                    msg = [msg sprintf(' Cells within %g um of the brain surface are rejected (Reject near surface).', obj.MinDepthUm)];
                end
                obj.setStatus(msg);
            end
        end

        function setKind(obj, kind)
            % The cell type whose sources the table lists: "pnn", "pv" or a source key.
            kind = string(kind);
            data = string(obj.KindDropDown.ItemsData);
            if ~any(data == kind), return; end
            obj.KindDropDown.Value = char(kind);
            obj.Kind = kind;
            obj.SelectedRows = zeros(1, 0);
            obj.refreshMetricItems();
            obj.reload();
        end

        function setPopulation(obj, population)
            population = lower(char(population));
            if ~any(strcmp(population, obj.POPULATION_DATA)), return; end
            obj.Population = population;
            obj.PopulationDropDown.Value = population;
            obj.reload();
        end

        function setColocUm(obj, um)
            if ~(isnumeric(um) && isscalar(um) && isfinite(um) && um >= 0 && um <= 200), return; end
            obj.ColocUm = double(um);
            obj.ColocEdit.Value = obj.ColocUm;
            obj.reload();
        end

        function setMinDepthUm(obj, um)
            % Reject every cell closer than UM micrometers to the brain surface (0 = reject none):
            % it is left out of the plots, the tables, the pairing and the exports, in both
            % channels, and the tissue that close to the surface is left out of the densities.
            % Cells of a section without a surface are kept. No measurement is needed.
            if ~(isnumeric(um) && isscalar(um) && isfinite(um) && um >= 0 && um <= 2000), return; end
            obj.MinDepthUm = double(um);
            obj.MinDepthEdit.Value = obj.MinDepthUm;
            obj.reload();
            obj.setStatus(obj.nearSurfaceText());
        end

        function setUse(obj, rows, tf)
            % Check or uncheck sections: rows of the table, or "all".
            if (ischar(rows) || isstring(rows))
                rows = 1:numel(obj.Rows);
            end
            rows = rows(rows >= 1 & rows <= numel(obj.Rows));
            obj.Use(obj.Rows(rows)) = logical(tf);
            obj.refreshTable();
            obj.refreshPlot();
        end

        function tf = selectSection(obj, which)
            % Select one section: a row of the table, or a dataset base.
            tf = false;
            if ischar(which) || isstring(which)
                r = find(obj.Sources.Dataset(obj.Rows) == string(which), 1);
            else
                r = which;
            end
            if isempty(r) || r < 1 || r > numel(obj.Rows), return; end
            obj.SelectedRows = r;
            try
                obj.SectionTable.Selection = r;
            catch
            end
            obj.onSelectionChanged();
            tf = true;
        end

        function n = measure(obj, which, force)
            % Measure sections: "selected" (the selected rows), "checked" (the checked rows)
            % or "all" (every section below the folder). Both channels of a section are
            % measured together. Returns the number of sources measured.
            if nargin < 3, force = false; end
            n = 0;
            S = obj.Sources;
            switch lower(char(which))
                case 'selected'
                    rows = obj.Rows(obj.SelectedRows);
                case 'checked'
                    rows = obj.Rows(obj.Use(obj.Rows));
                case 'all'
                    rows = (1:height(S))';
                otherwise
                    error('CellAnalysis:which', 'measure: "selected", "checked" or "all".');
            end
            if isempty(rows)
                obj.setStatus('Nothing to measure: select or check a section first.');
                return
            end
            ds = unique(S.Folder(rows) + "|" + S.Dataset(rows), 'stable');
            todo = find(ismember(S.Folder + "|" + S.Dataset, ds));
            if ~force
                todo = todo(S.State(todo) ~= "current");
            end
            if isempty(todo)
                obj.setStatus('Those sections are measured and up to date. Nothing to do.');
                return
            end
            obj.Busy = true;
            obj.updateControls();
            dlg = [];
            if numel(todo) > 1
                try
                    dlg = uiprogressdlg(obj.Figure, 'Title', 'Measuring cells', 'Cancelable', 'on', ...
                        'Message', 'Starting...');
                catch
                    dlg = [];
                end
            end
            failed = strings(0, 1);
            canceled = false;
            loaded = [];
            lastDs = "";
            tStart = tic;
            for q = 1:numel(todo)
                i = todo(q);
                if ~isempty(dlg) && isvalid(dlg)
                    if dlg.CancelRequested, canceled = true; break; end
                    dlg.Value = (q - 1) / numel(todo);
                    dlg.Message = sprintf('%s  %s  (%d of %d)', S.Section(i), S.Key(i), q, numel(todo));
                end
                obj.setStatus(sprintf('Measuring %s %s (%d of %d)...', S.Section(i), S.Key(i), q, numel(todo)));
                drawnow;
                thisDs = S.Folder(i) + "|" + S.Dataset(i);
                if thisDs ~= lastDs, loaded = []; end
                lastDs = thisDs;
                try
                    [~, ~, loaded] = cellanalysis.Project.measure(S(i, :), struct('Force', force, 'Loaded', loaded));
                    n = n + 1;
                catch ME
                    failed(end + 1, 1) = S.Section(i) + " " + S.Key(i) + ": " + string(ME.message); %#ok<AGROW>
                end
            end
            if ~isempty(dlg) && isvalid(dlg), close(dlg); end
            obj.Busy = false;
            obj.Sources = cellanalysis.Project.refreshState(obj.Sources, todo);
            obj.reload();
            msg = sprintf('Measured %d source(s) in %.0f s.', n, toc(tStart));
            if canceled, msg = [msg ' Stopped: the rest is left as it was.']; end
            if ~isempty(failed)
                msg = [msg sprintf(' %d failed: %s', numel(failed), char(failed(1)))];
            end
            obj.setStatus(msg);
        end

        function setGroup(obj, rows, name)
            % Give the sections of these table rows the group NAME ('' clears it).
            rows = rows(rows >= 1 & rows <= numel(obj.Rows));
            if isempty(rows), return; end
            obj.Groups = cellanalysis.Project.setGroup(obj.Groups, obj.Sources, obj.Rows(rows), name, "Group");
            obj.groupsChanged();
            obj.setStatus(sprintf('Group "%s" set for %d section(s). Kept in %s in the scanned folder.', ...
                char(name), numel(rows), cellanalysis.Project.GROUPS_FILE));
        end

        function rep = importGroups(obj, file)
            % Take groupings from a spreadsheet or CSV (cellanalysis.Project.importGroups).
            [obj.Groups, rep] = cellanalysis.Project.importGroups(obj.Groups, obj.Sources, file);
            obj.groupsChanged();
            obj.setStatus(char(rep.message));
        end

        function r = checkSubjects(obj)
            % The Check subjects button: ask the lab database about the subjects the file names
            % here name (which it has, their sex, species and project, their tags and their
            % variables; a few seconds at most), then group and plot by the renewed answers.
            r = struct('ok', false, 'asked', 0, 'missing', strings(0, 1), 'message', "", 'tagsRead', false);
            ids = unique(obj.Sources.Subject(strlength(obj.Sources.Subject) > 0));
            obj.setStatus(sprintf('Asking the lab database about %d subject(s)...', numel(ids)));
            drawnow;
            try
                r = celldb.refreshSubjects(ids);
            catch ME
                r.message = "Subjects not checked: " + string(ME.message);
            end
            obj.DbState = obj.databaseUsable();
            obj.databaseChanged();
            obj.setStatus(char(r.message));
        end

        function n = useByTags(obj, expr)
            % Check exactly the listed sections whose subject passes the tag filter EXPR (the lab
            % database's grammar: "cohort:a -qc:fail topic:*"; celldb.tagFilter) and uncheck the
            % others. An empty filter changes nothing. Returns the number of sections checked.
            expr = strtrim(char(expr));
            obj.UseTagsEdit.Value = expr;
            rows = obj.Rows;
            n = nnz(obj.Use(rows));
            if isempty(expr) || isempty(rows), return; end
            [keep, note] = celldb.tagFilter(obj.Sources.Subject(rows), expr);
            obj.Use(rows) = keep;
            n = nnz(keep);
            obj.refreshTable();
            obj.refreshPlot();
            obj.setStatus(strtrim(sprintf('%d of %d section(s) checked by the tags "%s". %s', n, numel(rows), expr, note)));
        end

        function setPlot(obj, name)
            if ~any(strcmp(char(name), obj.PLOTS)), return; end
            obj.PlotDropDown.Value = char(name);
            obj.updateControls();
            obj.refreshPlot();
        end

        function setMetric(obj, name)
            if ~any(string(obj.MetricDropDown.ItemsData) == string(name)), return; end
            obj.MetricDropDown.Value = char(name);
            obj.onMetricChanged();
        end

        function setXMetric(obj, name)
            if ~any(string(obj.XMetricDropDown.ItemsData) == string(name)), return; end
            obj.XMetricDropDown.Value = char(name);
            obj.refreshPlot();
        end

        function setGroupBy(obj, name)
            name = string(name);
            if strlength(name) == 0, name = "none"; end
            if ~any(string(obj.GroupByDropDown.ItemsData) == name), return; end
            obj.GroupByDropDown.Value = char(name);
            obj.refreshPlot();
        end

        function setUnit(obj, unit)
            unit = lower(char(unit));
            if ~any(strcmp(unit, obj.UNIT_DATA)), return; end
            obj.UnitDropDown.Value = unit;
            obj.refreshPlot();
        end

        function setScope(obj, scope)
            scope = lower(char(scope));
            if ~any(strcmp(scope, obj.SCOPE_DATA)), return; end
            obj.ScopeDropDown.Value = scope;
            obj.refreshPlot();
        end

        function setBinUm(obj, um)
            if ~(isnumeric(um) && isscalar(um) && isfinite(um) && um > 0), return; end
            step = cellanalysis.Project.DEPTH_STEP_UM;
            obj.BinEdit.Value = max(step, round(um / step) * step);
            obj.refreshPlot();
        end

        function showTab(obj, name)
            if strcmpi(char(name), 'Section')
                obj.Tabs.SelectedTab = obj.SectionTab;
            else
                obj.Tabs.SelectedTab = obj.DistTab;
            end
            obj.onTabChanged();
        end

        function setSurfaceMode(obj, mode)
            % How the brain surface of the selected section is defined.
            src = obj.selectedSource();
            if isempty(src), return; end
            mode = lower(char(mode));
            if ~any(strcmp(mode, obj.SURFACE_DATA)), return; end
            cellanalysis.Project.setSurface(src, struct('mode', mode));
            obj.surfaceChanged(src);
        end

        function setSurfaceLine(obj, xy)
            % The traced surface of the selected section: M x 2 [X Y] in full-resolution pixels.
            src = obj.selectedSource();
            if isempty(src), return; end
            cellanalysis.Project.setSurface(src, struct('mode', 'traced', 'line', xy));
            obj.surfaceChanged(src);
        end

        function tf = toggleSurfaceArea(obj, xy)
            % Switch the empty area holding the point xy (full-resolution pixels) on or off as
            % brain surface (automatic surface only). False when the point is on tissue.
            tf = false;
            src = obj.selectedSource();
            if isempty(src), return; end
            def = cellanalysis.Project.surfaceDef(src);
            if def.mode ~= "auto"
                obj.setStatus('Empty areas can be switched on and off only with the automatic surface (Surface: Automatic).');
                return
            end
            entry = obj.mapEntry(src);
            Sf = entry.Surface;
            k = cellanalysis.Surface.areaAt(Sf, xy);
            if k == 0
                obj.setStatus('That is tissue. Click an empty area to switch its edge on or off as brain surface.');
                return
            end
            inK = @(pts) arrayfun(@(r) cellanalysis.Surface.areaAt(Sf, pts(r, :)) == k, (1:size(pts, 1))');
            incK = logical(inK(def.include));
            excK = logical(inK(def.exclude));
            inc = def.include(~incK, :);
            exc = def.exclude(~excK, :);
            % an earlier click on this area is taken back; only an area that is as the automatic
            % choice left it gets a new point
            if Sf.AreaUsed(k)
                what = 'off';
                if ~any(incK), exc(end + 1, :) = reshape(double(xy), 1, 2); end
            else
                what = 'on';
                if ~any(excK), inc(end + 1, :) = reshape(double(xy), 1, 2); end
            end
            cellanalysis.Project.setSurface(src, struct('include', inc, 'exclude', exc));
            obj.surfaceChanged(src);
            obj.setStatus(sprintf(['That empty area is switched %s as brain surface. Distances of this section are ' ...
                'out of date until it is measured again (Measure selected).'], what));
            tf = true;
        end

        function file = exportCells(obj, file)
            % Write the cells behind the plot, one row per cell with the section's tags and
            % every metric, to a CSV.
            file = char(file);
            T = obj.View;
            if isempty(T)
                obj.setStatus('There are no measured cells to export.');
                file = '';
                return
            end
            if ismember('SourceRow', T.Properties.VariableNames), T.SourceRow = []; end
            for v = string(T.Properties.VariableNames)
                if islogical(T.(v)), T.(v) = double(T.(v)); end
            end
            writetable(T, file);
            obj.setStatus(sprintf('%d cells written to %s.', height(T), file));
        end

        function file = exportSummary(obj, file)
            % Write one row per section: its tags, the number of cells, the cells of the other
            % channel, the pairs and the tissue area, and the median of every metric (the
            % fraction for Colocalized and for Colocalized by chance).
            file = char(file);
            T = obj.sectionSummary();
            if isempty(T)
                obj.setStatus('There are no measured cells to summarize.');
                file = '';
                return
            end
            writetable(T, file);
            obj.setStatus(sprintf('%d sections written to %s.', height(T), file));
        end

        function file = saveFigure(obj, file)
            % Save what the visible tab shows (PNG, PDF, SVG, ... by the file's extension).
            file = char(file);
            if obj.Tabs.SelectedTab == obj.SectionTab, ax = obj.MapAxes; else, ax = obj.PlotAxes; end
            exportgraphics(ax, file, 'Resolution', 200);
            obj.setStatus(['Figure saved to ' file '.']);
        end

        function handled = handleKey(obj, key, modifiers)
            % What the window's key handler does: F5 scans, Ctrl+M measures the selected
            % sections, Ctrl+E exports the cells (asks for a file).
            if nargin < 3, modifiers = {}; end
            handled = true;
            ctrl = any(strcmp(modifiers, 'control'));
            switch lower(char(key))
                case 'f5'
                    obj.scanFolder(obj.ParentDirEdit.Value);
                case 'm'
                    if ctrl, obj.measure('selected', false); else, handled = false; end
                case 'e'
                    if ctrl, obj.onExportCells(); else, handled = false; end
                otherwise
                    handled = false;
            end
        end

        function waitForIdle(obj)
            % Run now what is deferred (the first scan, the section map) and draw.
            drawnow;
            names = fieldnames(obj.Pending);
            for i = 1:numel(names)
                fcn = [];
                if isfield(obj.Pending, names{i}), fcn = obj.Pending.(names{i}); end
                obj.cancelDeferred(names{i});
                if ~isempty(fcn), fcn(); end
            end
            drawnow;
        end

        function addCloseListener(obj, fcn)
            if ~isempty(obj.Figure) && isvalid(obj.Figure)
                addlistener(obj.Figure, 'ObjectBeingDestroyed', @(~, ~) fcn());
            end
        end

        function src = selectedSource(obj)
            % The source (a row of Sources, as a table) of the first selected section; [] = none.
            src = [];
            if isempty(obj.SelectedRows), return; end
            r = obj.SelectedRows(1);
            if r < 1 || r > numel(obj.Rows), return; end
            src = obj.Sources(obj.Rows(r), :);
        end

    end

    %% ===================================================================
    %  The window
    %  ===================================================================
    methods (Access = private)

        function buildUI(obj)
            obj.Figure = uifigure('Name', 'Cell Analysis', 'Position', [70 70 1640 900]);
            obj.Figure.CloseRequestFcn = @(s, e) obj.onClosing();
            obj.Figure.WindowKeyPressFcn = @(s, e) obj.handleKey(e.Key, e.Modifier);
            root = uigridlayout(obj.Figure, [3 1]);
            root.RowHeight = {'fit', '1x', 'fit'};
            root.ColumnWidth = {'1x'};

            % ---- toolbar -------------------------------------------------------------------------
            tb = uigridlayout(root, [1 9]);
            tb.Layout.Row = 1;
            tb.ColumnWidth = {'fit', '1x', 'fit', 'fit', 'fit', 'fit', 'fit', 'fit', 'fit'};
            tb.Padding = [4 4 4 4];
            uilabel(tb, 'Text', 'Parent directory:', 'HorizontalAlignment', 'right');
            obj.ParentDirEdit = uieditfield(tb, 'text', 'Tag', 'edit:parent', ...
                'ValueChangedFcn', @(s, e) obj.scanFolder(s.Value));
            obj.tip(obj.ParentDirEdit, ['Folder that holds the sections (every folder below it is searched). ' ...
                'Press Enter to scan it.']);
            obj.BrowseButton = uibutton(tb, 'Text', 'Browse...', 'Tag', 'btn:browse', ...
                'ButtonPushedFcn', @(s, e) obj.onBrowse());
            obj.tip(obj.BrowseButton, 'Choose the folder that holds the sections, then scan it.');
            obj.ScanButton = uibutton(tb, 'Text', 'Scan [F5]', 'Tag', 'btn:scan', ...
                'ButtonPushedFcn', @(s, e) obj.scanFolder(obj.ParentDirEdit.Value));
            obj.tip(obj.ScanButton, ['Find the sections below the folder again and re-read which are measured ' ...
                'and which are out of date (F5). Nothing is measured or written by a scan.']);
            obj.MeasureSelectedButton = uibutton(tb, 'Text', 'Measure selected [Ctrl+M]', 'Tag', 'btn:measureSelected', ...
                'ButtonPushedFcn', @(s, e) obj.measure('selected', false));
            obj.tip(obj.MeasureSelectedButton, ['Measure the cells of the selected sections, both channels: distance ' ...
                'from the brain surface, luminance and morphology (Ctrl+M). Cells that were measured before and did ' ...
                'not move are not measured again. The results are kept beside the data in <stem>_metrics.csv.']);
            obj.MeasureAllButton = uibutton(tb, 'Text', 'Measure all', 'FontWeight', 'bold', 'Tag', 'btn:measureAll', ...
                'ButtonPushedFcn', @(s, e) obj.measure('all', false));
            obj.tip(obj.MeasureAllButton, ['Measure every section below the folder that is not measured yet or is ' ...
                'out of date. About three seconds per channel; it can be stopped and continued later.']);
            obj.ExportCellsButton = uibutton(tb, 'Text', 'Export cells... [Ctrl+E]', 'Tag', 'btn:exportCells', ...
                'ButtonPushedFcn', @(s, e) obj.onExportCells());
            obj.tip(obj.ExportCellsButton, ['Write the cells behind the plot to a CSV: one row per cell with its ' ...
                'section, subject, groups and every metric (Ctrl+E). For statistics in R, Python or Prism.']);
            obj.ExportSummaryButton = uibutton(tb, 'Text', 'Export sections...', 'Tag', 'btn:exportSummary', ...
                'ButtonPushedFcn', @(s, e) obj.onExportSummary());
            obj.tip(obj.ExportSummaryButton, ['Write one row per section to a CSV: its subject and groups, the number ' ...
                'of cells, and the median of every metric (the fraction of colocalized cells).']);
            obj.SaveFigureButton = uibutton(tb, 'Text', 'Save figure...', 'Tag', 'btn:saveFigure', ...
                'ButtonPushedFcn', @(s, e) obj.onSaveFigure());
            obj.tip(obj.SaveFigureButton, 'Save the plot or the section map of the visible tab as PNG, PDF or SVG.');

            % ---- content ---------------------------------------------------------------------------
            content = uigridlayout(root, [1 2]);
            content.Layout.Row = 2;
            content.ColumnWidth = {610, '1x'};
            content.ColumnSpacing = 6;
            content.Padding = [4 0 4 0];

            left = uipanel(content, 'Title', 'Sections');
            lg = uigridlayout(left, [6 1]);
            lg.RowHeight = {'fit', 'fit', '1x', 'fit', 'fit', 'fit'};
            lg.RowSpacing = 6;

            fr = uigridlayout(lg, [1 4]);
            fr.ColumnWidth = {'fit', '1x', 'fit', '1x'};
            fr.Padding = [0 0 0 0];
            uilabel(fr, 'Text', 'Cell type:', 'HorizontalAlignment', 'right');
            obj.KindDropDown = uidropdown(fr, 'Items', {'PNN (WFA)'}, 'ItemsData', {'pnn'}, 'Tag', 'dd:kind', ...
                'ValueChangedFcn', @(s, e) obj.setKind(s.Value));
            obj.tip(obj.KindDropDown, ['Which cells to analyze: perineuronal nets (WFA; channels named ECM, PNN or WFA), ' ...
                'PV cells, or another channel by its name. One cell type is analyzed at a time; the other channel ' ...
                'of each section is used for colocalization.']);
            uilabel(fr, 'Text', 'Cells:', 'HorizontalAlignment', 'right');
            obj.PopulationDropDown = uidropdown(fr, 'Items', obj.POPULATION_ITEMS, 'ItemsData', obj.POPULATION_DATA, ...
                'Tag', 'dd:population', 'ValueChangedFcn', @(s, e) obj.setPopulation(s.Value));
            obj.tip(obj.PopulationDropDown, ['Kept cells: only the cells a person kept in Cell Curator (labeled Good, ' ...
                'reviewed, outside exclusion regions). All detections: every candidate that is not merged, stale or ' ...
                'excluded, reviewed or not; use it for sections that are not curated yet.']);
            fr2 = uigridlayout(lg, [1 5]);
            fr2.ColumnWidth = {'fit', 60, 'fit', 60, '1x'};
            fr2.Padding = [0 0 0 0];
            uilabel(fr2, 'Text', 'Coloc. within (um):', 'HorizontalAlignment', 'right');
            obj.ColocEdit = uieditfield(fr2, 'numeric', 'Value', obj.ColocUm, 'Limits', [0 200], 'Tag', 'edit:coloc', ...
                'ValueChangedFcn', @(s, e) obj.setColocUm(s.Value));
            obj.tip(obj.ColocEdit, ['A cell counts as colocalized when it is paired with a cell of the section''s other ' ...
                'channel no farther than this many micrometers from its center. Cells are paired one to one, the ' ...
                'closest first, so a PV cell is the partner of one net at most. To choose the distance, plot the ' ...
                'histogram of "Nearest cell of other channel": true pairs pile up at a few micrometers. Changing it ' ...
                'needs no new measurement.']);
            uilabel(fr2, 'Text', 'Reject near surface (um):', 'HorizontalAlignment', 'right');
            obj.MinDepthEdit = uieditfield(fr2, 'numeric', 'Value', obj.MinDepthUm, 'Limits', [0 2000], ...
                'Tag', 'edit:minDepth', 'ValueChangedFcn', @(s, e) obj.setMinDepthUm(s.Value));
            obj.tip(obj.MinDepthEdit, ['Reject every cell closer than this many micrometers to the brain surface, ' ...
                'for example the bright rim of stain along the pia: those cells are left out of the plots, the ' ...
                'list, the pairing with the other channel and the exports, and the tissue that close to the surface ' ...
                'is left out of the densities. 0 rejects none. Sections whose surface was not found keep all their ' ...
                'cells. On the Section tab a dashed line marks the border and crosses the rejected cells. Changing ' ...
                'it needs no new measurement, and the curation is not changed.']);

            obj.SectionTable = uitable(lg, 'ColumnName', obj.COLUMNS, 'Tag', 'table:sections', ...
                'ColumnEditable', [true false false true false false false], ...
                'ColumnSortable', false, 'ColumnWidth', {40, 96, '1x', 110, 60, 86, 96}, ...
                'RowName', {}, 'SelectionType', 'row', 'Multiselect', 'on', ...
                'CellEditCallback', @(s, e) obj.onTableEdit(e), ...
                'SelectionChangedFcn', @(s, e) obj.onTableSelection(e));
            obj.tip(obj.SectionTable, ['One row per section that has the chosen cell type. Use: uncheck a section to ' ...
                'leave it out of the plots and exports. Group: type a name to group sections yourself (kept in ' ...
                'cellanalysis_groups.csv in the scanned folder). Cells: cells of the chosen kind and population, ' ...
                'without those rejected near the surface. ' ...
                'Measured: yes, out of date (its curation, image or surface changed since) or no. Surface: how the ' ...
                'brain surface is defined. Select a row to see the section on the Section tab; select several to ' ...
                'measure them or to set their group.']);

            br = uigridlayout(lg, [1 5]);
            br.Padding = [0 0 0 0];
            br.ColumnSpacing = 6;
            obj.UseAllButton = uibutton(br, 'Text', 'Use all', 'Tag', 'btn:useAll', ...
                'ButtonPushedFcn', @(s, e) obj.setUse("all", true));
            obj.tip(obj.UseAllButton, 'Check every section of the list, so all take part in the plots and exports.');
            obj.UseNoneButton = uibutton(br, 'Text', 'Use none', 'Tag', 'btn:useNone', ...
                'ButtonPushedFcn', @(s, e) obj.setUse("all", false));
            obj.tip(obj.UseNoneButton, 'Uncheck every section of the list; then check the ones to compare.');
            obj.SetGroupButton = uibutton(br, 'Text', 'Set group...', 'Tag', 'btn:setGroup', ...
                'ButtonPushedFcn', @(s, e) obj.onSetGroup());
            obj.tip(obj.SetGroupButton, ['Give the selected sections a group name in one step (for example "control" ' ...
                'or "noise-exposed"). Select several rows with Shift or Ctrl first.']);
            obj.ImportGroupsButton = uibutton(br, 'Text', 'Import groups...', 'Tag', 'btn:importGroups', ...
                'ButtonPushedFcn', @(s, e) obj.onImportGroups());
            obj.tip(obj.ImportGroupsButton, ['Read groupings from a spreadsheet or CSV: one column names the subject ' ...
                '(Subject, SubjectID, Animal) or the section (Dataset, Section, Image Filename); every other column ' ...
                'becomes a grouping you can choose under "Group by" (treatment, age, atlas plate, ...).']);
            obj.CheckSubjectsButton = uibutton(br, 'Text', 'Check subjects', 'Tag', 'btn:checkSubjects', ...
                'ButtonPushedFcn', @(s, e) obj.checkSubjects());
            obj.tip(obj.CheckSubjectsButton, ['Ask the lab database about the subjects (SUBJ-ID) the file names here ' ...
                'name: their sex, species and project, their tags (cohort:a, pilot, ...) and their variables (age, ' ...
                'dose, ...). A few seconds at most; the answers are kept on this computer and then offered under ' ...
                '"Group by", "Metric" and "Against (scatter)". Nothing else here asks the server.']);

            tr = uigridlayout(lg, [1 2]);
            tr.ColumnWidth = {'fit', '1x'};
            tr.Padding = [0 0 0 0];
            uilabel(tr, 'Text', 'Use by tags:', 'HorizontalAlignment', 'right');
            obj.UseTagsEdit = uieditfield(tr, 'text', 'Tag', 'edit:useTags', 'Placeholder', 'cohort:a -qc:fail', ...
                'ValueChangedFcn', @(s, e) obj.useByTags(s.Value));
            obj.tip(obj.UseTagsEdit, ['Check the sections by the lab database tags of their subject and uncheck the ' ...
                'others; press Enter. Tags separated by spaces must all hold; a leading "-" means "does not have"; ' ...
                '"cohort:*" means any tag of that namespace; a bare word is a bare tag. Example: cohort:a -qc:fail. ' ...
                'Subjects that were never checked are left out (Check subjects). The status line says when a tag ' ...
                'is carried by no subject here.']);

            obj.DetailLabel = uilabel(lg, 'Text', 'No section selected.', 'WordWrap', 'on', 'Tag', 'label:detail', ...
                'VerticalAlignment', 'top', 'FontColor', [0.3 0.3 0.3]);

            obj.Tabs = uitabgroup(content, 'SelectionChangedFcn', @(s, e) obj.onTabChanged());
            obj.DistTab = uitab(obj.Tabs, 'Title', 'Distributions', 'Tag', 'tab:distributions');
            obj.tip(obj.DistTab, ['Histograms, cumulative distributions, box plots, depth profiles and scatter plots ' ...
                'of any metric, for the checked sections or the selected one, with a table of the numbers.']);
            obj.SectionTab = uitab(obj.Tabs, 'Title', 'Section', 'Tag', 'tab:section');
            obj.tip(obj.SectionTab, ['The selected section with its brain surface and its cells colored by the ' ...
                'chosen metric. The surface is checked and corrected here.']);

            % ---- distributions tab -----------------------------------------------------------------
            dg = uigridlayout(obj.DistTab, [3 1]);
            dg.RowHeight = {'fit', '1x', 170};
            cr = uigridlayout(dg, [2 7]);
            cr.RowHeight = {'fit', 'fit'};
            cr.ColumnWidth = {'1x', '1.4x', '1.4x', '1x', '1x', '1x', 70};
            cr.Padding = [0 0 0 0];
            cr.RowSpacing = 2;
            heads = {'Plot', 'Metric', 'Against (scatter)', 'Group by', 'One point per', 'Sections', 'Bin (um)'};
            for i = 1:numel(heads)
                h = uilabel(cr, 'Text', heads{i}, 'FontColor', [0.35 0.35 0.35]);
                h.Layout.Row = 1; h.Layout.Column = i;
            end
            obj.PlotDropDown = uidropdown(cr, 'Items', obj.PLOTS, 'Tag', 'dd:plot', ...
                'ValueChangedFcn', @(s, e) obj.setPlot(s.Value));
            obj.tip(obj.PlotDropDown, ['Histogram: how the values are spread (shares per group when grouped). ' ...
                'Cumulative: the share of cells at or below each value; the clearest way to compare groups. ' ...
                'Box by group: median, quartiles and whiskers. Metric by depth: the metric against the distance ' ...
                'from the brain surface. Cell density by depth: cells per mm^2 of tissue at each depth. ' ...
                'Colocalization: the share of these cells that are paired with a cell of the other channel, the ' ...
                'share of the other channel''s cells that are paired with one of these, and the share chance ' ...
                'alone would give, per group. Scatter: one metric against another.']);
            obj.MetricDropDown = uidropdown(cr, 'Items', {'Distance from brain surface (um)'}, ...
                'ItemsData', {'SurfaceDistUm'}, 'Tag', 'dd:metric', 'ValueChangedFcn', @(s, e) obj.onMetricChanged());
            obj.XMetricDropDown = uidropdown(cr, 'Items', {'Distance from brain surface (um)'}, ...
                'ItemsData', {'SurfaceDistUm'}, 'Tag', 'dd:xmetric', 'ValueChangedFcn', @(s, e) obj.refreshPlot());
            obj.GroupByDropDown = uidropdown(cr, 'Items', {'No grouping'}, 'ItemsData', {'none'}, 'Tag', 'dd:groupBy', ...
                'ValueChangedFcn', @(s, e) obj.refreshPlot());
            obj.tip(obj.GroupByDropDown, ['What the sections (or cells) are grouped by. From the file names: section, ' ...
                'subject, hemisphere, stain. From the lab database (when this computer has asked it about the ' ...
                'subject: Check subjects): sex, species, project, each tag namespace (Tag: cohort), each bare tag ' ...
                '(Tag: pilot) and each variable (Variable: housing). Yours: Group and the columns you imported. ' ...
                'Colocalized splits the cells of each section by whether a cell of the other channel is at the ' ...
                'same place.']);
            obj.UnitDropDown = uidropdown(cr, 'Items', obj.UNIT_ITEMS, 'ItemsData', obj.UNIT_DATA, 'Tag', 'dd:unit', ...
                'ValueChangedFcn', @(s, e) obj.refreshPlot());
            obj.ScopeDropDown = uidropdown(cr, 'Items', obj.SCOPE_ITEMS, 'ItemsData', obj.SCOPE_DATA, 'Tag', 'dd:scope', ...
                'ValueChangedFcn', @(s, e) obj.refreshPlot());
            obj.tip(obj.ScopeDropDown, ['Checked sections: every section checked in the list (across sections). ' ...
                'Selected section: only the section selected in the list (within a section).']);
            obj.BinEdit = uieditfield(cr, 'numeric', 'Value', 50, 'Limits', [25 1000], 'Tag', 'edit:bin', ...
                'ValueChangedFcn', @(s, e) obj.setBinUm(s.Value));
            ctrls = {obj.PlotDropDown, obj.MetricDropDown, obj.XMetricDropDown, obj.GroupByDropDown, ...
                obj.UnitDropDown, obj.ScopeDropDown, obj.BinEdit};
            for i = 1:numel(ctrls)
                ctrls{i}.Layout.Row = 2; ctrls{i}.Layout.Column = i;
            end
            obj.PlotAxes = uiaxes(dg);
            obj.PlotAxes.Layout.Row = 2;
            obj.PlotAxes.Toolbar.Visible = 'on';
            obj.SummaryTable = uitable(dg, 'RowName', {}, 'ColumnSortable', true, 'Tag', 'table:summary', ...
                'ColumnWidth', {'1x', 84, 64, 64, 64, 90, 76, 90, 76, 100, 80});
            obj.SummaryTable.Layout.Row = 3;
            obj.tip(obj.SummaryTable, ['The numbers behind the plot, one row per group: N observations (cells, ' ...
                'sections or subjects, as chosen under "One point per"), the cells behind them, mean, standard ' ...
                'deviation, standard error, median, quartiles, minimum and maximum of the metric. For the ' ...
                'colocalization plot: sections, cells of each channel, pairs, the percentage of each channel that ' ...
                'is paired (mean of the sections, with its standard error), the percentage chance would give, and ' ...
                'how many times above chance the pairing is.']);

            % ---- section tab -----------------------------------------------------------------------
            sg = uigridlayout(obj.SectionTab, [2 1]);
            sg.RowHeight = {'fit', '1x'};
            sr = uigridlayout(sg, [1 5]);
            sr.ColumnWidth = {'fit', 170, 'fit', 'fit', '1x'};
            sr.Padding = [0 0 0 0];
            uilabel(sr, 'Text', 'Brain surface:', 'HorizontalAlignment', 'right');
            obj.SurfaceDropDown = uidropdown(sr, 'Items', obj.SURFACE_ITEMS, 'ItemsData', obj.SURFACE_DATA, ...
                'Tag', 'dd:surface', 'ValueChangedFcn', @(s, e) obj.setSurfaceMode(s.Value));
            obj.TraceButton = uibutton(sr, 'Text', 'Trace surface...', 'Tag', 'btn:trace', ...
                'ButtonPushedFcn', @(s, e) obj.onTrace());
            obj.PickAreasButton = uibutton(sr, 'state', 'Text', 'Pick empty areas', 'Tag', 'btn:pickAreas', ...
                'ValueChangedFcn', @(s, e) obj.onPickAreas(s.Value));
            uilabel(sr, 'Text', ['Red: the brain surface. Dotted blue: empty areas that are not surface. ' ...
                'Cells are colored by the metric chosen on the Distributions tab. Dashed red and red crosses: ' ...
                'the border of Reject near surface and the cells it rejects.'], ...
                'FontColor', [0.35 0.35 0.35], 'WordWrap', 'on');
            obj.MapAxes = uiaxes(sg);
            obj.MapAxes.Layout.Row = 2;
            obj.MapAxes.XTick = []; obj.MapAxes.YTick = [];

            % ---- status ----------------------------------------------------------------------------
            obj.StatusLabel = uilabel(root, 'Text', 'Choose a folder that holds sections (Browse...).');
            obj.StatusLabel.Layout.Row = 3;

            obj.refreshMetricItems();
            obj.refreshGroupItems();
        end

        % ------------------------------------------------------------------ tooltips and enabling

        function tip(obj, ctrl, txt)
            % Give a control its tooltip and remember it (see enable).
            txt = char(txt);
            tag = matlab.lang.makeValidName(char(ctrl.Tag));
            if ~isempty(ctrl.Tag), obj.Tips.(tag) = txt; end
            ctrl.Tooltip = txt;
        end

        function enable(obj, ctrl, tf, why)
            % Enable or disable a control; a disabled one says why in its tooltip.
            tag = matlab.lang.makeValidName(char(ctrl.Tag));
            base = '';
            if isfield(obj.Tips, tag), base = obj.Tips.(tag); end
            if tf
                en = 'on'; txt = base;
            else
                en = 'off'; txt = [base ' Unavailable now: ' char(why)];
            end
            if ~strcmp(char(ctrl.Enable), en), ctrl.Enable = en; end
            if ~strcmp(char(ctrl.Tooltip), txt), ctrl.Tooltip = txt; end
        end

        function updateControls(obj)
            % Which controls can be used now, and why not.
            if isempty(obj.Figure) || ~isvalid(obj.Figure), return; end
            has = height(obj.Sources) > 0;
            hasRows = ~isempty(obj.Rows);
            sel = ~isempty(obj.SelectedRows);
            cells = ~isempty(obj.Cells);
            noFolder = 'no folder is scanned yet.';
            noRows = 'no section with this cell type is listed.';
            noSel = 'no section is selected in the list.';
            noCells = 'no cells are measured yet (Measure all).';
            busy = 'a measurement is running.';
            obj.enable(obj.MeasureAllButton, has && ~obj.Busy, CellToolkit.ternary(obj.Busy, busy, noFolder));
            obj.enable(obj.MeasureSelectedButton, sel && ~obj.Busy, CellToolkit.ternary(obj.Busy, busy, noSel));
            obj.enable(obj.ExportCellsButton, cells, noCells);
            obj.enable(obj.ExportSummaryButton, cells, noCells);
            obj.enable(obj.SaveFigureButton, has, noFolder);
            obj.enable(obj.KindDropDown, has, noFolder);
            obj.enable(obj.PopulationDropDown, has, noFolder);
            obj.enable(obj.ColocEdit, has, noFolder);
            obj.enable(obj.MinDepthEdit, has, noFolder);
            obj.enable(obj.UseAllButton, hasRows, noRows);
            obj.enable(obj.UseNoneButton, hasRows, noRows);
            obj.enable(obj.SetGroupButton, sel, noSel);
            obj.enable(obj.ImportGroupsButton, has, noFolder);
            dbOk = obj.DbState.ok;
            dbWhy = obj.DbState.why;
            hasSubjects = has && any(strlength(obj.Sources.Subject) > 0);
            obj.enable(obj.CheckSubjectsButton, hasSubjects && dbOk && ~obj.Busy, CellToolkit.ternary(~has, noFolder, ...
                CellToolkit.ternary(~hasSubjects, 'no file name here names a subject (SUBJ-ID).', ...
                CellToolkit.ternary(obj.Busy, busy, dbWhy))));
            obj.enable(obj.UseTagsEdit, hasRows, noRows);
            plotKind = char(obj.PlotDropDown.Value);
            isDepth = any(strcmp(plotKind, {'Metric by depth', 'Cell density by depth'}));
            isScatter = strcmp(plotKind, 'Scatter');
            isDensity = strcmp(plotKind, 'Cell density by depth');
            isColoc = strcmp(plotKind, 'Colocalization');
            obj.enable(obj.MetricDropDown, ~isDensity && ~isColoc, CellToolkit.ternary(isColoc, ...
                'the colocalization plot counts pairs; it has no metric.', 'the density plot counts cells; it has no metric.'));
            obj.enable(obj.XMetricDropDown, isScatter, 'only the scatter plot has a second metric.');
            why = 'a depth profile is always one profile per section.';
            if isColoc, why = 'colocalization is always one value per section.'; end
            obj.enable(obj.UnitDropDown, ~isDepth && ~isColoc, why);
            obj.enable(obj.BinEdit, isDepth, 'only the depth profiles are binned by distance.');
            obj.enable(obj.SurfaceDropDown, sel, noSel);
            obj.enable(obj.TraceButton, sel, noSel);
            auto = sel && strcmp(char(obj.SurfaceDropDown.Value), 'auto');
            obj.enable(obj.PickAreasButton, auto, CellToolkit.ternary(sel, ...
                'empty areas are picked only with the automatic surface.', noSel));
        end

        % ------------------------------------------------------------------ dropdown contents

        function refreshKinds(obj)
            % The cell types found below the folder.
            S = obj.Sources;
            items = {}; data = {};
            if any(S.Kind == "pnn"), items{end + 1} = 'PNN (WFA)'; data{end + 1} = 'pnn'; end
            if any(S.Kind == "pv"), items{end + 1} = 'PV'; data{end + 1} = 'pv'; end
            for k = reshape(unique(S.Key(S.Kind == "unknown")), 1, [])
                items{end + 1} = char(k); data{end + 1} = char(k); %#ok<AGROW>
            end
            if isempty(items), items = {'PNN (WFA)'}; data = {'pnn'}; end
            obj.KindDropDown.Items = items;
            obj.KindDropDown.ItemsData = data;
            if ~any(strcmp(char(obj.Kind), data)), obj.Kind = string(data{1}); end
            obj.KindDropDown.Value = char(obj.Kind);
            obj.refreshMetricItems();
        end

        function refreshMetricItems(obj)
            % The metrics that exist for the cell type.
            C = obj.Catalog;
            if obj.Kind ~= "pnn", C = C(C.Kinds == "both", :); end
            labels = C.Label;
            withUnit = strlength(C.Unit) > 0;
            labels(withUnit) = labels(withUnit) + " (" + C.Unit(withUnit) + ")";
            names = C.Name;
            % the number variables of the lab database: one value per subject, plotted like a metric
            D = obj.DbColumns;
            D = D(D.Type == "number", :);
            labels = [labels; "Variable: " + D.Label];
            names = [names; D.Name];
            for dd = [obj.MetricDropDown, obj.XMetricDropDown]
                keep = char(dd.Value);
                dd.Items = cellstr(labels);
                dd.ItemsData = cellstr(names);
                if any(names == string(keep)), dd.Value = keep; end
            end
            obj.onMetricChanged(false);
            obj.tip(obj.XMetricDropDown, ['Scatter plot only: the metric on the horizontal axis. ' ...
                char(obj.meaningOf(obj.XMetricDropDown.Value))]);
        end

        function refreshGroupItems(obj)
            f = obj.Factors;
            labels = f;
            labels(f == "Sex") = "Sex (lab database)";
            labels(f == "Species") = "Species (lab database)";
            labels(f == "DbProject") = "Project (lab database)";
            labels(f == "Group") = "Group (yours)";
            D = obj.DbColumns;
            for k = 1:height(D)
                word = CellToolkit.ternary(D.Source(k) == "tag", 'Tag: ', 'Variable: ');
                labels(f == D.Name(k)) = string(word) + D.Label(k);
            end
            items = ["No grouping", labels, "Colocalized"];
            data = ["none", f, "Colocalized"];
            keep = char(obj.GroupByDropDown.Value);
            obj.GroupByDropDown.Items = cellstr(items);
            obj.GroupByDropDown.ItemsData = cellstr(data);
            if any(data == string(keep)), obj.GroupByDropDown.Value = keep; end
        end

        function txt = meaningOf(obj, name)
            C = obj.Catalog;
            i = find(C.Name == string(name), 1);
            txt = "";
            if ~isempty(i), txt = C.Meaning(i); return; end
            D = obj.DbColumns;
            i = find(D.Name == string(name), 1);
            if ~isempty(i)
                txt = D.Meaning(i) + " One value per subject, the same for every cell of it: choose Sections " + ...
                    "or Subjects under ""One point per"".";
            end
        end

        function [label, unit] = labelOf(obj, name)
            C = obj.Catalog;
            i = find(C.Name == string(name), 1);
            label = string(name); unit = "";
            if isempty(i)
                D = obj.DbColumns;
                i = find(D.Name == string(name), 1);
                if ~isempty(i), label = D.Label(i); unit = D.Units(i); end
                return
            end
            unit = C.Unit(i);
            label = C.Label(i);
            if strlength(unit) > 0, label = label + " (" + unit + ")"; end
        end

        % ------------------------------------------------------------------ data

        function reload(obj)
            % Read the measured cells of the chosen kind and population, then show everything.
            S = obj.Sources;
            obj.Rows = find(S.Kind == obj.Kind | S.Key == obj.Kind);
            try
                [obj.Cells, obj.Sections] = cellanalysis.Project.load(S, obj.Kind, ...
                    struct('Population', obj.Population, 'ColocUm', obj.ColocUm, 'MinDepthUm', obj.MinDepthUm));
            catch ME
                obj.Cells = table();
                obj.Sections = table();
                obj.setStatus(['Could not read the measurements: ' ME.message]);
            end
            obj.SelectedRows = obj.SelectedRows(obj.SelectedRows <= numel(obj.Rows));
            obj.refreshGroupItems();
            obj.refreshTable();
            obj.refreshDetail();
            obj.updateControls();
            obj.refreshPlot();
            obj.requestMap();
        end

        function databaseChanged(obj)
            % The cache of the lab database was renewed: read the subjects' facts again, and
            % offer the tags and variables to group and plot by.
            S = cellanalysis.Project.readDatabase(obj.Sources);
            [obj.Sources, obj.Factors] = cellanalysis.Project.applyGroups(S, obj.Groups);
            obj.DbColumns = cellanalysis.Project.databaseColumns(obj.Sources);
            obj.refreshMetricItems();
            obj.reload();
        end

        function st = databaseUsable(~)
            % Whether the lab database can be asked from this computer, and why not: struct ok,
            % why. Asked at a scan and at Check subjects (it reads the client's settings), not
            % at every update of the controls.
            st = struct('ok', false, 'why', 'the lab database client is not usable here.');
            try
                [tf, w] = celldb.available();
                if tf && ~celldb.capturing()
                    tf = false;
                    w = "the lab database is turned off on this computer (the Dataset Manager's Database... turns it on).";
                end
                st.ok = logical(tf);
                if ~tf, st.why = char(w); end
            catch
            end
        end

        function groupsChanged(obj)
            % The groupings changed: write them, put them on the sources and on the cells.
            try
                cellanalysis.Project.writeGroups(obj.ParentDirectory, obj.Groups);
            catch ME
                obj.setStatus(['The groupings could not be written: ' ME.message]);
            end
            [obj.Sources, obj.Factors] = cellanalysis.Project.applyGroups(obj.Sources, obj.Groups);
            if ~isempty(obj.Cells)
                for f = obj.Factors
                    obj.Cells.(f) = obj.Sources.(f)(obj.Cells.SourceRow);
                end
            end
            obj.refreshGroupItems();
            obj.refreshTable();
            obj.refreshPlot();
        end

        function refreshTable(obj)
            S = obj.Sources;
            rows = obj.Rows;
            n = numel(rows);
            data = cell(n, numel(obj.COLUMNS));
            counts = zeros(height(S), 1);
            if ~isempty(obj.Cells)
                counts = accumarray(obj.Cells.SourceRow, 1, [height(S) 1]);
            end
            for q = 1:n
                i = rows(q);
                data{q, 1} = obj.Use(i);
                data{q, 2} = char(S.Subject(i));
                data{q, 3} = char(S.Section(i));
                data{q, 4} = char(S.Group(i));
                if S.State(i) == "none", data{q, 5} = ''; else, data{q, 5} = sprintf('%d', counts(i)); end
                switch S.State(i)
                    case "current", data{q, 6} = 'yes';
                    case "stale",   data{q, 6} = 'out of date';
                    otherwise,      data{q, 6} = 'no';
                end
                data{q, 7} = char(obj.surfaceText(S(i, :)));
            end
            obj.SectionTable.Data = data;
            try
                removeStyle(obj.SectionTable);
                stale = find(S.State(rows) ~= "current");
                if ~isempty(stale)
                    addStyle(obj.SectionTable, uistyle('FontColor', [0.72 0.35 0]), 'cell', ...
                        [stale(:), repmat(6, numel(stale), 1)]);
                end
            catch
            end
            try
                obj.SectionTable.Selection = obj.SelectedRows;
            catch
            end
        end

        function txt = surfaceText(~, s)
            switch s.SurfaceMode
                case "all",    txt = "every area";
                case "traced", txt = "traced";
                otherwise,     txt = "automatic";
            end
            if s.State == "current" && ~s.SurfaceOk, txt = txt + ": not found"; end
        end

        function refreshDetail(obj)
            src = obj.selectedSource();
            if isempty(src)
                obj.DetailLabel.Text = 'No section selected.';
                return
            end
            switch src.State
                case "none",  st = 'Not measured yet.';
                case "stale", st = 'Measured, but out of date: its curation, image or surface changed since.';
                otherwise,    st = sprintf('Measured: %d cells.', src.Measured);
            end
            cur = 'not curated (no kept cells; choose "All detections" to see its cells)';
            if src.Curated, cur = sprintf('%d kept cells', src.Kept); end
            if src.Complete, cur = [cur ', curation complete']; end
            db = strjoin(src{1, ["Sex" "Species" "DbProject"]}(strlength(src{1, ["Sex" "Species" "DbProject"]}) > 0), ', ');
            if strlength(db) == 0, db = "nothing known on this computer"; end
            if strlength(src.DbTags) > 0, db = db + ". Tags: " + src.DbTags; end
            if strlength(src.DbVariables) > 0, db = db + ". Variables: " + src.DbVariables; end
            near = '';
            if obj.MinDepthUm > 0 && src.State ~= "none"
                if ~src.SurfaceOk
                    near = sprintf('\nNo brain surface: no cell is rejected near it.');
                else
                    n = 0;
                    if ~isempty(obj.Sections)
                        k = find(obj.Sections.SourceRow == obj.Rows(obj.SelectedRows(1)), 1);
                        if ~isempty(k), n = obj.Sections.NearSurface(k); end
                    end
                    near = sprintf('\n%d cells rejected within %g um of the brain surface.', n, obj.MinDepthUm);
                end
            end
            obj.DetailLabel.Text = sprintf('%s  [%s]\n%d detections, %s. %s\nLab database: %s.%s', ...
                src.Dataset, src.Key, src.Detections, cur, st, db, near);
        end

        function txt = nearSurfaceText(obj)
            % One sentence for the status line: how many cells Reject near surface leaves out.
            if obj.MinDepthUm <= 0
                txt = 'No cell is rejected for being near the brain surface.';
                return
            end
            n = 0;
            if ~isempty(obj.Sections), n = sum(obj.Sections.NearSurface); end
            S = obj.Sources;
            rows = obj.Rows(S.State(obj.Rows) ~= "none" & ~S.SurfaceOk(obj.Rows));
            txt = sprintf('%d cells within %g um of the brain surface are rejected in the listed sections.', ...
                n, obj.MinDepthUm);
            if ~isempty(rows)
                txt = [txt sprintf(' %d section(s) have no brain surface and keep all their cells: trace it on the Section tab.', ...
                    numel(rows))];
            end
        end

        function T = viewCells(obj)
            % The cells the plots show: the checked sections, or the selected one.
            T = obj.Cells;
            if isempty(T), return; end
            if strcmp(char(obj.ScopeDropDown.Value), 'selected')
                src = obj.selectedSource();
                if isempty(src), T = T([], :); return; end
                T = T(T.SourceRow == obj.Rows(obj.SelectedRows(1)), :);
            else
                T = T(obj.Use(T.SourceRow), :);
            end
        end

        function T = sectionSummary(obj)
            % One row per section of the view: tags, cells, the median of every metric.
            V = obj.View;
            T = table();
            if isempty(V), return; end
            names = obj.Catalog.Name(ismember(obj.Catalog.Name, string(V.Properties.VariableNames)));
            if obj.Kind ~= "pnn", names = names(ismember(names, obj.Catalog.Name(obj.Catalog.Kinds == "both"))); end
            rows = unique(V.SourceRow, 'stable');
            out = cell(numel(rows), 1);
            for q = 1:numel(rows)
                m = V.SourceRow == rows(q);
                r = V(find(m, 1), [{'Dataset', 'Key'}, cellstr(obj.Factors)]);
                r.Cells = nnz(m);
                k = [];
                if ~isempty(obj.Sections), k = find(obj.Sections.SourceRow == rows(q), 1); end
                if ~isempty(k) && strlength(obj.Sections.OtherKey(k)) > 0
                    r.OtherChannel = obj.Sections.OtherKey(k);
                    r.OtherCells = obj.Sections.OtherCells(k);
                    r.Pairs = nnz(V.Colocalized(m) == 1);
                    r.ColocalizedOfOther = r.Pairs / max(r.OtherCells, 1);
                else
                    r.OtherChannel = "";
                    r.OtherCells = NaN; r.Pairs = NaN; r.ColocalizedOfOther = NaN;
                end
                if ~isempty(k), r.TissueMm2 = obj.Sections.TissueMm2(k); else, r.TissueMm2 = NaN; end
                r.MinDepthUm = obj.MinDepthUm;
                if ~isempty(k), r.RejectedNearSurface = obj.Sections.NearSurface(k); else, r.RejectedNearSurface = NaN; end
                for nm = reshape(names, 1, [])
                    x = double(V.(nm)(m));
                    x = x(isfinite(x));
                    if isempty(x)
                        r.(nm) = NaN;
                    elseif any(nm == ["Colocalized" "ColocChance"])
                        r.(nm) = mean(x);
                    else
                        r.(nm) = median(x);
                    end
                end
                out{q} = r;
            end
            T = vertcat(out{:});
        end

        % ------------------------------------------------------------------ the plot

        function refreshPlot(obj)
            if isempty(obj.Figure) || ~isvalid(obj.Figure), return; end
            ax = obj.PlotAxes;
            V = obj.viewCells();
            obj.View = V;
            S = obj.Sources;
            kind = char(obj.PlotDropDown.Value);
            metric = string(obj.MetricDropDown.Value);
            groupBy = string(obj.GroupByDropDown.Value);
            if groupBy == "none", groupBy = ""; end
            unit = string(obj.UnitDropDown.Value);
            obj.Summary = table();
            if isempty(S)
                obj.PlotInfo = cellanalysis.Plots.message(ax, 'Scan a folder of sections to begin.');
                obj.showSummary();
                return
            end
            if isempty(obj.Cells)
                if all(S.State(obj.Rows) == "none")
                    msg = 'Nothing is measured yet. Measure all measures every section below the folder.';
                elseif strcmp(obj.Population, 'kept')
                    msg = ['No kept cells in the measured sections. Curate them in Cell Curator, or choose ' ...
                        '"All detections" under Cells.'];
                else
                    msg = 'The measured sections hold no cells of this type.';
                end
                obj.PlotInfo = cellanalysis.Plots.message(ax, msg);
                obj.showSummary();
                return
            end
            if isempty(V)
                if strcmp(char(obj.ScopeDropDown.Value), 'selected')
                    msg = 'Select a measured section in the list (Sections: Selected section).';
                else
                    msg = 'No checked section has measured cells. Check sections in the list, or measure them.';
                end
                obj.PlotInfo = cellanalysis.Plots.message(ax, msg);
                obj.showSummary();
                return
            end
            [mLabel, mUnit] = obj.labelOf(metric);
            lab = struct('XLabel', mLabel, 'YLabel', mLabel, 'Title', '', 'YUnit', "");
            if strlength(groupBy) > 0
                lab.AllNames = unique(cellanalysis.Stats.groupOf(obj.Cells, groupBy));
            end
            nSec = numel(unique(V.SourceRow));
            depthNote = '';
            if obj.MinDepthUm > 0, depthNote = sprintf(' at least %g um from the surface', obj.MinDepthUm); end
            who = sprintf('%s, %s%s, %d cells in %d section(s)', char(obj.KindDropDown.Items{strcmp(obj.KindDropDown.ItemsData, ...
                char(obj.Kind))}), lower(obj.POPULATION_ITEMS{strcmp(obj.POPULATION_DATA, obj.Population)}), depthNote, ...
                height(V), nSec);
            unitWord = struct('cells', 'Cells', 'section', 'Sections', 'subject', 'Subjects');
            summaryMetric = metric;
            depthOpts = struct('BinUm', obj.BinEdit.Value, 'MinDepthUm', obj.MinDepthUm);
            if metric == "OtherDistUm"
                lab.Mark = obj.ColocUm;
                lab.MarkLabel = sprintf('colocalized within %g um', obj.ColocUm);
            end
            alongDepth = any(strcmp(kind, {'Metric by depth', 'Cell density by depth'})) || ...
                (metric == "SurfaceDistUm" && any(strcmp(kind, {'Histogram', 'Cumulative'})));
            if obj.MinDepthUm > 0 && alongDepth
                lab.Mark = obj.MinDepthUm;
                lab.MarkLabel = sprintf('rejected closer than %g um', obj.MinDepthUm);
            end
            try
                switch kind
                    case 'Colocalization'
                        K = cellanalysis.Stats.colocalization(V, obj.Sections, groupBy);
                        if isempty(K.Sections)
                            obj.PlotInfo = cellanalysis.Plots.message(ax, ['These sections have no second channel ' ...
                                'that is measured, so there is nothing to colocalize with. Measure both channels.']);
                            obj.showSummary();
                            return
                        end
                        [lab.ThisName, lab.OtherName] = obj.channelNames(K.Sections.SourceRow(1));
                        shift = max(50, 5 * obj.ColocUm);
                        lab.ChanceNote = sprintf('by chance (%s displaced by %g um)', lab.OtherName, shift);
                        lab.Title = sprintf('%s; paired one to one within %g um; bars = mean of the sections', who, obj.ColocUm);
                        obj.PlotInfo = cellanalysis.Plots.colocalization(ax, K, lab);
                        R = K.Summary;
                        R.Properties.VariableNames = {'Group', 'Sections', char(lab.ThisName), char(lab.OtherName), 'Pairs', ...
                            char("% of " + lab.ThisName), 'SEM', char("% of " + lab.OtherName), 'SEM ', '% by chance', 'x chance'};
                        obj.Summary = R;
                        obj.showSummary("colocalization");
                        return
                    case 'Histogram'
                        H = cellanalysis.Stats.histogram(V, metric, groupBy, unit);
                        lab.Title = who;
                        lab.YUnit = unitWord.(char(unit));
                        obj.PlotInfo = cellanalysis.Plots.histogram(ax, H, lab);
                    case 'Cumulative'
                        E = cellanalysis.Stats.cdf(V, metric, groupBy, unit);
                        lab.Title = who;
                        obj.PlotInfo = cellanalysis.Plots.cumulative(ax, E, lab);
                    case 'Box by group'
                        [v, g, names] = cellanalysis.Stats.values(V, metric, groupBy, unit);
                        lab.Title = sprintf('%s; one point per %s', who, lower(unitWord.(char(unit))(1:end - 1)));
                        obj.PlotInfo = cellanalysis.Plots.boxes(ax, v, g, names, lab);
                    case 'Metric by depth'
                        D = cellanalysis.Stats.depthProfile(V, S, metric, groupBy, depthOpts);
                        lab.Title = sprintf('%s; mean of the sections, band = SEM', who);
                        obj.PlotInfo = cellanalysis.Plots.depth(ax, D, lab);
                    case 'Cell density by depth'
                        D = cellanalysis.Stats.depthProfile(V, S, "Density", groupBy, depthOpts);
                        lab.YLabel = "Cell density (cells/mm^2 of tissue)";
                        lab.Title = sprintf('%s; mean of the sections, band = SEM', who);
                        obj.PlotInfo = cellanalysis.Plots.depth(ax, D, lab);
                        summaryMetric = "SurfaceDistUm";
                    case 'Scatter'
                        xm = string(obj.XMetricDropDown.Value);
                        [x, y, g, names] = cellanalysis.Stats.pairs(V, xm, metric, groupBy, unit);
                        lab.XLabel = obj.labelOf(xm);
                        lab.Title = sprintf('%s; one point per %s', who, lower(unitWord.(char(unit))(1:end - 1)));
                        obj.PlotInfo = cellanalysis.Plots.scatter(ax, x, y, g, names, lab);
                end
                if any(strcmp(kind, {'Metric by depth', 'Cell density by depth'})), unit = "cells"; end
                obj.Summary = cellanalysis.Stats.summary(V, summaryMetric, groupBy, unit);
            catch ME
                obj.PlotInfo = cellanalysis.Plots.message(ax, ['This plot could not be drawn: ' ME.message]);
            end
            obj.showSummary(summaryMetric, mUnit);
        end

        function showSummary(obj, metric, ~)
            R = obj.Summary;
            if isempty(R)
                obj.SummaryTable.Data = {};
                obj.SummaryTable.ColumnName = {'Group', 'N', 'Cells', 'Mean', 'SD', 'SEM', 'Median', 'Q1', 'Q3', 'Min', 'Max'};
                return
            end
            D = table2cell(R);
            D(:, 1) = cellstr(R.Group);
            for c = 2:size(D, 2)
                x = R{:, c};
                if all(x == round(x) | isnan(x)) && c <= 5
                    D(:, c) = arrayfun(@(v) sprintf('%d', v), x, 'UniformOutput', false);
                else
                    D(:, c) = arrayfun(@(v) sprintf('%.4g', v), x, 'UniformOutput', false);
                end
            end
            names = R.Properties.VariableNames;
            if string(metric) == "colocalization"
                names{1} = 'Group: colocalization';
            else
                names{1} = char("Group: " + obj.labelOf(metric));
            end
            % the column widths are fixed (set where the table is made): a table that is given
            % new widths and new names in one go keeps showing the old ones
            obj.SummaryTable.ColumnName = names;
            obj.SummaryTable.Data = D;
        end

        function [this, other] = channelNames(obj, sourceRow)
            %channelNames  Short names of the analyzed channel and of the section's other channel.
            name = @(kind, key) CellToolkit.ternary(kind == "pnn", 'PNN', CellToolkit.ternary(kind == "pv", 'PV', char(key)));
            S = obj.Sources;
            this = name(S.Kind(sourceRow), S.Key(sourceRow));
            other = 'other channel';
            k = find(obj.Sections.SourceRow == sourceRow, 1);
            if ~isempty(k) && strlength(obj.Sections.OtherKey(k)) > 0
                key = obj.Sections.OtherKey(k);
                other = name(curation.Proposals.kindOf(key), key);
            end
        end

        function onMetricChanged(obj, redraw)
            if nargin < 2, redraw = true; end
            obj.tip(obj.MetricDropDown, ['The measurement to plot. ' char(obj.meaningOf(obj.MetricDropDown.Value)) ...
                ' The cells on the Section tab are colored by it too.']);
            obj.tip(obj.UnitDropDown, ['What one observation is. Cells: every cell counts once, so sections with many ' ...
                'cells weigh more. Sections: one value per section (the median of its cells). Subjects: one value ' ...
                'per animal. Use sections or subjects to compare groups without counting the same animal many times.']);
            obj.tip(obj.BinEdit, ['Depth profiles only: width of the distance bins, in micrometers (a multiple of ' ...
                '25). Bins with fewer than 3 cells or too little tissue in a section give no value.']);
            obj.tip(obj.SurfaceDropDown, ['How the brain surface of the selected section is defined. Automatic: the ' ...
                'edge of the largest empty area of the picture (the outside of the brain), which you can correct ' ...
                'with Pick empty areas. Every empty area: ventricles and tears count as surface too. Traced line: ' ...
                'the line you drew with Trace surface. The choice is kept with the section and shared by its channels.']);
            obj.tip(obj.TraceButton, ['Draw the brain surface by hand on the picture: click along the surface, ' ...
                'double-click to finish. Distances are then measured from this line. Use it when the picture shows ' ...
                'no empty space beside the tissue, or when the automatic surface is wrong.']);
            obj.tip(obj.PickAreasButton, ['While this is on, click an empty area of the picture to switch its edge on ' ...
                'or off as brain surface: switch a ventricle off, or switch on a part of the outside that a shred ' ...
                'of tissue cut off.']);
            if redraw
                obj.updateControls();
                obj.refreshPlot();
                obj.requestMap();
            end
        end

        % ------------------------------------------------------------------ the section map

        function onTabChanged(obj)
            obj.requestMap();
        end

        function requestMap(obj)
            % Draw the selected section a moment from now (only while its tab is visible).
            if isempty(obj.Tabs) || ~isvalid(obj.Tabs) || obj.Tabs.SelectedTab ~= obj.SectionTab, return; end
            obj.defer('map', 0.15, @() obj.drawMap());
        end

        function entry = mapEntry(obj, src)
            % The display image and the surface of a source's section (cached).
            if istable(src), s = table2struct(src); else, s = src; end
            def = cellanalysis.Project.surfaceDef(src);
            key = char(s.ImagePath + "|" + s.Page + "|" + cellanalysis.Project.surfaceHash(def));
            hit = find(strcmp({obj.MapCache.Key}, key), 1);
            if ~isempty(hit)
                entry = obj.MapCache(hit);
                return
            end
            [Sf, pages] = cellanalysis.Project.loadSurface(src, def);
            pg = double(s.Page);
            if ~isfinite(pg) || pg < 1, pg = 1; end
            pg = min(pg, numel(pages));
            page = single(pages{pg});
            k = max(1, ceil(max(size(page)) / obj.MAP_MAX_DIM));
            small = imresize(page, 1 / k, 'box');
            v = small(isfinite(small) & small > min(small(:)));
            if isempty(v), v = small(:); end
            lo = prctile(v, 1); hi = prctile(v, 99.7);
            img = min(max((small - lo) / max(hi - lo, eps('single')), 0), 1) .^ 0.6;
            img(~isfinite(img)) = 0;
            entry = struct('Key', key, 'Img', img, 'Scale', 1 / k, 'Surface', Sf);
            obj.MapCache(end + 1) = entry;
            if numel(obj.MapCache) > obj.MAP_CACHE, obj.MapCache(1) = []; end
        end

        function drawMap(obj)
            ax = obj.MapAxes;
            src = obj.selectedSource();
            obj.MapInfo = struct('Dataset', "", 'Key', "", 'SurfaceOk', false, 'Mode', "", 'Cells', 0, 'Lines', 0, ...
                'Rejected', 0, 'DepthLines', 0, 'Message', "");
            if isempty(src)
                cellanalysis.Plots.message(ax, 'Select a section in the list to see it here.');
                return
            end
            try
                entry = obj.mapEntry(src);
            catch ME
                cellanalysis.Plots.message(ax, ['The section could not be shown: ' ME.message]);
                obj.MapInfo.Message = string(ME.message);
                return
            end
            Sf = entry.Surface;
            xy = zeros(0, 2); values = [];
            metric = string(obj.MetricDropDown.Value);
            if ~isempty(obj.Cells)
                m = obj.Cells.SourceRow == obj.Rows(obj.SelectedRows(1));
                xy = [obj.Cells.X(m), obj.Cells.Y(m)];
                if ismember(char(metric), obj.Cells.Properties.VariableNames)
                    values = double(obj.Cells.(char(metric))(m));
                end
            end
            note = '';
            if src.State == "none"
                note = '   (not measured yet: no cells shown)';
            elseif src.State == "stale"
                note = '   (out of date: measure again)';
            end
            if ~Sf.Ok, note = [note '   ' char(Sf.Message)]; end
            % the cells Reject near surface leaves out, and the border of its band
            rejected = zeros(0, 2);
            depthLines = cell(0, 1);
            if obj.MinDepthUm > 0
                depthLines = cellanalysis.Surface.depthLines(Sf, obj.MinDepthUm);
                if src.State ~= "none"
                    try
                        M = cellanalysis.Project.pick(cellanalysis.Project.readMetrics(src.MetricsPath), obj.Population, 0);
                        near = M.SurfaceDistUm < obj.MinDepthUm;
                        rejected = [M.X(near), M.Y(near)];
                    catch
                    end
                end
                if ~isempty(rejected)
                    note = [note sprintf('   (%d rejected within %g um of the surface)', size(rejected, 1), obj.MinDepthUm)];
                end
            end
            lab = struct('ValueLabel', obj.labelOf(metric), 'Title', sprintf('%s  %s%s', src.Section, src.Key, note), ...
                'Rejected', rejected, 'DepthLines', {depthLines});
            ax.Visible = 'on';
            obj.MapHandles = cellanalysis.Plots.map(ax, entry.Img, entry.Scale, Sf, xy, values, lab);
            obj.MapHandles.Scale = entry.Scale;
            obj.MapHandles.Image.ButtonDownFcn = @(s, e) obj.onMapClick(e);
            obj.MapInfo = struct('Dataset', src.Dataset, 'Key', src.Key, 'SurfaceOk', Sf.Ok, 'Mode', string(Sf.Mode), ...
                'Cells', size(xy, 1), 'Lines', numel(Sf.Lines), 'Rejected', size(rejected, 1), ...
                'DepthLines', numel(depthLines), 'Message', string(Sf.Message));
            obj.SurfaceDropDown.Value = char(Sf.Mode);
            obj.updateControls();
        end

        function surfaceChanged(obj, src)
            % The surface definition of a dataset changed: its sources are out of date.
            rows = find(obj.Sources.Folder == src.Folder & obj.Sources.Dataset == src.Dataset);
            obj.Sources = cellanalysis.Project.refreshState(obj.Sources, rows);
            obj.refreshTable();
            obj.refreshDetail();
            def = cellanalysis.Project.surfaceDef(src);
            obj.SurfaceDropDown.Value = char(def.mode);
            obj.updateControls();
            obj.setStatus(['The brain surface of this section changed. Its distances are out of date until it is ' ...
                'measured again (Measure selected).']);
            if obj.Tabs.SelectedTab == obj.SectionTab
                obj.cancelDeferred('map');
                obj.drawMap();
            end
        end

        function onMapClick(obj, ~)
            if ~obj.PickAreas, return; end
            p = obj.MapAxes.CurrentPoint(1, 1:2);
            xy = (p - 0.5) / obj.MapHandles.Scale + 0.5;
            obj.toggleSurfaceArea(xy);
        end

        function onPickAreas(obj, on)
            obj.PickAreas = logical(on);
            if obj.PickAreas
                obj.setStatus('Click an empty area of the picture to switch its edge on or off as brain surface.');
            end
        end

        function onTrace(obj)
            % Draw the surface by hand (interactive).
            src = obj.selectedSource();
            if isempty(src), return; end
            obj.setStatus('Click along the brain surface; double-click to finish, Esc to cancel.');
            try
                roi = drawpolyline(obj.MapAxes, 'Color', cellanalysis.Plots.SURFACE);
            catch ME
                obj.setStatus(['The surface could not be traced: ' ME.message]);
                return
            end
            if isempty(roi) || ~isvalid(roi) || size(roi.Position, 1) < 2
                obj.setStatus('No surface was traced.');
                return
            end
            xy = (roi.Position - 0.5) / obj.MapHandles.Scale + 0.5;
            delete(roi);
            obj.setSurfaceLine(xy);
        end

        % ------------------------------------------------------------------ callbacks

        function onTableSelection(obj, e)
            sel = e.Selection;
            if isempty(sel)
                obj.SelectedRows = zeros(1, 0);
            else
                obj.SelectedRows = unique(sel(:, 1))';
            end
            obj.onSelectionChanged();
        end

        function onSelectionChanged(obj)
            obj.refreshDetail();
            src = obj.selectedSource();
            if ~isempty(src)
                obj.SurfaceDropDown.Value = char(src.SurfaceMode);
            end
            obj.updateControls();
            if strcmp(char(obj.ScopeDropDown.Value), 'selected'), obj.refreshPlot(); end
            obj.requestMap();
        end

        function onTableEdit(obj, e)
            r = e.Indices(1); c = e.Indices(2);
            if r > numel(obj.Rows), return; end
            if c == 1
                obj.Use(obj.Rows(r)) = logical(e.NewData);
                obj.refreshPlot();
            elseif c == 4
                obj.setGroup(r, string(e.NewData));
            end
        end

        function onBrowse(obj)
            start = obj.ParentDirEdit.Value;
            if isempty(start) || ~isfolder(start), start = pwd; end
            d = uigetdir(start, 'Folder that holds the sections');
            figure(obj.Figure);
            if isequal(d, 0), return; end
            obj.scanFolder(d);
        end

        function onSetGroup(obj)
            if isempty(obj.SelectedRows), return; end
            a = inputdlg(sprintf('Group name for the %d selected section(s) (empty clears it):', numel(obj.SelectedRows)), ...
                'Set group', 1, {char(obj.Sources.Group(obj.Rows(obj.SelectedRows(1))))});
            if isempty(a), return; end
            obj.setGroup(obj.SelectedRows, a{1});
        end

        function onImportGroups(obj)
            [f, p] = uigetfile({'*.csv;*.xlsx;*.xls;*.txt', 'Tables (*.csv, *.xlsx, *.xls, *.txt)'}, ...
                'Spreadsheet or CSV with the groupings', obj.ParentDirectory);
            figure(obj.Figure);
            if isequal(f, 0), return; end
            try
                obj.importGroups(fullfile(p, f));
            catch ME
                uialert(obj.Figure, ME.message, 'The groupings could not be read');
            end
        end

        function onExportCells(obj)
            if isempty(obj.View), obj.setStatus('There are no measured cells to export.'); return; end
            [f, p] = uiputfile({'*.csv', 'CSV (*.csv)'}, 'Export the cells', ...
                fullfile(obj.ParentDirectory, sprintf('cells_%s.csv', char(obj.Kind))));
            figure(obj.Figure);
            if isequal(f, 0), return; end
            try
                obj.exportCells(fullfile(p, f));
            catch ME
                uialert(obj.Figure, ME.message, 'The cells could not be written');
            end
        end

        function onExportSummary(obj)
            if isempty(obj.View), obj.setStatus('There are no measured cells to summarize.'); return; end
            [f, p] = uiputfile({'*.csv', 'CSV (*.csv)'}, 'Export one row per section', ...
                fullfile(obj.ParentDirectory, sprintf('sections_%s.csv', char(obj.Kind))));
            figure(obj.Figure);
            if isequal(f, 0), return; end
            try
                obj.exportSummary(fullfile(p, f));
            catch ME
                uialert(obj.Figure, ME.message, 'The summary could not be written');
            end
        end

        function onSaveFigure(obj)
            [f, p] = uiputfile({'*.png', 'PNG image (*.png)'; '*.pdf', 'PDF (*.pdf)'; '*.svg', 'SVG (*.svg)'}, ...
                'Save the figure', fullfile(obj.ParentDirectory, 'cell_analysis.png'));
            figure(obj.Figure);
            if isequal(f, 0), return; end
            try
                obj.saveFigure(fullfile(p, f));
            catch ME
                uialert(obj.Figure, ME.message, 'The figure could not be saved');
            end
        end

        % ------------------------------------------------------------------ deferred work

        function defer(obj, name, delay, fcn)
            % Run fcn() once, DELAY seconds from now, replacing what was deferred under NAME.
            obj.cancelDeferred(name);
            obj.Pending.(name) = fcn;
            try
                t = timer('StartDelay', delay, 'ExecutionMode', 'singleShot', ...
                    'Name', ['CellAnalysis.' name], 'TimerFcn', @(~, ~) obj.runDeferred(name));
                obj.Timers.(name) = t;
                start(t);
            catch
                obj.runDeferred(name);
            end
        end

        function runDeferred(obj, name)
            if ~isvalid(obj) || ~isfield(obj.Pending, name), return; end
            fcn = obj.Pending.(name);
            obj.cancelDeferred(name);
            if isempty(obj.Figure) || ~isvalid(obj.Figure), return; end
            try
                fcn();
            catch ME
                obj.setStatus(['Could not finish: ' ME.message]);
            end
        end

        function cancelDeferred(obj, name)
            if isfield(obj.Pending, name), obj.Pending = rmfield(obj.Pending, name); end
            if isfield(obj.Timers, name)
                t = obj.Timers.(name);
                obj.Timers = rmfield(obj.Timers, name);
                if ~isempty(t) && isa(t, 'timer') && isvalid(t)
                    try
                        stop(t);
                        delete(t);
                    catch
                    end
                end
            end
        end

        function cancelAllDeferred(obj)
            names = fieldnames(obj.Timers);
            for i = 1:numel(names), obj.cancelDeferred(names{i}); end
            obj.Pending = struct();
        end

        function setStatus(obj, txt)
            obj.StatusText = char(txt);
            if ~isempty(obj.StatusLabel) && isvalid(obj.StatusLabel)
                obj.StatusLabel.Text = obj.StatusText;
            end
        end

        % ------------------------------------------------------------------ settings

        function loadPreferences(obj)
            if ~obj.UseSettings, return; end
            d = struct('figurePosition', [], 'parentDirectory', '', 'plot', 'Histogram', 'metric', 'SurfaceDistUm', ...
                'xMetric', 'SurfaceDistUm', 'groupBy', 'none', 'unit', 'cells', 'population', 'kept', ...
                'colocUm', 10, 'minDepthUm', 0, 'binUm', 50, 'kind', 'pnn');
            s = CellToolkit.getSettings('CellAnalysis', d);
            try
                pos = s.figurePosition;
                if isnumeric(pos) && numel(pos) == 4 && all(isfinite(pos)) && all(pos(3:4) > 100)
                    obj.Figure.Position = pos;
                end
                if ischar(s.parentDirectory) && isfolder(s.parentDirectory)
                    obj.ParentDirEdit.Value = s.parentDirectory;
                end
                if any(strcmp(s.plot, obj.PLOTS)), obj.PlotDropDown.Value = s.plot; end
                if any(strcmp(s.population, obj.POPULATION_DATA))
                    obj.Population = s.population;
                    obj.PopulationDropDown.Value = s.population;
                end
                if any(strcmp(s.unit, obj.UNIT_DATA)), obj.UnitDropDown.Value = s.unit; end
                if isnumeric(s.colocUm) && isscalar(s.colocUm) && s.colocUm >= 0 && s.colocUm <= 200
                    obj.ColocUm = s.colocUm;
                    obj.ColocEdit.Value = s.colocUm;
                end
                if isnumeric(s.minDepthUm) && isscalar(s.minDepthUm) && isfinite(s.minDepthUm) ...
                        && s.minDepthUm >= 0 && s.minDepthUm <= 2000
                    obj.MinDepthUm = double(s.minDepthUm);
                    obj.MinDepthEdit.Value = obj.MinDepthUm;
                end
                if isnumeric(s.binUm) && isscalar(s.binUm) && s.binUm >= 25 && s.binUm <= 1000
                    obj.BinEdit.Value = s.binUm;
                end
                obj.Kind = string(s.kind);
                obj.refreshMetricItems();
                if any(strcmp(s.metric, obj.MetricDropDown.ItemsData)), obj.MetricDropDown.Value = s.metric; end
                if any(strcmp(s.xMetric, obj.XMetricDropDown.ItemsData)), obj.XMetricDropDown.Value = s.xMetric; end
                obj.onMetricChanged(false);
            catch
            end
        end

        function savePreferences(obj)
            if ~obj.UseSettings || isempty(obj.Figure) || ~isvalid(obj.Figure), return; end
            try
                s = struct('figurePosition', obj.Figure.Position, 'parentDirectory', char(obj.ParentDirEdit.Value), ...
                    'plot', char(obj.PlotDropDown.Value), 'metric', char(obj.MetricDropDown.Value), ...
                    'xMetric', char(obj.XMetricDropDown.Value), 'groupBy', char(obj.GroupByDropDown.Value), ...
                    'unit', char(obj.UnitDropDown.Value), 'population', obj.Population, 'colocUm', obj.ColocUm, ...
                    'minDepthUm', obj.MinDepthUm, 'binUm', obj.BinEdit.Value, 'kind', char(obj.Kind));
                CellToolkit.setSettings('CellAnalysis', s);
            catch
            end
        end

        function onClosing(obj)
            obj.cancelAllDeferred();
            obj.savePreferences();
            delete(obj.Figure);
        end

    end
end

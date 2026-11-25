classdef (TestTags = {'Slow', 'RealData'}) tAnalysisReal < matlab.unittest.TestCase
    %tAnalysisReal  Cell Analysis on real sections (WFA and PV, 1.66 um/pixel): the brain surface is found in
    %   every picture, the cells are outlined, and their sizes are those of real nets and somata. Works on a
    %   temporary copy of %LOCALAPPDATA%\counting_perineuronal_nets\real_sections (skipped when it is absent)
    %   and leaves the original unchanged. The sections are "curated" by rule first (a detection whose
    %   rescore is above the scorer's cutpoint is kept), so that there are kept cells to analyze.
    %
    %   Prints how long measuring takes. When the environment variable CELLANALYSIS_SCREENS_OUT names a
    %   folder, pictures of the window are written there.
    %
    %   Run on the hidden desktop: pwsh -File tools\Run-Tests.ps1 tAnalysisReal -IncludeSlow

    properties
        Master
        Folder
        Before
    end

    methods (TestClassSetup)
        function copyRealSections(tc)
            tc.Master = fullfile(getenv('LOCALAPPDATA'), 'counting_perineuronal_nets', 'real_sections');
            tc.assumeTrue(isfolder(tc.Master), 'no local copy of real sections here');
            tc.Before = tCuratorReal.listing(tc.Master);
            fx = tc.applyFixture(matlab.unittest.fixtures.TemporaryFolderFixture);
            tc.Folder = fullfile(fx.Folder, 'real_sections');
            tc.applyFixture(matlab.unittest.fixtures.EnvironmentVariableFixture('CELLDB_PROVENANCE_DIR', ...
                fullfile(fx.Folder, 'no_provenance')));
            copyfile(tc.Master, tc.Folder);
            d = dir(fullfile(tc.Folder, '**', '*_locs.csv'));
            for k = 1:numel(d)
                tAnalysisReal.curateByRule(fullfile(d(k).folder, d(k).name));
            end
        end
    end

    methods (TestClassTeardown)
        function theOriginalIsUnchanged(tc)
            if isempty(tc.Before), return; end
            tc.verifyEqual(tCuratorReal.listing(tc.Master), tc.Before, 'the local copy of the real sections was changed');
        end
    end

    methods (Static)
        function curateByRule(locs)
            %curateByRule  Label Good what the scorer rates above its cutpoint, Bad the rest (as a person would, roughly).
            s = curation.Store.openCsv(locs, struct('AutosaveDelay', 0, 'ImportLegacy', false));
            T = s.T;
            cut = curation.Proposals.cutpoint(curation.Proposals.kindOf(s.Meta.Key));
            good = T.rescore > cut;
            s.setLabel(double(T.CellID(good)), "Good", "human");
            s.setLabel(double(T.CellID(~good)), "Bad", "human");
            s.close();
        end

        function shot(app, name)
            out = getenv('CELLANALYSIS_SCREENS_OUT');
            if isempty(out), return; end
            if ~isfolder(out), mkdir(out); end
            drawnow; pause(0.8); drawnow;
            file = fullfile(out, name);
            try
                exportapp(app.Figure, file);
            catch
                F = getframe(app.Figure);
                imwrite(F.cdata, file);
            end
            fprintf('[real] screenshot %s\n', file);
        end
    end

    methods (Test)
        function realSectionsAreMeasuredAndPlotted(tc)
            app = CellAnalysis(tc.Folder, 'UseSettings', false, 'Scan', 'now');
            tc.addTeardown(@() tAnalysisGui.closeApp(app));
            nSrc = height(app.Sources);
            tc.assertGreaterThanOrEqual(nSrc, 2);
            t0 = tic;
            n = app.measure('all');
            el = toc(t0);
            tc.verifyEqual(n, nSrc, app.StatusText);
            nCells = sum(app.Sources.Measured);
            fprintf('\n[real] measured %d sources, %d cells in %.1f s (%.1f s per source, %.2f ms per cell)\n', ...
                n, nCells, el, el / n, 1000 * el / nCells);
            tc.verifyLessThan(el / n, 15, 'a source is measured in seconds');
            tc.verifyTrue(all(app.Sources.State == "current"));
            tc.verifyTrue(all(app.Sources.SurfaceOk), 'every real section shows its brain surface');

            % a second pass has nothing to do, and a forced one of one section reads the image once
            t1 = tic;
            tc.verifyEqual(app.measure('all'), 0);
            tc.verifyLessThan(toc(t1), 3);

            % ---- nets -------------------------------------------------------------------------------
            C = app.Cells;
            tc.verifyGreaterThan(height(C), 300, 'kept nets');
            tc.verifyTrue(all(C.Kept));
            tc.verifyGreaterThan(mean(C.Segmented), 0.9);
            tc.verifyGreaterThan(mean(isfinite(C.SurfaceDistUm)), 0.99);
            tc.verifyGreaterThan(mean(C.InTissue), 0.98);
            med = @(x) median(x, 'omitnan');
            fprintf('[real] nets: diameter %.1f um, ring radius %.1f um, wall %.1f um, ring contrast %.2f, completeness %.2f, depth %.0f um, colocalized %.2f\n', ...
                med(C.DiameterUm), med(C.RingRadiusUm), med(C.WallThicknessUm), med(C.RingContrast), med(C.Completeness), ...
                med(C.SurfaceDistUm), mean(C.Colocalized, 'omitnan'));
            tc.verifyGreaterThan(med(C.DiameterUm), 14);
            tc.verifyLessThan(med(C.DiameterUm), 32);
            tc.verifyGreaterThan(med(C.RingRadiusUm), 4);
            tc.verifyLessThan(med(C.RingRadiusUm), 11);
            tc.verifyGreaterThan(med(C.Completeness), 0.6);
            tc.verifyGreaterThan(med(C.Snr), 2);
            tc.verifyGreaterThan(med(C.SurfaceDistUm), 200, 'cortical nets lie hundreds of micrometers below the pia');
            tc.verifyLessThan(med(C.SurfaceDistUm), 2500);
            frac = mean(C.Colocalized, 'omitnan');
            tc.verifyGreaterThan(frac, 0.15, 'a good share of nets surround a PV cell');
            tc.verifyLessThan(frac, 0.98);

            % ---- plots ------------------------------------------------------------------------------
            app.setGroupBy('Subject');
            tc.verifyEqual(app.PlotInfo.Kind, "histogram");
            tc.verifyGreaterThanOrEqual(numel(app.PlotInfo.Names), 2, 'two animals');
            tAnalysisReal.shot(app, 'analysis_histogram.png');
            app.setPlot('Cumulative');
            app.setMetric('NetMean');
            tAnalysisReal.shot(app, 'analysis_cumulative.png');
            app.setPlot('Cell density by depth');
            app.setBinUm(100);
            tc.verifyEqual(app.PlotInfo.Kind, "depth");
            tAnalysisReal.shot(app, 'analysis_density.png');
            app.setPlot('Metric by depth');
            app.setMetric('DiameterUm');
            tAnalysisReal.shot(app, 'analysis_metric_depth.png');
            app.setPlot('Box by group');
            app.setGroupBy('Section');
            app.setMetric('Completeness');
            tAnalysisReal.shot(app, 'analysis_box.png');
            app.setPlot('Scatter');
            app.setXMetric('SurfaceDistUm');
            app.setMetric('NetMean');
            app.setGroupBy('Colocalized');
            tAnalysisReal.shot(app, 'analysis_scatter.png');

            % ---- colocalization -------------------------------------------------------------------
            app.setPlot('Colocalization');
            app.setGroupBy('Subject');
            tc.verifyEqual(app.PlotInfo.Kind, "colocalization");
            K = cellanalysis.Stats.colocalization(app.View, app.Sections, "");
            fprintf('[real] colocalization: %.0f%% of nets with a PV cell, %.0f%% of PV cells with a net, %.1f%% by chance (x%.0f)\n', ...
                K.Summary.PctThis, K.Summary.PctOther, K.Summary.PctChance, K.Summary.Enrichment);
            tc.verifyGreaterThan(K.Summary.Enrichment, 3, 'nets and PV cells coincide far more often than their densities give');
            tc.verifyLessThan(K.Summary.PctChance, 15);
            tAnalysisReal.shot(app, 'analysis_colocalization.png');
            app.setPlot('Histogram');
            app.setMetric('OtherDistUm');
            app.setGroupBy('');
            tAnalysisReal.shot(app, 'analysis_other_distance.png');

            % ---- the section map --------------------------------------------------------------------
            app.setMetric('SurfaceDistUm');
            app.showTab('Section');
            app.selectSection(1);
            t2 = tic;
            app.waitForIdle();
            fprintf('[real] section map drawn in %.2f s (cold)\n', toc(t2));
            tc.verifyTrue(app.MapInfo.SurfaceOk);
            tc.verifyGreaterThan(app.MapInfo.Cells, 100);
            tAnalysisReal.shot(app, 'analysis_section.png');
            app.selectSection(2);
            app.waitForIdle();
            app.selectSection(1);
            t3 = tic;
            app.waitForIdle();
            warm = toc(t3);
            fprintf('[real] section map drawn in %.2f s (from the cache)\n', warm);
            tc.verifyLessThan(warm, 1.5, 'going back to a section is immediate');

            % ---- PV cells ---------------------------------------------------------------------------
            app.showTab('Distributions');
            app.setKind('pv');
            P = app.Cells;
            tc.verifyGreaterThan(height(P), 300, 'kept PV cells');
            fprintf('[real] PV: diameter %.1f um, aspect %.2f, circularity %.2f, solidity %.2f, SNR %.1f, depth %.0f um\n', ...
                med(P.DiameterUm), med(P.AspectRatio), med(P.Circularity), med(P.Solidity), med(P.Snr), med(P.SurfaceDistUm));
            tc.verifyGreaterThan(med(P.DiameterUm), 8);
            tc.verifyLessThan(med(P.DiameterUm), 20, 'PV somata are 10 to 15 um across');
            tc.verifyGreaterThan(med(P.Solidity), 0.85);
            tc.verifyLessThan(med(P.AspectRatio), 2);
            tc.verifyGreaterThan(mean(P.Segmented), 0.95);
            app.setPlot('Histogram');
            app.setMetric('DiameterUm');
            app.setGroupBy('Subject');
            tAnalysisReal.shot(app, 'analysis_pv_histogram.png');

            % ---- nothing but the two kinds of analysis files was written ------------------------------
            L = tCuratorReal.listing(tc.Folder);
            names = string(L.File);
            isNew = ~ismember(names, string(tc.Before.File));
            other = names(isNew & ~contains(names, ["_metrics.csv", ".cellanalysis.json", "_curation", ".curation.json", ".celldataset.json"]));
            tc.verifyEmpty(other, "unexpected new files: " + strjoin(other, ", "));
        end
    end
end

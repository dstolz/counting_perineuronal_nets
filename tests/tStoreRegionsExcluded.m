classdef tStoreRegionsExcluded < matlab.unittest.TestCase
%tStoreRegionsExcluded  Regression tests: the store keeps Excluded equal to "inside an exclude region
%   of scope image or this source" for every row, whatever creates, moves or un-excludes it, in the
%   same transaction as the cause; region ids are never reused. Review findings 6 and 9.
%
%   Run: pwsh -File tools\Run-Tests.ps1 tStoreRegionsExcluded

    properties (Access = private)
        Dir char
    end

    methods (TestClassSetup)
        function addPaths(tc)
            here = fileparts(mfilename('fullpath'));
            tc.applyFixture(matlab.unittest.fixtures.PathFixture(fullfile(fileparts(here), 'customizations')));
        end
    end

    methods (TestMethodSetup)
        function makeDir(tc)
            tmp = tc.applyFixture(matlab.unittest.fixtures.TemporaryFolderFixture);
            tc.Dir = tmp.Folder;
        end
    end

    %% ---- finding 6: Excluded follows the regions ------------------------------------------------
    methods (Test)
        function rowsAppendedByAReconcileInsideARegionAreExcluded(tc)
            s = tc.mem([100 100; 200 100; 300 100]);
            s.addRegion(struct('kind', 'exclude', 'xy', square(500, 500, 50)));
            s.reconcile(mkLocs([100 100; 200 100; 300 100; 500 500]));
            nw = idAt(s, 500, 500);
            tc.verifyTrue(s.get('Excluded', nw), 'a new detection inside an exclusion region is excluded');
            s.setLabel(nw, "Good");
            tc.verifyFalse(ismember(nw, s.kept().CellID), 'and never counted');
        end

        function cellAddedByHandInsideARegionIsExcludedAndNotKept(tc)
            s = tc.mem([100 100; 200 100]);
            s.addRegion(struct('kind', 'exclude', 'xy', square(500, 500, 50)));
            id = s.addCell([510 490]);
            tc.verifyTrue(s.get('Excluded', id));
            tc.verifyEqual(s.counts().kept, 0, 'a Good added inside a fold is not kept');
            out = s.addCell([700 700]);
            tc.verifyFalse(s.get('Excluded', out));
        end

        function movingACellAcrossARegionBorderUpdatesExcludedInOneUndoStep(tc)
            s = tc.mem([100 100; 200 100]);
            s.addRegion(struct('kind', 'exclude', 'xy', square(500, 500, 50)));
            id = idAt(s, 100, 100);
            s.setLabel(id, "Good");
            s.moveCell(id, [500 500]);
            tc.verifyTrue(s.get('Excluded', id), 'moved inside');
            tc.verifyEqual(s.counts().kept, 0);
            tc.verifyTrue(s.undo());
            tc.verifyEqual([s.get('X', id) s.get('Y', id)], [100 100]);
            tc.verifyFalse(s.get('Excluded', id), 'one undo restores the position and the flag');
            tc.verifyTrue(s.redo());
            tc.verifyTrue(s.get('Excluded', id));
            s.mergeCells([id idAt(s, 200, 100)], id, [150 150]);   % a merge that moves the keeper out
            tc.verifyFalse(s.get('Excluded', id));
        end

        function removingARegionUnexcludesItsCellsAndOneUndoRestoresBoth(tc)
            s = tc.mem([100 100; 200 100; 500 500]);
            id = idAt(s, 500, 500);
            s.setLabel(id, "Good");
            rid = s.addRegion(struct('kind', 'exclude', 'xy', square(500, 500, 50)));
            tc.verifyTrue(s.get('Excluded', id), 'addRegion excludes the cells inside');
            tc.verifyEqual(s.counts().kept, 0);
            s.removeRegion(rid);
            tc.verifyFalse(s.get('Excluded', id), 'removeRegion un-excludes them');
            tc.verifyEqual(s.counts().kept, 1);
            tc.verifyTrue(s.undo());
            tc.verifyTrue(s.get('Excluded', id));
            tc.verifyNumElements(s.regions(), 1, 'the same undo step brings the region back');
            tc.verifyTrue(s.undo());
            tc.verifyFalse(s.get('Excluded', id));
            tc.verifyEmpty(s.regions());
        end

        function imageScopeRegionOfTheOtherChannelExcludesThisChannelsCells(tc)
            [e, pv, pe] = tc.twoChannels('secX');
            inE = idAt(e, 200, 100);
            e.setLabel(inE, "Good");
            pv.addRegion(struct('kind', 'exclude', 'scope', 'image', 'xy', square(200, 100, 20)));
            pv.addRegion(struct('kind', 'exclude', 'scope', 'PV2', 'xy', square(300, 100, 20)));
            e.reloadRegions();
            tc.verifyTrue(e.get('Excluded', inE), 'an image-scope region applies to every channel');
            tc.verifyFalse(e.get('Excluded', idAt(e, 300, 100)), 'a PV2-scope region does not apply to ECM1');
            tc.verifyEqual(e.counts().kept, 0);
            crash = [tc.Dir '_crash'];
            copyfile(tc.Dir, crash);
            delete(fullfile(crash, '*.lock'));
            c = curation.Store.openCsv(strrep(pe, tc.Dir, crash), struct('AutosaveDelay', 0));
            tc.addTeardown(@() closeQuiet(c));
            tc.verifyTrue(c.get('Excluded', inE), 'the change is journaled');
        end

        function regionsAddedWhileASourceWasClosedApplyAtOpen(tc)
            [e, pv, pe] = tc.twoChannels('secY');
            id = idAt(e, 300, 100);
            e.setLabel(id, "Good");
            e.close();
            pv.addRegion(struct('kind', 'exclude', 'xy', square(300, 100, 20)));
            e2 = curation.Store.openCsv(pe, struct('AutosaveDelay', 0));
            tc.addTeardown(@() closeQuiet(e2));
            tc.verifyTrue(e2.get('Excluded', id), 'regions are applied when a source opens');
            tc.verifyEqual(e2.counts().kept, 0);
        end

        function setExcludedCannotContradictTheRegions(tc)
            s = tc.mem([100 100; 200 100; 500 500]);
            out = idAt(s, 100, 100); in = idAt(s, 500, 500);
            tc.verifyError(@() s.setExcluded(out, true), 'curation:Store:excludedByRegions', ...
                'no region contains it: it cannot be excluded by hand');
            tc.verifyFalse(s.get('Excluded', out));
            s.setLabel(in, "Good");
            s.beginBatch("Exclude a fold");             % what the map's lasso does
            s.addRegion(struct('kind', 'exclude', 'xy', square(500, 500, 50)));
            s.setExcluded(in, true);                    % agrees with the region: allowed, no-op
            s.endBatch();
            tc.verifyTrue(s.get('Excluded', in));
            tc.verifyError(@() s.setExcluded(in, false), 'curation:Store:excludedByRegions');
            s.setExcluded(out, false);                  % agrees: no error
            tc.verifyTrue(s.undo());
            tc.verifyFalse(s.get('Excluded', in), 'the batch is one undo step');
            tc.verifyEmpty(s.regions());
        end
    end

    %% ---- finding 9: region ids ------------------------------------------------------------------------
    methods (Test)
        function undoingARegionRemovalNeverReplacesTheOtherChannelsRegion(tc)
            [e, pv] = tc.twoChannels('secI');
            idE = e.addRegion(struct('kind', 'reference', 'xy', square(50, 50, 10), 'note', 'ecm'));
            e.removeRegion(idE);
            idP = pv.addRegion(struct('kind', 'reference', 'xy', square(150, 150, 10), 'note', 'pv'));
            tc.verifyNotEqual(idP, idE, 'a region id is never reused');
            e.undo();                                   % brings ECM's region back
            J = jsondecode(fileread(e.Paths.json));
            R = curation.Regions.normalize(J.regions);
            tc.verifyEqual(sort([R.id]), sort([idE idP]), 'both regions are in the shared JSON');
            tc.verifyEqual(R([R.id] == idP).note, "pv", 'the other channel''s region is intact');
            tc.verifyEqual(R([R.id] == idE).note, "ecm");
        end

        function undoRefusesWhenTheRegionIdIsNowHeldByAnotherRegion(tc)
            [e, ~] = tc.twoChannels('secJ');
            id = e.addRegion(struct('kind', 'reference', 'xy', square(50, 50, 10), 'note', 'mine'));
            e.removeRegion(id);
            json = e.Paths.json;
            J = jsondecode(fileread(json));             % e.g. written by an older version
            J.regions = {struct('id', id, 'kind', 'reference', 'scope', 'image', ...
                'xy', {num2cell([0 0; 9 0; 9 9], 2)}, 'note', 'theirs')};
            curation.AtomicIO.writeText(json, jsonencode(J));
            before = fileread(json);
            tc.verifyError(@() e.undo(), 'curation:Store:regionConflict');
            tc.verifyEqual(fileread(json), before, 'nothing is written');
            tc.verifyTrue(e.CanUndo, 'the undo step is kept');
            tc.verifyEmpty(e.regions(), 'the store is unchanged');
        end

        function nextRegionIdIsKeptAtTheTopOfTheJson(tc)
            [e, pv] = tc.twoChannels('secK');
            a = e.addRegion(struct('kind', 'reference', 'xy', square(50, 50, 10)));
            b = pv.addRegion(struct('kind', 'reference', 'xy', square(80, 80, 10)));
            pv.removeRegion(b);
            c = e.addRegion(struct('kind', 'reference', 'xy', square(90, 90, 10)));
            tc.verifyGreaterThan(c, b, 'the highest id, removed, is not handed out again');
            J = jsondecode(fileread(e.Paths.json));
            tc.verifyEqual(J.nextRegionId, max([a b c]) + 1);
        end
    end

    methods (Access = private)
        function s = mem(tc, xy)
            s = curation.Store.fromTable(mkLocs(xy), struct('Key', 'ECM1', 'UmPerPixel', 1, 'Reviewer', 'tester'));
            tc.addTeardown(@() closeQuiet(s));
        end

        function [e, pv, pe] = twoChannels(tc, base)
            pe = fullfile(tc.Dir, [base '_proj_ECM1_locs.csv']);
            pp = fullfile(tc.Dir, [base '_proj_PV2_locs.csv']);
            writetable(mkLocs([100 100; 200 100; 300 100; 400 100]), pe);
            writetable(mkLocs([110 110; 210 110; 310 110]), pp);
            e = curation.Store.openCsv(pe, struct('AutosaveDelay', 0, 'Reviewer', 'tester'));
            tc.addTeardown(@() closeQuiet(e));
            pv = curation.Store.openCsv(pp, struct('AutosaveDelay', 0, 'Reviewer', 'tester'));
            tc.addTeardown(@() closeQuiet(pv));
        end
    end
end

function L = mkLocs(xy)
n = size(xy, 1);
L = table(xy(:, 1), xy(:, 2), zeros(n, 1), linspace(0.5, 0.9, n)', repmat("img.tif", n, 1), zeros(n, 1), ...
    (1:n)', 'VariableNames', {'X', 'Y', 'class', 'score', 'imgName', 'thr', 'rescore'});
end

function xy = square(cx, cy, h)
xy = [cx - h, cy - h; cx + h, cy - h; cx + h, cy + h; cx - h, cy + h];
end

function id = idAt(s, x, y)
T = s.T;
k = find(abs(T.X - x) < 0.011 & abs(T.Y - y) < 0.011);
assert(numel(k) == 1, 'expected one row at (%g, %g), found %d', x, y, numel(k));
id = T.CellID(k);
end

function closeQuiet(s)
try
    if isvalid(s), s.close(); end
catch
end
end

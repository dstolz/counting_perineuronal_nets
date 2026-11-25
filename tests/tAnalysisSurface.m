classdef tAnalysisSurface < matlab.unittest.TestCase
    %tAnalysisSurface  cellanalysis.Surface: the tissue and the brain surface are found in a picture, the
    %   frame is never surface, a ventricle is not the outside, a person's choices and a traced line come
    %   on top, and distances, normals and tissue areas are right to a few micrometers.
    %
    %   Pictures are synthetic: tissue at about 100 with noise, empty space at 0 with a little noise.
    %
    %   Run on the hidden desktop: pwsh -File tools\Run-Tests.ps1 tAnalysisSurface

    properties (Constant)
        Um = 1.657
    end

    methods (Static)
        function img = tissue(H, W, emptyMask, seed)
            s = RandStream('mt19937ar', 'Seed', seed);
            img = 100 + 12 * randn(s, H, W) + 30 * imgaussfilt(randn(s, H, W), 25) * 25;
            img = max(img, 20);
            img(emptyMask) = abs(0.4 * randn(s, nnz(emptyMask), 1));
            img = single(img);
        end

        function [img, edge] = halfPlane(H, W, seed)
            %halfPlane  Empty space left of column EDGE (the surface is the vertical line x = edge + 0.5).
            edge = round(0.3 * W);
            m = false(H, W);
            m(:, 1:edge) = true;
            img = tAnalysisSurface.tissue(H, W, m, seed);
        end
    end

    methods (Test)
        function distanceFromAStraightSurface(tc)
            [img, edge] = tAnalysisSurface.halfPlane(400, 600, 1);
            S = cellanalysis.Surface.detect(img, tc.Um);
            tc.verifyTrue(S.Ok, char(S.Message));
            tc.verifyEqual(S.Mode, "auto");
            x = (edge + [20 80 200 290])';
            xy = [x, repmat(200, numel(x), 1)];
            d = cellanalysis.Surface.distanceAt(S, xy);
            expected = (x - (edge + 0.5)) * tc.Um;
            tc.verifyEqual(d, expected, 'AbsTol', 2.5 * tc.Um * S.Factor, 'distance to the edge of the tissue');
            % the frame is not surface: a cell beside the right edge of the picture is far from the surface
            far = cellanalysis.Surface.distanceAt(S, [598 200]);
            tc.verifyGreaterThan(far, 0.9 * (598 - edge) * tc.Um);
            tc.verifyTrue(all(cellanalysis.Surface.inTissue(S, xy)));
            tc.verifyFalse(cellanalysis.Surface.inTissue(S, [10 200]));
            tc.verifyEqual(cellanalysis.Surface.distanceAt(S, [10 200]), 0, 'outside the tissue the distance is 0');
            tc.verifyEqual(numel(S.Lines), 1, 'one stretch of surface');
            tc.verifyEqual(mean(S.Lines{1}(:, 1)), edge + 0.5, 'AbsTol', 2 * S.Factor, 'the drawn line is on the edge');
        end

        function theNormalPointsIntoTheTissue(tc)
            img = tAnalysisSurface.halfPlane(400, 600, 2);
            S = cellanalysis.Surface.detect(img, tc.Um);
            n = cellanalysis.Surface.normalAt(S, [300 200; 400 120]);
            tc.verifyEqual(n, [1 0; 1 0], 'AbsTol', 0.1);
        end

        function theSameUnderAnyGainAndOffset(tc)
            img = tAnalysisSurface.halfPlane(300, 400, 3);
            A = cellanalysis.Surface.detect(img, tc.Um);
            B = cellanalysis.Surface.detect(37 * img + 500, tc.Um);
            tc.verifyTrue(B.Ok);
            tc.verifyLessThan(nnz(A.Tissue ~= B.Tissue) / numel(A.Tissue), 0.002, 'the tissue does not depend on the scale');
            C = cellanalysis.Surface.detect({img, 3 * img + 7}, tc.Um);
            tc.verifyLessThan(nnz(A.Tissue ~= C.Tissue) / numel(A.Tissue), 0.002, 'nor on how many pages show it');
        end

        function aFrameFullOfTissueHasNoSurface(tc)
            img = tAnalysisSurface.tissue(300, 400, false(300, 400), 4);
            S = cellanalysis.Surface.detect(img, tc.Um);
            tc.verifyFalse(S.Ok);
            tc.verifySubstring(S.Message, 'trace it');
            tc.verifyTrue(all(isnan(cellanalysis.Surface.distanceAt(S, [100 100; 200 200]))));
            tc.verifyTrue(all(cellanalysis.Surface.inTissue(S, [100 100; 200 200])));
            tc.verifyTrue(all(isnan(cellanalysis.Surface.depthArea(S, 0:50:200))));
        end

        function aVentricleIsNotTheOutside(tc)
            H = 500; W = 700;
            [img, edge] = tAnalysisSurface.halfPlane(H, W, 5);
            [X, Y] = meshgrid(1:W, 1:H);
            hole = hypot(X - 520, Y - 250) < 70;                     % a ventricle, 232 um across
            img(hole) = 0;
            cell1 = [440 250];                                        % 10 px from the hole, 230 px from the outside
            S = cellanalysis.Surface.detect(img, tc.Um);
            tc.verifyTrue(S.Ok);
            tc.verifyEqual(nnz(S.AreaUsed), 1, 'only the largest empty area is surface');
            tc.verifyEqual(numel(S.AreaUsed), 2);
            tc.verifyEqual(cellanalysis.Surface.distanceAt(S, cell1), (440 - edge - 0.5) * tc.Um, 'AbsTol', 8);
            tc.verifyNotEmpty(S.OtherLines, 'the ventricle''s edge is drawn as "not surface"');
            tc.verifyFalse(cellanalysis.Surface.inTissue(S, [520 250]), 'the ventricle is not tissue');

            A = cellanalysis.Surface.detect(img, tc.Um, struct('Mode', "all"));
            tc.verifyEqual(cellanalysis.Surface.distanceAt(A, cell1), 10 * tc.Um, 'AbsTol', 8, 'every empty area: the hole counts');

            % a person switches the ventricle on, or the outside off
            I = cellanalysis.Surface.detect(img, tc.Um, struct('Include', [520 250]));
            tc.verifyEqual(nnz(I.AreaUsed), 2);
            tc.verifyEqual(cellanalysis.Surface.distanceAt(I, cell1), 10 * tc.Um, 'AbsTol', 8);
            E = cellanalysis.Surface.detect(img, tc.Um, struct('Include', [520 250], 'Exclude', [20 100]));
            tc.verifyEqual(nnz(E.AreaUsed), 1);
            tc.verifyEqual(cellanalysis.Surface.distanceAt(E, [edge + 30, 250]), (520 - 70 - edge - 30) * tc.Um, 'AbsTol', 10, ...
                'only the ventricle is surface now');
            N = cellanalysis.Surface.detect(img, tc.Um, struct('Exclude', [20 100]));
            tc.verifyFalse(N.Ok, 'nothing left to be surface');
            tc.verifySubstring(N.Message, 'switched off');
            tc.verifyEqual(cellanalysis.Surface.areaAt(S, [520 250]) > 0, true);
            tc.verifyEqual(cellanalysis.Surface.areaAt(S, [300 250]), 0, 'tissue is no empty area');
        end

        function aShredAtTheFrameDoesNotSplitTheOutside(tc)
            H = 500; W = 600;
            [img, edge] = tAnalysisSurface.halfPlane(H, W, 6);
            s = RandStream('mt19937ar', 'Seed', 60);
            img(240:300, 1:edge) = single(90 + 8 * randn(s, 61, edge));   % tissue reaching the left frame: 100 um wide
            S = cellanalysis.Surface.detect(img, tc.Um);
            tc.verifyEqual(numel(S.AreaUsed), 2, 'two empty areas');
            tc.verifyTrue(all(S.AreaUsed), 'both are the outside');
            d = cellanalysis.Surface.distanceAt(S, [edge + 60, 60; edge + 60, 440]);
            tc.verifyEqual(d, [1; 1] * 59.5 * tc.Um, 'AbsTol', 8, 'the surface is near above and below the shred');
            % a long stretch of tissue along the frame does part them
            B = cellanalysis.Surface.detect(img, tc.Um, struct('BridgeUm', 50));
            tc.verifyEqual(nnz(B.AreaUsed), 1);
        end

        function aTracedLineIsTheSurface(tc)
            img = tAnalysisSurface.tissue(300, 400, false(300, 400), 7);
            line = [50 20; 50 280];                                  % vertical, x = 50
            S = cellanalysis.Surface.detect(img, tc.Um, struct('Mode', "traced", 'Line', line));
            tc.verifyTrue(S.Ok, char(S.Message));
            x = [60 150 390]';
            d = cellanalysis.Surface.distanceAt(S, [x, [150; 150; 150]]);
            tc.verifyEqual(d, (x - 50) * tc.Um, 'AbsTol', 2 * tc.Um * S.Factor);
            tc.verifyEqual(S.Lines{1}, line);
            T = cellanalysis.Surface.detect(img, tc.Um, struct('Mode', "traced"));
            tc.verifyFalse(T.Ok, 'no line yet');
            tc.verifySubstring(T.Message, 'No surface line');
        end

        function tissueAreaPerDepth(tc)
            H = 400; W = 600;
            [img, edge] = tAnalysisSurface.halfPlane(H, W, 8);
            S = cellanalysis.Surface.detect(img, tc.Um);
            edges = 0:50:400;
            a = cellanalysis.Surface.depthArea(S, edges);
            want = 50 * H * tc.Um;                                   % a strip 50 um deep, as long as the picture is high
            tc.verifyEqual(a(2:end - 1), repmat(want, 1, numel(a) - 2), 'RelTol', 0.08);
            tc.verifyEqual(sum(a), min(400, (W - edge) * tc.Um) * H * tc.Um, 'RelTol', 0.03);
            % a region that is left out of the area, and one that limits it
            box = [edge + 1, 1; W, 1; W, H / 2; edge + 1, H / 2];    % the upper half of the tissue
            ex = cellanalysis.Surface.depthArea(S, edges, struct('Exclude', {{box}}));
            tc.verifyEqual(sum(ex), sum(a) / 2, 'RelTol', 0.04);
            in = cellanalysis.Surface.depthArea(S, edges, struct('Include', {{box}}));
            tc.verifyEqual(sum(in), sum(a) / 2, 'RelTol', 0.04);
        end

        function aLineAtAGivenDepth(tc)
            % the border of the band whose cells "Reject near surface" leaves out
            [img, edge] = tAnalysisSurface.halfPlane(400, 600, 11);
            S = cellanalysis.Surface.detect(img, tc.Um);
            L = cellanalysis.Surface.depthLines(S, 50);
            tc.assertNotEmpty(L);
            pts = vertcat(L{:});
            tc.verifyEqual(median(pts(:, 1)), edge + 0.5 + 50 / tc.Um, 'AbsTol', 2 * S.Factor, ...
                'the line runs 50 um into the tissue');
            inner = pts(:, 1) > 5 & pts(:, 1) < 595 & pts(:, 2) > 5 & pts(:, 2) < 395;
            tc.verifyEqual(cellanalysis.Surface.distanceAt(S, pts(inner, :)), repmat(50, nnz(inner), 1), 'AbsTol', 1, ...
                'every point of it is 50 um from the surface');
            tc.verifyEmpty(cellanalysis.Surface.depthLines(S, 0), 'no band, no line');
            none = cellanalysis.Surface.detect(tAnalysisSurface.tissue(300, 400, false(300, 400), 12), tc.Um);
            tc.verifyEmpty(cellanalysis.Surface.depthLines(none, 50), 'no surface, no line');
        end

        function smallHolesAndDebrisAreIgnored(tc)
            H = 400; W = 600;
            [img, edge] = tAnalysisSurface.halfPlane(H, W, 9);
            [X, Y] = meshgrid(1:W, 1:H);
            img(hypot(X - 400, Y - 200) < 12) = 0;                   % a vessel, 40 um across
            s = RandStream('mt19937ar', 'Seed', 90);
            dirt = hypot(X - 60, Y - 300) < 10;                      % debris outside
            img(dirt) = single(100 + 5 * randn(s, nnz(dirt), 1));
            S = cellanalysis.Surface.detect(img, tc.Um);
            tc.verifyEqual(numel(S.AreaUsed), 1, 'the vessel is not an empty area');
            tc.verifyTrue(cellanalysis.Surface.inTissue(S, [400 200]));
            tc.verifyFalse(cellanalysis.Surface.inTissue(S, [60 300]), 'debris is not tissue');
            tc.verifyEqual(cellanalysis.Surface.distanceAt(S, [edge + 50, 300]), 49.5 * tc.Um, 'AbsTol', 8);
        end

        function fullResolutionTissueMask(tc)
            [img, edge] = tAnalysisSurface.halfPlane(301, 403, 10);   % sizes that are no multiple of the factor
            S = cellanalysis.Surface.detect(img, tc.Um);
            M = cellanalysis.Surface.tissueFull(S);
            tc.verifySize(M, [301 403]);
            tc.verifyFalse(M(150, edge - 10));
            tc.verifyTrue(M(150, edge + 10));
            G = cellanalysis.Surface.tissueFull(S, 20);
            tc.verifyTrue(G(150, edge - 8), 'grown by 20 um');
        end

        function badInputIsRefused(tc)
            tc.verifyError(@() cellanalysis.Surface.detect(ones(10), 0), 'cellanalysis:Surface:badScale');
            tc.verifyError(@() cellanalysis.Surface.detect({ones(10), ones(11)}, 1), 'cellanalysis:Surface:badPage');
            tc.verifyError(@() cellanalysis.Surface.detect(ones(10), 1, struct('Mode', "nearest")), 'cellanalysis:Surface:badOption');
            tc.verifyError(@() cellanalysis.Surface.detect(ones(10), 1, struct('Nope', 1)), 'cellanalysis:Surface:badOption');
        end

        function theHashFollowsTheDefinition(tc)
            h = @cellanalysis.Surface.hashOf;
            tc.verifyEqual(h("auto", [], [], []), h("auto", [1 2; 3 4], [], []), 'a stored line does not matter while it is not used');
            tc.verifyNotEqual(h("auto", [], [5 6], []), h("auto", [], [], []));
            tc.verifyNotEqual(h("auto", [], [5 6], []), h("auto", [], [], [5 6]));
            tc.verifyNotEqual(h("traced", [1 2; 3 4]), h("traced", [1 2; 3 5]));
            tc.verifyNotEqual(h("all", []), h("auto", []));
        end
    end
end

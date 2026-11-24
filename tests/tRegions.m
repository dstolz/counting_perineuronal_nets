classdef tRegions < matlab.unittest.TestCase
    % Tests for curation.Regions (pure data in, data out; reads .roi files).

    properties
        Dir
    end

    methods (TestMethodSetup)
        function mkdir_(tc)
            tc.Dir = tempname;
            mkdir(tc.Dir);
            tc.addTeardown(@() rmdir(tc.Dir, 's'));
        end
    end

    methods (Static)
        function b = be16(v), b = typecast(swapbytes(int16(v)), 'uint8'); end
        function b = be32f(v), b = typecast(swapbytes(single(v)), 'uint8'); end

        function p = writeRoi(dirname, name, type, tlbr, nCoords, body, options, strokeWidth)
            % Byte-exact ImageJ ROI: 64-byte header (big-endian) followed by body bytes.
            if nargin < 7, options = 0; end
            if nargin < 8, strokeWidth = 0; end
            h = zeros(1, 64, 'uint8');
            h(1:4) = uint8('Iout');
            h(5:6) = tRegions.be16(228);
            h(7) = type;
            h(9:16) = [tRegions.be16(tlbr(1)) tRegions.be16(tlbr(2)) tRegions.be16(tlbr(3)) tRegions.be16(tlbr(4))];
            h(17:18) = typecast(swapbytes(uint16(nCoords)), 'uint8');
            h(35:36) = tRegions.be16(strokeWidth);
            h(51:52) = tRegions.be16(options);
            p = fullfile(dirname, name);
            fid = fopen(p, 'w'); fwrite(fid, [h uint8(body)], 'uint8'); fclose(fid);
        end

        function p = writeLine(dirname, name, p1, p2, w)
            p = tRegions.writeRoi(dirname, name, 3, [0 0 0 0], 0, [], 0, w);
            fid = fopen(p, 'r+'); fseek(fid, 18, 'bof');
            fwrite(fid, [tRegions.be32f(p1(1)) tRegions.be32f(p1(2)) tRegions.be32f(p2(1)) tRegions.be32f(p2(2))], 'uint8');
            fclose(fid);
        end

        function r = sq(x0, y0, w, h, varargin)
            r = curation.Regions.make("exclude", [x0 y0; x0+w y0; x0+w y0+h; x0 y0+h], varargin{:});
        end
    end

    methods (Test)
        function makeDefaults(tc)
            r = tRegions.sq(0, 0, 10, 10);
            tc.verifyEqual(r.kind, "exclude");
            tc.verifyEqual(r.scope, "image");
            tc.verifyEqual(r.id, 0);
            tc.verifyEqual(r.note, "");
            r = tRegions.sq(0, 0, 10, 10, struct('scope', "ECM1", 'note', "hi", 'id', 7));
            tc.verifyEqual([r.scope r.note r.id], ["ECM1" "hi" "7"]);
            % closing vertex dropped
            r = curation.Regions.make("analysis", [0 0; 1 0; 1 1; 0 0]);
            tc.verifyEqual(size(r.xy), [3 2]);
            tc.verifyError(@() curation.Regions.make("bogus", [0 0; 1 0; 1 1]), 'curation:Regions:badInput');
            tc.verifyError(@() curation.Regions.make("exclude", [0 0; 1 0]), 'curation:Regions:badInput');
        end

        function addRemoveIds(tc)
            R = curation.Regions.normalize([]);
            tc.verifyEqual(size(R), [0 1]);
            R = curation.Regions.add(R, tRegions.sq(0, 0, 1, 1));
            R = curation.Regions.add(R, tRegions.sq(0, 0, 1, 1));
            tc.verifyEqual([R.id], [1 2]);
            R = curation.Regions.add(R, tRegions.sq(0, 0, 1, 1, struct('id', 10)));
            R = curation.Regions.add(R, tRegions.sq(0, 0, 1, 1));
            tc.verifyEqual([R.id], [1 2 10 11]);
            R = curation.Regions.remove(R, 2);
            tc.verifyEqual([R.id], [1 10 11]);
            R = curation.Regions.remove(R, 99);
            tc.verifyEqual(numel(R), 3);
            tc.verifyEqual(size(R), [3 1]);
            R = curation.Regions.add(R, tRegions.sq(0, 0, 1, 1));
            tc.verifyEqual(R(end).id, 12);
            tc.verifyError(@() curation.Regions.add(R, tRegions.sq(0, 0, 1, 1, struct('id', 10))), 'curation:Regions:duplicateId');
            R = curation.Regions.remove(curation.Regions.remove(curation.Regions.remove(curation.Regions.remove(R, 1), 10), 11), 12);
            tc.verifyEqual(size(R), [0 1]);
            R = curation.Regions.add(R, tRegions.sq(0, 0, 1, 1));
            tc.verifyEqual(R.id, 1);
        end

        function containsSquareAndEdges(tc)
            R = curation.Regions.add(curation.Regions.normalize([]), tRegions.sq(10, 10, 20, 20));
            pts = [15 15; 10 10; 30 20; 20 30; 9.99 15; 31 31; 20 20];
            tf = curation.Regions.contains(R, pts);
            tc.verifyEqual(tf, [true; true; true; true; false; false; true]);
            tc.verifyEqual(size(curation.Regions.contains(R, zeros(0, 2))), [0 1]);
        end

        function containsConcave(tc)
            % U shape: notch between x 4..6 open at the top
            u = [0 0; 10 0; 10 10; 6 10; 6 4; 4 4; 4 10; 0 10];
            R = curation.Regions.add(curation.Regions.normalize([]), curation.Regions.make("exclude", u));
            tf = curation.Regions.contains(R, [2 8; 8 8; 5 8; 5 2; 5 4; 5 5]);
            tc.verifyEqual(tf, [true; true; false; true; true; false]);
        end

        function containsEmptyAndMultiple(tc)
            tc.verifyEqual(size(curation.Regions.contains(curation.Regions.normalize([]), [1 2; 3 4])), [2 0]);
            R = curation.Regions.add(curation.Regions.normalize([]), tRegions.sq(0, 0, 10, 10));
            R = curation.Regions.add(R, tRegions.sq(5, 5, 10, 10));
            tf = curation.Regions.contains(R, [2 2; 7 7; 12 12; 20 20]);
            tc.verifyEqual(tf, logical([1 0; 1 1; 0 1; 0 0]));
        end

        function excludedKindAndScope(tc)
            R = curation.Regions.normalize([]);
            R = curation.Regions.add(R, tRegions.sq(0, 0, 10, 10));                                   % exclude, image
            R = curation.Regions.add(R, tRegions.sq(100, 0, 10, 10, struct('scope', "ECM1")));         % exclude, ECM1
            R = curation.Regions.add(R, curation.Regions.make("analysis", [200 0; 210 0; 210 10; 200 10]));
            R = curation.Regions.add(R, curation.Regions.make("reference", [300 0; 310 0; 310 10; 300 10]));
            pts = [5 5; 105 5; 205 5; 305 5; 500 500];
            tc.verifyEqual(curation.Regions.excluded(R, pts, "ECM1"), [true; true; false; false; false]);
            tc.verifyEqual(curation.Regions.excluded(R, pts, "PV2"), [true; false; false; false; false]);
            tc.verifyEqual(curation.Regions.excluded(curation.Regions.normalize([]), pts, "ECM1"), false(5, 1));
            tc.verifyEqual(size(curation.Regions.excluded(R, zeros(0, 2), "ECM1")), [0 1]);
        end

        function inAnalysisNoneOneTwo(tc)
            pts = [5 5; 105 5; 500 500];
            R = curation.Regions.normalize([]);
            tc.verifyEqual(curation.Regions.inAnalysis(R, pts, "ECM1"), true(3, 1));
            R = curation.Regions.add(R, tRegions.sq(0, 0, 10, 10));      % exclude does not count
            tc.verifyEqual(curation.Regions.inAnalysis(R, pts, "ECM1"), true(3, 1));
            R = curation.Regions.add(R, curation.Regions.make("analysis", [0 0; 20 0; 20 20; 0 20]));
            tc.verifyEqual(curation.Regions.inAnalysis(R, pts, "ECM1"), [true; false; false]);
            R = curation.Regions.add(R, curation.Regions.make("analysis", [100 0; 120 0; 120 20; 100 20]));
            tc.verifyEqual(curation.Regions.inAnalysis(R, pts, "ECM1"), [true; true; false]);
            % a region scoped to another source does not apply
            R2 = curation.Regions.add(curation.Regions.normalize([]), ...
                curation.Regions.make("analysis", [0 0; 20 0; 20 20; 0 20], struct('scope', "PV2")));
            tc.verifyEqual(curation.Regions.inAnalysis(R2, pts, "ECM1"), true(3, 1));
            tc.verifyEqual(curation.Regions.inAnalysis(R2, pts, "PV2"), [true; false; false]);
        end

        function normalizeJsonRoundTrips(tc)
            a = tRegions.sq(0, 0, 10, 10);
            b = curation.Regions.make("analysis", [0 0; 5 0; 5 5; 0 5; -1 2], struct('scope', "ECM1", 'note', "five"));  % 5 vertices
            c = curation.Regions.make("reference", [1 1; 2 1; 2 2; 1 2], struct('note', ""));
            for list = {{}, {a}, {a, c}, {a, b}, {a, b, c}}
                R = curation.Regions.normalize([]);
                for k = 1:numel(list{1}), R = curation.Regions.add(R, list{1}{k}); end
                d = jsondecode(jsonencode(R));
                N = curation.Regions.normalize(d);
                tc.verifyEqual(size(N), size(R));
                tc.verifyEqual(fieldnames(N), fieldnames(curation.Regions.template()));
                for k = 1:numel(R)
                    tc.verifyEqual(N(k).id, R(k).id);
                    tc.verifyEqual(N(k).kind, R(k).kind);
                    tc.verifyEqual(N(k).scope, R(k).scope);
                    tc.verifyEqual(N(k).note, R(k).note);
                    tc.verifyEqual(N(k).xy, R(k).xy);
                end
                % idempotent
                tc.verifyEqual(curation.Regions.normalize(N), N);
            end
        end

        function normalizeOddShapes(tc)
            % cell array of structs with differing shapes / field sets
            c = {struct('id', 3, 'kind', 'exclude', 'scope', 'image', 'xy', [0 0; 1 0; 1 1], 'note', 'x'), ...
                 struct('kind', 'analysis', 'xy', {{[0 0], [4 0], [4 4], [0 4]}})};
            N = curation.Regions.normalize(c);
            tc.verifyEqual(size(N), [2 1]);
            tc.verifyEqual(N(2).xy, [0 0; 4 0; 4 4; 0 4]);
            tc.verifyEqual(N(2).scope, "image");
            tc.verifyEqual(N(2).id, 0);
            tc.verifyEqual(N(1).note, "x");
            % real jsondecode of mixed vertex-count arrays and of hand-written JSON
            d = jsondecode('[{"id":1,"kind":"exclude","scope":"image","xy":[[0,0],[1,0],[1,1]],"note":""},{"id":2,"kind":"analysis","scope":"ECM1","xy":[[0,0],[4,0],[4,4],[0,4]],"note":null}]');
            N = curation.Regions.normalize(d);
            tc.verifyEqual(size(N), [2 1]);
            tc.verifyEqual(N(2).xy, [0 0; 4 0; 4 4; 0 4]);
            tc.verifyEqual(N(2).note, "");
            d = jsondecode('{"id":5,"kind":"reference","scope":"image","xy":[[0,0],[1,0],[1,1]],"note":"n"}');
            N = curation.Regions.normalize(d);
            tc.verifyEqual(size(N), [1 1]);
            tc.verifyEqual(N.id, 5);
            tc.verifyEqual(curation.Regions.normalize(jsondecode('[]')), curation.Regions.normalize([]));
        end

        function importRect(tc)
            % ImageJ rect left=10 top=20 width=30 height=40 -> bottom=60 right=40
            p = tRegions.writeRoi(tc.Dir, 'r.roi', 1, [20 10 60 40], 0, []);
            r = curation.Regions.importImageJRoi(p);
            tc.verifyEqual(r.kind, "reference");
            tc.verifyEqual(r.scope, "image");
            tc.verifyEqual(r.xy, [10.5 20.5; 40.5 20.5; 40.5 60.5; 10.5 60.5]);
            % Convention: covers MATLAB pixel centres 11..40 x 21..60 = 30 x 40 pixels
            [xx, yy] = meshgrid(1:100, 1:100);
            in = inpolygon(xx, yy, r.xy(:, 1), r.xy(:, 2));
            tc.verifyEqual(nnz(in), 30 * 40);
            tc.verifyEqual([min(xx(in)) max(xx(in)) min(yy(in)) max(yy(in))], [11 40 21 60]);
            tc.verifyEqual(curation.Regions.areaUm2(r, 0.5), 30 * 40 * 0.25, 'AbsTol', 1e-9);
            r = curation.Regions.importImageJRoi(p, struct('kind', "exclude", 'scope', "ECM1", 'note', "box", 'id', 4));
            tc.verifyEqual([r.kind r.scope r.note r.id], ["exclude" "ECM1" "box" "4"]);
        end

        function importPolygon(tc)
            xs = [0 50 50 0]; ys = [0 0 30 30];
            body = [tRegions.be16(xs) tRegions.be16(ys)];
            p = tRegions.writeRoi(tc.Dir, 'p.roi', 0, [100 200 130 250], 4, body);
            r = curation.Regions.importImageJRoi(p);
            tc.verifyEqual(r.xy, [200.5 100.5; 250.5 100.5; 250.5 130.5; 200.5 130.5]);
            for t = [7 8]
                p = tRegions.writeRoi(tc.Dir, sprintf('p%d.roi', t), t, [100 200 130 250], 4, body);
                tc.verifyEqual(curation.Regions.importImageJRoi(p).xy, r.xy);
            end
        end

        function importSubpixelPolygon(tc)
            xs = [0 50 50]; ys = [0 0 30];
            xf = [200.25 250.5 250.5]; yf = [100.75 100.75 130.125];
            body = [tRegions.be16(xs) tRegions.be16(ys) ...
                tRegions.be32f(xf(1)) tRegions.be32f(xf(2)) tRegions.be32f(xf(3)) ...
                tRegions.be32f(yf(1)) tRegions.be32f(yf(2)) tRegions.be32f(yf(3))];
            p = tRegions.writeRoi(tc.Dir, 'sp.roi', 0, [100 200 130 250], 3, body, 128);
            r = curation.Regions.importImageJRoi(p);
            tc.verifyEqual(r.xy, [xf' + 0.5, yf' + 0.5]);
        end

        function importOval(tc)
            p = tRegions.writeRoi(tc.Dir, 'o.roi', 2, [0 0 40 100], 0, []);   % width 100, height 40
            r = curation.Regions.importImageJRoi(p);
            tc.verifyEqual(size(r.xy), [64 2]);
            tc.verifyEqual(min(r.xy), [0.5 0.5], 'AbsTol', 1e-9);
            c = mean(r.xy);
            tc.verifyEqual(c, [50.5 20.5], 'AbsTol', 1e-9);
            tc.verifyEqual(max(r.xy(:, 1)) - min(r.xy(:, 1)), 100, 'AbsTol', 1e-9);
            tc.verifyEqual(max(r.xy(:, 2)) - min(r.xy(:, 2)), 40, 'AbsTol', 1e-9);
            a = curation.Regions.areaUm2(r, 1);
            tc.verifyEqual(a, pi * 50 * 20, 'RelTol', 0.01);
            tc.verifyLessThan(a, pi * 50 * 20);
        end

        function importWideLine(tc)
            % horizontal: (0,0)->(100,0), width 20
            r = curation.Regions.importImageJRoi(tRegions.writeLine(tc.Dir, 'h.roi', [0 0], [100 0], 20));
            tc.verifyEqual(r.xy, [0 10; 100 10; 100 -10; 0 -10] + 0.5, 'AbsTol', 1e-5);
            tc.verifyEqual(curation.Regions.areaUm2(r, 1), 2000, 'AbsTol', 1e-3);
            % vertical: (50,10)->(50,110), width 30
            r = curation.Regions.importImageJRoi(tRegions.writeLine(tc.Dir, 'v.roi', [50 10], [50 110], 30));
            tc.verifyEqual(r.xy, [35 10; 35 110; 65 110; 65 10] + 0.5, 'AbsTol', 1e-5);
            tc.verifyEqual(curation.Regions.areaUm2(r, 1), 3000, 'AbsTol', 1e-3);
            % diagonal 3-4-5: (0,0)->(300,400), width 100: normal = (-0.8, 0.6)*50 = (-40, 30)
            r = curation.Regions.importImageJRoi(tRegions.writeLine(tc.Dir, 'd.roi', [0 0], [300 400], 100));
            tc.verifyEqual(r.xy, [-40 30; 260 430; 340 370; 40 -30] + 0.5, 'AbsTol', 1e-4);
            tc.verifyEqual(curation.Regions.areaUm2(r, 1), 500 * 100, 'AbsTol', 1e-2);   % length 500 x width 100
            % side lengths: long sides = line length, short sides = width
            d = diff([r.xy; r.xy(1, :)]);
            L = hypot(d(:, 1), d(:, 2));
            tc.verifyEqual(L', [500 100 500 100], 'AbsTol', 1e-3);
            % orientation of the long axis equals the line's
            ang = atan2d(d(1, 2), d(1, 1));
            tc.verifyEqual(ang, atan2d(400, 300), 'AbsTol', 1e-3);
        end

        function importErrors(tc)
            p = tRegions.writeLine(tc.Dir, 'thin.roi', [0 0], [100 0], 1);
            tc.verifyError(@() curation.Regions.importImageJRoi(p), 'curation:Regions:unsupportedRoi');
            p = tRegions.writeLine(tc.Dir, 'thin0.roi', [0 0], [100 0], 0);
            tc.verifyError(@() curation.Regions.importImageJRoi(p), 'curation:Regions:unsupportedRoi');
            p = tRegions.writeRoi(tc.Dir, 'pt.roi', 10, [0 0 1 1], 1, tRegions.be16([0 0]));
            try
                curation.Regions.importImageJRoi(p);
                tc.verifyFail('expected an error');
            catch e
                tc.verifyEqual(e.identifier, 'curation:Regions:unsupportedRoi');
                tc.verifySubstring(e.message, 'point');
            end
            p = tRegions.writeRoi(tc.Dir, 'fl.roi', 4, [0 0 1 1], 1, []);
            try
                curation.Regions.importImageJRoi(p);
                tc.verifyFail('expected an error');
            catch e
                tc.verifyEqual(e.identifier, 'curation:Regions:unsupportedRoi');
                tc.verifySubstring(e.message, 'freeline');
            end
            q = fullfile(tc.Dir, 'junk.roi'); fid = fopen(q, 'w'); fwrite(fid, zeros(1, 70, 'uint8')); fclose(fid);
            tc.verifyError(@() curation.Regions.importImageJRoi(q), 'curation:Regions:badRoi');
            tc.verifyError(@() curation.Regions.importImageJRoi(fullfile(tc.Dir, 'missing.roi')), 'curation:Regions:badRoi');
        end

        function importRealRoiNas(tc)
            f = fullfile('S:\ANALYSIS_BACKUPS\Daniel\HISTOLOGY\PNAS_REPLICATION\SUBJ-ID-1127', ...
                'SUBJ-ID-1127IHC_ECM26A260519S2_1A_L_WFA-PV_Z3_260511_1', ...
                'SUBJ-ID-1127IHC_ECM26A260519S2_1A_L_WFA-PV_Z3_260511_1_proj_roi.roi');
            tc.assumeTrue(isfile(f), 'S:\ NAS ROI file not reachable');
            r = curation.Regions.importImageJRoi(f);
            % header read independently by hand: line (120,1050)->(1224,1530), width 600
            p1 = [120 1050] + 0.5; p2 = [1224 1530] + 0.5;
            L = norm(p2 - p1);
            tc.verifyEqual(size(r.xy), [4 2]);
            tc.verifyEqual(mean(r.xy), (p1 + p2) / 2, 'AbsTol', 1e-3);
            d = diff([r.xy; r.xy(1, :)]); sides = hypot(d(:, 1), d(:, 2))';
            tc.verifyEqual(sides, [L 600 L 600], 'AbsTol', 1e-2);
            tc.verifyEqual(curation.Regions.areaUm2(r, 1), L * 600, 'RelTol', 1e-6);
        end

        function importRealRoiSubj1174(tc)
            root = 'S:\ANALYSIS_BACKUPS\Daniel\HISTOLOGY\PNAS_REPLICATION';
            tc.assumeTrue(isfolder(fullfile(root, 'SUBJ-ID-1174')), 'SUBJ-ID-1174 not on the NAS');
            hits = dir(fullfile(root, 'SUBJ-ID-1174', '*', '*ECM26A260608S1_1A_L_WFA-PV_Z3_260616_1_proj_roi.roi'));
            tc.assumeNotEmpty(hits, 'the 1174 ECM26A260608S1 ROI is not on the NAS');
            r = curation.Regions.importImageJRoi(fullfile(hits(1).folder, hits(1).name));
            p1 = [342 1161] + 0.5; p2 = [1308 1845] + 0.5; L = norm(p2 - p1);
            d = diff([r.xy; r.xy(1, :)]); sides = hypot(d(:, 1), d(:, 2))';
            tc.verifyEqual(mean(r.xy), (p1 + p2) / 2, 'AbsTol', 1e-3);
            tc.verifyEqual(sides, [L 600 L 600], 'AbsTol', 1e-2);
        end

        function areaUm2Basic(tc)
            r = tRegions.sq(0, 0, 10, 20);
            tc.verifyEqual(curation.Regions.areaUm2(r, 1), 200);
            tc.verifyEqual(curation.Regions.areaUm2(r, 0.645), 200 * 0.645^2, 'AbsTol', 1e-9);
        end
    end
end

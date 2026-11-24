classdef tCelldbRun < matlab.unittest.TestCase
%tCelldbRun  celldb.Run and celldb.recordCuration with no lab database client (CELLDB_NO_CLIENT=1).
%
%   Every test runs as on a computer without the CarasLabDB checkout: the provenance sidecar is still
%   written beside the curation files with every field, an unchanged source writes nothing, a changed one
%   names what it replaces, and a failing step warns instead of throwing. (tCelldbClient covers the
%   outbox.) The provenance fallback folder is a temporary one (CELLDB_PROVENANCE_DIR), so nothing is
%   written under %LOCALAPPDATA%.
%
%   Also holds the helper the other tCelldb* classes use to curate a synthetic section (curate, relabel).
%
%   Run: pwsh -File tools\Run-Tests.ps1 tCelldbRun

    properties (Constant)
        Section = "SUBJ-ID-9001IHC_ECM26A260519S2_1A_L_WFA-PV_Z3_260511_1"
    end

    properties
        Folder string
        Fallback string
    end

    methods (TestClassSetup)
        function addPaths(tc)
            here = fileparts(mfilename('fullpath'));
            tc.applyFixture(matlab.unittest.fixtures.PathFixture(fullfile(here, 'fixtures')));
            tc.applyFixture(matlab.unittest.fixtures.PathFixture(fullfile(fileparts(here), 'customizations')));
        end
    end

    methods (TestMethodSetup)
        function withoutClient(tc)
            tc.Folder = string(tempname);
            tc.Fallback = string(tempname);
            mkdir(tc.Folder);
            oldNo = string(getenv("CELLDB_NO_CLIENT"));
            oldFallback = string(getenv("CELLDB_PROVENANCE_DIR"));
            setenv("CELLDB_NO_CLIENT", "1");
            setenv("CELLDB_PROVENANCE_DIR", char(tc.Fallback));
            celldb.available(Refresh = true);
            tc.addTeardown(@() tCelldbRun.restoreEnvironment(oldNo, oldFallback, tc.Folder, tc.Fallback));
        end
    end

    methods (Static)
        function restoreEnvironment(oldNo, oldFallback, varargin)
            setenv("CELLDB_NO_CLIENT", char(oldNo));
            setenv("CELLDB_PROVENANCE_DIR", char(oldFallback));
            celldb.available(Refresh = true);
            for f = string(varargin)
                if isfolder(f)
                    rmdir(f, "s");
                elseif isfile(f)
                    delete(f);
                end
            end
        end

        function c = curate(folder, opts)
            %CURATE A synthetic section curated and completed: its store (open), truth and files.
            %   c = tCelldbRun.curate(folder, BaseName = ...) labels some cells of the ECM1 source, marks it
            %   complete, flushes the snapshot and exports _final.csv, as the GUI does before recordCuration.
            %   The caller closes c.store.
            arguments
                folder (1,1) string
                opts.BaseName (1,1) string = tCelldbRun.Section
            end
            [~, truth] = makeSyntheticDataset(folder, BaseName = opts.BaseName, NumCells = [24 24], ...
                ImageSize = [300 400], Variants = false);
            s = curation.Store.openCsv(truth.paths.ecm1Locs, ...
                struct('AutosaveDelay', 0, 'ImportLegacy', false, 'Reviewer', "tester"));
            ids = double(s.T.CellID);
            s.setLabel(ids(1:6), "Good", "human");
            s.setLabel(ids(7:9), "Bad", "human");
            s.setLabel(ids(10), "Uncertain", "human");
            s.setComplete(true);
            s.flush();
            s.exportFinal(s.Paths.final);
            c = struct("store", s, "truth", truth, "ids", ids, "folder", string(folder));
        end

        function relabel(c, k)
            %RELABEL Label cell number K of the curated section Good and write the files again.
            c.store.setLabel(c.ids(k), "Good", "human");
            c.store.flush();
            c.store.exportFinal(c.store.Paths.final);
        end

        function h = sha256(file)
            fid = fopen(file, "r");
            assert(fid > 0, "Cannot open " + file);
            data = fread(fid, Inf, "*uint8");
            fclose(fid);
            md = java.security.MessageDigest.getInstance("SHA-256");
            md.update(data);
            h = string(lower(reshape(dec2hex(typecast(md.digest(), "uint8"), 2)', 1, [])));
        end

        function r = records(folder)
            %RECORDS The decoded provenance records of FOLDER's .provenance, oldest first (a struct column).
            d = dir(fullfile(folder, ".provenance", "*.json"));
            [~, order] = sort(string({d.name}));
            d = d(order);
            r = cell(numel(d), 1);
            for k = 1:numel(d)
                r{k} = jsondecode(fileread(fullfile(d(k).folder, d(k).name)));
            end
        end
    end

    methods
        function writeFile(~, f, text)
            if ~isfolder(fileparts(f)); mkdir(fileparts(f)); end
            fid = fopen(f, "w");
            fwrite(fid, uint8(char(text)));
            fclose(fid);
        end
    end

    methods (Test)
        function theClientIsOffAndSaysWhy(tc)
            [tf, why] = celldb.available();
            tc.verifyFalse(tf);
            tc.verifySubstring(why, "CELLDB_NO_CLIENT");
            tc.verifyFalse(celldb.capturing());
            tc.verifySubstring(celldb.statusText(), "Lab database");
            tc.verifySubstring(celldb.statusText(), "CELLDB_NO_CLIENT");
        end

        function theSidecarHoldsEveryField(tc)
            c = tCelldbRun.curate(tc.Folder);
            tc.addTeardown(@() delete(c.store));
            roiFile = fullfile(tc.Folder, tc.Section + "_proj_roi.roi");
            tc.writeFile(roiFile, "roi bytes");
            rec = celldb.recordCuration(c.store, ManifestFacts = struct("DetectorTool", "CellDiscovery", ...
                "DetectorModel", "pnn_v2_fasterrcnn_640", "ScorerTool", "CellNeighborResolution", ...
                "ScorerModel", "pnn_v2_scoring_rank_learning"));
            tc.verifyTrue(rec.written);
            tc.verifyFalse(rec.queued);
            tc.verifySubstring(rec.reason, "Recorded locally");
            tc.verifySubstring(rec.reason, "environment");
            tc.verifyTrue(isfile(rec.file));
            tc.verifyTrue(startsWith(rec.file, fullfile(fileparts(c.store.Paths.csv), ".provenance")));

            r = jsondecode(fileread(rec.file));
            tc.verifyEqual(string(r.format), "cellcuration-provenance/1");
            tc.verifyMatches(string(r.run_id), "^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-");
            tc.verifyEqual(string(r.run_id), rec.runId);
            tc.verifyEqual(string(r.app), "counting_perineuronal_nets");
            tc.verifyEqual(string(r.pipeline_name), "counting_perineuronal_nets/curate");
            tc.verifyEqual(string(r.subject_id), "SUBJ-ID-9001");
            tc.verifyMatches(string(r.code_version), "^([0-9a-f]{7,}(-dirty)?|unknown)$");
            tc.verifyEqual(string(r.code_version), celldb.codeVersion());
            tc.verifyNotEmpty(r.matlab_release);
            tc.verifyEqual(string(r.status), "succeeded");
            tc.verifyEqual(string(r.error), "");
            zone = "^\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d\.\d{6}([+-]\d\d:\d\d|Z)$";
            tc.verifyMatches(string(r.started_at), zone);
            tc.verifyMatches(string(r.finished_at), zone);
            tc.verifyTrue(string(r.finished_at) >= string(r.started_at));

            p = r.parameters;
            tc.verifyEqual(string(p.source_key), "ECM1");
            tc.verifyEqual(string(p.channel_kind), "pnn");
            tc.verifyEqual(p.um_per_pixel, c.store.Meta.UmPerPixel);
            tc.verifyEqual(string(p.detector_tool), "CellDiscovery");
            tc.verifyEqual(string(p.detector_model), "pnn_v2_fasterrcnn_640");
            tc.verifyEqual(string(p.scorer_tool), "CellNeighborResolution");
            tc.verifyEqual(string(p.scorer_model), "pnn_v2_scoring_rank_learning");
            tc.verifyEqual(string(p.assist_model_version), "");
            tc.verifyEqual(p.reconcile_tolerance_um, 8);

            a = r.attributes;
            tc.verifyEqual(string(a.app), "CellCurator");
            counts = c.store.counts();
            for f = string(fieldnames(counts))'
                tc.verifyEqual(a.(f), counts.(f), "count " + f);
            end
            tc.verifyEqual(a.good, 6);
            tc.verifyTrue(a.complete);
            tc.verifyEqual(string(a.reviewer), "tester");
            tc.verifyEqual(string(a.subject_number), "9001");
            tc.verifyEqual(string(a.protocol), "IHC_ECM26A");
            tc.verifyEqual(string(a.series), "2");
            tc.verifyEqual(string(a.section_id), "1A");
            tc.verifyEqual(string(a.hemisphere), "L");
            tc.verifyEqual(string(a.stain), "WFA-PV");
            tc.verifyEqual(string(a.variant), "proj");
            tc.verifyEqual(string(a.image_key), tc.Section + "_proj");
            tc.verifyEqual(a.exclusion_regions, 0);

            ins = r.inputs;
            tc.verifyNumElements(ins, 3, "image, roi, detector locs");
            kinds = string({ins.kind});
            tc.verifyEqual(sort(kinds), sort(["section_image", "reference_roi", "detections_csv"]));
            for k = 1:numel(ins)
                tc.verifyEqual(string(ins(k).role), "derived");
                tc.verifyTrue(isfile(string(ins(k).path)));
                tc.verifyEqual(ins(k).bytes, dir(string(ins(k).path)).bytes);
                tc.verifyMatches(string(ins(k).mtime), "^\d{4}-\d\d-\d\dT.*([+-]\d\d:\d\d|Z)$");
            end
            image = ins(kinds == "section_image");
            tc.verifyEqual(string(image.sha256), "", "the 50-60 MB image is not hashed");
            tc.verifyEqual(string(image.format), "tif");
            locs = ins(kinds == "detections_csv");
            tc.verifyEqual(string(locs.sha256), tCelldbRun.sha256(c.truth.paths.ecm1Locs));
            roi = ins(kinds == "reference_roi");
            tc.verifyEqual(string(roi.sha256), tCelldbRun.sha256(roiFile));

            outs = r.outputs;
            tc.verifyNumElements(outs, 2);
            tc.verifyEqual(string(outs(1).path), string(c.store.Paths.csv));
            tc.verifyEqual(string(outs(2).path), string(c.store.Paths.final));
            tc.verifyEqual(string({outs.role}), ["derived", "derived"]);
            tc.verifyEqual(string({outs.kind}), ["curation_csv", "final_csv"]);
            for k = 1:2
                tc.verifyEqual(string(outs(k).sha256), tCelldbRun.sha256(string(outs(k).path)));
                tc.verifyEqual(outs(k).bytes, dir(string(outs(k).path)).bytes);
                tc.verifyMatches(string(outs(k).artifact_id), "^[0-9a-f]{8}-[0-9a-f]{4}-4");
                tc.verifyEqual(string(outs(k).replaces_sha256), "");
            end
        end

        function aNameThatDoesNotFitHasNoSubject(tc)
            c = tCelldbRun.curate(tc.Folder, BaseName = "SYN-0001_sec1");
            tc.addTeardown(@() delete(c.store));
            rec = celldb.recordCuration(c.store);
            tc.verifyTrue(rec.written);
            r = jsondecode(fileread(rec.file));
            tc.verifyEqual(string(r.subject_id), "");
            tc.verifyEqual(string(r.attributes.image_key), "SYN-0001_sec1_proj");
            tc.verifyEqual(string(r.attributes.sample_id), "");
        end

        function aSecondCallWithNothingChangedWritesNothing(tc)
            c = tCelldbRun.curate(tc.Folder);
            tc.addTeardown(@() delete(c.store));
            first = celldb.recordCuration(c.store);
            second = celldb.recordCuration(c.store);
            tc.verifyTrue(first.written);
            tc.verifyFalse(second.written);
            tc.verifyFalse(second.queued);
            tc.verifyEqual(second.file, "");
            tc.verifyEqual(second.reason, "Nothing changed since the last record");
            tc.verifyEqual(second.runId, first.runId);
            tc.verifyEqual(second.previousFile, first.file);
            tc.verifyNumElements(tCelldbRun.records(fileparts(c.store.Paths.csv)), 1);
            forced = celldb.recordCuration(c.store, Force = true);
            tc.verifyTrue(forced.written);
            tc.verifyNumElements(tCelldbRun.records(fileparts(c.store.Paths.csv)), 2);
        end

        function aChangedLabelWritesANewRecordNamingWhatItReplaces(tc)
            c = tCelldbRun.curate(tc.Folder);
            tc.addTeardown(@() delete(c.store));
            first = celldb.recordCuration(c.store);
            r1 = jsondecode(fileread(first.file));
            tCelldbRun.relabel(c, 11);
            second = celldb.recordCuration(c.store);
            tc.verifyTrue(second.written);
            tc.verifyNotEqual(second.runId, first.runId);
            r2 = jsondecode(fileread(second.file));
            tc.verifyEqual(r2.attributes.good, r1.attributes.good + 1);
            for k = 1:2
                tc.verifyNotEqual(string(r2.outputs(k).sha256), string(r1.outputs(k).sha256), "file " + k + " changed");
                tc.verifyEqual(string(r2.outputs(k).replaces_sha256), string(r1.outputs(k).sha256));
                tc.verifyEqual(string(r2.outputs(k).replaces_artifact_id), string(r1.outputs(k).artifact_id));
            end
            third = celldb.recordCuration(c.store);
            tc.verifyFalse(third.written, "compared with the latest record, not the first");
            tc.verifyEqual(third.runId, second.runId);
        end

        function aFailingStepWarnsAndNeverThrows(tc)
            c = tCelldbRun.curate(tc.Folder);
            tc.addTeardown(@() delete(c.store));
            before = tCelldbRun.sha256(c.store.Paths.csv);
            % neither the .provenance folder beside the files nor the fallback folder can be made
            tc.writeFile(fullfile(fileparts(c.store.Paths.csv), ".provenance"), "a file, not a folder");
            if isfolder(tc.Fallback); rmdir(tc.Fallback, "s"); end
            tc.writeFile(tc.Fallback, "a file, not a folder");
            box = containers.Map();
            tc.verifyWarning(@() tCelldbRun.keep(box, celldb.recordCuration(c.store)), "celldb:Provenance");
            rec = box("rec");
            tc.verifyFalse(rec.written);
            tc.verifyFalse(rec.queued);
            tc.verifyEqual(rec.file, "");
            tc.verifyNotEmpty(rec.reason);
            tc.verifyEqual(tCelldbRun.sha256(c.store.Paths.csv), before, "what the app wrote is untouched");

            tc.verifyWarning(@() tCelldbRun.keep(box, celldb.recordCuration(struct())), "celldb:Provenance");
            tc.verifyFalse(box("rec").written);
        end

        function aRunNamesWhatItOverwrote(tc)
            f = fullfile(tc.Folder, "o.txt");
            tc.writeFile(f, "old");
            run = celldb.Run("counting_perineuronal_nets/test_step");
            run.willWrite(f);
            tc.writeFile(f, "new");
            run.output(f);
            r = jsondecode(fileread(run.finish()));
            tc.verifyEqual(string(r.outputs(1).replaces_sha256), tCelldbRun.shaText("old"));
            tc.verifyEqual(string(r.outputs(1).sha256), tCelldbRun.shaText("new"));
        end

        function finishingTwiceWritesOnceAndAFailedRunIsRecorded(tc)
            f = fullfile(tc.Folder, "t.txt");
            tc.writeFile(f, "t");
            run = celldb.Run("counting_perineuronal_nets/test_step");
            run.output(f);
            first = run.fail(MException("test:boom", "boom"));
            tc.verifyEqual(run.finish(), first);
            tc.verifyNumElements(dir(fullfile(tc.Folder, ".provenance", "*.json")), 1);
            r = jsondecode(fileread(first));
            tc.verifyEqual(string(r.status), "failed");
            tc.verifyEqual(string(r.error), "boom");
        end

        function aRunWithNoOutputsUsesTheFallbackFolder(tc)
            run = celldb.Run("counting_perineuronal_nets/test_nothing_written", Parameters = struct("f", @sin));
            file = run.finish();
            tc.verifyTrue(startsWith(file, tc.Fallback));
            tc.verifyTrue(isfile(file));
            r = jsondecode(fileread(file));
            tc.verifyTrue(isfield(r.parameters, "not_recorded"));
        end

        function withoutTheClientNothingIsQueued(tc)
            tc.verifyEqual(celldb.enqueue("no such file.json"), "off");
            r = celldb.backfill(tc.Folder);
            tc.verifyEqual(r.queued, 0);
            tc.verifySubstring(r.message, "nothing was queued");
            q = celldb.suspend(); %#ok<NASGU> clearing it must do nothing
            clear q
        end

        function theLampSaysTheClientIsNotInstalled(tc)
            fig = uifigure(Visible = "off");
            tc.addTeardown(@() delete(fig));
            g = uigridlayout(fig, [1 2]);
            lamp = celldb.addLamp(g, Row = 1, Column = 2, Parent = fig);
            tc.verifyClass(lamp, "matlab.ui.control.Button");
            tc.verifyEqual(string(lamp.Text), "Database: not installed");
            tc.verifySubstring(string(lamp.Tooltip), "CELLDB_NO_CLIENT");
            tc.verifyEqual(lamp.Layout.Column, 2);
        end

        function theCodeVersionIsTheCommitOrUnknown(tc)
            v = celldb.codeVersion();
            tc.verifyMatches(v, "^([0-9a-f]{7,}(-dirty)?|unknown)$");
            tc.verifyEqual(celldb.codeVersion(), v, "kept for the session");
        end
    end

    methods (Static, Access = private)
        function keep(box, rec)
            box("rec") = rec;
        end

        function h = shaText(text)
            md = java.security.MessageDigest.getInstance("SHA-256");
            md.update(uint8(char(text)));
            h = string(lower(reshape(dec2hex(typecast(md.digest(), "uint8"), 2)', 1, [])));
        end
    end
end

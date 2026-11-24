classdef tCuratorDatabase < matlab.unittest.TestCase
    %tCuratorDatabase  The lab database in CellCurator changes nothing the app writes: the same curation
    %   (the same synthetic section, the same decisions in the same order, marked complete through the
    %   window) gives byte-identical <stem>_curation.csv (ReviewedAt normalised: it holds the time of
    %   each label) and <stem>_final.csv with the client switched off (CELLDB_NO_CLIENT=1) and with it
    %   on (an isolated, fake-server client: tests\celldb_test_client); after Mark source complete the
    %   record is made off the key path and its reason shown in the status bar; the status bar holds
    %   the database lamp and a Database... button.
    %
    %   Run on the hidden desktop: tools\Run-Tests.ps1 tCuratorDatabase

    properties
        Root
        Restore = {}
    end

    methods (TestMethodSetup)
        function setUp(tc)
            fx = tc.applyFixture(matlab.unittest.fixtures.TemporaryFolderFixture);
            tc.Root = fx.Folder;
            tc.applyFixture(matlab.unittest.fixtures.EnvironmentVariableFixture('CELLDB_PROVENANCE_DIR', ...
                fullfile(fx.Folder, 'provenance')));
            tc.addTeardown(@() tc.restoreClient());
        end
    end

    methods
        function restoreClient(tc)
            for k = numel(tc.Restore):-1:1
                tc.Restore{k} = [];
            end
            tc.Restore = {};
            try celldb.available('Refresh', true); catch, end
        end

        function [csv, final, app] = curate(tc, name)
            %curate  The scripted curation of one fresh synthetic section through the window.
            folder = fullfile(tc.Root, name);
            makeSyntheticDataset(folder, 'Variants', false);
            app = CellCurator('UseSettings', false, 'PrepareNext', false, 'Assist', false, 'ConfirmAudit', false);
            tc.addTeardown(@() tCuratorDatabase.closeApp(app));
            app.openParent(folder, '', 'ECM1');
            app.waitForLayout();
            k = 0;
            while app.Page.Kind == "active" && k < 100
                k = k + 1;
                app.galleryClick(min(2, numel(app.Page.Ids)), 'normal');
                app.handleKey('return', {});
            end
            st = app.Store;
            for i = 1:20
                C = curation.Pairs.find(st.kept(), st.Meta.UmPerPixel, struct('KeptPairs', st.Meta.KeptPairs));
                if isempty(C), break; end
                st.keepBoth(vertcat(C.Edges));
            end
            app.showQueue('review');
            app.handleKey('return', {});
            tc.assertTrue(logical(st.Meta.Complete), app.StatusText);
            t0 = tic;
            while isempty(app.LastRecord) && toc(t0) < 20      % the record is made at the next idle step
                pause(0.1);
                drawnow;
            end
            tc.assertNotEmpty(app.LastRecord, 'celldb.recordCuration ran after Mark source complete');
            csv = regexprep(fileread(st.Paths.csv), '\d{4}-\d{2}-\d{2}T[0-9:.]+(Z|[+-]\d{2}:?\d{2})?', '<time>');
            final = fileread(st.Paths.final);
        end
    end

    methods (Static)
        function closeApp(app)
            if ~isempty(app) && isvalid(app)
                delete(app);
            end
        end
    end

    methods (Test)
        function curationFilesAreTheSameWithAndWithoutTheClient(tc)
            tc.assumeNotEmpty(which('celldb.recordCuration'), 'the celldb package is not here');
            old = getenv('CELLDB_NO_CLIENT');
            tc.addTeardown(@() setenv('CELLDB_NO_CLIENT', old));
            % without the client
            setenv('CELLDB_NO_CLIENT', '1');
            celldb.available('Refresh', true);
            [csv0, final0, app0] = tc.curate('absent');
            rec0 = app0.LastRecord;
            tc.verifySubstring(char(app0.StatusText), char(string(rec0.reason)), 'the record''s reason is shown');
            tc.verifyTrue(logical(rec0.written), 'the provenance sidecar is kept without the client');
            db = findall(app0.Figure, 'Tag', 'btn:database');
            tc.verifyNotEmpty(db, 'a Database... button');
            tc.verifyNotEmpty(findall(app0.Figure, 'Tag', 'LabClientLamp'), 'the lamp: "not installed"');
            delete(app0);
            % with the client: an isolated one, its server faked
            setenv('CELLDB_NO_CLIENT', '');
            celldb.available('Refresh', true);                 % finds the client and puts it on the path
            tc.assumeNotEmpty(which('labclient.DB'), 'the labclient package is not here: only the absent state was run');
            [~, tc.Restore] = celldb_test_client();
            celldb.available('Refresh', true);
            tc.assumeTrue(celldb.available(), 'the client is too old or off');
            [csv1, final1, app1] = tc.curate('present');
            tc.verifyEqual(csv1, csv0, 'the curation CSV is byte for byte the same (ReviewedAt aside)');
            tc.verifyEqual(final1, final0, 'the final list is byte for byte the same');
            tc.verifyNotEmpty(app1.LastRecord);
            tc.verifySubstring(char(app1.StatusText), char(string(app1.LastRecord.reason)));
        end
    end
end

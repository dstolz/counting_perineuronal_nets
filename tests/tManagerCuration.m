classdef tManagerCuration < matlab.unittest.TestCase
    %TMANAGERCURATION  CellDatasetManager integration with the curation store: scan status,
    %   the Curate button and its tooltip, and no launch buttons for the removed legacy tools.

    properties
        Folder
        Truth
        EcmLocs
    end

    methods (TestMethodSetup)
        function buildFixture(tc)
            fx = tc.applyFixture(matlab.unittest.fixtures.TemporaryFolderFixture);
            [tc.Folder, tc.Truth] = makeSyntheticDataset(fullfile(fx.Folder, 'ds'));
            tc.EcmLocs = fullfile(tc.Folder, [char(tc.Truth.baseName) '_proj_ECM1_locs.csv']);
        end
    end

    methods (Test)
        function scanReportsCurationStatus(tc)
            s = curation.Store.openCsv(tc.EcmLocs, struct('AutosaveDelay', 0, 'ImportLegacy', false));
            ids = s.T.CellID;
            s.setLabel(ids(1:8), "Good", "human");
            s.setLabel(ids(9:12), "Bad", "human");
            s.close();

            ds = CellDatasetManager.scan(tc.Folder);
            src = [];
            for k = 1:numel(ds)
                for j = 1:numel(ds(k).Sources)
                    if strcmp(ds(k).Sources(j).Key, 'ECM1'), src = ds(k).Sources(j); end
                end
            end
            tc.assertNotEmpty(src, 'scan must still find the ECM1 source');
            tc.verifyTrue(src.Curated);
            tc.verifyEqual(src.CurReviewed, 12);
            tc.verifyEqual(src.CurGood, 8);
            tc.verifyEqual(src.CurBad, 4);
            tc.verifyTrue(isfile(src.CurationPath), 'status must point at the store snapshot');
        end

        function curateButtonAndNoLegacyButtons(tc)
            before = findall(groot, 'Type', 'figure');
            app = CellDatasetManager('', 'UseSettings', false); %#ok<NASGU>
            fig = setdiff(findall(groot, 'Type', 'figure'), before);
            tc.addTeardown(@() delete(fig(isvalid(fig))));
            tc.assertNumElements(fig, 1, 'the manager opens exactly one window');

            btn = findall(fig, 'Type', 'uibutton');
            texts = string(arrayfun(@(b) string(b.Text), btn));
            cur = btn(startsWith(texts, "Curate..."));
            tc.assertNumElements(cur, 1, 'there must be one Curate button');
            tc.verifyGreaterThan(strlength(string(cur.Tooltip)), 40, ...
                'the Curate button needs a descriptive tooltip');
            tc.verifyFalse(any(startsWith(texts, "Legacy")), 'the legacy launch buttons are removed');
            tc.verifyFalse(any(texts == "QC review..."), 'old label must be gone');

            % Every launch-row button explains itself.
            for b = btn(:)'
                tc.verifyNotEmpty(char(string(b.Tooltip)), ...
                    sprintf('button "%s" has no tooltip', b.Text));
            end
        end
    end
end

classdef tCelldbParse < matlab.unittest.TestCase
%tCelldbParse  celldb.parseSectionName: the lab's section file-name convention, on real names, odd
%   names and names that do not fit, and agreement with histology_analysis's parse_histology_filename.
%
%   Run: pwsh -File tools\Run-Tests.ps1 tCelldbParse

    methods (TestClassSetup)
        function addPaths(tc)
            here = fileparts(mfilename('fullpath'));
            tc.applyFixture(matlab.unittest.fixtures.PathFixture(fullfile(fileparts(here), 'customizations')));
        end
    end

    methods (Test)
        function aRealName(tc)
            p = celldb.parseSectionName("SUBJ-ID-1127IHC_ECM26A260519S2_1A_L_WFA-PV_Z3_260511_1_proj");
            tc.verifyTrue(p.ok);
            tc.verifyEqual(p.SubjectID, "SUBJ-ID-1127");
            tc.verifyEqual(p.SubjectNumber, "1127");
            tc.verifyEqual(p.SampleID, "IHC_ECM26A260519S2");
            tc.verifyEqual(p.Protocol, "IHC_ECM26A");
            tc.verifyEqual(p.Series, "2");
            tc.verifyEqual(p.SectionID, "1A");
            tc.verifyEqual(p.Hemisphere, "L");
            tc.verifyEqual(p.Stain, "WFA-PV");
            tc.verifyEqual(p.ZPlane, "Z3");
            tc.verifyEqual(p.DateCode, "260511");
            tc.verifyEqual(p.ImageNumber, "1");
            tc.verifyEqual(p.Variant, "proj");
            tc.verifyEqual(p.ImageKey, "SUBJ-ID-1127IHC_ECM26A260519S2_1A_L_WFA-PV_Z3_260511_1_proj");
        end

        function withoutAVariantOrWithAPathAndExtension(tc)
            p = celldb.parseSectionName("D:\data\SUBJ-ID-1127IHC_ECM26A260519S2_1A_L_WFA-PV_Z3_260511_1.tif");
            tc.verifyTrue(p.ok);
            tc.verifyEqual(p.Variant, "raw");
            tc.verifyEqual(p.ImageKey, "SUBJ-ID-1127IHC_ECM26A260519S2_1A_L_WFA-PV_Z3_260511_1");
            m = celldb.parseSectionName("SUBJ-ID-1127IHC_ECM26A260519S2_1A_L_WFA-PV_Z3_260511_1_mid");
            tc.verifyEqual(m.Variant, "mid");
            tc.verifyTrue(endsWith(m.ImageKey, "_1_mid"));
        end

        function roiAndValuesTailsNameTheirImage(tc)
            p = celldb.parseSectionName("SUBJ-ID-1127IHC_ECM26A260519S2_1A_L_WFA-PV_Z3_260511_1_proj_roi");
            tc.verifyTrue(p.ok);
            tc.verifyEqual(p.ImageKey, "SUBJ-ID-1127IHC_ECM26A260519S2_1A_L_WFA-PV_Z3_260511_1_proj");
        end

        function aSampleIdWithUnderscores(tc)
            p = celldb.parseSectionName("SUBJ-ID-12IHC_A_B_C260102S10_2B_R_PV_Z1_260103_7_proj");
            tc.verifyTrue(p.ok);
            tc.verifyEqual(p.SubjectID, "SUBJ-ID-12");
            tc.verifyEqual(p.SampleID, "IHC_A_B_C260102S10");
            tc.verifyEqual(p.Protocol, "IHC_A_B_C");
            tc.verifyEqual(p.Series, "10");
            tc.verifyEqual(p.SectionID, "2B");
            tc.verifyEqual(p.ImageNumber, "7");
        end

        function aSampleIdWithoutTheDateAndSeriesStillFits(tc)
            p = celldb.parseSectionName("SUBJ-ID-5pilot_1A_L_WFA_Z3_260511_1_proj");
            tc.verifyTrue(p.ok);
            tc.verifyEqual(p.SampleID, "pilot");
            tc.verifyEqual(p.Protocol, "");
            tc.verifyEqual(p.Series, "");
        end

        function namesThatDoNotFitAreNotAnError(tc)
            for name = ["SYN-0001_sec1_proj", "", "a_b_c", "SUBJ-ID-1127_1A_L_WFA_Z3_260511", ...
                    "NOSUBJ-1127IHC_X260519S2_1A_L_WFA_Z3_260511_1_proj", "SUBJ-ID-IHC_X260519S2_1A_L_WFA_Z3_260511_1"]
                p = celldb.parseSectionName(name);
                tc.verifyFalse(p.ok, "should not fit: '" + name + "'");
                tc.verifyEqual(p.SubjectID, "");
                tc.verifyEqual(p.ImageKey, "");
            end
            tc.verifyFalse(celldb.parseSectionName(string(missing)).ok);
            tc.verifyFalse(celldb.parseSectionName([]).ok);
        end

        function agreesWithTheHistologyParser(tc)
            repo = "C:\src\histology_analysis";
            tc.assumeTrue(isfolder(fullfile(repo, "histology_browser")), "histology_analysis is not here");
            old = path;
            tc.addTeardown(@() path(old));
            addpath(fullfile(repo, "histology_browser"));
            names = ["SUBJ-ID-1127IHC_ECM26A260519S2_1A_L_WFA-PV_Z3_260511_1_proj", ...
                "SUBJ-ID-1127IHC_ECM26A260519S2_1A_L_WFA-PV_Z3_260511_1", ...
                "SUBJ-ID-12IHC_A_B_C260102S10_2B_R_PV_Z1_260103_7_mid", ...
                "SUBJ-ID-5pilot_1A_L_WFA_Z3_260511_1_proj", ...
                "SUBJ-ID-1127IHC_ECM26A260519S2_1A_L_WFA-PV_Z3_260511_1_proj_roi", ...
                "SUBJ-ID-1127IHC_ECM26A260519S2_1A_L_WFA-PV_Z3_260511_1_proj_ROI2_values", ...
                "SUBJ-ID-1127IHC_ECM26A260519S2_1A_L_WFA-PV_Z3_260511_1_composite", ...
                "SYN-0001_sec1_proj", "a_b_c", "SUBJ-ID-1127_1A_L_WFA_Z3_260511"];
            fields = ["SubjectID", "SampleID", "SectionID", "Hemisphere", "Stain", "ZPlane", ...
                "DateCode", "ImageNumber", "Protocol", "Series"];
            for name = names
                h = parse_histology_filename(name);
                p = celldb.parseSectionName(name);
                tc.verifyEqual(p.ok, h.isValid, "ok for " + name);
                if ~h.isValid; continue; end
                for f = fields
                    tc.verifyEqual(p.(f), h.(f), f + " of " + name);
                end
                tc.verifyEqual(p.Variant, h.variant, "variant of " + name);
            end
        end
    end
end

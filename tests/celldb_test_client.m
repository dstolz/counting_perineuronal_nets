function [fake, restore, top] = celldb_test_client(opts)
%CELLDB_TEST_CLIENT The lab database client set up for a test: fake server, temporary everything.
%   [fake, restore, top] = celldb_test_client()
%   [...] = celldb_test_client(Enabled = false)
%
% A temporary preference store, a fake password vault, a temporary client
% folder, no sending timer, and labclient.FakeBackend standing in for the
% server, with storage root "nas" mapped to the new folder TOP and the
% subjects SUBJ-ID-9001, SUBJ-ID-9002 and SUBJ-ID-1127 (the ids the tests'
% section names use). RESTORE is a cell of cleanup objects: clear them in
% reverse order to put everything back (the preferences, the vault, the client
% folder, the sender and the backend of the user's own are never touched).
% Needs the labclient package.
%
% See also tCelldbClient, tCelldbInvariance.

arguments
    opts.Enabled (1,1) logical = true
end

restore = {labclient.Prefs.useTemporary(), labclient.Secrets.useFake(), ...
    labclient.DB.useTemporary(), labclient.Sync.useManual()};
fake = labclient.FakeBackend();
fake.Roots = table(1, "nas", "the lab's NAS", VariableNames = ["root_id", "name", "description"]);
fake.Subjects = table(["SUBJ-ID-9001"; "SUBJ-ID-9002"; "SUBJ-ID-1127"], ["P1"; "P1"; "P1"], ...
    repmat("meriones_unguiculatus", 3, 1), ["F"; "M"; "F"], ...
    VariableNames = ["subject_id", "project_id", "species_code", "sex"]);
f = fake;
restore{end + 1} = labclient.DB.useBackend(@() f);
top = string(tempname);
mkdir(top);
s = labclient.Settings.defaults();
s.Enabled = opts.Enabled;
s.Server = "labdb.test";
s.Username = "jdoe";
s.Roots = struct("Name", "nas", "Path", top);
labclient.Settings.save(s);
labclient.Secrets.setFake(labclient.Settings.load(), fake.Password);
end

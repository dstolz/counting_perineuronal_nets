classdef Store < handle
%STORE  Curation store of one detection source: every human decision about its cell candidates,
%   kept in sidecar files keyed by a stable CellID, independent of the detector's *_locs.csv.
%
%   The detector locs file is read-only input. Decisions survive re-detection: when the locs
%   file changes, reconcile() re-attaches every row to the regenerated detections by position.
%   Every user action is one transaction (one undo step, one Changed event, its journal lines
%   appended at once), so the GUI's key path never waits for the disk beyond one append.
%   The store never guesses: when the files do not show which cell a decision belongs to, it
%   refuses (an error) or opens read-only (a warning), and never deletes or rebuilds a file it
%   cannot read.
%
%   ---------------------------------------------------------------------------------------------
%   FACTORIES
%     s = curation.Store.open(mf, key, opts)       mf: CellDatasetManifest handle, key e.g. 'ECM1'
%     s = curation.Store.openCsv(locsCsvPath, opts) forCsv + keyForCsv + open (a '*_resized.csv'
%                                                  path is mapped to its full-resolution twin)
%     s = curation.Store.fromTable(locsTbl, meta, opts)  store built from an in-memory locs table.
%            meta: Key (default 'default'), UmPerPixel (default 0.645 + warning), and optionally
%            Folder + Stem (then it persists exactly like open, with files in Folder), ManifestBase
%            (JSON name; default as pathsFor), LocsFile (used for the fingerprint and the QC path),
%            QcPath, ImageSize, DetectionCount. Option fields (below) may also be given in meta.
%            With existing files in Folder it opens them and reconciles against locsTbl when its
%            fingerprint differs.
%     p = curation.Store.pathsFor(folder, stem, manifestBase)
%            struct csv, journal, json, lock, final (absolute paths; see FILES). The default
%            manifestBase is the Base CellDatasetManifest.forCsv gives for '<stem>_locs.csv':
%            the stem without a trailing '_<channel><page>' ('SYN-0001_sec1_proj_ECM1' ->
%            'SYN-0001_sec1_proj'), the stem itself when it has none.
%     S = curation.Store.schema()   table Name, Type, Default, Meaning of the snapshot columns
%
%   OPTIONS (open / openCsv / fromTable; struct, every field optional)
%     TolUm          8      reconcile and legacy-QC position tolerance, micrometers
%     Reviewer       getenv('USERNAME')
%     ReadOnly       false  open without the lock; every mutator throws curation:Store:readOnly
%     ImportLegacy   true   true | false | "force". true: run curation.LegacyImport on a store
%                           just created from the locs (never on one loaded from a snapshot or with
%                           journal history; a "legacy-import" journal event proves it ran).
%                           "force": import onto an existing store too, sparing every row a person
%                           decided (label source human/confirmed/blind, PosSource human/snap,
%                           merged or unmerged by a person).
%     AutosaveDelay  2      seconds of quiet after a change before the snapshot is written
%                           (0 or Inf: only flush()/close() write it)
%     Force          false  take the lock even when another live process holds it
%     OrphanMergePx  10     legacy resolver rule A5 (see curation.LegacyImport); 0 = literal rule
%     LocsFile       ''     use this locs CSV instead of resolving it from the manifest
%     QcPath         ''     use this legacy QC CSV instead of resolving it
%     Rebuild        false  start a new store: this source's snapshot and journal are renamed to
%                           '<stem>_curation.archived-<yyyyMMddTHHmmss>.csv' and
%                           '<stem>_curation.journal.archived-<ts>.csv', its JSON record is copied to
%                           '<stem>_curation.record.archived-<ts>.json' and removed from the shared
%                           JSON (regions and other sources stay). Nothing is deleted. Needs the lock.
%     AllowEmpty     false  apply an open-time reconcile against a locs file without detections
%     ForceReconcile false  apply an open-time reconcile that matches badly (see RECONCILE)
%     DetectionCount NaN    the detector's row count (legacy-import evidence; open reads the
%                           manifest's stages.detection.count when not given)
%
%   OPEN SEQUENCE
%     1 Detector locs: the manifest source's 'locs' field (detector output), NOT 'activeLocs';
%       when coordSpace(key) is 'resized', mf.locsPath(key,'full'); then activeLocs and the
%       naming conventions '<Base>_<key>_locs.csv', '<Base>_proj_<key>_locs.csv' (locs token from
%       CellDatasetManifest.locsToken). A '*_locs_resized.csv' is never used: its
%       full-resolution twin is. stem = locs file name without '_locs.csv'.
%     2 umPerPixel: manifest image record, else the value stored in the JSON, else TIFF
%       calibration (CellToolkit.tiffPixelSizeUm), else 0.645 with a warning. Meta.UmSource
%       says where the value came from ("manifest" | "meta" (fromTable) | "tiff" | "default")
%       and is stored with it (umSource), so a reopen reports the original source, not the
%       JSON. It changes only for a reason that is also warned about: the manifest gained an
%       image record (-> "manifest"), or a stored "default" guess is replaced by a TIFF
%       calibration found later (-> "tiff"). JSON written before umSource existed reads "store".
%     3 Lock (see LOCKING). Only the lock holder removes stray temporaries ('.<file>.*.tmp': a
%       read-only open never touches another process's write in progress) and, with Rebuild,
%       archives the old files.
%     4 JSON record (strict read): a JSON that exists but cannot be read opens the store
%       READ-ONLY with a warning naming the file (it is never rebuilt from nothing).
%     5 Snapshot. When '<stem>_curation.csv' exists, it is trusted if it is the CSV the JSON record
%       describes (record csvFingerprint = size + hash of the file; records written before that
%       field existed are trusted as before). Otherwise the journal's "snapshot" events identify
%       it (e.g. an older copy restored from a backup): the journal is replayed forward from that
%       revision, with a warning. When nothing identifies it (edited by hand, or record and
%       events both missing while the journal has transactions) the store opens READ-ONLY with a
%       warning naming the CSV, the JSON and the journal.
%       When the snapshot is missing and the source has no history (no JSON record, no journal
%       line), rows are created from the locs (CellID 1..n in file order, Origin detected, State
%       active, PosSource det, InLocs true). With history, rows are rebuilt from the locs and the
%       whole journal replayed ONLY if the locs file is the one the curation was made on (record
%       locsFingerprint, else the journal's "create" event) AND the journal holds no reconcile or
%       legacy-import (after those, CellIDs no longer follow the locs row order); otherwise open
%       throws curation:Store:snapshotMissing, naming the missing file and the remedies (restore
%       it, or Rebuild=true). Rows without a finite X/Y are never created (a warning says how many).
%     6 Journal replay: the committed transactions newer than the snapshot, in revision order (see
%       curation.Journal: TRANSACTIONS). A torn tail (a crash mid-write) is skipped with a
%       warning. A committed transaction that does not fit the rows (a CellID that is not there)
%       stops the replay and opens the store READ-ONLY with a warning; journalBytes never moves
%       past a committed transaction that was not applied. NextCellId ends at least 1 + every
%       id the snapshot or any "+row" / meta.NextCellId line ever held.
%     6b RescoreSource (see RESCORE). A snapshot written before that column existed opens too: it
%       is read by column name, and after the replay a row without a source whose finite rescore
%       is the detector's (InLocs, X/Y within 0.01 px of DET_X/DET_Y) gets "detector"; every other
%       value without a source is stale and set to NaN (pending; LastReconcile.warnings says how
%       many), and the upgraded snapshot is written before open returns (in memory only when
%       read-only). The same check drops a "detector" value that is not on its detector position.
%       On a snapshot and journal written since, it changes nothing.
%     7 Locs fingerprint (size, mtime in UTC, rows) differs from the stored one -> reconcile(),
%       journaled as a structural transaction before anything else is written. A reconcile it
%       refuses (curation:Store:emptyLocs, curation:Store:reconcileMismatch) opens the store
%       READ-ONLY with that message as the warning, unless AllowEmpty / ForceReconcile.
%     8 Legacy import (see ImportLegacy), journaled as a structural transaction ("legacy-import"
%       event and lines) when the store already existed; an import that finds nothing to import
%       leaves no trace.
%     9 Excluded is brought in line with the regions (the other channel may have changed them
%       while this source was closed): a structural "regions" transaction.
%     Anything structural (creation, replay, reconcile, import) is written to disk before open
%     returns; when the snapshot cannot be written then (e.g. the CSV is open in another
%     program) the open still succeeds with a warning, because the journal holds every change
%     (a store just created must write its first snapshot, else the open fails). Warnings
%     (scale fallback, lock holder, missing files, ...) are in LastReconcile.warnings; the reason
%     a store opened read-only is also LockInfo.Message (mutators throw it).
%
%   ---------------------------------------------------------------------------------------------
%   FILES (per source; stem e.g. 'SYN-0001_sec1_proj_ECM1'; all writes via curation.AtomicIO)
%     <stem>_curation.csv          snapshot, one row per candidate, columns below in this order.
%                                  Doubles in shortest round-trip text ('' = NaN), uint32 as
%                                  integers, logicals as 0/1, strings CSV-quoted when needed.
%                                  Read back with fixed import options, so every column keeps its
%                                  type (an all-empty string column is string, not double).
%     <stem>_curation.journal.csv  append-only, one line per changed field per cell, every
%                                  transaction framed by #begin/#commit marker lines; see
%                                  curation.Journal for the columns and value encoding. Also
%                                  event lines: "create", "open", "snapshot" (revision and the
%                                  CSV's fingerprint at each snapshot write, so a restored CSV can
%                                  be identified), "reconcile", "legacy-import". setRescore is a
%                                  transaction of its own (Action "setRescore": rescore and
%                                  RescoreSource lines), replayed like any other, never undoable.
%     <ManifestBase>.curation.json shared by every source of the dataset, in the dataset folder
%                                  (mf.Folder; the per-source files sit next to the locs file):
%         { "schema": "cellcuration/1.0",
%           "jsonRevision": n,            incremented by every write (curation.AtomicIO.updateJson)
%           "nextRegionId": n,            region ids are handed out from here and never reused
%           "regions": [ {id, kind: "exclude"|"analysis"|"reference", scope: "image"|<key>,
%                         xy: [[x,y],...], note}, ... ],
%           "sources": { "<key>": { nextCellId, revision, locsFile, locsFingerprint, umPerPixel,
%                 umSource, imageSize [height width], legacyImported, keptPairs [[idA,idB],...],
%                 sweepDone, complete, counts {...counts()}, autoReject {enabled, tau (null =
%                 none), modelVersion, audit}, stem, journalBytes, csvFingerprint, updated } } }
%         Every write is a locked load-modify-write ('<json>.lock', see curation.AtomicIO
%         UPDATEJSON): a writer that comes between another's read and write is merged, not
%         dropped; a file that cannot be read is never written. Snapshot writes modify only the
%         store's own sources.<key> (keeping unknown fields there) and preserve everything else;
%         region edits modify only the regions array, by region id (add/replace/remove), at
%         commit. The regions array is always written as an array of objects. jsondecode
%         collapses singleton arrays, so readers normalize shapes (keptPairs -> N x 2, regions ->
%         regions()). revision is the store revision the snapshot holds, journalBytes the journal
%         size then, csvFingerprint the snapshot's size and hash.
%     <stem>_curation.lock         {host, user, pid, time (ms), session}, created exclusively
%     <stem>_final.csv             exportFinal: kept rows only, columns
%                                  X,Y,class,score,imgName,thr,rescore,CellID
%
%   COLUMN SCHEMA (T, snapshot; read-back type in brackets)
%     CellID [uint32]       per-source id from 1, never reused (Meta.NextCellId persists and is
%                           journaled, so not even a crash gives an id back)
%     X, Y [double]         effective position, full-resolution image pixels
%     DET_X, DET_Y [double] detector position at the last match (NaN if added by hand)
%     class, score [double], imgName [string], thr [double]   from the locs, refreshed on each
%                           match (NaN/"" when the locs has no such column)
%     rescore [double]      Stage-2 score of a crop centered on the cell (see RESCORE)
%     RescoreSource [string] what produced rescore for the row's current position: "detector" |
%                           a scoring model's name | "" (pending, rescore NaN); see RESCORE
%     Origin [string]       detected | added | merged (a merge result created by a person)
%     State [string]        active | merged (a duplicate's loser, never labeled Bad by a merge)
%                           | stale (detection vanished, unreviewed; purged at the next reconcile)
%     MergedInto [uint32]   keeper's CellID, 0 = none
%     PosSource [string]    det | snap | human
%     InLocs [logical]      matched to the current locs file
%     DetRun [string]       locs fingerprint at the last match
%     MatchDistUm [double]  distance of the last match, micrometers (NaN never matched)
%     Label [string]        "" | Good | Bad | Uncertain
%     LabelSource [string]  "" | human | confirmed | blind | auto | legacy-qc | legacy-resolver
%     Reviewed [logical]    a person decided this row
%     Flag [string]         "" | later | recheck
%     Excluded [logical]    inside an exclusion region (derived and kept in step: see SEMANTICS)
%     ProposalP [double]    P(Good) shown when the label was decided
%     ModelP [double], ModelVersion [string]   latest assist-model prediction (derived data)
%     AuditRole [string]    "" | holdout | reject-audit | confirm-audit | catch
%     Reviewer, ReviewedAt [string]   who / when (ISO 8601 local time with offset)
%     Notes [string]        single line (line breaks become spaces; all text is trimmed)
%
%   ---------------------------------------------------------------------------------------------
%   SEMANTICS
%     Kept = State=="active" & Label=="Good" & Reviewed & ~Excluded & LabelSource in
%            {human, confirmed, blind, legacy-qc}. Excluded cells (inside an exclusion region:
%            tissue folds, edge artifacts) are never kept: keptMask, kept(), counts().kept,
%            counts().vanishedGood and exportFinal ('_final.csv') all leave them out; their
%            labels are kept, so removing the region restores them.
%     Excluded INVARIANT: for every row (active or not), Excluded == the row's X/Y lies inside
%            (or on the edge of) any region of kind "exclude" whose scope is "image" or this
%            source's key (curation.Regions.excluded). The store keeps it so itself: when rows
%            are created (open, reconcile append, addCell, legacy import), moved (moveCell,
%            mergeCells with xy, reconcile), and when regions change (addRegion, removeRegion,
%            undo/redo of those, reloadRegions, and at open). Changes that keep it belong to the
%            transaction of their cause (one undo restores both); changes caused by another
%            channel's regions (reloadRegions, open) are a structural "regions" transaction.
%            setExcluded cannot set a state the regions contradict.
%     setLabel sources human/confirmed/blind/legacy-* set Reviewed=true, Reviewer, ReviewedAt,
%     and bring a stale row back (State active, same transaction): a person's label counts.
%     Source auto may only carry Bad (setLabel(..,"Good","auto") throws curation:Store:autoNotBad),
%     leaves Reviewed=false and State as it is, and never overwrites a label from a person
%     (those ids are skipped).
%     Clearing (label "") empties Label/LabelSource/Reviewer/ReviewedAt and sets Reviewed=false.
%     Text arguments: '' (char), "" and [] all mean "none": setLabel(ids, '') clears,
%     setFlag(ids, '') and setAuditRole(ids, '') clear, setNote(id, '') empties the note; for
%     arguments with a default (label source, position source) '' / "" mean that default.
%     Every mutator validates all its arguments before it changes anything. A mutator that throws
%     inside a batch reverts only its own changes; the batch stays open with the earlier ones.
%
%   RESCORE (columns rescore, RescoreSource)
%     rescore is the Stage-2 network's score of a crop centered on the cell, so it belongs to a
%     position; scoring models differ in scale, so RescoreSource names what produced each value:
%       "detector"  the locs file's value at the row's detector position: rows created from the
%                   locs (open, reconcile append, legacy import) and rows a reconcile refreshes.
%                   Such a row always sits within 0.01 px of DET_X/DET_Y.
%       <model>     the scoring model (its folder name, e.g. "pnn_v2_scoring_ordinal_regression")
%                   that computed it for the row's effective position (curation.Rescore, stored
%                   with setRescore).
%       ""          pending: no valid score for the current position; rescore is NaN.
%     A move of more than 0.01 px (moveCell, mergeCells with xy) makes the score pending in the
%     same transaction, unless the row lands within 0.01 px of its detector position while it is
%     matched to the current locs (InLocs): then the locs' value comes back with "detector" (read
%     from the locs table or file the rows were matched to; pending when that file has changed
%     since). Undo/redo of a move restore exactly the value and source recorded with it, never a
%     score setRescore stored in between (that one was made for the other position). addCell rows
%     are pending. A legacy import that moves a row or drops its detector position makes it
%     pending. Reconcile: see RECONCILE.
%     rescorePending() lists the active rows with RescoreSource "". curation.Rescore.pending
%     decides by position alone (it cannot know which scores were computed), so the two differ:
%     only the store's lists a detection whose locs has no finite rescore, a row moved with
%     posSource "det", a row setRescore gave NaN, and (after opening a snapshot written before
%     RescoreSource existed) an unmatched detection on its detector position; only Rescore's
%     lists a row whose score was computed (setRescore) and an added or merged row that a
%     reconcile matched and that now sits on its detection. Otherwise they agree
%     (tests/tStoreRescore).
%
%   PUBLIC API (ids: CellIDs, any numeric vector; unknown ids throw curation:Store:unknownId;
%   duplicate ids are applied once. Every journaled mutator also takes an optional trailing ctx
%   struct with Queue, PageId, DwellMs, written on its journal lines; inside a batch the first
%   ctx given wins. Read-only stores throw curation:Store:readOnly, closed ones
%   curation:Store:closed, from every mutator including setModel and reconcile. A store whose
%   lock was taken over throws curation:Store:lockLost (see LOCKING).)
%     rep = s.reconcile(locsTbl, opts)     re-attach rows to a new locs table (opts.TolUm,
%                                          opts.Fingerprint, opts.AllowEmpty, opts.Force); NOT
%                                          undoable: clears undo/redo, bumps Revision, writes the
%                                          snapshot, journals it. All or nothing: when the
%                                          snapshot CSV cannot be written every change is
%                                          reverted and the error rethrown. See RECONCILE.
%     s.setLabel(ids, label, source, ctx)  source default "human"; ctx (optional struct):
%                                          ProposalP (scalar or per id), Queue, PageId, DwellMs,
%                                          Reviewer. Only rows whose label/source/reviewed state
%                                          changes are touched (and journaled), plus stale rows
%                                          a person labels (-> active).
%     s.setFlag(ids, flag)                 "" | later | recheck
%     s.setNote(ids, txt)                  replaces Notes
%     s.setExcluded(ids, tf)               compatibility only: a call that agrees with the regions
%                                          changes nothing; one that contradicts them throws
%                                          curation:Store:excludedByRegions (see SEMANTICS). In
%                                          "addRegion + setExcluded(idsInside, true)" batches,
%                                          call it after the addRegion (or not at all).
%     s.setAuditRole(ids, role, ctx)       "" | holdout | reject-audit | confirm-audit | catch;
%                                          undoable (a person's action). ctx.System true: the
%                                          app's bookkeeping (holdout, confirm-audit sampling): NOT
%                                          undoable, journaled as its own transaction (crash-safe),
%                                          Changed Kind "audit", curation:Store:inBatch in a batch
%     tf = s.InBatch                       a batch is open (background writes wait for its end)
%     s.setModel(ids, p, version)          ModelP/ModelVersion; derived: NOT undoable, NOT
%                                          journaled, saved with the snapshot, fires Changed
%                                          with Kind "model"
%     s.setRescore(ids, values, modelName) rescore = values (one per id; NaN = could not be
%                                          scored: rescore NaN, RescoreSource "" (pending)),
%                                          RescoreSource = modelName (one text, required when any
%                                          value is finite; a model folder path is reduced to its
%                                          name; "detector" is reserved). Scores curation.Rescore
%                                          computed for the cells' current positions. Derived:
%                                          NOT undoable, not a user action (no undo step; Changed
%                                          Kind "rescore"), saved with the snapshot, but journaled
%                                          as its own transaction (Action "setRescore"), so a crash
%                                          keeps it. Validates everything first; throws
%                                          curation:Store:inBatch inside a batch.
%     ids = s.rescorePending()             CellIDs (uint32) of active rows with RescoreSource ""
%                                          (see RESCORE)
%     ids = s.addCell(xy, opts)            xy n x 2; opts: PosSource "human"|"snap" (default
%                                          human), Label (default "Good"; "" = unreviewed),
%                                          LabelSource (default human), Notes, ProposalP (scalar
%                                          or per cell), and ctx fields. New rows: Origin added,
%                                          InLocs false, DET NaN, class/imgName/thr copied from
%                                          the source's most common values, Excluded per regions.
%     s.moveCell(ids, xy, posSource)       posSource default "human"; Excluded follows
%     s.mergeCells(ids, keeperId, xy)      every other id -> State merged, MergedInto keeper (rows
%                                          already merged into them follow); keeper State active;
%                                          optional xy moves the keeper (PosSource human). Labels
%                                          are not changed. The keeper must not be merged.
%     s.unmerge(id)                        a merged row -> active, MergedInto 0; a keeper id
%                                          unmerges every row merged into it
%     s.keepBoth(ids)                      [a b] or N x 2: pairs recorded in Meta.KeptPairs
%     s.setSweepDone(tf), s.setComplete(tf)  journaled, undoable meta changes (tf one logical)
%     s.setAutoReject(st)                  st: enabled (logical), tau (double, NaN = none),
%                                          modelVersion (text), audit (struct, free-form);
%                                          missing fields -> false / NaN / "" / struct().
%                                          Journaled, undoable meta change; Meta.AutoReject
%                                          holds it canonically (audit as
%                                          jsondecode(jsonencode(audit))) and is identical after
%                                          flush/close/reopen. Saved in sources.<key>.autoReject.
%     r = s.regions()                      dataset regions: N x 1 struct (id double, kind,
%                                          scope, note string, xy M x 2 double), 0 x 1 when none
%     id = s.addRegion(region)             region struct: kind, xy (M >= 3 finite vertices),
%                                          scope (default "image"), note, id (0/missing -> a new
%                                          id from the JSON's nextRegionId: never one in use or
%                                          handed out before; a used id throws
%                                          curation:Store:badArgument)
%     tf = s.removeRegion(id)              false when there is no such region
%     s.reloadRegions()                    re-read the regions from the JSON (the other channel
%                                          writes them too); Changed Kind "regions" if they or the
%                                          Excluded flags they imply differ.
%                                          Works read-only; throws curation:Store:inBatch in a batch.
%                                          addRegion/removeRegion are journaled ("+region" /
%                                          "-region" lines), undoable, and join an open batch;
%                                          the Excluded changes they cause are in the same
%                                          transaction. Regions are written to the
%                                          JSON when the transaction commits (and on undo/redo);
%                                          if that write fails the whole transaction is rolled
%                                          back (curation:Store:regionWriteFailed). After each
%                                          write regions() is re-read from the file. Undo/redo of
%                                          a region step whose id is now held by a DIFFERENT
%                                          region throws curation:Store:regionConflict and
%                                          changes nothing (the undo step is kept).
%     tf = s.undo(), tf = s.redo()         one transaction per step; depth 1000; false when empty
%     s.beginBatch(desc), s.endBatch()     group calls into ONE transaction (nestable);
%     s.cancelBatch()                      revert and drop the open batch
%     s.scheduleSave()                     (re)arm the debounced snapshot (mutators call it)
%     s.flush()                            write snapshot + JSON now when Dirty (skipped inside a
%                                          batch; no-op when read-only or in memory). Throws
%                                          curation:AtomicIO:jsonUnreadable / jsonBusy AFTER the
%                                          CSV and journal are written when the shared JSON cannot
%                                          be read (it is never overwritten; the next flush writes
%                                          the record), curation:Store:lockLost after a takeover.
%     s.close()                            flush, stop the timer, close the journal, release the
%                                          lock; later mutators throw curation:Store:closed.
%                                          delete(s) does the same. A failed flush is a warning
%                                          (curation:Store:flushFailed).
%     T = s.kept()                         table of the kept rows (all columns)
%     m = s.keptMask()                     logical per row of T
%     c = s.counts()                       struct: total, active, reviewed, good, bad, uncertain,
%                                          unreviewed, toReview, kept, autoRejected, flagged,
%                                          merged, added, stale, vanishedGood, excluded.
%                                          total/merged/added/stale count all rows; the others
%                                          count State "active" rows: reviewed (Reviewed),
%                                          good/bad/uncertain (Reviewed and that Label),
%                                          unreviewed (~Reviewed, auto rejects included),
%                                          toReview (~Reviewed, not auto, not Excluded), kept
%                                          (the Kept rule, so never Excluded), autoRejected
%                                          (auto Bad), flagged
%                                          (Flag set), excluded, rescorePending (RescoreSource "");
%                                          vanishedGood = kept rows with InLocs false and Origin
%                                          "detected"
%     s.exportFinal(path)                  write the kept rows (default Paths.final)
%     rows = s.rowsOf(ids)                 row index in T of each id (array lookup)
%     v = s.get(field, ids)                column values (all rows when ids omitted), fast
%
%   PROPERTIES (read-only)
%     T              table of all rows (built lazily from column arrays, cached until a change)
%     Meta           struct: Key, Stem, Folder, ManifestBase, UmPerPixel, UmSource, ImageSize
%                    [h w], LocsFile, LocsFingerprint, NextCellId, Revision, KeptPairs (N x 2
%                    uint32, rows sorted [low high]), SweepDone, Complete, LegacyImported,
%                    AutoReject (struct enabled, tau, modelVersion, audit; see setAutoReject),
%                    JournalBytes (text fields are char)
%     Paths          struct csv, journal, json, lock, final ('' fields for an in-memory store)
%     Dirty          in-memory state newer than the snapshot CSV
%     CanUndo, CanRedo, ReadOnly, NumRows
%     LastReconcile  report of the last reconcile (Ran false when none ran at open) + warnings
%     LastImport     report of the legacy import (empty struct when none ran)
%     LockInfo       struct Held (another process holds the lock), Host, User, Pid, Time,
%                    Session, TakenOver, Message (why the store is read-only, when it is), Lost
%                    (this store's lock was taken over while it was open)
%     Reviewer, Session, LastError
%   EVENTS
%     Changed        curation.ChangeEventData: ChangeSet, Kind ("do" | "undo" | "redo" |
%                    "reconcile" | "model" | "rescore" (setRescore: derived, not on the undo stack)
%                    | "audit" (setAuditRole with ctx.System: bookkeeping, not on the undo stack)
%                    | "regions" | "lockLost"), CellIDs, Fields, FullRefresh
%
%   RECONCILE (see curation.Reconciler.plan for the matching passes)
%     Passes, each one-to-one and nearest first, each only on what is still unmatched:
%       1 exact (0.01 px) on DET_X/Y, every row (merged rows included);
%       2 within TolUm on DET_X/Y, rows a person decided or touched: not merged, and Reviewed, or
%         PosSource human/snap, or Origin added/merged, or the keeper of a merged row;
%       3 the same rows within TolUm on effective X/Y (added and moved cells);
%       4 State "merged" rows within TolUm (DET_X/Y, X/Y when DET is NaN): a re-detected
%         duplicate stays merged;
%       5 all other rows (unreviewed, auto-rejected, stale) within TolUm on DET_X/Y;
%       6 a detection still unmatched within TolUm of an active Reviewed row that is still
%         unmatched is linked to it.
%     So a person's cell gets its re-detection before an unreviewed neighbor can, and a kept cell
%     never becomes "vanished" while its re-detection arrives as a second candidate.
%     Matched: score, class, imgName, thr, DET_X/Y, DetRun, MatchDistUm, InLocs=true;
%     X/Y follow the detector (PosSource -> det) unless PosSource is human; stale -> active.
%     rescore follows the position (see RESCORE): a row whose effective position (after the line
%     above) is within 0.01 px of its detection - det and snap rows, and human rows that sit on
%     it - gets the locs' rescore with RescoreSource "detector" ("" and NaN when the locs has
%     none). A row at a person's position elsewhere keeps its rescore and RescoreSource (a model's
%     score for that position; score, the detector's confidence for the nearby detection, and
%     DET_X/Y are still refreshed), except a "detector" value, which belonged to the old detector
%     position and becomes pending (NaN, "").
%     Unmatched rows keep rescore and RescoreSource. Appended rows: "detector" when the locs
%     gives a finite rescore, else "" (pending).
%     Unmatched (InLocs=false):
%       merged rows: unchanged (never staled or purged);
%       human-touched rows (Origin added/merged, PosSource human, or the keeper of a merged row):
%         unchanged;
%       reviewed Good: stays active and kept unless Excluded ("vanished Good");
%       reviewed Bad/Uncertain: retained as they are;
%       unreviewed and auto rows: -> stale; rows already stale before this reconcile -> purged,
%         except rows with a Flag, Notes or an AuditRole (an audit sample never loses members),
%         which stay stale.
%     Unmatched new detections are appended as unreviewed rows with new CellIDs (Excluded per
%     the regions). One that lies within TolUm of an active Reviewed row (which matched another
%     detection) is still appended, but listed in the report (nNearKept, nearKeptIds [new CellID,
%     reviewed CellID]) so the GUI can queue it as a close pair; it is never silent.
%     Detections without a finite X/Y are left out (warning, nDroppedNonFinite).
%     Refused (nothing changes; LastReconcile holds the report with Refused true):
%       curation:Store:emptyLocs          the table has no detections while rows are matched to
%                                         the current locs (opts.AllowEmpty applies it);
%       curation:Store:reconcileMismatch  fewer than half of the rows matched to the current locs
%                                         find a match: a different page, image or coordinate
%                                         space (opts.Force applies it).
%     Report: Ran, nOld, nNew, nExact, nNear (all non-exact), nNearDet, nNearHuman, nMergedRows,
%     nReactivated, nAppended, nVanishedGood, nVanishedOther, nStale, nPurged, tolUm, umPerPixel,
%     matchDistUm (vector, um), maxMatchDistUm, fingerprint, nNearKept, nearKeptIds,
%     nDroppedNonFinite, Refused, refusal ("" | "emptyLocs" | "mismatch"), warnings.
%
%   LOCKING
%     open takes '<stem>_curation.lock' with an exclusive create. If it exists and names another
%     session: on this host, that pid is alive when a process with it runs and did not start
%     after the lock was written (any program: a compiled app counts like MATLAB); on another
%     host, always. A live holder -> the store opens ReadOnly (LockInfo.Held, LockInfo.Message,
%     and a warning in LastReconcile.warnings) unless opts.Force; a dead one, or a lock of this
%     very process whose session is no longer open, is taken over (LockInfo.TakenOver).
%     Before every journal append and snapshot write the store checks that the lock file still
%     names its session: before a snapshot write always by reading the file; before a journal
%     append by reading it at most every LOCK_CHECK_SEC (2 s), so a label key does not wait for a
%     network round trip each time (LockReads counts the reads). A takeover by another store of
%     this MATLAB is seen at the next append (the in-process lock registry); one by another
%     process within 2 s, and at the latest before the snapshot is written (the journal lines
%     appended meanwhile are then at the end of the journal the new holder replays when it next
%     opens). When another session took it (Force), the store stops writing at once:
%     the change being made is reverted, the store turns ReadOnly, LockInfo.Lost is true and
%     LockInfo.Message says who took it, a Changed event of Kind "lockLost" is fired, and the
%     call throws curation:Store:lockLost.
%     close/delete remove the store's own lock and stop its save timer.
%
%   ERRORS a GUI may want to tell apart
%     curation:Store:readOnly, closed, lockLost, inBatch, unknownId, badArgument, badLabel,
%     badSource, autoNotBad, badMerge, excludedByRegions, regionConflict, regionWriteFailed,
%     snapshotMissing (open), emptyLocs, reconcileMismatch (reconcile), noLocs (open);
%     curation:AtomicIO:jsonUnreadable, jsonBusy, writeFailed.

    properties (Constant)
        SCHEMA = 'cellcuration/1.0'
        COLUMNS = ["CellID","X","Y","DET_X","DET_Y","class","score","rescore","RescoreSource", ...
            "imgName","thr","Origin","State","MergedInto","PosSource","InLocs","DetRun","MatchDistUm", ...
            "Label","LabelSource","Reviewed","Flag","Excluded","ProposalP","ModelP","ModelVersion", ...
            "AuditRole","Reviewer","ReviewedAt","Notes"]
        TYPES = ["uint32","double","double","double","double","double","double","double","string", ...
            "string","double","string","string","uint32","string","logical","string","double", ...
            "string","string","logical","string","logical","double","double","string", ...
            "string","string","string","string"]
        LABELS = ["", "Good", "Bad", "Uncertain"]
        LABEL_SOURCES = ["human", "confirmed", "blind", "auto", "legacy-qc", "legacy-resolver"]
        KEEP_SOURCES = ["human", "confirmed", "blind", "legacy-qc"]
        PERSON_SOURCES = ["human", "confirmed", "blind", "legacy-qc", "legacy-resolver"]
        FLAGS = ["", "later", "recheck"]
        AUDIT_ROLES = ["", "holdout", "reject-audit", "confirm-audit", "catch"]
        POS_SOURCES = ["det", "snap", "human"]
        MAX_UNDO = 1000
        DEFAULT_UM_PER_PIXEL = 0.645
        POS_TOL_PX = 0.01             % a position within this of another is the same (RESCORE)
        LOCK_CHECK_SEC = 2            % the lock file is read at most this often (LOCKING)
        COLS = cellstr(curation.Store.COLUMNS)
        TYPE_OF = curation.Store.makeTypeOf()
    end

    properties (SetAccess = private)
        Meta struct = struct()
        Paths struct = struct('csv', '', 'journal', '', 'json', '', 'lock', '', 'final', '')
        ReadOnly logical = false
        LastReconcile struct = struct()
        LastImport struct = struct()
        LockInfo struct = struct()
        Reviewer string = ""
        Session string = ""
        LastError string = ""
        Options struct = struct()
        LockReads double = 0          % reads of the lock file since open (diagnostics, tests)
    end

    properties (Dependent, SetAccess = private)
        T
        Dirty
        CanUndo
        CanRedo
        InBatch         % a beginBatch is open (a background write must wait: setRescore, system roles)
        NumRows
        JournalInfo     % struct Path, Bytes, KeepOpen, LastError ([] without a journal)
    end

    properties (Access = private)
        C struct = struct()          % columns, field per COLUMNS entry
        RowOfId double = zeros(0, 1) % CellID -> row (0 = absent)
        TCache = []
        UndoStack cell = {}
        RedoStack cell = {}
        Txn = []
        BatchDepth double = 0
        SavedRevision double = 0
        DerivedDirty logical = false
        JournalObj = []
        SaveTimer = []
        TimerActive logical = false
        LastChangeTic = []
        PendingSinceTic = []
        Seq double = 0
        Closed logical = false
        OwnsLock logical = false
        LockCheckTic = []            % when the lock file was last read and found to be this session's
        Persist logical = false
        Ready logical = false        % open completed: only then may close()/delete() write
        RegionCache struct = struct('id', {}, 'kind', {}, 'scope', {}, 'xy', {}, 'note', {})
        JsonStale logical = false    % the snapshot CSV is newer than the JSON record (write pending)
        SnapFp char = ''             % fingerprint of the snapshot CSV this store last wrote/read
        NextRegionIdMem double = 1   % region ids of an in-memory store (never reused)
        SnapAtOpen logical = false   % open must write a snapshot (e.g. a torn journal tail was skipped)
        LocsTable = []               % the in-memory locs table of fromTable (detector values)
        LocsCache = []               % struct fp, N: normalized locs of Meta.LocsFingerprint ([] N: unavailable)
    end

    events
        Changed
    end

    %% ======================================================================== factories
    methods (Static)

        function obj = open(mf, key, opts)
            %OPEN  Store of source KEY of the dataset whose CellDatasetManifest is MF.
            if nargin < 3, opts = struct(); end
            opts = curation.Store.fillOpts(opts);
            key = char(key);
            src = curation.Store.emptySrc();
            src.Key = key;
            src.ManifestBase = char(mf.Base);
            if ~isempty(opts.LocsFile)
                locs = curation.Store.fullResLocs(char(opts.LocsFile));
            else
                locs = curation.Store.resolveLocs(mf, key);
            end
            src.LocsFile = locs;
            src.JsonFolder = char(mf.Folder);   % the shared JSON lives with the dataset
            if ~isempty(locs)
                [folder, name] = fileparts(locs);
                src.Folder = folder;
                src.Stem = curation.Store.stemFromLocs(name);
            else
                src.Folder = char(mf.Folder);
            end
            % scale from the manifest image record
            try
                u = mf.Data.image.umPerPixel;
                if isnumeric(u) && isscalar(u) && isfinite(u) && u > 0
                    src.UmPerPixel = double(u);
                    src.UmSource = "manifest";
                end
            catch
            end
            % image + page (for TIFF calibration and image size)
            try
                if ~isempty(locs), src.ImagePath = char(mf.imageForLocs(locs)); end
            catch
            end
            if isempty(src.ImagePath)
                try src.ImagePath = char(mf.imagePath()); catch, end
            end
            try
                [~, pg] = mf.channelPage(key);
                if isfinite(pg), src.Page = pg; end
            catch
            end
            % legacy QC file
            if ~isempty(opts.QcPath)
                src.QcPath = char(opts.QcPath);
            else
                cands = {};
                try cands{end + 1} = char(mf.qcPath(key)); catch, end
                if ~isempty(locs)
                    [f, nm] = fileparts(locs);
                    cands{end + 1} = fullfile(f, [nm '_QC.csv']);
                    cands{end + 1} = fullfile(f, [nm '_resized_QC.csv']);
                end
                for k = 1:numel(cands)
                    if ~isempty(cands{k}) && isfile(cands{k})
                        src.QcPath = cands{k};
                        break;
                    end
                end
            end
            if ~isempty(src.QcPath) && ~isempty(regexpi(src.QcPath, '_resized_QC\.csv$', 'once'))
                src.QcResized = true;
                try
                    s = mf.source(key);
                    f = double(s.stages.detection.resize);
                    if isscalar(f) && f > 0, src.QcScale = f; end
                catch
                end
            end
            % evidence for the legacy import: the resized twin, the detector's row count
            if isempty(src.ResizedLocs)
                try
                    src.ResizedLocs = char(mf.locsPath(key, 'resized'));
                catch
                end
            end
            if isfinite(opts.DetectionCount)
                src.DetectionCount = opts.DetectionCount;
            else
                try
                    s = mf.source(key);
                    c = double(s.stages.detection.count);
                    if isscalar(c) && isfinite(c), src.DetectionCount = c; end
                catch
                end
            end
            obj = curation.Store.openImpl(src, opts);
        end

        function obj = openCsv(locsCsvPath, opts)
            %OPENCSV  open() for the dataset/source a locs CSV belongs to (by naming convention).
            if nargin < 2, opts = struct(); end
            locsCsvPath = curation.Store.fullResLocs(char(locsCsvPath));
            mf = CellDatasetManifest.forCsv(locsCsvPath);
            key = CellDatasetManifest.keyForCsv(locsCsvPath);
            if ~isfield(opts, 'LocsFile') || isempty(opts.LocsFile)
                opts.LocsFile = locsCsvPath;
            end
            obj = curation.Store.open(mf, key, opts);
        end

        function obj = fromTable(locsTbl, meta, opts)
            %FROMTABLE  Store from an in-memory locs table (persisted when meta has Folder+Stem).
            if nargin < 2 || isempty(meta), meta = struct(); end
            if nargin < 3, opts = struct(); end
            optNames = fieldnames(curation.Store.fillOpts(struct()));
            for k = 1:numel(optNames)
                if isfield(meta, optNames{k}) && ~isfield(opts, optNames{k})
                    opts.(optNames{k}) = meta.(optNames{k});
                end
            end
            opts = curation.Store.fillOpts(opts);
            src = curation.Store.emptySrc();
            src.Key = char(curation.Store.metaField(meta, 'Key', 'default'));
            src.LocsTable = locsTbl;
            u = curation.Store.metaField(meta, 'UmPerPixel', NaN);
            if isnumeric(u) && isscalar(u) && isfinite(u) && u > 0
                src.UmPerPixel = double(u);
                src.UmSource = "meta";
            end
            src.Folder = char(curation.Store.metaField(meta, 'Folder', ''));
            src.Stem = char(curation.Store.metaField(meta, 'Stem', ''));
            src.ManifestBase = char(curation.Store.metaField(meta, 'ManifestBase', ''));
            if isempty(src.ManifestBase) && ~isempty(src.Stem)
                src.ManifestBase = curation.Store.baseFromStem(src.Stem);
            end
            src.LocsFile = char(curation.Store.metaField(meta, 'LocsFile', ''));
            src.DetectionCount = opts.DetectionCount;
            src.ImageSize = double(curation.Store.metaField(meta, 'ImageSize', []));
            src.QcPath = char(curation.Store.metaField(meta, 'QcPath', opts.QcPath));
            if isempty(src.QcPath) && ~isempty(src.Folder) && ~isempty(src.Stem)
                cand = fullfile(src.Folder, [src.Stem '_locs_QC.csv']);
                if ~isempty(src.LocsFile)
                    [f, nm] = fileparts(src.LocsFile);
                    cand = fullfile(f, [nm '_QC.csv']);
                end
                if isfile(cand), src.QcPath = cand; end
            end
            obj = curation.Store.openImpl(src, opts);
        end

        function p = pathsFor(folder, stem, manifestBase)
            %PATHSFOR  Absolute paths of a source's curation files (see FILES in the help).
            folder = char(folder);
            stem = char(stem);
            if nargin < 3 || isempty(manifestBase)
                manifestBase = curation.Store.baseFromStem(stem);
            end
            manifestBase = char(manifestBase);
            p = struct( ...
                'csv', fullfile(folder, [stem '_curation.csv']), ...
                'journal', fullfile(folder, [stem '_curation.journal.csv']), ...
                'json', fullfile(folder, [manifestBase '.curation.json']), ...
                'lock', fullfile(folder, [stem '_curation.lock']), ...
                'final', fullfile(folder, [stem '_final.csv']));
        end

        function S = schema()
            %SCHEMA  Table of the snapshot columns: Name, Type, Default, Meaning.
            Name = curation.Store.COLUMNS(:);
            Type = curation.Store.TYPES(:);
            Default = ["0";"NaN";"NaN";"NaN";"NaN";"NaN";"NaN";"NaN";"""""";"""""";"NaN"; ...
                """detected""";"""active""";"0";"""det""";"false";"""""";"NaN"; ...
                """""";"""""";"false";"""""";"false";"NaN";"NaN";""""""; ...
                """""";"""""";"""""";""""""];
            Meaning = ["unique per source, never reused"; "effective X, full-res px"; ...
                "effective Y, full-res px"; "detector X at last match"; "detector Y at last match"; ...
                "from locs"; "from locs"; "Stage-2 score for the current position (RescoreSource)"; ...
                """detector"" (locs, at DET_X/Y) | scoring model name | """" (pending)"; ...
                "from locs"; "from locs"; ...
                "detected|added|merged"; "active|merged|stale"; "keeper CellID, 0 none"; ...
                "det|snap|human"; "matched to current locs"; "locs fingerprint at last match"; ...
                "last match distance, um"; """""|Good|Bad|Uncertain"; ...
                """""|human|confirmed|blind|auto|legacy-qc|legacy-resolver"; "a person decided"; ...
                """""|later|recheck"; "inside an exclusion region"; "P(Good) shown when decided"; ...
                "latest model P(Good)"; "model version"; ...
                """""|holdout|reject-audit|confirm-audit|catch"; "who"; "when, ISO 8601"; "notes"];
            S = table(Name, Type, Default, Meaning);
        end
    end

    %% ======================================================================== construction
    methods (Access = private)
        function obj = Store()
            obj.Meta = curation.Store.defaultMeta();
            obj.C = curation.Store.defaultRows(0);
            obj.LastReconcile = curation.Store.emptyReport();
            obj.LockInfo = curation.Store.emptyLockInfo();
            obj.RegionCache = curation.Store.emptyRegions();
        end
    end

    %% ======================================================================== mutators
    methods

        function setLabel(obj, ids, label, source, ctx)
            %SETLABEL  Label cells. label: "" (clear) | Good | Bad | Uncertain (any case).
            %   source: human (default) | confirmed | blind | auto | legacy-qc | legacy-resolver.
            %   ctx (optional): ProposalP (scalar or per id), Queue, PageId, DwellMs, Reviewer.
            obj.assertWritable();
            if nargin < 4 || isempty(source), source = "human"; end
            if nargin < 5 || ~isstruct(ctx), ctx = struct(); end
            label = curation.Store.canonLabel(label);
            source = curation.Store.canonSource(source);
            [rows, ia] = obj.uniqueRows(ids);
            pp = [];
            if isfield(ctx, 'ProposalP') && ~isempty(ctx.ProposalP)
                pp = double(ctx.ProposalP(:));
                if ~isscalar(pp)
                    if numel(pp) ~= numel(ids)
                        error('curation:Store:badArgument', 'ProposalP must be scalar or one per id.');
                    end
                    pp = pp(ia);
                end
            end
            if label == ""
                newSrc = ""; newRev = false; who = ""; at = "";
            elseif source == "auto"
                if label ~= "Bad"
                    error('curation:Store:autoNotBad', 'Source "auto" may only set the label Bad.');
                end
                byPerson = ismember(obj.C.LabelSource(rows), curation.Store.PERSON_SOURCES);
                rows = rows(~byPerson);
                if ~isempty(pp) && ~isscalar(pp), pp = pp(~byPerson); end
                newSrc = "auto"; newRev = false; who = ""; at = "";
            else
                newSrc = source; newRev = true;
                who = obj.Reviewer;
                if isfield(ctx, 'Reviewer') && strlength(curation.Store.oneText(ctx.Reviewer, 'reviewer')) > 0
                    who = curation.Store.oneText(ctx.Reviewer, 'reviewer');
                end
                at = string(curation.AtomicIO.isoNow(false));
            end
            % a person's label brings a stale row back: it is counted (finding 10)
            revive = [];
            if newRev
                revive = rows(obj.C.State(rows) == "stale");
            end
            ch = obj.C.Label(rows) ~= label | obj.C.LabelSource(rows) ~= newSrc ...
                | obj.C.Reviewed(rows) ~= newRev;
            rows = rows(ch);
            if ~isempty(pp) && ~isscalar(pp), pp = pp(ch); end
            if isempty(rows) && isempty(revive), return; end
            if label == ""
                desc = sprintf('Clear the label of %d cell(s)', numel(rows));
            else
                desc = sprintf('Label %d cell(s) %s', max(numel(rows), numel(revive)), label);
            end
            mark = obj.txnBegin(desc, "setLabel", ctx);
            try
                obj.txnSet('Label', rows, label);
                obj.txnSet('LabelSource', rows, newSrc);
                obj.txnSet('Reviewed', rows, newRev);
                obj.txnSet('Reviewer', rows, who);
                obj.txnSet('ReviewedAt', rows, at);
                if ~isempty(pp)
                    obj.txnSet('ProposalP', rows, pp);
                end
                obj.txnSet('State', revive, "active");
            catch ME
                obj.txnRollback(mark);
                rethrow(ME);
            end
            obj.txnCommit();
        end

        function setFlag(obj, ids, flag, ctx)
            %SETFLAG  Flag cells: "" | later | recheck.
            obj.assertWritable();
            if nargin < 4, ctx = struct(); end
            flag = curation.Store.canonMember(flag, curation.Store.FLAGS, 'flag');
            rows = obj.uniqueRows(ids);
            obj.simpleSet(sprintf('Flag %d cell(s) "%s"', numel(rows), flag), "setFlag", ...
                'Flag', rows, flag, ctx);
        end

        function setNote(obj, ids, txt, ctx)
            %SETNOTE  Replace the Notes of cells (single line, trimmed).
            obj.assertWritable();
            if nargin < 4, ctx = struct(); end
            txt = curation.Store.oneText(txt, 'note');   % '' / "" / [] clear the note
            rows = obj.uniqueRows(ids);
            obj.simpleSet(sprintf('Note on %d cell(s)', numel(rows)), "setNote", 'Notes', rows, txt, ctx);
        end

        function setExcluded(obj, ids, tf, ctx)
            %SETEXCLUDED  Kept for compatibility. Excluded FOLLOWS THE EXCLUSION REGIONS (see
            %   SEMANTICS): the store sets it itself whenever rows or regions change. A call that
            %   agrees with the regions changes nothing (no error, no warning, no undo step), so
            %   "addRegion + setExcluded(idsInside, true)" in one batch keeps working (call it
            %   after the addRegion). A call that contradicts them changes nothing and throws
            %   curation:Store:excludedByRegions: add or remove an exclude region instead.
            obj.assertWritable();
            if nargin < 4, ctx = struct(); end
            [rows, ia] = obj.uniqueRows(ids);
            tf = logical(tf(:));
            if ~isscalar(tf)
                if numel(tf) ~= numel(ids)
                    error('curation:Store:badArgument', 'tf must be scalar or one per id.');
                end
                tf = tf(ia);
            end
            if isempty(rows), return; end
            target = obj.excludedFor(obj.C.X(rows), obj.C.Y(rows));
            bad = find(tf ~= target, 1);
            if ~isempty(bad)
                words = ["outside every", "inside an"];
                error('curation:Store:excludedByRegions', ['Cell %d lies %s exclusion region, so it ' ...
                    'cannot be marked Excluded=%d: Excluded follows the regions. Add or remove an ' ...
                    'exclude region instead.'], obj.C.CellID(rows(bad)), words(target(bad) + 1), ...
                    tf(min(bad, numel(tf))));
            end
            obj.simpleSet(sprintf('Exclude %d cell(s)', numel(rows)), "setExcluded", ...
                'Excluded', rows, target, ctx);   % normally a no-op: the store keeps them in step
        end

        function setAuditRole(obj, ids, role, ctx)
            %SETAUDITROLE  "" | holdout | reject-audit | confirm-audit | catch.
            %   The person's form (default): an undoable user transaction; it joins an open batch.
            %   ctx.System true: the app's own bookkeeping (choosing the holdout, drawing a confirm
            %   audit), not a person's action: NOT undoable (no undo step, the redo stack is kept,
            %   so undo always reverts the person's last own action), journaled at once as its own
            %   transaction (Action "setAuditRole"; replayed after a crash), saved with the
            %   snapshot, Changed Kind "audit". Validates everything first; throws
            %   curation:Store:inBatch inside a batch (a background write never joins a person's
            %   transaction). ctx's Queue/PageId go on its journal lines as usual.
            obj.assertWritable();
            if nargin < 4 || isempty(ctx), ctx = struct(); end
            role = curation.Store.canonMember(role, curation.Store.AUDIT_ROLES, 'audit role');
            sys = isstruct(ctx) && isfield(ctx, 'System') && ~isempty(ctx.System) && logical(ctx.System(1));
            if isstruct(ctx) && isfield(ctx, 'System'), ctx = rmfield(ctx, 'System'); end
            if sys, obj.assertNoBatch(); end
            rows = obj.uniqueRows(ids);
            desc = sprintf('Audit role "%s" for %d cell(s)', role, numel(rows));
            if ~sys
                obj.simpleSet(desc, "setAuditRole", 'AuditRole', rows, role, ctx);
                return
            end
            if isempty(rows), return; end
            saved = obj.Txn;
            obj.Txn = curation.Store.newTxn(desc, "setAuditRole", ctx);
            obj.txnSet('AuditRole', rows, role);
            E = obj.Txn.Entries;
            obj.Txn = saved;
            obj.TCache = [];
            if isempty(E), return; end
            if ~obj.ownsLockNow()
                obj.applyEntries(E, false);   % nothing of it may stay unsaved in memory
                obj.loseLock();               % throws curation:Store:lockLost
            end
            cs = curation.ChangeSet(desc, "setAuditRole", E);
            cs = obj.stamp(cs, ctx);
            cs.Kind = "setAuditRole";
            if ~isempty(obj.JournalObj), obj.journalWrite(cs); end
            obj.fireChanged(cs, "audit", false);
            obj.scheduleSave();
        end

        function setModel(obj, ids, p, version)
            %SETMODEL  Store assist-model predictions (derived data: not undoable, not journaled,
            %   saved with the next snapshot). p scalar or one per id; version scalar or per id.
            obj.assertWritable();
            if nargin < 4, version = ""; end
            [rows, ia] = obj.uniqueRows(ids);
            p = double(p(:));
            if ~isscalar(p)
                if numel(p) ~= numel(ids)
                    error('curation:Store:badArgument', 'p must be scalar or one per id.');
                end
                p = p(ia);
            end
            if isempty(version)
                version = "";
            else
                version = curation.AtomicIO.cleanText(version);
            end
            if ~isscalar(version)
                if numel(version) ~= numel(ids)
                    error('curation:Store:badArgument', 'version must be scalar or one per id.');
                end
                version = version(ia);
            end
            if isempty(rows), return; end
            n = numel(rows);
            if isscalar(p), p = repmat(p, n, 1); end
            if isscalar(version), version = repmat(version, n, 1); end
            oldP = obj.C.ModelP(rows);
            obj.C.ModelP(rows) = p;
            obj.C.ModelVersion(rows) = version;
            obj.DerivedDirty = true;
            obj.TCache = [];
            e = curation.ChangeSet.entry('set', 'ModelP', obj.C.CellID(rows), oldP, p);
            cs = curation.ChangeSet("Model predictions", "setModel", e);
            cs.Kind = "model";
            cs.Revision = obj.Meta.Revision;
            obj.fireChanged(cs, "model", false);
            obj.scheduleSave();
        end

        function setRescore(obj, ids, values, modelName)
            %SETRESCORE  Store Stage-2 scores computed for the cells' current positions (e.g. by
            %   curation.Rescore): rescore = values, RescoreSource = modelName. values: one real
            %   number per id; NaN = could not be scored (rescore NaN, RescoreSource "": pending).
            %   modelName: one text, required when any value is finite; a model folder path is
            %   reduced to its name; "detector" is reserved. Derived data, but it took a Python
            %   run: NOT undoable and not a user action (no undo step; Changed Kind "rescore"), yet
            %   journaled as its own transaction (Action "setRescore") and saved with the snapshot,
            %   so a crash keeps it. Validates everything before it writes; duplicate ids are
            %   applied once (the first value). Throws curation:Store:inBatch inside a batch.
            obj.assertWritable();
            obj.assertNoBatch();
            if nargin < 3
                error('curation:Store:badArgument', 'setRescore(ids, values, modelName): values are missing.');
            end
            if nargin < 4, modelName = ""; end
            if ~(isnumeric(values) || islogical(values)) || ~isreal(values)
                error('curation:Store:badArgument', ['setRescore: values must be real numbers (NaN = ' ...
                    'could not be scored).']);
            end
            ids = ids(:);
            values = double(values(:));
            if numel(values) ~= numel(ids)
                error('curation:Store:badArgument', 'setRescore: one value per id (%d ids, %d values).', ...
                    numel(ids), numel(values));
            end
            if any(isinf(values))
                error('curation:Store:badArgument', 'setRescore: values must be finite or NaN.');
            end
            name = curation.Store.scorerName(modelName);
            if strcmpi(name, "detector")
                error('curation:Store:badArgument', ['setRescore: "detector" is reserved for the locs ' ...
                    'file''s values.']);
            end
            if name == "" && any(isfinite(values))
                error('curation:Store:badArgument', ['setRescore: name the scoring model that made the ' ...
                    'scores (RescoreSource).']);
            end
            [rows, ia] = obj.uniqueRows(ids);
            if isempty(rows), return; end
            values = values(ia);
            src = repmat(name, numel(rows), 1);
            src(isnan(values)) = "";
            saved = obj.Txn;
            obj.Txn = curation.Store.newTxn("Rescore", "setRescore", struct());
            obj.txnSet('rescore', rows, values);
            obj.txnSet('RescoreSource', rows, src);
            E = obj.Txn.Entries;
            obj.Txn = saved;
            obj.TCache = [];
            if isempty(E), return; end
            if ~obj.ownsLockNow()
                obj.applyEntries(E, false);   % nothing of it may stay unsaved in memory
                obj.loseLock();               % throws curation:Store:lockLost
            end
            cs = obj.sysCommit(sprintf('Rescore %d cell(s)', numel(rows)), "setRescore", E, true);
            obj.fireChanged(cs, "rescore", false);
            obj.scheduleSave();
        end

        function ids = rescorePending(obj)
            %RESCOREPENDING  CellIDs (uint32 column) of the active rows without a valid rescore for
            %   their current position (RescoreSource ""): the cells curation.Rescore should score.
            c = obj.C;
            ids = c.CellID(c.State == "active" & c.RescoreSource == "");
        end

        function ids = addCell(obj, xy, opts)
            %ADDCELL  Add cell(s) at xy (n x 2, full-resolution px). Returns the new CellIDs.
            %   opts: PosSource (human|snap, default human), Label (default Good; "" = none),
            %   LabelSource (default human), Notes, ProposalP (scalar or one per cell), Queue,
            %   PageId, DwellMs, Reviewer. Excluded follows the exclusion regions.
            obj.assertWritable();
            if nargin < 3 || ~isstruct(opts), opts = struct(); end
            xy = double(xy);
            if size(xy, 2) ~= 2 || isempty(xy) || any(~isfinite(xy(:)))
                error('curation:Store:badArgument', 'xy must be an n x 2 array of finite positions.');
            end
            n = size(xy, 1);
            posSrc = curation.Store.oneText(curation.Store.metaField(opts, 'PosSource', ""), 'position source');
            if posSrc == "", posSrc = "human"; end
            posSrc = curation.Store.canonMember(posSrc, ["human", "snap"], 'position source');
            if isfield(opts, 'Label')
                label = curation.Store.canonLabel(opts.Label);   % '' / "" = no label
            else
                label = "Good";
            end
            lsrc = curation.Store.canonSource(curation.Store.metaField(opts, 'LabelSource', ""));
            if label ~= "" && lsrc == "auto" && label ~= "Bad"
                error('curation:Store:autoNotBad', 'Source "auto" may only set the label Bad.');
            end
            pp = double(curation.Store.metaField(opts, 'ProposalP', NaN));
            if ~(isscalar(pp) || numel(pp) == n)
                error('curation:Store:badArgument', 'ProposalP must be scalar or one per cell.');
            end
            note = curation.Store.oneText(curation.Store.metaField(opts, 'Notes', ""), 'note');
            who = obj.Reviewer;
            if isfield(opts, 'Reviewer') && strlength(curation.Store.oneText(opts.Reviewer, 'reviewer')) > 0
                who = curation.Store.oneText(opts.Reviewer, 'reviewer');
            end
            R = curation.Store.defaultRows(n);
            first = obj.Meta.NextCellId;
            ids = uint32(first + (0:n - 1)');
            R.CellID = ids;
            R.X = xy(:, 1); R.Y = xy(:, 2);
            [cls, img, thr] = obj.typicalLocsValues();
            R.class(:) = cls; R.imgName(:) = img; R.thr(:) = thr;
            R.Origin(:) = "added";
            R.PosSource(:) = posSrc;
            R.InLocs(:) = false;
            R.Notes(:) = note;
            R.ProposalP(:) = pp(:);
            R.Excluded = obj.excludedFor(R.X, R.Y);
            if label ~= ""
                R.Label(:) = label;
                R.LabelSource(:) = lsrc;
                if lsrc ~= "auto"
                    R.Reviewed(:) = true;
                    R.Reviewer(:) = who;
                    R.ReviewedAt(:) = string(curation.AtomicIO.isoNow(false));
                end
            end
            mark = obj.txnBegin(sprintf('Add %d cell(s)', n), "addCell", opts);
            try
                obj.Meta.NextCellId = first + n;   % ids are never given back, even on failure
                obj.appendRows(R);
                obj.Txn.Entries(end + 1, 1) = curation.ChangeSet.entry('add', '', ids, [], R);
            catch ME
                obj.txnRollback(mark);
                rethrow(ME);
            end
            obj.txnCommit();
        end

        function moveCell(obj, ids, xy, posSource, ctx)
            %MOVECELL  Move cell(s) to xy (n x 2 or 1 x 2 for all); posSource default "human".
            %   Excluded follows the exclusion regions (same transaction).
            obj.assertWritable();
            if nargin < 4, posSource = ""; end
            if nargin < 5, ctx = struct(); end
            posSource = curation.Store.oneText(posSource, 'position source');
            if posSource == "", posSource = "human"; end   % '' / "" / [] = the default
            posSource = curation.Store.canonMember(posSource, curation.Store.POS_SOURCES, 'position source');
            ids = ids(:);
            rows = obj.rowsOf(ids);
            xy = double(xy);
            if size(xy, 2) ~= 2 || any(~isfinite(xy(:))) || ~(size(xy, 1) == 1 || size(xy, 1) == numel(rows))
                error('curation:Store:badArgument', 'xy must be 1 x 2 or one finite row per id.');
            end
            if size(xy, 1) == 1, xy = repmat(xy, numel(rows), 1); end
            x0 = obj.C.X(rows); y0 = obj.C.Y(rows);
            mark = obj.txnBegin(sprintf('Move %d cell(s)', numel(rows)), "moveCell", ctx);
            try
                obj.txnSet('X', rows, xy(:, 1));
                obj.txnSet('Y', rows, xy(:, 2));
                obj.txnSet('PosSource', rows, posSource);
                obj.enforceExcluded(rows);
                obj.followRescore(rows, x0, y0);
            catch ME
                obj.txnRollback(mark);
                rethrow(ME);
            end
            obj.txnCommit();
        end

        function mergeCells(obj, ids, keeperId, xy, ctx)
            %MERGECELLS  Merge duplicates into keeperId; optional xy (1 x 2) moves the keeper.
            obj.assertWritable();
            if nargin < 4, xy = []; end
            if nargin < 5, ctx = struct(); end
            kRow = obj.rowsOf(keeperId);
            if ~isscalar(kRow)
                error('curation:Store:badArgument', 'keeperId must be one CellID.');
            end
            if obj.C.State(kRow) == "merged"
                error('curation:Store:badMerge', 'Cell %d is merged into %d and cannot keep others.', ...
                    obj.C.CellID(kRow), obj.C.MergedInto(kRow));
            end
            if ~isempty(xy)
                xy = double(xy);
                if numel(xy) ~= 2 || any(~isfinite(xy(:)))
                    error('curation:Store:badArgument', 'xy must be one finite position.');
                end
            end
            rows = obj.uniqueRows(ids);
            others = rows(rows ~= kRow);
            keeper = obj.C.CellID(kRow);
            children = find(ismember(obj.C.MergedInto, obj.C.CellID(others)) & obj.C.State == "merged");
            children = setdiff(children, [others; kRow]);
            mark = obj.txnBegin(sprintf('Merge %d cell(s) into %d', numel(others), keeper), "mergeCells", ctx);
            try
                obj.txnSet('State', others, "merged");
                obj.txnSet('MergedInto', others, keeper);
                obj.txnSet('MergedInto', children, keeper);
                obj.txnSet('State', kRow, "active");
                if ~isempty(xy)
                    x0 = obj.C.X(kRow); y0 = obj.C.Y(kRow);
                    obj.txnSet('X', kRow, xy(1));
                    obj.txnSet('Y', kRow, xy(2));
                    obj.txnSet('PosSource', kRow, "human");
                    obj.enforceExcluded(kRow);
                    obj.followRescore(kRow, x0, y0);
                end
            catch ME
                obj.txnRollback(mark);
                rethrow(ME);
            end
            obj.txnCommit();
        end

        function unmerge(obj, id, ctx)
            %UNMERGE  Undo a merge: a merged id -> active; a keeper id -> all rows merged into it.
            obj.assertWritable();
            if nargin < 3, ctx = struct(); end
            rows = obj.uniqueRows(id);
            targets = rows(obj.C.State(rows) == "merged");
            keepers = rows(obj.C.State(rows) ~= "merged");
            if ~isempty(keepers)
                targets = [targets; find(ismember(obj.C.MergedInto, obj.C.CellID(keepers)) ...
                    & obj.C.State == "merged")];
            end
            targets = unique(targets);
            mark = obj.txnBegin(sprintf('Unmerge %d cell(s)', numel(targets)), "unmerge", ctx);
            try
                obj.txnSet('State', targets, "active");
                obj.txnSet('MergedInto', targets, uint32(0));
            catch ME
                obj.txnRollback(mark);
                rethrow(ME);
            end
            obj.txnCommit();
        end

        function keepBoth(obj, ids, ctx)
            %KEEPBOTH  Record pair(s) [a b] (or N x 2) as distinct cells: not proposed again.
            obj.assertWritable();
            if nargin < 3, ctx = struct(); end
            ids = double(ids);
            if isvector(ids) && numel(ids) == 2, ids = reshape(ids, 1, 2); end
            if size(ids, 2) ~= 2
                error('curation:Store:badArgument', 'keepBoth takes [a b] or an N x 2 array.');
            end
            obj.rowsOf(ids(:));   % validates
            pairs = uint32(sort(ids, 2));
            pairs = pairs(pairs(:, 1) ~= pairs(:, 2), :);
            old = obj.Meta.KeptPairs;
            new = unique([old; pairs], 'rows');
            if isequal(new, old), return; end
            mark = obj.txnBegin(sprintf('Keep both (%d pair(s))', size(pairs, 1)), "keepBoth", ctx);
            try
                obj.txnMeta('KeptPairs', new);
            catch ME
                obj.txnRollback(mark);
                rethrow(ME);
            end
            obj.txnCommit();
        end

        function setSweepDone(obj, tf)
            %SETSWEEPDONE  Missed-cell sweep done flag (journaled, undoable). tf: logical scalar.
            obj.assertWritable();
            tf = curation.Store.oneFlag(tf, 'SweepDone');
            if isequal(obj.Meta.SweepDone, tf), return; end
            mark = obj.txnBegin("Sweep done: " + string(tf), "setSweepDone", struct());
            try
                obj.txnMeta('SweepDone', tf);
            catch ME
                obj.txnRollback(mark);
                rethrow(ME);
            end
            obj.txnCommit();
        end

        function setComplete(obj, tf)
            %SETCOMPLETE  Section complete flag (journaled, undoable). tf: logical scalar.
            obj.assertWritable();
            tf = curation.Store.oneFlag(tf, 'Complete');
            if isequal(obj.Meta.Complete, tf), return; end
            mark = obj.txnBegin("Complete: " + string(tf), "setComplete", struct());
            try
                obj.txnMeta('Complete', tf);
            catch ME
                obj.txnRollback(mark);
                rethrow(ME);
            end
            obj.txnCommit();
        end

        function setAutoReject(obj, st, ctx)
            %SETAUTOREJECT  Auto-reject state of this source (journaled, undoable meta change,
            %   saved in sources.<key>.autoReject). st: struct with enabled (logical), tau (double,
            %   NaN or [] = none), modelVersion (text), audit (struct, free-form). Missing fields
            %   take the defaults false / NaN / "" / struct(). Meta.AutoReject holds the canonical
            %   form: audit as jsondecode(jsonencode(audit)), so it is identical after a reopen.
            obj.assertWritable();
            if nargin < 3, ctx = struct(); end
            new = curation.Store.normAutoReject(st);
            if isequaln(new, obj.Meta.AutoReject), return; end
            mark = obj.txnBegin("Auto-reject settings", "setAutoReject", ctx);
            try
                obj.txnMeta('AutoReject', new);
            catch ME
                obj.txnRollback(mark);
                rethrow(ME);
            end
            obj.txnCommit();
        end

        %% ------------------------------------------------------------------ regions
        function r = regions(obj)
            %REGIONS  The dataset's regions (shared by every source of the dataset): N x 1 struct
            %   array with fields id (double), kind ("exclude"|"analysis"|"reference"), scope
            %   ("image" or a source key), xy (M x 2 double, full-resolution px), note (string);
            %   0 x 1 with those fields when there are none. As of open, the last write of this
            %   store, or the last reloadRegions().
            r = obj.RegionCache;
        end

        function id = addRegion(obj, region, ctx)
            %ADDREGION  Add a region (struct with kind, xy M x 2 (M >= 3), optional scope
            %   (default "image"), note, id). id 0 or missing -> a new id from the shared JSON's
            %   nextRegionId (never one in use, never one handed out before, even when that region
            %   was removed); an id already in use throws curation:Store:badArgument. Journaled,
            %   undoable, joins an open batch; written to the shared JSON at commit. Rows inside an
            %   "exclude" region (scope "image" or this source) become Excluded in the same
            %   transaction.
            obj.assertWritable();
            if nargin < 3, ctx = struct(); end
            r = curation.Store.checkRegion(region);
            taken = curation.Store.regionIds(obj.RegionCache);
            if obj.Persist
                taken = [taken; curation.Store.regionIds(obj.readRegionsFile())];
            end
            if r.id == 0
                r.id = obj.reserveRegionId(taken);
            elseif any(taken == r.id)
                error('curation:Store:badArgument', 'Region id %g already exists.', r.id);
            else
                obj.NextRegionIdMem = max(obj.NextRegionIdMem, r.id + 1);
            end
            id = r.id;
            mark = obj.txnBegin(sprintf('Add %s region %g', r.kind, id), "addRegion", ctx);
            try
                obj.txnRegion([], r);
                obj.enforceExcluded();
            catch ME
                obj.txnRollback(mark);
                rethrow(ME);
            end
            obj.txnCommit();
        end

        function tf = removeRegion(obj, id, ctx)
            %REMOVEREGION  Remove the region with this id; false when there is none. Journaled,
            %   undoable, joins an open batch; written to the shared JSON at commit. Rows no longer
            %   inside any exclude region lose Excluded in the same transaction.
            obj.assertWritable();
            if nargin < 3, ctx = struct(); end
            tf = false;
            k = find(curation.Store.regionIds(obj.RegionCache) == double(id), 1);
            if isempty(k) && obj.Persist && obj.BatchDepth == 0
                obj.RegionCache = obj.readRegionsFile();   % added by the other channel?
                k = find(curation.Store.regionIds(obj.RegionCache) == double(id), 1);
            end
            if isempty(k), return; end
            r = obj.RegionCache(k);
            mark = obj.txnBegin(sprintf('Remove %s region %g', r.kind, r.id), "removeRegion", ctx);
            try
                obj.txnRegion(r, []);
                obj.enforceExcluded();
            catch ME
                obj.txnRollback(mark);
                rethrow(ME);
            end
            obj.txnCommit();
            tf = true;
        end

        function reloadRegions(obj)
            %RELOADREGIONS  Re-read the regions from the shared JSON (the other channel's store
            %   writes the same array). Fires Changed (Kind "regions") when they differ. Allowed
            %   on read-only stores; not inside a batch (curation:Store:inBatch).
            %   Rows whose Excluded the reloaded regions change are updated as a structural
            %   (journaled, not undoable) transaction; on a read-only store in memory only.
            %   Throws curation:AtomicIO:jsonUnreadable when the JSON cannot be read.
            obj.assertNoBatch();
            if ~obj.Persist || obj.Closed, return; end
            new = obj.readRegionsFile();
            changed = ~isequaln(new, obj.RegionCache);
            obj.RegionCache = new;
            if ~obj.ReadOnly && ~obj.ownsLockNow(), obj.loseLock(); end
            E = obj.resyncExcluded("Regions reloaded", true);
            if ~isempty(E) && ~obj.ReadOnly
                obj.scheduleSave();
            end
            if ~changed && isempty(E), return; end
            cs = curation.ChangeSet("Regions reloaded", "reloadRegions", E);
            cs.Revision = obj.Meta.Revision;
            obj.fireChanged(cs, "regions", true);
        end

        function id = reserveRegionId(obj, taken)
            % A new region id: above every id in use and every id handed out before.
            if obj.Persist
                floorMax = max([0; taken(:)]);
                s = curation.AtomicIO.updateJson(obj.Paths.json, ...
                    @(J) curation.Store.reserveRegionIdIn(J, floorMax));
                id = double(s.nextRegionId) - 1;
            else
                id = max([obj.NextRegionIdMem; max([0; taken(:)]) + 1]);
            end
            obj.NextRegionIdMem = max(obj.NextRegionIdMem, id + 1);
        end

        %% ------------------------------------------------------------------ undo / batches
        function tf = undo(obj)
            %UNDO  Revert the last transaction. false when there is nothing to undo. Undoing a
            %   region removal whose id is now held by a different region (the other channel's)
            %   throws curation:Store:regionConflict and changes nothing.
            obj.assertWritable();
            obj.assertNoBatch();
            tf = false;
            if isempty(obj.UndoStack), return; end
            if ~obj.ownsLockNow(), obj.loseLock(); end
            cs = obj.UndoStack{end};
            obj.UndoStack(end) = [];
            obj.applyEntries(cs.Entries, false);
            jcs = curation.Store.invertForJournal(cs);
            try
                obj.persistRegionOps(jcs.Entries);
            catch ME
                obj.applyEntries(cs.Entries, true);
                obj.UndoStack{end + 1} = cs;
                rethrow(ME);
            end
            extra = obj.resyncAfter(cs);
            jcs.Entries = [jcs.Entries; extra];
            obj.RedoStack{end + 1} = cs;
            jcs.Action = "undo";
            jcs.Desc = "Undo: " + cs.Desc;
            obj.finishReplay(jcs, cs, "undo", ~isempty(extra));
            tf = true;
        end

        function tf = redo(obj)
            %REDO  Re-apply the last undone transaction. false when there is nothing to redo.
            %   A region id now held by a different region: curation:Store:regionConflict, no change.
            obj.assertWritable();
            obj.assertNoBatch();
            tf = false;
            if isempty(obj.RedoStack), return; end
            if ~obj.ownsLockNow(), obj.loseLock(); end
            cs = obj.RedoStack{end};
            obj.RedoStack(end) = [];
            obj.applyEntries(cs.Entries, true);
            try
                obj.persistRegionOps(cs.Entries);
            catch ME
                obj.applyEntries(cs.Entries, false);
                obj.RedoStack{end + 1} = cs;
                rethrow(ME);
            end
            extra = obj.resyncAfter(cs);
            obj.pushUndo(cs);
            jcs = cs;
            jcs.Entries = [jcs.Entries; extra];
            jcs.Action = "redo";
            jcs.Desc = "Redo: " + cs.Desc;
            obj.finishReplay(jcs, cs, "redo", ~isempty(extra));
            tf = true;
        end

        function beginBatch(obj, desc)
            %BEGINBATCH  Start grouping calls into one transaction (nestable). A call inside the
            %   batch that throws reverts only its own changes; the batch stays open.
            obj.assertWritable();
            if nargin < 2 || isempty(desc), desc = "Batch"; end
            if obj.BatchDepth == 0
                obj.Txn = curation.Store.newTxn(desc, "batch", struct());
                obj.Txn.NextCellId0 = obj.Meta.NextCellId;
            end
            obj.BatchDepth = obj.BatchDepth + 1;
        end

        function endBatch(obj)
            %ENDBATCH  Close a batch level; the outermost commits the transaction.
            if obj.BatchDepth <= 0
                error('curation:Store:noBatch', 'endBatch without beginBatch.');
            end
            obj.BatchDepth = obj.BatchDepth - 1;
            if obj.BatchDepth == 0
                obj.txnCommit();
            end
        end

        function cancelBatch(obj)
            %CANCELBATCH  Revert everything done in the open batch and drop it.
            if obj.BatchDepth <= 0, return; end
            obj.BatchDepth = 0;
            obj.txnAbort();
        end

        %% ------------------------------------------------------------------ persistence
        function scheduleSave(obj)
            %SCHEDULESAVE  Arm the debounced snapshot: it is written AutosaveDelay s after the
            %   last change (at the latest 10 x AutosaveDelay after the first unsaved one).
            if ~obj.Persist || obj.ReadOnly || obj.Closed, return; end
            obj.LastChangeTic = tic;
            if isempty(obj.PendingSinceTic), obj.PendingSinceTic = obj.LastChangeTic; end
            d = obj.Options.AutosaveDelay;
            if ~(d > 0) || ~isfinite(d) || obj.TimerActive, return; end
            try
                if isempty(obj.SaveTimer) || ~isvalid(obj.SaveTimer)
                    obj.SaveTimer = obj.makeTimer(d);
                end
                start(obj.SaveTimer);
                obj.TimerActive = true;
            catch ME
                obj.LastError = string(ME.message);
            end
        end

        function flush(obj)
            %FLUSH  Write the snapshot CSV and the JSON record now (when Dirty or missing; the
            %   JSON record alone when only it is pending). Throws curation:AtomicIO:jsonUnreadable
            %   (or jsonBusy) after writing the CSV and the journal when the shared JSON cannot be
            %   read: the JSON is never rebuilt from nothing, and the record is written by the next
            %   flush once it reads again. Throws curation:Store:lockLost when another session took
            %   the lock (the store is then read-only).
            if ~obj.Persist || obj.ReadOnly || obj.Closed || obj.BatchDepth > 0 || ~obj.Ready
                return;
            end
            if obj.Dirty || ~isfile(obj.Paths.csv)
                obj.writeSnapshot();
            elseif obj.JsonStale
                obj.writeSnapshotJson();
            end
        end

        function close(obj)
            %CLOSE  Flush, stop the save timer, close the journal, release the lock.
            if obj.Closed, return; end
            obj.stopTimer();
            if obj.BatchDepth > 0
                obj.BatchDepth = 0;
                obj.txnCommit();
            end
            if obj.Persist && ~obj.ReadOnly
                try
                    obj.flush();
                catch ME
                    obj.LastError = string(ME.message);
                    warning('curation:Store:flushFailed', 'Saving %s failed: %s', obj.Paths.csv, ME.message);
                end
            end
            if ~isempty(obj.JournalObj)
                try obj.JournalObj.close(); catch, end
            end
            obj.releaseLock();
            obj.Closed = true;
        end

        function delete(obj)
            try
                obj.close();
            catch
            end
            try
                if ~isempty(obj.SaveTimer) && isvalid(obj.SaveTimer)
                    stop(obj.SaveTimer);
                    delete(obj.SaveTimer);
                end
            catch
            end
        end

        %% ------------------------------------------------------------------ reconcile
        function rep = reconcile(obj, locsTbl, opts)
            %RECONCILE  Re-attach the rows to a regenerated locs table (see RECONCILE in the help).
            %   opts: TolUm (default the store's), Fingerprint (default from the table),
            %   AllowEmpty (false: a table without detections is refused, curation:Store:emptyLocs,
            %   while rows are matched to the current locs), Force (false: refused,
            %   curation:Store:reconcileMismatch, when fewer than half of the rows matched to the
            %   current locs find a match). A refused reconcile changes nothing; its report is in
            %   LastReconcile (Refused true). All or nothing: when the snapshot cannot be written
            %   every change is reverted and the error rethrown.
            obj.assertWritable();
            obj.assertNoBatch();
            if nargin < 3 || ~isstruct(opts), opts = struct(); end
            tolUm = curation.Store.metaField(opts, 'TolUm', obj.Options.TolUm);
            fp = char(curation.Store.metaField(opts, 'Fingerprint', ''));
            if isempty(fp)
                fp = curation.Reconciler.tableFingerprint(locsTbl);
            end
            rep = obj.reconcileImpl(locsTbl, fp, tolUm, false, opts);
        end

        %% ------------------------------------------------------------------ queries
        function rows = rowsOf(obj, ids)
            %ROWSOF  Row index (in T) of each CellID; throws curation:Store:unknownId.
            ids = double(ids(:));
            n = numel(obj.RowOfId);
            bad = ~(ids >= 1 & ids <= n & ids == fix(ids));
            if any(bad)
                error('curation:Store:unknownId', 'Unknown CellID %g.', ids(find(bad, 1)));
            end
            rows = obj.RowOfId(ids);
            if any(rows == 0)
                error('curation:Store:unknownId', 'Unknown CellID %g.', ids(find(rows == 0, 1)));
            end
        end

        function v = get(obj, field, ids)
            %GET  Column values: all rows, or the rows of ids (in ids order).
            field = char(field);
            if ~isfield(obj.C, field)
                error('curation:Store:badArgument', 'Unknown column %s.', field);
            end
            if nargin < 3
                v = obj.C.(field);
            else
                v = obj.C.(field)(obj.rowsOf(ids));
            end
        end

        function m = keptMask(obj)
            %KEPTMASK  Kept rule per row (see SEMANTICS).
            c = obj.C;
            m = c.State == "active" & c.Label == "Good" & c.Reviewed & ~c.Excluded ...
                & ismember(c.LabelSource, curation.Store.KEEP_SOURCES);
        end

        function K = kept(obj)
            %KEPT  Table of the kept rows.
            K = obj.T(obj.keptMask(), :);
        end

        function s = counts(obj)
            %COUNTS  Row counts (see the help for the fields).
            c = obj.C;
            act = c.State == "active";
            rev = c.Reviewed;
            auto = act & c.LabelSource == "auto" & c.Label == "Bad";
            keptM = obj.keptMask();
            s = struct();
            s.total = numel(c.CellID);
            s.active = nnz(act);
            s.reviewed = nnz(act & rev);
            s.good = nnz(act & rev & c.Label == "Good");
            s.bad = nnz(act & rev & c.Label == "Bad");
            s.uncertain = nnz(act & rev & c.Label == "Uncertain");
            s.unreviewed = nnz(act & ~rev);
            s.toReview = nnz(act & ~rev & ~auto & ~c.Excluded);
            s.kept = nnz(keptM);
            s.autoRejected = nnz(auto);
            s.flagged = nnz(act & strlength(c.Flag) > 0);
            s.merged = nnz(c.State == "merged");
            s.added = nnz(c.Origin == "added");
            s.stale = nnz(c.State == "stale");
            s.vanishedGood = nnz(keptM & ~c.InLocs & c.Origin == "detected");
            s.excluded = nnz(act & c.Excluded);
            s.rescorePending = nnz(act & c.RescoreSource == "");
        end

        function exportFinal(obj, path)
            %EXPORTFINAL  Write the kept rows: X,Y,class,score,imgName,thr,rescore,CellID.
            if nargin < 2 || isempty(path)
                path = obj.Paths.final;
            end
            if isempty(path)
                error('curation:Store:noPath', 'An in-memory store needs an export path.');
            end
            m = obj.keptMask();
            c = obj.C;
            f = @curation.AtomicIO.fmtDouble;
            P = [f(c.X(m)), f(c.Y(m)), f(c.class(m)), f(c.score(m)), ...
                curation.AtomicIO.csvEscape(c.imgName(m)), f(c.thr(m)), f(c.rescore(m)), ...
                string(c.CellID(m))];
            hdr = "X,Y,class,score,imgName,thr,rescore,CellID";
            if isempty(P)
                txt = hdr + newline;
            else
                txt = strjoin([hdr; join(P, ",", 2)], newline) + newline;
            end
            curation.AtomicIO.writeText(path, txt);
        end
    end

    %% ======================================================================== dependent
    methods
        function T = get.T(obj)
            if isempty(obj.TCache)
                cols = curation.Store.COLS;
                vals = cell(1, numel(cols));
                for k = 1:numel(cols)
                    vals{k} = obj.C.(cols{k});
                end
                obj.TCache = table(vals{:}, 'VariableNames', cols);
            end
            T = obj.TCache;
        end

        function tf = get.Dirty(obj)
            tf = obj.Meta.Revision ~= obj.SavedRevision || obj.DerivedDirty;
        end

        function tf = get.CanUndo(obj)
            tf = ~isempty(obj.UndoStack) && ~obj.ReadOnly && ~obj.Closed;
        end

        function tf = get.CanRedo(obj)
            tf = ~isempty(obj.RedoStack) && ~obj.ReadOnly && ~obj.Closed;
        end

        function tf = get.InBatch(obj)
            tf = obj.BatchDepth > 0;
        end

        function n = get.NumRows(obj)
            n = numel(obj.C.CellID);
        end

        function s = get.JournalInfo(obj)
            s = [];
            j = obj.JournalObj;
            if isempty(j), return; end
            s = struct('Path', j.Path, 'Bytes', j.Bytes, 'KeepOpen', j.KeepOpen, ...
                'LastError', j.LastError);
        end
    end

    %% ======================================================================== transactions
    methods (Access = private)

        function assertWritable(obj)
            if obj.Closed
                error('curation:Store:closed', 'This curation store is closed.');
            end
            if obj.ReadOnly
                msg = 'This curation store is read-only.';
                if isfield(obj.LockInfo, 'Message') && strlength(string(obj.LockInfo.Message)) > 0
                    msg = char(obj.LockInfo.Message);
                end
                error('curation:Store:readOnly', '%s', msg);
            end
        end

        function assertNoBatch(obj)
            if obj.BatchDepth > 0
                error('curation:Store:inBatch', 'Not allowed inside beginBatch/endBatch.');
            end
        end

        function [rows, ia] = uniqueRows(obj, ids)
            ids = ids(:);
            rows = obj.rowsOf(ids);
            if numel(rows) > 1
                [rows, ia] = unique(rows, 'stable');
            else
                ia = (1:numel(rows))';
            end
        end

        function simpleSet(obj, desc, action, field, rows, val, ctx)
            if isempty(rows), return; end
            mark = obj.txnBegin(desc, action, ctx);
            try
                obj.txnSet(field, rows, val);
            catch ME
                obj.txnRollback(mark);
                rethrow(ME);
            end
            obj.txnCommit();
        end

        function mark = txnBegin(obj, desc, action, ctx)
            % Open (or join) the transaction; MARK = its entry count before this call, so a failing
            % call can roll back only its own entries (txnRollback).
            if isempty(obj.Txn)
                obj.Txn = curation.Store.newTxn(desc, action, ctx);
                obj.Txn.NextCellId0 = obj.Meta.NextCellId;
            elseif isstruct(ctx)
                % inside a batch: keep the first context given
                for f = {'Queue', 'PageId', 'DwellMs'}
                    if isfield(ctx, f{1}) && ~isempty(ctx.(f{1})) && ...
                            (~isfield(obj.Txn.Ctx, f{1}) || isempty(obj.Txn.Ctx.(f{1})))
                        obj.Txn.Ctx.(f{1}) = ctx.(f{1});
                    end
                end
            end
            mark = numel(obj.Txn.Entries);
        end

        function txnRollback(obj, mark)
            % Revert the entries a failing call added after MARK. Inside a batch the batch stays
            % open with everything before MARK; outside one the transaction is dropped.
            if isempty(obj.Txn), return; end
            E = obj.Txn.Entries;
            if mark < numel(E)
                obj.applyEntries(E(mark + 1:end), false);
                obj.Txn.Entries = E(1:mark);
            end
            if obj.BatchDepth == 0
                obj.Txn = [];
            end
            obj.TCache = [];
        end

        function txnSet(obj, field, rows, vals, force)
            % FORCE: record every row, also those whose value does not change (so undo/redo set
            % it exactly; see followRescore).
            if isempty(rows), return; end
            n = numel(rows);
            vals = curation.Store.castCol(curation.Store.TYPE_OF.(field), vals);
            if isscalar(vals) && n > 1
                vals = repmat(vals, n, 1);
            end
            old = obj.C.(field)(rows);
            if nargin < 5 || ~force
                if isfloat(old)
                    ch = ~(old == vals | (isnan(old) & isnan(vals)));
                else
                    ch = old ~= vals;
                end
                if ~any(ch), return; end
                if ~all(ch)
                    rows = rows(ch); old = old(ch); vals = vals(ch);
                end
            end
            obj.C.(field)(rows) = vals;
            obj.Txn.Entries(end + 1, 1) = curation.ChangeSet.entry('set', field, ...
                obj.C.CellID(rows), old, vals);
        end

        function txnMeta(obj, name, val)
            old = obj.Meta.(name);
            obj.Meta.(name) = val;
            obj.Txn.Entries(end + 1, 1) = curation.ChangeSet.entry('meta', name, [], old, val);
        end

        function txnRegion(obj, oldR, newR)
            % One region transition (old -> new; [] = none) in the open transaction.
            obj.Txn.Entries(end + 1, 1) = curation.ChangeSet.entry('region', 'Regions', [], oldR, newR);
            obj.RegionCache = curation.Store.regionOp(obj.RegionCache, oldR, newR);
        end

        function persistRegionOps(obj, entries)
            % Apply the region entries (in order, old -> new) to the shared JSON with one
            % atomic load-modify-write, then take the file's regions as the cache. A region id
            % that is now held by a different region throws curation:Store:regionConflict and
            % writes nothing.
            if isempty(entries) || ~any(strcmp({entries.Kind}, 'region')) || ~obj.Persist
                return;
            end
            ops = entries(strcmp({entries.Kind}, 'region'));
            try
                curation.AtomicIO.updateJson(obj.Paths.json, @(J) curation.Store.applyRegionOps(J, ops));
            catch ME
                if strcmp(ME.identifier, 'curation:Store:regionConflict')
                    rethrow(ME);
                end
                error('curation:Store:regionWriteFailed', 'Writing the regions to %s failed: %s', ...
                    obj.Paths.json, ME.message);
            end
            % read back, so the cache is exactly what a reopen (or the other channel) will see
            obj.RegionCache = obj.readRegionsFile();
        end

        function R = readRegionsFile(obj)
            % The regions of the shared JSON; throws curation:AtomicIO:jsonUnreadable when the
            % file exists but cannot be read (never "no regions" for an unreadable file).
            R = curation.Store.emptyRegions();
            if ~obj.Persist, return; end
            J = curation.AtomicIO.readJsonStrict(obj.Paths.json);
            if isstruct(J) && isscalar(J) && isfield(J, 'regions')
                R = curation.Store.normRegions(J.regions);
            end
        end

        function txnAbort(obj)
            if isempty(obj.Txn), return; end
            entries = obj.Txn.Entries;
            obj.Txn = [];
            obj.applyEntries(entries, false);
            obj.TCache = [];
        end

        function txnCommit(obj)
            if obj.BatchDepth > 0, return; end
            txn = obj.Txn;
            obj.Txn = [];
            if isempty(txn) || isempty(txn.Entries), return; end
            if ~obj.ownsLockNow()
                obj.applyEntries(txn.Entries, false);   % nothing of it may stay unsaved in memory
                obj.loseLock();                          % throws curation:Store:lockLost
            end
            if any(strcmp({txn.Entries.Kind}, 'region'))
                try
                    obj.persistRegionOps(txn.Entries);   % shared JSON first: on failure, roll back
                catch ME
                    obj.applyEntries(txn.Entries, false);
                    rethrow(ME);
                end
                % the file may also hold regions the other channel added meanwhile: Excluded
                % follows all of them, in this same transaction
                obj.Txn = txn;
                obj.enforceExcluded();
                txn = obj.Txn;
                obj.Txn = [];
            end
            cs = curation.ChangeSet(txn.Desc, txn.Action, txn.Entries);
            cs = obj.stamp(cs, txn.Ctx);
            obj.pushUndo(cs);
            obj.RedoStack = {};
            obj.TCache = [];
            jcs = cs;
            if isfield(txn, 'NextCellId0') && obj.Meta.NextCellId > txn.NextCellId0
                % ids handed out are journaled (journal copy only: undo never gives one back)
                jcs.Entries(end + 1, 1) = curation.ChangeSet.entry('meta', 'NextCellId', [], ...
                    txn.NextCellId0, obj.Meta.NextCellId);
            end
            obj.journalWrite(jcs);
            obj.fireChanged(cs, "do", false);
            obj.scheduleSave();
        end

        function cs = sysCommit(obj, desc, action, entries, journal)
            % A structural transaction the store makes itself (reconcile, legacy import, keeping
            % Excluded in step with regions changed elsewhere): stamped with a new revision and
            % journaled like a person's transaction, but never undoable.
            cs = curation.ChangeSet(desc, action, entries);
            cs = obj.stamp(cs, struct());
            cs.Kind = string(action);
            obj.TCache = [];
            if journal && ~isempty(entries) && ~isempty(obj.JournalObj)
                obj.journalWrite(cs);
            end
        end

        %% ------------------------------------------------------------------ Excluded invariant
        function tf = excludedFor(obj, x, y)
            % Inside any "exclude" region of scope "image" or this source's key.
            x = double(x(:)); y = double(y(:));
            tf = false(numel(x), 1);
            R = obj.RegionCache;
            if isempty(R) || isempty(x), return; end
            sel = [R.kind]' == "exclude" & ([R.scope]' == "image" | [R.scope]' == string(obj.Meta.Key));
            if ~any(sel), return; end
            try
                tf = curation.Regions.excluded(R(sel), [x y], obj.Meta.Key);
            catch
                % private fallback (curation.Regions absent): any applicable polygon contains it
                for r = reshape(R(sel), 1, [])
                    tf = tf | inpolygon(x, y, r.xy(:, 1), r.xy(:, 2));
                end
            end
            tf = reshape(logical(tf), [], 1);
        end

        function enforceExcluded(obj, rows)
            % Inside the open transaction: Excluded of ROWS (default all) := what the regions say.
            if nargin < 2, rows = (1:numel(obj.C.CellID))'; end
            rows = rows(:);
            if isempty(rows), return; end
            obj.txnSet('Excluded', rows, obj.excludedFor(obj.C.X(rows), obj.C.Y(rows)));
        end

        %% ------------------------------------------------------------------ rescore follows the position
        function followRescore(obj, rows, x0, y0)
            % Inside the open transaction, after ROWS moved from (x0, y0) (see RESCORE): a row that
            % moved more than POS_TOL_PX loses its score (NaN, pending) unless it now sits on its
            % detector position, where the current locs' value comes back ("detector"); a
            % "detector" value off its detector position is dropped too. The moved rows' rescore
            % and RescoreSource are recorded even when unchanged, so undo/redo set exactly the
            % value of that time, never one setRescore stored in between for the other position.
            if isempty(rows), return; end
            [rows, ia] = unique(rows(:), 'stable');
            x0 = x0(ia); y0 = y0(ia);
            tol = curation.Store.POS_TOL_PX;
            c = obj.C;
            x = c.X(rows); y = c.Y(rows);
            moved = hypot(x - x0(:), y - y0(:)) > tol;
            onDet = hypot(x - c.DET_X(rows), y - c.DET_Y(rows)) <= tol;   % NaN DET: false
            src = c.RescoreSource(rows);
            isDet = src == "detector";
            back = moved & onDet & ~isDet;
            drop = (moved & ~onDet) | (isDet & ~onDet);
            touch = moved | drop;
            if ~any(touch), return; end
            r = c.rescore(rows);
            r(drop) = NaN;
            src(drop) = "";
            if any(back)
                b = find(back);
                v = obj.detectorRescore(rows(b));
                ok = isfinite(v);
                r(b) = v;
                src(b) = "";
                src(b(ok)) = "detector";
            end
            obj.txnSet('rescore', rows(touch), r(touch), true);
            obj.txnSet('RescoreSource', rows(touch), src(touch), true);
        end

        function v = detectorRescore(obj, rows)
            % The current locs' rescore at each row's detector position (within POS_TOL_PX); NaN
            % when it cannot be told: the row is not matched to the current locs, or the locs at
            % hand are not those the rows were matched to (changed since the last reconcile).
            rows = rows(:);
            v = nan(numel(rows), 1);
            c = obj.C;
            k = find(c.InLocs(rows) & isfinite(c.DET_X(rows)) & isfinite(c.DET_Y(rows)));
            if isempty(k), return; end
            N = obj.currentLocs();
            if isempty(N) || isempty(N.X), return; end
            [a, b] = curation.Reconciler.match([c.DET_X(rows(k)), c.DET_Y(rows(k))], [N.X, N.Y], ...
                curation.Store.POS_TOL_PX);
            v(k(a)) = N.rescore(b);
        end

        function N = currentLocs(obj)
            % Normalized locs (normalizeLocs) of the detector run the rows are matched to
            % (Meta.LocsFingerprint): cached, else from the in-memory locs table or the locs file;
            % [] when the file at hand is another one or missing (remembered until the next
            % reconcile, so a missing file is not read again on every move).
            fp = char(obj.Meta.LocsFingerprint);
            K = obj.LocsCache;
            if isstruct(K) && strcmp(K.fp, fp)
                N = K.N;
                return;
            end
            N = [];
            try
                src = struct('LocsTable', obj.LocsTable, 'LocsFile', char(obj.Meta.LocsFile));
                [L, lfp] = curation.Store.loadLocs(src);
                if istable(L) && ~isempty(fp) && curation.Reconciler.equivalent(fp, lfp)
                    N = curation.Store.normalizeLocs(L);
                end
            catch
                N = [];
            end
            obj.LocsCache = struct('fp', fp, 'N', N);
        end

        function E = resyncExcluded(obj, desc, journal)
            % Bring every row's Excluded in line with the regions as a structural transaction
            % (journaled when writable and JOURNAL), or in memory on a read-only store. Returns
            % the entries (empty when nothing differed).
            E = curation.ChangeSet.emptyEntries();
            t = obj.excludedFor(obj.C.X, obj.C.Y);
            ch = find(t ~= obj.C.Excluded);
            if isempty(ch), return; end
            if obj.ReadOnly || obj.Closed
                E = curation.ChangeSet.entry('set', 'Excluded', obj.C.CellID(ch), obj.C.Excluded(ch), t(ch));
                obj.C.Excluded(ch) = t(ch);
                obj.TCache = [];
                return;
            end
            saved = obj.Txn;
            obj.Txn = curation.Store.newTxn(desc, "regions", struct());
            obj.txnSet('Excluded', ch, t(ch));
            E = obj.Txn.Entries;
            obj.Txn = saved;
            obj.sysCommit(desc, "regions", E, journal);
        end

        function E = resyncAfter(obj, cs)
            % After undo/redo: the Excluded changes the regions require now (they may hold
            % regions the other channel added since), as entries for the journal copy.
            E = curation.ChangeSet.emptyEntries();
            if isempty(cs.Entries), return; end
            k = {cs.Entries.Kind};
            f = {cs.Entries.Field};
            if ~any(strcmp(k, 'region') | strcmp(k, 'add') | strcmp(f, 'X') | strcmp(f, 'Y') ...
                    | strcmp(f, 'Excluded'))
                return;
            end
            saved = obj.Txn;
            obj.Txn = curation.Store.newTxn("resync", "regions", struct());
            obj.enforceExcluded();
            E = obj.Txn.Entries;
            obj.Txn = saved;
        end

        function cs = stamp(obj, cs, ctx)
            % New revision + sequence number + time + context on a change set.
            obj.Seq = obj.Seq + 1;
            obj.Meta.Revision = obj.Meta.Revision + 1;
            cs.Revision = obj.Meta.Revision;
            cs.Seq = obj.Seq;
            cs.Time = string(curation.AtomicIO.isoNow(true));
            cs.Reviewer = obj.Reviewer;
            if nargin >= 3 && isstruct(ctx)
                if isfield(ctx, 'Queue') && ~isempty(ctx.Queue), cs.Queue = string(ctx.Queue); end
                if isfield(ctx, 'PageId') && ~isempty(ctx.PageId), cs.PageId = string(ctx.PageId); end
                if isfield(ctx, 'DwellMs') && ~isempty(ctx.DwellMs), cs.DwellMs = double(ctx.DwellMs(1)); end
            end
        end

        function pushUndo(obj, cs)
            obj.UndoStack{end + 1} = cs;
            if numel(obj.UndoStack) > curation.Store.MAX_UNDO
                obj.UndoStack(1) = [];
            end
        end

        function finishReplay(obj, jcs, cs, kind, full)
            % Common tail of undo/redo: new revision, journal, event, autosave.
            if nargin < 5, full = false; end
            jcs = obj.stamp(jcs, struct());
            obj.TCache = [];
            obj.journalWrite(jcs);
            obj.fireChanged(cs, kind, full);
            obj.scheduleSave();
        end

        function applyEntries(obj, entries, forward)
            if forward
                order = 1:numel(entries);
            else
                order = numel(entries):-1:1;
            end
            for k = order
                e = entries(k);
                switch e.Kind
                    case 'set'
                        rows = obj.RowOfId(double(e.CellID));
                        if forward
                            obj.C.(e.Field)(rows) = e.New;
                        else
                            obj.C.(e.Field)(rows) = e.Old;
                        end
                    case 'add'
                        if forward
                            obj.appendRows(e.New);
                        else
                            obj.removeIds(e.CellID);
                        end
                    case 'region'
                        if forward
                            obj.RegionCache = curation.Store.regionOp(obj.RegionCache, e.Old, e.New);
                        else
                            obj.RegionCache = curation.Store.regionOp(obj.RegionCache, e.New, e.Old);
                        end
                    case 'meta'
                        if forward
                            obj.Meta.(e.Field) = e.New;
                        else
                            obj.Meta.(e.Field) = e.Old;
                        end
                end
            end
            obj.TCache = [];
        end

        function journalWrite(obj, cs)
            if isempty(obj.JournalObj), return; end
            obj.JournalObj.append(cs);
            if strlength(obj.JournalObj.LastError) > 0
                obj.LastError = obj.JournalObj.LastError;
            end
        end

        function fireChanged(obj, cs, kind, full)
            try
                if ~event.hasListener(obj, 'Changed'), return; end
            catch
            end
            cs.Kind = string(kind);
            notify(obj, 'Changed', curation.ChangeEventData(cs, kind, full));
        end

        %% ------------------------------------------------------------------ rows
        function appendRows(obj, R)
            n0 = numel(obj.C.CellID);
            k = numel(R.CellID);
            if k == 0, return; end
            cols = curation.Store.COLS;
            for i = 1:numel(cols)
                obj.C.(cols{i}) = [obj.C.(cols{i}); R.(cols{i})(:)];
            end
            obj.RowOfId(double(R.CellID)) = n0 + (1:k)';
            obj.TCache = [];
        end

        function removeIds(obj, ids)
            ids = double(ids(:));
            ids = ids(ids >= 1 & ids <= numel(obj.RowOfId));
            rows = obj.RowOfId(ids);
            rows = rows(rows > 0);
            if isempty(rows), return; end
            keep = true(numel(obj.C.CellID), 1);
            keep(rows) = false;
            obj.C = curation.Store.selectRows(obj.C, keep);
            obj.rebuildIndex();
        end

        function rebuildIndex(obj)
            ids = double(obj.C.CellID);
            m = max([0; ids; obj.Meta.NextCellId - 1]);
            obj.RowOfId = zeros(m, 1);
            obj.RowOfId(ids) = (1:numel(ids))';
            obj.TCache = [];
        end

        function [cls, img, thr] = typicalLocsValues(obj)
            c = obj.C;
            v = c.class(isfinite(c.class));
            if isempty(v), cls = NaN; else, cls = mode(v); end
            s = c.imgName(strlength(c.imgName) > 0);
            if isempty(s)
                img = "";
            else
                [u, ~, g] = unique(s);
                [~, k] = max(accumarray(g, 1));
                img = u(k);
            end
            t = c.thr(isfinite(c.thr));
            if isempty(t), thr = NaN; else, thr = mode(t); end
        end
    end

    %% ======================================================================== open internals
    methods (Static, Access = private)

        function obj = openImpl(src, opts)
            obj = curation.Store();
            obj.Options = opts;
            obj.Reviewer = curation.AtomicIO.cleanText(opts.Reviewer);
            obj.Session = string(curation.Store.newSession());
            M = obj.Meta;
            M.Key = src.Key;
            M.Folder = src.Folder;
            M.Stem = src.Stem;
            M.ManifestBase = src.ManifestBase;
            M.LocsFile = src.LocsFile;
            obj.Meta = M;

            if isempty(src.JsonFolder), src.JsonFolder = src.Folder; end
            % a stem is needed to find the files: from the locs, else from the JSON record
            if isempty(src.Stem) && ~isempty(src.JsonFolder) && ~isempty(src.ManifestBase)
                J = curation.AtomicIO.readJson(fullfile(src.JsonFolder, [src.ManifestBase '.curation.json']));
                rec = curation.Store.sourceRecord(J, src.Key);
                if isstruct(rec) && isfield(rec, 'stem') && ~isempty(rec.stem)
                    src.Stem = char(rec.stem);
                    obj.Meta.Stem = src.Stem;
                end
            end
            obj.Persist = ~isempty(src.Folder) && ~isempty(src.Stem);
            if ~istable(src.LocsTable) && isempty(src.LocsFile) && ~obj.Persist
                error('curation:Store:noLocs', 'No locs file found for source %s.', src.Key);
            end
            if istable(src.LocsTable), obj.LocsTable = src.LocsTable; end
            try
                obj.openBody(src, opts);
            catch ME
                obj.abandonOpen();   % release the lock, write nothing
                rethrow(ME);
            end
        end

        function src = emptySrc()
            src = struct('Key', 'default', 'Folder', '', 'JsonFolder', '', 'Stem', '', 'ManifestBase', '', ...
                'LocsFile', '', 'LocsTable', [], 'UmPerPixel', NaN, 'UmSource', "", ...
                'ImagePath', '', 'Page', 1, 'ImageSize', [], 'QcPath', '', 'QcResized', false, ...
                'QcScale', NaN, 'ResizedLocs', '', 'DetectionCount', NaN);
        end

        function opts = fillOpts(opts)
            if ~isstruct(opts), opts = struct(); end
            user = getenv('USERNAME');
            if isempty(user), user = getenv('USER'); end
            d = struct('TolUm', 8, 'Reviewer', string(user), 'ReadOnly', false, ...
                'ImportLegacy', true, 'AutosaveDelay', 2, 'Force', false, ...
                'OrphanMergePx', 10, 'LocsFile', '', 'QcPath', '', 'Rebuild', false, ...
                'AllowEmpty', false, 'ForceReconcile', false, 'DetectionCount', NaN);
            f = fieldnames(d);
            for k = 1:numel(f)
                if ~isfield(opts, f{k}) || (isempty(opts.(f{k})) && ~ischar(d.(f{k})))
                    opts.(f{k}) = d.(f{k});
                end
            end
            opts.ReadOnly = logical(opts.ReadOnly);
            opts.Force = logical(opts.Force);
            opts.Rebuild = logical(opts.Rebuild);
            opts.AllowEmpty = logical(opts.AllowEmpty);
            opts.ForceReconcile = logical(opts.ForceReconcile);
            % ImportLegacy: true | false | "force" (import even onto a curated store, sparing every
            % row a person decided)
            v = opts.ImportLegacy;
            opts.ImportForce = false;
            if ischar(v) || isstring(v)
                s = lower(strtrim(string(v)));
                if s == "force"
                    opts.ImportLegacy = true;
                    opts.ImportForce = true;
                elseif any(s == ["true", "1", "yes", "on"])
                    opts.ImportLegacy = true;
                elseif any(s == ["false", "0", "no", "off"])
                    opts.ImportLegacy = false;
                else
                    error('curation:Store:badArgument', 'ImportLegacy is true, false or "force" (got "%s").', s);
                end
            else
                opts.ImportLegacy = logical(v);
            end
            opts.TolUm = double(opts.TolUm);
            opts.AutosaveDelay = double(opts.AutosaveDelay);
            opts.DetectionCount = double(opts.DetectionCount);
        end

        function v = metaField(s, name, default)
            v = default;
            if isstruct(s) && isfield(s, name) && ~isempty(s.(name))
                v = s.(name);
            end
        end

        function M = defaultMeta()
            M = struct('Key', '', 'Stem', '', 'Folder', '', 'ManifestBase', '', ...
                'UmPerPixel', NaN, 'UmSource', '', 'ImageSize', [], 'LocsFile', '', ...
                'LocsFingerprint', '', 'NextCellId', 1, 'Revision', 0, ...
                'KeptPairs', zeros(0, 2, 'uint32'), 'SweepDone', false, 'Complete', false, ...
                'LegacyImported', false, ...
                'AutoReject', curation.Store.normAutoReject([]), ...
                'JournalBytes', 0);
        end

        function r = emptyReport()
            r = struct('Ran', false, 'nOld', 0, 'nNew', 0, 'nExact', 0, 'nNear', 0, ...
                'nNearDet', 0, 'nNearHuman', 0, 'nMergedRows', 0, 'nReactivated', 0, ...
                'nAppended', 0, 'nVanishedGood', 0, 'nVanishedOther', 0, 'nStale', 0, ...
                'nPurged', 0, 'tolUm', NaN, 'umPerPixel', NaN, 'matchDistUm', zeros(0, 1), ...
                'maxMatchDistUm', 0, 'fingerprint', "", 'nNearKept', 0, ...
                'nearKeptIds', zeros(0, 2, 'uint32'), 'nDroppedNonFinite', 0, 'Refused', false, ...
                'refusal', "", 'warnings', strings(0, 1));
        end

        function L = emptyLockInfo()
            L = struct('Held', false, 'Host', "", 'User', "", 'Pid', NaN, 'Time', "", ...
                'Session', "", 'TakenOver', false, 'Message', "", 'Lost', false);
        end

        function t = newTxn(desc, action, ctx)
            if ~isstruct(ctx), ctx = struct(); end
            t = struct('Desc', string(desc), 'Action', string(action), ...
                'Entries', curation.ChangeSet.emptyEntries(), 'Ctx', ctx, 'NextCellId0', NaN);
        end

        function s = newSession()
            persistent count
            if isempty(count), count = 0; end
            count = count + 1;
            s = sprintf('%s-%d-%s-%d', curation.Store.hostName(), curation.Store.myPid(), ...
                char(datetime('now', 'Format', 'yyyyMMdd''T''HHmmss')), count);
        end

        function v = castCol(type, v)
            switch type
                case 'string'
                    v = string(v);
                case 'double'
                    v = double(v);
                case 'uint32'
                    v = uint32(v);
                case 'logical'
                    v = logical(v);
            end
            v = v(:);
        end

        function R = defaultRows(n)
            R = struct();
            cols = curation.Store.COLUMNS;
            types = curation.Store.TYPES;
            for k = 1:numel(cols)
                switch types(k)
                    case "uint32", R.(char(cols(k))) = zeros(n, 1, 'uint32');
                    case "double", R.(char(cols(k))) = nan(n, 1);
                    case "logical", R.(char(cols(k))) = false(n, 1);
                    otherwise, R.(char(cols(k))) = strings(n, 1);
                end
            end
            R.Origin(:) = "detected";
            R.State(:) = "active";
            R.PosSource(:) = "det";
        end

        function C = selectRows(C, keep)
            cols = curation.Store.COLS;
            for k = 1:numel(cols)
                C.(cols{k}) = C.(cols{k})(keep);
            end
        end

        function C = concatRows(C, R)
            cols = curation.Store.COLS;
            for k = 1:numel(cols)
                C.(cols{k}) = [C.(cols{k}); R.(cols{k})(:)];
            end
        end

        %% ------------------------------------------------------------- locs
        function [N, nDrop] = normalizeLocs(T)
            % Columns of a locs table; rows without a finite X and Y are dropped (they could
            % never be matched and would churn on every reconcile), NDROP says how many.
            if ~istable(T)
                error('curation:Store:badLocs', 'The locs must be a table.');
            end
            names = string(T.Properties.VariableNames);
            n = height(T);
            N = struct();
            for c = ["X", "Y", "class", "score", "rescore", "thr"]
                k = find(strcmpi(names, c), 1);
                if isempty(k)
                    if c == "X" || c == "Y"
                        error('curation:Store:badLocs', 'The locs table has no %s column.', c);
                    end
                    v = nan(n, 1);
                else
                    v = T.(char(names(k)));
                    if isnumeric(v) || islogical(v)
                        v = double(v);
                    else
                        v = str2double(string(v));
                    end
                end
                N.(char(c)) = v(:);
            end
            N.rescore(~isfinite(N.rescore)) = NaN;   % no score (RESCORE: "" always holds NaN)
            k = find(strcmpi(names, "imgName"), 1);
            if isempty(k)
                N.imgName = strings(n, 1);
            else
                N.imgName = curation.AtomicIO.cleanText(T.(char(names(k))));
                N.imgName = N.imgName(:);
            end
            ok = isfinite(N.X) & isfinite(N.Y);
            nDrop = nnz(~ok);
            if nDrop > 0
                for f = fieldnames(N)'
                    N.(f{1}) = N.(f{1})(ok);
                end
            end
        end

        function [R, nDrop] = rowsFromLocs(L, fp, firstId)
            [N, nDrop] = curation.Store.normalizeLocs(L);
            R = curation.Store.rowsFromNorm(N, (1:numel(N.X))', fp, firstId);
        end

        function s = dropWarning(n)
            s = sprintf(['%d detection(s) of the locs table have no finite X/Y position; they were ' ...
                'left out.'], n);
        end

        function p = twinPath(src)
            % The '*_locs_resized.csv' twin of the full-resolution locs ('' when unknown).
            p = '';
            if ~isempty(src.ResizedLocs) && isfile(src.ResizedLocs)
                p = char(src.ResizedLocs);
                return;
            end
            if isempty(src.LocsFile), return; end
            [f, nm] = fileparts(char(src.LocsFile));
            cand = fullfile(f, [nm '_resized.csv']);
            if isfile(cand), p = cand; end
        end

        function f = twinScale(src, L, Tw)
            % Resized coordinates = full coordinates * f: the manifest's detection resize factor,
            % else the median X ratio of the rows both files have (the detector's order).
            f = src.QcScale;
            if f > 0, return; end
            f = NaN;
            try
                n = min(height(L), height(Tw));
                xf = double(L.X(1:n));
                xr = Tw.X(1:n);
                if ~isnumeric(xr), xr = str2double(string(xr)); end
                xr = double(xr);
                ok = xf > 0 & isfinite(xr) & isfinite(xf);
                if nnz(ok) >= 1
                    f = median(xr(ok) ./ xf(ok));
                end
            catch
            end
        end

        function R = rowsFromNorm(N, idx, fp, firstId)
            n = numel(idx);
            R = curation.Store.defaultRows(n);
            R.CellID = uint32(firstId + (0:n - 1)');
            R.X = N.X(idx); R.Y = N.Y(idx);
            R.DET_X = N.X(idx); R.DET_Y = N.Y(idx);
            R.class = N.class(idx); R.score = N.score(idx); R.rescore = N.rescore(idx);
            R.RescoreSource(isfinite(R.rescore)) = "detector";   % else "": pending
            R.imgName = N.imgName(idx); R.thr = N.thr(idx);
            R.InLocs(:) = true;
            R.DetRun(:) = string(fp);
        end

        function [L, fp] = loadLocs(src)
            L = []; fp = '';
            if istable(src.LocsTable)
                L = src.LocsTable;
                if ~isempty(src.LocsFile) && isfile(src.LocsFile)
                    fp = curation.Reconciler.fingerprint(src.LocsFile, height(L));
                else
                    fp = curation.Reconciler.tableFingerprint(L);
                end
                return;
            end
            if isempty(src.LocsFile) || ~isfile(src.LocsFile), return; end
            L = curation.LegacyImport.readCsv(src.LocsFile, ...
                ["imgName", "NeighborPairID", "NeighborResolvedStatus"]);
            fp = curation.Reconciler.fingerprint(src.LocsFile, height(L));
        end

        function p = fullResLocs(p)
            p = char(p);
            if ~isempty(regexpi(p, '_resized\.csv$', 'once'))
                p = regexprep(p, '_resized\.csv$', '.csv', 'ignorecase');
            end
        end

        function stem = stemFromLocs(name)
            tok = '_locs';
            try tok = char(CellDatasetManifest.locsToken()); catch, end
            stem = regexprep(name, [regexptranslate('escape', tok) '(_resized)?$'], '', 'ignorecase');
            if strcmp(stem, name)
                stem = regexprep(name, '_locs(_resized)?$', '', 'ignorecase');
            end
        end

        function base = baseFromStem(stem)
            % '<base>_<channel><page>' -> '<base>' (CellDatasetManifest's rule), else the stem.
            t = regexp(char(stem), '^(?<base>.+)_(?<ch>[A-Za-z_]+?)(?<pg>\d+)$', 'names', 'once');
            if isempty(t)
                base = char(stem);
            else
                base = t.base;
            end
        end

        function locs = resolveLocs(mf, key)
            locs = '';
            cands = {};
            s = [];
            try s = mf.source(key); catch, end
            if isstruct(s) && isfield(s, 'locs') && ~isempty(s.locs)
                cands{end + 1} = curation.Store.absIn(mf.Folder, s.locs);
            end
            try
                if strcmpi(mf.coordSpace(key), 'resized')
                    cands{end + 1} = char(mf.locsPath(key, 'full'));
                end
            catch
            end
            try cands{end + 1} = char(mf.activeLocs(key)); catch, end
            tok = '_locs';
            try tok = char(CellDatasetManifest.locsToken()); catch, end
            cands{end + 1} = fullfile(mf.Folder, [char(mf.Base) '_' key tok '.csv']);
            cands{end + 1} = fullfile(mf.Folder, [char(mf.Base) '_proj_' key tok '.csv']);
            for k = 1:numel(cands)
                if isempty(cands{k}), continue; end
                c = curation.Store.fullResLocs(cands{k});
                if isfile(c)
                    locs = c;
                    return;
                end
            end
        end

        function p = absIn(folder, name)
            name = char(string(name));
            if ~isempty(regexp(name, '^([A-Za-z]:[\\/]|[\\/]{2}|/)', 'once'))
                p = name;
            else
                p = fullfile(char(folder), name);
            end
        end

        function [um, srcName, warn] = chooseScale(src, jsonUm, jsonSrc)
            % Manifest/meta value, else the stored value with the source it was first taken
            % from (so UmSource is stable across reopens), else TIFF calibration, else 0.645.
            % A stored "default" is re-checked against the TIFF first.
            if nargin < 3 || strlength(string(jsonSrc)) == 0, jsonSrc = "store"; end
            jsonSrc = string(jsonSrc);
            warn = strings(0, 1);
            um = src.UmPerPixel;
            srcName = src.UmSource;
            if ~(um > 0) && jsonUm > 0 && jsonSrc ~= "default"
                um = jsonUm; srcName = jsonSrc;
            end
            if ~(um > 0) && ~isempty(src.ImagePath)
                try
                    u = CellToolkit.tiffPixelSizeUm(src.ImagePath, src.Page);
                    if isfinite(u) && u > 0
                        um = u; srcName = "tiff";
                    end
                catch
                end
            end
            if ~(um > 0)
                um = curation.Store.DEFAULT_UM_PER_PIXEL;
                srcName = "default";
                warn(end + 1, 1) = sprintf(['The pixel size is unknown (no manifest record or TIFF ' ...
                    'calibration); using %.3f um/px.'], um);
            end
            if jsonUm > 0 && abs(jsonUm - um) > 1e-9
                warn(end + 1, 1) = sprintf('The pixel size changed from %.4g (stored) to %.4g um/px (%s).', ...
                    jsonUm, um, srcName);
            end
        end

        function sz = imageSizeOf(src)
            sz = [];
            if ~isempty(src.ImageSize)
                sz = reshape(double(src.ImageSize), 1, []);
                return;
            end
            if isempty(src.ImagePath) || ~isfile(src.ImagePath), return; end
            try
                info = imfinfo(src.ImagePath);
                pg = min(max(1, round(src.Page)), numel(info));
                sz = [double(info(pg).Height), double(info(pg).Width)];
            catch
            end
        end

        function f = qcScaleOf(src, L, um)
            % Resized-QC coordinates = full coordinates * f.
            f = src.QcScale;
            if f > 0, return; end
            if ~isempty(src.ResizedLocs) && isfile(src.ResizedLocs)
                try
                    R = readtable(src.ResizedLocs, 'TextType', 'string', 'VariableNamingRule', 'preserve');
                    if height(R) == height(L)
                        xr = double(R.X); xf = double(L.X);
                        ok = xf > 0 & isfinite(xr);
                        f = median(xr(ok) ./ xf(ok));
                    end
                catch
                end
            end
            if ~(f > 0)
                f = um / curation.Store.DEFAULT_UM_PER_PIXEL;
            end
        end

        function s = fileTimeIso(file)
            s = "";
            try
                d = dir(char(file));
                if ~isempty(d)
                    s = curation.AtomicIO.isoFromDatetime(datetime(d(1).datenum, 'ConvertFrom', 'datenum'));
                end
            catch
            end
        end

        %% ------------------------------------------------------------- snapshot
        function [C, warn, missing] = readSnapshot(path)
            % Rows of a snapshot CSV with the schema's types. MISSING: schema columns the file does
            % not have (filled with their defaults; e.g. RescoreSource in a snapshot written before
            % it existed, which open then fills by rule).
            warn = strings(0, 1);
            cols = curation.Store.COLUMNS;
            types = curation.Store.TYPES;
            hdr = '';
            D = [];
            have = cols;
            fid = fopen(path, 'r', 'n', 'UTF-8');
            if fid >= 0
                hdr = fgetl(fid);
                if ~ischar(hdr), hdr = ''; end
                hdr = strtrim(strrep(hdr, char(65279), ''));   % tolerate a BOM
                names = string(strsplit(hdr, ','));
                if ~isempty(hdr) && ~contains(hdr, '"') && all(ismember(names, cols)) ...
                        && numel(unique(names)) == numel(names)
                    % fast path: one textscan pass with the known column types (the current
                    % header, or one of known columns only, e.g. an older schema)
                    [~, kt] = ismember(names, cols);
                    ty = types(kt);
                    spec = repmat({'%q'}, 1, numel(ty));
                    spec(ty == "double" | ty == "logical") = {'%f'};
                    spec(ty == "uint32") = {'%u32'};
                    try
                        D = textscan(fid, [spec{:}], 'Delimiter', ',', 'Whitespace', '', ...
                            'EmptyValue', NaN, 'ReturnOnError', false);
                        n = numel(D{1});
                        if any(cellfun(@numel, D) ~= n), D = []; end
                    catch
                        D = [];
                    end
                    have = names;
                end
                fclose(fid);
            end
            if ~isempty(D)
                C = curation.Store.defaultRows(numel(D{1}));
                for k = 1:numel(have)
                    nm = char(have(k));
                    v = D{k};
                    switch curation.Store.TYPE_OF.(nm)
                        case 'logical'
                            v = v ~= 0 & ~isnan(v);
                        case 'string'
                            v = string(v);
                        case 'uint32'
                            v = uint32(v);
                    end
                    C.(nm) = reshape(v, [], 1);
                end
                missing = cols(~ismember(cols, have));
                other = missing(missing ~= "RescoreSource");
                if ~isempty(other)
                    warn(end + 1, 1) = "The snapshot lacks the column(s) " + strjoin(other, ", ") + ...
                        "; they were filled with their defaults.";
                end
                return;
            end
            if strcmp(hdr, char(join(cols, ",")))
                warn(end + 1, 1) = "The snapshot could not be read in one pass; it was read column by column.";
                T = readtable(path, 'TextType', 'string', 'VariableNamingRule', 'preserve', ...
                    'Delimiter', ',');
            else
                warn(end + 1, 1) = "The snapshot header differs from the current schema; columns were matched by name.";
                T = readtable(path, 'TextType', 'string', 'VariableNamingRule', 'preserve', ...
                    'Delimiter', ',');
            end
            n = height(T);
            C = struct();
            names = string(T.Properties.VariableNames);
            for k = 1:numel(cols)
                nm = char(cols(k));
                j = find(names == cols(k), 1);
                if isempty(j)
                    D = curation.Store.defaultRows(n);
                    C.(nm) = D.(nm);
                    continue;
                end
                C.(nm) = curation.Store.coerce(T.(char(names(j))), types(k), n);
            end
            missing = cols(~ismember(cols, names));
        end

        function [C, nStale, nChanged] = fillRescoreSource(C, upgrade)
            % RescoreSource in line with the rows (RESCORE; open step 6b). UPGRADE: a row without a
            % source whose finite rescore came from the locs it matches, at its detector position
            % (InLocs, X/Y within POS_TOL_PX of DET_X/Y), gets "detector". Then every value without
            % a source, and every "detector" value off its detector position, is stale: NaN, "".
            % NSTALE = finite values set to NaN, NCHANGED = rows changed. Rows written since
            % RescoreSource exists already hold to this, so it changes nothing on them; a model's
            % score cannot be checked here (moves drop it when they happen).
            tol = curation.Store.POS_TOL_PX;
            src = C.RescoreSource;
            fin = isfinite(C.rescore);
            onDet = hypot(C.X - C.DET_X, C.Y - C.DET_Y) <= tol;
            up = false(size(src));
            if upgrade
                up = src == "" & fin & C.InLocs & onDet;
                src(up) = "detector";
            end
            bad = (src == "detector" & ~(fin & onDet)) | (src == "" & ~isnan(C.rescore));
            nStale = nnz(bad & fin);
            nChanged = nnz(bad | up);
            if nChanged == 0, return; end
            C.rescore(bad) = NaN;
            src(bad) = "";
            C.RescoreSource = src;
        end

        function C1 = rescoreAfterRowChanges(C0, C1)
            % After the store itself changed rows C0 -> C1 (legacy import): a row moved more than
            % POS_TOL_PX loses its score unless it is a "detector" value still on its detector
            % position; a "detector" value off its detector position (e.g. DET_X/Y dropped for a
            % merge result or an added row) is stale. Both become pending (NaN, "").
            tol = curation.Store.POS_TOL_PX;
            [tf, loc] = ismember(double(C1.CellID), double(C0.CellID));
            moved = false(numel(C1.CellID), 1);
            i1 = find(tf); i0 = loc(tf);
            moved(i1) = hypot(C1.X(i1) - C0.X(i0), C1.Y(i1) - C0.Y(i0)) > tol;
            onDet = hypot(C1.X - C1.DET_X, C1.Y - C1.DET_Y) <= tol;
            isDet = C1.RescoreSource == "detector";
            drop = (moved & ~(isDet & onDet)) | (isDet & ~onDet);
            C1.rescore(drop) = NaN;
            C1.RescoreSource(drop) = "";
        end

        function v = coerce(v, type, n)
            switch type
                case "uint32"
                    if ~isnumeric(v), v = str2double(string(v)); end
                    v = double(v); v(isnan(v)) = 0; v = uint32(v);
                case "double"
                    if ~isnumeric(v) && ~islogical(v), v = str2double(string(v)); end
                    v = double(v);
                case "logical"
                    if islogical(v)
                        % keep
                    elseif isnumeric(v)
                        v = v ~= 0 & ~isnan(v);
                    else
                        s = lower(strtrim(string(v)));
                        v = s == "1" | s == "true";
                    end
                otherwise
                    if isnumeric(v) && all(isnan(v(:)))
                        v = strings(n, 1);
                    else
                        v = string(v);
                        v(ismissing(v)) = "";
                    end
            end
            v = reshape(v, [], 1);
            if numel(v) ~= n
                v = v(1:min(end, n));
            end
        end
    end

    %% ======================================================================== persistence
    methods (Access = private)

        function openBody(obj, src, opts)
            % The open sequence (see OPEN SEQUENCE in the class help).
            warn = strings(0, 1);
            % ---- lock first: nothing is cleaned, archived or written without it --------------
            if obj.Persist
                obj.Paths = curation.Store.pathsFor(src.Folder, src.Stem, src.ManifestBase);
                if ~isempty(src.JsonFolder) && ~strcmpi(src.JsonFolder, src.Folder)
                    [~, jn, je] = fileparts(obj.Paths.json);
                    obj.Paths.json = fullfile(src.JsonFolder, [jn je]);
                end
                if opts.ReadOnly
                    obj.ReadOnly = true;
                else
                    warn = [warn; obj.acquireLock(opts.Force)];
                end
                if opts.Rebuild && obj.ReadOnly
                    msg = char(obj.LockInfo.Message);
                    if isempty(msg), msg = 'the store was opened read-only'; end
                    error('curation:Store:readOnly', 'Rebuild needs this source''s lock: %s', msg);
                end
                if ~obj.ReadOnly
                    % only the lock holder removes temporaries: another's may be a live write
                    [~, nm, ex] = fileparts(obj.Paths.csv);
                    curation.AtomicIO.cleanTemps(src.Folder, [nm ex]);
                    if opts.Rebuild
                        warn = [warn; obj.archiveForRebuild()];
                    end
                    obj.JournalObj = curation.Journal(obj.Paths.journal, obj.Session);
                end
            end

            % ---- JSON record and regions (an unreadable JSON: read-only, never rebuilt) -------
            rec = []; J = [];
            if obj.Persist
                try
                    J = curation.AtomicIO.readJsonStrict(obj.Paths.json);
                catch ME
                    if ~strcmp(ME.identifier, 'curation:AtomicIO:jsonUnreadable'), rethrow(ME); end
                    reason = "Opened read-only: " + string(ME.message);
                    warn(end + 1, 1) = reason;
                    obj.becomeReadOnly(reason);
                    J = [];
                end
                rec = curation.Store.sourceRecord(J, src.Key);
            end
            jsonUm = NaN; jsonUmSrc = "";
            if isstruct(rec)
                obj.applyRecord(rec);
                jsonUm = obj.Meta.UmPerPixel;
                jsonUmSrc = string(obj.Meta.UmSource);
            end
            if obj.Persist && isstruct(J) && isscalar(J) && isfield(J, 'regions')
                try
                    obj.RegionCache = curation.Store.normRegions(J.regions);
                catch ME
                    warn(end + 1, 1) = "The regions in the JSON could not be read: " + ME.message;
                end
            end

            % ---- the snapshot, or rows from the locs -----------------------------------------
            created = false; loaded = false; rebuilt = false;
            L = []; fp = ''; base = 0; fromByte = 0;
            noRescoreSource = false;
            if obj.Persist && isfile(obj.Paths.csv)
                [obj.C, w, missing] = curation.Store.readSnapshot(obj.Paths.csv);
                noRescoreSource = any(missing == "RescoreSource");
                warn = [warn; w];
                [base, fromByte, w, reason] = obj.snapshotBase(rec);
                warn = [warn; w];
                if strlength(reason) > 0
                    warn(end + 1, 1) = reason;
                    obj.becomeReadOnly(reason);
                end
                obj.Meta.Revision = base;
                obj.Meta.NextCellId = max([obj.Meta.NextCellId; double(obj.C.CellID) + 1]);
                obj.rebuildIndex();
                loaded = true;
            else
                [L, fp] = curation.Store.loadLocs(src);
                if ~istable(L)
                    error('curation:Store:noLocs', 'No locs file found for source %s (%s).', ...
                        src.Key, src.LocsFile);
                end
                [obj.C, nDrop] = curation.Store.rowsFromLocs(L, fp, 1);
                if nDrop > 0, warn(end + 1, 1) = curation.Store.dropWarning(nDrop); end
                if obj.Persist && obj.hasHistory(rec)
                    obj.checkRebuildFromLocs(rec, fp, src);   % else curation:Store:snapshotMissing
                    rebuilt = true;
                    warn(end + 1, 1) = sprintf(['The snapshot %s was missing; its rows were rebuilt ' ...
                        'from %s (the locs file the curation was made on; no reconcile or import ' ...
                        'since) and the whole journal was replayed.'], obj.Paths.csv, src.LocsFile);
                else
                    created = true;
                end
                obj.Meta.NextCellId = max(obj.Meta.NextCellId, numel(obj.C.CellID) + 1);
                obj.Meta.Revision = 0;
                obj.Meta.JournalBytes = 0;
                obj.Meta.LocsFingerprint = fp;
                obj.rebuildIndex();
            end
            obj.SavedRevision = obj.Meta.Revision;
            if rebuilt, obj.SavedRevision = -1; end
            replayed = 0;
            if obj.Persist && ~created
                [replayed, w, bad] = obj.replayJournal(fromByte, base);
                warn = [warn; w];
                if strlength(bad) > 0
                    warn(end + 1, 1) = bad;
                    obj.becomeReadOnly(bad);
                end
            end

            % ---- RescoreSource in line with the rows (a snapshot written before it existed) ----
            if loaded || rebuilt
                [obj.C, nStale, nChanged] = curation.Store.fillRescoreSource(obj.C, true);
                if nChanged > 0 || noRescoreSource
                    obj.TCache = [];
                    obj.SnapAtOpen = true;   % write the upgraded snapshot (when writable)
                end
                if nStale > 0 && noRescoreSource
                    warn(end + 1, 1) = sprintf(['The snapshot %s was written before the RescoreSource ' ...
                        'column existed. It was filled from the rows ("detector" where a row matches the ' ...
                        'locs at its detector position, pending otherwise); %d stale rescore value(s) of ' ...
                        'moved, added or unmatched cells were set to NaN (pending).'], obj.Paths.csv, nStale);
                elseif nStale > 0
                    warn(end + 1, 1) = sprintf(['%d rescore value(s) did not belong to their cell''s ' ...
                        'position (a journal written before the RescoreSource column existed?) and ' ...
                        'were set to NaN (pending).'], nStale);
                end
            end

            % ---- scale and image size ----------------------------------------------------------
            [um, umSrc, w] = curation.Store.chooseScale(src, jsonUm, jsonUmSrc);
            warn = [warn; w];
            obj.Meta.UmPerPixel = um;
            obj.Meta.UmSource = char(umSrc);
            if isempty(obj.Meta.ImageSize)
                obj.Meta.ImageSize = curation.Store.imageSizeOf(src);
            end

            % ---- locs changed? -------------------------------------------------------------------
            reconciled = false;
            if loaded || rebuilt
                need = false;
                if istable(src.LocsTable)
                    [L, fp] = curation.Store.loadLocs(src);
                    need = ~curation.Reconciler.equivalent(obj.Meta.LocsFingerprint, fp);
                elseif ~isempty(src.LocsFile) && isfile(src.LocsFile)
                    if ~curation.Reconciler.sameStamp(obj.Meta.LocsFingerprint, src.LocsFile)
                        [L, fp] = curation.Store.loadLocs(src);
                        need = ~curation.Reconciler.equivalent(obj.Meta.LocsFingerprint, fp);
                    end
                else
                    warn(end + 1, 1) = "The detector locs file is missing; showing the stored curation without reconciling.";
                end
                if need
                    if obj.ReadOnly
                        warn(end + 1, 1) = "The locs file changed; reconcile is pending until the store is opened writable.";
                    else
                        ropts = struct('AllowEmpty', opts.AllowEmpty, 'Force', opts.ForceReconcile);
                        try
                            obj.reconcileImpl(L, fp, opts.TolUm, true, ropts);
                            reconciled = true;
                        catch ME
                            if ~any(strcmp(ME.identifier, {'curation:Store:emptyLocs', ...
                                    'curation:Store:reconcileMismatch'}))
                                rethrow(ME);
                            end
                            reason = "Opened read-only: " + string(ME.message);
                            warn(end + 1, 1) = reason;
                            obj.becomeReadOnly(reason);
                        end
                    end
                end
            end

            % ---- legacy import ---------------------------------------------------------------------
            imported = obj.maybeImport(src, opts, L, um, created);
            if imported
                warn = [warn; obj.LastImport.warnings];
            end

            % ---- Excluded follows the regions (the other channel may have changed them) -------
            obj.resyncExcluded("Apply the exclusion regions", ~created);

            % ---- write what changed ----------------------------------------------------------------
            obj.Ready = true;
            if obj.Persist && ~obj.ReadOnly
                if created
                    % nothing is journaled before the first snapshot exists: a failure fails the open
                    obj.writeSnapshot();
                    obj.JournalObj.event("create", obj.Meta.Revision, obj.Reviewer, ...
                        jsonencode(struct('locsFingerprint', obj.Meta.LocsFingerprint, ...
                        'rows', numel(obj.C.CellID))));
                    if imported
                        obj.JournalObj.event("legacy-import", obj.Meta.Revision, obj.Reviewer, ...
                            curation.Store.importSummary(obj.LastImport));
                    end
                elseif replayed > 0 || imported || reconciled || rebuilt || obj.SnapAtOpen ...
                        || obj.Dirty || ~isfile(obj.Paths.json)
                    try
                        obj.writeSnapshot();
                    catch ME
                        if strcmp(ME.identifier, 'curation:Store:lockLost'), rethrow(ME); end
                        obj.LastError = string(ME.message);
                        warn(end + 1, 1) = sprintf(['The snapshot %s could not be written (%s); the ' ...
                            'journal %s holds every change, so nothing is lost.'], obj.Paths.csv, ...
                            ME.message, obj.Paths.journal);
                    end
                end
                if ~isempty(obj.JournalObj)
                    obj.JournalObj.event("open", obj.Meta.Revision, obj.Reviewer, "");
                end
            end
            obj.LastReconcile.warnings = [obj.LastReconcile.warnings; warn];
        end

        function writeSnapshot(obj)
            % The snapshot CSV (and a "snapshot" journal event naming its fingerprint), then the
            % JSON record. A JSON failure (curation:AtomicIO:jsonUnreadable / jsonBusy) is thrown
            % after the CSV and the journal are written; the record is written at the next flush.
            obj.writeSnapshotCsv();
            obj.writeSnapshotJson();
        end

        function writeSnapshotCsv(obj)
            if ~obj.ownsLockNow(true), obj.loseLock(); end
            txt = curation.Store.snapshotText(obj.C);
            curation.AtomicIO.writeText(obj.Paths.csv, txt);
            obj.SnapFp = curation.Store.snapshotFp(txt, curation.Journal.fileLength(obj.Paths.csv));
            if ~isempty(obj.JournalObj)
                b0 = obj.JournalObj.Bytes;
                obj.JournalObj.event("snapshot", obj.Meta.Revision, obj.Reviewer, ...
                    jsonencode(struct('csv', obj.SnapFp, 'journalBytes', b0)));
                obj.Meta.JournalBytes = obj.JournalObj.Bytes;
            else
                obj.Meta.JournalBytes = curation.Journal.fileLength(obj.Paths.journal);
            end
            obj.SavedRevision = obj.Meta.Revision;
            obj.DerivedDirty = false;
            obj.PendingSinceTic = [];
            obj.JsonStale = true;
            obj.SnapAtOpen = false;
        end

        function writeSnapshotJson(obj)
            try
                curation.AtomicIO.updateJson(obj.Paths.json, @(J) obj.mergeJson(J));
            catch ME
                obj.LastError = string(ME.message);
                rethrow(ME);
            end
            obj.JsonStale = false;
        end

        function J = mergeJson(obj, J)
            if ~isstruct(J) || ~isscalar(J), J = struct(); end
            J = curation.Store.canonJson(J);
            key = obj.Meta.Key;
            rec = struct();
            if isfield(J.sources, key) && isstruct(J.sources.(key)) && isscalar(J.sources.(key))
                rec = J.sources.(key);
            end
            M = obj.Meta;
            rec.stem = M.Stem;
            rec.locsFile = curation.Store.relTo(M.LocsFile, M.Folder);
            rec.locsFingerprint = M.LocsFingerprint;
            rec.umPerPixel = M.UmPerPixel;
            rec.umSource = M.UmSource;
            rec.imageSize = M.ImageSize;
            rec.nextCellId = M.NextCellId;
            rec.revision = obj.SavedRevision;
            rec.legacyImported = M.LegacyImported;
            rec.keptPairs = num2cell(double(M.KeptPairs), 2);
            rec.sweepDone = M.SweepDone;
            rec.complete = M.Complete;
            rec.counts = obj.counts();
            rec.autoReject = M.AutoReject;
            rec.journalBytes = M.JournalBytes;
            rec.csvFingerprint = obj.SnapFp;
            rec.updated = curation.AtomicIO.isoNow(false);
            J.sources.(key) = rec;
        end

        function applyRecord(obj, rec)
            M = obj.Meta;
            g = @(name, d) curation.Store.metaField(rec, name, d);
            M.NextCellId = double(g('nextCellId', 1));
            M.Revision = double(g('revision', 0));
            M.LocsFingerprint = char(string(g('locsFingerprint', '')));
            M.UmPerPixel = double(g('umPerPixel', NaN));
            sz = g('imageSize', []);
            M.ImageSize = reshape(double(sz), 1, []);
            M.LegacyImported = logical(g('legacyImported', false));
            M.KeptPairs = curation.Store.normPairs(g('keptPairs', []));
            M.SweepDone = logical(g('sweepDone', false));
            M.Complete = logical(g('complete', false));
            try
                M.AutoReject = curation.Store.normAutoReject(g('autoReject', []));
            catch
                M.AutoReject = curation.Store.normAutoReject([]);
            end
            M.UmSource = char(string(g('umSource', '')));
            M.JournalBytes = double(g('journalBytes', 0));
            if isempty(M.Stem)
                M.Stem = char(string(g('stem', '')));
            end
            obj.Meta = M;
        end

        function [base, fromByte, warn, reason] = snapshotBase(obj, rec)
            % Which revision the snapshot CSV holds, and where in the journal to replay from.
            % Trusted when it is the CSV the JSON record describes (csvFingerprint; records
            % written before that field existed are trusted as before). Otherwise the journal's
            % "snapshot" events identify it (a restored older copy: replayed forward from its
            % revision); when nothing identifies it, REASON says why the store must stay
            % read-only.
            warn = strings(0, 1);
            reason = "";
            base = obj.Meta.Revision;
            fromByte = obj.Meta.JournalBytes;
            fp = curation.Store.snapshotFpOfFile(obj.Paths.csv);
            obj.SnapFp = fp;
            recFp = '';
            if isstruct(rec) && isfield(rec, 'csvFingerprint') && ~isempty(rec.csvFingerprint)
                recFp = char(string(rec.csvFingerprint));
            end
            if isstruct(rec) && (isempty(recFp) || strcmp(recFp, fp))
                return;
            end
            [hit, rev, bytes] = obj.findSnapshotEvent(fp);
            if hit
                base = rev;
                fromByte = bytes;
                if isstruct(rec)
                    warn(end + 1, 1) = sprintf(['%s is not the snapshot %s describes (revision %d) ' ...
                        'but an earlier one (revision %d; restored from a backup?). The journal was ' ...
                        'replayed forward from it.'], obj.Paths.csv, obj.Paths.json, ...
                        round(double(curation.Store.metaField(rec, 'revision', NaN))), round(rev));
                else
                    warn(end + 1, 1) = sprintf(['The record of this source is missing from %s; %s ' ...
                        'was identified in the journal as revision %d and the journal was replayed ' ...
                        'from there.'], obj.Paths.json, obj.Paths.csv, round(rev));
                    obj.recoverMetaFromJournal(rev);
                end
                return;
            end
            if ~isstruct(rec) && ~obj.journalHasTransactions()
                base = 0;
                fromByte = 0;
                return;
            end
            reason = sprintf(['Opened read-only: the snapshot %s matches neither the record in %s ' ...
                'nor any snapshot recorded in the journal %s, so it cannot be told which changes it ' ...
                'holds. Nothing is written. Restore the matching files from a backup, or open with ' ...
                'Rebuild=true to start over (the old files are kept).'], obj.Paths.csv, ...
                obj.Paths.json, obj.Paths.journal);
        end

        function [hit, rev, bytes] = findSnapshotEvent(obj, fp)
            hit = false; rev = 0; bytes = 0;
            R = curation.Journal.read(obj.Paths.journal, 0);
            k = find(R.Action == "snapshot" & R.Field == "");
            for i = numel(k):-1:1
                try
                    s = jsondecode(char(R.New(k(i))));
                catch
                    continue;
                end
                if isstruct(s) && isfield(s, 'csv') && strcmp(char(string(s.csv)), fp)
                    hit = true;
                    rev = R.RevisionNum(k(i));
                    bytes = double(curation.Store.metaField(s, 'journalBytes', 0));
                    return;
                end
            end
        end

        function tf = journalHasTransactions(obj)
            R = curation.Journal.read(obj.Paths.journal, 0);
            tf = any(strlength(R.Field) > 0);
        end

        function recoverMetaFromJournal(obj, upToRev)
            % Without a JSON record: the meta values the journal recorded up to revision UPTOREV.
            R = curation.Journal.read(obj.Paths.journal, 0);
            G = curation.Journal.transactions(R);
            [~, o] = sortrows([G.Revision, G.FirstLine]);
            for g = o'
                if ~G.Committed(g) || G.Revision(g) > upToRev, continue; end
                for i = G.DataLines{g}'
                    f = R.Field(i);
                    if startsWith(f, "meta.")
                        obj.applyMetaLine(char(extractAfter(f, "meta.")), R.New(i));
                    end
                end
            end
            ev = R.Action(R.Field == "");
            if any(ev == "legacy-import")
                obj.Meta.LegacyImported = true;
            end
            if isempty(obj.Meta.LocsFingerprint)
                k = find(R.Action == "create" & R.Field == "", 1, 'last');
                if ~isempty(k)
                    try
                        s = jsondecode(char(R.New(k)));
                        obj.Meta.LocsFingerprint = char(string(s.locsFingerprint));
                    catch
                    end
                end
            end
        end

        function applyMetaLine(obj, name, txt)
            switch name
                case {'KeptPairs', 'SweepDone', 'Complete', 'AutoReject', 'LegacyImported', 'LocsFingerprint'}
                    obj.Meta.(name) = curation.Store.decodeMeta(name, txt);
                case 'NextCellId'
                    obj.Meta.NextCellId = max(obj.Meta.NextCellId, curation.Store.decodeMeta(name, txt));
            end
        end

        function tf = hasHistory(obj, rec)
            % A JSON record or any journal line: the source has been curated before.
            tf = isstruct(rec) || curation.Journal.fileLength(obj.Paths.journal) > ...
                numel(curation.Journal.HEADER) + 2;
        end

        function checkRebuildFromLocs(obj, rec, fp, src)
            % Finding 1: rows may be rebuilt from the locs (CellID 1..n in file order) only when
            % they are the rows the curation was made on: the same locs file, and no reconcile or
            % legacy import since (both re-number nothing but no longer follow the file order).
            R = curation.Journal.read(obj.Paths.journal, 0);
            structural = any(ismember(R.Action, ["reconcile", "legacy-import"]));
            fpRec = '';
            if isstruct(rec) && isfield(rec, 'locsFingerprint')
                fpRec = char(string(rec.locsFingerprint));
            end
            if isempty(fpRec)
                k = find(R.Action == "create" & R.Field == "", 1, 'last');
                if ~isempty(k)
                    try
                        s = jsondecode(char(R.New(k)));
                        fpRec = char(string(s.locsFingerprint));
                    catch
                    end
                end
            end
            same = ~isempty(fpRec) && curation.Reconciler.equivalent(fpRec, fp);
            if same && ~structural
                return;
            end
            if structural
                why = ['the journal records a reconcile or a legacy import, after which CellIDs no ' ...
                    'longer follow the row order of the locs file'];
            elseif isempty(fpRec)
                why = 'no record says which locs file the curation was made on';
            else
                why = 'the locs file changed since the curation was made on it';
            end
            error('curation:Store:snapshotMissing', ['The curation snapshot %s is missing, but %s and ' ...
                '%s hold curation work on source %s. Its rows cannot be rebuilt safely from %s (%s), ' ...
                'so decisions could land on the wrong cells. Restore %s from a backup; or open with ' ...
                'Rebuild=true to archive the journal and the JSON record under timestamped names and ' ...
                'start a new, empty store (nothing is deleted).'], obj.Paths.csv, obj.Paths.json, ...
                obj.Paths.journal, src.Key, src.LocsFile, why, obj.Paths.csv);
        end

        function warn = archiveForRebuild(obj)
            % Rebuild=true: move this source's snapshot and journal, and copy its JSON record, to
            % timestamped names (then drop the record from the shared JSON); never deletes.
            warn = strings(0, 1);
            ts = char(datetime('now', 'Format', 'yyyyMMdd''T''HHmmss'));
            folder = fileparts(obj.Paths.csv);
            stem = obj.Meta.Stem;
            moved = strings(0, 1);
            J = curation.AtomicIO.readJsonStrict(obj.Paths.json);   % unreadable: nothing is moved
            pairs = {obj.Paths.csv, fullfile(folder, [stem '_curation.archived-' ts '.csv']); ...
                obj.Paths.journal, fullfile(folder, [stem '_curation.journal.archived-' ts '.csv'])};
            for k = 1:size(pairs, 1)
                if ~isfile(pairs{k, 1}), continue; end
                [ok, msg] = movefile(pairs{k, 1}, pairs{k, 2});
                if ~ok
                    error('curation:AtomicIO:writeFailed', 'Rebuild: could not archive %s: %s', pairs{k, 1}, msg);
                end
                moved(end + 1, 1) = string(pairs{k, 2}); %#ok<AGROW>
            end
            rec = curation.Store.sourceRecord(J, obj.Meta.Key);
            if isstruct(rec)
                rp = fullfile(folder, [stem '_curation.record.archived-' ts '.json']);
                curation.AtomicIO.writeJson(rp, rec);
                key = obj.Meta.Key;
                curation.AtomicIO.updateJson(obj.Paths.json, @(J) curation.Store.removeSource(J, key));
                moved(end + 1, 1) = string(rp);
            end
            if ~isempty(moved)
                warn(end + 1, 1) = "Rebuild: the previous curation of this source was archived as " + ...
                    strjoin(moved, ", ") + "; a new store starts from the locs file.";
            end
        end

        function imported = maybeImport(obj, src, opts, L, um, created)
            % Finding 4: the legacy import runs on a store just created from the locs (never on
            % one loaded from a snapshot or with journal history), or when ImportLegacy="force";
            % a forced import skips every row a person decided (curation.LegacyImport Protected).
            imported = false;
            force = opts.ImportForce && ~obj.ReadOnly;
            if ~(force || (opts.ImportLegacy && created && ~obj.Meta.LegacyImported))
                return;
            end
            if ~istable(L), [L, ~] = curation.Store.loadLocs(src); end
            if ~istable(L), return; end
            [Li, lopts, w, extra] = obj.legacyInputs(src, L, um);
            Q = curation.LegacyImport.readQc(src.QcPath);
            C0 = obj.C;
            M0 = obj.Meta;
            Cx = C0;
            if ~isempty(extra)
                % rows the resolver appended in the resized file: new rows, scaled to full size
                [N, ~] = curation.Store.normalizeLocs(Li(extra, :));
                R = curation.Store.rowsFromNorm(N, (1:numel(N.X))', obj.Meta.LocsFingerprint, obj.Meta.NextCellId);
                Cx = curation.Store.concatRows(Cx, R);
                obj.Meta.NextCellId = obj.Meta.NextCellId + numel(R.CellID);
            end
            prot = false(numel(Cx.CellID), 1);
            if force
                touched = obj.personMergeIds();
                prot = ismember(Cx.LabelSource, ["human", "confirmed", "blind"]) ...
                    | ismember(Cx.PosSource, ["human", "snap"]) | ismember(double(Cx.CellID), touched);
            end
            lopts.Protected = prot;
            [C2, irep] = curation.LegacyImport.apply(Cx, Li, Q, lopts);
            irep.qc.path = string(src.QcPath);
            irep.warnings = [w; irep.warnings];
            C2.Excluded = obj.excludedFor(C2.X, C2.Y);
            C2 = curation.Store.rescoreAfterRowChanges(Cx, C2);   % moved / merge results: pending
            obj.C = C2;
            obj.rebuildIndex();
            kp = obj.Meta.KeptPairs;
            if ~isempty(irep.keptPairs)
                kp = unique([kp; irep.keptPairs], 'rows');
            end
            E = curation.Store.diffEntries(C0, C2);
            if ~isequal(kp, M0.KeptPairs)
                E(end + 1, 1) = curation.ChangeSet.entry('meta', 'KeptPairs', [], M0.KeptPairs, kp);
            end
            if ~M0.LegacyImported
                E(end + 1, 1) = curation.ChangeSet.entry('meta', 'LegacyImported', [], false, true);
            end
            if obj.Meta.NextCellId > M0.NextCellId
                E(end + 1, 1) = curation.ChangeSet.entry('meta', 'NextCellId', [], M0.NextCellId, obj.Meta.NextCellId);
            end
            obj.Meta.KeptPairs = kp;
            obj.Meta.LegacyImported = true;
            obj.LastImport = irep;
            % an import that changed nothing (no legacy files) leaves no trace in the journal, so
            % it never blocks rebuilding a lost snapshot (finding 1)
            imported = any(~strcmp({E.Kind}, 'meta') | ~strcmp({E.Field}, 'LegacyImported'));
            journal = imported && ~created && obj.Persist && ~obj.ReadOnly;
            obj.sysCommit("Legacy import", "legacy-import", E, journal);
            if journal
                obj.JournalObj.event("legacy-import", obj.Meta.Revision, obj.Reviewer, ...
                    curation.Store.importSummary(irep));
            end
        end

        function [Li, lopts, warn, extra] = legacyInputs(obj, src, L, um)
            % The table the resolver rules read, and the evidence of how many rows the detector
            % wrote (finding 7): the resized twin's row count when it is pristine, else the
            % manifest's detection count (only when it is below the file's row count). Resolver
            % work saved to the resized twin (finding 8) is read from there, scaled to full size;
            % EXTRA = its rows that are not in the full-resolution locs.
            warn = strings(0, 1);
            extra = zeros(0, 1);
            Li = L;
            lopts = struct('TolPx', obj.Options.TolUm / um, 'OrphanMergePx', obj.Options.OrphanMergePx, ...
                'QcScale', 1, 'LocsTime', curation.Store.fileTimeIso(src.LocsFile), ...
                'NOrig', NaN, 'NOrigSource', "");
            if src.QcResized
                lopts.QcScale = curation.Store.qcScaleOf(src, L, um);
            end
            hasCur = any(strcmpi(L.Properties.VariableNames, 'CURATED_X'));
            twin = curation.Store.twinPath(src);
            Tw = [];
            if ~isempty(twin) && isfile(twin)
                try
                    Tw = curation.LegacyImport.readCsv(twin, ["imgName", "NeighborPairID", "NeighborResolvedStatus"]);
                catch
                    Tw = [];
                end
            end
            twinCur = istable(Tw) && any(strcmpi(Tw.Properties.VariableNames, 'CURATED_X'));
            if hasCur && istable(Tw) && ~twinCur && height(Tw) <= height(L)
                lopts.NOrig = height(Tw);
                lopts.NOrigSource = "resized";
            elseif ~hasCur && twinCur
                f = curation.Store.twinScale(src, L, Tw);
                if f > 0
                    Li = Tw;
                    for c = ["X", "Y", "CURATED_X", "CURATED_Y"]
                        k = find(strcmpi(Li.Properties.VariableNames, c), 1);
                        if isempty(k), continue; end
                        v = Li.(Li.Properties.VariableNames{k});
                        if ~isnumeric(v), v = str2double(string(v)); end
                        Li.(Li.Properties.VariableNames{k}) = double(v) / f;
                    end
                    lopts.NOrig = height(L);
                    lopts.NOrigSource = "full-resolution locs";
                    lopts.FromResized = true;
                    extra = (height(L) + 1:height(Li))';
                    warn(end + 1, 1) = sprintf(['The resolver''s work was saved to %s (resized mode); it ' ...
                        'was imported from there, coordinates divided by %.4g.'], twin, f);
                else
                    warn(end + 1, 1) = sprintf(['%s holds resolver work but its scale to %s could not ' ...
                        'be established; it was not imported.'], twin, src.LocsFile);
                end
            end
            if ~isfinite(lopts.NOrig) && isfinite(src.DetectionCount) && src.DetectionCount > 0 ...
                    && src.DetectionCount < height(L)
                lopts.NOrig = src.DetectionCount;
                lopts.NOrigSource = "manifest";
            end
        end

        function ids = personMergeIds(obj)
            % CellIDs a person merged or unmerged (State/MergedInto lines of a person's
            % transaction, and the keepers they name), from the whole journal.
            ids = zeros(0, 1);
            if ~obj.Persist, return; end
            R = curation.Journal.read(obj.Paths.journal, 0);
            sys = ismember(R.Action, ["reconcile", "legacy-import", "regions"]);
            m = (R.Field == "State" | R.Field == "MergedInto") & ~sys;
            ids = str2double(R.CellID(m));
            k = R.Field == "MergedInto" & ~sys;
            ids = unique([ids; str2double(R.New(k)); str2double(R.Old(k))]);
            ids = ids(isfinite(ids) & ids > 0);
        end

        function [n, warn, bad] = replayJournal(obj, fromByte, base)
            % Apply the committed journal transactions newer than revision BASE, in revision
            % order. A torn tail (no #commit, or fewer lines than it declares; or the last
            % transaction of a journal without markers) is skipped and reported, and the open
            % then writes a snapshot so it is never considered again. A committed transaction
            % that does not fit the rows (a CellID that is not there) stops the replay: BAD says
            % why and the store opens read-only, writing nothing (journalBytes never moves past
            % a committed transaction that was not applied). NextCellId ends at least one past
            % every id the snapshot or any "+row" / meta.NextCellId line ever held.
            n = 0; warn = strings(0, 1); bad = "";
            R = curation.Journal.read(obj.Paths.journal, fromByte);
            if isempty(R.Field), return; end
            maxId = 0;
            isAdd = R.Field == "+row";
            if any(isAdd), maxId = max([0; str2double(R.CellID(isAdd))]); end
            isNext = R.Field == "meta.NextCellId";
            if any(isNext)
                v = arrayfun(@(t) curation.Store.decodeMeta('NextCellId', t), R.New(isNext));
                maxId = max([maxId; v(:) - 1]);
            end
            G = curation.Journal.transactions(R);
            if isempty(G.Revision), return; end
            torn = ~G.Committed & G.Revision > base;
            if any(torn)
                a = unique(G.Action(torn));
                warn(end + 1, 1) = sprintf(['%d incomplete change(s) at the end of the journal %s ' ...
                    '(written while MATLAB stopped) were not replayed: %s.'], nnz(torn), ...
                    obj.Paths.journal, strjoin(a, ", "));
                obj.SnapAtOpen = true;
            end
            sel = find(G.Committed & G.Revision > base);
            if ~isempty(sel)
                [~, o] = sortrows([G.Revision(sel), G.FirstLine(sel)]);
                sel = sel(o);
            end
            for g = sel'
                lines = G.DataLines{g};
                why = obj.applyTxnLines(R, lines);
                if strlength(why) > 0
                    bad = sprintf(['Opened read-only: the journal %s holds a change (revision %d, %s) ' ...
                        'that does not fit the snapshot %s (%s). Nothing is written, so nothing is ' ...
                        'lost. Restore the files from a backup, or open with Rebuild=true to start ' ...
                        'over (the old files are kept).'], obj.Paths.journal, round(G.Revision(g)), ...
                        G.Action(g), obj.Paths.csv, why);
                    break;
                end
                n = n + numel(lines);
                obj.Meta.Revision = max(obj.Meta.Revision, G.Revision(g));
            end
            ids = double(obj.C.CellID);
            obj.Meta.NextCellId = max([obj.Meta.NextCellId; maxId + 1; max([0; ids]) + 1]);
            obj.TCache = [];
        end

        function why = applyTxnLines(obj, R, lines)
            % Apply one committed transaction's data lines, all or nothing.
            why = "";
            if isempty(lines), return; end
            fld = R.Field(lines);
            ids = str2double(R.CellID(lines));
            added = ids(fld == "+row");
            needs = fld == "-row" | arrayfun(@(f) isfield(curation.Store.TYPE_OF, char(f)), fld);
            have = false(numel(ids), 1);
            ok = ids >= 1 & ids <= numel(obj.RowOfId) & ids == fix(ids);
            have(ok) = obj.RowOfId(ids(ok)) > 0;
            have = have | ismember(ids, added);
            miss = find(needs & ~have, 1);
            if ~isempty(miss)
                why = sprintf('CellID %g is not in the store', ids(miss));
                return;
            end
            brk = [true; fld(2:end) ~= fld(1:end - 1)];
            starts = find(brk);
            ends = [starts(2:end) - 1; numel(lines)];
            for k = 1:numel(starts)
                ii = lines(starts(k):ends(k));
                f = fld(starts(k));
                if f == "+row"
                    for i = ii'
                        row = curation.Store.rowFromJson(R.New(i));
                        if isempty(row), continue; end
                        id = double(row.CellID);
                        if id <= numel(obj.RowOfId) && obj.RowOfId(id) > 0, continue; end
                        obj.appendRows(row);
                    end
                elseif f == "-row"
                    obj.removeIds(str2double(R.CellID(ii)));
                elseif startsWith(f, "meta.")
                    obj.applyMetaLine(char(extractAfter(f, "meta.")), R.New(ii(end)));
                elseif isfield(curation.Store.TYPE_OF, char(f))
                    rows = obj.RowOfId(str2double(R.CellID(ii)));
                    vals = curation.Journal.decode(R.New(ii), curation.Store.TYPE_OF.(char(f)));
                    obj.C.(char(f))(rows) = vals;
                end
            end
            obj.TCache = [];
        end

        %% ------------------------------------------------------------- reconcile core
        function rep = reconcileImpl(obj, L, fp, tolUm, fromOpen, ropts)
            % FROMOPEN: the change is journaled first (the snapshot is written at the end of the
            % open, best effort). Otherwise all or nothing: the snapshot CSV is written first and
            % when that fails every change is reverted (rows, meta, undo history) and the error
            % rethrown; then the structural transaction is journaled.
            if nargin < 6 || ~isstruct(ropts), ropts = struct(); end
            allowEmpty = logical(curation.Store.metaField(ropts, 'AllowEmpty', false));
            force = logical(curation.Store.metaField(ropts, 'Force', false));
            [N, nDrop] = curation.Store.normalizeLocs(L);
            um = obj.Meta.UmPerPixel;
            if ~(um > 0), um = curation.Store.DEFAULT_UM_PER_PIXEL; end
            tolPx = tolUm / um;
            C0 = obj.C;
            n0 = numel(C0.CellID);
            rep = curation.Store.emptyReport();
            rep.Ran = true;
            rep.nOld = n0;
            rep.nNew = numel(N.X);
            rep.tolUm = tolUm;
            rep.umPerPixel = um;
            rep.fingerprint = string(fp);
            rep.nDroppedNonFinite = nDrop;
            if nDrop > 0
                rep.warnings(end + 1, 1) = curation.Store.dropWarning(nDrop);
            end
            nIn = nnz(C0.InLocs);
            if rep.nNew == 0 && nIn > 0 && ~allowEmpty
                obj.refuseReconcile(rep, "emptyLocs", sprintf(['The new locs table has no detections, ' ...
                    'but %d stored rows are matched to the current one: reconciling would mark every ' ...
                    'unreviewed row stale. Nothing was changed; check the locs file, or reconcile ' ...
                    'with AllowEmpty=true to apply it.'], nIn), 'curation:Store:emptyLocs');
            end
            P = curation.Reconciler.plan(C0, [N.X, N.Y], tolPx);
            rep.nExact = P.Counts.exact;
            rep.nNearDet = P.Counts.nearDet;
            rep.nNearHuman = P.Counts.nearHuman;
            rep.nMergedRows = P.Counts.merged;
            rep.nNear = nnz(P.Pass > 1);
            matchedIn = nnz(C0.InLocs & P.RowNew > 0);
            if nIn > 0 && rep.nNew > 0 && matchedIn < 0.5 * nIn && ~force
                obj.refuseReconcile(rep, "mismatch", sprintf(['Only %d of the %d stored detections ' ...
                    'matched the new locs (%d detections) within %g um: a different image, page or ' ...
                    'coordinate space? Nothing was changed; reconcile with Force=true to apply it ' ...
                    'anyway.'], matchedIn, nIn, rep.nNew, tolUm), 'curation:Store:reconcileMismatch');
            end

            C = C0;
            mr = find(P.RowNew > 0);
            nj = P.RowNew(mr);
            C.score(mr) = N.score(nj);
            C.class(mr) = N.class(nj);
            C.imgName(mr) = N.imgName(nj);
            C.thr(mr) = N.thr(nj);
            C.DET_X(mr) = N.X(nj);
            C.DET_Y(mr) = N.Y(nj);
            C.DetRun(mr) = string(fp);
            C.MatchDistUm(mr) = P.DistPx(mr) * um;
            C.InLocs(mr) = true;
            fol = C.PosSource(mr) ~= "human";
            C.X(mr(fol)) = N.X(nj(fol));
            C.Y(mr(fol)) = N.Y(nj(fol));
            C.PosSource(mr(fol)) = "det";
            % the Stage-2 score follows the position (RESCORE): the locs' value only where the
            % effective position is the detection's; a person's position elsewhere keeps its own
            % score, except a "detector" value, which was the old detector position's
            onIt = hypot(C.X(mr) - N.X(nj), C.Y(mr) - N.Y(nj)) <= curation.Store.POS_TOL_PX;
            fr = mr(onIt); fj = nj(onIt);
            C.rescore(fr) = N.rescore(fj);
            C.RescoreSource(fr) = "";
            C.RescoreSource(fr(isfinite(N.rescore(fj)))) = "detector";
            gone = mr(~onIt & C.RescoreSource(mr) == "detector");
            C.rescore(gone) = NaN;
            C.RescoreSource(gone) = "";
            re = C.State(mr) == "stale";
            C.State(mr(re)) = "active";
            rep.nReactivated = nnz(re);
            rep.matchDistUm = P.DistPx(mr) * um;
            if ~isempty(rep.matchDistUm), rep.maxMatchDistUm = max(rep.matchDistUm); end

            un = find(P.RowNew == 0);
            C.InLocs(un) = false;
            isMergedRow = C.State(un) == "merged";
            keeperIds = unique(C.MergedInto(C.State == "merged" & C.MergedInto > 0));
            touched = C.Origin(un) ~= "detected" | C.PosSource(un) == "human" ...
                | ismember(C.CellID(un), keeperIds);
            byPerson = C.Reviewed(un) & ismember(C.LabelSource(un), curation.Store.PERSON_SOURCES);
            det = ~isMergedRow & C.Origin(un) == "detected";
            rep.nVanishedGood = nnz(det & byPerson & C.Label(un) == "Good" & C.State(un) == "active");
            rep.nVanishedOther = nnz(det & byPerson & C.Label(un) ~= "Good");
            loose = ~isMergedRow & ~byPerson & ~touched;
            wasStale = C.State(un) == "stale";
            % never purged: rows with a flag, a note, or in an audit sample (finding H)
            protectedRow = strlength(C.Flag(un)) > 0 | strlength(C.Notes(un)) > 0 ...
                | strlength(C.AuditRole(un)) > 0;
            purge = un(loose & wasStale & ~protectedRow);
            newStale = un(loose & ~wasStale);
            C.State(newStale) = "stale";
            rep.nStale = numel(newStale);
            rep.nPurged = numel(purge);

            k = numel(P.NewUnmatched);
            first = obj.Meta.NextCellId;
            if k > 0
                R = curation.Store.rowsFromNorm(N, P.NewUnmatched, fp, first);
                C = curation.Store.concatRows(C, R);
            end
            rep.nAppended = k;
            if ~isempty(P.NearKept)
                % a new detection within tolerance of a reviewed row: appended, but reported as
                % [new CellID, reviewed CellID] so the GUI can queue the pair (never silent)
                [~, pos] = ismember(P.NearKept(:, 1), P.NewUnmatched);
                rep.nearKeptIds = uint32([first + pos - 1, double(C0.CellID(P.NearKept(:, 2)))]);
                rep.nNearKept = size(rep.nearKeptIds, 1);
                rep.warnings(end + 1, 1) = sprintf(['%d new detection(s) lie within %g um of a ' ...
                    'reviewed cell; they were added as candidates and listed in nearKeptIds.'], ...
                    rep.nNearKept, tolUm);
            end
            if ~isempty(purge)
                keep = true(numel(C.CellID), 1);
                keep(purge) = false;
                C = curation.Store.selectRows(C, keep);
            end
            C.Excluded = obj.excludedFor(C.X, C.Y);   % appended and moved rows follow the regions

            % ---- apply ---------------------------------------------------------------------------
            M0 = obj.Meta; U0 = obj.UndoStack; R0 = obj.RedoStack; LR0 = obj.LastReconcile;
            E = curation.Store.diffEntries(C0, C);
            if ~strcmp(char(M0.LocsFingerprint), char(fp))
                E(end + 1, 1) = curation.ChangeSet.entry('meta', 'LocsFingerprint', [], ...
                    char(M0.LocsFingerprint), char(fp));
            end
            if k > 0
                E(end + 1, 1) = curation.ChangeSet.entry('meta', 'NextCellId', [], first, first + k);
            end
            obj.Meta.NextCellId = first + k;
            obj.Meta.LocsFingerprint = char(fp);
            obj.C = C;
            obj.rebuildIndex();
            obj.LocsCache = struct('fp', char(fp), 'N', N);   % the detector values of this run
            obj.UndoStack = {};
            obj.RedoStack = {};
            if rep.nNew > 0 && numel(mr) < 0.5 * min(rep.nNew, max(1, n0 - nnz(C0.State == "merged")))
                rep.warnings(end + 1, 1) = sprintf(['Only %d of %d detections matched stored rows: ' ...
                    'a different image, page or pixel size?'], numel(mr), rep.nNew);
            end
            if rep.maxMatchDistUm > 0.75 * tolUm
                rep.warnings(end + 1, 1) = sprintf(['The largest match distance (%.2f um) is close to ' ...
                    'the tolerance (%g um).'], rep.maxMatchDistUm, tolUm);
            end
            obj.LastReconcile = rep;
            summary = jsonencode(rmfield(rep, {'matchDistUm', 'warnings'}));
            if fromOpen
                obj.sysCommit("Reconcile", "reconcile", E, true);
                if ~isempty(obj.JournalObj)
                    obj.JournalObj.event("reconcile", obj.Meta.Revision, obj.Reviewer, summary);
                end
                return;
            end
            cs = obj.sysCommit("Reconcile", "reconcile", E, false);
            if obj.Persist && ~obj.ReadOnly
                try
                    obj.writeSnapshotCsv();
                catch ME
                    obj.C = C0;
                    obj.Meta = M0;
                    obj.rebuildIndex();
                    obj.UndoStack = U0;
                    obj.RedoStack = R0;
                    obj.LastReconcile = LR0;
                    obj.TCache = [];
                    rethrow(ME);
                end
                obj.journalWrite(cs);
                if ~isempty(obj.JournalObj)
                    obj.JournalObj.event("reconcile", obj.Meta.Revision, obj.Reviewer, summary);
                end
                try
                    obj.writeSnapshotJson();
                catch ME
                    rep.warnings(end + 1, 1) = sprintf(['The JSON record could not be updated (%s); the ' ...
                        'snapshot and the journal hold the reconcile, and the record is written at ' ...
                        'the next save.'], ME.message);
                    obj.LastReconcile = rep;
                    warning('curation:Store:jsonNotUpdated', '%s', rep.warnings(end));
                end
            end
            ev = curation.ChangeSet("Reconcile", "reconcile");
            ev.Revision = obj.Meta.Revision;
            obj.fireChanged(ev, "reconcile", true);
        end

        function refuseReconcile(obj, rep, why, msg, id)
            rep.Ran = false;
            rep.Refused = true;
            rep.refusal = string(why);
            rep.warnings(end + 1, 1) = string(msg);
            obj.LastReconcile = rep;
            error(id, '%s', msg);
        end

        %% ------------------------------------------------------------- lock
        function warn = acquireLock(obj, force)
            % Take '<stem>_curation.lock' with an exclusive create (never write-then-read-back).
            % A lock of another live process (same host: that pid runs and started before the
            % lock was written; another host: always) makes the store read-only unless FORCE.
            warn = strings(0, 1);
            p = obj.Paths.lock;
            me = struct('host', curation.Store.hostName(), 'user', char(obj.Reviewer), ...
                'pid', curation.Store.myPid(), 'time', curation.AtomicIO.isoNow(true), ...
                'session', char(obj.Session));
            txt = jsonencode(me);
            takenOver = false;
            got = false;
            for attempt = 1:3
                if curation.AtomicIO.createExclusive(p, txt)
                    got = true;
                    break;
                end
                info = curation.Store.readLockFile(p);
                live = curation.Store.lockIsLive(info, p);
                if live && ~force
                    L = curation.Store.lockInfoFrom(info);
                    L.Held = true;
                    L.Message = sprintf(['Opened read-only: %s on %s (pid %d) has had this source ' ...
                        'open since %s.'], L.User, L.Host, L.Pid, L.Time);
                    obj.LockInfo = L;
                    obj.ReadOnly = true;
                    warn(end + 1, 1) = L.Message;
                    return;
                end
                % stale (or forced): take it over by delete + exclusive create; a process that
                % wins the same race keeps it and this one goes read-only
                try delete(p); catch, end
                if curation.AtomicIO.createExclusive(p, txt)
                    got = true;
                    takenOver = true;
                    L = curation.Store.lockInfoFrom(info);
                    warn(end + 1, 1) = sprintf('Took over the lock of %s on %s (pid %d, %s).', ...
                        L.User, L.Host, L.Pid, L.Time);
                    break;
                end
            end
            if ~got
                obj.ReadOnly = true;
                L = curation.Store.emptyLockInfo();
                L.Held = true;
                L.Message = "Opened read-only: another process took the lock at the same moment.";
                obj.LockInfo = L;
                warn(end + 1, 1) = L.Message;
                return;
            end
            obj.OwnsLock = true;
            L = curation.Store.emptyLockInfo();
            L.Host = string(me.host); L.User = string(me.user); L.Pid = me.pid;
            L.Time = string(me.time); L.Session = string(me.session); L.TakenOver = takenOver;
            obj.LockInfo = L;
            curation.Store.registry('add', p, me.session);
        end

        function releaseLock(obj)
            if ~obj.OwnsLock, return; end
            p = obj.Paths.lock;
            try
                if curation.Store.lockTextIsMine(curation.Store.readSmall(p), obj.Session)
                    delete(p);
                end
            catch
            end
            curation.Store.registry('remove', p, char(obj.Session));
            obj.OwnsLock = false;
        end

        function tf = ownsLockNow(obj, force)
            % Before every journal append and snapshot write: is the lock file still this
            % session's? (A store that was taken over with Force must stop writing.) A lock file
            % that someone deleted is taken back when possible. The file is read at most every
            % LOCK_CHECK_SEC (a label key must not wait for a network round trip each time); FORCE
            % (every snapshot write) reads it always, and so does any check after another store
            % of this MATLAB took the same lock (the in-process registry says so at once).
            tf = true;
            if ~obj.Persist || ~obj.OwnsLock || obj.ReadOnly, return; end
            if nargin < 2, force = false; end
            p = obj.Paths.lock;
            if ~force && ~isempty(obj.LockCheckTic) && toc(obj.LockCheckTic) < curation.Store.LOCK_CHECK_SEC && ...
                    curation.Store.registry('has', p, char(obj.Session))
                return
            end
            obj.LockReads = obj.LockReads + 1;
            txt = curation.Store.readSmall(p);
            if curation.Store.lockTextIsMine(txt, obj.Session)
                obj.LockCheckTic = tic;
                return
            end
            if isempty(txt) && ~isfile(p)
                me = struct('host', curation.Store.hostName(), 'user', char(obj.Reviewer), ...
                    'pid', curation.Store.myPid(), 'time', curation.AtomicIO.isoNow(true), ...
                    'session', char(obj.Session));
                if curation.AtomicIO.createExclusive(p, jsonencode(me))
                    obj.LockCheckTic = tic;
                    return
                end
                txt = curation.Store.readSmall(p);
                if curation.Store.lockTextIsMine(txt, obj.Session)
                    obj.LockCheckTic = tic;
                    return
                end
            end
            obj.LockCheckTic = [];
            tf = false;
        end

        function loseLock(obj)
            % The lock was taken over: stop writing, turn read-only, tell the GUI, throw.
            info = [];
            try info = jsondecode(curation.Store.readSmall(obj.Paths.lock)); catch, end
            L = curation.Store.lockInfoFrom(info);
            L.Held = true;
            L.Lost = true;
            L.Message = sprintf(['Read-only from now on: %s on %s (pid %d) took over this source ' ...
                '(lock written %s). Every change before this one is saved; the change just made was ' ...
                'not saved and has been reverted.'], L.User, L.Host, L.Pid, L.Time);
            obj.LockInfo = L;
            obj.LastError = L.Message;
            obj.ReadOnly = true;
            obj.OwnsLock = false;
            curation.Store.registry('remove', obj.Paths.lock, char(obj.Session));
            obj.TimerActive = false;   % stop, not delete: this may run in the timer's own callback
            try
                if ~isempty(obj.SaveTimer) && isvalid(obj.SaveTimer), stop(obj.SaveTimer); end
            catch
            end
            if ~isempty(obj.JournalObj)
                try obj.JournalObj.close(); catch, end
                obj.JournalObj = [];
            end
            obj.Txn = [];
            obj.BatchDepth = 0;
            obj.TCache = [];
            cs = curation.ChangeSet("Lock lost", "lockLost");
            cs.Revision = obj.Meta.Revision;
            obj.fireChanged(cs, "lockLost", true);
            error('curation:Store:lockLost', '%s', L.Message);
        end

        function becomeReadOnly(obj, reason)
            % Open fallback: keep showing the data, never write (no lock, no journal).
            obj.ReadOnly = true;
            if obj.OwnsLock, obj.releaseLock(); end
            if ~isempty(obj.JournalObj)
                try obj.JournalObj.close(); catch, end
                obj.JournalObj = [];
            end
            L = obj.LockInfo;
            if ~(isfield(L, 'Held') && L.Held) && strlength(string(L.Message)) == 0
                L.Message = string(reason);   % the first reason is the one to show
                obj.LockInfo = L;
            end
        end

        function abandonOpen(obj)
            % A failed open: release what it took, write nothing.
            obj.stopTimer();
            if ~isempty(obj.JournalObj)
                try obj.JournalObj.close(); catch, end
                obj.JournalObj = [];
            end
            try obj.releaseLock(); catch, end
            obj.Closed = true;
        end

        %% ------------------------------------------------------------- timer
        function t = makeTimer(obj, d)
            ref = obj;
            try
                ref = matlab.lang.WeakReference(obj);
            catch
            end
            period = max(0.05, round(d / 4 * 1000) / 1000);
            t = timer('Name', 'curation.Store autosave', 'ExecutionMode', 'fixedSpacing', ...
                'Period', period, 'StartDelay', max(0.001, round(d * 1000) / 1000), ...
                'BusyMode', 'drop', 'ObjectVisibility', 'off', ...
                'TimerFcn', @(tm, ~) curation.Store.onSaveTimer(tm, ref));
        end

        function stopTimer(obj)
            obj.TimerActive = false;
            try
                if ~isempty(obj.SaveTimer) && isvalid(obj.SaveTimer)
                    stop(obj.SaveTimer);
                    delete(obj.SaveTimer);
                end
            catch
            end
            obj.SaveTimer = [];
        end
    end

    methods (Static, Hidden)
        % Public only so a timer callback, a Constant initializer and a test can reach them.

        function R = fallbackNormRegions(decoded)
            % Regions normalizer used when curation.Regions is absent (or rejects the input);
            % mirrors curation.Regions.normalize. Callers pass the result through canonRegions.
            R = curation.Store.emptyRegions();
            if isempty(decoded), return; end
            if iscell(decoded)
                items = decoded(:);
            elseif isstruct(decoded)
                items = num2cell(decoded(:));
            else
                error('curation:Store:badArgument', 'Cannot interpret a %s as regions.', class(decoded));
            end
            tmpl = struct('id', 0, 'kind', "reference", 'scope', "image", 'xy', zeros(0, 2), 'note', "");
            out = repmat(tmpl, numel(items), 1);
            for k = 1:numel(items)
                s = items{k};
                o = tmpl;
                if ~isstruct(s), continue; end
                if isfield(s, 'id') && ~isempty(s.id), o.id = double(s.id(1)); end
                if isfield(s, 'kind') && ~isempty(s.kind), o.kind = string(s.kind); end
                if isfield(s, 'scope') && ~isempty(s.scope), o.scope = string(s.scope); end
                if isfield(s, 'note') && ~isempty(s.note), o.note = string(s.note); end
                if isfield(s, 'xy') && ~isempty(s.xy)
                    v = s.xy;
                    if iscell(v)
                        rows = cellfun(@(c) reshape(double(c), 1, []), v(:), 'UniformOutput', false);
                        v = vertcat(rows{:});
                    else
                        v = double(v);
                        if size(v, 2) ~= 2 && size(v, 1) == 2, v = v.'; end
                    end
                    o.xy = v;
                end
                out(k) = o;
            end
            R = out;
        end


        function t = makeTypeOf()
            t = struct();
            for k = 1:numel(curation.Store.COLUMNS)
                t.(char(curation.Store.COLUMNS(k))) = char(curation.Store.TYPES(k));
            end
        end

        function onSaveTimer(tm, ref)
            obj = [];
            try
                if isa(ref, 'matlab.lang.WeakReference')
                    obj = ref.Handle;
                else
                    obj = ref;
                end
            catch
            end
            if isempty(obj) || ~isvalid(obj) || obj.Closed
                try stop(tm); delete(tm); catch, end
                return;
            end
            try
                if ~obj.Dirty
                    obj.TimerActive = false;
                    obj.PendingSinceTic = [];
                    stop(tm);
                    return;
                end
                if obj.BatchDepth > 0, return; end
                d = obj.Options.AutosaveDelay;
                quiet = isempty(obj.LastChangeTic) || toc(obj.LastChangeTic) >= 0.999 * d;
                late = ~isempty(obj.PendingSinceTic) && toc(obj.PendingSinceTic) >= 10 * d;
                if quiet || late
                    obj.flush();
                    if ~obj.Dirty
                        obj.TimerActive = false;
                        stop(tm);
                    end
                end
            catch ME
                obj.LastError = string(ME.message);
                obj.TimerActive = false;
                try stop(tm); catch, end
                warning('curation:Store:autosaveFailed', 'Autosave failed: %s', ME.message);
            end
        end
    end

    methods (Static, Access = private)

        function txt = snapshotText(C)
            cols = curation.Store.COLUMNS;
            types = curation.Store.TYPES;
            n = numel(C.CellID);
            P = strings(n, numel(cols));
            for k = 1:numel(cols)
                v = C.(char(cols(k)));
                switch types(k)
                    case "uint32"
                        P(:, k) = string(v);
                    case "double"
                        P(:, k) = curation.AtomicIO.fmtDouble(v);
                    case "logical"
                        s = repmat("0", n, 1);
                        s(v) = "1";
                        P(:, k) = s;
                    otherwise
                        P(:, k) = curation.AtomicIO.csvEscape(v);
                end
            end
            hdr = join(cols, ",");
            if n == 0
                txt = char(hdr + newline);
            else
                txt = char(strjoin([hdr; join(P, ",", 2)], newline) + newline);
            end
        end

        function rec = sourceRecord(J, key)
            rec = [];
            if isstruct(J) && isscalar(J) && isfield(J, 'sources') && isstruct(J.sources) ...
                    && isscalar(J.sources) && isfield(J.sources, key)
                rec = J.sources.(key);
                if ~isstruct(rec) || ~isscalar(rec), rec = []; end
            end
        end

        function P = normPairs(v)
            P = zeros(0, 2, 'uint32');
            if isempty(v), return; end
            if iscell(v)
                v = cellfun(@(c) reshape(double(c), 1, []), v, 'UniformOutput', false);
                v = vertcat(v{:});
            end
            v = double(v);
            if numel(v) < 2, return; end
            v = reshape(v, [], 2);
            P = unique(uint32(sort(v, 2)), 'rows');
        end

        function v = decodeMeta(name, txt)
            txt = string(txt);
            switch name
                case 'KeptPairs'
                    try
                        v = curation.Store.normPairs(jsondecode(char(txt)));
                    catch
                        v = zeros(0, 2, 'uint32');
                    end
                case 'AutoReject'
                    try
                        v = curation.Store.normAutoReject(jsondecode(char(txt)));
                    catch
                        v = curation.Store.normAutoReject([]);
                    end
                case 'LocsFingerprint'
                    v = char(txt);
                case 'NextCellId'
                    v = str2double(regexprep(char(txt), '[\[\]\s]', ''));
                    if ~isfinite(v), v = 1; end
                otherwise   % SweepDone, Complete, LegacyImported
                    v = txt == "1" || lower(txt) == "true";
            end
        end

        function fp = snapshotFp(txt, nBytes)
            % Fingerprint of a snapshot CSV: its size and a hash of its text.
            fp = sprintf('bytes=%d;hash=%s', round(nBytes), curation.Hash.of(char(txt)));
        end

        function fp = snapshotFpOfFile(path)
            fp = curation.Store.snapshotFp(curation.AtomicIO.readText(path), curation.Journal.fileLength(path));
        end

        function s = importSummary(irep)
            s = jsonencode(struct('resolver', rmfield(irep.resolver, 'warnings'), ...
                'qc', rmfield(irep.qc, {'unmatched', 'warnings'}), 'keptPairs', size(irep.keptPairs, 1)));
        end

        function J = canonJson(J)
            % The shared JSON's shape: schema, regions as an array of objects, sources a struct.
            if ~isstruct(J) || ~isscalar(J), J = struct(); end
            J.schema = curation.Store.SCHEMA;
            if ~isfield(J, 'regions'), J.regions = []; end
            try
                J.regions = curation.Store.encodeRegions(curation.Store.normRegions(J.regions));
            catch
                % unreadable regions: leave them exactly as found
            end
            if ~isfield(J, 'sources') || ~isstruct(J.sources) || ~isscalar(J.sources)
                J.sources = struct();
            end
        end

        function J = removeSource(J, key)
            J = curation.Store.canonJson(J);
            if isfield(J.sources, key)
                J.sources = rmfield(J.sources, key);
            end
        end

        function J = reserveRegionIdIn(J, floorMax)
            % Hand out the next region id (J.nextRegionId - 1 afterward): never one in use, never
            % one handed out before (nextRegionId only grows).
            J = curation.Store.canonJson(J);
            ids = zeros(0, 1);
            try ids = curation.Store.regionIds(curation.Store.normRegions(J.regions)); catch, end
            nxt = 1;
            if isfield(J, 'nextRegionId') && isnumeric(J.nextRegionId) && isscalar(J.nextRegionId)
                nxt = double(J.nextRegionId);
            end
            id = max([nxt; max([0; ids]) + 1; floorMax + 1]);
            J.nextRegionId = id + 1;
        end

        function tf = sameRegion(a, b)
            tf = double(a.id) == double(b.id) && string(a.kind) == string(b.kind) ...
                && string(a.scope) == string(b.scope) && string(a.note) == string(b.note) ...
                && isequal(size(a.xy), size(b.xy)) ...
                && all(abs(double(a.xy(:)) - double(b.xy(:))) <= 1e-6 * max(1, abs(double(a.xy(:)))));
        end

        function E = diffEntries(C0, C1)
            % ChangeSet entries that turn rows C0 into C1: per column 'set' entries for the rows
            % both hold (by CellID), one 'add' for new rows, one 'remove' for rows that are gone.
            E = curation.ChangeSet.emptyEntries();
            id0 = double(C0.CellID); id1 = double(C1.CellID);
            [tf, loc] = ismember(id1, id0);
            i1 = find(tf); i0 = loc(tf);
            cols = curation.Store.COLS;
            for k = 2:numel(cols)
                c = cols{k};
                a = C0.(c)(i0); b = C1.(c)(i1);
                if isfloat(a)
                    ch = ~(a == b | (isnan(a) & isnan(b)));
                else
                    ch = a ~= b;
                end
                if any(ch)
                    E(end + 1, 1) = curation.ChangeSet.entry('set', c, C1.CellID(i1(ch)), a(ch), b(ch)); %#ok<AGROW>
                end
            end
            nw = find(~tf);
            if ~isempty(nw)
                R = curation.Store.selectRows(C1, nw);
                E(end + 1, 1) = curation.ChangeSet.entry('add', '', C1.CellID(nw), [], R);
            end
            gone = find(~ismember(id0, id1));
            if ~isempty(gone)
                R = curation.Store.selectRows(C0, gone);
                E(end + 1, 1) = curation.ChangeSet.entry('remove', '', C0.CellID(gone), R, []);
            end
        end

        function R = rowFromJson(txt)
            R = [];
            try
                s = jsondecode(char(txt));
            catch
                return;
            end
            R = curation.Store.defaultRows(1);
            cols = curation.Store.COLUMNS;
            types = curation.Store.TYPES;
            for k = 1:numel(cols)
                nm = char(cols(k));
                if ~isfield(s, nm), continue; end
                v = s.(nm);
                switch types(k)
                    case "double"
                        if ischar(v) || isstring(v), v = str2double(v); end
                        if isempty(v), v = NaN; end
                        R.(nm) = double(v);
                    case "uint32"
                        if isempty(v), v = 0; end
                        R.(nm) = uint32(v);
                    case "logical"
                        if isempty(v), v = false; end
                        R.(nm) = logical(v);
                    otherwise
                        if isempty(v), v = ""; end
                        R.(nm) = string(v);
                end
            end
        end

        function s = relTo(p, folder)
            p = char(p);
            s = p;
            if isempty(p), return; end
            [d, n, e] = fileparts(p);
            if strcmpi(strrep(d, '\', '/'), strrep(char(folder), '\', '/'))
                s = [n e];
            end
        end

        function cs = invertForJournal(cs)
            E = cs.Entries;
            n = numel(E);
            out = curation.ChangeSet.emptyEntries();
            for k = n:-1:1
                e = E(k);
                switch e.Kind
                    case 'set'
                        out(end + 1, 1) = curation.ChangeSet.entry('set', e.Field, e.CellID, e.New, e.Old); %#ok<AGROW>
                    case 'add'
                        out(end + 1, 1) = curation.ChangeSet.entry('remove', '', e.CellID, e.New, []); %#ok<AGROW>
                    case 'meta'
                        out(end + 1, 1) = curation.ChangeSet.entry('meta', e.Field, [], e.New, e.Old); %#ok<AGROW>
                    case 'region'
                        out(end + 1, 1) = curation.ChangeSet.entry('region', e.Field, [], e.New, e.Old); %#ok<AGROW>
                end
            end
            cs.Entries = out;
        end

        %% ------------------------------------------------------------- auto-reject
        function a = normAutoReject(st)
            % Canonical auto-reject state: enabled (logical), tau (double, NaN = none),
            % modelVersion (string), audit (struct in jsondecode(jsonencode(.)) form).
            a = struct('enabled', false, 'tau', NaN, 'modelVersion', "", 'audit', struct());
            if isempty(st), return; end
            if ~isstruct(st) || ~isscalar(st)
                error('curation:Store:badArgument', 'The auto-reject state must be a scalar struct.');
            end
            if isfield(st, 'enabled') && ~isempty(st.enabled)
                v = st.enabled;
                if ~(islogical(v) || isnumeric(v)) || ~isscalar(v) || isnan(double(v))
                    error('curation:Store:badArgument', 'autoReject.enabled must be a logical scalar.');
                end
                a.enabled = logical(v);
            end
            if isfield(st, 'tau') && ~isempty(st.tau)
                v = st.tau;
                if ~isnumeric(v) || ~isscalar(v)
                    error('curation:Store:badArgument', 'autoReject.tau must be a numeric scalar (NaN = none).');
                end
                a.tau = double(v);
            end
            if isfield(st, 'modelVersion')
                a.modelVersion = curation.Store.oneText(st.modelVersion, 'model version');
            end
            if isfield(st, 'audit') && ~isempty(st.audit)
                if ~isstruct(st.audit)
                    error('curation:Store:badArgument', 'autoReject.audit must be a struct.');
                end
                a.audit = jsondecode(jsonencode(st.audit));
            end
        end

        %% ------------------------------------------------------------- regions
        function R = emptyRegions()
            R = struct('id', {}, 'kind', {}, 'scope', {}, 'xy', {}, 'note', {});
            R = reshape(R, 0, 1);
        end

        function ids = regionIds(R)
            if isempty(R)
                ids = zeros(0, 1);
            else
                ids = reshape(double([R.id]), [], 1);
            end
        end

        function R = normRegions(decoded)
            % Canonical N x 1 region array from whatever jsondecode returned (struct, struct
            % array, cell of structs with differing fields or vertex counts, []). Uses
            % curation.Regions.normalize when that class exists, then enforces the types here.
            persistent haveRegions
            if isempty(haveRegions)
                try
                    haveRegions = ~isempty(meta.class.fromName('curation.Regions'));
                catch
                    haveRegions = false;
                end
            end
            R = [];
            if haveRegions
                try
                    R = curation.Regions.normalize(decoded);
                catch
                    R = [];
                end
            end
            if isempty(R) && ~isempty(decoded)
                R = curation.Store.fallbackNormRegions(decoded);
            end
            R = curation.Store.canonRegions(R);
        end

        function R = canonRegions(R)
            % Exact field order and types: id double, kind/scope/note string, xy M x 2 double.
            E = curation.Store.emptyRegions();
            if isempty(R), R = E; return; end
            n = numel(R);
            out = repmat(struct('id', 0, 'kind', "", 'scope', "", 'xy', zeros(0, 2), 'note', ""), n, 1);
            for k = 1:n
                r = R(k);
                out(k).id = double(r.id(1));
                out(k).kind = curation.Store.oneText(r.kind, 'region kind');
                sc = curation.Store.oneText(r.scope, 'region scope');
                if sc == "", sc = "image"; end
                out(k).scope = sc;
                xy = double(r.xy);
                if isempty(xy), xy = zeros(0, 2); end
                out(k).xy = reshape(xy, [], 2);
                out(k).note = curation.Store.oneText(r.note, 'region note');
            end
            R = out;
        end

        function r = checkRegion(region)
            % One region from the caller, validated and canonical.
            if ~isstruct(region) || ~isscalar(region)
                error('curation:Store:badArgument', 'A region is a scalar struct (kind, xy, scope, note, id).');
            end
            if ~isfield(region, 'kind')
                error('curation:Store:badArgument', 'A region needs a kind ("exclude", "analysis" or "reference").');
            end
            try
                r = curation.Store.normRegions(region);
            catch ME
                error('curation:Store:badArgument', 'Invalid region: %s', ME.message);
            end
            r = r(1);
            r.kind = lower(r.kind);
            if ~ismember(r.kind, ["exclude", "analysis", "reference"])
                error('curation:Store:badArgument', 'Unknown region kind "%s".', r.kind);
            end
            if size(r.xy, 1) < 3 || any(~isfinite(r.xy(:)))
                error('curation:Store:badArgument', 'A region needs at least 3 finite vertices (M x 2).');
            end
            if ~(isfinite(r.id) && r.id >= 0 && r.id == fix(r.id))
                error('curation:Store:badArgument', 'A region id must be 0 (assign) or a positive integer.');
            end
        end

        function R = regionOp(R, oldR, newR)
            % Transition old -> new on a region array ([] = none), keyed by id.
            if ~isempty(oldR)
                R = R(curation.Store.regionIds(R) ~= oldR.id);
            end
            if ~isempty(newR)
                R = R(curation.Store.regionIds(R) ~= newR.id);
                R = [reshape(R, [], 1); newR];
            end
            if isempty(R)
                R = curation.Store.emptyRegions();
            else
                R = reshape(R, [], 1);
            end
        end

        function J = applyRegionOps(J, ops)
            % Region transitions (old -> new) on the shared JSON. An id held in the file by a
            % DIFFERENT region than the one this transition expects (e.g. undoing a removal whose
            % id the other channel has since been given by an older version) throws
            % curation:Store:regionConflict before anything is changed. nextRegionId stays above
            % every id.
            if ~isstruct(J) || ~isscalar(J), J = struct(); end
            if ~isfield(J, 'schema'), J.schema = curation.Store.SCHEMA; end
            R = curation.Store.emptyRegions();
            if isfield(J, 'regions'), R = curation.Store.normRegions(J.regions); end
            for k = 1:numel(ops)
                o = ops(k).Old; n = ops(k).New;
                ref = o;
                if isempty(ref), ref = n; end
                if ~isempty(ref)
                    cur = R(curation.Store.regionIds(R) == ref.id);
                    okOld = ~isempty(o) && ~isempty(cur) && curation.Store.sameRegion(cur(1), o);
                    okNew = ~isempty(n) && ~isempty(cur) && curation.Store.sameRegion(cur(1), n);
                    if ~isempty(cur) && ~okOld && ~okNew
                        error('curation:Store:regionConflict', ['Region id %g is now held by a ' ...
                            'different region ("%s", %s, note "%s"); it was left as it is and this ' ...
                            'step was not applied.'], ref.id, cur(1).kind, cur(1).scope, cur(1).note);
                    end
                end
                R = curation.Store.regionOp(R, o, n);
            end
            J.regions = curation.Store.encodeRegions(R);
            if ~isfield(J, 'sources') || ~isstruct(J.sources), J.sources = struct(); end
            nxt = 1;
            if isfield(J, 'nextRegionId') && isnumeric(J.nextRegionId) && isscalar(J.nextRegionId)
                nxt = double(J.nextRegionId);
            end
            J.nextRegionId = max([nxt; max([0; curation.Store.regionIds(R)]) + 1]);
        end

        function c = encodeRegions(R)
            % Cell column of plain structs, so jsonencode always writes an array of objects and
            % every xy as [[x,y],...] (a 1 x 1 struct would otherwise become an object).
            c = cell(numel(R), 1);
            for k = 1:numel(R)
                c{k} = curation.Journal.regionStruct(R(k));
            end
        end

        %% ------------------------------------------------------------- validation
        function s = oneText(x, what)
            % One text value as a string scalar. '' / "" / [] / {} all mean "none" -> "".
            if nargin < 2, what = 'text'; end
            if isempty(x)
                s = "";
                return;
            end
            s = curation.AtomicIO.cleanText(x);
            if ~isscalar(s)
                error('curation:Store:badArgument', 'One %s at a time.', what);
            end
        end

        function name = scorerName(m)
            % setRescore's modelName: one text ('' / "" / [] = none); a model folder path is
            % reduced to its last component, the model's name.
            if isempty(m)
                name = "";
                return;
            end
            if ~(ischar(m) || isstring(m) || iscellstr(m))
                error('curation:Store:badArgument', 'setRescore: the scoring model name must be text.');
            end
            name = curation.Store.oneText(m, 'scoring model name');
            if contains(name, ["/", "\"])
                t = regexprep(char(name), '[\\/]+$', '');
                [~, b, e] = fileparts(t);
                name = string([b e]);
            end
        end

        function tf = oneFlag(v, what)
            % One logical value (validated before anything is written).
            if ~(islogical(v) || isnumeric(v)) || ~isscalar(v) || isnan(double(v))
                error('curation:Store:badArgument', '%s takes one logical value.', what);
            end
            tf = logical(v);
        end

        function label = canonLabel(label)
            s = curation.Store.oneText(label, 'label');
            k = find(strcmpi(curation.Store.LABELS, s), 1);
            if isempty(k)
                error('curation:Store:badLabel', 'Unknown label "%s" (Good, Bad, Uncertain or "").', s);
            end
            label = curation.Store.LABELS(k);
        end

        function src = canonSource(src)
            % "" (or '') means the default source "human".
            s = lower(curation.Store.oneText(src, 'label source'));
            if s == "", s = "human"; end
            if ~ismember(s, curation.Store.LABEL_SOURCES)
                error('curation:Store:badSource', 'Unknown label source "%s".', s);
            end
            src = s;
        end

        function v = canonMember(v, allowed, what)
            s = curation.Store.oneText(v, what);
            k = find(strcmpi(allowed, s), 1);
            if isempty(k)
                error('curation:Store:badArgument', 'Unknown %s "%s".', what, s);
            end
            v = allowed(k);
        end

        %% ------------------------------------------------------------- process / host
        function h = hostName()
            persistent cached
            if isempty(cached)
                cached = getenv('COMPUTERNAME');
                if isempty(cached)
                    try
                        [~, cached] = system('hostname');
                        cached = strtrim(cached);
                    catch
                        cached = 'unknown';
                    end
                end
            end
            h = cached;
        end

        function p = myPid()
            persistent cached
            if isempty(cached)
                try
                    cached = double(feature('getpid'));
                catch
                    cached = 0;
                end
            end
            p = cached;
        end

        function tf = pidAlive(pid, lockTime)
            % true when process PID runs on this machine and was not started after LOCKTIME (the
            % time its lock was written; a later start means the pid was reused). Whatever the
            % program is called: a compiled app holds its lock like MATLAB does. When the start
            % time cannot be read (another user's process) the process counts as alive.
            tf = true;
            if ~(pid > 0), tf = false; return; end
            if nargin < 2, lockTime = ""; end
            t = curation.Store.parseIsoTime(lockTime);
            if ispc
                try
                    if NET.isNETSupported
                        try
                            pr = System.Diagnostics.Process.GetProcessById(int32(pid));
                        catch
                            tf = false;   % no such process
                            return;
                        end
                        try
                            if pr.HasExited, tf = false; return; end
                        catch
                        end
                        try
                            st = pr.StartTime.ToUniversalTime();
                            started = datetime(double(st.Year), double(st.Month), double(st.Day), ...
                                double(st.Hour), double(st.Minute), ...
                                double(st.Second) + double(st.Millisecond) / 1000, 'TimeZone', 'UTC');
                            if ~isnat(t) && started > t + seconds(2)
                                tf = false;   % the pid now belongs to a process started later
                            end
                        catch
                        end
                        return;
                    end
                catch
                end
                [st, out] = system(sprintf('tasklist /FI "PID eq %d" /FO CSV /NH', round(pid)));
                tf = st == 0 && contains(out, sprintf('"%d"', round(pid)));
            else
                [st, ~] = system(sprintf('ps -p %d -o pid=', round(pid)));
                tf = st == 0;
                if tf && ~isnat(t)
                    [st2, out] = system(sprintf('ps -p %d -o etimes=', round(pid)));
                    el = str2double(strtrim(out));
                    if st2 == 0 && isfinite(el)
                        started = datetime('now', 'TimeZone', 'UTC') - seconds(el);
                        tf = ~(started > t + seconds(2));
                    end
                end
            end
        end

        function t = parseIsoTime(s)
            % datetime (UTC) of an ISO 8601 time with offset, NaT when it cannot be read.
            t = NaT('TimeZone', 'UTC');
            s = char(string(s));
            if isempty(s), return; end
            fmts = {'yyyy-MM-dd''T''HH:mm:ss.SSSXXX', 'yyyy-MM-dd''T''HH:mm:ssXXX'};
            for k = 1:numel(fmts)
                try
                    t = datetime(s, 'InputFormat', fmts{k}, 'TimeZone', 'UTC');
                    return;
                catch
                end
            end
        end

        function txt = readSmall(p)
            % Whole small file as char, '' when missing or unreadable.
            txt = '';
            fid = fopen(char(p), 'r', 'n', 'UTF-8');
            if fid < 0, return; end
            txt = fread(fid, [1 Inf], '*char');
            fclose(fid);
        end

        function tf = lockTextIsMine(txt, session)
            tf = ~isempty(txt) && ~isempty(regexp(char(txt), ['"session"\s*:\s*"' ...
                regexptranslate('escape', char(session)) '"'], 'once'));
        end

        function info = readLockFile(p)
            % Decoded lock file; [] when it stays empty or invalid for ~0.3 s (a lock being
            % written is empty for a moment after its exclusive create).
            info = [];
            for k = 1:4
                txt = curation.Store.readSmall(p);
                if ~isempty(strtrim(txt))
                    try
                        info = jsondecode(txt);
                        if isstruct(info) && isscalar(info), return; end
                    catch
                    end
                    info = [];
                end
                if ~isfile(p), return; end
                pause(0.05 * k);
            end
        end

        function live = lockIsLive(info, p)
            % Is the lock described by INFO (decoded lock file) held by a live session?
            live = false;
            if ~(isstruct(info) && isscalar(info) && isfield(info, 'pid')), return; end
            oHost = char(string(curation.Store.metaField(info, 'host', '')));
            oPid = double(curation.Store.metaField(info, 'pid', NaN));
            oSess = char(string(curation.Store.metaField(info, 'session', '')));
            oTime = string(curation.Store.metaField(info, 'time', ''));
            live = true;
            if strcmpi(oHost, curation.Store.hostName())
                if oPid == curation.Store.myPid()
                    live = curation.Store.registry('has', p, oSess);
                else
                    live = curation.Store.pidAlive(oPid, oTime);
                end
            end
        end

        function L = lockInfoFrom(info)
            L = curation.Store.emptyLockInfo();
            if ~(isstruct(info) && isscalar(info)), return; end
            L.Host = string(curation.Store.metaField(info, 'host', ''));
            L.User = string(curation.Store.metaField(info, 'user', ''));
            L.Pid = double(curation.Store.metaField(info, 'pid', NaN));
            L.Time = string(curation.Store.metaField(info, 'time', ''));
            L.Session = string(curation.Store.metaField(info, 'session', ''));
        end

        function out = registry(op, lockPath, session)
            % Sessions of this MATLAB process that hold a lock, by lock path.
            persistent M
            if isempty(M)
                M = containers.Map('KeyType', 'char', 'ValueType', 'char');
            end
            key = lower(char(lockPath));
            out = false;
            switch op
                case 'add'
                    M(key) = char(session);
                case 'remove'
                    if isKey(M, key) && strcmp(M(key), char(session))
                        remove(M, key);
                    end
                case 'has'
                    out = isKey(M, key) && strcmp(M(key), char(session));
            end
        end
    end
end

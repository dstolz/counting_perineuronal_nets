classdef UiText
%UITEXT  Every word CellCurator shows: tooltips, button labels, the key map, the cheat sheet, the
%   color legend, the status and context messages, and the label colors. One place, so the
%   wording stays consistent and can be tested (tTooltips).
%
%   t = curation.UiText.tip(id, args...)     tooltip of control ID (sprintf ARGS into it)
%   s = curation.UiText.label(id, args...)   text of a button or heading (shortcut in brackets)
%   s = curation.UiText.msg(id, args...)     status-bar / context-line / undo text
%   T = curation.UiText.keymap()             table Key, Modifier, Label, Action, Description:
%                                            Key and Modifier as CellCurator.handleKey takes them,
%                                            Label as the user reads it ("Ctrl+Z", "Enter")
%   C = curation.UiText.colors()             label colors, 0-255 doubles (see below)
%   s = curation.UiText.cheatSheet(width)    the key and mouse cheat sheet (one char row, newlines;
%                                            lines of at most WIDTH characters, default 48)
%   L = curation.UiText.legendItems()        the color legend under the gallery (swatches + text)
%   s = curation.UiText.bandLabel(band)      "Likely good", "Middle, leaning bad", ...
%   s = curation.UiText.queueLabel(name)     "Review", "Flagged", "Browse Good", ...
%   s = curation.UiText.disabled(id, reason) tooltip of control ID when disabled, saying why
%
%   L = curation.UiText.mapLegendItems(S)    the legend under the section map (S: the map markers)
%   s = curation.UiText.markerClassLabel(c)  "To review", "Good", ... (curation.MapMarkers.CLASSES)
%
%   Colors (Okabe-Ito, color-blind safe; shared with the map and the Dataset Manager):
%     Good [0 158 115], Bad [213 94 0], Uncertain [240 228 66], Flag (corner badge) [204 121 167],
%     Blind [140 140 140] (audit tile not decided yet: a neutral border, no proposal),
%     Cursor [255 255 255], Selection [86 180 233],
%     ProposedGood / ProposedBad: the default's color at reduced strength (untouched tiles),
%     Background [24 24 24] (gallery), ProposedStrength (the blend factor),
%     Unreviewed [0 114 178] (map points not decided yet: the default of their marker; the map's
%     markers are the reviewer's choice, curation.MapMarkers), Exclude [230 159 0] (exclusion regions),
%     Reference [217 217 217] (the reference strip), DimFactor (excluded cells on the map keep this
%     share of their color).

    properties (Constant)
        SEP = [' ' char(183) ' ']          % " · "
        DASH = ['  ' char(8212) '  ']      % "  —  "
        LEFT = char(8592)                  % ←
        RIGHT = char(8594)                 % →
        UP = char(8593)                    % ↑
        DOWN = char(8595)                  % ↓
        ELLIPSIS = char(8230)              % …
        CHECK = char(10003)                % ✓
        MU = char(181)                     % µ
        ProposedStrength = 0.45
        DimFactor = 0.35
    end

    methods (Static)

        %% ------------------------------------------------------------------ tooltips
        function t = tip(id, varargin)
            %TIP  Tooltip text of control ID.
            L = curation.UiText.LEFT;
            R = curation.UiText.RIGHT;
            switch char(id)
                % ---- map and edits
                case 'toggleView'
                    t = ['Switch the center between the gallery of tiles and the map of the whole section ' ...
                        '[Tab] or [v]. Pressed: the map is showing. Labels, zoom and page stay where they are.'];
                case 'showOnMap'
                    t = ['Show on map [.]: the cell under the pointer (else the cursor) on the map of the ' ...
                        'section, selected, with its neighbors around it.'];
                case 'toolSelect'
                    t = ['Select tool [s]: click a cell to select it (Shift+click adds), drag to pan. Click ' ...
                        'inside an exclusion region to select the region. Double-click or Enter shows the cell ' ...
                        'in the gallery. Esc returns here from every other tool.'];
                case 'toolAdd'
                    t = ['Add tool [a]: click where the detector missed a cell to add one there (labeled ' ...
                        'Good). Shift+click snaps it to the center of the stained structure nearby (the hole ' ...
                        'of a net, the body of a PV cell; snapToCellCentroid). A click on an existing cell ' ...
                        'selects it instead.'];
                case 'toolMove'
                    t = ['Move tool [m]: drag a cell to where it belongs; its tiles are cut again at the new ' ...
                        'place. Hold Shift as you release the mouse button to snap it to the center of the ' ...
                        'stained structure nearby (the hole of a net, the body of a PV cell; ' ...
                        'snapToCellCentroid); without Shift it lands exactly where you drop it.'];
                case 'toolLasso'
                    t = ['Lasso tool [l]: draw around cells, then label them all, make the area an exclusion ' ...
                        'region (tissue folds, edges) or merge them into one cell.'];
                case 'fitMap'
                    t = 'Show the whole section. The wheel zooms about the pointer; dragging pans; + and - zoom too.';
                case 'markers'
                    t = ['Markers' char(8230) ': choose the color and symbol of the map''s points for each cell ' ...
                        'state (to review, Good, Bad, Uncertain, flagged). Used by the map and the locator, and ' ...
                        'remembered for the next session.'];
                case 'markerColor'
                    t = 'The color of the %s markers on the map and the locator.';
                case 'markerSymbol'
                    t = 'The symbol of the %s markers.';
                case 'markerFilled'
                    t = ['Filled: a solid %s marker (with a thin dark edge). Off: only its outline, so the ' ...
                        'cell under it stays visible. The symbols + x * have no face to fill.'];
                case 'markerDefaults'
                    t = 'Put every marker back to its default (shown at once; OK keeps it).';
                case 'markerOk'
                    t = 'Keep these markers and remember them for the next session [Enter].';
                case 'markerCancel'
                    t = 'Close and go back to the markers as they were [Esc].';
                case 'lassoGood'
                    t = 'Label every lassoed cell Good [g] (one undo step).';
                case 'lassoBad'
                    t = 'Label every lassoed cell Bad [b] (one undo step).';
                case 'lassoUncertain'
                    t = 'Label every lassoed cell Uncertain [u] (one undo step).';
                case 'lassoExclude'
                    t = ['Exclude region [e]: the lassoed area becomes an exclusion region of every channel of ' ...
                        'this section. Its cells leave the review, the counts and the final list. Ctrl+Z undoes it.'];
                case 'lassoMerge'
                    t = ['Merge into one [j]: the lassoed cells are one cell detected several times. The ' ...
                        'highest-scored one is kept and the others are merged into it.'];
                case 'lassoCancel'
                    t = 'Cancel [Esc]: forget the lasso; nothing changes.';
                case 'regionRemove'
                    t = ['Remove region [Del]: delete this exclusion region; its cells count again, in every ' ...
                        'channel. Ctrl+Z restores it.'];
                case 'regionKeep'
                    t = 'Keep the region [Esc]: deselect it; nothing changes.';
                case 'pairAcceptMerge'
                    t = ['The proposal [Enter]: one cell detected twice. Keep the higher-scored detection and ' ...
                        'merge the other into it.'];
                case 'pairAcceptKeep'
                    t = 'The proposal [Enter]: two separate cells. Keep both; the pair is not proposed again.';
                case 'pairAcceptMergeReviewed'
                    t = ['The proposal [Enter]: a new detection (after a re-detection) right next to a cell ' ...
                        'you reviewed is the same cell; merge it into the reviewed one.'];
                case 'pairOtherKeep'
                    t = 'Keep both [k]: two separate cells, neither is merged; the pair is not proposed again.';
                case 'pairOtherMerge'
                    t = 'Merge [j]: one cell detected twice. Keep the higher-scored detection, merge the other into it.';
                case 'pairSkip'
                    t = ['Skip [' R ']: decide this pair later and show the next one.'];
                case 'pairBack'
                    t = ['Back [' L ']: show the previous pair again.'];
                case 'sweepPrev'
                    t = ['Previous field [' L '] or [Backspace].'];
                case 'sweepNext'
                    t = 'Next field [Space] or [Enter]. After the last field the sweep is marked done.';
                case 'sweepWidth'
                    t = ['Width of one sweep field in micrometers (neighboring fields overlap by a tenth). ' ...
                        'Smaller fields: more of them, each shown larger. Remembered for next time.'];
                case 'finishFlagged'
                    t = 'Show the flagged cells (Flagged queue). Each needs a label before the source can be completed.';
                case 'finishPairs'
                    t = 'Resolve the close pairs on the map (Close pairs queue): merge duplicates or keep both.';
                case 'finishVanished'
                    t = ['Show the kept cells whose detection vanished after a re-detection (Vanished good ' ...
                        'queue). Not required for completing.'];
                case 'finishSweep'
                    t = ['Step over the whole section on the map and add the cells the detector missed (Sweep ' ...
                        'for missed cells). Optional: only needed if this section will be used to train the detector.'];
                case 'finishAudit'
                    t = ['Show the audit tiles still to judge (gray border, no proposal): a few tiles you confirmed ' ...
                        'by default, and the blind holdout. Each needs g, b or u before the source can be completed.'];
                case 'finishRescore'
                    t = ['Rescore now: the cells you added or moved have no Stage-2 score for their new position. ' ...
                        'Optional (it does not block completing), but the score feeds the proposals and the assist ' ...
                        'model, and <name>_final.csv carries it. score.py runs in the background with %s; review ' ...
                        'goes on meanwhile and the scores are stored between pages. %s'];
                case 'rescoreEdited'
                    t = ['Score the cells you added or moved in this source (score.py with %s, in the ' ...
                        'background; the scores are stored between pages). Their score feeds the proposals and ' ...
                        'the assist model, and _final.csv carries it. %s'];
                case 'training'
                    t = ['Training' char(8230) ': the Training tab on the right. What your labels can train now, ' ...
                        'the exports (scorer, detector, observation table), fine-tuning the scorer and the ' ...
                        'detector''s training command. Nothing there runs on the review keys.'];
                case 'tabTraining'
                    t = 'Training data from your labels: exports, the scorer fine-tune and the detector command.';
                case 'trainCounts'
                    t = ['What the curated labels of the channel kind on screen can train: labels a person decided ' ...
                        '(not audit evidence, not excluded, not flagged) for the scorer; sources marked complete ' ...
                        'AND swept for missed cells for the detector. The export itself reports what it left out. ' ...
                        'Counted in the background from the saved curation files, again after a confirmed page ' ...
                        'or a completion.'];
                case 'trainExport2'
                    t = ['Export scorer training set' char(8230) ': choose an empty folder; the Stage-2 data ' ...
                        '(train/validation split by animal, the model input of each source regenerated) and a ' ...
                        'plain-text summary are written there. The window waits while it writes.'];
                case 'trainExport1'
                    t = ['Export detector training set' char(8230) ': choose an empty folder; only sources marked ' ...
                        'complete and swept for missed cells are written (the detector learns that every ' ...
                        'unannotated pixel is background). Exclusion regions are painted out.'];
                case 'trainExportObs'
                    t = ['Export observation table' char(8230) ': every reviewed cell of this channel kind in one ' ...
                        'CSV, in the legacy QC observation format (with a summary beside it).'];
                case 'trainSummary'
                    t = ['The plain-text summary of the last export: counts per section and animal, what was left ' ...
                        'out and why, which preprocessing facts were recorded and which assumed, and the training ' ...
                        'command lines (read-only).'];
                case 'trainFineTune'
                    t = ['Fine-tune scorer: train_score.py fine-tunes the shipped ordinal scorer on the last scorer ' ...
                        'training set (%s) in its own process; review goes on. On success a new model folder is ' ...
                        'deployed in the repository and Score edited cells uses it for this channel kind.'];
                case 'trainState'
                    t = 'The state of the scorer fine-tune: running, finished (with the model folder made) or failed.';
                case 'trainLog'
                    t = 'The last lines of the fine-tune''s output (the whole log is curation_trainer.log in its run folder).';
                case 'trainCopyCmd'
                    t = ['Copy detector training command: the train.py command for the last detector training set ' ...
                        'goes to the clipboard and shows below. It runs for hours to days, so start it yourself ' ...
                        'in a terminal at the repository.'];
                case 'trainCommand'
                    t = 'The detector training command last copied (read-only; paste it into a terminal).';
                % ---- assist model and audit
                case 'assistSource'
                    t = ['Where the proposals come from. Before the assist model exists they come from the ' ...
                        'rescore of the Stage-2 scorer (cold start). The model takes over at 200 labels with 30 ' ...
                        'of each class, and is refitted in the background after every 150 new labels; a refit never ' ...
                        'changes the page on screen, only the order and proposals of the pages after it.'];
                case 'assistAccuracy'
                    t = ['The model''s out-of-fold AUC (sections of other animals held out) next to the rescore ' ...
                        'alone on the same labels: 1 = cells always ranked above non-cells, 0.5 = chance. ' ...
                        'Most of these labels were given with a proposal in view, so this number flatters the ' ...
                        'model; the Audit report gives its accuracy on tiles judged blind.'];
                case 'assistAgreement'
                    t = ['Agreement on audit tiles only: how often the proposal (P >= 0.5 means Good) matched what ' ...
                        'you decided when the tile was shown without any proposal. Labels given with a proposal in ' ...
                        'view are never used, because following the proposal would look like agreement.'];
                case 'auditReport'
                    t = ['Build the reviewer-consistency and model-accuracy report of this folder in the ' ...
                        'background; it appears in the Audit tab on the right, in plain language, ready to save.'];
                case 'saveReport'
                    t = ['Save the audit report: the text and its tables go to .cellcuration\audit_report_<date>.txt ' ...
                        'and .csv in the folder of sections.'];
                case 'tabAudit'
                    t = 'The audit report of this folder: what blind audit tiles say about the review and the model.';
                case 'auditText'
                    t = 'The audit report (read-only). Build it with Audit report... on the left; save it with Save report.';
                case 'database'
                    t = ['The lab database: its server, your login and what waits to be sent. The curation files ' ...
                        'are the same with or without it.'];
                case 'subject'
                    t = ['What the lab database says about the animal this section is of: its sex, species and ' ...
                        'project, its tags (cohort:a, pilot, ...) and its variables (age, dose, ...), written ' ...
                        'to the status bar. Shown only when you press this, so that you do not see the animal''s ' ...
                        'group while you decide on cells. The answers are the ones this computer last read ' ...
                        '(Dataset Manager: Check subjects); nothing here asks the server.'];
                case 'finishComplete'
                    t = ['Mark this source complete [Enter]: its final list of kept cells is written ' ...
                        '(<name>_final.csv; if it cannot be written the source stays incomplete), it is recorded ' ...
                        'as finished and the dataset manifest is updated. Ctrl+Z undoes it. A later edit that ' ...
                        'changes the kept cells or leaves cells to review makes it incomplete again, and its ' ...
                        'final list is then renamed <name>_final.stale.csv until it is completed again.'];
                case 'finishNext'
                    t = 'Go on with %s, the next source that still has cells to review [n].';
                % ---- review window
                case 'openFolder'
                    t = 'Choose a folder of sections. Every section below it that has detections is listed on the left.';
                case 'msgOpenFolder'
                    t = 'Choose the folder of sections to review (a folder picker opens).';
                case 'reopen'
                    t = 'Open the folder you reviewed last time: %s';
                case 'dataset'
                    t = 'The section on screen. Choose another one to review it; your work here is saved first.';
                case 'source'
                    t = 'Review channel %s of this section (image page %s). %s';
                case 'sourceActive'
                    t = 'Channel %s is on screen (image page %s). %s';
                case 'mode'
                    t = ['How tiles are drawn: the channel under review, an overlay (reviewed channel green, ' ...
                        'other channel magenta), the other channel alone, or both side by side. ' ...
                        '[o] cycles; hold [c] to see the other channel.'];
                case 'gain'
                    t = ['Brightness of every tile and of the map, relative to the default of the source on ' ...
                        'screen (chosen from its cells'' crops, so dim cells are visible). Keys: [ darker, ] ' ...
                        'brighter, 0 back to the default.'];
                case 'gamma'
                    t = ['Mid-tone contrast (gamma) of every tile and of the map, relative to the source''s ' ...
                        'default. Keys: ; darker, '' brighter, 0 back to the default.'];
                case 'evenTiles'
                    t = ['Even out the tiles [t]: each tile is brightened or darkened so its cell''s center ' ...
                        'shows at the level of this source''s typical cell (at most 3x either way, so an ' ...
                        'empty tile stays dark). Off: one contrast for the whole page, so a dim cell looks ' ...
                        'dim. Brightness and gamma still apply on top; the map is not changed.'];
                case 'undo'
                    t = 'Undo the last change [Ctrl+Z]. The page it was made on comes back on screen.';
                case 'redo'
                    t = 'Redo the change you just undid [Ctrl+Y].';
                case 'help'
                    t = 'Show or hide the list of keys and mouse actions [?].';
                case 'closeHelp'
                    t = 'Hide the list of keys [?] or [Esc].';
                case 'queues'
                    t = ['What to review. Review: undecided cells, a page at a time, each page with one ' ...
                        'proposed label, plus a few audit tiles (gray border, no proposal). Flagged: cells set aside with [f]. Close pairs: kept cells so close ' ...
                        'they may be one cell (on the map). Vanished good: kept cells the detector no longer ' ...
                        'finds. Browse: cells already labeled, to check again. Sweep: step over the map to ' ...
                        'add missed cells (optional).'];
                case 'sections'
                    t = ['Every section in the folder with the share of its cells reviewed; ' char(10003) ...
                        ' marks a completed source. Click one to review it.'];
                case 'tabInspector'
                    t = 'The cell under the pointer (or the cursor, or the one selected on the map), enlarged, with its scores, label and note.';
                case 'tabMap'
                    t = ['The whole section: the cells of the page on screen in color, the one under the ' ...
                        'pointer ringed. Click a place to show it on the big map.'];
                case 'note'
                    t = 'A one-line note on the cell shown above. Press Enter to save it.';
                case 'good'
                    t = 'Label Good [g]: a real cell to keep. Acts on the selected tiles, else on the cell shown above.';
                case 'bad'
                    t = 'Label Bad [b]: not a cell. Acts on the selected tiles, else on the cell shown above.';
                case 'uncertain'
                    t = 'Label Uncertain [u]: cannot tell from this view. Acts on the selected tiles, else on the cell shown above.';
                case 'flag'
                    t = ['Set aside for later [f]: the cell leaves the review pages and waits under Flagged. ' ...
                        'Press again to remove the flag.'];
                case 'clear'
                    t = 'Clear [x]: remove the label and the flag; the cell is undecided again.';
                case 'confirm'
                    t = ['Confirm the page [Enter]: every untouched tile gets the page''s proposed label, ' ...
                        'then the next page appears. Audit tiles (gray border) never get it: each needs g, b or u.'];
                case 'prev'
                    t = 'Go back one page [PgUp]. Its labels can still be changed.';
                case 'next'
                    t = ['Go to the next page without confirming this one [PgDn]: nothing is labeled, ' ...
                        'and the tiles you left untouched stay in the queue.'];
                case 'nextSource'
                    t = 'Open the next channel or section that still has cells to review [n].';
                case 'openNext'
                    t = 'Open %s, the next source with cells to review [n].';
                otherwise
                    error('curation:UiText:unknownId', 'No tooltip "%s".', char(id));
            end
            if ~isempty(varargin)
                t = sprintf(t, varargin{:});
            end
        end

        function t = disabled(id, reason)
            %DISABLED  Tooltip of control ID while it is disabled: what it does, and why it is off.
            t = [curation.UiText.tip(id) ' ' char(8212) ' unavailable now: ' char(reason)];
        end

        %% ------------------------------------------------------------------ labels
        function s = label(id, varargin)
            %LABEL  Text of a button, item or heading (a shortcut in brackets where there is one).
            L = curation.UiText.LEFT;
            E = curation.UiText.ELLIPSIS;
            switch char(id)
                case {'openFolder', 'msgOpenFolder'}, s = ['Open folder' E];
                case 'reopen',      s = 'Reopen %s';
                case 'undo',        s = 'Undo [Ctrl+Z]';
                case 'redo',        s = 'Redo [Ctrl+Y]';
                case 'help',        s = 'Keys [?]';
                case 'closeHelp',   s = 'Close [?]';
                case 'good',        s = 'Good [g]';
                case 'bad',         s = 'Bad [b]';
                case 'uncertain',   s = 'Uncertain [u]';
                case 'flag',        s = 'Flag [f]';
                case 'clear',       s = 'Clear [x]';
                case 'confirm',     s = 'Confirm page [Enter]';
                case 'prev',        s = 'Previous page [PgUp]';
                case 'next',        s = 'Next page [PgDn]';
                case 'nextSource',  s = 'Next source [n]';
                case 'openNext',    s = 'Open next source [n]';
                case 'brightness',  s = 'Brightness';
                case 'gamma',       s = 'Gamma';
                case 'evenTiles',   s = 'Even tiles [t]';
                case 'queuesHead',  s = 'Queues';
                case 'progressHead', s = 'Progress';
                case 'sectionsHead', s = 'Sections';
                case 'inspectorTab', s = 'Inspector';
                case 'mapTab',      s = 'Map';
                case 'mapPlaceholder', s = 'Open a source to see its map here.';
                case 'locatorHint', s = 'Click a place to show it on the big map.';
                case 'toggleView',  s = 'Map view [Tab]';
                case 'showOnMap',   s = 'Show on map [.]';
                case 'toolSelect',  s = 'Select [s]';
                case 'toolAdd',     s = 'Add [a]';
                case 'toolMove',    s = 'Move [m]';
                case 'toolLasso',   s = 'Lasso [l]';
                case 'fitMap',      s = 'Whole section';
                case 'markers',     s = ['Markers' E];
                case 'markerTitle', s = 'Map markers';
                case 'markerHeadClass', s = 'Cell state';
                case 'markerHeadColor', s = 'Color';
                case 'markerHeadSymbol', s = 'Symbol';
                case 'markerHeadFilled', s = 'Filled';
                case 'markerHeadPreview', s = 'Preview';
                case 'markerNote',  s = ['Excluded cells keep their marker, dimmed. Changes show on the map at ' ...
                                        'once; OK keeps them for the next session, Cancel goes back.'];
                case 'markerDefaults', s = 'Defaults';
                case 'markerOk',    s = 'OK';
                case 'markerCancel', s = 'Cancel';
                case 'lassoGood',   s = 'Good [g]';
                case 'lassoBad',    s = 'Bad [b]';
                case 'lassoUncertain', s = 'Uncertain [u]';
                case 'lassoExclude', s = 'Exclude region [e]';
                case 'lassoMerge',  s = 'Merge into one [j]';
                case 'lassoCancel', s = 'Cancel [Esc]';
                case 'regionRemove', s = 'Remove region [Del]';
                case 'regionKeep',  s = 'Keep it [Esc]';
                case 'pairAcceptMerge', s = 'Merge, keep the higher-scored cell [Enter]';
                case 'pairAcceptKeep',  s = 'Keep both [Enter]';
                case 'pairAcceptMergeReviewed', s = 'Merge into the reviewed cell [Enter]';
                case 'pairOtherKeep',   s = 'Keep both [k]';
                case 'pairOtherMerge',  s = 'Merge [j]';
                case 'pairSkip',    s = ['Skip [' curation.UiText.RIGHT ']'];
                case 'pairBack',    s = ['Back [' L ']'];
                case 'sweepPrev',   s = ['Previous field [' L ']'];
                case 'sweepNext',   s = 'Next field [Space]';
                case 'sweepWidth',  s = ['Field width (' char(181) 'm)'];
                case 'finishComplete', s = 'Mark source complete [Enter]';
                case 'finishNext',  s = 'Open next source [n]';
                case 'noFolder',    s = 'No folder open';
                case 'noSection',   s = '(no section)';
                case 'notePlaceholder', s = 'Note on this cell (Enter saves)';
                case 'inspectEmpty', s = 'Point at a tile to see it here.';
                case 'cheatTitle',  s = 'Keys and mouse';
                case 'captionTarget', s = 'Reviewed channel';
                case 'captionCompanion', s = 'Other channel';
                case 'captionOverlay', s = 'Overlay';
                case 'assistHead',  s = 'Assist';
                case 'auditReport', s = ['Audit report' E];
                case 'saveReport',  s = 'Save report';
                case 'auditTab',    s = 'Audit';
                case 'auditEmpty',  s = ['No report yet. Press Audit report' E ' on the left to build one: ' ...
                        'it says how often a tile confirmed by default changes when judged blind, and how ' ...
                        'accurate the assist model is on blind holdout tiles.'];
                case 'database',    s = ['Database' E];
                case 'subject',     s = ['Subject' E];
                case 'training',    s = ['Training' E];
                case 'trainingTab', s = 'Training';
                case 'rescoreEdited', s = 'Score edited cells (%s)';
                case 'rescoreRunning', s = ['Scoring edited cells' E];
                case 'trainHead',   s = 'Training data';
                case 'trainExport2', s = ['Export scorer training set' E];
                case 'trainExport1', s = ['Export detector training set' E];
                case 'trainExportObs', s = ['Export observation table' E];
                case 'trainLastExport', s = 'Last export';
                case 'trainNoExport', s = 'No export yet in this window.';
                case 'trainFineHead', s = 'Fine-tune the scorer (Stage 2)';
                case 'trainFineTune', s = 'Fine-tune scorer';
                case 'trainCopyCmd', s = 'Copy detector training command';
                otherwise
                    error('curation:UiText:unknownId', 'No label "%s".', char(id));
            end
            if ~isempty(varargin)
                s = sprintf(s, varargin{:});
            end
        end

        function [items, data] = modeItems()
            %MODEITEMS  Display-mode dropdown items and their values.
            items = {'Target', 'Overlay', 'Companion', 'Side by side'};
            data = {'target', 'overlay', 'companion', 'side'};
        end

        function s = modeName(mode)
            switch char(mode)
                case 'target',    s = 'the reviewed channel';
                case 'overlay',   s = 'overlay (reviewed channel green, other channel magenta)';
                case 'companion', s = 'the other channel';
                case 'side',      s = 'both channels side by side';
                otherwise,        s = char(mode);
            end
        end

        function s = queueLabel(name)
            %QUEUELABEL  Display name of a queue.
            switch char(name)
                case 'review',          s = 'Review';
                case 'flagged',         s = 'Flagged';
                case 'vanishedGood',    s = 'Vanished good';
                case 'browseGood',      s = 'Browse Good';
                case 'browseBad',       s = 'Browse Bad';
                case 'browseUncertain', s = 'Browse Uncertain';
                case 'closePairs',      s = 'Close pairs';
                case 'sweep',           s = 'Sweep for missed cells';
                case 'map',             s = 'Map';
                otherwise,              s = char(name);
            end
        end

        function s = bandLabel(band)
            %BANDLABEL  Display name of a review band (curation.Queues page Band).
            switch char(band)
                case 'middle-high', s = 'Middle, leaning good';
                case 'middle-low',  s = 'Middle, leaning bad';
                case 'good',        s = 'Likely good';
                case 'bad',         s = 'Likely bad';
                case 'blind',       s = 'Blind tiles';
                otherwise,          s = curation.UiText.queueLabel(band);
            end
        end

        %% ------------------------------------------------------------------ messages
        function s = msg(id, varargin)
            %MSG  Status, context-line and undo-description texts (sprintf templates).
            S = curation.UiText.SEP;
            D = curation.UiText.DASH;
            E = curation.UiText.ELLIPSIS;
            K = curation.UiText.CHECK;
            MU = curation.UiText.MU;
            switch char(id)
                % ---- map and edits: status bar
                case 'mapNoSource',  s = 'Open a source first: the map shows the section of the source on screen.';
                case 'mapShown',     s = ['Map of %s' S '%s cells' S 'Tab returns to the gallery.'];
                case 'toolSelectOn', s = 'Select tool: click a cell to select it; drag to pan.';
                case 'toolAddOn',    s = 'Add tool: click where the detector missed a cell (Shift+click snaps it to its center).';
                case 'toolMoveOn',   s = 'Move tool: drag a cell to where it belongs (hold Shift as you release to snap it to its center).';
                case 'toolLassoOn',  s = 'Lasso tool: draw around cells.';
                case 'toolReadOnly', s = 'Read-only: cells cannot be added, moved or lassoed in this window.';
                case 'mapNoTarget',  s = 'Select a cell on the map first (click it), or point at one.';
                case 'mapMarked',    s = 'Marked %s %s on the map.';
                case 'mapCleared',   s = 'Cleared %s on the map.';
                case 'mapFlagged',   s = 'Flagged %s for later.';
                case 'mapUnflagged', s = 'Removed the flag from %s.';
                case 'added',        s = 'Added cell %d (Good) at X %.1f, Y %.1f%s.';
                case 'moved',        s = 'Moved cell %d by %.1f px%s.';
                case 'snapped',      s = ' (snapped %.1f px to the center)';
                case 'snapNone',     s = ' (snap found no structure nearby: placed where you put it)';
                case 'addOutside',   s = 'That is outside the image: no cell was added.';
                case 'lassoMarked',  s = 'Marked %s %s (lasso).';
                case 'lassoEmpty',   s = 'The lasso holds no cells: only Exclude region applies.';
                case 'excludedRegion', s = 'Exclusion region %d added: %s left out, in every channel of this section.';
                case 'mergedCells',  s = 'Merged %s into cell %d.';
                case 'mergeNeedsTwo', s = 'Merging needs at least two cells inside the lasso.';
                case 'regionSelected', s = 'Exclusion region %d selected: Del removes it, Esc keeps it.';
                case 'regionRemoved', s = 'Removed exclusion region %d: %s count again.';
                case 'regionsApplied', s = 'Exclusion regions applied to %s: %s excluded, %s counted again.';
                case 'regionsAtOpen', s = '%s of %s lie inside exclusion regions and are left out.';
                case 'regionConflict', s = 'Nothing changed: %s';
                case 'jsonNotSaved', s = ['The cells and the journal are saved, but the shared regions file ' ...
                        'was not: %s It is written at the next save.'];
                case 'lockLost',     s = 'Another session took this source over; it is read-only here now. %s';
                case 'reconciled',   s = 'Detections changed since last time: %s.';
                case 'reconMatched', s = '%s matched';
                case 'reconNew',     s = '%s new';
                case 'reconKeptGone', s = '%s kept %s no longer detected (they stay kept; see Vanished good)';
                case 'reconStale',   s = '%s unreviewed no longer detected';
                case 'reconNearKept', s = '%s new %s right next to reviewed cells (see Close pairs)';
                case 'openedReadOnly', s = 'Opened %s of %s read-only: %s';
                case 'ctxPairMergeReviewed', s = 'Enter: merge the new detection into reviewed cell %d';
                case 'nearKeptTitle', s = ['New detection %.1f ' MU 'm from reviewed cell %d'];
                case 'roiFailed',    s = 'The reference ROI %s could not be read (%s); it is not drawn.';
                case 'keyOnMap',     s = '[%s] works on the map: %s Press Tab to show the map.';
                case 'keyNotNow',    s = '[%s] %s';
                case 'pairsNone',    s = 'No close pairs left in %s.';
                case 'pairMerged',   s = 'Merged %s into cell %d.';
                case 'pairKept',     s = 'Kept both cells (%s); the pair is not proposed again.';
                case 'pairWrap',     s = 'That was the last pair; back to the first one.';
                case 'pairFirst',    s = 'This is the first pair.';
                case 'sweepStart',   s = ['Sweep: %d fields of %d ' MU 'm. Click each cell the detector missed, then Space.'];
                case 'sweepResume',  s = 'Sweep resumed at field %d of %d.';
                case 'sweepFirst',   s = 'This is the first field.';
                case 'sweepDone',    s = 'Sweep done: all %d fields of %s checked.';
                case 'sweepWidthSet', s = ['Sweep fields are %d ' MU 'm wide now: %d fields.'];
                case 'noGalleryPage', s = 'Cell %d is on no gallery page (%s).';
                case 'onMapAlready', s = 'The map is showing: select a cell, then Enter shows it in the gallery.';
                case 'completed',    s = '%s is complete: %s kept cells written to %s.';
                case 'cannotComplete', s = 'Not complete yet: %s.';
                case 'notComplete',  s = '%s is no longer complete: %s.';
                case 'alreadyComplete', s = '%s is already complete.';
                % ---- map and edits: context line
                case 'ctxMap',       s = ['Map of %s' S '%s cells' D '%s'];
                case 'ctxMapSelect', s = ['click a cell to select it' S 'Tab: back to the gallery'];
                case 'ctxMapAdd',    s = ['Add tool: click where the detector missed a cell' S 'Shift+click: snapped to its center'];
                case 'ctxMapMove',   s = ['Move tool: drag a cell to where it belongs' S 'hold Shift as you release: snapped to its center'];
                case 'ctxMapLasso',  s = 'Lasso tool: draw around cells to label, exclude or merge them';
                case 'ctxMapOne',    s = ['Cell %d selected (%s)' D 'Enter: show it in the gallery' S 'g b u f x: label it'];
                case 'ctxMapMany',   s = ['%s selected' D 'g b u f x: label them all' S 'Esc: clear'];
                case 'ctxLasso',     s = ['Lasso: %s' D 'g b u: label them' S 'e: exclusion region' S 'j: merge into one' S 'Esc: cancel'];
                case 'ctxRegion',    s = ['Exclusion region %d (%s)' D 'Del: remove it (its cells count again)' S 'Esc: keep it'];
                case 'ctxPair',      s = ['%s' S 'pair %d of %d' D '%s'];
                case 'ctxPairMerge', s = 'Enter: merge, keep cell %d (rescore %s)';
                case 'ctxPairKeep',  s = 'Enter: keep both (two cells)';
                case 'ctxPairsNone', s = ['No close pairs in %s' D 'Tab: back to the gallery'];
                case 'ctxSweep',     s = ['Sweep field %d of %d' D 'click each cell the detector missed' S 'Space: next field'];
                case 'ctxSweepLast', s = ['Sweep field %d of %d, the last' D 'click each cell the detector missed' S 'Space: finish the sweep'];
                case 'ctxFinishReady', s = ['%s is reviewed' D 'Enter: mark it complete and write its final list of cells'];
                case 'ctxFinishAudit', s = ['%s: %s still to judge' D 'Enter: show them (g, b or u each)'];
                case 'ctxFinishDone', s = ['%s is complete' D 'Enter or n: open %s'];
                case 'ctxFinishDoneAll', s = ['%s is complete' D 'every source in this folder is reviewed'];
                case 'ctxFinishOpen', s = ['%s reviewed, %s still open' D 'Enter or n: open %s'];
                case 'ctxFinishOpenLast', s = ['%s reviewed, %s still open' D 'resolve them to complete it'];
                case 'nextOf',       s = '%s of %s';
                case 'showPairs',    s = ['Showing Close pairs' S '%s.'];
                case 'leftPairs',    s = 'Left the close pairs (back to the review).';
                case 'leftSweep',    s = 'Left the sweep at field %d of %d; it resumes there.';
                % ---- finishing a source: checklist
                case 'finTitle',     s = '%s: every cell is reviewed';
                case 'finTitleDone', s = ['%s is complete ' K];
                case 'finUnreviewed', s = 'Cells to review: %s';
                case 'finFlagged',   s = 'Flagged for later: %s';
                case 'finPairs',     s = 'Close pairs: %s';
                case 'finVanished',  s = 'Vanished good: %s';
                case 'finSweepDone', s = ['Sweep for missed cells: done ' K];
                case 'finSweepNot',  s = ['Sweep for missed cells: not done (optional ' char(8212) ...
                        ' only needed if this section will be used to train the detector)'];
                case 'finSweepPart', s = ['Sweep for missed cells: at field %d of %d (optional ' char(8212) ...
                        ' only needed if this section will be used to train the detector)'];
                case 'finOk',        s = ['0 ' K];
                case 'finOpen',      s = ['%s ' char(8212) ' %s'];
                case 'finCompleted', s = ['Completed ' K ' (Ctrl+Z undoes it)'];
                case 'finCompleteFirst', s = ['%s ' char(8212) ' first: %s'];
                case 'pageDone',     s = ['Page %d of %d done' S 'every tile on it was decided.'];
                case 'finWhyOpen',   s = 'still open: %s';
                case 'finAlready',   s = 'this source is already complete.';
                case 'finWhyReady',  s = 'Everything is resolved: press Enter to mark it complete.';
                case 'finWhyDone',   s = '%s kept cells are in its final list (%s).';
                case 'finWhyTodo',   s = 'Still open: %s.';
                case 'finNothing',   s = 'nothing is left in this queue.';
                case 'partToReview', s = '%s to review';
                case 'partFlagged',  s = '%s flagged';
                case 'partPairs',    s = '%s close %s';
                case 'finActFlagged', s = 'review them';
                case 'finActPairs',  s = 'resolve them on the map';
                case 'finActVanished', s = 'check them';
                case 'finAudit',     s = 'Audit tiles to judge: %s';
                case 'finActAudit',  s = 'judge them (g, b or u)';
                case 'partAudit',    s = '%s to judge';
                case 'finDone',      s = ['%s ' char(8212) ' nothing to do'];
                case 'finDoneTip',   s = '%s Nothing is left here.';
                case 'finNothingHere', s = 'Nothing is left in that list.';
                % ---- blind (audit) tiles
                case 'auditTiles',   s = '%s audit %s (gray border)';
                case 'blindSelect',  s = ['Audit tile: press g, b or u (or a label button). No proposal is shown ' ...
                        'for it, so your own judgment measures the review.'];
                case 'blindKeep',    s = ['Marked %s %s' S '%s g, b or u (the cursor is on the first).'];
                case 'blindLeft',    s = '%s g, b or u (the cursor is on the first).';
                case 'blindNoClear', s = 'An audit tile waiting for its judgment has nothing to clear: press g, b or u.';
                case 'blindSkipped', s = [S '%s left for their own judgment (audit tiles are labeled one at a time)'];
                case 'blindInspect', s = ['Cell %d' S 'audit tile (blind)\nJudge it without a proposal: g, b or u.\n' ...
                        'Its scores and P(Good) show once you have decided.\nFlag: %s'];
                case 'holdoutApplied', s = '%s set aside as blind holdout tiles%s.';
                case 'holdoutGone',  s = ' (%s listed no longer exist)';
                case 'confirmAudit', s = ['%s: %s confirmed by default will be shown again blind ' ...
                        '(audit tiles, gray border) to measure the review.'];
                case 'enterHeld',    s = ['Enter ignored: release it first. A held Enter repeats, so each ' ...
                        'page needs its own press.'];
                case 'enterTooSoon', s = ['Enter ignored: the page has been on screen for less than %d ms. ' ...
                        'Look at it, then press Enter again.'];
                case 'ctxMapAudit',  s = ['Cell %d: audit cell' D 'judge it with g, b or u (its label and ' ...
                        'scores show once you have)'];
                case 'pairNoTarget', s = ['Point at one cell of the pair (or click it) to label it; the pair ' ...
                        'itself: Enter, k or j.'];
                case 'finalNotWritten', s = ['%s is NOT complete: its final list %s could not be written (%s). ' ...
                        'Nothing changed; fix the cause and mark it complete again.'];
                case 'notCompleteKept', s = ['%s is no longer complete: the kept cells changed (mark it complete ' ...
                        'again to write the new final list).'];
                case 'finalStaled',  s = ['The final list of %s no longer matches it and was renamed %s ' ...
                        '(mark the source complete again to write a new one).'];
                % ---- rescoring edited cells
                case 'finRescore',   s = 'Cells waiting for a score: %s';
                case 'finActRescore', s = 'Rescore now (optional)';
                case 'finRescoreBusy', s = ['%s ' char(8212) ' scoring' E];
                case 'rescoreStart', s = ['Scoring %s edited %s with %s: preparing the image' E];
                case 'rescoreNone',  s = 'Every cell of %s has a score for its position: nothing to rescore.';
                case 'rescoreNoPython', s = 'Cannot rescore here: %s';
                case 'rescoreBusy',  s = 'A rescore is running already (see the status bar).';
                case 'rescoreDeferred', s = ['The new scores wait until the tile drag ends' E];
                case 'rescoreModel', s = 'Scorer: %s.';
                case 'rescoreReadOnly', s = 'This source is read-only here: its cells cannot be rescored.';
                % ---- the Training tab
                case 'trainMeaning', s = ['A fine-tuned scorer changes the meaning of rescore: cells scored with ' ...
                        'it carry its scale, not the shipped scorer''s (RescoreSource names the scorer of each ' ...
                        'cell). Detections keep their old scores until they are rescored, and the cold-start ' ...
                        'proposals assume the shipped scorer''s scale.'];
                case 'trainIdle',    s = 'No fine-tune has run in this window.';
                case 'trainRunning', s = ['Fine-tuning the %s scorer on %s in the background ' char(8212) ...
                        ' review goes on. Log: %s'];
                case 'trainDone',    s = ['Fine-tune finished: the new scorer is the model folder %s. Existing ' ...
                        'detections keep their old scores until they are rescored; Score edited cells uses it ' ...
                        'for this channel kind from now on.'];
                case 'trainDoneNoDeploy', s = 'Fine-tune finished in %s, but no model folder was made: %s';
                case 'trainFailed',  s = 'The fine-tune failed (%s); see %s.';
                case 'trainCanceled', s = 'The fine-tune was canceled.';
                case 'trainCountsText', s = ['Scorer: %s Good, %s Uncertain, %s Bad from %d sections of %d ' ...
                        'animals. Detector: %d of %d sources complete and swept (%d marked complete).'];
                case 'trainCounting', s = ['Counting what can be exported' char(8230) ' (from the saved ' ...
                        'curation files, in the background; review can go on)'];
                case 'trainUpdating', s = ['(updating' char(8230) ')'];
                case 'trainCountingWhy', s = ['counting what can be exported (a moment; the counts appear above).'];
                case 'trainNo2Labels', s = 'there are no Good or Bad labels of this channel kind yet.';
                case 'trainNo2Animals', s = ['the scorer is validated on animals it was not trained on: Good and ' ...
                        'Bad labels of at least 2 animals are needed; there are labels of %d.'];
                case 'trainNo1Sweep', s = ['no source is both complete and swept: %d marked complete, none swept ' ...
                        'for missed cells (the detector learns that every unannotated pixel is background).'];
                case 'trainNo1Complete', s = ['no source is marked complete and swept for missed cells yet (the ' ...
                        'detector learns that every unannotated pixel is background).'];
                case 'trainExporting', s = ['Exporting the %s training set (%s) to %s' E ' the window waits ' ...
                        'until it is written.'];
                case 'trainExported', s = 'Exported the %s training set (%s) to %s in %d s';
                % ---- display
                case 'displayReset', s = ['Display back to the default of %s: brightness x%.2f and gamma %.2f on ' ...
                        'the page limits (chosen from its cells'' crops).'];
                % ---- lab database
                case 'dbMissing',    s = ['The lab database client is not here: %s Nothing is sent; the curation ' ...
                        'files are the same without it.'];
                case 'subjectNoSource', s = 'No source is open: there is no subject to look up.';
                case 'subjectNoName',   s = ['The file name of this section names no subject (SUBJ-ID-<number>), so ' ...
                        'the lab database cannot be asked about it.'];
                case 'subjectNotAsked', s = ['%s: this computer has not asked the lab database about it yet. Press ' ...
                        'Check subjects in the Dataset Manager.'];
                case 'subjectNoClient', s = '%s: nothing is known here. %s';
                case 'subjectAbsent',   s = '%s is not in the lab database.';
                case 'subjectKnown',    s = '%s in the lab database: %s.';
                case 'subjectTags',     s = 'Tags: %s';
                case 'subjectVariables', s = 'Variables: %s';
                case 'subjectNoFacts',  s = 'No tags or variables';
                % ---- assist model and audit report
                case 'assistOff',    s = 'Assist is off in this window: proposals come from the rescore (cold start).';
                case 'assistRead',   s = ['Assist: the folder was read in the background (%d sources); the model ' ...
                        'follows your labels from now on (left panel).'];
                case 'assistReading', s = ['Proposals: rescore (cold start)' S 'reading the folder' E];
                case 'assistCold',   s = ['Proposals: rescore (cold start)' S 'the model starts at %d labels ' ...
                        'with %d of each class; you have %s (%s Good, %s Bad)'];
                case 'assistModel',  s = ['Proposals: model %d' S 'trained on %s labels from %s of %s%s'];
                case 'assistRefitting', s = [S 'refitting' E];
                case 'assistAuc',    s = 'Model AUC %.2f (out of fold) vs rescore alone %.2f';
                case 'assistAucNoBase', s = 'Model AUC %.2f (out of fold)';
                case 'assistAucNone', s = 'Model accuracy: shown after the first fit.';
                case 'assistAgree',  s = 'Judged blind: %s tiles; the proposal matched your decision on %d%%';
                case 'assistAgreeFew', s = 'Agreement: not enough audit tiles yet (%d of 30 judged blind)';
                case 'modelApplied', s = ['Proposals updated (model %d): the pages after this one follow it; ' ...
                        'this page stays as it is.'];
                case 'reportBuilding', s = ['Building the audit report in the background' E ' it appears in the Audit tab.'];
                case 'reportReady',  s = 'The audit report is ready (Audit tab on the right); Save report writes it to the folder.';
                case 'reportSaved',  s = 'Audit report saved in %s: %s (text) and %s (tables).';
                case 'reportNone',   s = ['There is no report to save yet: build it with Audit report' E ' on the left.'];
                case 'reportGenerated', s = 'Report of %s, built %s';
                % ---- map and edits: undo descriptions
                case 'txnMarkMap',   s = 'Mark %s %s (map)';
                case 'txnClearMap',  s = 'Clear %s (map)';
                case 'txnAdd',       s = 'Add a cell at X %.0f, Y %.0f';
                case 'txnMove',      s = 'Move cell %d';
                case 'txnLasso',     s = 'Mark %s %s (lasso)';
                case 'txnExclude',   s = 'Exclusion region (%s)';
                case 'txnRemoveRegion', s = 'Remove exclusion region %d';
                case 'txnApplyRegions', s = 'Apply the exclusion regions';
                case 'txnMerge',     s = 'Merge %s into cell %d';
                case 'txnPairKeep',  s = 'Keep both cells of a close pair (%s)';
                case 'txnNotComplete', s = 'No longer complete';
                % ---- left panel (map)
                case 'sweepItem',    s = 'Sweep for missed cells  (%s)';
                case 'sweepOptional', s = 'optional';
                case 'sweepDoneItem', s = ['done ' K];
                case 'sweepAt',      s = 'at field %d';
                case 'sectionItemDone', s = [K ' %s  (%d%%)'];
                case 'sectionItemPart', s = ['%s  (%d%%)  ' K ' %s'];
                % status bar
                case 'ready',        s = 'Open a folder of sections to start (Open folder at the top left).';
                case 'looking',      s = ['Looking for sections in %s' E];
                case 'noDatasets',   s = 'No section with detections was found in %s.';
                case 'notFolder',    s = 'Not a folder: %s';
                case 'opening',      s = ['Opening %s of %s' E];
                case 'opened',       s = ['Opened %s of %s' S '%s cells, %s to review.'];
                case 'readOnly',     s = 'Read-only: %s Labels cannot be changed in this window.';
                case 'readOnlyShort', s = 'Read-only: this source is open in another session, so labels cannot be changed here.';
                case 'openFailed',   s = 'Could not open %s of %s: %s';
                case 'missingImage', s = 'The image of %s was not found (%s): its tiles are blank.';
                case 'marked',       s = ['Marked %s %s' S 'page %d of %d'];
                case 'cleared',      s = ['Cleared %s' S 'page %d of %d'];
                case 'flagged',      s = 'Flagged %s for later (see the Flagged queue).';
                case 'unflagged',    s = 'Removed the flag from %s.';
                case 'confirmed',    s = ['Marked %s %s' S 'page %d of %d confirmed'];
                case 'advanced',     s = ['Page %d of %d' S 'no labels were applied'];
                case 'undid',        s = 'Undid: %s';
                case 'redid',        s = 'Redid: %s';
                case 'nothingUndo',  s = 'Nothing to undo.';
                case 'nothingRedo',  s = 'Nothing to redo.';
                case 'noTarget',     s = ['Point at a tile (or move the cursor with ' curation.UiText.UP ' ' curation.UiText.DOWN ') first.'];
                case 'lastPage',     s = 'This is the last page to review.';
                case 'pageLeft',     s = ['Page %d left unconfirmed' S 'its untouched tiles stay in the queue (PgUp goes back).'];
                case 'pageShown',    s = ['Page %d of %d' S 'no labels were applied'];
                case 'firstPage',    s = 'This is the first page of this session.';
                case 'noHistory',    s = 'No earlier page in this session yet.';
                case 'saved',        s = 'Saved.';
                case 'allDone',      s = 'Every source in this folder is reviewed.';
                case 'lastSource',   s = 'This is the last source in the folder.';
                case 'firstSource',  s = 'This is the first source in the folder.';
                case 'mode',         s = 'Showing %s.';
                case 'sideNoHold',   s = 'Side by side already shows the other channel.';
                case 'companionHeld', s = 'Showing the other channel while c is held.';
                case 'gain',         s = 'Brightness %.2fx of the default (0 resets it).';
                case 'gamma',        s = 'Gamma %.2fx of the default (0 resets it).';
                case 'evenTilesOn',  s = ['Even tiles on' S 'every cell is shown at the level of a typical cell of this source (t turns it off).'];
                case 'evenTilesOff', s = ['Even tiles off' S 'one contrast for the whole page: a dim cell looks dim.'];
                case 'zoom',         s = ['Tile zoom %d%%' S '%d tiles per page.'];
                case 'showQueue',    s = ['Showing %s' S '%s cells.'];
                case 'note',         s = 'Saved the note of cell %d.';
                case 'selection',    s = '%d tiles selected: g, b, u, f or x applies to all of them (Esc clears).';
                case 'selectionCleared', s = 'Selection cleared.';
                case 'problem',      s = 'Problem: %s';
                case 'repaged',      s = ['%d tiles per page now' S 'page %d of %d'];
                % context line (head and tail joined by DASH)
                case 'ctxActive',    s = ['%s' S 'P %.2f' char(8211) '%.2f' S 'page %d of %d'];
                case 'ctxBlindHead', s = ['Blind tiles' S 'page %d of %d'];
                case 'ctxEnterMark', s = 'Enter: mark the %s untouched %s %s';
                case 'ctxEnterMarkBlind', s = 'Enter: mark the %s untouched %s %s, and %s g, b or u';
                case 'ctxBlindOnly', s = 'judge each tile: g, b or u (%s left; no proposal is shown)';
                case 'ctxBlindLeft', s = '%s g, b or u before the next page';
                case 'ctxEnterNext', s = 'Enter: next page (every tile here is decided)';
                case 'ctxReadOnly',  s = 'Read-only: labels cannot be changed here';
                case 'ctxList',      s = ['%s' S 'page %d of %d'];
                case 'ctxListEnter', s = 'Enter: next page (labels change only where you mark them)';
                case 'ctxListLast',  s = 'Enter: back to the first page of this queue';
                case 'ctxHistory',   s = ['Earlier page %d of %d' S '%s'];
                case 'ctxHistoryEnter', s = ['Enter or PgDn: forward' S 'a click switches Good ' char(8596) ' Bad'];
                case 'ctxEmptyNext', s = ['Nothing left to review in %s' D 'Enter or n: open %s (%s)'];
                case 'ctxEmptyDone', s = ['Nothing left to review in this folder' D 'every source is done'];
                case 'ctxEmptyQueue', s = ['Nothing in %s for %s' D 'choose another queue on the left'];
                case 'ctxNone',      s = ['Open a folder to start' D 'Open folder at the top left'];
                % message panel
                case 'msgNoneTitle', s = 'No folder open';
                case 'msgNoneText',  s = 'Choose a folder of sections. Every section below it that has detections can be reviewed here.';
                case 'msgDoneTitle', s = '%s is reviewed';
                case 'msgDoneNext',  s = 'Next with cells to review: %s of %s (about %s cells). Press n or Enter to open it.';
                case 'msgDoneAll',   s = 'Every source in this folder is reviewed.';
                case 'msgEmptyQueueTitle', s = 'Nothing in %s';
                case 'msgEmptyQueueText',  s = 'There are no cells in this queue for %s. Choose another queue on the left.';
                case 'msgNoDatasetsTitle', s = 'No sections found';
                % undo descriptions (transactions)
                case 'txnMark',      s = 'Mark %s %s (page %d)';
                case 'txnClear',     s = 'Clear %s (page %d)';
                case 'txnFlag',      s = 'Flag %s for later';
                case 'txnUnflag',    s = 'Remove the flag of %s';
                case 'txnConfirm',   s = 'Confirm page %d (%s %s)';
                case 'txnNote',      s = 'Note on cell %d';
                % left panel
                case 'queueItem',    s = '%s  (%s)';
                case 'reviewItem',   s = 'Review  (%s left)';
                case 'bands',        s = ['Left by band: middle %s' S 'likely good %s' S 'likely bad %s'];
                case 'bandsBlind',   s = ['Left by band: middle %s' S 'likely good %s' S 'likely bad %s' S 'audit %s'];
                case 'paceCapped',   s = '1,000+';
                case 'progSource',   s = 'Source %s: %s of %s done (%d%%)';
                case 'progSection',  s = 'Section, all channels: %s of %s (%d%%)';
                case 'progFolder',   s = 'Whole folder: %s of %s (%d%%)';
                case 'paceNone',     s = 'Pace: shown after the first confirmed page.';
                case 'pace',         s = ['Pace: %s cells/min (last %d pages)' S '%s left in %s'];
                case 'paceDone',     s = ['Pace: %s cells/min (last %d pages)' S '%s is done'];
                case 'progFlagged',  s = [S '%s flagged'];
                case 'sectionItem',  s = '%s  (%d%%)';
                case 'sourceLeft',   s = '%s left to review.';
                otherwise
                    error('curation:UiText:unknownId', 'No message "%s".', char(id));
            end
            if ~isempty(varargin)
                s = sprintf(s, varargin{:});
            end
        end

        %% ------------------------------------------------------------------ key map
        function T = keymap()
            %KEYMAP  Every key CellCurator handles: Key, Modifier (as handleKey takes them), Label
            %   (as shown to the user), Action (the button tag action it shares), Description.
            L = curation.UiText.LEFT; R = curation.UiText.RIGHT;
            U = curation.UiText.UP;   D = curation.UiText.DOWN;
            rows = {
                "g",          "",        "g",            "good",        "Label the tile Good (the tile under the pointer, else the cursor; or every selected tile). On the map: the selected cells"
                "b",          "",        "b",            "bad",         "Label the tile Bad"
                "u",          "",        "u",            "uncertain",   "Label the tile Uncertain"
                "f",          "",        "f",            "flag",        "Flag the tile for later, or remove its flag"
                "x",          "",        "x",            "clear",       "Clear the tile's label and flag (back to untouched)"
                "backspace",  "",        "Backspace",    "clear",       "Same as x (in a sweep: the previous field)"
                "return",     "",        "Enter",        "confirm",     "Confirm the page: untouched tiles get the proposed label; next page. On the map: what the line above the map says"
                "space",      "",        "Space",        "confirm",     "Same as Enter"
                "pageup",     "",        "PgUp",         "prev",        "Previous page (still editable). Map: previous pair or field"
                "pagedown",   "",        "PgDn",         "next",        "Next page without confirming: untouched tiles stay in the queue. Map: skip the pair, next field"
                "leftarrow",  "",        string(L),      "cursorLeft",  "Move the cursor one tile left (map: previous pair or field, else pan)"
                "rightarrow", "",        string(R),      "cursorRight", "Move the cursor one tile right (map: skip the pair, next field, else pan)"
                "uparrow",    "",        string(U),      "cursorUp",    "Move the cursor up one row (map: pan)"
                "downarrow",  "",        string(D),      "cursorDown",  "Move the cursor down one row (map: pan)"
                "tab",        "",        "Tab",          "toggleView",  "Switch between the gallery and the map of the section"
                "v",          "",        "v",            "toggleView",  "Same as Tab"
                ".",          "",        ".",            "showOnMap",   "Show the pointed-at (or cursor) cell on the map, selected"
                "s",          "",        "s",            "toolSelect",  "Map: Select tool (click a cell; Shift+click adds; drag pans)"
                "a",          "",        "a",            "toolAdd",     "Map: Add tool (click where a cell was missed; Shift+click snaps)"
                "m",          "",        "m",            "toolMove",    "Map: Move tool (drag a cell to its place; Shift at release snaps)"
                "l",          "",        "l",            "toolLasso",   "Map: Lasso tool (draw around cells)"
                "e",          "",        "e",            "lassoExclude", "After a lasso: make the area an exclusion region"
                "j",          "",        "j",            "merge",       "Merge: the lassoed cells into one, or the close pair on screen (the higher-scored cell is kept)"
                "k",          "",        "k",            "keepBoth",    "Close pairs: keep both cells (two cells)"
                "delete",     "",        "Del",          "regionRemove", "Remove the selected exclusion region"
                "n",          "",        "n",            "nextSource",  "Open the next source that still has cells to review"
                "rightarrow", "control", "Ctrl+" + R,    "sourceNext",  "Next source in the folder (channel, then section)"
                "leftarrow",  "control", "Ctrl+" + L,    "sourcePrev",  "Previous source in the folder"
                "z",          "control", "Ctrl+Z",       "undo",        "Undo the last change; its page comes back on screen"
                "y",          "control", "Ctrl+Y",       "redo",        "Redo the change just undone"
                "s",          "control", "Ctrl+S",       "save",        "Save now (every change is also saved as you go)"
                "o",          "",        "o",            "mode",        "Cycle the display: target, overlay, companion, side by side"
                "c",          "",        "c (hold)",     "companion",   "Show the other channel while the key is held"
                "[",          "",        "[",            "darker",      "Darker tiles"
                "]",          "",        "]",            "brighter",    "Brighter tiles"
                ";",          "",        ";",            "gammaUp",     "Darker mid-tones (gamma up)"
                "'",          "",        "'",            "gammaDown",   "Brighter mid-tones (gamma down)"
                "0",          "",        "0",            "resetDisplay", "Brightness and gamma back to the default of this source (chosen from its cells' crops)"
                "t",          "",        "t",            "evenTiles",   "Even tiles on or off: each tile scaled so its cell shows at a typical level, not too bright or too dark"
                "+",          "",        "+",            "zoomIn",      "Larger tiles (fewer per page); map: zoom in"
                "-",          "",        "-",            "zoomOut",     "Smaller tiles (more per page); map: zoom out"
                "?",          "",        "?",            "help",        "Show or hide this list"
                "escape",     "",        "Esc",          "escape",      "Clear the selection; hide this list. Map: cancel, back to the Select tool"
                };
            T = cell2table(rows, 'VariableNames', {'Key', 'Modifier', 'Label', 'Action', 'Description'});
            for v = 1:width(T)
                T.(v) = string(T.(v));
            end
        end

        function s = cheatSheet(width)
            %CHEATSHEET  The cheat sheet shown with [?]: how review by exception works, the mouse
            %   gestures and every key of keymap() (generated from it, so nothing is missing).
            %   Lines are at most WIDTH characters (default 48, the inspector panel in a monospaced
            %   font); descriptions wrap under themselves (a hanging indent after the key column).
            if nargin < 1, width = 48; end
            T = curation.UiText.keymap();
            W = curation.UiText.wrapText(['Each page proposes one label: the faint border color ' ...
                'of its untouched tiles. Mark only the tiles that differ, then press Enter: every ' ...
                'untouched tile gets the proposed label. A tile with a gray border is an audit tile: ' ...
                'it shows no proposal and needs g, b or u (Enter waits for it).'], width);
            lines = [{'REVIEW BY EXCEPTION'}; cellstr(W); {''; 'MOUSE'}];
            mouse = {
                'Click',       'make the tile the exception; click again: untouched'
                'Right-click', 'Uncertain; again: untouched'
                'Drag',        'the same change on every tile you pass'
                'Shift+click', 'select tiles: keys then act on all of them'
                'Point',       'shows the cell enlarged in the inspector'};
            for k = 1:size(mouse, 1)
                lines = [lines; curation.UiText.keyLines(mouse{k, 1}, mouse{k, 2}, width)]; %#ok<AGROW>
            end
            lines = [lines; {''; 'MAP (Tab shows it)'}];
            mapMouse = {
                'Wheel',       'zoom about the pointer'
                'Drag',        'pan (Select and Add tools)'
                'Click',       'select a cell; Shift+click adds to the selection; on empty space inside an exclusion region: select the region'
                'Dbl-click',   'show the cell in the gallery'
                'Add tool',    'click where a cell was missed'
                'Move tool',   'drag a cell to its place'
                'Lasso tool',  'draw around cells; a bar offers label, exclude and merge'};
            for k = 1:size(mapMouse, 1)
                lines = [lines; curation.UiText.keyLines(mapMouse{k, 1}, mapMouse{k, 2}, width)]; %#ok<AGROW>
            end
            lines = [lines; {''; 'KEYS'}];
            for k = 1:height(T)
                lines = [lines; curation.UiText.keyLines(char(T.Label(k)), char(T.Description(k)), width)]; %#ok<AGROW>
            end
            s = strjoin(lines, newline);
        end

        %% ------------------------------------------------------------------ colors
        function C = colors()
            %COLORS  Label colors (0-255 doubles), shared by the gallery, map and Dataset Manager.
            C = struct();
            C.Good = [0 158 115];
            C.Bad = [213 94 0];
            C.Uncertain = [240 228 66];
            C.Flag = [204 121 167];
            C.Blind = [140 140 140];
            C.Cursor = [255 255 255];
            C.Selection = [86 180 233];
            C.Background = [24 24 24];
            a = curation.UiText.ProposedStrength;
            C.ProposedGood = round(a * C.Good + (1 - a) * C.Background);
            C.ProposedBad = round(a * C.Bad + (1 - a) * C.Background);
            C.ProposedStrength = a;
            C.Unreviewed = [0 114 178];
            C.Exclude = [230 159 0];
            C.Reference = [217 217 217];
            C.DimFactor = curation.UiText.DimFactor;
        end

        function L = mapLegendItems(S)
            %MAPLEGENDITEMS  The legend under the section map: struct array with Name, Kind ("marker":
            %   a point drawn with Marker; "ring": the selection ring; "area": a region outline;
            %   "dashed": the reference strip), Colors (1 x 3, 0-255), Marker (struct Color, Symbol,
            %   Filled for curation.MapMarkers.swatch; [] for the others) and Text. S: the map
            %   markers (curation.MapMarkers; default its defaults). Excluded cells are shown with the
            %   Good marker, dimmed.
            if nargin < 1, S = curation.MapMarkers.defaults(); end
            S = curation.MapMarkers.validate(S);
            C = curation.UiText.colors();
            d = curation.UiText.DimFactor;
            dim = round(d * S.Good.Color + (1 - d) * C.Background);
            ex = S.Good;
            ex.Color = dim;
            L = struct( ...
                'Name',   {'good', 'bad', 'uncertain', 'unreviewed', 'flag', 'excluded', 'selected', ...
                           'region', 'reference'}, ...
                'Kind',   {"marker", "marker", "marker", "marker", "marker", "marker", "ring", "area", "dashed"}, ...
                'Colors', {S.Good.Color, S.Bad.Color, S.Uncertain.Color, S.Unreviewed.Color, S.Flagged.Color, dim, ...
                           C.Selection, C.Exclude, C.Reference}, ...
                'Marker', {S.Good, S.Bad, S.Uncertain, S.Unreviewed, S.Flagged, ex, [], [], []}, ...
                'Text',   {'Good', 'Bad', 'Uncertain', 'to review', 'flagged', ...
                           'excluded (dim)', 'selected', 'exclusion region', 'reference strip'});
        end

        function s = markerClassLabel(cls)
            %MARKERCLASSLABEL  The name of a map marker class (curation.MapMarkers.CLASSES).
            switch char(cls)
                case 'Unreviewed', s = 'To review';
                case 'Flagged',    s = 'Flagged';
                otherwise,         s = char(cls);
            end
        end

        function L = legendItems()
            %LEGENDITEMS  The color legend under the gallery: struct array with Name, Kind
            %   ("border": a tile border of that color; "corner": the corner badge), Colors (n x 3,
            %   0-255: one swatch per row) and Text. CellCurator draws each swatch the way the tiles
            %   show that color.
            C = curation.UiText.colors();
            L = struct( ...
                'Name',   {'good', 'bad', 'uncertain', 'proposed', 'blind', 'flag', 'cursor', 'selection'}, ...
                'Kind',   {"border", "border", "border", "border", "border", "corner", "outline", "outline"}, ...
                'Colors', {C.Good, C.Bad, C.Uncertain, [C.ProposedGood; C.ProposedBad], C.Blind, ...
                           C.Flag, C.Cursor, C.Selection}, ...
                'Text',   {'Good', 'Bad', 'Uncertain', 'proposed (Enter applies it)', 'audit tile: g, b or u', ...
                           'flagged for later', 'cursor', 'selected'});
        end
    end

    methods (Static, Access = private)
        function lines = keyLines(key, desc, width)
            %KEYLINES  "  key        description" with the description wrapped under itself.
            pad = 14;
            W = curation.UiText.wrapText(desc, width - pad);
            lines = cell(numel(W), 1);
            for k = 1:numel(W)
                if k == 1
                    lines{k} = sprintf('  %-11s %s', char(key), char(W(k)));
                else
                    lines{k} = [blanks(pad) char(W(k))];
                end
            end
        end

        function lines = wrapText(txt, width)
            %WRAPTEXT  Words of TXT in lines of at most WIDTH characters (string column).
            words = split(strip(string(txt)));
            lines = strings(0, 1);
            cur = "";
            for w = words'
                if cur == ""
                    cand = w;
                else
                    cand = cur + " " + w;
                end
                if strlength(cand) > width && cur ~= ""
                    lines(end + 1, 1) = cur; %#ok<AGROW>
                    cur = w;
                else
                    cur = cand;
                end
            end
            if cur ~= "", lines(end + 1, 1) = cur; end
        end
    end
end

classdef Proposals
%PROPOSALS  P(Good) proposals for unreviewed detections (pure data in, data out).
%
%   p = curation.Proposals.coldStart(T, sourceKey)
%   p = curation.Proposals.current(T, sourceKey)
%   kind = curation.Proposals.kindOf(sourceKey)
%   c = curation.Proposals.cutpoint(kind)

    methods (Static)

        function p = coldStart(T, sourceKey)
        %COLDSTART  Cold-start P(Good), an N x 1 double in [0,1], one per row of T.
        %   p = 1 ./ (1 + exp(-(rescore - c4))) where c4 is the scorer cutpoint for
        %   "at least 4 of 7 raters agree" (see cutpoint). Rows whose rescore is not
        %   finite use score clamped to [0,1]; rows with neither get 0.5.
            c4 = curation.Proposals.cutpoint(curation.Proposals.kindOf(sourceKey));
            n = height(T);
            p = 0.5 * ones(n, 1);
            if n == 0, return; end
            resc = nan(n, 1);
            if ismember('rescore', T.Properties.VariableNames)
                resc = double(T.rescore(:));
            end
            sc = nan(n, 1);
            if ismember('score', T.Properties.VariableNames)
                sc = double(T.score(:));
            end
            hasR = isfinite(resc);
            hasS = ~hasR & isfinite(sc);
            p(hasR) = 1 ./ (1 + exp(-(resc(hasR) - c4)));
            p(hasS) = min(max(sc(hasS), 0), 1);
        end

        function p = current(T, sourceKey)
        %CURRENT  Best available P(Good), N x 1: ModelP where finite, else coldStart.
            p = curation.Proposals.coldStart(T, sourceKey);
            if ismember('ModelP', T.Properties.VariableNames)
                m = double(T.ModelP(:));
                ok = isfinite(m);
                p(ok) = min(max(m(ok), 0), 1);
            end
        end

        function kind = kindOf(sourceKey)
        %KINDOF  Stain kind of a source key: "pnn" | "pv" | "unknown".
        %   Case-insensitive; trailing digits (the page number) are ignored.
        %   ECM, PNN, WFA -> "pnn"; PV -> "pv"; anything else -> "unknown".
            k = lower(regexprep(char(string(sourceKey)), '\d+$', ''));
            switch k
                case {'ecm', 'pnn', 'wfa'}
                    kind = "pnn";
                case 'pv'
                    kind = "pv";
                otherwise
                    kind = "unknown";
            end
        end

        function c = cutpoint(kind)
        %CUTPOINT  Ordinal scorer cutpoint for "at least 4 of 7 raters agree".
        %   kind is "pnn" | "pv" | "unknown"; unknown (and anything else) gives 0.
            % ---- CUTPOINT TABLE: correct here only ------------------------------
            % Read from the shipped model checkpoints by an earlier review
            % (to be re-checked in Phase 2).
            %   pnn (WFA scorer): -0.170
            %   pv  (PV scorer) : -0.401
            %   unknown         :  0
            % ---------------------------------------------------------------------
            switch lower(char(string(kind)))
                case 'pnn', c = -0.170;
                case 'pv',  c = -0.401;
                otherwise,  c = 0;
            end
        end

    end
end

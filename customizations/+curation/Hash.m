classdef Hash
%HASH  Short content hash (14 hex characters) of numbers and text, in pure MATLAB.
%
%   h = curation.Hash.of(a, b, ...)   string, e.g. "03f1a2c9e07b44"
%
%   Each argument may be numeric, logical, char, string, a cell array of these, or a datetime.
%   Numbers are hashed by their double-precision bytes (so uint32 5 and double 5 hash alike);
%   text by its UTF-8 bytes; every argument also contributes its class and size, so [1 2] and
%   [1;2] or "12" and 12 differ. Two independent polynomial hashes modulo ~2^26 are combined
%   (about 52 bits): meant for fingerprints and version tags, NOT for security.
%
%   Pure MATLAB (no Java), so it gives the same answer on thread-based workers (backgroundPool)
%   and across sessions and releases.

    properties (Constant, Access = private)
        MODS = [67108859 67108837]     % moduli below 2^26 (products stay exact in double)
        BASES = [257 263]
        BLOCK = 4096
    end

    methods (Static)
        function h = of(varargin)
            parts = cell(1, 2 * numel(varargin));
            for k = 1:numel(varargin)
                [b, tag] = curation.Hash.bytesOf(varargin{k});
                parts{2 * k - 1} = uint8([tag 0]);
                parts{2 * k} = b(:)';
            end
            h = string(curation.Hash.bytesHash([parts{:}]));
        end
    end

    methods (Static, Access = private)
        function [b, tag] = bytesOf(x)
            if iscell(x)
                bs = cell(1, numel(x));
                for i = 1:numel(x)
                    [bi, ti] = curation.Hash.bytesOf(x{i});
                    bs{i} = [uint8(ti) 0 bi(:)'];
                end
                b = [bs{:}];
                tag = sprintf('cell%s', mat2str(size(x)));
            elseif isstring(x) || ischar(x)
                s = string(x);
                s(ismissing(s)) = "<missing>";
                if isempty(s)
                    b = uint8([]);
                else
                    b = unicode2native(char(join(s(:), char(31))), 'UTF-8');
                end
                tag = sprintf('text%s', mat2str(size(s)));
            elseif isdatetime(x)
                b = typecast(posixtime(x(:)) * 1, 'uint8');
                tag = sprintf('time%s', mat2str(size(x)));
            elseif isnumeric(x) || islogical(x)
                v = double(x(:));
                v(isnan(v)) = NaN;              % one NaN bit pattern
                b = typecast(v, 'uint8');
                tag = sprintf('num%s', mat2str(size(x)));
            else
                error('curation:Hash:badType', 'Cannot hash a value of class %s.', class(x));
            end
            b = uint8(b);
        end

        function h = bytesHash(b)
            b = double(b(:));
            n = numel(b);
            L = curation.Hash.BLOCK;
            nb = max(1, ceil(n / L));
            b(nb * L) = 0;                      % pad with zeros
            B = reshape(b, L, nb);
            out = zeros(1, 2);
            for j = 1:2
                M = curation.Hash.MODS(j);
                base = curation.Hash.BASES(j);
                [pw, PL] = curation.Hash.powers(j);
                colH = mod(pw' * B, M);         % per block: sum b(i) * base^(L-i) mod M
                hv = 0;
                for c = 1:nb
                    hv = mod(hv * PL + colH(c), M);
                end
                hv = mod(hv * base + mod(n, M), M);
                out(j) = hv;
            end
            h = sprintf('%07x%07x', out(1), out(2));
        end

        function [pw, PL] = powers(j)
            persistent cache
            if isempty(cache), cache = cell(1, 2); end
            if isempty(cache{j})
                M = curation.Hash.MODS(j);
                base = curation.Hash.BASES(j);
                L = curation.Hash.BLOCK;
                p = zeros(L, 1);
                p(L) = 1;
                for i = L - 1:-1:1
                    p(i) = mod(p(i + 1) * base, M);
                end
                cache{j} = struct('pw', p, 'PL', mod(p(1) * base, M));
            end
            pw = cache{j}.pw;
            PL = cache{j}.PL;
        end
    end
end

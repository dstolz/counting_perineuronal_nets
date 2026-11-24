function t = timeText(dt)
%TIMETEXT A zoned datetime as text with its offset and microseconds ("" for NaT).
%   The form the lab database client (labclient.Bundles.timeText) writes, so
%   a provenance record can become an outbox record without converting.
if isnat(dt)
    t = "";
    return
end
if isempty(dt.TimeZone)
    dt.TimeZone = "local";
end
dt.Format = "yyyy-MM-dd'T'HH:mm:ss.SSSSSSxxx";
t = string(dt);
end

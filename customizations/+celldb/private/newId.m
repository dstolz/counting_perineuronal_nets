function id = newId()
%NEWID A random (version 4) uuid, lowercase, from Java's secure generator.
id = lower(string(java.util.UUID.randomUUID().toString()));
end

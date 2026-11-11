# Role source layout

The owner requested src/common, src/client, and src/server during
implementation. All library units now use these directories. Unit names
are unchanged. Compiler search paths, facade source arguments, package
inventory generation, provenance target paths, and the merge plan agree.
The source checker rejects a library unit outside its role directory.

The macOS build passed for common, client and server. Package inventory and
version checks passed for 108 library units. Existing source-size and
client dependency failures remain assigned to their current agents.
The layout does not claim those unfinished checks pass.

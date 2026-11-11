# M00 inventory and provenance

## Source state

The inspected client commit is `709336f542cbedf9ce1ab67d83bddcfd560eb1c0`.
The inspected server commit is `16e2003a9f31648005c5565d118bbd42acf935a8`.
Both source working trees were clean when inspected on 2026-11-11. The
inventory has one row for each tracked regular file: 195 client files and
244 server files. It records the source commit, path, SHA-256 hash, target
path, source license, action, and story. The unit map remains in
`plan/merge-0.30.0-units.tsv`.

The client project carries the Apache License, Version 2.0. The server
project carries the GNU Lesser General Public License, version 2.1, with the
Free Pascal linking exception. The full texts are preserved in `LICENSES/`.
The source NOTICE files are also preserved. Common implementation inputs
have separate rows for each source so that both origins remain visible.

The license relationship for the combined distribution is unresolved. No
combined license is asserted. The inventory records the license of the
source project for each input. Technical merge work can continue while this
question remains open.

## Reference reading

RFC 1928, Sections 3 through 6, specifies the TCP client method negotiation,
request, addressing, and reply procedures. Section 8 describes security
considerations. RFC 1929, Sections 2 and 3, specifies username and password
authentication and its security considerations. The plain-text copies were
retrieved from the RFC Editor on 2026-11-11:

- RFC 1928: https://www.rfc-editor.org/rfc/rfc1928.txt
- RFC 1929: https://www.rfc-editor.org/rfc/rfc1929.txt

`doc/references/README.md` lists both copies and retrieval dates.

## Evidence limits

The inventory is evidence of tracked input coverage and source provenance.
It does not record a test result. Baseline test runs are recorded by the
test owner. Binary or ignored files are not tracked inputs and are not in the
inventory.

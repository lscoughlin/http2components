# TLS-09 shared security matrix

Checked 2026-11-11 on macOS arm64 with FPC 3.2.4. The implementation base is
`f52bdf7d2b50b7a64bb337fa519637043f667019`.

## Reading record

The task read the TLS-09 plan card, bounded matrix, and R1–R3 material. The
RFC reading followed RFC 9113 sections 3.2 and 9.2, RFC 8740 sections 2 and
3, RFC 7301 sections 3.1 and 3.2, RFC 8446 sections 4.1, 4.2, 4.3.2, 4.4,
5, and 6, RFC 5280 sections 4.1, 4.2.1.6, 4.2.1.9, 4.2.1.12, and 6, and
RFC 4514 sections 2 and 3. The RFC Editor references and check date are
recorded in `plan/notes/tls-02-engines-reading.md` and
`plan/notes/tls-08-reading.md`.

The task read the merged provider notes `tls-05-openssl.md` and
`tls-06-tlslib.md`, the client contract note `tls-07-client.md`, the server
reading and acceptance notes `tls-08-reading.md` and
`tls-08-main-acceptance.md`, the common policy and session units, both
provider test programs, both provider factories, and the shared session
contract. The runner uses the common encrypted-buffer session API and the
existing PEM fixtures. It does not use OpenSSL as a runtime peer.

## Runner and case groups

`test/integration/tls/Http2.Tls.Security.Tests.pas` runs O/O, O/T, T/O, and
T/T. Each pair runs TLS 1.2 and TLS 1.3. Case IDs include the pair, version,
scenario, client-auth mode, and client identity state.

- A05 trusted server identity and copied verified peer metadata, unknown CA,
  expired server identity, DNS mismatch, IP SAN success, and IP mismatch.
- A05 trust separation: the server context has its own valid CA trust while
  the client trusts a different CA; the server certificate still fails
  client verification.
- A06 none/request/require with missing, valid, and invalid client identity.
  The server peer is checked for verified metadata before principal use.
- A07 selected `h2`, selected `http/1.1`, and no ALPN selection. The selected
  ALPN, TLS version, and cipher are read from both negotiated session records.

All pump loops have a 12,000-step cap and a 4,000 ms absolute deadline. The
runner aborts both sessions in a `finally` block. There are no external
listeners or network peers.

## Compile record

Build commands, with all dependency roots set to the read-only directories in
the main checkout:

```text
python3 tools/build.py build:common
python3 tools/build.py build:openssl
python3 tools/build.py build:tlslib
python3 -c "import runpy; from pathlib import Path; m=runpy.run_path('tools/build.py'); m['compile_file'](Path('test/integration/tls/Http2.Tls.Security.Tests.pas').resolve(), 'tls-integration-test', tests=True)"
```

All four commands completed successfully. The initial TlsLib build performed
its dependency bootstrap. The final runner compile exited 0 and produced
`bin/aarch64-darwin/default/tls-integration-test/programs/Http2.Tls.Security.Tests`.
The binary was not executed by this task. No runtime cases are reported as
passed here. The coordinator must run the binary under its bounded execution
protocol and record actual outcomes, skips, failures, timeout status, and
cleanup before acceptance.

## Limits

The runner covers provider-session integration over in-memory ciphertext. It
does not prove HTTP/2 request handling, listener behavior, independent peer
conformance, Linux behavior, load capacity, or production readiness. It has
no provider-specific unsupported cases because its required matrix uses
features supported by both providers.

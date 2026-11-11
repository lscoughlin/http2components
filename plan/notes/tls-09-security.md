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
The coordinator ran the first compiled version and it stopped after the first
trusted O/O TLS 1.2 case. The next unknown-CA case raised the expected
`ETlsSessionError` outside the runner's result classification. The runner
now records only verification or alert errors as peer rejection. A timeout,
unexpected terminal state, setup error, or other session error fails the
case.

The expired TLSLib fixture has a valid hostname and matching root issuer. The
runner now uses owned fixtures under
`test/fixtures/tls-integration-security/`. The expired leaf is signed by the
same intermediate as the valid chain control. The leaf includes a DNS SAN,
the server-auth usage, and the intermediate in its transmitted chain. The
client trust anchor is the shared test root. OpenSSL 4.1.0 generated this
local fixture. `openssl verify` confirmed that the expired leaf fails only
because it is expired and the valid control chain verifies. The CLI was used
for fixture generation and certificate-path checks only; it was not a TLS
peer.

The coordinator's first run stopped after the trusted O/O TLS 1.2 case on an
uncaught expected verification error. The second run stopped after seven O/O
TLS 1.2 assertions because the server-preference ALPN case expected `h2`
while the configured server preference was `http/1.1`. The runner now checks
the configured server preference, while the trusted case checks `h2` when
the server lists it first. The coordinator's third run passed all 200 named
assertions in 1.073 seconds. It completed 152 handshake scenarios: 19 per
provider pair and TLS version combination. The executable exited 0 under the
30-second limit. There was no timeout. The coordinator log is
`bin/tls-coordinator/tls09-security-03.log`. Earlier failed logs remain
`bin/tls-coordinator/tls09-security-01.log` and
`bin/tls-coordinator/tls09-security-02.log`.

The fixture tool was `/opt/homebrew/bin/openssl`, version
`OpenSSL 4.1.0 23 Oct 2026`. The command arguments were:

```text
/opt/homebrew/bin/openssl req -new -key test/tls/tlslib/fixtures/server-intermediate.key -subj '/O=http2components test/CN=localhost' -out <temporary>/expired.csr
/opt/homebrew/bin/openssl ca -batch -config <temporary>/ca.cnf -startdate 20150101000000Z -enddate 20160101000000Z -in <temporary>/expired.csr -out test/fixtures/tls-integration-security/expired-server.crt
```

The temporary CA configuration used the existing
`test/fixtures/client/certs/mtls/intermediate.crt` and `intermediate.key`.
It set a critical `CA:false` constraint, digital-signature and key-encipherment
usage, server-auth EKU, and `DNS:localhost` plus `IP:127.0.0.1` SANs. The
certificate and key are synthetic integration-test material. The chain file
is the expired leaf followed by the existing intermediate certificate. The
same chain and key load through both provider identity loaders.

Fixture path checks used these commands with the same CLI:

```text
/opt/homebrew/bin/openssl verify -CAfile test/fixtures/client/certs/mtls/ca.crt -untrusted test/fixtures/client/certs/mtls/intermediate.crt test/fixtures/tls-integration-security/expired-server.crt
/opt/homebrew/bin/openssl verify -CAfile test/fixtures/client/certs/mtls/ca.crt -untrusted test/fixtures/client/certs/mtls/intermediate.crt test/tls/tlslib/fixtures/server-intermediate-chain.crt
```

The expired leaf failed with `error 10 at 0 depth lookup: certificate has
expired`. The valid control returned `OK`. The CLI was used only for local
fixture generation and path checks. Runtime TLS used the installed OpenSSL
3.5.9 library at `/opt/homebrew/opt/openssl@3/lib`.

## Limits

The runner covers provider-session integration over in-memory ciphertext. It
does not prove HTTP/2 request handling, listener behavior, independent peer
conformance, Linux behavior, load capacity, or production readiness. It has
no provider-specific unsupported cases because its required matrix uses
features supported by both providers.

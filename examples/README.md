# Integration examples

These short programs show explicit TLS provider selection through the public
client and server facades. The client examples enable certificate and host
name verification. They do not use an implicit provider or an insecure policy.

| Program | Provider and configuration |
|---|---|
| `tls_openssl.pas` | OpenSSL with system trust. |
| `tls_tlslib.pas` | TlsLib with an explicit CA file and system trust disabled. |
| `tls_dual_role.pas` | One OpenSSL context for both client and server roles. The client trusts the supplied server identity, and the server uses a certificate with a `localhost` subject alternative name. |
| `tls_https_proxy.pas` | Separate OpenSSL contexts for the origin and HTTPS proxy. The origin uses system trust; the proxy uses the supplied CA file. |

Build all examples with `python3 tools/build.py examples`. The integration
programs are written to `bin/<target>/<profile>/examples-integration/programs/`.
The build compiles the examples. It does not run them.

The TLS programs need their selected provider libraries at runtime. Set
`OPENSSL_LIBPATH` for OpenSSL when the library is outside the system search
path. The TlsLib example does not use OpenSSL.

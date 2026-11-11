# TLS-02 coordinator review

The review date is 2026-11-11. The accepted layout revision is `d4f56ab`.
The adapter study is `df0d17e`. The engine study is `7fef7e0`.

## Accepted route

Both provider engines support client and server buffer sessions. The engine
report distinguishes executed cases from source-backed optional features.
The four dependency revisions in that report are the TLS-04 inputs.

The server uses raw asynchronous mORMot sockets with native TLS disabled.
Each listener holds its context. Each accepted connection holds a common
session and a reference to its context. The server adapter owns pending
plaintext until the session accepts it, and pending ciphertext until the raw
socket queue accepts it. It does not use `INetTls.Send`, `NewNetTls`, or a
borrowed `AcceptCert` pointer. No mORMot patch is approved or needed.

The actual poll study proves the transport route with fake sessions. The
engine study proves the provider route separately. TLS-09 still owns real
provider sessions through HTTP client and server transports and all four
provider pairs. Neither study is independent protocol conformance evidence.

## Required implementation details

- The common context exposes enough non-secret immutable policy information
  for role validation, including enabled roles, required client authentication,
  and the context handshake limit. TLS-03 defines that information once.
- A session option distinguishes a default client identity from an explicit
  nil identity selected for a dial. A nil selector result never restores a
  default identity.
- All common policy arrays and returned metadata have defined copy rules.
  Callers cannot mutate context policy through a shared dynamic array.
- The server serializes session calls. The session lock is released before
  a raw write that can call `AfterWrite` again.
- The server checks a fixed accept-time deadline even while input arrives.
  The existing one-second sweep can delay closure by up to one second plus
  scheduling delay. Session advancement also checks the absolute deadline;
  a late handshake cannot become open between sweep callbacks.
- TLS-06 rejects system trust unless it includes and verifies the optional
  TlsLib system-trust implementation. A fixed path-builder depth is not a
  configurable verification-depth capability.
- Resumption and early data remain disabled. Unsupported requested policy
  fails before any transport operation.

## Scope

The source siblings remain read-only. Linux, load, containers, long-running
connections, and full conformance remain deferred to TLS-13. Provider and
role implementation tasks still need their own bounded contract tests.

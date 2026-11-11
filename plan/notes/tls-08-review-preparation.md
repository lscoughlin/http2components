# TLS-08 review preparation

The coordinator read the current async write and read paths on 2026-11-11.
The TLS-08 implementation has not started. These points supplement the
accepted raw poll adapter route in `tls-02-review.md`.

## Plaintext credit and encrypted output

The existing `SendPendingOutput` and `AfterWrite` call
`FCore.ReportWritten(FCore.HandedOutTotal - PendingWriteBytes)`.
Before the TLS replacement, the transport reports application-byte credit.
The raw TLS adapter sends ciphertext, which has a different length.
Subtraction of pending ciphertext from handed-out plaintext is not valid.

The new adapter needs separate plaintext credit and encrypted output
counts. It retains a plaintext suffix that `WritePlaintext` has not accepted.
It retains each encrypted suffix that the raw writer has not accepted.
A raw write retry does not encrypt the same plaintext again. Handshake and
alert records do not count as HTTP plaintext. Application budgets cannot
release bytes before the accepted plaintext reaches the transport's agreed
write boundary.

A conservative credit policy can release a completed plaintext batch only
when its encrypted output has left both adapter and raw socket queues.
A more precise mapping can release partial batches. In either case the
policy has an explicit bounded queue and progress tests. The old total
subtraction is not reused across two different byte domains.

## Callback and close paths

`fOwner.Write` can call `AfterWrite` before it returns. The existing
`FInSend` and `FSendRequested` pattern protects the HTTP send loop from
reentry. The session lock is not held across a raw socket write. A late
write request remains observable when the current send loop exits.

`OnFirstRead` contains an exception boundary because mORMot does not catch
an escaping exception before its I/O worker loop ends. The new raw route
retains an exception boundary for provider errors. `OnRead` passes only
authenticated plaintext to the HTTP/1.1 or HTTP/2 core, after policy and ALPN
checks complete. HTTP/1.1 secure-transport and half-close decisions use the
new TLS session state, since raw mORMot `fSecure` stays nil.

## Deadline clock

`Http2.Server.Async.Sweep` records that `SysUtils.GetTickCount64` uses wall
time on this Darwin build. The existing server accept and sweep clocks use
`mormot.core.os.GetTickCount64`. All TLS start, advance, and sweep values use
the same monotonic clock. The accepted study uses the absolute accept-time
deadline and the periodic sweep, including busy peers that send fragments.
It snapshots handles and validates them before removal. It does not keep
an unprotected pointer across removal or reuse.

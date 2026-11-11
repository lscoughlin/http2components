{**
---
license: Apache-2.0 OR (LGPL-2.1-only WITH Independent-modules-exception)
copyright: Copyright 2026 Liam Seamus Coughlin
keywords: tls, session, buffers
notes:
  - This unit defines TLS session operations and negotiated metadata.
---
}
unit Http2.Common.Tls.Session;
{$mode delphi}{$H+}{$interfaces com}
interface
uses SysUtils, Http2.Common.Tls.Types, Http2.Common.Tls.Identity,
  Http2.Common.Tls.Policy;
type
  TTlsNegotiatedInfo = record
    Role: TTlsRole;
    Version: TTlsVersion;
    CipherName, SelectedAlpn: string;
    PeerCertificate: ITLSPeerCertificate;
    Resumed: Boolean;
  end;
  TTlsProgress = record
    State: TTlsSessionState;
    NeedInput, NeedOutput, MadeProgress: Boolean;
  end;
  ITLSSession = interface(IInterface)
    ['{B7C805A9-BC07-47C6-B8C3-E6E5D1AA2303}']
    function State: TTlsSessionState;
    { Accepts up to ACount bytes from ABuffer[AOffset]. The caller retains every
      byte beyond the returned count. The maximum accepted prefix is 16 KiB.
      Zero count is valid. A bad range raises tecProtocol and leaves state
      unchanged. Feed remains valid while closing to accept peer close data.
      Feed is invalid after closed or failed state. }
    function FeedEncrypted(const ABuffer: TBytes; const AOffset, ACount: SizeInt): SizeInt;
    { Copies queued ciphertext into the existing destination range. The method
      does not resize ABuffer. The caller owns copied bytes after return.
      Pending fatal-alert output remains drainable in failed state until Abort. }
    function DrainEncrypted(var ABuffer: TBytes; const AOffset, ACapacity: SizeInt): SizeInt;
    { Accepts up to ACount plaintext bytes. Accepted bytes must not be submitted
      again. A zero result means no capacity or the session is not open. A bad
      range raises tecProtocol and leaves state unchanged. }
    function WritePlaintext(const ABuffer: TBytes; const AOffset, ACount: SizeInt): SizeInt;
    { Copies available plaintext into the existing destination range. Zero means
      no plaintext is ready; State distinguishes open, authenticated close, and
      failure. Buffered plaintext is returned before a terminal error. On close,
      zero means authenticated close. On failure, zero available bytes raises the
      stored ETlsSessionError. }
    function ReadPlaintext(var ABuffer: TBytes; const AOffset, ACapacity: SizeInt): SizeInt;
    { Advances without waiting. AMonotonicMs is an absolute monotonic time.
      The effective deadline is the earlier context and role deadline. Input
      does not restart the deadline. }
    function Advance(const AMonotonicMs: Int64): TTlsProgress;
    { EOF is abrupt transport closure. A non-closed TLS session becomes failed.
      Buffered plaintext remains readable before the stored truncation error. }
    procedure NotifyTransportEof;
    { Starts TLS close_notify. Queued ciphertext remains drainable while closing. }
    procedure BeginShutdown;
    { Cancellation is prompt and terminal. All buffers are discarded. }
    procedure Abort;
    { Raises ETlsSessionError until State is open. Failed and closed sessions
      remain terminal and cannot return negotiated data. }
    function NegotiatedInfo: TTlsNegotiatedInfo;
  end;
implementation
end.

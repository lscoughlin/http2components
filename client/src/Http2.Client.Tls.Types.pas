{**
---
license: Apache-2.0 OR (LGPL-2.1-only WITH Independent-modules-exception)
copyright: Copyright 2026 Liam Seamus Coughlin
keywords: http2, client, tls
notes:
  - This unit is part of the imported client transport.
---
}
unit Http2.Client.Tls.Types;

{$mode delphi}{$H+}
{$interfaces com}

interface

uses
  SysUtils, Classes, BaseUnix, Sockets, Http2.Client.Errors,
  Http2.Client.Proxy.Types, Http2.Client.IdentityHandle,
  Http2.Client.ClientCert;

const
  /// the single ALPN protocol this client offers in strict mode (RFC 7540
  /// section 3.3)
  cHttp2AlpnProtocol = 'h2';
  /// HTTP/1.1's ALPN name, offered only when the caller enables fallback
  cHttp11AlpnProtocol = 'http/1.1';
  /// the ALPN offer in strict mode (fallback off): "h2" only
  cHttp2AlpnOffer: array[0..0] of string = (cHttp2AlpnProtocol);
  /// the ALPN offer when HTTP/1.1 fallback is on (doc/design/fallback.md
  /// "Negotiation", step 2)
  cHttp2Http1AlpnOffer: array[0..1] of string =
    (cHttp2AlpnProtocol, cHttp11AlpnProtocol);
  /// default connect/read/write deadline when none is set explicitly
  cDefaultSocketTimeoutMs = 30000;

type
  /// how the client treats a cleartext ("http") origin (doc/design/
  /// fallback.md "Factory surface").  ctReject is the default: a cleartext
  /// request raises instead of silently sending bytes in the clear.
  /// ctHttp1 speaks cleartext HTTP/1.1 from the first byte, with no Upgrade
  /// probe.
  // Declared here, not in Http2.Client.Messages.pas: the transport layer acts on the
  // policy, and Http2.Client.Messages already uses this unit for IHttp2Socket, so a
  // declaration there would be a circular unit reference.  Http2.Client.Messages
  // re-exports these as aliases for callers that only use that unit.
  TClearTextPolicy = (ctReject, ctPriorKnowledge, ctUpgrade, ctHttp1);

  /// the transport selected for one origin (doc/design/fallback.md)
  TNegotiatedProtocol = (npHttp2Tls, npHttp2Cleartext, npHttp1Tls,
    npHttp1Cleartext);

  IHttp2Socket = interface;   // forward: declared in full just below

  /// implemented by a socket factory that also understands cleartext and the
  /// HTTP/1.1 fallback.  The base IHttp2SocketFactory (declared in
  /// Http2.Client) predates S13 and only knows "dial TLS, speak h2"; the
  /// client checks for this extended contract with Supports() so an injected
  /// test factory keeps working unchanged.
  ICleartextSocketFactory = interface
    ['{C13A0001-0000-4000-8000-000000000001}']
    /// dial AHost:APort for AScheme and return the socket plus the protocol
    /// the transport is committed to.  For TLS the protocol follows the ALPN
    /// result; for cleartext it follows APolicy.
    function DialProtocol(const AHost: string; const APort: Word;
      const AScheme: string; const AHttp1Fallback: Boolean;
      const APolicy: TClearTextPolicy; const ATimeoutMs: Integer;
      out AProtocol: TNegotiatedProtocol): IHttp2Socket;
  end;

  /// a blocking, connected byte stream carrying HTTP/2 frames
  // - Read returns the number of bytes read and returns 0 only at end of
  //   stream; it never assumes one transport read yields the whole request
  IHttp2Socket = interface
    function Read(var ABuffer; ACount: Integer): Integer;
    function Write(const ABuffer; ACount: Integer): Integer;
    procedure Close;
    function GetConnected: Boolean;
    function GetConnectTimeoutMs: Integer;
    procedure SetConnectTimeoutMs(const AValue: Integer);
    function GetReadTimeoutMs: Integer;
    procedure SetReadTimeoutMs(const AValue: Integer);
    function GetWriteTimeoutMs: Integer;
    procedure SetWriteTimeoutMs(const AValue: Integer);
    property Connected: Boolean read GetConnected;
    property ConnectTimeoutMs: Integer read GetConnectTimeoutMs write SetConnectTimeoutMs;
    property ReadTimeoutMs: Integer read GetReadTimeoutMs write SetReadTimeoutMs;
    property WriteTimeoutMs: Integer read GetWriteTimeoutMs write SetWriteTimeoutMs;
  end;

/// encode an ALPN protocol list in wire form: each entry is one length byte
// followed by its bytes; ['h2'] encodes as 0x02,0x68,0x32
function AlpnProtocolList(const AProtocols: array of string): TBytes;

/// decode a selected ALPN protocol name from raw bytes; returns empty when none was selected
function AlpnSelectedName(const AData: PByte; const ALen: Cardinal): string;

/// verify the negotiated ALPN protocol is exactly "h2", else raise
// EHttpProtocolError; a peer that selected nothing or "http/1.1" must fail
// here rather than silently continue on HTTP/1.1
procedure RequireH2Alpn(const AData: PByte; const ALen: Cardinal);

/// encode the ALPN offer for the caller's fallback policy: "h2" when fallback
// is off (the strict default), "h2" then "http/1.1" when it is on
// (doc/design/fallback.md "Negotiation")
function AlpnOfferFor(const AHttp1Fallback: Boolean): TBytes;
function SecureRandomCardinal: Cardinal;

/// normalise a selected ALPN name to one of "h2", "http/1.1" or "" (nothing
// selected, or a protocol this client does not know) so the caller can choose
// a codec (doc/design/fallback.md "Negotiation")
function AlpnNegotiatedName(const AName: string): string;

/// Map a client ALPN result to the selected HTTP codec. Empty ALPN is
/// HTTP/1.1 only when fallback is enabled.
function ProtocolForTlsAlpn(const AName: string;
  const AHttp1Fallback: Boolean): TNegotiatedProtocol;

/// read exactly ACount bytes, or up to EOF; returns the byte count (0 only at
// immediate EOF) and raises EHttpTimeout when the deadline expires
procedure SetSocketTimeout(AFd, ALevel, AOption, ATimeoutMs: Integer);
function SocketTimedOut: Boolean;

function SocketReadFully(AFd, ACount, ATimeoutMs: Integer;
  var ABuffer): Integer;

/// like SocketReadFully, but a timeout after some bytes returns those bytes
// - a timeout before any byte raises EHttpTimeout; no consumed byte is lost
function SocketReadPartial(AFd, ACount, ATimeoutMs: Integer;
  var ABuffer): Integer;

/// write all ACount bytes, raising EHttpTimeout when the deadline expires
function SocketWriteFully(AFd, ACount, ATimeoutMs: Integer;
  const ABuffer): Integer;

type
  /// a socket that can return whatever is available instead of insisting on
  /// the full count (IHttp2Socket.Read reads exactly ACount bytes or up to
  /// EOF).  A TLS layer carried over another stream needs this: records arrive
  /// in arbitrary sizes and waiting for a full buffer would stall the
  /// handshake.
  IPartialReader = interface
    ['{7B1D5E02-9F6A-4C57-8A31-5D2E0C4A9B21}']
    /// block until at least one byte is available, then return between 1 and
    /// ACount bytes; 0 means end of stream
    function ReadSome(var ABuffer; ACount: Integer): Integer;
  end;

  /// implemented by a socket that can tell, without blocking, whether input
  /// is already waiting on the wire (an idle HTTP/1.1 connection must not
  /// hold unread bytes before it is reused)
  IPendingInput = interface
    ['{C3A1E5B2-6D47-4F9A-8E21-5B7D0A9C1E02}']
    /// True when a read would not block; a closed peer also reports True
    function HasPendingInput: Boolean;
  end;

  /// implemented by a socket whose blocked read another thread can end early
  // - the connection thread blocks in a read for one poll interval. A frame that
  //   another thread queues in that time would wait for the end of the interval,
  //   so the thread that queues it calls InterruptRead. A socket without this
  //   contract keeps the timed read
  IReadInterrupt = interface
    ['{4E0B7A36-2C51-4D8F-9B64-7A13C5E8F0D2}']
    /// prepare the wake channel; the caller calls it once, before any read
    procedure EnableInterrupt;
    /// end a blocked or the next read at once with EHttpTimeout, as an idle
    // poll ends; callable from any thread and a no-op before EnableInterrupt
    procedure InterruptRead;
  end;

  /// implemented by a socket factory that dials through a per-request proxy
  /// (doc/design/proxy.md).  A factory that lacks it is dialled without a
  /// proxy, as before.
  IProxySocketFactory = interface
    ['{7B1D5E02-9F6A-4C57-8A31-5D2E0C4A9B22}']
    /// like ICleartextSocketFactory.DialProtocol; AProxy nil dials directly
    function DialProtocolVia(const AHost: string; const APort: Word;
      const AScheme: string; const AHttp1Fallback: Boolean;
      const APolicy: TClearTextPolicy; const ATimeoutMs: Integer;
      const AProxy: IProxy;
      out AProtocol: TNegotiatedProtocol): IHttp2Socket;
  end;

  /// implemented by a socket factory that can dial a connection which will
  /// speak HTTP/1.1 only, as a WebSocket needs (doc/design/websocket.md).  TLS
  /// offers "http/1.1" alone in ALPN; a peer answering "h2" is refused, a peer
  /// without ALPN support is accepted.  AProxy nil dials directly.
  IHttp1SocketFactory = interface
    ['{7B1D5E02-9F6A-4C57-8A31-5D2E0C4A9B23}']
    function DialHttp1(const AHost: string; const APort: Word;
      const AScheme: string; const ATimeoutMs: Integer;
      const AProxy: IProxy): IHttp2Socket;
  end;

  /// implemented by a socket factory that takes the origin identity per dial
  /// (doc/design/mtls.md "Selector and proxy identity"): the pool asks the
  /// selector outside its lock and hands the answer down.  AIdentity nil
  /// presents no certificate; the factory's own identity is not used.
  IIdentitySocketFactory = interface
    ['{7B1D5E02-9F6A-4C57-8A31-5D2E0C4A9B24}']
    function DialProtocolViaAs(const AHost: string; const APort: Word;
      const AScheme: string; const AHttp1Fallback: Boolean;
      const APolicy: TClearTextPolicy; const ATimeoutMs: Integer;
      const AProxy: IProxy; const AIdentity: IClientIdentity;
      const AIdentityExplicit: Boolean;
      out AProtocol: TNegotiatedProtocol): IHttp2Socket;
    function DialHttp1As(const AHost: string; const APort: Word;
      const AScheme: string; const ATimeoutMs: Integer;
      const AProxy: IProxy; const AIdentity: IClientIdentity;
      const AIdentityExplicit: Boolean): IHttp2Socket;
  end;

  /// Supplies a stable TLS-context discriminator for client connection keys.
  ITlsContextPoolKey = interface
    ['{9A918EE5-9355-48F1-A86A-0933FD078708}']
    function TlsContextPoolKey: string;
  end;

implementation

uses
  Http2.Client.SigPipe;

function AlpnProtocolList(const AProtocols: array of string): TBytes;
var
  i, n, p: Integer;
  s: UTF8String;
begin
  Result := nil;
  n := 0;
  for i := 0 to High(AProtocols) do
  begin
    if Length(AProtocols[i]) > 255 then
      raise EHttpProtocolError.Create('ALPN protocol name longer than 255 bytes');
    Inc(n, 1 + Length(AProtocols[i]));
  end;
  SetLength(Result, n);
  p := 0;
  for i := 0 to High(AProtocols) do
  begin
    s := UTF8String(AProtocols[i]);
    Result[p] := Byte(Length(s));
    Inc(p);
    if Length(s) > 0 then
    begin
      Move(s[1], Result[p], Length(s));
      Inc(p, Length(s));
    end;
  end;
end;

function AlpnSelectedName(const AData: PByte; const ALen: Cardinal): string;
var
  i: Cardinal;
  s: AnsiString;
begin
  if (AData = nil) or (ALen = 0) then
  begin
    Result := '';
    Exit;
  end;
  SetLength(s, ALen);
  for i := 0 to ALen - 1 do
    s[i + 1] := AnsiChar(AData[i]);
  Result := string(s);
end;

procedure RequireH2Alpn(const AData: PByte; const ALen: Cardinal);
var
  Selected: string;
begin
  Selected := AlpnSelectedName(AData, ALen);
  if Selected <> cHttp2AlpnProtocol then
    raise EHttpProtocolError.CreateFmt(
      'peer did not negotiate ALPN "%s" (selected "%s")',
      [cHttp2AlpnProtocol, Selected]);
end;

function AlpnOfferFor(const AHttp1Fallback: Boolean): TBytes;
begin
  if AHttp1Fallback then
    Result := AlpnProtocolList(cHttp2Http1AlpnOffer)
  else
    Result := AlpnProtocolList(cHttp2AlpnOffer);
end;

function AlpnNegotiatedName(const AName: string): string;
begin
  if (AName = cHttp2AlpnProtocol) or (AName = cHttp11AlpnProtocol) then
    Result := AName
  else
    Result := '';
end;

function ProtocolForTlsAlpn(const AName: string;
  const AHttp1Fallback: Boolean): TNegotiatedProtocol;
begin
  if AName = cHttp2AlpnProtocol then
    Exit(npHttp2Tls);
  if AHttp1Fallback and
     ((AName = cHttp11AlpnProtocol) or (AName = '')) then
    Exit(npHttp1Tls);
  raise EHttpProtocolError.CreateFmt(
    'peer did not negotiate an allowed TLS ALPN protocol (selected "%s")',
    [AName]);
end;


procedure SetSocketTimeout(AFd, ALevel, AOption, ATimeoutMs: Integer);
var
  tv: TTimeVal;
begin
  tv.tv_sec := ATimeoutMs div 1000;
  tv.tv_usec := (ATimeoutMs mod 1000) * 1000;
  fpSetSockOpt(AFd, ALevel, AOption, @tv, SizeOf(tv));
end;

function SocketTimedOut: Boolean;
var
  e: Integer;
begin
  e := fpGetErrno;
  Result := (e = ESysEAGAIN) or (e = ESysEWOULDBLOCK);
end;


function SocketReadFully(AFd, ACount, ATimeoutMs: Integer;
  var ABuffer): Integer;
var
  n: ssize_t;
  base: PByte;
begin
  if ACount <= 0 then
    Exit(0);
  SetSocketTimeout(AFd, SOL_SOCKET, SO_RCVTIMEO, ATimeoutMs);
  base := PByte(@ABuffer);
  Result := 0;
  while Result < ACount do
  begin
    n := fpRecv(AFd, base + Result, ACount - Result, 0);
    if n > 0 then
      Inc(Result, n)
    else if n = 0 then
      Exit // EOF: return whatever was read so far
    else if SocketTimedOut then
      raise EHttpTimeout.CreateFmt('read timed out after %d ms', [ATimeoutMs])
    else if fpGetErrno = ESysEINTR then
      Continue
    else
      raise EHttpConnectionClosed.CreateFmt('socket read failed (errno %d)',
        [fpGetErrno]);
  end;
end;

function SocketReadPartial(AFd, ACount, ATimeoutMs: Integer;
  var ABuffer): Integer;
var
  n: ssize_t;
  base: PByte;
begin
  if ACount <= 0 then
    Exit(0);
  SetSocketTimeout(AFd, SOL_SOCKET, SO_RCVTIMEO, ATimeoutMs);
  base := PByte(@ABuffer);
  Result := 0;
  while Result < ACount do
  begin
    n := fpRecv(AFd, base + Result, ACount - Result, 0);
    if n > 0 then
      Inc(Result, n)
    else if n = 0 then
      Exit
    else if SocketTimedOut then
    begin
      if Result > 0 then
        Exit;                 // keep the consumed bytes; the caller reads on
      raise EHttpTimeout.CreateFmt('read timed out after %d ms', [ATimeoutMs]);
    end
    else if fpGetErrno = ESysEINTR then
      Continue
    else
      raise EHttpConnectionClosed.CreateFmt('socket read failed (errno %d)',
        [fpGetErrno]);
  end;
end;

function SocketWriteFully(AFd, ACount, ATimeoutMs: Integer;
  const ABuffer): Integer;
var
  n: ssize_t;
  base: PByte;
begin
  if ACount <= 0 then
    Exit(0);
  SetSocketTimeout(AFd, SOL_SOCKET, SO_SNDTIMEO, ATimeoutMs);
  base := PByte(@ABuffer);
  Result := 0;
  while Result < ACount do
  begin
    n := fpSend(AFd, base + Result, ACount - Result, cMsgNoSignal);
    if n > 0 then
      Inc(Result, n)
    else if SocketTimedOut then
      raise EHttpTimeout.CreateFmt('write timed out after %d ms', [ATimeoutMs])
    else if fpGetErrno = ESysEINTR then
      Continue
    else
      raise EHttpConnectionClosed.CreateFmt('socket write failed (errno %d)',
        [fpGetErrno]);
  end;
end;

function SecureRandomCardinal: Cardinal;
var
  H: THandle;
  Done, N: Integer;
begin
  H := FileOpen('/dev/urandom', fmOpenRead or fmShareDenyNone);
  if H < 0 then
    raise EHttpConnectionError.Create('the operating system random source is unavailable');
  try
    Done := 0;
    while Done < SizeOf(Result) do
    begin
      N := FileRead(H, PByte(@Result)[Done], SizeOf(Result) - Done);
      if N < 0 then
      begin
        if fpGetErrno = ESysEINTR then Continue;
        raise EHttpConnectionError.Create('the operating system random source failed');
      end;
      if N = 0 then
        raise EHttpConnectionError.Create('the operating system random source returned incomplete data');
      Inc(Done, N);
    end;
  finally
    FileClose(H);
  end;
end;

end.

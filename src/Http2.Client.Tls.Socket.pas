{**
---
license: Apache-2.0 OR (LGPL-2.1-only WITH Independent-modules-exception)
copyright: Copyright 2026 Liam Seamus Coughlin
keywords: http2, client, tls
notes:
  - This unit is part of the imported client transport.
---
}
unit Http2.Client.Tls.Socket;

{$mode delphi}{$H+}
{$modeswitch advancedrecords}
{$interfaces com}

interface

uses
  SysUtils, Classes, Sockets, BaseUnix, mormot.core.base, mormot.core.os,
  mormot.lib.openssl11, Http2.Client.Errors, Http2.Client.Proxy.Types,
  Http2.Client.Tls.Types, Http2.Client.ClientCert;

function DialProxyTlsSocket(const ATransport: IHttp2Socket;
  const AHost: string; const AInsecure: Boolean; const ACACertFile: string;
  const AIdentity: IClientIdentity; const ATimeoutMs: Integer): IHttp2Socket;

type
  /// TLS socket over an existing connected IHttp2Socket (ALPN "h2").
  TTlsSocket = class(TInterfacedObject, IHttp2Socket, IPartialReader)
  private
    /// True when OpenSSL uses memory BIOs over another byte stream.
    FStreamMode: Boolean;
    FRbio: PBIO;
    FWbio: PBIO;
    FEofFed: Boolean;
    FTransport: IHttp2Socket;
    FHost: string;
    FInsecure: Boolean;
    FCACertFile: string;
    FCtx: PSSL_CTX;
    FSsl: PSSL;
    FHandshaked: Boolean;
    FSelectedProtocol: string;
    FAlpnOffer: TBytes;
    FRequireH2: Boolean;
    FIdentity: IClientIdentity;
    /// True after application data has been read.
    FReadAny: Boolean;
    /// True once the server sent a CertificateRequest
    FCertRequested: Boolean;
    FConnectTimeoutMs: Integer;
    FReadTimeoutMs: Integer;
    FWriteTimeoutMs: Integer;
    procedure BioFlush;
    function BioFeed: Boolean;
    function StreamHandshake(const ASsl: PSSL): Integer;
    procedure RaiseIfClientAuthRejected(const AErr: Integer);
    procedure ProbeRejectionAfterWrite;
  protected
    // --- crypto seams (overridden by tests) ---
    function CreateSslContext: PSSL_CTX; virtual;
    procedure DestroySslContext; virtual;
    function CreateSslHandle(const ACtx: PSSL_CTX): PSSL; virtual;
    procedure DestroySslHandle; virtual;
    function ApplyAlpnProtos(const ACtx: PSSL_CTX): Integer; virtual;
    procedure ApplyVerifyMode(const ACtx: PSSL_CTX; const AMode: Integer); virtual;
    /// install the client identity (leaf, chain, key) on the per-dial context
    procedure ApplyClientIdentity(const ACtx: PSSL_CTX); virtual;
    function ApplyHostnameVerification(const ASsl: PSSL;
      const AHost: string): Integer; virtual;
    function ApplySniHost(const ASsl: PSSL;
      const AHost: string): Integer; virtual;
    function BindSocket(const ASsl: PSSL; const AFd: Integer): Integer; virtual;
    function HandshakeConnect(const ASsl: PSSL): Integer; virtual;
    function SelectedAlpnBytes(const ASsl: PSSL): TBytes; virtual;
    function LastSslError(const ASsl: PSSL; const AResult: Integer): Integer; virtual;
    /// drain the OpenSSL error queue after an SSL_ERROR_SSL and return the
    /// reason code of its last entry (0 when empty)
    function TakeSslReason: Cardinal; virtual;
    function SslReadBytes(const ASsl: PSSL; const ABuffer: Pointer;
      const ACount: Integer): Integer; virtual;
    function SslWriteBytes(const ASsl: PSSL; const ABuffer: Pointer;
      const ACount: Integer): Integer; virtual;
    procedure SslShutdown(const ASsl: PSSL); virtual;
    function GetSocketFd: Integer; virtual;
  public
    constructor Create(const ATransport: IHttp2Socket; const AHost: string;
      const AInsecure: Boolean = False; const ACACertFile: string = '';
      const AIdentity: IClientIdentity = nil);
    destructor Destroy; override;
    /// perform the TLS handshake and verify ALPN; raises on failure
    procedure Establish;
    /// dial, connect, and TLS-wrap in one call; the insecure flag is the
    /// explicit verify-off toggle (default False = verify the peer)
    class function Dial(const AHost: string; const APort: Word;
      const AInsecure: Boolean = False;
      const AConnectTimeoutMs: Integer = cDefaultSocketTimeoutMs;
      const ACACertFile: string = ''; const AProxyHost: string = '';
      const AProxyPort: Word = 0;
      const AIdentity: IClientIdentity = nil): IHttp2Socket;
    /// Dial and TLS-wrap with the caller's ALPN list. The caller applies policy.
    class function DialWithAlpn(const AHost: string; const APort: Word;
      const AAlpnOffer: TBytes; const AInsecure: Boolean = False;
      const AConnectTimeoutMs: Integer = cDefaultSocketTimeoutMs;
      const ACACertFile: string = ''; const AProxyHost: string = '';
      const AProxyPort: Word = 0;
      const AIdentity: IClientIdentity = nil): IHttp2Socket;
    /// Dial a cleartext TCP socket for h2c prior knowledge.
    class function DialCleartext(const AHost: string; const APort: Word;
      const AConnectTimeoutMs: Integer = cDefaultSocketTimeoutMs;
      const AProxyHost: string = '';
      const AProxyPort: Word = 0): IHttp2Socket;
    /// override the ALPN offer this socket will send in Establish; ignored by
    /// the Dial overloads, which set it for you
    procedure SetAlpnOffer(const AOffer: TBytes);
    /// Dial through AProxy and negotiate its tunnel before origin TLS.
    // - AIdentity goes to the origin leg only, never to an https proxy;
    //   AProxyIdentity goes to the TLS leg of an https proxy only
    class function DialVia(const AHost: string; const APort: Word;
      const AInsecure: Boolean; const AConnectTimeoutMs: Integer;
      const ACACertFile: string; const AProxy: IProxy;
      const AIdentity: IClientIdentity = nil;
      const AProxyIdentity: IClientIdentity = nil): IHttp2Socket;
    class function DialWithAlpnVia(const AHost: string; const APort: Word;
      const AAlpnOffer: TBytes; const AInsecure: Boolean;
      const AConnectTimeoutMs: Integer; const ACACertFile: string;
      const AProxy: IProxy; const AIdentity: IClientIdentity = nil;
      const AProxyIdentity: IClientIdentity = nil): IHttp2Socket;
    class function DialCleartextVia(const AHost: string; const APort: Word;
      const AConnectTimeoutMs: Integer; const AProxy: IProxy;
      const AInsecure: Boolean = False; const ACACertFile: string = '';
      const AProxyIdentity: IClientIdentity = nil): IHttp2Socket;
    function ReadSome(var ABuffer; ACount: Integer): Integer;
    property StreamMode: Boolean read FStreamMode write FStreamMode;
    property Insecure: Boolean read FInsecure;
    /// the identity installed on the per-dial context; nil presents none
    property Identity: IClientIdentity read FIdentity;
    /// PEM bundle used to verify the peer; '' = the system trust store
    property CACertFile: string read FCACertFile;
    property SelectedProtocol: string read FSelectedProtocol;
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

implementation

uses
  Http2.Client.Tls.Tunnel, Http2.Client.Tls.Plain, Http2.Client.SigPipe;

const
  SSL_R_SSLV3_ALERT_HANDSHAKE_FAILURE = 1040;
  cSslReasonMask = $7FFFFF;
  cHandshakeContentType = 22;
  cMsgCertificateRequest = 13;

type
  TSslMsgCallback = procedure(write_p, version, content_type: Integer;
    buf: Pointer; len: PtrUInt; ssl: PSSL; arg: Pointer); cdecl;
  // SSL_set_msg_callback and SSL_set_msg_callback_arg are macros over these
  TSslCallbackCtrl = function(ssl: PSSL; cmd: Integer;
    fp: Pointer): PtrInt; cdecl;
  TSslCtrl = function(ssl: PSSL; cmd: Integer; larg: PtrInt;
    parg: Pointer): PtrInt; cdecl;

const
  SSL_CTRL_SET_MSG_CALLBACK = 15;
  SSL_CTRL_SET_MSG_CALLBACK_ARG = 16;

var
  GSslCallbackCtrl: TSslCallbackCtrl;
  GSslCtrl: TSslCtrl;
  GMsgCallbackResolved: Boolean;

/// the address of an optional libssl entry the mormot bindings do not expose,
// or nil when it cannot be resolved
function ResolveSslProc(const AName: PAnsiChar): Pointer;
var
  Dir: string;
  Lib: TLibHandle;
begin
  Result := nil;
  Dir := GetEnvironmentVariable('OPENSSL_LIBPATH');
  if Dir <> '' then
    Dir := IncludeTrailingPathDelimiter(Dir);
  Lib := LibraryOpen(Dir + LIB_SSL3);
  if Lib <> 0 then
    Result := LibraryResolve(Lib, AName);
end;

/// notes a CertificateRequest from the server on the owning TTlsSocket
procedure NoteHandshakeMessage(write_p, version, content_type: Integer;
  buf: Pointer; len: PtrUInt; ssl: PSSL; arg: Pointer); cdecl;
begin
  if (write_p = 0) and (content_type = cHandshakeContentType) and (len >= 1) and
     (arg <> nil) and (PByte(buf)^ = cMsgCertificateRequest) then
    TTlsSocket(arg).FCertRequested := True;
end;

{ routed dialing }

/// connect AHost:APort through AProxy (nil = direct).  The result is the
/// socket the origin protocol runs on: after a CONNECT or SOCKS5 tunnel it is
/// a transparent byte stream to the origin.  AStream is True when that socket
/// is not a plain TCP socket (an https proxy), so a TLS layer above must run
/// in memory-BIO mode.
constructor TTlsSocket.Create(const ATransport: IHttp2Socket;
  const AHost: string; const AInsecure: Boolean; const ACACertFile: string;
  const AIdentity: IClientIdentity);
begin
  inherited Create;
  FIdentity := AIdentity;
  FTransport := ATransport;
  FHost := AHost;
  FInsecure := AInsecure;
  FCACertFile := ACACertFile;
  FAlpnOffer := AlpnOfferFor(False); // strict default: offer "h2" alone
  FRequireH2 := True;
  FConnectTimeoutMs := cDefaultSocketTimeoutMs;
  FReadTimeoutMs := cDefaultSocketTimeoutMs;
  FWriteTimeoutMs := cDefaultSocketTimeoutMs;
end;

procedure TTlsSocket.SetAlpnOffer(const AOffer: TBytes);
begin
  FAlpnOffer := AOffer;
end;

destructor TTlsSocket.Destroy;
begin
  Close;
  inherited Destroy;
end;

function TTlsSocket.CreateSslContext: PSSL_CTX;
begin
  if not OpenSslIsAvailable then
    raise EHttpConnectionError.Create(
      'OpenSSL is not available: set OPENSSL_LIBPATH to the OpenSSL library ' +
      'directory (e.g. /opt/homebrew/opt/openssl@3/lib)');
  Result := SSL_CTX_new(TLS_client_method());
  if Result = nil then
    raise EHttpConnectionError.Create('SSL_CTX_new failed');
end;

procedure TTlsSocket.DestroySslContext;
begin
  if FCtx <> nil then
  begin
    SSL_CTX_free(FCtx);
    FCtx := nil;
  end;
end;

function TTlsSocket.CreateSslHandle(const ACtx: PSSL_CTX): PSSL;
begin
  Result := SSL_new(ACtx);
  if Result = nil then
    raise EHttpConnectionError.Create('SSL_new failed');
  // SSL_set_msg_callback is optional: without it a TLS 1.2 handshake_failure
  // stays a generic connection error
  if not GMsgCallbackResolved then
  begin
    GSslCallbackCtrl := ResolveSslProc('SSL_callback_ctrl');
    GSslCtrl := ResolveSslProc('SSL_ctrl');
    GMsgCallbackResolved := True;
  end;
  if Assigned(GSslCallbackCtrl) and Assigned(GSslCtrl) then
  begin
    GSslCallbackCtrl(Result, SSL_CTRL_SET_MSG_CALLBACK,
      Pointer(@NoteHandshakeMessage));
    GSslCtrl(Result, SSL_CTRL_SET_MSG_CALLBACK_ARG, 0, Self);
  end;
end;

procedure TTlsSocket.DestroySslHandle;
begin
  if FSsl <> nil then
  begin
    SSL_free(FSsl);
    FSsl := nil;
  end;
end;

function TTlsSocket.ApplyAlpnProtos(const ACtx: PSSL_CTX): Integer;
begin
  if Length(FAlpnOffer) = 0 then
    Exit(0);
  Result := SSL_CTX_set_alpn_protos(ACtx, @FAlpnOffer[0], Length(FAlpnOffer));
end;

procedure TTlsSocket.ApplyVerifyMode(const ACtx: PSSL_CTX;
  const AMode: Integer);
begin
  if AMode <> SSL_VERIFY_NONE then
    // an explicit PEM bundle (private CA, or a test certificate) replaces the
    // system trust store rather than adding to it
    if FCACertFile <> '' then
    begin
      if SSL_CTX_load_verify_locations(ACtx, PUtf8Char(UTF8String(FCACertFile)),
         nil) <> 1 then
        raise EHttpConnectionError.CreateFmt(
          'SSL_CTX_load_verify_locations failed for "%s"', [FCACertFile]);
    end
    else
      SSL_CTX_set_default_verify_paths(ACtx);
  SSL_CTX_set_verify(ACtx, AMode, nil);
end;

procedure TTlsSocket.ApplyClientIdentity(const ACtx: PSSL_CTX);
var
  I: Integer;
  Cert: PX509;
begin
  if FIdentity = nil then
    Exit;
  // the identity keeps its own references: OpenSSL up-refs the leaf and key,
  // and each chain certificate is up-ref'd here because
  // SSL_CTX_add_extra_chain_cert takes ownership of the one it is given
  if SSL_CTX_use_certificate(ACtx, FIdentity.GetCertificate) <> 1 then
  begin
    TakeSslReason;
    raise EHttpConnectionError.Create('installing the client certificate failed');
  end;
  for I := 0 to FIdentity.GetChainCount - 1 do
  begin
    Cert := FIdentity.GetChainCertificate(I);
    X509_up_ref(Cert);
    if SSL_CTX_add_extra_chain_cert(ACtx, Cert) <> 1 then
    begin
      X509_free(Cert);
      TakeSslReason;
      raise EHttpConnectionError.Create(
        'installing the client certificate chain failed');
    end;
  end;
  if (SSL_CTX_use_PrivateKey(ACtx, FIdentity.GetPrivateKey) <> 1) or
     (SSL_CTX_check_private_key(ACtx) <> 1) then
  begin
    TakeSslReason;
    raise EHttpConnectionError.Create('installing the client key failed');
  end;
end;

function TTlsSocket.ApplyHostnameVerification(const ASsl: PSSL;
  const AHost: string): Integer;
begin
  Result := SSL_set1_host(ASsl, PUtf8Char(UTF8String(AHost)));
end;

function TTlsSocket.ApplySniHost(const ASsl: PSSL;
  const AHost: string): Integer;
begin
  Result := SSL_set_tlsext_host_name(ASsl, UTF8String(AHost));
end;

function TTlsSocket.BindSocket(const ASsl: PSSL; const AFd: Integer): Integer;
begin
  Result := SSL_set_fd(ASsl, AFd);
end;

function TTlsSocket.HandshakeConnect(const ASsl: PSSL): Integer;
var
  Shield: TSigPipeShield;
begin
  SigPipeShieldEnter(Shield);
  try
    Result := SSL_connect(ASsl);
  finally
    SigPipeShieldLeave(Shield);
  end;
end;

function TTlsSocket.SelectedAlpnBytes(const ASsl: PSSL): TBytes;
var
  data: PByte;
  len: Cardinal;
  i: Cardinal;
begin
  Result := nil;
  data := nil;
  len := 0;
  SSL_get0_alpn_selected(ASsl, @data, @len);
  if (data = nil) or (len = 0) then
    Exit;
  SetLength(Result, len);
  for i := 0 to len - 1 do
    Result[i] := data[i];
end;

function TTlsSocket.LastSslError(const ASsl: PSSL;
  const AResult: Integer): Integer;
begin
  Result := SSL_get_error(ASsl, AResult);
end;

function TTlsSocket.TakeSslReason: Cardinal;
var
  Code: Cardinal;
begin
  Result := 0;
  if not OpenSslIsAvailable then
    Exit;
  repeat
    Code := ERR_get_error;
    if Code <> 0 then
      Result := Code and cSslReasonMask;
  until Code = 0;
end;

procedure TTlsSocket.RaiseIfClientAuthRejected(const AErr: Integer);
var
  Alert: string;
  Reason: Cardinal;
begin
  if AErr <> SSL_ERROR_SSL then
    Exit;
  Reason := TakeSslReason;
  Alert := ClientAuthAlertName(Reason);
  if (Alert = '') and FCertRequested and
     (Reason = SSL_R_SSLV3_ALERT_HANDSHAKE_FAILURE) then
    Alert := 'handshake failure';
  // TLS 1.3 reports the rejection on the first read, after the handshake
  // "succeeded"; an alert after application data is not classified this way
  if (Alert <> '') and (not FReadAny) then
    raise EHttpTlsClientAuthError.Create(
      'the server rejected the client certificate (TLS alert: ' + Alert + ')',
      Alert);
end;

procedure TTlsSocket.ProbeRejectionAfterWrite;
var
  B: Byte;
  N: Integer;
begin
  // a write that fails before anything was read may have been cut short by the
  // server closing after a client-certificate alert (TLS 1.3): read once to
  // see whether that alert is waiting
  if FReadAny or FStreamMode then
    Exit;
  TakeSslReason;
  N := SslReadBytes(FSsl, @B, 1);
  if N <= 0 then
    RaiseIfClientAuthRejected(LastSslError(FSsl, N));
end;

function TTlsSocket.SslReadBytes(const ASsl: PSSL; const ABuffer: Pointer;
  const ACount: Integer): Integer;
var
  Shield: TSigPipeShield;
begin
  // a read can write too (alerts, TLS 1.3 key updates)
  SigPipeShieldEnter(Shield);
  try
    Result := SSL_read(ASsl, ABuffer, ACount);
  finally
    SigPipeShieldLeave(Shield);
  end;
end;

function TTlsSocket.SslWriteBytes(const ASsl: PSSL; const ABuffer: Pointer;
  const ACount: Integer): Integer;
var
  Shield: TSigPipeShield;
begin
  SigPipeShieldEnter(Shield);
  try
    Result := SSL_write(ASsl, ABuffer, ACount);
  finally
    SigPipeShieldLeave(Shield);
  end;
end;

procedure TTlsSocket.SslShutdown(const ASsl: PSSL);
var
  Shield: TSigPipeShield;
begin
  SigPipeShieldEnter(Shield);
  try
    SSL_shutdown(ASsl);
  finally
    SigPipeShieldLeave(Shield);
  end;
end;

function TTlsSocket.GetSocketFd: Integer;
var
  Obj: TObject;
begin
  if (FTransport = nil) or
     (not Supports(FTransport, TPlainSocket, Obj)) then
    raise EHttpConnectionError.Create(
      'TLS requires a plain TCP transport exposing a socket handle');
  Result := TPlainSocket(Obj).Handle;
end;

procedure TTlsSocket.Establish;
var
  r, err: Integer;
  Alpn: TBytes;
begin
  if FHandshaked then
    Exit;
  try
    FCtx := CreateSslContext;
    ApplyVerifyMode(FCtx, SslVerifyModeFor(FInsecure));
    ApplyClientIdentity(FCtx);
    if ApplyAlpnProtos(FCtx) <> 0 then
      raise EHttpConnectionError.Create('SSL_CTX_set_alpn_protos failed');
    FSsl := CreateSslHandle(FCtx);
    if not FInsecure then
      if ApplyHostnameVerification(FSsl, FHost) <> 1 then
        raise EHttpConnectionError.Create('SSL_set1_host failed');
    if ApplySniHost(FSsl, FHost) <> 1 then
      raise EHttpConnectionError.Create('SSL_set_tlsext_host_name failed');
    if FStreamMode then
    begin
      // the transport is another byte stream: OpenSSL gets two memory BIOs
      // (SSL_set_bio takes ownership of both) and StreamHandshake moves the
      // bytes; deadlines are the transport's own
      FRbio := BIO_new(BIO_s_mem());
      FWbio := BIO_new(BIO_s_mem());
      if (FRbio = nil) or (FWbio = nil) then
        raise EHttpConnectionError.Create('BIO_new failed');
      SSL_set_bio(FSsl, FRbio, FWbio);
      FTransport.ReadTimeoutMs := FConnectTimeoutMs;
      FTransport.WriteTimeoutMs := FConnectTimeoutMs;
      r := StreamHandshake(FSsl);
      FTransport.ReadTimeoutMs := FReadTimeoutMs;
      FTransport.WriteTimeoutMs := FWriteTimeoutMs;
    end
    else
    begin
      if BindSocket(FSsl, GetSocketFd) <> 1 then
        raise EHttpConnectionError.Create('SSL_set_fd failed');
      // SSL_connect recv()s/send()s directly on the fd, so install the
      // deadline there as well: a stalled handshake must not block forever
      SetSocketTimeout(GetSocketFd, SOL_SOCKET, SO_RCVTIMEO, FConnectTimeoutMs);
      SetSocketTimeout(GetSocketFd, SOL_SOCKET, SO_SNDTIMEO, FConnectTimeoutMs);
      r := HandshakeConnect(FSsl);
    end;
    if r <> 1 then
    begin
      err := LastSslError(FSsl, r);
      if (not FStreamMode) and SslTimedOut(err) then
        raise EHttpTimeout.CreateFmt('TLS handshake timed out after %d ms',
          [FConnectTimeoutMs])
      else
      begin
        RaiseIfClientAuthRejected(err);
        raise EHttpConnectionError.CreateFmt(
          'TLS handshake failed (SSL_get_error=%d)', [err]);
      end;
    end;
    Alpn := SelectedAlpnBytes(FSsl);
    // strict mode still fails when the peer does not select "h2" (interop
    // A.9); a fallback dial skips the check and reports the name instead
    if FRequireH2 then
      RequireH2Alpn(PByte(Alpn), Length(Alpn));
    FSelectedProtocol := AlpnNegotiatedName(
      AlpnSelectedName(PByte(Alpn), Length(Alpn)));
    FHandshaked := True;
  except
    DestroySslHandle;
    FRbio := nil;
    FWbio := nil;
    DestroySslContext;
    raise;
  end;
end;

class function TTlsSocket.Dial(const AHost: string; const APort: Word;
  const AInsecure: Boolean; const AConnectTimeoutMs: Integer;
  const ACACertFile: string; const AProxyHost: string;
  const AProxyPort: Word; const AIdentity: IClientIdentity): IHttp2Socket;
var
  Transport: TPlainSocket;
  Sock: TTlsSocket;
begin
  Transport := TPlainSocket.Create(AHost, APort, AConnectTimeoutMs, AProxyHost,
    AProxyPort);
  Sock := TTlsSocket.Create(Transport, AHost, AInsecure, ACACertFile,
    AIdentity);
  Sock.ConnectTimeoutMs := AConnectTimeoutMs;
  Sock.ReadTimeoutMs := AConnectTimeoutMs;
  try
    Sock.Establish;
  except
    Sock.Free;
    raise;
  end;
  Result := Sock;
end;

class function TTlsSocket.DialWithAlpn(const AHost: string; const APort: Word;
  const AAlpnOffer: TBytes; const AInsecure: Boolean;
  const AConnectTimeoutMs: Integer;
  const ACACertFile: string; const AProxyHost: string;
  const AProxyPort: Word; const AIdentity: IClientIdentity): IHttp2Socket;
var
  Transport: TPlainSocket;
  Sock: TTlsSocket;
begin
  Transport := TPlainSocket.Create(AHost, APort, AConnectTimeoutMs, AProxyHost,
    AProxyPort);
  Sock := TTlsSocket.Create(Transport, AHost, AInsecure, ACACertFile,
    AIdentity);
  Sock.ConnectTimeoutMs := AConnectTimeoutMs;
  Sock.ReadTimeoutMs := AConnectTimeoutMs;
  // the caller supplies the offer and applies its own ALPN policy afterwards
  Sock.FAlpnOffer := AAlpnOffer;
  Sock.FRequireH2 := False;
  try
    Sock.Establish;
  except
    Sock.Free;
    raise;
  end;
  Result := Sock;
end;

class function TTlsSocket.DialCleartext(const AHost: string; const APort: Word;
  const AConnectTimeoutMs: Integer; const AProxyHost: string;
  const AProxyPort: Word): IHttp2Socket;
var
  Sock: TPlainSocket;
begin
  Sock := TPlainSocket.Create(AHost, APort, AConnectTimeoutMs, AProxyHost,
    AProxyPort);
  Sock.SetConnectTimeoutMs(AConnectTimeoutMs);
  Sock.SetReadTimeoutMs(AConnectTimeoutMs);
  Sock.SetWriteTimeoutMs(AConnectTimeoutMs);
  Result := Sock;
end;

class function TTlsSocket.DialVia(const AHost: string; const APort: Word;
  const AInsecure: Boolean; const AConnectTimeoutMs: Integer;
  const ACACertFile: string; const AProxy: IProxy;
  const AIdentity, AProxyIdentity: IClientIdentity): IHttp2Socket;
var
  Transport: IHttp2Socket;
  Stream: Boolean;
  Sock: TTlsSocket;
begin
  Transport := DialRoutedTransport(AHost, APort, AConnectTimeoutMs, AProxy,
    AInsecure, ACACertFile, AProxyIdentity, Stream);
  Sock := TTlsSocket.Create(Transport, AHost, AInsecure, ACACertFile,
    AIdentity);
  Sock.FStreamMode := Stream;
  Sock.ConnectTimeoutMs := AConnectTimeoutMs;
  Sock.ReadTimeoutMs := AConnectTimeoutMs;
  try
    Sock.Establish;
  except
    Sock.Free;
    raise;
  end;
  Result := Sock;
end;

class function TTlsSocket.DialWithAlpnVia(const AHost: string;
  const APort: Word; const AAlpnOffer: TBytes; const AInsecure: Boolean;
  const AConnectTimeoutMs: Integer; const ACACertFile: string;
  const AProxy: IProxy; const AIdentity,
  AProxyIdentity: IClientIdentity): IHttp2Socket;
var
  Transport: IHttp2Socket;
  Stream: Boolean;
  Sock: TTlsSocket;
begin
  Transport := DialRoutedTransport(AHost, APort, AConnectTimeoutMs, AProxy,
    AInsecure, ACACertFile, AProxyIdentity, Stream);
  Sock := TTlsSocket.Create(Transport, AHost, AInsecure, ACACertFile,
    AIdentity);
  Sock.FStreamMode := Stream;
  Sock.ConnectTimeoutMs := AConnectTimeoutMs;
  Sock.ReadTimeoutMs := AConnectTimeoutMs;
  // the caller supplies the offer and applies its own ALPN policy afterwards
  Sock.FAlpnOffer := AAlpnOffer;
  Sock.FRequireH2 := False;
  try
    Sock.Establish;
  except
    Sock.Free;
    raise;
  end;
  Result := Sock;
end;

class function TTlsSocket.DialCleartextVia(const AHost: string;
  const APort: Word; const AConnectTimeoutMs: Integer; const AProxy: IProxy;
  const AInsecure: Boolean; const ACACertFile: string;
  const AProxyIdentity: IClientIdentity): IHttp2Socket;
var
  Stream: Boolean;
begin
  Result := DialRoutedTransport(AHost, APort, AConnectTimeoutMs, AProxy,
    AInsecure, ACACertFile, AProxyIdentity, Stream);
  Result.ConnectTimeoutMs := AConnectTimeoutMs;
  Result.ReadTimeoutMs := AConnectTimeoutMs;
  Result.WriteTimeoutMs := AConnectTimeoutMs;
end;

function TTlsSocket.Read(var ABuffer; ACount: Integer): Integer;
var
  n, err: Integer;
  base: PByte;
begin
  if not FHandshaked then
    raise EHttpConnectionError.Create('TLS handshake not completed');
  if ACount <= 0 then
    Exit(0);
  // SSL_read ultimately recv()s on the underlying fd, so the read deadline
  // must be installed there for a stalled peer to surface as EHttpTimeout
  if not FStreamMode then
    SetSocketTimeout(GetSocketFd, SOL_SOCKET, SO_RCVTIMEO, FReadTimeoutMs);
  base := PByte(@ABuffer);
  Result := 0;
  while Result < ACount do
  begin
    n := SslReadBytes(FSsl, base + Result, ACount - Result);
    if n > 0 then
    begin
      FReadAny := True;
      Inc(Result, n);
    end
    else
    begin
      err := LastSslError(FSsl, n);
      if FStreamMode and (err = SSL_ERROR_WANT_READ) then
      begin
        BioFlush;
        BioFeed;            // at EOF the next SSL_read reports the close
      end
      else if FStreamMode and (err = SSL_ERROR_WANT_WRITE) then
        BioFlush
      else if (err = SSL_ERROR_ZERO_RETURN) or
         ((err = SSL_ERROR_SYSCALL) and (n = 0)) or
         (FStreamMode and FEofFed and (err = SSL_ERROR_SSL)) then
        Exit // clean close_notify, or peer closed the transport without one
      else if (not FStreamMode) and SslTimedOut(err) then
        raise EHttpTimeout.CreateFmt('TLS read timed out after %d ms',
          [FReadTimeoutMs])
      else
      begin
        RaiseIfClientAuthRejected(err);
        raise EHttpConnectionClosed.CreateFmt(
          'TLS read failed (SSL_get_error=%d)', [err]);
      end;
    end;
  end;
end;

function TTlsSocket.Write(const ABuffer; ACount: Integer): Integer;
var
  n, err: Integer;
  base: PByte;
begin
  if not FHandshaked then
    raise EHttpConnectionError.Create('TLS handshake not completed');
  if ACount <= 0 then
    Exit(0);
  if not FStreamMode then
    SetSocketTimeout(GetSocketFd, SOL_SOCKET, SO_SNDTIMEO, FWriteTimeoutMs);
  base := PByte(@ABuffer);
  Result := 0;
  while Result < ACount do
  begin
    n := SslWriteBytes(FSsl, base + Result, ACount - Result);
    if n > 0 then
    begin
      Inc(Result, n);
      if FStreamMode then
        BioFlush;
    end
    else
    begin
      err := LastSslError(FSsl, n);
      if FStreamMode and (err = SSL_ERROR_WANT_READ) then
      begin
        BioFlush;
        BioFeed;
      end
      else if FStreamMode and (err = SSL_ERROR_WANT_WRITE) then
        BioFlush
      else if (not FStreamMode) and SslTimedOut(err) then
        raise EHttpTimeout.CreateFmt('TLS write timed out after %d ms',
          [FWriteTimeoutMs])
      else
      begin
        RaiseIfClientAuthRejected(err);
        if err = SSL_ERROR_SYSCALL then
          ProbeRejectionAfterWrite;
        raise EHttpConnectionClosed.CreateFmt(
          'TLS write failed (SSL_get_error=%d)', [err]);
      end;
    end;
  end;
end;

function TTlsSocket.ReadSome(var ABuffer; ACount: Integer): Integer;
var
  n, err: Integer;
begin
  if not FHandshaked then
    raise EHttpConnectionError.Create('TLS handshake not completed');
  if ACount <= 0 then
    Exit(0);
  if not FStreamMode then
    SetSocketTimeout(GetSocketFd, SOL_SOCKET, SO_RCVTIMEO, FReadTimeoutMs);
  while True do
  begin
    n := SslReadBytes(FSsl, @ABuffer, ACount);
    if n > 0 then
    begin
      FReadAny := True;
      Exit(n);
    end;
    err := LastSslError(FSsl, n);
    if FStreamMode and (err = SSL_ERROR_WANT_READ) then
    begin
      BioFlush;
      BioFeed;
    end
    else if FStreamMode and (err = SSL_ERROR_WANT_WRITE) then
      BioFlush
    else if (err = SSL_ERROR_ZERO_RETURN) or
       ((err = SSL_ERROR_SYSCALL) and (n = 0)) or
       (FStreamMode and FEofFed and (err = SSL_ERROR_SSL)) then
      Exit(0)
    else if (not FStreamMode) and SslTimedOut(err) then
      raise EHttpTimeout.CreateFmt('TLS read timed out after %d ms',
        [FReadTimeoutMs])
    else
    begin
      RaiseIfClientAuthRejected(err);
      raise EHttpConnectionClosed.CreateFmt(
        'TLS read failed (SSL_get_error=%d)', [err]);
    end;
  end;
end;

{ memory-BIO plumbing for a TLS layer carried over another byte stream }

procedure TTlsSocket.BioFlush;
var
  Buf: array[0..16383] of Byte;
  N: Integer;
begin
  if FWbio = nil then
    Exit;
  while BIO_ctrl(FWbio, _BIO_CTRL_PENDING, 0, nil) > 0 do
  begin
    N := BIO_read(FWbio, @Buf[0], SizeOf(Buf));
    if N <= 0 then
      Break;
    FTransport.Write(Buf[0], N);
  end;
end;

function TTlsSocket.BioFeed: Boolean;
var
  Buf: array[0..16383] of Byte;
  N: Integer;
  PR: IPartialReader;
begin
  if Supports(FTransport, IPartialReader, PR) then
    N := PR.ReadSome(Buf[0], SizeOf(Buf))
  else
    N := FTransport.Read(Buf[0], 1);
  if N <= 0 then
  begin
    // an empty read BIO now reports end of stream instead of "try again"
    BIO_ctrl(FRbio, BIO_C_SET_BUF_MEM_EOF_RETURN, 0, nil);
    FEofFed := True;
    Exit(False);
  end;
  if BIO_write(FRbio, @Buf[0], N) <> N then
    raise EHttpConnectionError.Create('BIO_write failed');
  Result := True;
end;

function TTlsSocket.StreamHandshake(const ASsl: PSSL): Integer;
var
  r, err: Integer;
begin
  repeat
    r := HandshakeConnect(ASsl);
    BioFlush;
    if r = 1 then
      Exit(1);
    err := LastSslError(ASsl, r);
    if err = SSL_ERROR_WANT_READ then
    begin
      if not BioFeed then
        Exit(r);            // the proxy closed during the handshake
    end
    else if err <> SSL_ERROR_WANT_WRITE then
      Exit(r);
  until False;
end;

procedure TTlsSocket.Close;
begin
  if FSsl <> nil then
    SslShutdown(FSsl);
  if FStreamMode and FHandshaked then
    try
      BioFlush;             // deliver close_notify through the tunnel
    except
      // the transport may already be gone
    end;
  DestroySslHandle;
  FRbio := nil;
  FWbio := nil;
  DestroySslContext;
  FHandshaked := False;
  if FTransport <> nil then
    FTransport.Close;
end;

function TTlsSocket.GetConnected: Boolean;
begin
  Result := FHandshaked and (FTransport <> nil) and FTransport.Connected;
end;

function TTlsSocket.GetConnectTimeoutMs: Integer;
begin
  Result := FConnectTimeoutMs;
end;

procedure TTlsSocket.SetConnectTimeoutMs(const AValue: Integer);
begin
  FConnectTimeoutMs := AValue;
end;

function TTlsSocket.GetReadTimeoutMs: Integer;
begin
  Result := FReadTimeoutMs;
end;

procedure TTlsSocket.SetReadTimeoutMs(const AValue: Integer);
begin
  FReadTimeoutMs := AValue;
  if FTransport <> nil then
    FTransport.ReadTimeoutMs := AValue;
end;

function TTlsSocket.GetWriteTimeoutMs: Integer;
begin
  Result := FWriteTimeoutMs;
end;

procedure TTlsSocket.SetWriteTimeoutMs(const AValue: Integer);
begin
  FWriteTimeoutMs := AValue;
  if FTransport <> nil then
    FTransport.WriteTimeoutMs := AValue;
end;

function DialProxyTlsSocket(const ATransport: IHttp2Socket;
  const AHost: string; const AInsecure: Boolean; const ACACertFile: string;
  const AIdentity: IClientIdentity; const ATimeoutMs: Integer): IHttp2Socket;
var
  Sock: TTlsSocket;
begin
  Sock := TTlsSocket.Create(ATransport, AHost, AInsecure, ACACertFile,
    AIdentity);
  Sock.FAlpnOffer := nil;
  Sock.FRequireH2 := False;
  Sock.ConnectTimeoutMs := ATimeoutMs;
  Sock.ReadTimeoutMs := ATimeoutMs;
  Sock.WriteTimeoutMs := ATimeoutMs;
  try
    Sock.Establish;
  except
    Sock.Free;
    raise;
  end;
  Result := Sock;
end;

end.

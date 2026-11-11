{**
---
license: Apache-2.0 OR (LGPL-2.1-only WITH Independent-modules-exception)
copyright: Copyright 2026 Liam Seamus Coughlin
keywords: http2, client, tls
notes:
  - This unit is part of the imported client transport.
---
}
unit Http2.Client.Tls.Plain;

{$mode delphi}{$H+}
{$interfaces com}

interface

uses
  SysUtils, Classes, Sockets, ssockets, BaseUnix, Http2.Client.Tls.Types;

type
  /// a plain (cleartext) TCP socket over fcl-net's TInetSocket. When a proxy
  /// is configured the TCP connection goes to the proxy and a CONNECT tunnel
  /// to the real target is negotiated first, so every layer above (TLS, h2c,
  /// HTTP/1.1) sees a transparent byte stream to the origin.
  TPlainSocket = class(TInterfacedObject, IHttp2Socket, IPartialReader)
  private
    FSocket: TInetSocket;
    FHandle: Integer;
    FConnected: Boolean;
    FConnectTimeoutMs: Integer;
    FReadTimeoutMs: Integer;
    FWriteTimeoutMs: Integer;
  public
    constructor Create(const AHost: string; const APort: Word;
      const AConnectTimeoutMs: Integer = cDefaultSocketTimeoutMs;
      const AProxyHost: string = ''; const AProxyPort: Word = 0);
    destructor Destroy; override;
    /// the underlying OS socket handle (needed to hand the socket to OpenSSL)
    property Handle: Integer read FHandle;
    function Read(var ABuffer; ACount: Integer): Integer;
    function ReadSome(var ABuffer; ACount: Integer): Integer;
    function Write(const ABuffer; ACount: Integer): Integer;
    procedure Close;
    function GetConnected: Boolean;
    function GetConnectTimeoutMs: Integer;
    procedure SetConnectTimeoutMs(const AValue: Integer);
    function GetReadTimeoutMs: Integer;
    procedure SetReadTimeoutMs(const AValue: Integer);
    function GetWriteTimeoutMs: Integer;
    procedure SetWriteTimeoutMs(const AValue: Integer);
  end;

implementation

uses
  Http2.Client.Errors, Http2.Client.SigPipe,
  Http2.Client.Tls.Tunnel;

constructor TPlainSocket.Create(const AHost: string; const APort: Word;
  const AConnectTimeoutMs: Integer;
  const AProxyHost: string; const AProxyPort: Word);
var
  opt: LongInt;
  DialHost: string;
  DialPort: Word;
begin
  inherited Create;
  FConnectTimeoutMs := AConnectTimeoutMs;
  FReadTimeoutMs := cDefaultSocketTimeoutMs;
  FWriteTimeoutMs := cDefaultSocketTimeoutMs;
  // with a proxy the TCP connection goes to the proxy; everything above then
  // talks to the origin through a CONNECT tunnel
  if AProxyHost <> '' then
  begin
    DialHost := AProxyHost;
    DialPort := AProxyPort;
  end
  else
  begin
    DialHost := AHost;
    DialPort := APort;
  end;
  try
    FSocket := TInetSocket.Create(DialHost, DialPort, AConnectTimeoutMs);
  except
    on E: ESocketError do
      if E.Code = seConnectTimeOut then
        raise EHttpTimeout.CreateFmt('connect timed out after %d ms',
          [AConnectTimeoutMs])
      else
        raise EHttpConnectionError.CreateFmt('connect to %s:%d failed: %s',
          [DialHost, DialPort, E.Message]);
  end;
  FHandle := FSocket.Handle;
  FSocket.WriteFlags := cMsgNoSignal;
  FConnected := True;
  opt := 1;
{$IFDEF DARWIN}
  fpSetSockOpt(FHandle, SOL_SOCKET, SO_NOSIGPIPE, @opt, SizeOf(opt));
{$ENDIF}
  if AProxyHost <> '' then
    try
      EstablishProxyTunnelFd(FHandle, AHost, APort, AConnectTimeoutMs, '', '');
    except
      Close;
      raise;
    end;
end;

destructor TPlainSocket.Destroy;
begin
  Close;
  inherited Destroy;
end;

procedure TPlainSocket.Close;
begin
  // TInetSocket.Free owns the OS close; calling fpClose here as well would
  // close the descriptor twice (and could close an unrelated reused fd)
  if FSocket <> nil then
  begin
    FSocket.Free;
    FSocket := nil;
  end;
  FHandle := -1;
  FConnected := False;
end;

function TPlainSocket.Read(var ABuffer; ACount: Integer): Integer;
begin
  if not FConnected then
    raise EHttpConnectionClosed.Create('socket is closed');
  Result := SocketReadFully(FHandle, ACount, FReadTimeoutMs, ABuffer);
end;

function TPlainSocket.ReadSome(var ABuffer; ACount: Integer): Integer;
var
  n: ssize_t;
begin
  if not FConnected then
    raise EHttpConnectionClosed.Create('socket is closed');
  if ACount <= 0 then
    Exit(0);
  SetSocketTimeout(FHandle, SOL_SOCKET, SO_RCVTIMEO, FReadTimeoutMs);
  while True do
  begin
    n := fpRecv(FHandle, @ABuffer, ACount, 0);
    if n >= 0 then
      Exit(n);
    if SocketTimedOut then
      raise EHttpTimeout.CreateFmt('read timed out after %d ms',
        [FReadTimeoutMs])
    else if fpGetErrno <> ESysEINTR then
      raise EHttpConnectionClosed.CreateFmt('socket read failed (errno %d)',
        [fpGetErrno]);
  end;
end;

function TPlainSocket.Write(const ABuffer; ACount: Integer): Integer;
begin
  if not FConnected then
    raise EHttpConnectionClosed.Create('socket is closed');
  Result := SocketWriteFully(FHandle, ACount, FWriteTimeoutMs, ABuffer);
end;

function TPlainSocket.GetConnected: Boolean;
begin
  Result := FConnected;
end;

function TPlainSocket.GetConnectTimeoutMs: Integer;
begin
  Result := FConnectTimeoutMs;
end;

procedure TPlainSocket.SetConnectTimeoutMs(const AValue: Integer);
begin
  FConnectTimeoutMs := AValue;
end;

function TPlainSocket.GetReadTimeoutMs: Integer;
begin
  Result := FReadTimeoutMs;
end;

procedure TPlainSocket.SetReadTimeoutMs(const AValue: Integer);
begin
  FReadTimeoutMs := AValue;
end;

function TPlainSocket.GetWriteTimeoutMs: Integer;
begin
  Result := FWriteTimeoutMs;
end;

procedure TPlainSocket.SetWriteTimeoutMs(const AValue: Integer);
begin
  FWriteTimeoutMs := AValue;
end;

{ client-certificate rejection }

const
  // OpenSSL reason codes of the alerts a server sends when it refuses the
  // client's certificate (openssl/sslerr.h: SSL_AD_REASON_OFFSET + alert number)
  SSL_R_SSLV3_ALERT_NO_CERTIFICATE = 1041;
  SSL_R_SSLV3_ALERT_BAD_CERTIFICATE = 1042;
  SSL_R_SSLV3_ALERT_UNSUPPORTED_CERTIFICATE = 1043;
  SSL_R_SSLV3_ALERT_CERTIFICATE_REVOKED = 1044;
  SSL_R_SSLV3_ALERT_CERTIFICATE_EXPIRED = 1045;
  SSL_R_SSLV3_ALERT_CERTIFICATE_UNKNOWN = 1046;
  SSL_R_TLSV1_ALERT_UNKNOWN_CA = 1048;
  SSL_R_TLSV1_ALERT_ACCESS_DENIED = 1049;
  SSL_R_TLSV13_ALERT_CERTIFICATE_REQUIRED = 1116;
  // a TLS 1.2 server that gets no certificate answers handshake_failure; it
  // counts as a client-certificate rejection only after a CertificateRequest
  SSL_R_SSLV3_ALERT_HANDSHAKE_FAILURE = 1040;
  cSslReasonMask = $7FFFFF;   // ERR_REASON_MASK
  cHandshakeContentType = 22; // SSL3_RT_HANDSHAKE
  cMsgCertificateRequest = 13;

end.

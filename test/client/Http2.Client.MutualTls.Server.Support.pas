{**
---
license: Apache-2.0 OR (LGPL-2.1-only WITH Independent-modules-exception)
copyright: Copyright 2026 Liam Seamus Coughlin
keywords: client_test_support
notes:
  - this contains the local TLS peer used by client tests
---
}
unit Http2.Client.MutualTls.Server.Support;

{$mode delphi}{$H+}
{$modeswitch advancedrecords}
{$modeswitch typehelpers}
{$interfaces com}

interface

uses
    SysUtils, Classes, SyncObjs, Sockets, BaseUnix, fpcunit, testregistry,
  mormot.core.base, mormot.core.os, mormot.lib.openssl11,
  Http2.Client.Errors, Http2.Client.ClientCert, Http2.Client.Proxy, Http2.Client.Tls, Http2.Client.Messages,
  Http2.Client.Stream,
  Http2.Client,
  Http2.Client.Sse, Http2.Client.WebSocket, Http2.Client.RequestObserver,
  Http2.Client.RequestObserver.Support;

const
  cPass = 'mtls-test-pass';
  cTls12 = TLS1_2_VERSION;
  cTls13 = TLS1_3_VERSION;



function Fixture(const AName: string): string;

type
  TMtlsKind = (mkH2, mkHttp1, mkSse, mkWebSocket, mkPlain);

  /// the ALPN protocol the server selects when the client offers it
  TAlpnChoice = record
    Len: Byte;
    Name: array[0..15] of AnsiChar;
  end;

  TMtlsServer = class;

  /// serves one HTTP/2 connection beside the others, so a client that opens a
  /// second connection to the same origin is not blocked behind the first
  TMtlsConnThread = class(TThread)
  private
    FServer: TMtlsServer;
    FFd: Integer;
  protected
    procedure Execute; override;
  public
    constructor Create(const AServer: TMtlsServer; const AFd: Integer);
  end;

  TMtlsServer = class(TThread)
  private
    FActive: Integer;
    FListenFd: Integer;
    FCtx: PSSL_CTX;
    FKind: TMtlsKind;
    FAlpn: TAlpnChoice;
    FPort: Word;
    procedure Serve(const AFd: Integer);
    procedure ServeAndClose(const AFd: Integer);
    procedure ServeTls(const AFd: Integer);
  protected
    procedure Execute; override;
  public
    /// TCP connections accepted, handshakes completed and refused
    Connections, Handshakes, Refused, Requests: Integer;
    /// subject of the last client certificate the server accepted
    LastSubject: string;
    /// a client certificate was offered on any accepted handshake
    SawClientCert: Boolean;
    /// every accepted handshake in order, as '|<subject>' or '|none'
    AllSubjects: string;
    /// an HTTP/1.1 request for a path starting with /redir is answered 302
    /// to this Location
    RedirectTo: string;
    /// AOptionalCert asks for a certificate without insisting on one, so a
    /// client that presents none still completes the handshake
    constructor Create(const AKind: TMtlsKind; const AVersion: Integer;
      const AOptionalCert: Boolean = False);
    destructor Destroy; override;
    procedure Stop;
    property Port: Word read FPort;
  end;

  TTunnelMode = (tmConnect, tmSocks5, tmHttps);

  /// who chooses the origin identity of a wss dial
  TIdentitySource = (isFixed, isSelector, isRequest);

  /// forwards one connection at a time to the origin port; for tmHttps the
  /// client leg is TLS and the proxy notes whether a certificate was offered
  TTunnelProxy = class(TThread)
  private
    FListenFd: Integer;
    FCtx: PSSL_CTX;
    FMode: TTunnelMode;
    FOriginPort: Word;
    FRequireCert: Boolean;
    FPort: Word;
    procedure Handle(const AFd: Integer);
  protected
    procedure Execute; override;
  public
    Tunnels, Refused: Integer;
    SawClientCert: Boolean;
    /// subject of the last client certificate the proxy accepted
    LastSubject: string;
    /// ARequireCert makes an https proxy refuse a client that offers none
    /// AVersion pins the https leg to one TLS version (0 = any)
    constructor Create(const AMode: TTunnelMode; const AOriginPort: Word;
      const ARequireCert: Boolean = False; const AVersion: Integer = 0);
    destructor Destroy; override;
    procedure Stop;
    property Port: Word read FPort;
    property Mode: TTunnelMode read FMode;
  end;

  /// answers a fixed identity per port and counts the calls; the optional
  /// probe checks, from another thread, that the pool lock is free during it

implementation


function Fixture(const AName: string): string;
begin
  Result := ExtractFilePath(ParamStr(0)) + '../test/fixtures/client/certs/mtls/' + AName;
  if FileExists(Result) then
    Exit;
  Result := 'test/fixtures/client/certs/mtls/' + AName;
end;

{ one accepted connection, TLS or plain }

type
  TConn = record
    Ssl: PSSL;
    Fd: Integer;
  end;

function ConnRead(const C: TConn; var ABuf; const N: Integer): Integer;
begin
  if C.Ssl <> nil then
    Result := SSL_read(C.Ssl, @ABuf, N)
  else
    Result := fpRecv(C.Fd, @ABuf, N, 0);
  if Result < 0 then
    Result := 0;
end;

procedure ConnWrite(const C: TConn; const ABuf; const N: Integer);
var
  Sent, R: Integer;
begin
  Sent := 0;
  while Sent < N do
  begin
    if C.Ssl <> nil then
      R := SSL_write(C.Ssl, PByte(@ABuf) + Sent, N - Sent)
    else
      R := fpSend(C.Fd, PByte(@ABuf) + Sent, N - Sent, 0);
    if R <= 0 then
      Exit;
    Inc(Sent, R);
  end;
end;

procedure ConnWriteText(const C: TConn; const AText: AnsiString);
begin
  if AText <> '' then
    ConnWrite(C, AText[1], Length(AText));
end;

function ConnReadFull(const C: TConn; var ABuf; const N: Integer): Boolean;
var
  Got, R: Integer;
begin
  Got := 0;
  while Got < N do
  begin
    R := ConnRead(C, (PByte(@ABuf) + Got)^, N - Got);
    if R <= 0 then
      Exit(False);
    Inc(Got, R);
  end;
  Result := True;
end;

function ConnReadHead(const C: TConn): AnsiString;
var
  B: Byte;
begin
  Result := '';
  while ConnRead(C, B, 1) = 1 do
  begin
    Result := Result + AnsiChar(B);
    if (Length(Result) >= 4) and
       (Copy(Result, Length(Result) - 3, 4) = #13#10#13#10) then
      Exit;
    if Length(Result) > 16384 then
      Exit;
  end;
end;

procedure SetTimeouts(const AFd: Integer; const AMs: Integer);
var
  Tv: TTimeVal;
  One: Integer;
begin
  // a write to a connection the client already closed must not kill the run
  One := 1;
  {$IFDEF DARWIN}
  fpSetSockOpt(AFd, SOL_SOCKET, SO_NOSIGPIPE, @One, SizeOf(One));
  {$ENDIF}
  Tv.tv_sec := AMs div 1000;
  Tv.tv_usec := (AMs mod 1000) * 1000;
  fpSetSockOpt(AFd, SOL_SOCKET, SO_RCVTIMEO, @Tv, SizeOf(Tv));
  fpSetSockOpt(AFd, SOL_SOCKET, SO_SNDTIMEO, @Tv, SizeOf(Tv));
end;

function ListenOnLoopback(out APort: Word): Integer;
var
  Addr: TSockAddr;
  Len: LongInt;
begin
  Result := fpsocket(AF_INET, SOCK_STREAM, 0);
  FillChar(Addr, SizeOf(Addr), 0);
  Addr.sin_family := AF_INET;
  Addr.sin_port := htons(0);
  Addr.sin_addr.s_addr := htonl($7F000001);
  fpbind(Result, @Addr, SizeOf(Addr));
  fplisten(Result, 8);
  Len := SizeOf(Addr);
  fpgetsockname(Result, @Addr, @Len);
  APort := ntohs(Addr.sin_port);
end;

function WaitReadable(const AFd: Integer; const AMs: Integer): Boolean;
var
  P: TPollFd;
begin
  P.fd := AFd;
  P.events := POLLIN;
  P.revents := 0;
  Result := fpPoll(@P, 1, AMs) > 0;
end;

type
  TAlpnSelectCb = function(ssl: PSSL; out_: PPByte; outlen: PByte;
    in_: PByte; inlen: Cardinal; arg: Pointer): Integer; cdecl;
  TSetAlpnSelectCb = procedure(ctx: PSSL_CTX; cb: TAlpnSelectCb;
    arg: Pointer); cdecl;

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

/// picks the server's configured protocol when the client offered it
function AlpnSelect(ssl: PSSL; out_: PPByte; outlen: PByte; in_: PByte;
  inlen: Cardinal; arg: Pointer): Integer; cdecl;
var
  Choice: ^TAlpnChoice;
  P: PByte;
  Left: Cardinal;
  L: Byte;
begin
  Choice := arg;
  P := in_;
  Left := inlen;
  while Left > 0 do
  begin
    L := P^;
    if (L = Choice^.Len) and (Left > L) and
       (CompareByte((P + 1)^, Choice^.Name[0], L) = 0) then
    begin
      out_^ := PByte(@Choice^.Name[0]);
      outlen^ := L;
      Exit(SSL_TLSEXT_ERR_OK);
    end;
    if Left < Cardinal(L) + 1 then
      Break;
    Dec(Left, Cardinal(L) + 1);
    Inc(P, Integer(L) + 1);
  end;
  Result := SSL_TLSEXT_ERR_NOACK;
end;

{ TMtlsServer }

constructor TMtlsServer.Create(const AKind: TMtlsKind; const AVersion: Integer;
  const AOptionalCert: Boolean);
var
  SetCb: TSetAlpnSelectCb;
  Name: AnsiString;
begin
  FKind := AKind;
  FListenFd := ListenOnLoopback(FPort);
  FCtx := SSL_CTX_new(TLS_server_method());
  SSL_CTX_use_certificate_file(FCtx, PUtf8Char(UTF8String(Fixture('server.crt'))),
    SSL_FILETYPE_PEM);
  SSL_CTX_use_PrivateKey_file(FCtx, PUtf8Char(UTF8String(Fixture('server.key'))),
    SSL_FILETYPE_PEM);
  SSL_CTX_load_verify_locations(FCtx,
    PUtf8Char(UTF8String(Fixture('ca.crt'))), nil);
  if AOptionalCert then
    SSL_CTX_set_verify(FCtx, SSL_VERIFY_PEER, nil)
  else
    SSL_CTX_set_verify(FCtx,
      SSL_VERIFY_PEER or SSL_VERIFY_FAIL_IF_NO_PEER_CERT, nil);
  if AVersion <> 0 then
  begin
    SSL_CTX_set_min_proto_version(FCtx, AVersion);
    SSL_CTX_set_max_proto_version(FCtx, AVersion);
  end;
  // ALPN: h2 for the HTTP/2 server, http/1.1 for the HTTP/1.1 kinds
  if AKind = mkH2 then
    Name := 'h2'
  else
    Name := 'http/1.1';
  FAlpn.Len := Length(Name);
  Move(Name[1], FAlpn.Name[0], Length(Name));
  SetCb := ResolveSslProc('SSL_CTX_set_alpn_select_cb');
  if Assigned(SetCb) and (AKind <> mkPlain) then
    SetCb(FCtx, AlpnSelect, @FAlpn);
  inherited Create(False);
end;

destructor TMtlsServer.Destroy;
begin
  if FCtx <> nil then
    SSL_CTX_free(FCtx);
  if FListenFd >= 0 then
    fpClose(FListenFd);
  inherited Destroy;
end;

procedure TMtlsServer.Stop;
var
  I: Integer;
begin
  Terminate;
  WaitFor;
  // connection threads end when their client closes or the socket times out
  for I := 1 to 400 do
  begin
    if FActive = 0 then
      Break;
    Sleep(25);
  end;
end;

procedure TMtlsServer.ServeAndClose(const AFd: Integer);
begin
  try
    Serve(AFd);
  except
    // a failed exchange is visible to the client as an error
  end;
  fpClose(AFd);
end;

{ TMtlsConnThread }

constructor TMtlsConnThread.Create(const AServer: TMtlsServer;
  const AFd: Integer);
begin
  FServer := AServer;
  FFd := AFd;
  FreeOnTerminate := True;
  inherited Create(False);
end;

procedure TMtlsConnThread.Execute;
begin
  try
    FServer.ServeAndClose(FFd);
  finally
    InterlockedDecrement(FServer.FActive);
  end;
end;

procedure TMtlsServer.Execute;
var
  Fd: Integer;
begin
  while not Terminated do
  begin
    if not WaitReadable(FListenFd, 50) then
      Continue;
    Fd := fpAccept(FListenFd, nil, nil);
    if Fd < 0 then
      Continue;
    InterlockedIncrement(Connections);
    SetTimeouts(Fd, 3000);
    if FKind = mkH2 then
    begin
      InterlockedIncrement(FActive);
      TMtlsConnThread.Create(Self, Fd);
    end
    else
      ServeAndClose(Fd);
  end;
end;

procedure TMtlsServer.Serve(const AFd: Integer);
var
  C: TConn;
  Head: AnsiString;
begin
  if FKind <> mkPlain then
  begin
    ServeTls(AFd);
    Exit;
  end;
  C.Ssl := nil;
  C.Fd := AFd;
  Head := ConnReadHead(C);
  if Head <> '' then
  begin
    InterlockedIncrement(Requests);
    ConnWriteText(C, 'HTTP/1.1 200 OK'#13#10'Content-Length: 2'#13#10 +
      'Connection: close'#13#10#13#10'ok');
  end;
end;

procedure TMtlsServer.ServeTls(const AFd: Integer);
var
  C: TConn;
  Peer: PX509;
  Head, Key: AnsiString;
  P: Integer;
  Hdr: array[0..8] of Byte;
  Payload: array of Byte;
  Len: Integer;
  Sid: LongWord;
  Resp: array[0..8] of Byte;
  Preface: array[0..23] of Byte;
  Buf: array[0..255] of Byte;
  Closed: Boolean;

  procedure H2Frame(const AType, AFlags: Byte; const AStream: LongWord;
    const APayload: array of Byte);
  var
    F: array of Byte;
    I: Integer;
  begin
    SetLength(F, 9 + Length(APayload));
    F[0] := 0;
    F[1] := Length(APayload) shr 8;
    F[2] := Length(APayload) and $FF;
    F[3] := AType;
    F[4] := AFlags;
    F[5] := AStream shr 24;
    F[6] := (AStream shr 16) and $FF;
    F[7] := (AStream shr 8) and $FF;
    F[8] := AStream and $FF;
    for I := 0 to High(APayload) do
      F[9 + I] := APayload[I];
    ConnWrite(C, F[0], Length(F));
  end;

begin
  C.Fd := AFd;
  C.Ssl := SSL_new(FCtx);
  SSL_set_fd(C.Ssl, AFd);
  try
    if SSL_accept(C.Ssl) <> 1 then
    begin
      InterlockedIncrement(Refused);
      // the alert is already sent; read what the client wrote after its
      // handshake before closing, so the close does not reset the connection
      // and take the alert with it
      fpShutdown(AFd, SHUT_WR);
      SetTimeouts(AFd, 300);
      while fpRecv(AFd, @Buf[0], SizeOf(Buf), 0) > 0 do;
      Exit;
    end;
    InterlockedIncrement(Handshakes);
    Peer := SSL_get_peer_certificate(C.Ssl);
    if Peer <> nil then
    begin
      SawClientCert := True;
      LastSubject := string(Peer^.SubjectName);
      AllSubjects := AllSubjects + '|' + LastSubject;
      X509_free(Peer);
    end
    else
      AllSubjects := AllSubjects + '|none';
    case FKind of
      mkH2:
        begin
          if not ConnReadFull(C, Preface[0], SizeOf(Preface)) then
            Exit;
          H2Frame(4, 0, 0, []);                 // our SETTINGS (empty)
          while ConnReadFull(C, Hdr[0], 9) do
          begin
            Len := (Hdr[0] shl 16) or (Hdr[1] shl 8) or Hdr[2];
            Sid := (LongWord(Hdr[5] and $7F) shl 24) or (LongWord(Hdr[6]) shl 16) or
              (LongWord(Hdr[7]) shl 8) or Hdr[8];
            SetLength(Payload, Len);
            if (Len > 0) and (not ConnReadFull(C, Payload[0], Len)) then
              Exit;
            case Hdr[3] of
              4: if (Hdr[4] and 1) = 0 then
                   H2Frame(4, 1, 0, []);        // ACK the client's SETTINGS
              1: begin                          // HEADERS: answer 200 'ok'
                   InterlockedIncrement(Requests);
                   H2Frame(1, 4, Sid, [$88]);
                   H2Frame(0, 1, Sid, [Ord('o'), Ord('k')]);
                 end;
              7: Exit;                          // GOAWAY
            end;
          end;
        end;
      mkHttp1:
        begin
          Head := ConnReadHead(C);
          if Head <> '' then
          begin
            InterlockedIncrement(Requests);
            if (RedirectTo <> '') and (Pos('GET /redir', string(Head)) = 1) then
              ConnWriteText(C, 'HTTP/1.1 302 Found'#13#10'Location: ' +
                AnsiString(RedirectTo) + #13#10'Content-Length: 0'#13#10 +
                'Connection: close'#13#10#13#10)
            else
              ConnWriteText(C, 'HTTP/1.1 200 OK'#13#10'Content-Length: 2'#13#10 +
                'Connection: close'#13#10#13#10'ok');
          end;
        end;
      mkSse:
        begin
          Head := ConnReadHead(C);
          if Head <> '' then
          begin
            InterlockedIncrement(Requests);
            ConnWriteText(C, 'HTTP/1.1 200 OK'#13#10 +
              'Content-Type: text/event-stream'#13#10 +
              'Connection: close'#13#10#13#10'data: hello'#10#10);
          end;
        end;
      mkWebSocket:
        begin
          Head := ConnReadHead(C);
          P := Pos('sec-websocket-key:', LowerCase(Head));
          if P = 0 then
            Exit;
          Key := Trim(Copy(Head, P + 18, Pos(#13, Copy(Head, P, MaxInt)) - 19));
          InterlockedIncrement(Requests);
          ConnWriteText(C, 'HTTP/1.1 101 Switching Protocols'#13#10 +
            'Upgrade: websocket'#13#10'Connection: Upgrade'#13#10 +
            'Sec-WebSocket-Accept: ' + AnsiString(WsComputeAccept(string(Key))) +
            #13#10#13#10 + #$81#$05'hello');
          // answer the client's close frame, then end
          Closed := False;
          while (not Closed) and ConnReadFull(C, Resp[0], 2) do
          begin
            Len := Resp[1] and $7F;
            if (Resp[1] and $80) <> 0 then
              ConnReadFull(C, Buf[0], 4);
            if (Len > 0) and (Len < 126) then
              ConnReadFull(C, Buf[0], Len);
            if (Resp[0] and $0F) = 8 then
            begin
              ConnWriteText(C, #$88#$00);
              Closed := True;
            end;
          end;
        end;
    end;
    SSL_shutdown(C.Ssl);
  finally
    SSL_free(C.Ssl);
  end;
end;

{ TTunnelProxy }

constructor TTunnelProxy.Create(const AMode: TTunnelMode;
  const AOriginPort: Word; const ARequireCert: Boolean;
  const AVersion: Integer);
begin
  FMode := AMode;
  FOriginPort := AOriginPort;
  FRequireCert := ARequireCert;
  FListenFd := ListenOnLoopback(FPort);
  if AMode = tmHttps then
  begin
    FCtx := SSL_CTX_new(TLS_server_method());
    SSL_CTX_use_certificate_file(FCtx,
      PUtf8Char(UTF8String(Fixture('server.crt'))), SSL_FILETYPE_PEM);
    SSL_CTX_use_PrivateKey_file(FCtx,
      PUtf8Char(UTF8String(Fixture('server.key'))), SSL_FILETYPE_PEM);
    // ask for a certificate and trust the fixture CA, so one offered to the
    // proxy would be seen (and verified) rather than abort the handshake
    SSL_CTX_load_verify_locations(FCtx,
      PUtf8Char(UTF8String(Fixture('ca.crt'))), nil);
    if ARequireCert then
      SSL_CTX_set_verify(FCtx,
        SSL_VERIFY_PEER or SSL_VERIFY_FAIL_IF_NO_PEER_CERT, nil)
    else
      SSL_CTX_set_verify(FCtx, SSL_VERIFY_PEER, nil);
    if AVersion <> 0 then
    begin
      SSL_CTX_set_min_proto_version(FCtx, AVersion);
      SSL_CTX_set_max_proto_version(FCtx, AVersion);
    end;
  end;
  inherited Create(False);
end;

destructor TTunnelProxy.Destroy;
begin
  if FCtx <> nil then
    SSL_CTX_free(FCtx);
  if FListenFd >= 0 then
    fpClose(FListenFd);
  inherited Destroy;
end;

procedure TTunnelProxy.Stop;
begin
  Terminate;
  WaitFor;
end;

procedure TTunnelProxy.Execute;
var
  Fd: Integer;
begin
  while not Terminated do
  begin
    if not WaitReadable(FListenFd, 50) then
      Continue;
    Fd := fpAccept(FListenFd, nil, nil);
    if Fd < 0 then
      Continue;
    SetTimeouts(Fd, 3000);
    try
      Handle(Fd);
    except
      // the client sees the tunnel break
    end;
    fpClose(Fd);
  end;
end;

procedure TTunnelProxy.Handle(const AFd: Integer);
var
  C: TConn;
  Origin: Integer;
  Addr: TSockAddr;
  Head: AnsiString;
  B: array[0..255] of Byte;
  Buf: array[0..16383] of Byte;
  N, I: Integer;
  Peer: PX509;
  Fds: array[0..1] of TPollFd;
  Ready: Boolean;
begin
  C.Fd := AFd;
  C.Ssl := nil;
  try
    if FMode = tmHttps then
    begin
      C.Ssl := SSL_new(FCtx);
      SSL_set_fd(C.Ssl, AFd);
      if SSL_accept(C.Ssl) <> 1 then
      begin
        InterlockedIncrement(Refused);
        // let the client read the alert before the close
        fpShutdown(AFd, SHUT_WR);
        SetTimeouts(AFd, 300);
        while fpRecv(AFd, @B[0], SizeOf(B), 0) > 0 do;
        Exit;
      end;
      Peer := SSL_get_peer_certificate(C.Ssl);
      if Peer <> nil then
      begin
        SawClientCert := True;
        LastSubject := string(Peer^.SubjectName);
        X509_free(Peer);
      end;
    end;
    if FMode = tmSocks5 then
    begin
      // greeting, then the CONNECT request: both consumed, target ignored
      if not ConnReadFull(C, B[0], 2) then
        Exit;
      if not ConnReadFull(C, B[2], B[1]) then
        Exit;
      B[0] := 5;
      B[1] := 0;
      ConnWrite(C, B[0], 2);
      if not ConnReadFull(C, B[0], 4) then
        Exit;
      case B[3] of
        1: N := 4;
        4: N := 16;
      else
        begin
          if not ConnReadFull(C, B[4], 1) then
            Exit;
          N := B[4];
        end;
      end;
      if not ConnReadFull(C, B[5], N + 2) then
        Exit;
    end
    else
    begin
      Head := ConnReadHead(C);
      if Pos('CONNECT ', Head) <> 1 then
        Exit;
    end;
    Origin := fpsocket(AF_INET, SOCK_STREAM, 0);
    FillChar(Addr, SizeOf(Addr), 0);
    Addr.sin_family := AF_INET;
    Addr.sin_port := htons(FOriginPort);
    Addr.sin_addr.s_addr := htonl($7F000001);
    if fpconnect(Origin, @Addr, SizeOf(Addr)) <> 0 then
    begin
      fpClose(Origin);
      Exit;
    end;
    SetTimeouts(Origin, 3000);
    try
      InterlockedIncrement(Tunnels);
      if FMode = tmSocks5 then
      begin
        FillChar(B, SizeOf(B), 0);
        B[0] := 5;
        B[3] := 1;
        ConnWrite(C, B[0], 10);
      end
      else
        ConnWriteText(C, 'HTTP/1.1 200 Connection established'#13#10#13#10);
      // pump both ways until either side ends
      Fds[0].fd := AFd;
      Fds[0].events := POLLIN;
      Fds[1].fd := Origin;
      Fds[1].events := POLLIN;
      repeat
        Ready := (C.Ssl <> nil) and (SSL_pending(C.Ssl) > 0);
        Fds[0].revents := 0;
        Fds[1].revents := 0;
        if Ready then
          Fds[0].revents := POLLIN
        else if fpPoll(@Fds[0], 2, 4000) <= 0 then
          Break;
        if Fds[0].revents <> 0 then
        begin
          N := ConnRead(C, Buf[0], SizeOf(Buf));
          if N <= 0 then
            Break;
          I := 0;
          while I < N do
          begin
            I := I + fpSend(Origin, @Buf[I], N - I, 0);
            if I < 0 then
              Break;
          end;
        end;
        if Fds[1].revents <> 0 then
        begin
          N := fpRecv(Origin, @Buf[0], SizeOf(Buf), 0);
          if N <= 0 then
            Break;
          ConnWrite(C, Buf[0], N);
        end;
      until False;
    finally
      fpClose(Origin);
    end;
  finally
    if C.Ssl <> nil then
    begin
      SSL_shutdown(C.Ssl);
      SSL_free(C.Ssl);
    end;
  end;
end;


end.

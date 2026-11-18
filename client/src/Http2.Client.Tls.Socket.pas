{**
---
license: Apache-2.0 OR (LGPL-2.1-only WITH Independent-modules-exception)
copyright: Copyright 2026 Liam Seamus Coughlin
keywords: client, tls, transport
notes:
  - TLS records use the provider-neutral common session contract.
---
}
unit Http2.Client.Tls.Socket;

{$mode delphi}{$H+}{$interfaces com}

interface

uses
  SysUtils, Http2.Client.Errors, Http2.Client.Proxy.Types,
  SyncObjs,
  Http2.Client.Tls.Types, Http2.Client.ClientCert,
  Http2.Common.Tls.Context, Http2.Common.Tls.Policy,
  Http2.Common.Tls.Session, Http2.Common.Tls.Types;

type
  IHttp2TlsSocketInfo = interface(IInterface)
    ['{886B9697-5F40-44F7-A074-95B2A9B8C159}']
    function NegotiatedTlsInfo: TTlsNegotiatedInfo;
    function SelectedProtocol: string;
  end;

function DialProxyTlsSocket(const ATransport: IHttp2Socket;
  const AHost: string; const AContext: ITLSContext;
  const AIdentity: IClientIdentity; const ATimeoutMs: Integer): IHttp2Socket;
procedure RequireClientTlsContext(const AContext: ITLSContext;
  const AWhat: string);
procedure RejectLegacyTlsPolicy(const AInsecure: Boolean;
  const ACACertFile: string);

type
  TTlsSocket = class(TInterfacedObject, IHttp2Socket, IPartialReader,
    IHttp2TlsSocketInfo, IPendingInput, IReadInterrupt)
  private
    FTransport: IHttp2Socket;
    FReader: IPartialReader;
    FContext: ITLSContext;
    FSession: ITLSSession;
    FIdentity: IClientIdentity;
    FInfo: TTlsNegotiatedInfo;
    FProtocol: string;
    FConnected: Boolean;
    FTransportEof: Boolean;
    FSessionLock: TCriticalSection;
    FReadLock: TCriticalSection;
    FWriteLock: TCriticalSection;
    FInputProgress: PRTLEvent;
    FInputGeneration: LongInt;
    FPlainBuffer: TBytes;
    FEncryptedPending: TBytes;
    FEncryptedOffset: SizeInt;
    FEncryptedOutput: TBytes;
    FEncryptedOutputOffset: SizeInt;
    FHandshakeDeadlineMs: Int64;
    procedure Pump(const AReadInput: Boolean);
    function AdvanceSession: TTlsProgress;
    procedure MapSessionError(const AError: ETlsSessionError);
    procedure ReadPeerAlertAfterWriteFailure;
    procedure NotifyTransportEof;
    function FlushEncrypted: Boolean;
    function ReadEncrypted: Boolean;
    function ReadApplicationEncrypted: Boolean;
    function GetPlain(var ABuffer; const ACount: Integer): Integer;
    function PollSessionInput: Boolean;
    procedure PutPlain(const ABuffer; const ACount: Integer);
  public
    constructor Create(const ATransport: IHttp2Socket; const AHost: string;
      const AContext: ITLSContext; const AIdentity: IClientIdentity;
      const AAlpn: array of string; const ATimeoutMs: Integer;
      const AIdentityExplicit: Boolean = False);
    destructor Destroy; override;
    class function Dial(const AHost: string; const APort: Word;
      const AInsecure: Boolean = False; const AConnectTimeoutMs: Integer = cDefaultSocketTimeoutMs;
      const ACACertFile: string = ''; const AProxyHost: string = '';
      const AProxyPort: Word = 0; const AIdentity: IClientIdentity = nil;
      const AContext: ITLSContext = nil; const AUnixPath: string = ''): IHttp2Socket;
    class function DialWithAlpn(const AHost: string; const APort: Word;
      const AAlpnOffer: TBytes; const AInsecure: Boolean = False;
      const AConnectTimeoutMs: Integer = cDefaultSocketTimeoutMs;
      const ACACertFile: string = ''; const AProxyHost: string = '';
      const AProxyPort: Word = 0; const AIdentity: IClientIdentity = nil;
      const AContext: ITLSContext = nil; const AUnixPath: string = ''): IHttp2Socket;
    class function DialCleartext(const AHost: string; const APort: Word;
      const AConnectTimeoutMs: Integer = cDefaultSocketTimeoutMs;
      const AProxyHost: string = ''; const AProxyPort: Word = 0; const AUnixPath: string = ''): IHttp2Socket;
    class function DialVia(const AHost: string; const APort: Word;
      const AInsecure: Boolean; const AConnectTimeoutMs: Integer;
      const ACACertFile: string; const AProxy: IProxy;
      const AIdentity: IClientIdentity = nil; const AProxyIdentity: IClientIdentity = nil;
      const AContext: ITLSContext = nil; const AProxyContext: ITLSContext = nil;
      const AUnixPath: string = ''): IHttp2Socket;
    class function DialWithAlpnVia(const AHost: string; const APort: Word;
      const AAlpnOffer: TBytes; const AInsecure: Boolean;
      const AConnectTimeoutMs: Integer; const ACACertFile: string;
      const AProxy: IProxy; const AIdentity: IClientIdentity = nil;
      const AProxyIdentity: IClientIdentity = nil; const AContext: ITLSContext = nil;
      const AProxyContext: ITLSContext = nil;
      const AIdentityExplicit: Boolean = False; const AUnixPath: string = ''): IHttp2Socket;
    class function DialCleartextVia(const AHost: string; const APort: Word;
      const AConnectTimeoutMs: Integer; const AProxy: IProxy;
      const AInsecure: Boolean = False; const ACACertFile: string = '';
      const AProxyIdentity: IClientIdentity = nil;
      const AProxyContext: ITLSContext = nil; const AUnixPath: string = ''): IHttp2Socket;
    function ReadSome(var ABuffer; ACount: Integer): Integer;
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
    function NegotiatedTlsInfo: TTlsNegotiatedInfo;
    function SelectedProtocol: string;
    function HasPendingInput: Boolean;
    /// the wake channel is the one of the transport; a transport without one
    // leaves the timed read
    procedure EnableInterrupt;
    procedure InterruptRead;
    property Connected: Boolean read GetConnected;
    property ConnectTimeoutMs: Integer read GetConnectTimeoutMs write SetConnectTimeoutMs;
    property ReadTimeoutMs: Integer read GetReadTimeoutMs write SetReadTimeoutMs;
    property WriteTimeoutMs: Integer read GetWriteTimeoutMs write SetWriteTimeoutMs;
  end;

implementation

uses Http2.Client.Tls.Plain, Http2.Client.Tls.Tunnel, Http2.Client.Proxy,
  mormot.core.os;

function IsIpLiteral(const AHost: string): Boolean; forward;

procedure RequireClientTlsContext(const AContext: ITLSContext;
  const AWhat: string);
begin
  if AContext = nil then
    raise EHttpTlsConfigError.Create('an explicit ' + AWhat + ' TLS context is required');
  if not (trClient in AContext.Info.Roles) then
    raise EHttpTlsConfigError.Create('the ' + AWhat +
      ' TLS context does not support client sessions');
end;

procedure RejectLegacyTlsPolicy(const AInsecure: Boolean;
  const ACACertFile: string);
begin
  if AInsecure or (ACACertFile <> '') then
    raise EHttpTlsConfigError.Create(
      'TLS trust is configured by ITLSContext; legacy insecure and CA-file options are unsupported');
end;

constructor TTlsSocket.Create(const ATransport: IHttp2Socket; const AHost: string;
  const AContext: ITLSContext; const AIdentity: IClientIdentity;
  const AAlpn: array of string; const ATimeoutMs: Integer;
  const AIdentityExplicit: Boolean);
var Opt: TTlsClientSessionOptions;
begin
  inherited Create;
  FSessionLock := TCriticalSection.Create;
  FReadLock := TCriticalSection.Create;
  FWriteLock := TCriticalSection.Create;
  FInputProgress := nil;
  FInputProgress := RTLEventCreate;
  try
    RequireClientTlsContext(AContext, 'origin');
  except
    ATransport.Close;
    raise;
  end;
  FContext := AContext; FTransport := ATransport;
  FConnected := True;
  try
    if not Supports(ATransport, IPartialReader, FReader) then
      raise EHttpConnectionError.Create('TLS transport does not support partial reads');
    FSessionLock.Acquire;
    try
    Opt := Default(TTlsClientSessionOptions); Opt.HostName := AHost;
    Opt.HandshakeStartMs := mormot.core.os.GetTickCount64;
    if ATimeoutMs > 0 then
      FHandshakeDeadlineMs := Opt.HandshakeStartMs + ATimeoutMs;
    if FContext.Info.HandshakeTimeoutMs > 0 then
      if (FHandshakeDeadlineMs = 0) or
         (FHandshakeDeadlineMs > Opt.HandshakeStartMs + FContext.Info.HandshakeTimeoutMs) then
        FHandshakeDeadlineMs := Opt.HandshakeStartMs + FContext.Info.HandshakeTimeoutMs;
    Opt.HandshakeDeadlineMs := FHandshakeDeadlineMs;
    if (AHost <> '') and not IsIpLiteral(AHost) then
      Opt.ServerName := AHost;
    Opt.IdentitySelection := tisUseDefault;
    if AIdentityExplicit or (AIdentity <> nil) then
    begin Opt.IdentitySelection := tisExplicit; Opt.Identity := AIdentity; end;
    Opt := Opt.WithAlpns(AAlpn); FSession := FContext.CreateClientSession(Opt);
    FTransport.ConnectTimeoutMs := ATimeoutMs;
    FTransport.ReadTimeoutMs := ATimeoutMs; FTransport.WriteTimeoutMs := ATimeoutMs;
    while FSession.State <> tssOpen do
    begin
      if FSession.State in [tssFailed, tssClosed] then
        raise EHttpTlsConfigError.Create('TLS handshake terminated before opening');
      Pump(True);
    end;
    FHandshakeDeadlineMs := 0;
    FTransport.ReadTimeoutMs := FTransport.ConnectTimeoutMs;
    FInfo := FSession.NegotiatedInfo; FProtocol := FInfo.SelectedAlpn;
    finally
      FSessionLock.Release;
    end;
  except
    on E: Exception do
    begin
      if FSession <> nil then FSession.Abort;
      FConnected := False;
      FTransport.Close;
      if E is ETlsSessionError then
        MapSessionError(ETlsSessionError(E));
      raise;
    end;
  end;
end;

destructor TTlsSocket.Destroy;
begin
  Close;
  FWriteLock.Free;
  FReadLock.Free;
  FSessionLock.Free;
  if FInputProgress <> nil then RTLEventDestroy(FInputProgress);
  inherited Destroy;
end;

function TTlsSocket.FlushEncrypted: Boolean;
var N: SizeInt;
begin
  Result := False;
  if not FWriteLock.TryEnter then
    Exit;
  try
    while True do
    begin
      if Length(FEncryptedOutput) = 0 then
      begin
        SetLength(FEncryptedOutput, TlsMaxEncryptedOutput);
        N := FSession.DrainEncrypted(FEncryptedOutput, 0,
          Length(FEncryptedOutput));
        if N <= 0 then
        begin
          FEncryptedOutput := nil;
          Exit;
        end;
        Result := True;
        SetLength(FEncryptedOutput, N);
        FEncryptedOutputOffset := 0;
      end;
      if not FTransport.Connected then
        raise EHttpConnectionClosed.Create('TLS transport closed during write');
      FSessionLock.Release;
      try
        try
          N := FTransport.Write(FEncryptedOutput[FEncryptedOutputOffset],
            Length(FEncryptedOutput) - FEncryptedOutputOffset);
        except
          ReadPeerAlertAfterWriteFailure;
          raise;
        end;
      finally
        FSessionLock.Acquire;
      end;
      if (N < 0) or
         (N > Length(FEncryptedOutput) - FEncryptedOutputOffset) then
        raise EHttpConnectionError.Create('transport returned an invalid write count');
      if N = 0 then
        raise EHttpConnectionClosed.Create('TLS transport made no write progress');
      Inc(FEncryptedOutputOffset, N);
      if FEncryptedOutputOffset = Length(FEncryptedOutput) then
      begin
        FEncryptedOutput := nil;
        FEncryptedOutputOffset := 0;
      end;
    end;
  finally
    FWriteLock.Leave;
  end;
end;

function ClientAuthAlertName(const ADescription: Integer): string;
begin
  case ADescription of
    41: Result := 'no certificate';
    42: Result := 'bad certificate';
    43: Result := 'unsupported certificate';
    44: Result := 'certificate revoked';
    45: Result := 'certificate expired';
    46: Result := 'unknown certificate';
    48: Result := 'unknown ca';
    49: Result := 'access denied';
    116: Result := 'certificate required';
  else
    Result := '';
  end;
end;

function ClientAuthAlertOf(const AError: ETlsSessionError): string;
begin
  if AError.PeerAlertDescription = 40 then
  begin
    if AError.ClientCertificateRequested then
      Result := 'handshake failure'
    else
      Result := '';
  end
  else
    Result := ClientAuthAlertName(AError.PeerAlertDescription);
end;

procedure TTlsSocket.MapSessionError(const AError: ETlsSessionError);
var
  Alert: string;
begin
  if AError.Category = tecAlert then
  begin
    Alert := ClientAuthAlertOf(AError);
    if Alert <> '' then
      raise EHttpTlsClientAuthError.Create(AError.Message, Alert);
  end;
  case AError.Category of
    tecTimeout: raise EHttpTimeout.Create(AError.Message);
    tecTransportEof: raise EHttpConnectionClosed.Create(AError.Message);
    tecConfiguration: raise EHttpTlsConfigError.Create(AError.Message);
    tecVerification, tecProtocol, tecAlert, tecInternal:
      raise EHttpConnectionError.Create(AError.Message);
  end;
end;

procedure TTlsSocket.ReadPeerAlertAfterWriteFailure;
var
  PreviousTimeout, N: Integer;
  Data: TBytes;
  Deadline, NowMs: QWord;
  Used: SizeInt;
  ReadNeeded: Boolean;
begin
  // Some TLS 1.3 servers reject a client certificate only after they receive
  // application data.  With HTTP/2, the connection preface is the first data;
  // a server can send its TLS alert and reset the socket before the preface
  // write completes.  Read until a terminal TLS result or a short absolute
  // deadline so a preceding record fragment cannot hide the alert.  A timeout
  // or EOF leaves the original write error as the connection failure.
  // The caller does not hold the session lock.  The method holds it only to
  // look at or to change the session state, and never across the transport
  // read, so other threads can use the session while the read waits.
  // Do not invert the ordinary reader -> session lock order.
  if not FReadLock.TryEnter then
    Exit;
  try
    PreviousTimeout := FTransport.ReadTimeoutMs;
    try
      Deadline := mormot.core.os.GetTickCount64 + 100;
      repeat
        NowMs := mormot.core.os.GetTickCount64;
        if NowMs >= Deadline then
          Break;
        FTransport.ReadTimeoutMs := Integer(Deadline - NowMs);
        try
          N := 0;
          FSessionLock.Acquire;
          try
            ReadNeeded := Length(FEncryptedPending) = 0;
          finally
            FSessionLock.Release;
          end;
          if ReadNeeded then
          begin
            SetLength(Data, TlsMaxEncryptedInput);
            N := FReader.ReadSome(Data[0], Length(Data));
          end;
          FSessionLock.Acquire;
          try
            if ReadNeeded then
            begin
              if N <= 0 then
              begin
                FTransportEof := True;
                NotifyTransportEof;
                Break;
              end;
              if N > Length(Data) then
                Break;
              SetLength(Data, N);
              FEncryptedPending := Data;
              FEncryptedOffset := 0;
            end;
            try
              Used := FSession.FeedEncrypted(FEncryptedPending,
                FEncryptedOffset, Length(FEncryptedPending) - FEncryptedOffset);
            except
              on E: ETlsSessionError do
                MapSessionError(E);
            end;
            if (Used <= 0) or
               (Used > Length(FEncryptedPending) - FEncryptedOffset) then
              Break;
            Inc(FEncryptedOffset, Used);
            if FEncryptedOffset >= Length(FEncryptedPending) then
            begin
              FEncryptedPending := nil;
              FEncryptedOffset := 0;
            end;
            InterlockedIncrement(FInputGeneration);
            RTLEventSetEvent(FInputProgress);
            AdvanceSession;
          finally
            FSessionLock.Release;
          end;
        except
          on E: EHttpTlsClientAuthError do
            raise;
          on Exception do
            Break; // keep the transport write error without a TLS auth alert
        end;
      until False;
    finally
      FTransport.ReadTimeoutMs := PreviousTimeout;
    end;
  finally
    FReadLock.Release;
    RTLEventSetEvent(FInputProgress);
  end;
end;

function TTlsSocket.AdvanceSession: TTlsProgress;
var E: ETlsSessionError;
begin
  try
    Result := FSession.Advance(mormot.core.os.GetTickCount64);
  except
    on E: ETlsSessionError do MapSessionError(E);
  end;
end;

procedure TTlsSocket.NotifyTransportEof;
var E: ETlsSessionError;
begin
  try
    FSession.NotifyTransportEof;
  except
    on E: ETlsSessionError do MapSessionError(E);
  end;
end;

function TTlsSocket.ReadEncrypted: Boolean;
var
  N, Used, RetryCount: SizeInt;
  Progress: Boolean;
  P: TTlsProgress;
begin
  Result := False;
  if Length(FEncryptedPending) = 0 then
  begin
    SetLength(FEncryptedPending, TlsMaxEncryptedInput);
    N := FReader.ReadSome(FEncryptedPending[0], Length(FEncryptedPending));
    if N <= 0 then
    begin
      FEncryptedPending := nil;
      FTransportEof := True;
      InterlockedIncrement(FInputGeneration);
      RTLEventSetEvent(FInputProgress);
      NotifyTransportEof;
      Exit;
    end;
    if N > Length(FEncryptedPending) then
      raise EHttpConnectionError.Create('transport returned an invalid read count');
    SetLength(FEncryptedPending, N);
    FEncryptedOffset := 0;
  end;
  RetryCount := 0;
  repeat
    try
      Used := FSession.FeedEncrypted(FEncryptedPending, FEncryptedOffset,
        Length(FEncryptedPending) - FEncryptedOffset);
    except
      on E: ETlsSessionError do MapSessionError(E);
    end;
    if Used <> 0 then Break;
    P := AdvanceSession;
    Progress := P.MadeProgress or FlushEncrypted;
    if not Progress or (RetryCount >= 63) then Break;
    Inc(RetryCount);
  until False;
  if (Used < 0) or
     (Used > Length(FEncryptedPending) - FEncryptedOffset) then
    raise EHttpConnectionError.Create('TLS session returned an invalid input count');
  Result := Used > 0;
  Inc(FEncryptedOffset, Used);
  if FEncryptedOffset >= Length(FEncryptedPending) then
  begin
    FEncryptedPending := nil;
    FEncryptedOffset := 0;
  end;
  if Used > 0 then AdvanceSession;
  if Used > 0 then
  begin
    InterlockedIncrement(FInputGeneration);
    RTLEventSetEvent(FInputProgress);
  end;
  FlushEncrypted;
end;

function TTlsSocket.ReadApplicationEncrypted: Boolean;
var
  Data: TBytes;
  N: SizeInt;
begin
  Result := False;
  SetLength(Data, TlsMaxEncryptedInput);
  FSessionLock.Release;
  try
    N := FReader.ReadSome(Data[0], Length(Data));
  finally
    FSessionLock.Acquire;
  end;
  if not FConnected then
    Exit;
  if N <= 0 then
  begin
    FTransportEof := True;
    InterlockedIncrement(FInputGeneration);
    RTLEventSetEvent(FInputProgress);
    NotifyTransportEof;
    Exit;
  end;
  if N > Length(Data) then
    raise EHttpConnectionError.Create('transport returned an invalid read count');
  SetLength(Data, N);
  FEncryptedPending := Data;
  FEncryptedOffset := 0;
  Result := ReadEncrypted;
end;

procedure TTlsSocket.Pump(const AReadInput: Boolean);
var
  P: TTlsProgress;
  Fed, OwnsReader: Boolean;
  InputGeneration: LongInt;
  WaitDeadlineMs: QWord;
begin
  P := AdvanceSession; FlushEncrypted;
  if AReadInput and P.NeedInput then
  begin
    if (FHandshakeDeadlineMs > 0) and
       (FSession.State in [tssNew, tssHandshaking]) then
    begin
      if mormot.core.os.GetTickCount64 >= QWord(FHandshakeDeadlineMs) then
        raise EHttpTimeout.Create('TLS handshake timed out');
      FTransport.ReadTimeoutMs := FHandshakeDeadlineMs - mormot.core.os.GetTickCount64;
    end;
    RTLEventResetEvent(FInputProgress);
    InputGeneration := InterlockedCompareExchange(FInputGeneration, 0, 0);
    WaitDeadlineMs := 0;
    if FTransport.ReadTimeoutMs > 0 then
      WaitDeadlineMs := mormot.core.os.GetTickCount64 +
        QWord(FTransport.ReadTimeoutMs);
    FSessionLock.Release;
    try
      OwnsReader := FReadLock.TryEnter;
      if not OwnsReader then
      begin
        // An application reader may be waiting for more plaintext. Wake when
        // it feeds input or releases the reader lock after an error/timeout.
        while FConnected and
          (InterlockedCompareExchange(FInputGeneration, 0, 0) = InputGeneration) and
          not OwnsReader do
        begin
          if (WaitDeadlineMs > 0) and
             (mormot.core.os.GetTickCount64 >= WaitDeadlineMs) then
            raise EHttpTimeout.Create('TLS transport read timed out');
          RTLEventWaitFor(FInputProgress, 100);
          if FConnected and
             (InterlockedCompareExchange(FInputGeneration, 0, 0) = InputGeneration) then
            OwnsReader := FReadLock.TryEnter;
        end;
      end;
      if OwnsReader then
      begin
        FSessionLock.Acquire;
        try
          if FConnected then
          begin
            if Length(FEncryptedPending) > 0 then
              Fed := ReadEncrypted
            else
              Fed := ReadApplicationEncrypted;
            if not Fed and (Length(FEncryptedPending) > 0) then
              raise ETlsSessionError.Create(
                'TLS session cannot accept more encrypted input', tecProtocol);
            if (FHandshakeDeadlineMs > 0) and
               (FSession.State = tssOpen) then
            begin
              FHandshakeDeadlineMs := 0;
              FTransport.ReadTimeoutMs := FTransport.ConnectTimeoutMs;
            end;
          end;
        finally
          FSessionLock.Release;
          FReadLock.Release;
        end;
      end
    finally
      // Pump is called with FSessionLock held, including when reading fails.
      FSessionLock.Acquire;
    end;
    AdvanceSession; FlushEncrypted;
  end;
end;

function TTlsSocket.GetPlain(var ABuffer; const ACount: Integer): Integer;
var B: TBytes;
begin
  if ACount <= 0 then Exit(0);
  if Length(FPlainBuffer) > 0 then
  begin
    Result := ACount;
    if Result > Length(FPlainBuffer) then Result := Length(FPlainBuffer);
    Move(FPlainBuffer[0], ABuffer, Result);
    Delete(FPlainBuffer, 0, Result);
    Exit;
  end;
  SetLength(B, ACount); Result := FSession.ReadPlaintext(B, 0, ACount);
  if Result > 0 then Move(B[0], ABuffer, Result);
end;

function IsIpLiteral(const AHost: string): Boolean;
var
  Host: string;
  V4: LongWord;
  V6: array[0..15] of Byte;
begin
  Host := AHost;
  if (Length(Host) > 1) and (Host[1] = '[') and
     (Host[Length(Host)] = ']') then
    Host := Copy(Host, 2, Length(Host) - 2);
  Result := Http2.Client.Proxy.ParseIp4Literal(Host, V4) or
    Http2.Client.Proxy.ParseIp6Literal(Host, V6);
end;

/// True when the session holds plaintext, an alert or an end of stream, or
// when the transport is readable and the bytes in it give one of these.  A
// read that gives no plaintext (a TLS 1.3 NewSessionTicket, a key update)
// leaves the socket not pending.  Plaintext that the check reads stays in
// FPlainBuffer for the next read.  The caller holds both locks.
function TTlsSocket.PollSessionInput: Boolean;
var
  Source: IPendingInput;
  Chunk: TBytes;
  N: SizeInt;
begin
  Result := True;
  try
    if (Length(FPlainBuffer) > 0) or (FSession.PendingPlaintext > 0) or
       FTransportEof or (FSession.State in [tssClosed, tssFailed]) then
      Exit;
    Result := False;
    if not Supports(FTransport, IPendingInput, Source) then
      Exit;
    while (Length(FEncryptedPending) > 0) or Source.HasPendingInput do
    begin
      if not ReadEncrypted and not FTransportEof then
        Exit(True);   // the session holds input that it cannot take
      AdvanceSession;
      FlushEncrypted;
      SetLength(Chunk, TlsMaxEncryptedInput);
      N := FSession.ReadPlaintext(Chunk, 0, Length(Chunk));
      if N > 0 then
      begin
        SetLength(Chunk, N);
        FPlainBuffer := Chunk;
        Exit(True);
      end;
      if FTransportEof or (FSession.State in [tssClosed, tssFailed]) then
        Exit(True);
    end;
  except
    on Exception do Result := True;   // the next read reports the problem
  end;
end;

procedure TTlsSocket.EnableInterrupt;
var
  Transport: IReadInterrupt;
begin
  if Supports(FTransport, IReadInterrupt, Transport) then
    Transport.EnableInterrupt;
end;

procedure TTlsSocket.InterruptRead;
var
  Transport: IReadInterrupt;
begin
  if Supports(FTransport, IReadInterrupt, Transport) then
    Transport.InterruptRead;
end;

function TTlsSocket.HasPendingInput: Boolean;
begin
  if not FConnected then
    Exit(False);
  Result := True;   // a socket in use is not idle
  if not FReadLock.TryEnter then
    Exit;
  try
    if not FSessionLock.TryEnter then
      Exit;
    try
      Result := PollSessionInput;
    finally
      FSessionLock.Release;
    end;
  finally
    FReadLock.Release;
  end;
end;

procedure TTlsSocket.PutPlain(const ABuffer; const ACount: Integer);
var B: TBytes; Accepted, N: SizeInt; P: TTlsProgress;
begin
  if ACount <= 0 then Exit;
  if not FConnected then
    raise EHttpConnectionClosed.Create('TLS socket is closed');
  SetLength(B, ACount); Move(ABuffer, B[0], ACount); Accepted := 0;
  while Accepted < ACount do
  begin
    if FTransportEof or (FSession.State = tssClosed) then
      raise EHttpConnectionClosed.Create('TLS transport is closed');
    if FSession.State = tssFailed then
      raise ETlsSessionError.Create('TLS session is not writable', tecProtocol);
    N := FSession.WritePlaintext(B, Accepted, ACount - Accepted);
    if (N < 0) or (N > ACount - Accepted) then
      raise EHttpConnectionError.Create('TLS session returned an invalid write count');
    Inc(Accepted, N);
    if N = 0 then
    begin
      P := AdvanceSession;
      FlushEncrypted;
      if P.NeedInput then
        Pump(True)
      else if not P.MadeProgress then
        raise EHttpConnectionError.Create('TLS session made no write progress');
    end
    else
      Pump(False);
  end;
  Pump(False);
end;

function DecodeAlpn(const AData: TBytes): TStringArray;
var I, P, N: Integer;
begin
  Result := nil; P := 0;
  while P < Length(AData) do begin
    N := AData[P]; Inc(P); if P + N > Length(AData) then Break;
    I := Length(Result); SetLength(Result, I + 1);
    SetString(Result[I], PAnsiChar(@AData[P]), N); Inc(P, N);
  end;
end;

class function TTlsSocket.Dial(const AHost: string; const APort: Word;
  const AInsecure: Boolean; const AConnectTimeoutMs: Integer;
  const ACACertFile, AProxyHost: string; const AProxyPort: Word;
  const AIdentity: IClientIdentity; const AContext: ITLSContext;
  const AUnixPath: string): IHttp2Socket;
var T: IHttp2Socket;
begin
  RejectLegacyTlsPolicy(AInsecure, ACACertFile);
  RequireClientTlsContext(AContext, 'origin');
  if AUnixPath <> '' then
    T := TPlainSocket.CreateUnix(AUnixPath, AConnectTimeoutMs)
  else
    T := TPlainSocket.Create(AHost, APort, AConnectTimeoutMs, AProxyHost, AProxyPort);
  Result := TTlsSocket.Create(T, AHost, AContext, AIdentity, [cHttp2AlpnProtocol], AConnectTimeoutMs);
end;

class function TTlsSocket.DialWithAlpn(const AHost: string; const APort: Word;
  const AAlpnOffer: TBytes; const AInsecure: Boolean;
  const AConnectTimeoutMs: Integer; const ACACertFile, AProxyHost: string;
  const AProxyPort: Word; const AIdentity: IClientIdentity;
  const AContext: ITLSContext; const AUnixPath: string): IHttp2Socket;
var T: IHttp2Socket;
begin
  RejectLegacyTlsPolicy(AInsecure, ACACertFile);
  RequireClientTlsContext(AContext, 'origin');
  if AUnixPath <> '' then
    T := TPlainSocket.CreateUnix(AUnixPath, AConnectTimeoutMs)
  else
    T := TPlainSocket.Create(AHost, APort, AConnectTimeoutMs, AProxyHost, AProxyPort);
  Result := TTlsSocket.Create(T, AHost, AContext, AIdentity, DecodeAlpn(AAlpnOffer), AConnectTimeoutMs);
end;

class function TTlsSocket.DialCleartext(const AHost: string; const APort: Word;
  const AConnectTimeoutMs: Integer; const AProxyHost: string;
  const AProxyPort: Word; const AUnixPath: string): IHttp2Socket;
begin
  if AUnixPath <> '' then
    Exit(TPlainSocket.CreateUnix(AUnixPath, AConnectTimeoutMs));
  Result := TPlainSocket.Create(AHost, APort, AConnectTimeoutMs, AProxyHost, AProxyPort);
end;

class function TTlsSocket.DialVia(const AHost: string; const APort: Word;
  const AInsecure: Boolean; const AConnectTimeoutMs: Integer;
  const ACACertFile: string; const AProxy: IProxy;
  const AIdentity, AProxyIdentity: IClientIdentity;
  const AContext, AProxyContext: ITLSContext; const AUnixPath: string): IHttp2Socket;
begin
  RejectLegacyTlsPolicy(AInsecure, ACACertFile);
  Result := DialWithAlpnVia(AHost, APort, AlpnProtocolList([cHttp2AlpnProtocol]),
    AInsecure, AConnectTimeoutMs, ACACertFile, AProxy, AIdentity, AProxyIdentity,
    AContext, AProxyContext, False, AUnixPath);
end;

class function TTlsSocket.DialWithAlpnVia(const AHost: string; const APort: Word;
  const AAlpnOffer: TBytes; const AInsecure: Boolean;
  const AConnectTimeoutMs: Integer; const ACACertFile: string;
  const AProxy: IProxy; const AIdentity, AProxyIdentity: IClientIdentity;
  const AContext, AProxyContext: ITLSContext;
  const AIdentityExplicit: Boolean; const AUnixPath: string): IHttp2Socket;
var T: IHttp2Socket; IsStream: Boolean;
begin
  RejectLegacyTlsPolicy(AInsecure, ACACertFile);
  RequireClientTlsContext(AContext, 'origin');
  T := DialRoutedTransport(AHost, APort, AConnectTimeoutMs, AProxy, AInsecure, ACACertFile, AProxyIdentity, IsStream, AProxyContext, AUnixPath);
  Result := TTlsSocket.Create(T, AHost, AContext, AIdentity,
    DecodeAlpn(AAlpnOffer), AConnectTimeoutMs, AIdentityExplicit);
end;

class function TTlsSocket.DialCleartextVia(const AHost: string; const APort: Word;
  const AConnectTimeoutMs: Integer; const AProxy: IProxy;
  const AInsecure: Boolean; const ACACertFile: string;
  const AProxyIdentity: IClientIdentity; const AProxyContext: ITLSContext;
  const AUnixPath: string): IHttp2Socket;
var IsStream: Boolean;
begin
  RejectLegacyTlsPolicy(AInsecure, ACACertFile);
  Result := DialRoutedTransport(AHost, APort, AConnectTimeoutMs, AProxy,
    AInsecure, ACACertFile, AProxyIdentity, IsStream, AProxyContext, AUnixPath);
end;

function TTlsSocket.ReadSome(var ABuffer; ACount: Integer): Integer;
var P: TTlsProgress; Fed: Boolean;
begin
  try
    FReadLock.Acquire;
    try
      if ACount <= 0 then Exit(0);
      repeat
        FSessionLock.Acquire;
        try
          Result := GetPlain(ABuffer, ACount);
          if Result > 0 then Exit;
          if not FConnected or (FSession.State in [tssClosed, tssFailed]) then
            Exit(0);
          P := AdvanceSession;
          FlushEncrypted;
          if not P.NeedInput then
            Continue;
          if Length(FEncryptedPending) > 0 then
            Fed := ReadEncrypted
          else
            Fed := ReadApplicationEncrypted;
          if not FConnected then
            Exit(0);
          if not Fed and (Length(FEncryptedPending) > 0) then
          begin
            Result := GetPlain(ABuffer, ACount);
            if Result > 0 then Exit;
            raise ETlsSessionError.Create(
              'TLS session cannot accept more encrypted input', tecProtocol);
          end;
        finally
          FSessionLock.Release;
        end;
      until False;
    finally
      FReadLock.Release;
      RTLEventSetEvent(FInputProgress);
    end;
  except
    on E: ETlsSessionError do MapSessionError(E);
  end;
end;

function TTlsSocket.Read(var ABuffer; ACount: Integer): Integer;
var P: PByte; N: Integer;
begin
  Result := 0; P := PByte(@ABuffer);
  while Result < ACount do begin
    try
      N := ReadSome(P[Result], ACount - Result);
    except
      on EHttpTimeout do
        if Result > 0 then Break   // keep the consumed bytes; the caller reads on
        else raise;
    end;
    if N <= 0 then Break;
    Inc(Result, N);
  end;
end;

function TTlsSocket.Write(const ABuffer; ACount: Integer): Integer;
begin
  try
    FSessionLock.Acquire;
    try PutPlain(ABuffer, ACount); Result := ACount;
    finally FSessionLock.Release; end;
  except
    on E: ETlsSessionError do MapSessionError(E);
  end;
end;

procedure TTlsSocket.Close;
begin
  if not FConnected then Exit;
  FConnected := False;
  RTLEventSetEvent(FInputProgress);
  if FTransport <> nil then FTransport.Close;
  FSessionLock.Acquire;
  try if FSession <> nil then FSession.Abort;
  finally FSessionLock.Release; end;
end;

function TTlsSocket.GetConnected: Boolean; begin Result := FConnected and FTransport.Connected; end;
function TTlsSocket.GetConnectTimeoutMs: Integer; begin Result := FTransport.ConnectTimeoutMs; end;
procedure TTlsSocket.SetConnectTimeoutMs(const AValue: Integer); begin FTransport.ConnectTimeoutMs := AValue; end;
function TTlsSocket.GetReadTimeoutMs: Integer; begin Result := FTransport.ReadTimeoutMs; end;
procedure TTlsSocket.SetReadTimeoutMs(const AValue: Integer); begin FTransport.ReadTimeoutMs := AValue; end;
function TTlsSocket.GetWriteTimeoutMs: Integer; begin Result := FTransport.WriteTimeoutMs; end;
procedure TTlsSocket.SetWriteTimeoutMs(const AValue: Integer); begin FTransport.WriteTimeoutMs := AValue; end;
function TTlsSocket.NegotiatedTlsInfo: TTlsNegotiatedInfo; begin Result := FInfo; end;
function TTlsSocket.SelectedProtocol: string; begin Result := FProtocol; end;

function DialProxyTlsSocket(const ATransport: IHttp2Socket; const AHost: string;
  const AContext: ITLSContext; const AIdentity: IClientIdentity;
  const ATimeoutMs: Integer): IHttp2Socket;
begin
  RequireClientTlsContext(AContext, 'HTTPS proxy');
  Result := TTlsSocket.Create(ATransport, AHost, AContext, AIdentity, [], ATimeoutMs);
end;

end.

{**
---
license: Apache-2.0 OR (LGPL-2.1-only WITH Independent-modules-exception)
copyright: Copyright 2026 Liam Seamus Coughlin
keywords: http2, client, websocket, tunnel, lease
notes:
  - This unit runs a byte tunnel over one stream lease, for a WebSocket over HTTP/2 (RFC 8441).
  - Two locks guard the lease. The send lock of the tunnel is taken first, then the pool lock of the pooled connection (the lock of the lease). No path takes the send lock while it holds the pool lock.
  - The pool lock is held exactly once around each call of the lease, because the credit wait of the lease releases it once.
  - Reset and Release stop a parked sender first (StopSend), then take the send lock, so that the sender ends before the tunnel posts RST_STREAM or releases the lease. The sender posts the RST_STREAM when it ends a parked send, so the tunnel posts it only when no send did.
---
}
unit Http2.Client.WebSocket.LeaseTunnel;

{$mode delphi}{$H+}
{$interfaces com}

interface

uses
  SysUtils, SyncObjs, Http2.Client.Errors, Http2.Common.Frames, Http2.Common.Errors,
  Http2.Client.Connection, Http2.Client.Stream, Http2.Client.Stream.Types,
  Http2.Client.Tunnel.Types;

type
  /// a byte tunnel over one stream lease whose request is open and whose response headers arrived
  // - the lease is the one of the pool entry (story C1); the tunnel never starts it
  // - the poll of ReadSome is the body-read time of the request (WithBodyReadTimeout);
  //   the lease has no per-call poll, so the ATimeoutMs argument is not used
  TLeaseTunnel = class(TInterfacedObject, IH2Tunnel)
  private
    FLease: TStreamLease;
    FKeep: IConnectionStream;     // keeps the lease alive while the tunnel lives
    FConnection: TConnection;     // weak: the pooled connection outlives the tunnel
    FPoolLock: TCriticalSection;  // weak: the WaitLock of the lease (the pool lock)
    FSendLock: TCriticalSection;  // owned: serializes the senders of this tunnel
    FEndSent: Boolean;            // guarded by FPoolLock
    FResetDone: Boolean;          // guarded by FPoolLock
    FReleased: Boolean;           // guarded by FPoolLock
    procedure LockPool;
    procedure UnlockPool;
    /// the stream was reset, failed or was stopped by EmitData (the peer side)
    function RemoteReset: Boolean;
    /// the peer ended the stream with END_STREAM or RST_STREAM (not a local stop)
    function PeerEnded: Boolean;
    /// the stream is closed on the wire, so no RST_STREAM may be sent
    function StreamClosed: Boolean;
    /// the send side of the stream ended (END_STREAM sent or the lease half-closed)
    function LocalSideDone: Boolean;
    /// the reason SendData must not send, or '' when it may send
    function SendRefusal: string;
    /// send RST_STREAM CANCEL when the stream is not closed, then release the lease
    procedure ResetLocked;
    /// stop a parked sender, wait for the send in progress, then release the lease;
    // APostReset posts RST_STREAM CANCEL first, unless a send already did
    procedure StopAndRelease(const APostReset: Boolean);
  public
    /// the lease must have its WaitLock set (the pool lock); AConnection posts RST_STREAM
    constructor Create(const ALease: TStreamLease; const AConnection: TConnection);
    destructor Destroy; override;
    /// send AData as DATA; blocks for credit; raises EHttpConnectionError when the stream ended
    procedure SendData(const AData: TBytes);
    /// half-close: END_STREAM with no data (once; no effect after a reset or release)
    procedure EndSend;
    /// wait for at least one octet; returns the count, 0 at END_STREAM, -1 when the poll ran out
    function ReadSome(var ABuffer; ACount: Integer; ATimeoutMs: Integer): Integer;
    /// RST_STREAM with CANCEL unless the stream is closed or already reset; releases the lease (idempotent)
    procedure Reset;
    /// true once both directions ended, the stream was reset or the tunnel was released
    function IsEnded: Boolean;
    /// true when the peer reset the stream or the connection failed the stream
    function EndedAbnormally: Boolean;
    /// release the lease without a RST_STREAM (idempotent)
    procedure Release;
  end;

implementation

constructor TLeaseTunnel.Create(const ALease: TStreamLease;
  const AConnection: TConnection);
begin
  inherited Create;
  if (ALease = nil) or (AConnection = nil) then
    raise EHttpError.Create('a tunnel needs a lease and a connection',
      ecInternalError);
  if ALease.WaitLock = nil then
    raise EHttpError.Create('a tunnel needs the pool lock of its lease',
      ecInternalError);
  FLease := ALease;
  FKeep := ALease;
  FConnection := AConnection;
  FPoolLock := ALease.WaitLock;
  FSendLock := TCriticalSection.Create;
end;

destructor TLeaseTunnel.Destroy;
begin
  // FPC also runs the destructor when the constructor raised, before FLease is set
  if FLease <> nil then
    Release;
  FSendLock.Free;
  inherited Destroy;
end;

procedure TLeaseTunnel.LockPool;
begin
  FPoolLock.Acquire;
end;

procedure TLeaseTunnel.UnlockPool;
begin
  FPoolLock.Release;
end;

function TLeaseTunnel.RemoteReset: Boolean;
begin
  Result := FLease.RstReceived or (FLease.PeerReset <> 0) or FLease.Failed;
end;

function TLeaseTunnel.PeerEnded: Boolean;
begin
  // a StopSend sets PeerDone too, but that is not the peer's end
  Result := FLease.PeerDone = cPeerDoneByPeer;
end;

function TLeaseTunnel.StreamClosed: Boolean;
begin
  // RFC 9113 section 5.1: a closed stream takes no frame but PRIORITY
  Result := RemoteReset or FLease.UploadStopped or
    (FLease.LocalState = lsClosed) or
    (LocalSideDone and PeerEnded);
end;

function TLeaseTunnel.LocalSideDone: Boolean;
begin
  Result := FEndSent or (FLease.LocalState = lsLocalHalfClosed) or
    (FLease.LocalState = lsClosed);
end;

function TLeaseTunnel.SendRefusal: string;
begin
  Result := '';
  if FReleased then
    Result := 'the WebSocket stream is released'
  else if FResetDone or RemoteReset or FLease.UploadStopped then
    Result := 'the WebSocket stream was reset or failed'
  else if PeerEnded then
    Result := 'the peer ended the WebSocket stream'
  else if LocalSideDone then
    Result := 'the send side of the WebSocket stream is closed';
end;

procedure TLeaseTunnel.ResetLocked;
begin
  if FResetDone then
    Exit;
  FResetDone := True;
  // the reset goes out only when the stream is still open on the wire
  if not StreamClosed then
    FConnection.PostFrame(BuildRstStreamFrame(FLease.StreamId, ecCancel));
  FReleased := True;
  FLease.ReleaseLease;
end;

procedure TLeaseTunnel.SendData(const AData: TBytes);
var
  Refusal, Failure: string;
begin
  Refusal := '';
  Failure := '';
  FSendLock.Acquire;
  try
    // the send lock is held before the pool lock (the order of this unit)
    LockPool;
    try
      Refusal := SendRefusal;
      if Refusal = '' then
      begin
        try
          // one call, one pool lock: the credit wait of the lease releases it
          FLease.SendData(AData, False);
        except
          on E: Exception do
            Failure := E.Message;
        end;
        // EmitData drops the rest of a call silently when the peer ended the
        // stream during the wait, so the flag decides whether the octets went out
        if (Failure = '') and FLease.UploadStopped then
        begin
          // a local Reset or Release stops the send too: its reason comes first
          Refusal := SendRefusal;
          if Refusal = '' then
            Refusal := 'the peer ended or reset the WebSocket stream during the send';
        end;
        if Failure <> '' then
          Refusal := 'the send failed: ' + Failure;
      end;
    finally
      UnlockPool;
    end;
    if (Failure <> '') then
    begin
      // a part of a frame may be on the wire: the stream is reset, never left open
      LockPool;
      try
        ResetLocked;
      finally
        UnlockPool;
      end;
    end;
    if Refusal <> '' then
      raise EHttpConnectionError.Create(Refusal);
  finally
    FSendLock.Release;
  end;
end;

procedure TLeaseTunnel.EndSend;
begin
  FSendLock.Acquire;
  try
    LockPool;
    try
      if FEndSent or FReleased then
        Exit;
      FEndSent := True;
      // END_STREAM only on an open send side of a stream that is not closed
      if (FLease.LocalState = lsHeadersSent) and (not StreamClosed) then
        FLease.EndSend;
    finally
      UnlockPool;
    end;
  finally
    FSendLock.Release;
  end;
end;

function TLeaseTunnel.ReadSome(var ABuffer; ACount: Integer;
  ATimeoutMs: Integer): Integer;
begin
  Result := 0;
  if ACount <= 0 then
    Exit;
  try
    LockPool;
    try
      if FReleased then
        raise EHttpConnectionError.Create('the WebSocket stream is released');
      try
        Result := FLease.ReadBody(ABuffer, ACount);
      except
        on E: EHttpTimeout do
          Result := -1;   // the poll found no octet; the lease state is unchanged
      end;
    finally
      UnlockPool;
    end;
  finally
    // the attempt hook is delivered outside the pool lock
    FLease.DeliverEnd;
  end;
end;

procedure TLeaseTunnel.StopAndRelease(const APostReset: Boolean);
begin
  // the stop wakes a sender that waits for credit; it returns with the stream stopped
  FLease.StopSend;
  // the send lock is taken without the pool lock: a send holds it while it waits
  FSendLock.Acquire;
  try
    LockPool;
    try
      // a parked send that ended by the stop posted its own RST_STREAM
      if APostReset and (not FLease.UploadStopped) then
        FConnection.PostFrame(BuildRstStreamFrame(FLease.StreamId, ecCancel));
      FLease.ReleaseLease;
    finally
      UnlockPool;
    end;
  finally
    FSendLock.Release;
  end;
end;

procedure TLeaseTunnel.Reset;
var
  First, PostReset: Boolean;
begin
  First := False;
  PostReset := False;
  LockPool;
  try
    if not FResetDone then
    begin
      FResetDone := True;
      First := True;
      // decided before the stop, which sets PeerDone: the reset goes out only
      // when the stream is still open on the wire
      PostReset := not StreamClosed;
      FReleased := True;
    end;
  finally
    UnlockPool;
  end;
  if First then
    StopAndRelease(PostReset);
end;

function TLeaseTunnel.IsEnded: Boolean;
begin
  LockPool;
  try
    Result := FReleased or FResetDone or RemoteReset or
      (FLease.LocalState = lsClosed) or
      (LocalSideDone and PeerEnded);
  finally
    UnlockPool;
  end;
end;

function TLeaseTunnel.EndedAbnormally: Boolean;
begin
  LockPool;
  try
    Result := RemoteReset;
  finally
    UnlockPool;
  end;
end;

procedure TLeaseTunnel.Release;
var
  First: Boolean;
begin
  First := False;
  LockPool;
  try
    if not FReleased then
    begin
      FReleased := True;
      First := True;
    end;
  finally
    UnlockPool;
  end;
  if First then
    StopAndRelease(False);
end;

end.

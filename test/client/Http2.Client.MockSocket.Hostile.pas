{**
---
license: Apache-2.0 OR (LGPL-2.1-only WITH Independent-modules-exception)
copyright: Copyright 2026 Liam Seamus Coughlin
keywords: client_test_support
notes:
  - this scripts a hostile HTTP/2 peer that sends frames a normal server never sends
---
}
unit Http2.Client.MockSocket.Hostile;

{$mode delphi}{$H+}

interface

uses
  SysUtils, Http2.Common.Frames, Http2.Client.MockSocket.Support,
  Http2.Client.MockSocket.Frames;

type
  /// the action that Flood calls once for each index
  TFloodAction = procedure(AIndex: Integer) of object;

  /// a scripted peer that sends the frames a normal server never sends:
  /// DATA with no end, a CONTINUATION chain, or any raw frame. It feeds the
  /// bytes to a TMockSocket, so the client reads them as wire bytes.
  // - the peer does not own AMock or AServer; the caller frees them
  THostilePeer = class
  private
    FMock: TMockSocket;
    FServer: TScriptedServer;
  public
    constructor Create(const AMock: TMockSocket; const AServer: TScriptedServer);
    /// send ACount bytes of 'A' as one DATA frame
    procedure SendData(AStreamId: LongWord; ACount: Integer; AEndStream: Boolean);
    /// send a HEADERS frame that carries one part of a header block
    procedure SendHeadersFragment(AStreamId: LongWord; const AFragment: TBytes;
      AEndStream, AEndHeaders: Boolean);
    /// send a CONTINUATION frame that carries the next part of a header block
    procedure SendContinuation(AStreamId: LongWord; const AFragment: TBytes;
      AEndHeaders: Boolean);
    /// send any frame, with its header fields exactly as built
    procedure SendFrame(const AFrame: TFrame);
    /// call AAction ACount times, with the index 0 to ACount - 1
    procedure Flood(ACount: Integer; const AAction: TFloodAction);
    /// the frames that the client wrote, after the 24-byte preface
    function WrittenFrames: TArray<TFrame>;
  end;

implementation

constructor THostilePeer.Create(const AMock: TMockSocket;
  const AServer: TScriptedServer);
begin
  inherited Create;
  FMock := AMock;
  FServer := AServer;
end;

procedure THostilePeer.SendData(AStreamId: LongWord; ACount: Integer;
  AEndStream: Boolean);
var
  Data: TBytes;
begin
  SetLength(Data, ACount);
  if ACount > 0 then
    FillChar(Data[0], ACount, Ord('A'));
  SendFrame(BuildDataFrame(AStreamId, Data, AEndStream));
end;

procedure THostilePeer.SendHeadersFragment(AStreamId: LongWord;
  const AFragment: TBytes; AEndStream, AEndHeaders: Boolean);
begin
  SendFrame(BuildHeadersFrame(AStreamId, AFragment, AEndHeaders, AEndStream));
end;

procedure THostilePeer.SendContinuation(AStreamId: LongWord;
  const AFragment: TBytes; AEndHeaders: Boolean);
begin
  SendFrame(BuildContinuationFrame(AStreamId, AFragment, AEndHeaders));
end;

procedure THostilePeer.SendFrame(const AFrame: TFrame);
begin
  FMock.Feed(FrameToBytes(AFrame));
end;

procedure THostilePeer.Flood(ACount: Integer; const AAction: TFloodAction);
var
  I: Integer;
begin
  for I := 0 to ACount - 1 do
    AAction(I);
end;

function THostilePeer.WrittenFrames: TArray<TFrame>;
begin
  Result := ParseFrameSequence(FMock.WrittenBytes, True);
end;

end.

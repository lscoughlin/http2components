{**
---
license: Apache-2.0 OR (LGPL-2.1-only WITH Independent-modules-exception)
copyright: Copyright 2026 Liam Seamus Coughlin
keywords: http2, client, exchange
notes:
  - This unit owns stream exchange notification helpers.
---
}
unit Http2.Client.Stream.Exchange;

{$mode delphi}{$H+}
{$interfaces com}

interface

uses
  SysUtils, Http2.Client.Stream.Types, Http2.Client.Errors,
  Http2.Client.Connection;

procedure RecordExchangeEnd(const AExchange: IExchangeObserver;
  var AEndDue: TLeaseEndDue; const AReason: TLeaseEndDue);
procedure FireExchangeEnd(const AExchange: IExchangeObserver;
  var AEndFired: LongInt; const AReason: TLeaseEndDue;
  const AAbandoned: Boolean; const ABytesIn, ABytesOut: Int64;
  const AArrivals: TArrivalStats; AError: Exception);
function ConcatStreamBytes(const A, B: TBytes): TBytes;
function CreateStreamError(const AConnection: TConnection;
  const AMessage: string; const AConnectionError: Boolean;
  const ACode: THttp2ErrorCode; const AStreamId: LongWord): EHttpError;

implementation

procedure RecordExchangeEnd(const AExchange: IExchangeObserver;
  var AEndDue: TLeaseEndDue; const AReason: TLeaseEndDue);
begin
  if (AExchange <> nil) and (AEndDue = edNone) then
    AEndDue := AReason;
end;

procedure FireExchangeEnd(const AExchange: IExchangeObserver;
  var AEndFired: LongInt; const AReason: TLeaseEndDue;
  const AAbandoned: Boolean; const ABytesIn, ABytesOut: Int64;
  const AArrivals: TArrivalStats; AError: Exception);
var
  Info: TExchangeEnd;
begin
  try
    if (AExchange = nil) or
       (InterlockedCompareExchange(AEndFired, 1, 0) <> 0) then
      Exit;
    Info.Abandoned := AAbandoned;
    Info.BytesIn := ABytesIn;
    Info.BytesOut := ABytesOut;
    Info.Arrivals := AArrivals;
    Info.Error := AError;
    try
      AExchange.ExchangeEnded(Info);
    except
      // The attempt tracker protects observer callbacks.
    end;
  finally
    AError.Free;
  end;
end;

function ConcatStreamBytes(const A, B: TBytes): TBytes;
var
  N, I: Integer;
begin
  Result := nil;
  N := Length(A);
  SetLength(Result, N + Length(B));
  for I := 0 to N - 1 do
    Result[I] := A[I];
  for I := 0 to High(B) do
    Result[N + I] := B[I];
end;

function CreateStreamError(const AConnection: TConnection;
  const AMessage: string; const AConnectionError: Boolean;
  const ACode: THttp2ErrorCode; const AStreamId: LongWord): EHttpError;
var
  Msg: string;
begin
  Msg := AMessage;
  if Msg = '' then
    Msg := 'stream failed';
  if AConnectionError then
    Result := AConnection.FailureError(Msg, ACode)
  else
    Result := EHttpStreamError.Create(Msg, AStreamId, ACode);
end;

end.

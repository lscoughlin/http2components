{**
---
license: Apache-2.0 OR (LGPL-2.1-only WITH Independent-modules-exception)
copyright: Copyright 2026 Liam Seamus Coughlin
keywords: http2, client, websocket, extended connect, rfc 8441
notes:
  - This unit holds the handshake rules of a WebSocket over HTTP/2 (RFC 8441 section 5). It builds the extended CONNECT request and checks its answer. It has no I/O.
  - The answer rule is the status 200 only. A content-length field and an extension field are reasons to refuse the answer.
---
}
/// The handshake rules of a WebSocket over HTTP/2 (RFC 8441 section 5): the
/// request fields of the extended CONNECT and the check of its answer. The
/// functions have no I/O.
// - depends on Http2.Client.WebSocket for TWsHeaderField and the restricted names
unit Http2.Client.WebSocket.H2Handshake;

{$mode delphi}{$H+}
{$modeswitch advancedrecords}
{$interfaces com}

interface

uses
  SysUtils, Http2.Client.Errors, Http2.Common.Headers, Http2.Common.Status,
  Http2.Client.Stream.Types, Http2.Client.WebSocket;

const
  /// the body-read poll of the WebSocket reader, in milliseconds. A poll that
  /// finds no octet raises EHttpTimeout and leaves the stream as it was.
  cWsH2PollMs = 100;
  /// the ':protocol' value of a WebSocket (RFC 8441 section 5)
  cWsH2Protocol = 'websocket';

/// build the extended CONNECT request of a WebSocket over HTTP/2. ATarget is
/// the path and query, and AAuthority is the ':authority' value. The request
/// keeps its stream open and has no body. It sets no response limit, because
/// the stream is a long-lived conversation. Raises EHttpWebSocketError when a
/// caller header is set by the handshake, is not valid, or cannot be sent on
/// the stream.
function WsBuildH2Request(const ASecure: Boolean; const ATarget, AAuthority: string;
  const ASubprotocols: TArray<string>;
  const AHeaders: TArray<TWsHeaderField>): TStreamRequest;

/// check the 200 answer to the extended CONNECT. Returns '' when the answer is
/// acceptable (AChosen is the selected subprotocol, or '' when none was
/// selected). Else returns the reason. The accept field is ignored.
function WsCheckH2Response(const AStatus: Integer;
  const AFields: TArray<TWsHeaderField>; const AOffered: TArray<string>;
  out AChosen: string): string;

implementation

/// the values of every field with the name AName, in wire order
function FieldValues(const AFields: TArray<TWsHeaderField>;
  const AName: string): TArray<string>;
var
  I, N: Integer;
begin
  Result := nil;
  SetLength(Result, Length(AFields));
  N := 0;
  for I := 0 to High(AFields) do
    if SameText(AFields[I].Name, AName) then
    begin
      Result[N] := AFields[I].Value;
      Inc(N);
    end;
  SetLength(Result, N);
end;

/// split every value at its commas; each item is one list entry
function SplitList(const AValues: TArray<string>): TArray<string>;
var
  I, N, P: Integer;
  V, Item: string;
begin
  Result := nil;
  N := 0;
  for I := 0 to High(AValues) do
  begin
    V := AValues[I];
    while True do
    begin
      P := Pos(',', V);
      if P = 0 then
        Item := V
      else
        Item := Copy(V, 1, P - 1);
      SetLength(Result, N + 1);
      Result[N] := Trim(Item);
      Inc(N);
      if P = 0 then
        Break;
      V := Copy(V, P + 1, MaxInt);
    end;
  end;
end;

function ListContains(const AList: TArray<string>; const AItem: string): Boolean;
var
  I: Integer;
begin
  Result := False;
  for I := 0 to High(AList) do
    if AList[I] = AItem then
      Exit(True);
end;

function SchemeOf(const ASecure: Boolean): string;
begin
  if ASecure then
    Result := 'https'
  else
    Result := 'http';
end;

procedure CheckCallerHeader(const AHeader: TWsHeaderField; out AName: string);
begin
  AName := LowerCase(Trim(AHeader.Name));
  if not WsIsHttpToken(AName) then
    raise EHttpWebSocketError.CreateFmt('"%s" is not a header name', [AHeader.Name]);
  if WsIsRestrictedHeader(AName) then
    raise EHttpWebSocketError.CreateFmt(
      'header "%s" is set by the handshake and cannot be supplied', [AName]);
  // a decoded body would break the octets of the WebSocket
  if AName = HeaderAcceptEncoding then
    raise EHttpWebSocketError.CreateFmt(
      'header "%s" cannot be supplied: the stream must not be decoded', [AName]);
  if (Pos(#13, AHeader.Value) > 0) or (Pos(#10, AHeader.Value) > 0) then
    raise EHttpWebSocketError.Create('a header value cannot contain a line break');
end;

function WsBuildH2Request(const ASecure: Boolean; const ATarget, AAuthority: string;
  const ASubprotocols: TArray<string>;
  const AHeaders: TArray<TWsHeaderField>): TStreamRequest;
var
  I: Integer;
  Name, Joined: string;
begin
  // check every caller header before the request holds any of them
  for I := 0 to High(AHeaders) do
    CheckCallerHeader(AHeaders[I], Name);
  for I := 0 to High(ASubprotocols) do
    if not WsIsHttpToken(ASubprotocols[I]) then
      raise EHttpWebSocketError.CreateFmt('"%s" is not a subprotocol name',
        [ASubprotocols[I]]);

  Result := TStreamRequest.WithMethod(hmConnect, AAuthority);
  Result := Result.WithScheme(SchemeOf(ASecure));
  Result := Result.WithPath(ATarget);
  Result := Result.WithProtocol(cWsH2Protocol);
  Result := Result.WithKeepOpen;
  Result := Result.WithBodyReadTimeout(cWsH2PollMs);
  Result.MaxResponseBytes := 0;
  Result.MaxResponseBytesSet := True;

  Result := Result.WithHeader(HeaderSecWebSocketVersion, '13');
  if Length(ASubprotocols) > 0 then
  begin
    Joined := '';
    for I := 0 to High(ASubprotocols) do
    begin
      if I > 0 then
        Joined := Joined + ', ';
      Joined := Joined + ASubprotocols[I];
    end;
    Result := Result.WithHeader(HeaderSecWebSocketProtocol, Joined);
  end;
  for I := 0 to High(AHeaders) do
  begin
    CheckCallerHeader(AHeaders[I], Name);
    Result := Result.WithHeader(Name, AHeaders[I].Value);
  end;
end;

function WsCheckH2Response(const AStatus: Integer;
  const AFields: TArray<TWsHeaderField>; const AOffered: TArray<string>;
  out AChosen: string): string;
var
  Protos, Items: TArray<string>;
begin
  AChosen := '';
  if AStatus <> HttpStatusOk then
    Exit(Format('server answered %d instead of 200', [AStatus]));
  if Length(FieldValues(AFields, HeaderSecWebSocketExtensions)) > 0 then
    Exit('server selected an extension that was not offered');
  if Length(FieldValues(AFields, HeaderContentLength)) > 0 then
    Exit(Format('response has a "%s" field, but the stream has no length',
      [HeaderContentLength]));
  Protos := FieldValues(AFields, HeaderSecWebSocketProtocol);
  if Length(Protos) = 0 then
    Exit('');
  Items := SplitList(Protos);
  if Length(Items) <> 1 then
    Exit('server selected more than one subprotocol');
  if not ListContains(AOffered, Items[0]) then
    Exit(Format('server selected subprotocol "%s" that was not offered',
      [Items[0]]));
  AChosen := Items[0];
  Result := '';
end;

end.

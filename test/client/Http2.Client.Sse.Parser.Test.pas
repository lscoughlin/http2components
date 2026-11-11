{**
---
license: Apache-2.0 OR (LGPL-2.1-only WITH Independent-modules-exception)
copyright: Copyright 2026 Liam Seamus Coughlin
keywords: client_test
notes:
  - this preserves a client test from the source project
---
}
/// Server-Sent Events tests (plan story S14).
// - the parser tests are pure: no socket, no transport. The single most
//   important assertion is chunk-split invariance — the same byte stream fed
//   at EVERY offset must produce the same events (doc/design/
//   server-sent-events.md "Testing"). A parser that only works when a chunk
//   boundary happens to fall on a line break is the classic SSE defect.
// - the transport tests run against the real connection thread over a
//   TMockSocket, so credit flushing and frame routing are genuine; the
//   reconnect tests use a scripted IHttpClient and no transport at all.
unit Http2.Client.Sse.Parser.Test;

{$mode delphi}{$H+}
{$modeswitch advancedrecords}
{$modeswitch typehelpers}
{$interfaces com}

interface

uses
  SysUtils, Classes, SyncObjs, Generics.Collections, fpcunit, testregistry,
  Http2.Client.Errors, Http2.Common.Frames, Http2.Common.Headers, Http2.Common.Hpack, Http2.Client.Tls,
  Http2.Client.Connection, Http2.Client.Stream, Http2.Client.Messages, Http2.Client, Http2.Client.WebSocket,
  Http2.Client.Sse, Http2.Client.MockSocket, Http2.Client.RequestObserver, Http2.Client.Sse.Support;
type
  TSseParserTest = class(TTestCase)
  private
    procedure ParseAll(const AText: string; out AEvents: TArray<TSseEvent>);
  published
    procedure TestSingleEvent;
    procedure TestDataLinesAreJoinedWithNewline;
    procedure TestIncompleteEventAtEofIsDiscarded;
    procedure TestDefaultEventTypeIsMessage;
    procedure TestNamedEventType;
    procedure TestIdSetsLastEventId;
    procedure TestIdWithNulIsIgnored;
    procedure TestRetryIsParsed;
    procedure TestRetryRejectsNonDigits;
    procedure TestCommentIsIgnoredButKeepsAlive;
    procedure TestBlankLineWithoutDataDispatchesNothing;
    procedure TestEventOnlyFieldDoesNotDispatch;
    procedure TestUnknownFieldIsIgnored;
    procedure TestLeadingSpaceIsStrippedOnce;
    procedure TestNoSpaceAfterColon;
    procedure TestValueMayContainColons;
    procedure TestEmptyValue;
    procedure TestCrlfTerminatedStream;
    procedure TestCrOnlyTerminatedStream;
    procedure TestBomIsStrippedOnce;
    procedure TestBomOnlyAtStart;
    procedure TestChunkSplitInvariance;
    procedure TestChunkSplitInvarianceWithCrlfPairs;
    procedure TestSplitUtf8SequenceSurvivesAcrossFeeds;
    procedure TestInvalidUtf8Raises;
    procedure TestOverlongUtf8Raises;
    procedure TestSurrogateUtf8Raises;
    procedure TestRetryMsSurvivesDispatch;
    procedure TestResetClearsState;
  end;

  TSseSourceTest = class(TTestCase)
  private
    function ResponseOf(const AText: string;
      const AContentType: string = cSseContentType;
      const AStatus: LongInt = 200;
      const AEncoding: string = ''): IHttpResponse;
  published
    procedure TestValidateAcceptsEventStream;
    procedure TestValidateAcceptsParametersAndCase;
    procedure TestValidateRejectsOtherStatus;
    procedure TestValidateRejectsOtherContentType;
    procedure TestValidateRejectsNonUtf8Charset;
    procedure TestValidateRejectsContentCoding;
    procedure TestReadEventsFromBody;
    procedure TestReadEventIsIncrementalPerBlankLine;
    procedure TestReadEventReturnsFalseAtEof;
    procedure TestLastEventIdTracksTheStream;
    procedure TestRetryMsTracksTheStream;
    procedure TestCloseStopsFurtherEvents;
  end;

  TSseRequestTest = class(TTestCase)
  published
    procedure TestSseRequestSetsAcceptAndIdentity;
    procedure TestSseRequestWaitsIndefinitelyForTheBody;
    procedure TestOrdinaryRequestKeepsTheLegacyBodyDeadline;
  end;

implementation

procedure TSseParserTest.ParseAll(const AText: string;
  out AEvents: TArray<TSseEvent>);
var
  P: TSseEventParser;
  List: TList<TSseEvent>;
  I: Integer;
begin
  List := TList<TSseEvent>.Create;
  P := TSseEventParser.Create;
  try
    P.Feed(BytesOf(AText), List);
    SetLength(AEvents, List.Count);
    for I := 0 to List.Count - 1 do
      AEvents[I] := List[I];
  finally
    P.Free;
    List.Free;
  end;
end;

procedure TSseParserTest.TestSingleEvent;
var
  Ev: TArray<TSseEvent>;
begin
  ParseAll('data: hello' + #10 + #10, Ev);
  AssertEquals('one event dispatched', 1, Length(Ev));
  AssertEquals('the data payload', 'hello', Ev[0].Data);
  AssertEquals('the default event type', 'message', Ev[0].EventType);
  AssertEquals('no id was set', '', Ev[0].Id);
  AssertEquals('no retry was set', 0, Ev[0].RetryMs);
end;

procedure TSseParserTest.TestDataLinesAreJoinedWithNewline;
var
  Ev: TArray<TSseEvent>;
begin
  ParseAll('data: a' + #10 + 'data: b' + #10 + #10, Ev);
  AssertEquals('one event dispatched', 1, Length(Ev));
  AssertEquals('the lines are joined with a newline', 'a' + #10 + 'b',
    Ev[0].Data);
end;

procedure TSseParserTest.TestIncompleteEventAtEofIsDiscarded;
var
  Ev: TArray<TSseEvent>;
begin
  // WHATWG: the event is dispatched only on the blank line. A stream that
  // ends mid-event (no final blank line) must NOT dispatch the partial
  // event, so a truncated reconnect cannot deliver half an event.
  ParseAll('data: tail', Ev);
  AssertEquals('an unterminated event is not dispatched', 0, Length(Ev));
  ParseAll('data: a' + #10 + #10 + 'data: tail', Ev);
  AssertEquals('only the terminated event is dispatched', 1, Length(Ev));
  AssertEquals('and it is the complete one', 'a', Ev[0].Data);
end;

procedure TSseParserTest.TestDefaultEventTypeIsMessage;
var
  Ev: TArray<TSseEvent>;
begin
  ParseAll('data: x' + #10 + #10, Ev);
  AssertEquals('default event type', cSseDefaultEventType, Ev[0].EventType);
end;

procedure TSseParserTest.TestNamedEventType;
var
  Ev: TArray<TSseEvent>;
begin
  ParseAll('event: ping' + #10 + 'data: x' + #10 + #10, Ev);
  AssertEquals('the named event type', 'ping', Ev[0].EventType);
end;

procedure TSseParserTest.TestIdSetsLastEventId;
var
  Ev: TArray<TSseEvent>;
  P: TSseEventParser;
  L: TList<TSseEvent>;
begin
  ParseAll('id: 42' + #10 + 'data: x' + #10 + #10, Ev);
  AssertEquals('the id is carried on the event', '42', Ev[0].Id);
  // and it survives the dispatch that follows
  P := TSseEventParser.Create;
  L := TList<TSseEvent>.Create;
  try
    P.Feed(BytesOf('id: 42' + #10 + 'data: a' + #10 + #10 +
      'data: b' + #10 + #10), L);
    AssertEquals('two events', 2, L.Count);
    AssertEquals('the id survives the following dispatch', '42',
      P.LastEventId);
    AssertEquals('the second event reports the same id', '42', L[1].Id);
  finally
    P.Free;
    L.Free;
  end;
end;

procedure TSseParserTest.TestIdWithNulIsIgnored;
var
  P: TSseEventParser;
  L: TList<TSseEvent>;
  Raw: TBytes;
begin
  // a value containing a NUL byte makes the whole id field ignored, so the
  // previous id stays in force (WHATWG "id" field)
  P := TSseEventParser.Create;
  L := TList<TSseEvent>.Create;
  try
    Raw := BytesOf('id: ok' + #10 + 'data: a' + #10 + #10 + 'id: bad');
    Raw := Raw + RawBytes([$00]);
    Raw := Raw + BytesOf('x' + #10 + 'data: b' + #10 + #10);
    P.Feed(Raw, L);
    AssertEquals('two events dispatched', 2, L.Count);
    AssertEquals('the NUL id is ignored, the earlier id stays', 'ok',
      P.LastEventId);
    AssertEquals('the first event reports the good id', 'ok', L[0].Id);
    AssertEquals('the second event still reports it', 'ok', L[1].Id);
  finally
    P.Free;
    L.Free;
  end;
end;

procedure TSseParserTest.TestRetryIsParsed;
var
  P: TSseEventParser;
  L: TList<TSseEvent>;
begin
  P := TSseEventParser.Create;
  L := TList<TSseEvent>.Create;
  try
    P.Feed(BytesOf('retry: 1500' + #10 + #10), L);
    AssertEquals('retry alone dispatches nothing', 0, L.Count);
    AssertEquals('the retry value', 1500, P.RetryMs);
  finally
    P.Free;
    L.Free;
  end;
end;

procedure TSseParserTest.TestRetryRejectsNonDigits;
var
  P: TSseEventParser;
  L: TList<TSseEvent>;
begin
  P := TSseEventParser.Create;
  L := TList<TSseEvent>.Create;
  try
    P.Feed(BytesOf('retry: 1500' + #10 + #10), L);
    P.Feed(BytesOf('retry: 12x' + #10 + #10), L);
    AssertEquals('a non-numeric retry is ignored', 1500, P.RetryMs);
  finally
    P.Free;
    L.Free;
  end;
end;

procedure TSseParserTest.TestCommentIsIgnoredButKeepsAlive;
var
  Ev: TArray<TSseEvent>;
begin
  ParseAll(': keep-alive' + #10 + #10 + 'data: x' + #10 + #10, Ev);
  AssertEquals('only the data event dispatched', 1, Length(Ev));
  AssertEquals('the payload', 'x', Ev[0].Data);
end;

procedure TSseParserTest.TestBlankLineWithoutDataDispatchesNothing;
var
  Ev: TArray<TSseEvent>;
begin
  ParseAll('event: ping' + #10 + #10, Ev);
  AssertEquals('an event name without data dispatches nothing', 0,
    Length(Ev));
end;

procedure TSseParserTest.TestEventOnlyFieldDoesNotDispatch;
var
  Ev: TArray<TSseEvent>;
begin
  ParseAll('id: 7' + #10 + 'retry: 100' + #10 + #10, Ev);
  AssertEquals('state-only fields dispatch nothing', 0, Length(Ev));
end;

procedure TSseParserTest.TestUnknownFieldIsIgnored;
var
  Ev: TArray<TSseEvent>;
begin
  ParseAll('foo: bar' + #10 + 'data: x' + #10 + #10, Ev);
  AssertEquals('one event dispatched', 1, Length(Ev));
  AssertEquals('the unknown field is ignored', 'x', Ev[0].Data);
end;

procedure TSseParserTest.TestLeadingSpaceIsStrippedOnce;
var
  Ev: TArray<TSseEvent>;
begin
  // exactly ONE leading space is removed; a second is part of the value
  ParseAll('data:  two' + #10 + #10, Ev);
  AssertEquals('only one leading space is stripped', ' two', Ev[0].Data);
end;

procedure TSseParserTest.TestNoSpaceAfterColon;
var
  Ev: TArray<TSseEvent>;
begin
  ParseAll('data:no-space' + #10 + #10, Ev);
  AssertEquals('a value may follow the colon directly', 'no-space',
    Ev[0].Data);
end;

procedure TSseParserTest.TestValueMayContainColons;
var
  Ev: TArray<TSseEvent>;
begin
  ParseAll('data: a:b:c' + #10 + #10, Ev);
  AssertEquals('only the first colon separates field from value', 'a:b:c',
    Ev[0].Data);
end;

procedure TSseParserTest.TestEmptyValue;
var
  Ev: TArray<TSseEvent>;
begin
  ParseAll('data:' + #10 + #10, Ev);
  AssertEquals('an empty data line still counts as data', 1, Length(Ev));
  AssertEquals('the payload is empty', '', Ev[0].Data);
end;

procedure TSseParserTest.TestCrlfTerminatedStream;
var
  Ev: TArray<TSseEvent>;
begin
  ParseAll('data: a' + #13 + #10 + 'data: b' + #13 + #10 + #13 + #10, Ev);
  AssertEquals('one event dispatched', 1, Length(Ev));
  AssertEquals('CRLF is a line terminator', 'a' + #10 + 'b', Ev[0].Data);
end;

procedure TSseParserTest.TestCrOnlyTerminatedStream;
var
  Ev: TArray<TSseEvent>;
begin
  ParseAll('data: a' + #13 + 'data: b' + #13 + #13, Ev);
  AssertEquals('one event dispatched', 1, Length(Ev));
  AssertEquals('a lone CR is a line terminator', 'a' + #10 + 'b', Ev[0].Data);
end;

procedure TSseParserTest.TestBomIsStrippedOnce;
var
  Ev: TArray<TSseEvent>;
begin
  ParseAll(#$EF + #$BB + #$BF + 'data: x' + #10 + #10, Ev);
  AssertEquals('one event dispatched', 1, Length(Ev));
  AssertEquals('the BOM is not part of the field name', 'x', Ev[0].Data);
end;

procedure TSseParserTest.TestBomOnlyAtStart;
var
  P: TSseEventParser;
  L: TList<TSseEvent>;
  Raw: TBytes;
begin
  // a BOM-looking sequence that is not at the very start is data
  P := TSseEventParser.Create;
  L := TList<TSseEvent>.Create;
  try
    Raw := BytesOf('data: x' + #10 + #10 + 'data: ');
    Raw := Raw + RawBytes([$EF, $BB, $BF]);
    Raw := Raw + BytesOf(#10 + #10);
    P.Feed(Raw, L);
    AssertEquals('two events', 2, L.Count);
    AssertEquals('the later BOM bytes are part of the data',
      #$EF + #$BB + #$BF, L[1].Data);
  finally
    P.Free;
    L.Free;
  end;
end;

procedure TSseParserTest.TestChunkSplitInvariance;
var
  Stream: string;
  Raw: TBytes;
  Canonical: TArray<TSseEvent>;
  P: TSseEventParser;
  L: TList<TSseEvent>;
  Part: TBytes;
  I, J, K: Integer;
  Same: Boolean;

  function SameAs(AList: TList<TSseEvent>): Boolean;
  var
    M: Integer;
  begin
    Result := AList.Count = Length(Canonical);
    if Result then
      for M := 0 to AList.Count - 1 do
        if (AList[M].Data <> Canonical[M].Data) or
           (AList[M].EventType <> Canonical[M].EventType) or
           (AList[M].Id <> Canonical[M].Id) or
           (AList[M].RetryMs <> Canonical[M].RetryMs) then
        begin
          Result := False;
          Break;
        end;
  end;

begin
  Stream := ': this is a test stream' + #10 + #10 +
    'event: greeting' + #10 +
    'data: hello' + #10 +
    'data: world' + #10 +
    'id: 1' + #10 +
    'retry: 500' + #10 + #10 +
    'data: second' + #10 +
    'id: 2' + #10 + #10 +
    'data: third' + #10 + #10;
  Raw := BytesOf(Stream);
  ParseAll(Stream, Canonical);
  AssertEquals('the reference stream yields three events', 3,
    Length(Canonical));
  AssertEquals('first event data', 'hello' + #10 + 'world',
    Canonical[0].Data);
  AssertEquals('first event type', 'greeting', Canonical[0].EventType);
  AssertEquals('second event id', '2', Canonical[1].Id);
  AssertEquals('second event retry', 500, Canonical[1].RetryMs);

  // feed the same stream one byte at a time
  Same := True;
  P := TSseEventParser.Create;
  L := TList<TSseEvent>.Create;
  try
    for I := 0 to High(Raw) do
    begin
      SetLength(Part, 1);
      Part[0] := Raw[I];
      P.Feed(Part, L);
    end;
    Same := SameAs(L);
  finally
    P.Free;
    L.Free;
  end;
  AssertTrue('byte-at-a-time feeding yields identical events', Same);

  // and at every two-way split point
  Same := True;
  for I := 0 to Length(Raw) do
  begin
    P := TSseEventParser.Create;
    L := TList<TSseEvent>.Create;
    try
      P.Feed(Copy(Raw, 0, I), L);
      P.Feed(Copy(Raw, I, Length(Raw) - I), L);
      if not SameAs(L) then
        Same := False;
    finally
      P.Free;
      L.Free;
    end;
    if not Same then
      Break;
  end;
  AssertTrue('every two-way split yields identical events', Same);
end;

procedure TSseParserTest.TestChunkSplitInvarianceWithCrlfPairs;
var
  Stream: string;
  Raw: TBytes;
  Events: TArray<TSseEvent>;
  P: TSseEventParser;
  L: TList<TSseEvent>;
  Part: TBytes;
  I, K: Integer;
  Same: Boolean;
begin
  // the hard case: the CR and its LF land in different chunks
  Stream := 'data: a' + #13 + #10 + 'data: b' + #13 + #10 + #13 + #10 +
    'data: c' + #13 + #10 + #13 + #10;
  Raw := BytesOf(Stream);
  ParseAll(Stream, Events);
  AssertEquals('the reference stream yields two events', 2, Length(Events));
  AssertEquals('the first payload', 'a' + #10 + 'b', Events[0].Data);
  Same := True;
  P := TSseEventParser.Create;
  L := TList<TSseEvent>.Create;
  try
    for I := 0 to High(Raw) do
    begin
      SetLength(Part, 1);
      Part[0] := Raw[I];
      P.Feed(Part, L);
    end;
    Same := L.Count = Length(Events);
    if Same then
      for K := 0 to L.Count - 1 do
        if L[K].Data <> Events[K].Data then
          Same := False;
  finally
    P.Free;
    L.Free;
  end;
  AssertTrue('a CR/LF split across chunks is not a double terminator', Same);
end;

procedure TSseParserTest.TestSplitUtf8SequenceSurvivesAcrossFeeds;
var
  P: TSseEventParser;
  L: TList<TSseEvent>;
  Raw, Part: TBytes;
  I: Integer;
  Expected: string;
begin
  // a two-byte sequence fed one byte at a time must be reassembled, not
  // rejected and not corrupted
  Expected := 'ann' + #$C3 + #$A9 + 'e';
  Raw := BytesOf('data: ' + Expected + #10 + #10);
  P := TSseEventParser.Create;
  L := TList<TSseEvent>.Create;
  try
    for I := 0 to High(Raw) do
    begin
      SetLength(Part, 1);
      Part[0] := Raw[I];
      P.Feed(Part, L);
    end;
    AssertEquals('one event', 1, L.Count);
    AssertEquals('a split multi-byte sequence is reassembled', Expected,
      L[0].Data);
  finally
    P.Free;
    L.Free;
  end;
end;

procedure TSseParserTest.TestInvalidUtf8Raises;
var
  P: TSseEventParser;
  L: TList<TSseEvent>;
  Raw: TBytes;
  Raised: Boolean;
begin
  P := TSseEventParser.Create;
  L := TList<TSseEvent>.Create;
  try
    // $FF is never a legal UTF-8 byte
    Raw := BytesOf('data: ');
    Raw := Raw + RawBytes([$FF]);
    Raw := Raw + BytesOf(#10 + #10);
    Raised := False;
    try
      P.Feed(Raw, L);
    except
      on E: EHttpProtocolError do Raised := True;
    end;
    AssertTrue('invalid UTF-8 raises EHttpProtocolError', Raised);
  finally
    P.Free;
    L.Free;
  end;
end;

procedure TSseParserTest.TestOverlongUtf8Raises;
var
  P: TSseEventParser;
  L: TList<TSseEvent>;
  Raw: TBytes;
  Raised: Boolean;
begin
  P := TSseEventParser.Create;
  L := TList<TSseEvent>.Create;
  try
    // C0 80 is an overlong encoding of NUL; C2 is the shortest legal lead
    Raw := BytesOf('data: ');
    Raw := Raw + RawBytes([$C0, $80]);
    Raw := Raw + BytesOf(#10 + #10);
    Raised := False;
    try
      P.Feed(Raw, L);
    except
      on E: EHttpProtocolError do Raised := True;
    end;
    AssertTrue('an overlong form raises EHttpProtocolError', Raised);
  finally
    P.Free;
    L.Free;
  end;
end;

procedure TSseParserTest.TestSurrogateUtf8Raises;
var
  P: TSseEventParser;
  L: TList<TSseEvent>;
  Raw: TBytes;
  Raised: Boolean;
begin
  P := TSseEventParser.Create;
  L := TList<TSseEvent>.Create;
  try
    // ED A0 80 encodes U+D800, a surrogate: illegal in UTF-8
    Raw := BytesOf('data: ');
    Raw := Raw + RawBytes([$ED, $A0, $80]);
    Raw := Raw + BytesOf(#10 + #10);
    Raised := False;
    try
      P.Feed(Raw, L);
    except
      on E: EHttpProtocolError do Raised := True;
    end;
    AssertTrue('a surrogate raises EHttpProtocolError', Raised);
  finally
    P.Free;
    L.Free;
  end;
end;

procedure TSseParserTest.TestRetryMsSurvivesDispatch;
var
  L: TList<TSseEvent>;
  P: TSseEventParser;
begin
  P := TSseEventParser.Create;
  L := TList<TSseEvent>.Create;
  try
    P.Feed(BytesOf('retry: 250' + #10 + 'data: a' + #10 + #10 +
      'data: b' + #10 + #10), L);
    AssertEquals('two events', 2, L.Count);
    AssertEquals('the first event carries the retry in force', 250,
      L[0].RetryMs);
    AssertEquals('the retry survives dispatch', 250, L[1].RetryMs);
    AssertEquals('the parser still reports it', 250, P.RetryMs);
  finally
    P.Free;
    L.Free;
  end;
end;

procedure TSseParserTest.TestResetClearsState;
var
  P: TSseEventParser;
  L: TList<TSseEvent>;
begin
  P := TSseEventParser.Create;
  L := TList<TSseEvent>.Create;
  try
    P.Feed(BytesOf('id: 9' + #10 + 'retry: 400' + #10 + 'data: a' + #10 + #10),
      L);
    AssertEquals('id before reset', '9', P.LastEventId);
    AssertEquals('retry before reset', 400, P.RetryMs);
    P.Reset;
    AssertEquals('id cleared', '', P.LastEventId);
    AssertEquals('retry cleared', 0, P.RetryMs);
    // a partial line left over from before the reset must not resurface
    P.Feed(BytesOf('data: b' + #10 + #10), L);
    AssertEquals('the post-reset event is clean', 'b', L[L.Count - 1].Data);
  finally
    P.Free;
    L.Free;
  end;
end;

{ TSseSourceTest }

function TSseSourceTest.ResponseOf(const AText: string;
  const AContentType: string; const AStatus: LongInt;
  const AEncoding: string): IHttpResponse;
var
  H: IHttpHeaders;
begin
  H := NewHttpHeaders;
  if AContentType <> '' then
    H.Add(HeaderContentType, AContentType);
  if AEncoding <> '' then
    H.Add(HeaderContentEncoding, AEncoding);
  Result := TStubResponse.Create(AStatus, H,
    TDripBodyStream.Create(BytesOf(AText), 3));
end;

procedure TSseSourceTest.TestValidateAcceptsEventStream;
var
  R: IHttpResponse;
begin
  R := ResponseOf('data: x' + #10 + #10);
  AssertTrue('a 200 text/event-stream passes',
    TSseSource.ValidateResponse(R));
end;

procedure TSseSourceTest.TestValidateAcceptsParametersAndCase;
begin
  AssertTrue('media type is case-insensitive',
    TSseSource.IsEventStreamContentType('TEXT/Event-Stream'));
  AssertTrue('a charset parameter is allowed',
    TSseSource.IsEventStreamContentType('text/event-stream; charset=utf-8'));
  AssertTrue('a quoted utf-8 charset is allowed',
    TSseSource.IsEventStreamContentType(
      'text/event-stream; charset="UTF-8"'));
  AssertFalse('a non-utf-8 charset is not',
    TSseSource.IsEventStreamContentType(
      'text/event-stream; charset=iso-8859-1'));
end;

procedure TSseSourceTest.TestValidateRejectsOtherStatus;
var
  R: IHttpResponse;
  Raised: Boolean;
begin
  R := ResponseOf('', cSseContentType, 404);
  Raised := False;
  try
    TSseSource.ValidateResponse(R);
  except
    on E: EHttpProtocolError do Raised := True;
  end;
  AssertTrue('a non-200 status is rejected', Raised);
end;

procedure TSseSourceTest.TestValidateRejectsOtherContentType;
var
  R: IHttpResponse;
  Raised: Boolean;
begin
  R := ResponseOf('{}', 'application/json');
  Raised := False;
  try
    TSseSource.ValidateResponse(R);
  except
    on E: EHttpProtocolError do Raised := True;
  end;
  AssertTrue('a non-event-stream content type is rejected', Raised);
end;

procedure TSseSourceTest.TestValidateRejectsNonUtf8Charset;
var
  R: IHttpResponse;
  Raised: Boolean;
begin
  R := ResponseOf('data: x' + #10 + #10,
    'text/event-stream; charset=iso-8859-1');
  Raised := False;
  try
    TSseSource.ValidateResponse(R);
  except
    on E: EHttpProtocolError do Raised := True;
  end;
  AssertTrue('a non-utf-8 charset is rejected', Raised);
end;

procedure TSseSourceTest.TestValidateRejectsContentCoding;
var
  R: IHttpResponse;
  Raised: Boolean;
begin
  // transparent decoding buffers to the coding footer, so a coded event
  // stream cannot deliver events incrementally: it must be refused
  R := ResponseOf('data: x' + #10 + #10, cSseContentType, 200, 'gzip');
  Raised := False;
  try
    TSseSource.ValidateResponse(R);
  except
    on E: EHttpProtocolError do Raised := True;
  end;
  AssertTrue('a gzip-coded event stream is rejected', Raised);
  R := ResponseOf('data: x' + #10 + #10, cSseContentType, 200, 'identity');
  AssertTrue('identity coding is accepted', TSseSource.ValidateResponse(R));
end;

procedure TSseSourceTest.TestReadEventsFromBody;
var
  S: IHttpSseSource;
  E: TSseEvent;
begin
  S := TSseSource.Create(ResponseOf(
    'data: one' + #10 + #10 + 'event: two' + #10 + 'data: 2' + #10 + #10));
  AssertTrue('first event', S.ReadEvent(E));
  AssertEquals('first payload', 'one', E.Data);
  AssertEquals('first type', 'message', E.EventType);
  AssertTrue('second event', S.ReadEvent(E));
  AssertEquals('second payload', '2', E.Data);
  AssertEquals('second type', 'two', E.EventType);
  AssertFalse('then the stream ends', S.ReadEvent(E));
end;

procedure TSseSourceTest.TestReadEventIsIncrementalPerBlankLine;
var
  S: IHttpSseSource;
  E: TSseEvent;
begin
  // the body hands out three bytes at a time, so an implementation that
  // waits for the end of the body cannot pass this test
  S := TSseSource.Create(ResponseOf(
    'data: a' + #10 + #10 + 'data: b' + #10 + #10));
  AssertTrue('the first event arrives before the whole body is read',
    S.ReadEvent(E));
  AssertEquals('the first payload', 'a', E.Data);
  AssertTrue('the second event', S.ReadEvent(E));
  AssertEquals('the second payload', 'b', E.Data);
  AssertFalse('end of stream', S.ReadEvent(E));
end;

procedure TSseSourceTest.TestReadEventReturnsFalseAtEof;
var
  S: IHttpSseSource;
  E: TSseEvent;
begin
  S := TSseSource.Create(ResponseOf(''));
  AssertFalse('an empty body has no events', S.ReadEvent(E));
  AssertFalse('and it stays ended', S.ReadEvent(E));
end;

procedure TSseSourceTest.TestLastEventIdTracksTheStream;
var
  S: IHttpSseSource;
  E: TSseEvent;
begin
  S := TSseSource.Create(ResponseOf(
    'id: 11' + #10 + 'data: a' + #10 + #10 + 'data: b' + #10 + #10));
  AssertTrue('first event', S.ReadEvent(E));
  AssertEquals('the id is reported', '11', S.LastEventId);
  AssertTrue('second event', S.ReadEvent(E));
  AssertEquals('the id is still in force', '11', S.LastEventId);
end;

procedure TSseSourceTest.TestRetryMsTracksTheStream;
var
  S: IHttpSseSource;
  E: TSseEvent;
begin
  S := TSseSource.Create(ResponseOf(
    'retry: 750' + #10 + 'data: a' + #10 + #10));
  AssertTrue('first event', S.ReadEvent(E));
  AssertEquals('retry reported', 750, S.RetryMs);
end;

procedure TSseSourceTest.TestCloseStopsFurtherEvents;
var
  S: IHttpSseSource;
  E: TSseEvent;
begin
  S := TSseSource.Create(ResponseOf(
    'data: a' + #10 + #10 + 'data: b' + #10 + #10));
  AssertTrue('first event', S.ReadEvent(E));
  S.Close;
  AssertFalse('a closed source yields no further events', S.ReadEvent(E));
end;

{ TSseReconnectTest }

/// every scripted body opens with a 1 ms retry so a reconnect test does not
/// sleep out the 3000 ms default

procedure TSseRequestTest.TestSseRequestSetsAcceptAndIdentity;
var
  R: THttpRequest;
begin
  R := SseRequest('https://a.example/events');
  AssertEquals('method is GET', 'GET', R.MethodToken);
  AssertEquals('accept is text/event-stream', cSseContentType,
    R.Headers.GetFirst(HeaderAccept));
  AssertEquals('no-store cache control', 'no-store',
    R.Headers.GetFirst(HeaderCacheControl));
  AssertEquals('identity encoding', 'identity',
    R.Headers.GetFirst(HeaderAcceptEncoding));
end;

procedure TSseRequestTest.TestSseRequestWaitsIndefinitelyForTheBody;
var
  S: TStreamRequest;
begin
  S := SseRequest('https://a.example/events').ToStreamRequest;
  AssertTrue('the body read deadline is set explicitly',
    S.BodyReadTimeoutSet);
  AssertEquals('and it means wait indefinitely', 0, S.BodyReadTimeoutMs);
  AssertEquals('the lease request still carries identity', 'identity',
    S.Headers.GetFirst(HeaderAcceptEncoding));
end;

procedure TSseRequestTest.TestOrdinaryRequestKeepsTheLegacyBodyDeadline;
var
  S: TStreamRequest;
begin
  // the default path must be byte-for-byte the historic behaviour: an
  // unset deadline falls back to the header timeout inside the lease
  S := THttpRequest.Create(hmGet, 'https://a.example/x').ToStreamRequest;
  AssertFalse('an ordinary request does not set a body deadline',
    S.BodyReadTimeoutSet);
end;

{ TSseTransportTest }

initialization
  RegisterTest(TSseParserTest);
  RegisterTest(TSseSourceTest);
  RegisterTest(TSseRequestTest);
end.

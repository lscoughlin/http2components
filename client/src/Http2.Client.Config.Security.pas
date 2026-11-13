{**
---
license: Apache-2.0 OR (LGPL-2.1-only WITH Independent-modules-exception)
copyright: Copyright 2026 Liam Seamus Coughlin
keywords: client, security options
notes:
  - this holds the client security options record and its validation
---
}
unit Http2.Client.Config.Security;

{$mode delphi}{$H+}
{$modeswitch advancedrecords}
{$modeswitch typehelpers}
{$interfaces com}

interface

uses
  SysUtils;

const
  /// the default cap on the bytes that a stream may hold in its receive queue
  cDefaultMaxReceiveQueueBytes = 1048576;
  /// the default cap on the header list of a response (128 KiB)
  cDefaultMaxHeaderListSize = 131072;
  /// the default cap on one line of a server-sent event stream (32 MiB)
  cDefaultSseMaxLineBytes = 33554432;
  /// the default cap on one server-sent event (64 MiB)
  cDefaultSseMaxEventBytes = 67108864;
  /// the default idle time of a server-sent event stream (10 minutes)
  cDefaultSseMaxIdleTimeMs = 600000;
  /// the default retry delay of a server-sent event stream (10 minutes)
  cDefaultSseMaxRetryMs = 600000;
  /// the default ratio of decoded bytes to encoded bytes (1000 to 1)
  cDefaultMaxDecodeRatio = 1000;

  /// the smallest and largest value of MaxReceiveQueueBytes
  cMinReceiveQueueBytes = 16384;
  cMaxReceiveQueueBytes = 1073741824;
  /// the smallest and largest non-zero value of MaxHeaderListSize
  cMinHeaderListSize = 1024;
  cMaxHeaderListSize = 16777216;
  /// the smallest and largest non-zero value of the SSE byte caps
  cMinSseBytes = 1024;
  cMaxSseBytes = 1073741824;

type
  /// how a redirect may move to another host or origin (doc/design/redirects.md)
  TRedirectPolicy = (rpAnyHost, rpSameHostOnly, rpSameOriginOnly,
    rpSameOriginUpgrade);

  /// the client security limits.  Each With method returns a changed copy;
  /// the receiver is not changed.  Problems names each value that is out of
  /// range; an empty string means that every value is valid.
  TClientSecurityOptions = record
  private
    FRedirectPolicy: TRedirectPolicy;
    FMaxReceiveQueueBytes: Int64;
    FMaxResponseBytes: Int64;
    FMaxDecodedResponseBytes: Int64;
    FMaxDecodeRatio: Integer;
    FMaxHeaderListSize: Integer;
    FSseMaxLineBytes: Integer;
    FSseMaxEventBytes: Integer;
    FSseMaxIdleTimeMs: Integer;
    FSseMaxRetryMs: Integer;
  public
    /// the options with the documented defaults
    class function Default: TClientSecurityOptions; static;
    function WithRedirectPolicy(const APolicy: TRedirectPolicy):
      TClientSecurityOptions;
    function WithMaxReceiveQueueBytes(const AValue: Int64):
      TClientSecurityOptions;
    function WithMaxResponseBytes(const AValue: Int64):
      TClientSecurityOptions;
    function WithMaxDecodedResponseBytes(const AValue: Int64):
      TClientSecurityOptions;
    function WithMaxDecodeRatio(const AValue: Integer):
      TClientSecurityOptions;
    function WithMaxHeaderListSize(const AValue: Integer):
      TClientSecurityOptions;
    function WithSseMaxLineBytes(const AValue: Integer):
      TClientSecurityOptions;
    function WithSseMaxEventBytes(const AValue: Integer):
      TClientSecurityOptions;
    function WithSseMaxIdleTimeMs(const AValue: Integer):
      TClientSecurityOptions;
    function WithSseMaxRetryMs(const AValue: Integer):
      TClientSecurityOptions;
    /// one line for each value that is out of range, '' when none is
    function Problems: string;

    property RedirectPolicy: TRedirectPolicy read FRedirectPolicy;
    property MaxReceiveQueueBytes: Int64 read FMaxReceiveQueueBytes;
    property MaxResponseBytes: Int64 read FMaxResponseBytes;
    property MaxDecodedResponseBytes: Int64 read FMaxDecodedResponseBytes;
    property MaxDecodeRatio: Integer read FMaxDecodeRatio;
    property MaxHeaderListSize: Integer read FMaxHeaderListSize;
    property SseMaxLineBytes: Integer read FSseMaxLineBytes;
    property SseMaxEventBytes: Integer read FSseMaxEventBytes;
    property SseMaxIdleTimeMs: Integer read FSseMaxIdleTimeMs;
    property SseMaxRetryMs: Integer read FSseMaxRetryMs;
  end;

  /// implemented by THttpClient so that a caller can read the options
  /// of a client with Supports
  IHttpClientOptions = interface
    ['{C3A1E5B2-6D47-4F9A-8E21-5B7D0A9C1E01}']
    /// the security options that the client was built with
    function Options: TClientSecurityOptions;
  end;

implementation

class function TClientSecurityOptions.Default: TClientSecurityOptions;
begin
  Result.FRedirectPolicy := rpAnyHost;
  Result.FMaxReceiveQueueBytes := cDefaultMaxReceiveQueueBytes;
  Result.FMaxResponseBytes := 0;
  Result.FMaxDecodedResponseBytes := 0;
  Result.FMaxDecodeRatio := cDefaultMaxDecodeRatio;
  Result.FMaxHeaderListSize := cDefaultMaxHeaderListSize;
  Result.FSseMaxLineBytes := cDefaultSseMaxLineBytes;
  Result.FSseMaxEventBytes := cDefaultSseMaxEventBytes;
  Result.FSseMaxIdleTimeMs := cDefaultSseMaxIdleTimeMs;
  Result.FSseMaxRetryMs := cDefaultSseMaxRetryMs;
end;

function TClientSecurityOptions.WithRedirectPolicy(
  const APolicy: TRedirectPolicy): TClientSecurityOptions;
begin
  Result := Self;
  Result.FRedirectPolicy := APolicy;
end;

function TClientSecurityOptions.WithMaxReceiveQueueBytes(
  const AValue: Int64): TClientSecurityOptions;
begin
  Result := Self;
  Result.FMaxReceiveQueueBytes := AValue;
end;

function TClientSecurityOptions.WithMaxResponseBytes(
  const AValue: Int64): TClientSecurityOptions;
begin
  Result := Self;
  Result.FMaxResponseBytes := AValue;
end;

function TClientSecurityOptions.WithMaxDecodedResponseBytes(
  const AValue: Int64): TClientSecurityOptions;
begin
  Result := Self;
  Result.FMaxDecodedResponseBytes := AValue;
end;

function TClientSecurityOptions.WithMaxDecodeRatio(
  const AValue: Integer): TClientSecurityOptions;
begin
  Result := Self;
  Result.FMaxDecodeRatio := AValue;
end;

function TClientSecurityOptions.WithMaxHeaderListSize(
  const AValue: Integer): TClientSecurityOptions;
begin
  Result := Self;
  Result.FMaxHeaderListSize := AValue;
end;

function TClientSecurityOptions.WithSseMaxLineBytes(
  const AValue: Integer): TClientSecurityOptions;
begin
  Result := Self;
  Result.FSseMaxLineBytes := AValue;
end;

function TClientSecurityOptions.WithSseMaxEventBytes(
  const AValue: Integer): TClientSecurityOptions;
begin
  Result := Self;
  Result.FSseMaxEventBytes := AValue;
end;

function TClientSecurityOptions.WithSseMaxIdleTimeMs(
  const AValue: Integer): TClientSecurityOptions;
begin
  Result := Self;
  Result.FSseMaxIdleTimeMs := AValue;
end;

function TClientSecurityOptions.WithSseMaxRetryMs(
  const AValue: Integer): TClientSecurityOptions;
begin
  Result := Self;
  Result.FSseMaxRetryMs := AValue;
end;

/// add one line to AText; the lines are separated by a line break
procedure AddProblem(var AText: string; const ALine: string);
begin
  if AText <> '' then
    AText := AText + LineEnding;
  AText := AText + ALine;
end;

function TClientSecurityOptions.Problems: string;
begin
  Result := '';
  if (FMaxReceiveQueueBytes < cMinReceiveQueueBytes) or
     (FMaxReceiveQueueBytes > cMaxReceiveQueueBytes) then
    AddProblem(Result, Format('MaxReceiveQueueBytes must be from %d to %d',
      [cMinReceiveQueueBytes, cMaxReceiveQueueBytes]));
  if FMaxResponseBytes < 0 then
    AddProblem(Result, 'MaxResponseBytes must be 0 or more');
  if FMaxDecodedResponseBytes < 0 then
    AddProblem(Result, 'MaxDecodedResponseBytes must be 0 or more');
  if FMaxDecodeRatio < 0 then
    AddProblem(Result, 'MaxDecodeRatio must be 0 or more');
  if (FMaxHeaderListSize < cMinHeaderListSize) or
     (FMaxHeaderListSize > cMaxHeaderListSize) then
    AddProblem(Result, Format('MaxHeaderListSize must be from %d to %d',
      [cMinHeaderListSize, cMaxHeaderListSize]));
  if (FSseMaxLineBytes <> 0) and ((FSseMaxLineBytes < cMinSseBytes) or
     (FSseMaxLineBytes > cMaxSseBytes)) then
    AddProblem(Result, Format(
      'SseMaxLineBytes must be 0 or from %d to %d',
      [cMinSseBytes, cMaxSseBytes]));
  if (FSseMaxEventBytes <> 0) and ((FSseMaxEventBytes < cMinSseBytes) or
     (FSseMaxEventBytes > cMaxSseBytes)) then
    AddProblem(Result, Format(
      'SseMaxEventBytes must be 0 or from %d to %d',
      [cMinSseBytes, cMaxSseBytes]));
  if FSseMaxIdleTimeMs < 0 then
    AddProblem(Result, 'SseMaxIdleTimeMs must be 0 or more');
  if FSseMaxRetryMs < 1 then
    AddProblem(Result, 'SseMaxRetryMs must be 1 or more');
end;

end.

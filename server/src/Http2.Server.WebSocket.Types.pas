{**
---
license: Apache-2.0 OR (LGPL-2.1-only WITH Independent-modules-exception)
copyright: Copyright 2026 Liam Seamus Coughlin
keywords: websocket, session, handler, init, handshake, environment
notes:
  - This unit holds the types that an application sees, IWsSession, IWsHandler
    and TWsInitResult, and the two interfaces between the session and the rest of
    the server, IWsHandshake and IWsEnvironment.
  - IWsHandshake builds the response that opens the session. The upgrade of
    HTTP/1.1 answers 101 with the accept key, and HTTP/2 answers 200. The session
    does not know the protocol.
  - The session calls the handler on a thread of the streaming pool, one call at a
    time for a session and in the order of the events.
---
}
/// The types of the WebSocket session
unit Http2.Server.WebSocket.Types;

{$mode delphi}{$H+}
{$modeswitch advancedrecords}
{$interfaces com}

interface

uses
  SysUtils, Http2.Common.Hpack, Http2.Common.Body, Http2.Server.Seam, Http2.Server.Duplex,
  Http2.Server.Limits, Http2.Server.Observer, Http2.Server.WebSocket.Options;

type
  /// the decision of IWsHandler.Init
  TWsInitResult = record
    /// true to open the session, false to refuse the upgrade
    Accept: Boolean;
    /// when accepting: the subprotocol, which must be one of those offered, or empty
    Subprotocol: string;
    /// when accepting: more fields for the handshake response
    ResponseHeaders: THeaderBlock;
    /// when refusing: the status; 0 means 403
    Status: Integer;
    /// when refusing: the fields of the error response, for example WWW-Authenticate
    RejectHeaders: THeaderBlock;
    RejectBody: TBytes;
    /// accept with no subprotocol
    class function Accepted: TWsInitResult; static;
    /// accept with this subprotocol
    class function AcceptedWith(const ASubprotocol: string): TWsInitResult; static;
    /// refuse with this status
    class function Rejected(const AStatus: Integer): TWsInitResult; static;
  end;

  /// one WebSocket session
  IWsSession = interface
    ['{7E1F0C11-00C1-4A11-9C72-000000000F01}']
    /// queue one message; legal from any thread at any time; never blocks
    // - srFull: the outbound queue is over the limit and nothing was queued
    // - srClosed: the session has ended or the Close frame went out
    function Send(const AData: TBytes; const AText: Boolean): TSendResult;
    /// queue one message that the reader supplies in pieces
    // - each chunk of the reader goes out as one fragment of the message, and the
    //   call returns at once with srQueued
    // - the streaming pool reads the chunks. When the channel is full, the stream
    //   waits and the drain of the channel wakes it
    // - while the stream runs, Send and SendStream return srFull; Ping and Close still
    //   go out between the fragments
    // - a reader that raises ends the session with Failed
    function SendStream(const AReader: IBodyWriter; const AText: Boolean): TSendResult;
    /// queue a Ping with up to 125 octets
    procedure Ping(const AData: TBytes);
    /// send a Close frame and wait for the Close frame of the peer
    procedure Close(const ACode: Word = 1000; const AReason: string = '');
    /// close the channel at once; no Close frame and no later callback
    procedure Abort;
    function IsOpen: Boolean;
    /// the Close frame of the peer has arrived
    function InputClosed: Boolean;
    /// the Close frame of the server has gone out
    function OutputClosed: Boolean;
    function Subprotocol: string;
    /// the handshake request, read-only; the body is empty
    function Request: IServerRequest;
    function Id: Int64;
    /// a value of the application that lives as long as the session
    function Context: IInterface;
    procedure SetContext(const AValue: IInterface);
  end;

  /// the application side of a session
  IWsHandler = interface
    ['{7E1F0C11-00C2-4A11-9C72-000000000F02}']
    /// the first call of a session: authorise, choose the subprotocol, greet
    // - the upgrade request has been checked, and the response has not gone out
    // - Send, Ping and Close are legal here; their frames follow the response
    function Init(const ARequest: IServerRequest; const AOffered: TArray<string>;
      const ASession: IWsSession): TWsInitResult;
    /// a message; AMessage gives its octets
    // - a message that ends inside the inline limit is complete in memory, and a read
    //   never waits; a larger message streams, and a read waits for the next octets
    // - the reader is valid for this call only; the session aborts it when the call returns
    // - a text message is valid UTF-8 up to the last octet that the reader gave
    // - a read raises EStreamCancelled when the session ends, or when the message fails
    //   (a bad UTF-8 octet, 1007) or stalls (1008)
    // - the call holds one streaming pool thread until it returns
    procedure Message(const ASession: IWsSession; const AMessage: IBodyReader;
      const AText: Boolean);
    procedure Pong(const ASession: IWsSession; const AData: TBytes);
    /// the session ended; AClean tells whether the closing handshake completed
    procedure Closed(const ASession: IWsSession; const ACode: Word;
      const AReason: string; const AClean: Boolean);
    /// a callback raised; the session aborts after this call
    procedure Failed(const ASession: IWsSession; const E: Exception);
  end;

  /// the response that opens the session
  TWsActivation = record
    Status: Integer;
    Headers: THeaderBlock;
  end;

  /// the protocol-specific part of the handshake
  IWsHandshake = interface
    ['{7E1F0C11-00C3-4A11-9C72-000000000F03}']
    /// the response for an accepted session
    function Activation(const ASubprotocol: string;
      const AExtra: THeaderBlock): TWsActivation;
  end;

  /// what a session counts
  TWsCounter = (wcMessagesIn, wcMessagesOut, wcBytesIn, wcBytesOut,
    wcProtocolErrors, wcPingTimeouts);

  /// a session that waits for IWsHandler.Init, watched for its time limit
  IWsInitWatch = interface
    ['{7E1F0C11-00C4-4A11-9C72-000000000F04}']
    /// the time limit passed while Init still ran
    procedure InitTimedOut;
  end;

  /// what a session needs from the server
  IWsEnvironment = interface
    ['{7E1F0C11-00C5-4A11-9C72-000000000F05}']
    function Options: TWsOptions;
    function Clock: IMonotonicClock;
    function NextId: Int64;
    procedure Report(const AKind: TServerEventKind; const ACode: Integer;
      const ADetail: string);
    procedure SessionOpened;
    procedure SessionClosed;
    procedure Count(const AWhat: TWsCounter; const AValue: Int64);
    /// call ASession.InitTimedOut when ADeadlineMs passes, from a thread that is
    /// not a pool thread, because Init may hold every pool thread
    procedure WatchInit(const ASession: IWsInitWatch; const ADeadlineMs: QWord);
    procedure UnwatchInit(const ASession: IWsInitWatch);
  end;

implementation

class function TWsInitResult.Accepted: TWsInitResult;
begin
  Result := Default(TWsInitResult);
  Result.Accept := True;
end;

class function TWsInitResult.AcceptedWith(const ASubprotocol: string): TWsInitResult;
begin
  Result := Accepted;
  Result.Subprotocol := ASubprotocol;
end;

class function TWsInitResult.Rejected(const AStatus: Integer): TWsInitResult;
begin
  Result := Default(TWsInitResult);
  Result.Status := AStatus;
end;

end.

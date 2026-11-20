{**
---
license: Apache-2.0 OR (LGPL-2.1-only WITH Independent-modules-exception)
copyright: Copyright 2026 Liam Seamus Coughlin
keywords: http2, server, admission, handler error, reset
notes:
  - This unit holds the answer to a handler that raised.
  - Before the first write, the answer is a 500 response with an empty body.
  - After the headers, the answer is a reset of the stream with INTERNAL_ERROR.
    The stream then ends and frees its slot.
---
}
/// The answer to a handler that raised
// - the handler pool calls AnswerHandlerError once for each handler exception
//   that the handler did not detach from.
unit Http2.Server.Admission.Errors;

{$mode delphi}{$H+}

interface

uses
  Http2.Common.Errors,
  Http2.Common.Status,
  Http2.Server.ResponseWriter,
  Http2.Server.Stream;

/// answer a handler that raised
// - ABeforeHeaders True: queue a 500 response with an empty body, which ends
//   the stream
// - ABeforeHeaders False: reset the stream with INTERNAL_ERROR and tell the
//   peer with RST_STREAM
procedure AnswerHandlerError(const AStream: TServerStream;
  const ABeforeHeaders: Boolean);

implementation

procedure AnswerHandlerError(const AStream: TServerStream;
  const ABeforeHeaders: Boolean);
begin
  if ABeforeHeaders then
  begin
    AStream.QueueResponseHeaders(HttpStatusInternalServerError,
      WithDate(nil, HttpStatusInternalServerError), True);
    // the request body may still be on its way: the flush resets the stream
    // after the 500 when it is
    AStream.ResetAfterEnd;
  end
  else
    AStream.Refuse(ecInternalError);
end;

end.

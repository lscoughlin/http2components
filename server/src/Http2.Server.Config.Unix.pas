{**
---
license: Apache-2.0 OR (LGPL-2.1-only WITH Independent-modules-exception)
copyright: Copyright 2026 Liam Seamus Coughlin
keywords: unix socket, configuration
notes:
  - This unit holds the server option record for a Unix socket.
  - Http2.Server.Config carries the record in its Unix property.
  - The path rule of the byte limit and the NUL byte lives in
    Http2.Common.UnixPath, so the server and the client share it.
---
}
/// The options of a Unix domain socket listener
// - TUnixSocketOptions is the record that the factory carries in its Unix
//   property
// - an empty path keeps the TCP listener
unit Http2.Server.Config.Unix;

{$mode delphi}{$H+}
{$modeswitch advancedrecords}
{$interfaces com}

interface

type
  /// the options of a Unix domain socket listener
  ///
  /// A record is a value, so a copy of the factory holds its own settings.
  /// An empty path selects the TCP listener.
  TUnixSocketOptions = record
  private
    FPath: string;
    FMode: Integer;
  public
    /// the defaults: no path, and the umask keeps the file mode
    class function Create: TUnixSocketOptions; static;
    /// the absolute path of the socket file; an empty text selects the TCP
    /// listener
    function WithPath(const AValue: string): TUnixSocketOptions;
    /// the file mode that is set after the bind; -1 leaves the umask in force
    function WithMode(const AValue: Integer): TUnixSocketOptions;
    /// true when a path is set, so the listener is a Unix socket
    function Enabled: Boolean;

    /// add one text to AProblems for each setting that is not usable
    // - the mode is checked even when no path is set
    procedure Validate(var AProblems: TArray<string>);

    property Path: string read FPath;
    property Mode: Integer read FMode;
  end;

implementation

uses
  Http2.Common.UnixPath;

{ TUnixSocketOptions }

class function TUnixSocketOptions.Create: TUnixSocketOptions;
begin
  Result.FPath := '';
  Result.FMode := -1;
end;

function TUnixSocketOptions.WithPath(const AValue: string): TUnixSocketOptions;
begin
  Result := Self;
  Result.FPath := AValue;
end;

function TUnixSocketOptions.WithMode(const AValue: Integer): TUnixSocketOptions;
begin
  Result := Self;
  Result.FMode := AValue;
end;

function TUnixSocketOptions.Enabled: Boolean;
begin
  Result := FPath <> '';
end;

procedure TUnixSocketOptions.Validate(var AProblems: TArray<string>);

  procedure Add(const AText: string);
  begin
    SetLength(AProblems, Length(AProblems) + 1);
    AProblems[High(AProblems)] := AText;
  end;

var
  LProblem: string;
begin
  if Enabled then
  begin
    LProblem := UnixPathProblem(FPath);
    if LProblem <> '' then
      Add(LProblem);
    if Pos(':', FPath) > 0 then
      Add('the Unix socket path holds a colon');
  end;
  if (FMode < -1) or (FMode > $1FF) then
    Add('the Unix socket mode is out of range');
end;

end.

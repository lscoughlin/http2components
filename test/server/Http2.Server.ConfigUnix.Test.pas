{**
---
license: Apache-2.0 OR (LGPL-2.1-only WITH Independent-modules-exception)
copyright: Copyright 2026 Liam Seamus Coughlin
keywords: unix socket, test
notes:
  - These tests hold the option record of a Unix socket and its checks in
    Validate.
  - A path is refused when it is relative, holds a colon or a NUL byte, or is
    longer than 103 bytes.
---
}
unit Http2.Server.ConfigUnix.Test;

{$mode delphi}{$H+}
{$modeswitch advancedrecords}
{$interfaces com}

interface

uses
  {$IFDEF UNIX}cthreads,{$ENDIF}
  SysUtils, fpcunit, testregistry,
  Http2.Server, Http2.Server.Config, Http2.Server.Http1.RawClient;

type
  /// tests of the server option record of a Unix socket
  TConfigUnixTest = class(TTestCase)
  private
    FHandler: IHttp2Handler;
    function Base: THttp2ServerFactory;
    function Rejects(const AFactory: THttp2ServerFactory;
      const AWord: string): Boolean;
    function RejectsOption(const AOptions: TUnixSocketOptions;
      const AWord: string): Boolean;
  protected
    procedure SetUp; override;
  published
    procedure TestDefaultsAreOff;
    procedure TestWithUnixSocketSetsPathAndKeepsOthers;
    procedure TestFactoryIsCopyOnWrite;
    procedure TestEmptyPathMeansTcp;
    procedure TestRelativePathIsRefused;
    procedure TestColonInPathIsRefused;
    procedure TestNulInPathIsRefused;
    procedure TestPathOf103BytesPasses;
    procedure TestPathOf104BytesIsRefused;
    procedure TestModeRange;
    procedure TestReusePortWithUnixIsRefused;
    procedure TestPortIsNotValidatedInUnixMode;
    procedure TestUnixModeNeedsTlsOrClearText;
  end;

implementation

procedure TConfigUnixTest.SetUp;
begin
  FHandler := TTestHandler.Create;
end;

function TConfigUnixTest.Base: THttp2ServerFactory;
begin
  Result := THttp2ServerFactory.Create
    .WithHandler(FHandler)
    .WithClearTextAllowed(True);
end;

function TConfigUnixTest.Rejects(const AFactory: THttp2ServerFactory;
  const AWord: string): Boolean;
var
  Problems: TArray<string>;
  I: Integer;
begin
  Result := False;
  if AFactory.Validate(Problems) then
    Exit;
  for I := 0 to High(Problems) do
    if Pos(AWord, Problems[I]) > 0 then
      Exit(True);
end;

function TConfigUnixTest.RejectsOption(const AOptions: TUnixSocketOptions;
  const AWord: string): Boolean;
var
  Problems: TArray<string>;
  I: Integer;
begin
  Result := False;
  Problems := nil;
  AOptions.Validate(Problems);
  for I := 0 to High(Problems) do
    if Pos(AWord, Problems[I]) > 0 then
      Exit(True);
end;

procedure TConfigUnixTest.TestDefaultsAreOff;
var
  Problems: TArray<string>;
begin
  AssertFalse('the default path is empty', Base.Unix.Enabled);
  AssertEquals('the default path', '', Base.Unix.Path);
  AssertEquals('the default mode keeps the umask', -1, Base.Unix.Mode);
  AssertTrue('the defaults pass validation', Base.Validate(Problems));
end;

procedure TConfigUnixTest.TestWithUnixSocketSetsPathAndKeepsOthers;
var
  F: THttp2ServerFactory;
  Problems: TArray<string>;
begin
  F := Base.WithPort(9000).WithUnixSocket('/tmp/h2-one.sock');
  AssertTrue('the path is set', F.Unix.Enabled);
  AssertEquals('the path text', '/tmp/h2-one.sock', F.Unix.Path);
  AssertEquals('the port is kept', 9000, F.Port);
  AssertTrue('the socket options are kept', F.Socket.TcpNoDelay);
  AssertTrue('the factory still validates', F.Validate(Problems));
end;

procedure TConfigUnixTest.TestFactoryIsCopyOnWrite;
var
  F1, F2: THttp2ServerFactory;
begin
  F1 := Base.WithUnixSocket('/tmp/h2-one.sock');
  F2 := F1.WithUnixSocket('/tmp/h2-two.sock').WithUnixSocketMode($1A4);
  AssertEquals('the old value keeps the old path', '/tmp/h2-one.sock', F1.Unix.Path);
  AssertEquals('the old mode keeps the umask', -1, F1.Unix.Mode);
  AssertEquals('the new value holds the new path', '/tmp/h2-two.sock', F2.Unix.Path);
  AssertEquals('the new mode is set', $1A4, F2.Unix.Mode);
end;

procedure TConfigUnixTest.TestEmptyPathMeansTcp;
var
  Problems: TArray<string>;
begin
  AssertFalse('an empty path is not enabled',
    Base.WithUnixSocket('').Unix.Enabled);
  AssertTrue('an empty path passes validation',
    Base.WithUnixSocket('').Validate(Problems));
end;

procedure TConfigUnixTest.TestRelativePathIsRefused;
var
  Problems: TArray<string>;
begin
  AssertFalse('a relative path fails validation',
    Base.WithUnixSocket('h2.sock').Validate(Problems));
  AssertTrue('the text names the Unix socket path',
    Rejects(Base.WithUnixSocket('h2.sock'), 'Unix socket path'));
  AssertTrue('the text does not hold the path',
    not Rejects(Base.WithUnixSocket('h2.sock'), 'h2.sock'));
end;

procedure TConfigUnixTest.TestColonInPathIsRefused;
var
  Problems: TArray<string>;
  Options: TUnixSocketOptions;
begin
  Options := TUnixSocketOptions.Create.WithPath('/tmp/a:b.sock');
  AssertFalse('a colon fails validation',
    Base.WithUnixSocket('/tmp/a:b.sock').Validate(Problems));
  AssertTrue('the text names the colon',
    RejectsOption(Options, 'colon'));
  AssertTrue('the text does not hold the path',
    not RejectsOption(Options, 'a:b.sock'));
end;

procedure TConfigUnixTest.TestNulInPathIsRefused;
var
  Options: TUnixSocketOptions;
begin
  Options := TUnixSocketOptions.Create.WithPath('/tmp/a' + #0 + 'b.sock');
  AssertTrue('a NUL byte is refused', RejectsOption(Options, 'NUL byte'));
end;

procedure TConfigUnixTest.TestPathOf103BytesPasses;
var
  Problems: TArray<string>;
  Path: string;
begin
  Path := '/' + StringOfChar('a', 102);
  AssertEquals('the path is 103 bytes', 103, Length(Path));
  AssertTrue('103 bytes pass',
    Base.WithUnixSocket(Path).Validate(Problems));
end;

procedure TConfigUnixTest.TestPathOf104BytesIsRefused;
var
  Problems: TArray<string>;
  Path: string;
begin
  Path := '/' + StringOfChar('a', 103);
  AssertEquals('the path is 104 bytes', 104, Length(Path));
  AssertFalse('104 bytes fail',
    Base.WithUnixSocket(Path).Validate(Problems));
  AssertTrue('the text names the length',
    Rejects(Base.WithUnixSocket(Path), 'bytes long'));
end;

procedure TConfigUnixTest.TestModeRange;
var
  Problems: TArray<string>;
begin
  AssertTrue('mode -1 passes',
    Base.WithUnixSocketMode(-1).Validate(Problems));
  AssertTrue('mode 0 passes',
    Base.WithUnixSocketMode(0).Validate(Problems));
  AssertTrue('mode $1FF passes',
    Base.WithUnixSocketMode($1FF).Validate(Problems));
  AssertFalse('mode $200 fails',
    Base.WithUnixSocketMode($200).Validate(Problems));
  AssertFalse('mode -2 fails',
    Base.WithUnixSocketMode(-2).Validate(Problems));
  AssertTrue('the text names the mode',
    Rejects(Base.WithUnixSocketMode($200), 'mode'));
end;

procedure TConfigUnixTest.TestReusePortWithUnixIsRefused;
var
  F: THttp2ServerFactory;
begin
  F := Base.WithSocketOptions(TSocketOptions.Create.WithReusePort(True))
    .WithUnixSocket('/tmp/h2-one.sock');
  AssertTrue('reuse-port with a Unix path is refused',
    Rejects(F, 'reuse-port'));
end;

procedure TConfigUnixTest.TestPortIsNotValidatedInUnixMode;
var
  F: THttp2ServerFactory;
begin
  F := Base.WithPort(70000).WithUnixSocket('/tmp/h2-one.sock');
  AssertFalse('the port is not checked in Unix mode',
    Rejects(F, 'port'));
end;

procedure TConfigUnixTest.TestUnixModeNeedsTlsOrClearText;
var
  F: THttp2ServerFactory;
begin
  F := THttp2ServerFactory.Create.WithHandler(FHandler)
    .WithUnixSocket('/tmp/h2-one.sock');
  AssertTrue('no certificate and no cleartext is refused',
    Rejects(F, 'cleartext is off'));
end;

initialization
  RegisterTest(TConfigUnixTest);

end.

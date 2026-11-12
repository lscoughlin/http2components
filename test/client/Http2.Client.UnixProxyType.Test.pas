{**
---
license: Apache-2.0 OR (LGPL-2.1-only WITH Independent-modules-exception)
copyright: Copyright 2026 Liam Seamus Coughlin
keywords: unix socket, test
notes:
  - This unit holds tests for a Unix socket.
---
}
unit Http2.Client.UnixProxyType.Test;

{$mode delphi}{$H+}
{$modeswitch advancedrecords}
{$interfaces com}

interface

uses
  SysUtils, fpcunit, testregistry, Http2.Client.Errors, Http2.Client.Proxy,
  Http2.Client.Proxy.Unix;

type
  /// tests the proxy value on a Unix socket path (U-06d)
  TUnixProxyTypeTest = class(TTestCase)
  private
    procedure AssertRejected(const AProxy: IProxy);
  published
    procedure TestUnixProxyHasNoHostOrPort;
    procedure TestTcpProxyHasEmptyPath;
    procedure TestUnixProxyKeepsItsKind;
    procedure TestAbsolutePathAcceptedForHttpAndSocks5;
    procedure TestRelativePathIsRejected;
    procedure TestPathLimitIsOneHundredAndThreeBytes;
    procedure TestNulByteIsRejected;
    procedure TestTlsUnixProxyIsRejected;
    procedure TestProblemTextNeverHoldsThePath;
    procedure TestRouteKeyDiffersByPath;
    procedure TestRouteKeyNeverEqualsTcpKey;
    procedure TestRouteKeyKeepsCredentials;
    procedure TestSocksCredentialLimitStillApplies;
    procedure TestTcpHostStillRequired;
  end;

implementation

procedure TUnixProxyTypeTest.AssertRejected(const AProxy: IProxy);
var
  LRaised: Boolean;
begin
  LRaised := False;
  try
    ValidateProxy(AProxy);
  except
    on E: EHttpProxyConfigError do
      LRaised := True;
  end;
  AssertTrue('the proxy is rejected', LRaised);
end;

procedure TUnixProxyTypeTest.TestUnixProxyHasNoHostOrPort;
var
  LProxy: IProxy;
begin
  LProxy := TProxy.CreateUnix(pkHttp, '/tmp/h2-proxy.sock', '', '');
  AssertEquals('host is empty', '', LProxy.Host);
  AssertEquals('port is zero', 0, Integer(LProxy.Port));
  AssertEquals('path is kept', '/tmp/h2-proxy.sock', LProxy.UnixPath);
end;

procedure TUnixProxyTypeTest.TestTcpProxyHasEmptyPath;
var
  LProxy: IProxy;
begin
  LProxy := TProxy.Create('proxy.corp', 3128);
  AssertEquals('path is empty for TCP', '', LProxy.UnixPath);
end;

procedure TUnixProxyTypeTest.TestUnixProxyKeepsItsKind;
var
  LProxy: IProxy;
begin
  LProxy := TProxy.CreateUnix(pkSocks5, '/tmp/h2-proxy.sock', '', '');
  AssertEquals('kind is SOCKS5', Ord(pkSocks5), Ord(LProxy.Kind));
end;

procedure TUnixProxyTypeTest.TestAbsolutePathAcceptedForHttpAndSocks5;
begin
  ValidateProxy(TProxy.CreateUnix(pkHttp, '/tmp/h2-proxy.sock', '', ''));
  ValidateProxy(TProxy.CreateUnix(pkSocks5, '/tmp/h2-proxy.sock', '', ''));
end;

procedure TUnixProxyTypeTest.TestRelativePathIsRejected;
begin
  AssertRejected(TProxy.CreateUnix(pkHttp, 'tmp/h2-proxy.sock', '', ''));
  AssertRejected(TProxy.CreateUnix(pkHttp, '', '', ''));
end;

procedure TUnixProxyTypeTest.TestPathLimitIsOneHundredAndThreeBytes;
begin
  ValidateProxy(TProxy.CreateUnix(pkHttp, '/' + StringOfChar('a', 102), '', ''));
  AssertRejected(TProxy.CreateUnix(pkHttp, '/' + StringOfChar('a', 103), '', ''));
end;

procedure TUnixProxyTypeTest.TestNulByteIsRejected;
begin
  AssertRejected(TProxy.CreateUnix(pkHttp, '/tmp/h2' + #0 + 'proxy.sock', '', ''));
end;

procedure TUnixProxyTypeTest.TestTlsUnixProxyIsRejected;
begin
  AssertRejected(TProxy.CreateUnix(pkHttps, '/tmp/h2-proxy.sock', '', ''));
end;

procedure TUnixProxyTypeTest.TestProblemTextNeverHoldsThePath;
begin
  AssertEquals('valid path has no problem', '',
    UnixProxyProblem('/tmp/h2-proxy.sock', pkHttp));
  AssertEquals('TLS has a problem', 'a Unix proxy cannot use TLS',
    UnixProxyProblem('/tmp/h2-proxy.sock', pkHttps));
  AssertTrue('relative path text is set',
    UnixProxyProblem('secret-path.sock', pkHttp) <> '');
  AssertEquals('relative path text holds no path',
    Pos('secret-path', UnixProxyProblem('secret-path.sock', pkHttp)), 0);
end;

procedure TUnixProxyTypeTest.TestRouteKeyDiffersByPath;
begin
  AssertTrue('keys differ by path',
    ProxyRouteKey(TProxy.CreateUnix(pkHttp, '/tmp/h2-a.sock', '', '')) <>
    ProxyRouteKey(TProxy.CreateUnix(pkHttp, '/tmp/h2-b.sock', '', '')));
  AssertEquals('key names the path', ' via unix:/tmp/h2-a.sock',
    ProxyRouteKey(TProxy.CreateUnix(pkHttp, '/tmp/h2-a.sock', '', '')));
end;

procedure TUnixProxyTypeTest.TestRouteKeyNeverEqualsTcpKey;
begin
  AssertTrue('Unix key differs from TCP key',
    ProxyRouteKey(TProxy.CreateUnix(pkHttp, '/tmp/h2-a.sock', '', '')) <>
    ProxyRouteKey(TProxy.Create('unix', 1)));
end;

procedure TUnixProxyTypeTest.TestRouteKeyKeepsCredentials;
begin
  AssertTrue('user name changes the key',
    ProxyRouteKey(TProxy.CreateUnix(pkSocks5, '/tmp/h2-a.sock', 'u', 'p')) <>
    ProxyRouteKey(TProxy.CreateUnix(pkSocks5, '/tmp/h2-a.sock', '', '')));
  AssertEquals('password is not in the key', ' via socks5:u@unix:/tmp/h2-a.sock',
    ProxyRouteKey(TProxy.CreateUnix(pkSocks5, '/tmp/h2-a.sock', 'u', 'p')));
end;

procedure TUnixProxyTypeTest.TestSocksCredentialLimitStillApplies;
begin
  AssertRejected(TProxy.CreateUnix(pkSocks5, '/tmp/h2-a.sock',
    StringOfChar('u', 256), ''));
  ValidateProxy(TProxy.CreateUnix(pkHttp, '/tmp/h2-a.sock',
    StringOfChar('u', 256), ''));
end;

procedure TUnixProxyTypeTest.TestTcpHostStillRequired;
begin
  AssertRejected(TProxy.Create('', 3128));
end;

initialization
  RegisterTest(TUnixProxyTypeTest);
end.

{**
---
license: Apache-2.0 OR (LGPL-2.1-only WITH Independent-modules-exception)
copyright: Copyright 2026 Liam Seamus Coughlin
keywords: client_test
notes:
  - this shields native OpenSSL calls in client test peers from SIGPIPE
---
}
unit Http2.Client.Test.OpenSSL.SigPipe;

{$mode delphi}{$H+}

interface

uses
  mormot.lib.openssl11;

function TestSslAccept(const ASsl: PSSL): Integer;
function TestSslRead(const ASsl: PSSL; const ABuffer: Pointer;
  const ACount: Integer): Integer;
function TestSslWrite(const ASsl: PSSL; const ABuffer: Pointer;
  const ACount: Integer): Integer;
function TestSslShutdown(const ASsl: PSSL): Integer;

implementation

uses
  Http2.Client.SigPipe;

function TestSslAccept(const ASsl: PSSL): Integer;
var
  Shield: TSigPipeShield;
begin
  SigPipeShieldEnter(Shield);
  try
    Result := SSL_accept(ASsl);
  finally
    SigPipeShieldLeave(Shield);
  end;
end;

function TestSslRead(const ASsl: PSSL; const ABuffer: Pointer;
  const ACount: Integer): Integer;
var
  Shield: TSigPipeShield;
begin
  SigPipeShieldEnter(Shield);
  try
    Result := SSL_read(ASsl, ABuffer, ACount);
  finally
    SigPipeShieldLeave(Shield);
  end;
end;

function TestSslWrite(const ASsl: PSSL; const ABuffer: Pointer;
  const ACount: Integer): Integer;
var
  Shield: TSigPipeShield;
begin
  SigPipeShieldEnter(Shield);
  try
    Result := SSL_write(ASsl, ABuffer, ACount);
  finally
    SigPipeShieldLeave(Shield);
  end;
end;

function TestSslShutdown(const ASsl: PSSL): Integer;
var
  Shield: TSigPipeShield;
begin
  SigPipeShieldEnter(Shield);
  try
    Result := SSL_shutdown(ASsl);
  finally
    SigPipeShieldLeave(Shield);
  end;
end;

end.

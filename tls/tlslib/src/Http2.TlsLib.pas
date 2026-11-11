{**
---
license: Apache-2.0 OR (LGPL-2.1-only WITH Independent-modules-exception)
copyright: Copyright 2026 Liam Seamus Coughlin
keywords: tls, tlslib, provider
notes:
  - This unit adapts the TlsLib buffer engine to the common TLS contract.
---
}
unit Http2.TlsLib;

{$mode delphi}{$H+}{$interfaces com}{$modeswitch advancedrecords}

interface

uses
  SysUtils, Classes, Http2.Common.Tls.Types, Http2.Common.Tls.Identity,
  Http2.Common.Tls.Policy, Http2.Common.Tls.Session, Http2.Common.Tls.Context,
  Http2.TlsLib.Context, Http2.TlsLib.Factory;

type
  ETlsLibProviderUnavailable = class(ETlsContextError);
  TTlsLibIdentity = class;
  TTlsLibIdentityClass = class of TTlsLibIdentity;
  TTlsLibIdentity = class
  public
    class function FromPemFiles(const ACertFile, AKeyFile: string;
      const APassphrase: string = ''): ITLSIdentity; static;
    class function FromPem(const ACertPem, AKeyPem: TBytes;
      const APassphrase: string = ''): ITLSIdentity; overload; static;
    class function FromPem(const ACertPem, AKeyPem: string;
      const APassphrase: string = ''): ITLSIdentity; overload; static;
    class function FromPkcs12File(const AFile: string;
      const APassphrase: string = ''): ITLSIdentity; static;
    class function FromPkcs12(const AData: TBytes;
      const APassphrase: string = ''): ITLSIdentity; static;
  end;
  TlsLibIdentity = TTlsLibIdentity;

  TTlsLibContext = Http2.TlsLib.Context.TTlsLibContext;
  TlsLibContext = TTlsLibContext;
  TTlsLibContextFactory = Http2.TlsLib.Factory.TTlsLibContextFactory;

implementation

uses
  Http2.TlsLib.Identity;

function ReadFileBytes(const APath: string): TBytes;
var S: TFileStream;
begin
  try
    S := TFileStream.Create(APath, fmOpenRead or fmShareDenyNone);
  except
    on E: Exception do
      raise ETlsContextError.Create('TlsLib input file could not be opened');
  end;
  try
    if S.Size > 4 * 1024 * 1024 then
      raise ETlsContextError.Create('TlsLib identity input exceeds the 4 MiB limit');
    SetLength(Result, S.Size);
    if Length(Result) > 0 then S.ReadBuffer(Result[0], Length(Result));
  finally
    S.Free;
  end;
end;

class function TTlsLibIdentity.FromPemFiles(const ACertFile, AKeyFile: string;
  const APassphrase: string): ITLSIdentity;
begin
  try
    Result := TlsLibCreateIdentity(ReadFileBytes(ACertFile), ReadFileBytes(AKeyFile),
      nil, APassphrase, tifPem);
  except
    on E: ETlsContextError do raise;
    on E: Exception do raise ETlsContextError.Create('TlsLib identity files could not be read');
  end;
end;

class function TTlsLibIdentity.FromPem(const ACertPem, AKeyPem: TBytes;
  const APassphrase: string): ITLSIdentity;
begin
  Result := TlsLibCreateIdentity(ACertPem, AKeyPem, nil, APassphrase, tifPem);
end;

class function TTlsLibIdentity.FromPem(const ACertPem, AKeyPem: string;
  const APassphrase: string): ITLSIdentity;
begin
  Result := FromPem(TEncoding.UTF8.GetBytes(ACertPem), TEncoding.UTF8.GetBytes(AKeyPem),
    APassphrase);
end;

class function TTlsLibIdentity.FromPkcs12File(const AFile: string;
  const APassphrase: string): ITLSIdentity;
begin
  try
    Result := TlsLibCreateIdentity(ReadFileBytes(AFile), nil, nil, APassphrase, tifPkcs12);
  except
    on E: ETlsContextError do raise;
    on E: Exception do raise ETlsContextError.Create('TlsLib PKCS#12 identity file could not be read');
  end;
end;

class function TTlsLibIdentity.FromPkcs12(const AData: TBytes;
  const APassphrase: string): ITLSIdentity;
begin
  Result := TlsLibCreateIdentity(AData, nil, nil, APassphrase, tifPkcs12);
end;

end.

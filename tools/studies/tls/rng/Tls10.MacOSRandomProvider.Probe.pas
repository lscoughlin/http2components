{**
---
license: LGPL-2.1-only WITH Independent-modules-exception
copyright: Copyright 2026 Liam Seamus Coughlin
keywords: tls, random, macos, probe
notes:
  - this checks the CryptoLib macOS random provider compile path
---
}
program Tls10MacOSRandomProviderProbe;

{$mode delphi}

uses
  ClpCryptoLibTypes,
  ClpMacOSRandomProvider;

var
  Provider: TMacOSRandomProvider;
  EmptyBytes: TCryptoLibByteArray;
  SmallBytes: TCryptoLibByteArray;
  LargeBytes: TCryptoLibByteArray;
begin
  Provider := TMacOSRandomProvider.Create;
  try
    SetLength(EmptyBytes, 0);
    Provider.GetBytes(EmptyBytes);
    SetLength(SmallBytes, 16);
    Provider.GetBytes(SmallBytes);
    SetLength(LargeBytes, 4096);
    Provider.GetBytes(LargeBytes);
    WriteLn('PASS 3: zero, 16-byte, and 4096-byte requests');
  finally
    Provider.Free;
  end;
end.

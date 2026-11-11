{**
---
license: Apache-2.0 OR (LGPL-2.1-only WITH Independent-modules-exception)
copyright: Copyright 2026 Liam Seamus Coughlin
keywords: openssl, resource, counter, test
notes:
  - This unit counts selected native OpenSSL objects with ex_data callbacks.
---
}
unit Http2.OpenSSL.Live.Resources;
{$mode delphi}{$H+}
interface
function InstallOpenSSLResourceCounters: Boolean;
function LiveX509Count: Integer;
function LiveSSLCount: Integer;
function LiveSSLContextCount: Integer;
implementation
uses SysUtils, mormot.core.base, mormot.core.os, mormot.lib.openssl11;
type
  TExCallback = procedure(parent, ptr, ad: Pointer; idx: Integer;
    argl: PtrInt; argp: Pointer); cdecl;
  TGetExNewIndex = function(classIndex: Integer; argl: PtrInt; argp: Pointer;
    newFunc, dupFunc: Pointer; freeFunc: TExCallback): Integer; cdecl;
const
  cExIndexSsl = 0;
  cExIndexSslCtx = 1;
  cExIndexX509 = 3;
var
  GLiveSSL, GLiveSslCtx, GLiveX509: LongInt;
  GLib: TSynLibrary;
  GGetIndex: TGetExNewIndex;

procedure IncrementSsl(parent, ptr, ad: Pointer; idx: Integer; argl: PtrInt; argp: Pointer); cdecl;
begin InterlockedIncrement(GLiveSSL); end;
procedure DecrementSsl(parent, ptr, ad: Pointer; idx: Integer; argl: PtrInt; argp: Pointer); cdecl;
begin InterlockedDecrement(GLiveSSL); end;
procedure IncrementSslCtx(parent, ptr, ad: Pointer; idx: Integer; argl: PtrInt; argp: Pointer); cdecl;
begin InterlockedIncrement(GLiveSslCtx); end;
procedure DecrementSslCtx(parent, ptr, ad: Pointer; idx: Integer; argl: PtrInt; argp: Pointer); cdecl;
begin InterlockedDecrement(GLiveSslCtx); end;
procedure IncrementX509(parent, ptr, ad: Pointer; idx: Integer; argl: PtrInt; argp: Pointer); cdecl;
begin InterlockedIncrement(GLiveX509); end;
procedure DecrementX509(parent, ptr, ad: Pointer; idx: Integer; argl: PtrInt; argp: Pointer); cdecl;
begin InterlockedDecrement(GLiveX509); end;

function InstallOpenSSLResourceCounters: Boolean;
var Dir, Err: string;
begin
  Result := False;
  if not OpenSslIsAvailable then Exit;
  Dir := GetSystemEnvString('OPENSSL_LIBPATH');
  if (Dir <> '') and DirectoryExists(Dir) then Dir := IncludeTrailingPathDelimiter(Dir)
  else Dir := '';
  GLib := TSynLibrary.Create;
  if not GLib.TryLoadLibrary([Dir + LIB_CRYPTO4, Dir + LIB_CRYPTO3,
    Dir + LIB_CRYPTO1], nil, @Err) then Exit;
  if not GLib.Resolve(_PU, 'CRYPTO_get_ex_new_index', @@GGetIndex, nil, @Err) then Exit;
  Result := (GGetIndex(cExIndexSsl, 0, nil, @IncrementSsl, nil, @DecrementSsl) >= 0) and
    (GGetIndex(cExIndexSslCtx, 0, nil, @IncrementSslCtx, nil, @DecrementSslCtx) >= 0) and
    (GGetIndex(cExIndexX509, 0, nil, @IncrementX509, nil, @DecrementX509) >= 0);
end;
function LiveX509Count: Integer; begin Result := GLiveX509; end;
function LiveSSLCount: Integer; begin Result := GLiveSSL; end;
function LiveSSLContextCount: Integer; begin Result := GLiveSslCtx; end;
finalization
  GLib.Free;
end.

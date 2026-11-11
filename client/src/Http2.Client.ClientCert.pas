{**
---
license: Apache-2.0 OR (LGPL-2.1-only WITH Independent-modules-exception)
copyright: Copyright 2026 Liam Seamus Coughlin
keywords: client, tls, identity
notes:
  - This unit re-exports the provider-neutral identity contract.
---
}
unit Http2.Client.ClientCert;

{$mode delphi}{$H+}{$interfaces com}

interface

uses
  Http2.Common.Tls.Identity;

type
  IClientIdentity = Http2.Common.Tls.Identity.ITLSIdentity;

  IClientIdentitySelector = interface(IInterface)
    ['{C7B81D88-A802-41FA-B68D-A895E55B0C07}']
    function Select(const AHost: string; const APort: Word): IClientIdentity;
  end;

function FixedIdentitySelector(
  const AIdentity: IClientIdentity): IClientIdentitySelector;

implementation

type
  TFixedIdentitySelector = class(TInterfacedObject, IClientIdentitySelector)
  private
    FIdentity: IClientIdentity;
  public
    constructor Create(const AIdentity: IClientIdentity);
    function Select(const AHost: string; const APort: Word): IClientIdentity;
  end;

constructor TFixedIdentitySelector.Create(const AIdentity: IClientIdentity);
begin
  inherited Create;
  FIdentity := AIdentity;
end;

function TFixedIdentitySelector.Select(const AHost: string;
  const APort: Word): IClientIdentity;
begin
  Result := FIdentity;
end;

function FixedIdentitySelector(
  const AIdentity: IClientIdentity): IClientIdentitySelector;
begin
  Result := TFixedIdentitySelector.Create(AIdentity);
end;

end.

{**
---
license: Apache-2.0 OR (LGPL-2.1-only WITH Independent-modules-exception)
copyright: Copyright 2026 Liam Seamus Coughlin
keywords: client_test, tls, identity
notes:
  - This checks provider-neutral client identity and selector behavior.
---
}
unit Http2.Client.ClientCert.Test;

{$mode delphi}{$H+}{$interfaces com}

interface

uses
  SysUtils, fpcunit, testregistry, Http2.Client.ClientCert,
  Http2.Client.Api, Http2.Client.Errors, Http2.Client.Factory,
  Http2.Common.Tls.Identity,
  Http2.Common.Tls.Types;

type
  TClientIdentitySelectorTest = class(TTestCase)
  published
    procedure TestFixedSelectorReturnsTheConfiguredIdentity;
    procedure TestFixedSelectorPreservesAnExplicitNil;
    procedure TestBuildAcceptsNeutralIdentity;
    procedure TestBuildRejectsExpiredNeutralIdentity;
    procedure TestBuildWithoutIdentity;
  end;

implementation

type
  TFakeIdentity = class(TInterfacedObject, ITLSIdentity)
  private
    FLeaf: TTlsCertificateSummary;
  public
    constructor Create;
    procedure SetExpiry(const AValue: TDateTime);
    function BackendName: string;
    function Leaf: TTlsCertificateSummary;
    function Formats: TTlsIdentityFormats;
  end;

constructor TFakeIdentity.Create;
begin
  inherited Create;
  FLeaf.Subject := 'CN=client.example';
  FLeaf.FingerprintSha256 := '0123456789abcdef';
  FLeaf.NotAfterUtc := EncodeDate(2099, 1, 1);
end;

procedure TFakeIdentity.SetExpiry(const AValue: TDateTime);
begin
  FLeaf.NotAfterUtc := AValue;
end;

function TFakeIdentity.BackendName: string;
begin
  Result := 'fake';
end;

function TFakeIdentity.Leaf: TTlsCertificateSummary;
begin
  Result := FLeaf;
end;

function TFakeIdentity.Formats: TTlsIdentityFormats;
begin
  Result := [];
end;

procedure TClientIdentitySelectorTest.TestFixedSelectorReturnsTheConfiguredIdentity;
var
  Identity, Selected: IClientIdentity;
  Selector: IClientIdentitySelector;
begin
  Identity := TFakeIdentity.Create;
  Selector := FixedIdentitySelector(Identity);
  Selected := Selector.Select('origin.example', 443);
  Check(Selected = Identity, 'selector returned a different identity');
  Check(Selected.Leaf.Subject = 'CN=client.example',
    'provider-neutral leaf metadata was not retained');
end;

procedure TClientIdentitySelectorTest.TestFixedSelectorPreservesAnExplicitNil;
var
  Selector: IClientIdentitySelector;
begin
  Selector := FixedIdentitySelector(nil);
  Check(Selector.Select('origin.example', 443) = nil,
    'nil selector identity was replaced by a default');
end;

procedure TClientIdentitySelectorTest.TestBuildAcceptsNeutralIdentity;
var
  Identity: IClientIdentity;
  Client: IHttpClient;
begin
  Identity := TFakeIdentity.Create;
  Client := THttpClientFactory.Create.WithClientIdentity(Identity).Build;
  Check(Client <> nil, 'factory rejected a valid provider-neutral identity');
end;

procedure TClientIdentitySelectorTest.TestBuildRejectsExpiredNeutralIdentity;
var
  Identity: IClientIdentity;
  Fake: TFakeIdentity;
begin
  Fake := TFakeIdentity.Create;
  Fake.SetExpiry(EncodeDate(2000, 1, 1));
  Identity := Fake;
  try
    THttpClientFactory.Create.WithClientIdentity(Identity).Build;
    Fail('factory accepted an expired identity');
  except
    on E: EHttpTlsConfigError do ;
  end;
end;

procedure TClientIdentitySelectorTest.TestBuildWithoutIdentity;
var
  Client: IHttpClient;
begin
  Client := THttpClientFactory.Create.Build;
  Check(Client <> nil, 'factory build without an identity failed');
end;

initialization
  RegisterTest(TClientIdentitySelectorTest);

end.

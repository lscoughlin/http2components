{**
---
license: Apache-2.0 OR (LGPL-2.1-only WITH Independent-modules-exception)
copyright: Copyright 2026 Liam Seamus Coughlin
keywords: client, identity
notes:
  - The request identity handle is the shared provider-neutral identity.
---
}
unit Http2.Client.IdentityHandle;

{$mode delphi}{$H+}{$interfaces com}

interface

uses Http2.Common.Tls.Identity;

type
  IClientIdentityHandle = Http2.Common.Tls.Identity.ITLSIdentity;

implementation
end.

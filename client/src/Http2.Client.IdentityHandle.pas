{**
---
license: Apache-2.0 OR (LGPL-2.1-only WITH Independent-modules-exception)
copyright: Copyright 2026 Liam Seamus Coughlin
keywords: http2, client
notes:
  - Imported from http2client source revision 709336f542cbedf9ce1ab67d83bddcfd560eb1c0.
  - Unit references use the common and client namespaces.
---
}
/// the TLS-free handle a request carries for a client identity
// - Http2.Client.WebSocket depends on the RTL only, so a request cannot name
//   IClientIdentity (which exposes OpenSSL types); it carries this base
//   interface instead, and IClientIdentity (Http2.Client.ClientCert) descends from
//   it.  Callers pass an IClientIdentity; doc/design/mtls.md "Per-request
//   identity".
unit Http2.Client.IdentityHandle;

{$mode delphi}{$H+}
{$interfaces com}

interface

type
  IClientIdentityHandle = interface
    ['{9937B7EF-26BF-44EF-B95B-99C6C7A9077D}']
  end;

implementation

end.

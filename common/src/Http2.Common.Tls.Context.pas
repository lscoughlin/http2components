{**
---
license: Apache-2.0 OR (LGPL-2.1-only WITH Independent-modules-exception)
copyright: Copyright 2026 Liam Seamus Coughlin
keywords: tls, context, policy
notes:
  - This unit defines the shared TLS context interface and API GUID.
---
}
unit Http2.Common.Tls.Context;
{$mode delphi}{$H+}{$interfaces com}
interface
uses Http2.Common.Tls.Types, Http2.Common.Tls.Session,
  Http2.Common.Tls.Policy;
type
  { Immutable context data can be shared across threads. Each created session
    belongs to one serialized transport owner and retains its context. }
  ITLSContext = interface(IInterface)
    ['{D0387A76-78E3-4D18-B2E2-21D7051B2B03}']
    function BackendName: string;
    function Capabilities: TTlsCapabilities;
    { Returns non-secret role, authentication, and context timeout information. }
    function Info: TTlsContextInfo;
    { Raises ETlsContextError before transport use if client support is absent. }
    function CreateClientSession(const AOptions: TTlsClientSessionOptions): ITLSSession;
    { Raises ETlsContextError before transport use if server support is absent. }
    function CreateServerSession(const AOptions: TTlsServerSessionOptions): ITLSSession;
  end;
implementation
end.

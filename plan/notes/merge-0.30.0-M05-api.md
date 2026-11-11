# M05 common API and boundary

## Frozen public facade

`src/Http2.Common.pas` exposes the following aliases and forwarding functions. The leaf units remain available for callers that need smaller imports. This public facade does not define duplicate record, enum, interface, class, or exception identities.

| Public names | Defining unit |
| --- | --- |
| `THttp2ErrorCode`, `EHttpError`, `EHttpConnectionError`, `EHttpProtocolError`, `EHttpStreamError`, `EHttpTimeout`, `EHttpConnectionClosed` | `Http2.Common.Errors` |
| `ecNoError`, `ecProtocolError`, `ecInternalError`, `ecFlowControlError`, `ecSettingsTimeout`, `ecStreamClosed`, `ecFrameSizeError`, `ecRefusedStream`, `ecCancel`, `ecCompressionError`, `ecConnectError`, `ecEnhanceYourCalm`, `ecInadequateSecurity`, `ecHttp11Required` | `Http2.Common.Errors` |
| `IHttpHeaders`, `NewHttpHeaders` | `Http2.Common.Headers` |
| `HeaderMethod`, `HeaderPath`, `HeaderScheme`, `HeaderAuthority`, `HeaderStatus`, `HeaderContentType`, `HeaderContentLength`, `HeaderContentEncoding`, `HeaderAccept`, `HeaderAcceptEncoding`, `HeaderUserAgent`, `HeaderAuthorization`, `HeaderCookie`, `HeaderSetCookie`, `HeaderCacheControl`, `HeaderLocation`, `HeaderHost`, `HeaderTe`, `HeaderLastEventId` | `Http2.Common.Headers` |
| `THttpHeaderField`, `THeaderBlock`, `THpackTableState`, `THpackCodec` | `Http2.Common.Hpack` |
| `TFrameType`, `TFrameFlag`, `TFrameFlags`, `TFrameHeader`, `TFrame`, `TConnectionSettings` | `Http2.Common.Frames` |
| `ftData`, `ftHeaders`, `ftPriority`, `ftRstStream`, `ftSettings`, `ftPushPromise`, `ftPing`, `ftGoAway`, `ftWindowUpdate`, `ftContinuation`, `ffEndStream`, `ffEndHeaders`, `ffAck`, `ffPadded`, `ffPriority` | `Http2.Common.Frames` |
| `FrameHeaderSize`, `ClientPrefaceSize`, `ClientPreface`, `SettingsEntrySize`, `DefaultMaxFrameSize`, `MinAllowedFrameSize`, `MaxAllowedFrameSize`, `MaxStreamId`, `SettingHeaderTableSize`, `SettingEnablePush`, `SettingMaxConcurrentStreams`, `SettingInitialWindowSize`, `SettingMaxFrameSize`, `SettingMaxHeaderListSize`, `SettingEnableConnectProtocol` | `Http2.Common.Frames` |
| `FrameFlagsToByte`, `FrameTypeName`, `IsKnownFrameType`, `BuildDataFrame`, `BuildHeadersFrame`, `BuildContinuationFrame`, `BuildPriorityFrame`, `BuildRstStreamFrame`, `BuildSettingsFrame`, `BuildServerSettings`, `BuildSettingsAck`, `CheckClientPreface`, `ReadClientPreface`, `BuildPingFrame`, `BuildGoAwayFrame`, `BuildWindowUpdateFrame` | `Http2.Common.Frames` |
| `ParseRstStream`, `ParseGoAway`, `ParseWindowUpdate`, `ParsePing`, `ParsePriority`, `HeaderPriorityDependsOn`, `HeaderBlockOffset`, `ExtractHeaderBlock`, `ExtractDataPayload`, `ReadFrame`, `WriteFrame`, `ValidateFrame` | `Http2.Common.Frames` |
| `TWindow`, `TFlowControl`, `MaxWindowSize`, `DefaultWindowSize`, `ShouldEmitWindowUpdate` | `Http2.Common.FlowControl` |

`THpackCodec` exposes `Encode`, `Decode`, `ApplySettings`, `SetDecoderLimit`, `SetEncoderCap`, `SetPeerTableSize`, table size properties, `Huffman`, and `MaxHeaderListSize`. M06 and M07 use the directional HPACK operations where local and peer settings differ. `ApplySettings` remains for source compatibility and retains the old both-direction behavior.

`TConnectionSettings.Decode` keeps both overloads: decoding from defaults and applying entries as a delta to a base value. `TFrame` keeps the client receive metadata, which is never part of wire encoding. `TFlowControl` includes both combined client operations and separate server connection/stream operations.

The pinned role sources have no explicit GUID on `IHttpHeaders`. The common interface uses one canonical declaration and does not add a GUID.

## Dependency boundary

The facade uses only RTL and basic FCL units, plus the common leaf units. The common leaf units do not use client or server units, mORMot2, JSON, XML, transport, TLS, sockets, or role-specific connection logic. Role error units alias the common base errors but remain outside the facade.

## Verification

A direct FPC 3.2.4 macOS arm64 compile of `test/common/Http2.Common.ApiProbe.pas` succeeded with exit code 0. The probe imports only `Http2.Common` and exercised header operations, HPACK encode/decode, SETTINGS frame construction and validation, window initialization, and error naming.

The M04 bounded common runner passed 229 tests with zero errors, failures, or ignored tests. M05 adds no changes to common behavior.


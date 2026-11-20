---
license: Apache-2.0 OR (LGPL-2.1-only WITH Independent-modules-exception)
copyright: Copyright 2026 Liam Seamus Coughlin
keywords: compiler, verification, historical
notes:
  - These probe sources are historical inputs from the client source project.
  - They do not verify the merged tree.
---

# Client compiler probes

These standalone Pascal files are preserved as compiler evidence from the
client source project at commit `709336f542cbedf9ce1ab67d83bddcfd560eb1c0`.
The [source probe notes](source-notes.md) describe their original purpose.
No probe was run for this documentation migration.

The files are outside the active source and test trees. The duplicate client
library implementation `doc/reference/fpc-verified/h2/Http2.Client.pas` is
not copied. The compiled probe binaries are also not copied. The source
`testclient.pas` is retained as an historical probe source; it depends on the
excluded duplicate unit and is not a merged-tree build target.

SHA-256 values below identify the copied source files.

| File | Establishes | SHA-256 |
| --- | --- | --- |
| `probe.pas` | A class procedure generic fails to parse under objfpc mode. | `988192bb3f5cdf6932c0b61236419c2e258bae8cd2cef335aefdb76fbd6c9619` |
| `probe10.pas` | A generic method under objfpc with genericmethods still fails to parse. | `1a60731956cce08960ce16f81cd2d841388a1576a1ad018605d275000d20cdf0` |
| `probe11.pas` | TSimpleEvent raises an exception at run time on macOS. | `fcd919b21995066d7ebf7199238d35c71a5d89d3027c4e084b660b6e939402d5` |
| `probe12.pas` | A blocking queue with a thread consumer gives the expected sum. | `4272dcef26968ced6e6c33a4e05ec57ee7b620321efa3985461c9715f3d68864` |
| `probe2.pas` | Generic classes, generic records and specialize compile and run under objfpc mode. | `6b50e8a48edbff47d72e22b1dd7de7de7dfb738eaa431f7516321187a7971ccc` |
| `probe3.pas` | TQueue and TDictionary need specialize under objfpc mode, and TStringList lacks Remove. | `1e2f5d0428d87cffe5ddf88cf31f7d373f2021c0e8a9d806facbc7609ce12033` |
| `probe4.pas` | Interface reference release destroys an object, and TStringList lacks Remove. | `d0eb97b3d5f29f89a28e67a10a9d5da5317a415ad9de36eb972707d71e3b9530` |
| `probe6.pas` | TCriticalSection works, and TEvent raises an exception on macOS. | `380f50476d363ddaf75e86b462acbbf273dd764e822ceb6edf46c5e4b01bee7b` |
| `probe7.pas` | The RTLEvent functions work. | `c9dd1f18650a35f5fca0bdef27922cc625b4859f82f980b77d81a24929c4586f` |
| `probe8.pas` | TCriticalSection and TQueue work, and TMonitor is absent. | `563e47a58453976c13ce57eadd2d7ffc31bb5120a0ff1c128024668b6147d8e5` |
| `probe9.pas` | A generic method compiles and runs under delphi mode. | `4b0432b305448781ef25347ac2944201d156586ca94bd4a7e5d89403a5d09522` |
| `testclient.pas` | The factory, request, body, header and client declarations of the document compile and run. | `b6f299b69c1d995b89f4fbec4c9c71b8dc0077cd5e3b3626385579bb1c490784` |

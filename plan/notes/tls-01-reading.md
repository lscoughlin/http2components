# TLS-01 reading and build notes

TLS-01 moved the 135 production units from the three old source roots into
`common/src`, `client/src`, and `server/src`. The unit names and source bytes
stay unchanged. The inventory comparison against the accepted TLS-00 base
reports one new path for every original unit.

The package generator reads `tools/components.py`. The generator keeps
Readers in a separate client package. The current tree has four packages.
The two provider package definitions stay reserved in the component map until
TLS-04 adds provider sources.

The Lazarus version is 4.0. The installed Lazarus source includes project-group
examples in `components/tachart/demo/all_tachart_demos.lpg`. The group uses
`CONFIG`, `ProjectGroup FileVersion="2"`, `Targets`, `Target FileName`, and
`BuildModes`. The project group lists the four packages that exist now. The
package checker parses the group XML and checks that its relative package
paths match the available package files. `lazbuild` accepts individual `.lpk`
files, so package builds use those files.

The source, documentation, version, package, and generated package checks pass.
The common, client, and server components compile on macOS. Each Lazarus
package compiles with its own output directory and a config directory under
`bin/`. The mORMot2 checkout is read-only and is at the required pin.

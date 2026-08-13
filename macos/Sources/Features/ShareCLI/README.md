# ShareCLI native control endpoint

`Control/` is a source-local, macOS-app integration copy of ShareCLI's
dependency-free Swift control transport. Its canonical upstream is the
`contrib/ghostty-control` package in ShareCLI; this fork intentionally vendors
the source into Ghostty's filesystem-synchronised Xcode target so release builds
do not depend on a developer-machine checkout or a SwiftPM sidecar process.

`ShareCLIControlBootstrap.swift` is Ghostty-specific. It owns the endpoint only
after `AppDelegate.applicationDidFinishLaunching`, keeps weak bindings keyed by
`SurfaceView.id`, reconciles them on controller surface-tree changes, and
invalidates them before app termination.

The native adapter truthfully supports only:

- UTF-8 text injection through Ghostty's existing `Surface.sendText` path,
  but only while the target `SurfaceView` still has a live `surfaceModel`;
- foreground PID and TTY metadata when the underlying surface provides it; and
- bounded bytes from Ghostty's 500 ms cached visible-screen text.

It intentionally does **not** claim raw PTY events, resize, durable PTY state,
or atomic layout operations. During a surface-tree mutation the inventory first
becomes incomplete, then the app actor publishes the full replacement tree as
one monotonically increasing stable generation. Callers may infer exits only
from a complete generation; a write-capability response is false and writes
fail explicitly whenever the target `surfaceModel` is unavailable.

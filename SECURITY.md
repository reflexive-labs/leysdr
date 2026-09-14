# Security

## What the daemon trusts

`leylined` runs as your user, owns the radio hardware, and listens on one Unix domain socket
(`~/Library/Application Support/Leyline/leyline.sock` on macOS). There is no authentication and no
authorization on that socket by design: the control plane trusts the user account, and the socket
is created with your umask in a directory only you can write. Anything that can open the socket can
do everything `ley` can — tune, take over a sweep, destroy another client's capture, read samples.
Client identity on the wire (`leyline-client-id` and friends) is attribution for the event log, not
a credential.

`ley mcp` hands that same surface to an agent: an MCP client that can start it can do everything
`ley` can, which is the trust a local shell already has, and it speaks stdin and stdout only. It
opens no network listener of its own; a network transport for it waits on the same remote-access
milestone (`docs/reference/mcp.md`, "What an agent can do, and the trust that implies").

The daemon opens no network listener. Remote control is a later milestone and will arrive with
authentication designed for it (`docs/design/control-plane.md`, "Auth for TCP remote access").

## What the daemon connects to

`ley devices attach rtltcp host:port` (or, for a foreground run, `leylined --rtltcp host:port` and
`LEYLINE_RTLTCP`) makes an outbound, cleartext TCP connection to an `rtl_tcp` server you name, and
streams raw samples from it. Nothing on that link is authenticated or encrypted; use it on a network
you trust. An attached endpoint is remembered in `devices.json` beside the socket and reconnected at
every start until `ley devices detach` forgets it.

## What the daemon reads and writes

- Reads IQ files and JSON sidecars you name with `ley play`; a sidecar is capped at 1 MiB and must be
  a regular file, and sample rates outside 1 kSPS–100 MSPS are refused.
- Writes its socket (`ley daemon status` prints the path), a pidfile, a log and `devices.json`
  beside it, and the LaunchAgent plist under `~/Library/LaunchAgents` when you run
  `ley daemon install`.
- Does not write recordings yet.

## Reporting a vulnerability

Use GitHub's private vulnerability reporting on the repository (Security → Report a vulnerability)
rather than a public issue. Include the version from `ley version` and `ley daemon status`.

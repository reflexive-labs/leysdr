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

The AI features (`docs/design/ai.md`, being built) will add to what a client of the socket can do.
Any client will be able to start paid work on your provider account, such as a speech job or an
assistant conversation, and to add entries to the usage ledger with `ReportUsage`. No client will
be able to read a provider key back, because the contract accepts keys and never returns them.

The daemon opens no network listener. Remote control is a later milestone and will arrive with
authentication designed for it (`docs/design/control-plane.md`, "Auth for TCP remote access").

## What the daemon connects to

`ley devices attach rtltcp host:port` (or, for a foreground run, `leylined --rtltcp host:port` and
`LEYLINE_RTLTCP`) makes an outbound, cleartext TCP connection to an `rtl_tcp` server you name, and
streams raw samples from it. Nothing on that link is authenticated or encrypted; use it on a network
you trust. An attached endpoint is remembered in `devices.json` beside the socket and reconnected at
every start until `ley devices detach` removes it.

A `webhook:URL` notifier (`ley watch --notify=webhook:URL`) makes the daemon POST each matching
decode record to that URL as JSON, over `http` or `https` (the only schemes it accepts), for as
long as the job runs.

The daemon itself will make no model call. A provider's API is contacted by the worker processes
the daemon starts for the AI features: a speech decoder plugin, and `ley` running as the assistant
or as the check that runs when a key is added. Each plugin's manifest lists the hosts it contacts
(`contacts_hosts`), and `ley decoders` shows them; the assistant and the check contact the host of
the provider or endpoint you set with `ley ai add`.

## What the daemon reads and writes

- Reads IQ files and JSON sidecars you name with `ley play`; a sidecar is capped at 1 MiB and must be
  a regular file, and sample rates outside 1 kSPS–100 MSPS are refused.
- Writes its socket (`ley daemon status` prints the path), a pidfile, a log and `devices.json`
  beside it, and the LaunchAgent plist under `~/Library/LaunchAgents` when you run
  `ley daemon install`.
- Writes recordings under `~/Library/Application Support/Leyline/recordings` (`--recordings`
  moves it; `--recordings-cap` and `--recordings-age` bound it), and kept decode jobs' records
  under `~/Library/Application Support/Leyline/store` (`--store`).
- Will store provider keys added with `ley ai add` or the app's Settings: on macOS a login-keychain
  item per provider (service `com.leysdr.leyline`), elsewhere a `credentials.json` file of mode
  0600 in its data directory. No RPC, event or log line returns a key; `ley ai` shows the provider,
  a label and the last four characters. `ai.json` in the data directory holds that listing and
  the model each feature uses, and `usage.jsonl` in the store holds the usage ledger.
- Will keep the assistant's conversations under `conversations/` in its data directory, one
  directory of mode 0700 per conversation, with files of mode 0600 readable by your user only:
  `conversation.json`, what every client sees of it (the turns, the tool calls and their results),
  and `transcript.jsonl`, the worker's model transcript, which is what was sent to the provider.
  Both can hold frequencies, decoded records and speech text, and neither holds a key. They stay
  until the conversation is deleted (`ley ask --delete`); the daemon keeps the newest 100 and drops
  any unused for 90 days.

## What the daemon runs

- **Decoder plugins.** A decode job starts the `executable` named in a decoder's `manifest.json`,
  found in the directories `--decoders` / `LEYLINE_DECODERS` list and in
  `~/Library/Application Support/Leyline/decoders`. It runs as your user with no sandbox, so
  anything you put in those directories runs with your permissions. Listing decoders
  (`ley decoders`) reads the manifests and executes nothing.
- **Shell notifiers.** `ley watch --notify=shell:CMD` makes the daemon run `CMD` with
  `/bin/sh -c` for each matching record, with the record's JSON on stdin. Any client of the socket
  can ask for this, which is one more reason the socket must stay private to your account.
- **`ley` as a worker.** For a key check and for each assistant conversation the daemon will run
  `ley worker`, found beside `leylined`, then on `PATH` (`--ley` / `LEYLINE_LEY` overrides it). It
  runs as your user with no sandbox and receives the provider key on stdin, never in its arguments
  or environment. A decoder plugin whose manifest names a provider receives that provider's key
  the same way. The assistant's tools are `ley mcp`'s; it has no tool that runs a shell command or
  adds a shell notifier.

## Supported versions

Leyline SDR is pre-release. Only `main` is supported; a fix lands there and nowhere else.

## Reporting a vulnerability

Report it privately through GitHub's private vulnerability reporting on
[reflexive-labs/leysdr](https://github.com/reflexive-labs/leysdr/security/advisories/new)
(Security, then Report a vulnerability), not in a public issue. Include the output of `ley version`
and `ley daemon status`, and the steps that show the problem. We aim to reply within a week.

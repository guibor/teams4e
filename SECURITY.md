# Security and Privacy

teams4e is an unofficial client for potentially sensitive workplace data.
It is not an encrypted vault, an authentication broker, or a way around tenant
policy. Review your organization's rules before connecting a live account or
using an agent provider.

## Authentication Boundary

- The package ships no OAuth app registration, client secret, tenant identity,
  access token, or refresh token.
- Your external provider owns login, consent, conditional access, and refresh.
  It must be approved for the operations you use.
- The bundled backend consumes short-lived delegated Graph tokens. A token
  command is executed directly as an argument list, not through a shell.
- A configured credential file is read-only from teams4e's perspective.
  Restrict access to it and keep it outside the checkout.
- Access tokens are retained in backend memory and used in authenticated HTTP
  requests. This is not a promise that a compromised local machine cannot
  inspect them.
- A custom backend adapter can keep tokens inside an existing service instead.
  No universal MCP adapter is included.

See [AUTHENTICATION.md](AUTHENTICATION.md) for provider contracts and limitations.

## Where Content Goes

| Data | Destination / control |
| --- | --- |
| Messages, calendar requests, attachments | Microsoft Graph and authorized download endpoints through the backend |
| Reading/search cache | Configurable local SQLite database |
| Snoozes, favorites, and local action state | Configurable local state file |
| Unsent drafts and displayed images | Configurable local cache directories |
| Downloads, Markdown exports, Org captures | Local destinations you select or configure |
| Thread analysis | An exported conversation made available to your selected Agent Shell agent |
| Ongoing companion | Bounded excerpts and explicitly shared context sent to the selected agent after you start it |

Local caches, drafts, exports, and snapshots can contain personal or confidential
content even when they contain no tokens. They are not encrypted by teams4e.
Use appropriate device encryption, file permissions, backups, and retention.
Agent session directories are not automatically purged.

Ordinary reading does not start an agent. Using Agent Shell only as the local
Markdown renderer does not submit messages to an AI service. The companion is
opt-in, but invoking it starts periodic checks by default; see [COMPANION.md](COMPANION.md)
for pausing, scope limits, and manual-only operation. Agent tools and permissions
are governed by your agent configuration, not restricted by teams4e.

Org composition disables Babel execution and rejects includes, setup files,
macros, and calls. Markdown conversion runs the configured Pandoc executable
without a shell. Rendering is not a general sandbox for third-party Emacs
packages or user hooks.

## Diagnostics and Local Processes

The package redacts tokens and outgoing message arguments in its own error
reporting. Performance reports intentionally omit conversation content and
identities. Nevertheless, review all logs and screenshots before sharing:
provider output, server responses, paths, and names can still be sensitive.

Some one-shot operations pass message text or file paths as process arguments.
Not invoking a shell avoids shell interpolation; it does not guarantee secrecy
from operating-system process inspection. Use a trusted workstation.

Do not put credentials in shell history, configuration examples, issue reports,
tests, or the source tree. Ignore rules are a convenience, not a security boundary,
and do not protect files already tracked by Git.

## Reporting a Vulnerability

Do not post credentials, private transcripts, or exploit details in a public issue.

Use GitHub's private vulnerability reporting option if it is available. If no
private reporting option is offered, open a minimal issue requesting a private
contact channel **without sensitive details**. There is no published response-time
guarantee; this is a volunteer-maintained package.

For an ordinary bug, use a synthetic mock reproduction and describe the Emacs
version, command sequence, and enabled optional packages. See [CONTRIBUTING.md](CONTRIBUTING.md).

## Before Sharing a Fork or Demo

1. Scan both the working files and reachable Git history for secrets.
2. Inspect tracked files, commit identities, screenshots, and animations manually.
3. Use reserved example identities and synthetic message/calendar data.
4. Keep runtime stores, credentials, and local configuration outside the repository.
5. Inspect the staged diff; an ignore rule does not remove an earlier commit.
6. Rotate exposed credentials through their owner. History cleanup alone does
   not revoke a token or erase copies from forks and clones.

[PUBLIC-READINESS.md](PUBLIC-READINESS.md) records the latest scoped audit.
A clean scan is not a guarantee that no sensitive data or vulnerabilities exist.

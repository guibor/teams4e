# Reuse an Existing Microsoft 365 Login

`teams4e` separates the Emacs client from the application that owns Microsoft
identity. This is useful in managed organizations where an MCP service,
corporate broker, CLI, TUI, or DavMail-like bridge is already approved, but a
new Entra application registration would require another security review.

The approved integration remains responsible for:

- its Entra application registration and client identity;
- interactive login and tenant consent;
- refresh-token storage and renewal;
- conditional-access and organization policy.

`teams4e` needs either a fresh delegated Microsoft Graph access token or an
adapter that performs its backend operations through that integration. It does
not bypass consent, conditional access, or Graph permissions.

## Choose an Integration Pattern

| Existing integration | Recommended teams4e boundary |
| --- | --- |
| Can print a short-lived Graph token | Token command |
| Maintains a local shared credential record | Read-only credential file |
| Exposes MCP/tools but never exports tokens | Backend adapter |

The access token must be intended for Microsoft Graph, represent the signed-in
user, and contain delegated scopes for the features you use. An arbitrary MCP
connection or a token for a different audience is not sufficient.

## Pattern 1: Token Command

This is the smallest and preferred boundary. Configure an argv list rather
than a shell command:

```elisp
(setq teams4e-token-command
      '("m365-token" "print" "--resource" "graph"))
```

`m365-token` is an example executable name, not a tool distributed with this
package. The same applies to the helper and adapter paths below: provide the
bridge for your existing integration. MCP or DavMail access alone is not a
ready-made teams4e login.

`teams4e` runs the command directly. Its stdout must contain only a raw access
token or one JSON object:

```json
{"access_token":"REDACTED","expires_at":1786123456}
```

`expires_at` may use Unix seconds or milliseconds. It can be omitted for a JWT
with an `exp` claim. The backend caches the token in memory and invokes the
command again shortly before expiry.

The helper should:

1. reuse the login and refresh state already owned by the approved integration;
2. request or retrieve a delegated Microsoft Graph token;
3. print the token envelope to stdout and diagnostics only to stderr;
4. exit unsuccessfully when no fresh token can be provided.

Do not put a literal token in Emacs configuration, command arguments, shell
history, or the repository.

## Pattern 2: Broker-Owned Credential File

Some MCP hosts and OAuth brokers already maintain a local JSON credential
store. Point `teams4e` at it:

```elisp
(setq teams4e-token-command nil
      teams4e-credentials-file "~/.config/my-m365/credentials.json"
      teams4e-credential-server-name "m365"
      teams4e-credential-server-url nil)
```

The file is a JSON object whose values may include credential records. A
minimal example is:

```json
{
  "connection-id": {
    "server_name": "m365",
    "server_url": "https://mcp.example.test/m365",
    "graph_access_token": "REDACTED",
    "graph_expires_at": 1786123456000
  }
}
```

`teams4e-credential-server-name` selects the record. Set
`teams4e-credential-server-url` when more than one record has the same name and
an exact URL match is needed.

If the approved OAuth owner can refresh or establish that record, configure its
executable:

```elisp
(setq teams4e-bootstrap-program "/path/to/my-oauth-owner")
```

The bundled backend invokes it as:

```text
HELPER --refresh-if-needed --credentials FILE
```

`M-x teams4e-login` runs the same owner interactively. `teams4e` then rereads
the file and requires a fresh `graph_access_token`. It never writes this file, emits a refresh token, or uses one to obtain an
access token; the external owner remains responsible for renewal.

Restrict the credential file to the current user, for example mode `0600` on
Unix-like systems. Do not place it inside the package directory.

## Pattern 3: MCP or Broker Backend Adapter

Many MCP servers deliberately expose operations but not bearer tokens. That is
a sound security boundary. In this case, keep the token inside the service and
provide an executable adapter:

```elisp
(setq teams4e-backend-program "/path/to/teams4e-mcp-adapter"
      teams4e-use-persistent-backend nil)
```

No universal MCP adapter is bundled: tool names and result schemas vary by
service. This pattern requires implementing and mapping the operations you
intend to use. Token-command integration is usually less work when supported.

For an initial adapter, support one-shot operation:

- receive the same command and options as command-line arguments;
- invoke the corresponding MCP or broker tool;
- print exactly one JSON document to stdout;
- send diagnostics to stderr and return a nonzero status on failure.

The bundled `bin/teams4e-graph` executable is the reference implementation.
Its mock path is implemented in `bin/teams4e_mock.py` and selected by
`teams4e-mock-mode`; there is no separate `bin/teams4e-mock` executable. The Emacs side treats the backend
as a replaceable integration layer, so views, rendering, bookmarks, compose,
capture, and keybindings do not need to know where authentication lives.

Keep `teams4e-use-persistent-backend` disabled for a normally named custom
adapter. A full drop-in backend installed with the executable basename
`teams4e-graph` may also implement the optional persistent transport. It is
started with `serve` and reads newline-delimited request objects:

```json
{"id":1,"args":["teams","chat","list","--output","json"]}
```

and responds with the same integer ID:

```json
{"id":1,"ok":true,"result":[]}
```

Failures use `{"id":1,"ok":false,"error":"redacted explanation"}`. Responses
may complete out of order. Never print logs or banners to persistent stdout.

## Verify the Connection

1. Test the existing OAuth owner independently and confirm it is signed in.
2. Configure one boundary above and evaluate the settings in Emacs.
3. Run `M-x teams4e-status`. Confirm the account and a fresh Graph token.
4. Run `M-x teams4e` to open the inbox.
5. Open `M-x teams4e-meetings` only after chat works; calendar scopes are
   separate and often require additional approval.

For UI evaluation without any identity provider, use:

```elisp
(setq teams4e-mock-mode t)
(teams4e)
```

After testing the mock, run `M-x teams4e-mock-disable` before connecting to your
real account.

## Permissions Are Feature-Specific

Configure scopes through the approved OAuth owner, not by editing a token.
Use the least privileges needed for your chosen operations. Chat access alone
does not imply calendar access, and permissions do not override sharing policy.

- Free/busy through [getSchedule](https://learn.microsoft.com/en-us/graph/api/calendar-getschedule?view=graph-rest-1.0)
  supports delegated `Calendars.ReadBasic` as its least-privileged option.
- Ranked alternatives through [findMeetingTimes](https://learn.microsoft.com/en-us/graph/api/user-findmeetingtimes?view=graph-rest-1.0)
  use delegated `Calendars.Read.Shared` or an appropriate higher permission.
- Calendar responses and new-time proposals require calendar write access.
  Consult the endpoint permissions for the operations you enable.

These are examples, not an exhaustive permission manifest for every feature.
Resolve chat access first; add calendar and attachment capabilities as needed.

## Troubleshooting

| Symptom | Check |
| --- | --- |
| Token command output cannot be parsed | Keep stdout to one raw token or one JSON object; move logs to stderr |
| Token is immediately rejected | Confirm its audience is Microsoft Graph and it is not expired |
| Chat works but calendar is unavailable | Request the relevant delegated calendar scopes through the existing owner |
| Credential file is ignored | Check the file path and `server_name`; add the exact `server_url` selector only when needed |
| MCP connection works elsewhere but teams4e cannot connect | The MCP host must export a Graph token or be wrapped by a backend adapter |
| Mutating actions fail while reads work | The approved token may lack write scopes or tenant policy may block that operation |

## Local Data

Credential storage and application data are separate. The reading cache, drafts,
images, downloaded attachments, Markdown exports, and Org captures can contain
workplace content even though they are not token stores. Keep these outside
source repositories and choose paths and backups appropriate for your data.
Do not attach them wholesale to public issues. Agent analysis explicitly gives
your selected agent access to an exported thread; it is optional.

## Security Boundary

- `teams4e` does not include a client ID, client secret, tenant ID, refresh token,
  or organization-specific endpoint.
- Token commands are argv arrays and are not evaluated by a shell.
- Package diagnostics redact tokens and outgoing message arguments, but review
  provider/server output and screenshots yourself before sharing them.
- Access tokens exist in the backend process memory and in the HTTP
  `Authorization` header; use the backend-adapter pattern if even short-lived
  token export is unacceptable.
- A token grants only what its scopes and tenant policy permit. Reusing an
  approved OAuth owner reduces duplicate identity machinery; it does not expand
  authority.

For local storage, process-argument visibility, agent sharing, and safe reports,
see [SECURITY.md](SECURITY.md).

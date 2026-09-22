# Local Testing Without a Teams Tenant

teams4e has three useful test levels. Only the last one proves Microsoft 365
authorization and tenant behavior.

## 1. Offline Contract Suite

Run the complete account-free suite:

```sh
make test
make compile
```

ERT exercises the real Emacs UI against fixtures and the persistent mock
tenant. Python tests patch the HTTP boundary and verify Graph URL construction,
pagination, batches, retries, cache behavior, and mutations. No credentials or
network are required.

## 2. Delayed Interactive Mock

The deterministic mock uses the production argv/JSON process protocol. Add
latency to reveal unnecessary blocking, duplicate redraws, stale callbacks, and
selection/reader divergence:

```elisp
(setq teams4e-mock-mode t
      teams4e-mock-delay-ms 250
      teams4e-cache-first t
      teams4e-use-persistent-backend t)
```

Then run:

```text
C-u M-x teams4e-mock-enable   reset the fake tenant
M-x teams4e-sync              populate its SQLite reading cache
M-x teams4e                   open cache-first, then refresh
b m                           exercise meeting enrichment
g                             force a fresh calendar attachment
M-x teams4e-performance-report
```

Use `C-u M-x teams4e-performance-report` to clear old measurements. The report
is held only in memory and includes operation labels, transport, status, item
counts, and durations. It excludes content, people, IDs, URLs, and tokens.

Useful stress values are 100-300 ms for ordinary latency and 1000-2000 ms for
visible races. Set `teams4e-mock-delay-ms` back to zero after testing.

### Try the public workflow

In the mock inbox, open a conversation with `RET`, return to the headers, and:

1. Press `b t`, then `F` twice. The unread filter should toggle while the
   Today bookmark remains selected.
2. Press `z` on a conversation. It should disappear from the ordinary view.
3. Press `b s`. Find the conversation and its wake time, then press `Z u`
   to unsnooze it.
4. Press `b a` to return to All active chats. Open a thread and compose a
   reply with `R`; insert a participant mention with `C-c C-m`.
5. Exercise `a e` to export Markdown, and `b m` to inspect mock meetings.

These operations stay in the mock. Agent analysis (`a g`) is a separate,
optional integration and can start a real configured agent even in mock mode.
When finished, `M-x teams4e-mock-disable` returns to the live backend; it
does not configure authentication.

## Optional Link-Hint Integration Tests

CI also tests link discovery, opening, and copying against pinned versions of
link-hint and Avy. With those packages installed locally:

```sh
emacs -Q --batch -L . -L /path/to/link-hint -L /path/to/avy \
  -l tests/teams4e-link-hint-tests.el -f ert-run-tests-batch-and-exit
```

These tests use synthetic URLs and intercept browser/clipboard actions.
They cover rich-renderer link properties, plain HTML rendering, and card and
attachment links; no Teams account or browser launch is needed.

## 3. Microsoft-Supported External Tests

[Microsoft Dev Proxy][dev-proxy] can intercept Graph URLs and return documented
mock responses without calling Graph. It can also inject latency, throttling,
5xx responses, and malformed or missing batch responses, and can reject every
unmocked request. It is useful for HTTP resilience and Graph wire-contract
tests. It does not prove OAuth, delegated consent, service quirks, or tenant
data.

A personal Microsoft account is insufficient: the Graph
[list chats](https://learn.microsoft.com/en-us/graph/api/chat-list?view=graph-rest-1.0)
API supports delegated work or school accounts, not personal accounts.

The closest full test environment is a qualifying [Microsoft 365 E5 developer
sandbox][developer-sandbox]. Microsoft currently documents a preconfigured
instant sandbox with fictitious users plus Teams, Graph mail, and calendar
sample data. Eligibility is limited, the subscription is for development, and
it can expire or be revoked.

Therefore:

- Use the offline suite for every commit.
- Use delayed mock sessions for UI responsiveness and race testing.
- Use Dev Proxy for Graph failure and wire-shape scenarios.
- Use an E5 sandbox or a harmless company test chat for final OAuth, consent,
  live Teams behavior, and tenant-specific performance validation.

[dev-proxy]: https://learn.microsoft.com/en-us/microsoft-cloud/dev/dev-proxy/how-to/mock-responses
[developer-sandbox]: https://learn.microsoft.com/en-us/office/developer-program/microsoft-365-developer-program-get-started

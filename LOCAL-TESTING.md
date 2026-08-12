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

# Contributing to teams4e

teams4e is a standalone Emacs package. Contributions should work without the
maintainer's Emacs distribution, organization, account, agent skills, or local
tools.

## Reproduce with the mock

Start with [LOCAL-TESTING.md](LOCAL-TESTING.md). The bundled mock exercises the
same argv/JSON boundary as the live backend and needs no account. For a UI
report, include the key sequence, expected result, actual result, Emacs version,
and whether Evil is enabled. For slow operations, include the content-free
`M-x teams4e-performance-report` when useful.

If an issue only happens live, describe the operation and a redacted error.
Do not attach access tokens, credential files, real transcripts, cache databases,
or screenshots containing workplace information. Synthetic JSON reproductions
are preferable.

## Make a focused change

Keep organization-specific login and refresh logic in the external token
provider or backend adapter. Add user preferences through the `teams4e`
Customize group; do not embed account addresses, tenant IDs, private paths,
browser profiles, or required agent skills in package defaults.

Reuse the canonical chat list and established local state. View filters should
compose without copying or synchronizing separate inbox representations.

Run these checks from the repository root with Emacs and Python installed:

```sh
make test
make compile
git diff --check
```

Add regression coverage for behavioral changes, particularly asynchronous
updates, filter boundaries, and backend contracts. Update the README and
changelog when a user-visible command or default changes.

## Integration contributions

[AUTHENTICATION.md](AUTHENTICATION.md) documents token commands, shared credential
records, and custom backend adapters. Describe prerequisites and supported
operations explicitly. A successful mock test does not establish that a
particular tenant grants calendar or chat permissions.

Use reserved example identities in fixtures and demos. Keep live data outside
the checkout, and inspect the staged diff before submitting a pull request.
The source is licensed under GPL-3.0-or-later; see [LICENSE](LICENSE).

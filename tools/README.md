# Real Emacs demo captures

The README images are exported by graphical Emacs, not recreated in HTML.
They use the actual teams4e inbox, reader, Org composer, meeting view, and
bundled mock backend. Conversation text and identities are synthetic.

## Reproduce the screenshots

Run the **Capture real Emacs demo** workflow from GitHub Actions, or:

```sh
gh workflow run capture.yml --repo guibor/teams4e
```

The workflow pins Moe Dark, Iosevka, and Agent Shell's Markdown renderer.
It installs graphical Emacs and runs it under Xvfb. Download the
`real-emacs-demo` artifact after the workflow succeeds. It contains four PNGs,
the GIF assembled from those PNGs, and `capture.json` with the Emacs version,
source revision, theme, font, and capture method.

Inspect all four PNGs before replacing README assets. The workflow does not
automatically commit anything or update the README.

For local capture, install Emacs 29.1+ with graphical/Cairo support, Python
3.10+, Pillow, and Iosevka. Make Moe Theme and Agent Shell available on
Emacs's load path. The exact pinned revisions and font download are in
[the workflow](../.github/workflows/capture.yml).

```sh
mkdir -p .tmp/capture
emacs -Q -L . -L /path/to/moe-theme.el -L /path/to/agent-shell \
  --load tools/capture-demo.el
python3 tools/assemble-demo.py .tmp/capture
```

A headless machine also needs Xvfb; use the invocation in the workflow.

## What is and is not represented

- Screenshots come from `x-export-frames`, with no added labels, overlays,
  reconstructed UI, or color substitutions.
- Moe Dark and Iosevka match the configuration used for the demo. This is a
  clean Emacs session, not a capture of a personal Spacemacs profile.
- Incoming rich text uses Agent Shell's optional Markdown renderer. Outgoing
  composition uses Org mode and teams4e's real split reader/composer layout.
- The mock backend provides data only; rendering and navigation are the actual
  package code. This is not evidence of live Microsoft authentication.
- Every run uses new temporary state/cache/draft paths. It never loads an
  existing Teams account, sends a real message, or modifies a user's session.
- Dates are relative to capture day, so the upcoming meeting view remains
  meaningful when the demo is regenerated.
- The script fails if Moe Dark or Iosevka is missing instead of silently using
  a different appearance.

`seed-demo.py` builds the synthetic tenant using the bundled mock schema.
It refuses to overwrite an existing state file.

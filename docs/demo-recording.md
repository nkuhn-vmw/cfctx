# Recording a demo for the README

Asciinema + svg-term-cli gives you a small, crisp SVG you can embed in
GitHub's README (GitHub renders `<img>` tags for SVG but not for video).

## One-time setup

```bash
brew install asciinema svg-term
```

## Record

```bash
# In a fresh Ghostty terminal, sized to ~100 cols x 24 rows:
asciinema rec /tmp/cfctx.cast \
    --cols 100 --rows 24 \
    --idle-time-limit 2 \
    --title "cfctx — one-command Tanzu context switching"

# Inside the recording shell, do a clean demo:
cfctx                                    # list foundations
cfctx tdc                                # switch → sources env, auto-logs-in, retargets cf
cf apps | head -5                        # prove it works
cfctx ndc                                # switch foundations instantly (cached token)
cfctx doctor                             # health check
cfctx clear                              # unset
exit
```

## Turn it into an SVG

```bash
svg-term --in /tmp/cfctx.cast --out docs/demo.svg --window --no-optimize
```

Keep dimensions modest — SVG can be ~200KB. If too big, re-record with
shorter idle times or trim the cast with `asciinema cat` + manual edits.

## Or host on asciinema.org

```bash
asciinema upload /tmp/cfctx.cast
# → prints a URL like https://asciinema.org/a/<id>
```

Then update README.md: uncomment the line around "demo: record with..."
and fill in `<ID>`.

## What to show (recommended ordering)

1. `cfctx` — the listing with color + URLs
2. `cfctx tdc` — first switch (shows enrichment if fresh)
3. `cf apps` (or any `cf` command) — prove the session works
4. `cfctx ndc` — second foundation switch (instant, cached tokens)
5. `cfctx doctor` — health check output
6. `cfctx pick` — fzf interactive picker (if you have it installed)

Keep it under 45 seconds. README demos get skipped if too long.

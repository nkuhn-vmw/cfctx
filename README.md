# cfctx

[![CI](https://github.com/nkuhn-vmw/cfctx/actions/workflows/ci.yml/badge.svg)](https://github.com/nkuhn-vmw/cfctx/actions/workflows/ci.yml)
[![Latest release](https://img.shields.io/github/v/release/nkuhn-vmw/cfctx?label=release)](https://github.com/nkuhn-vmw/cfctx/releases/latest)
[![License](https://img.shields.io/github/license/nkuhn-vmw/cfctx)](LICENSE)
[![Shell](https://img.shields.io/badge/shell-bash%20%7C%20zsh-blue)](https://github.com/nkuhn-vmw/cfctx)
[![Platform](https://img.shields.io/badge/platform-macOS%20%7C%20Linux-lightgrey)](https://github.com/nkuhn-vmw/cfctx#install)

**Per-shell Cloud Foundry / Tanzu context switcher. Think [kubectx](https://github.com/ahmetb/kubectx), for CF / Ops Manager / BOSH / CredHub.**

Two muscle-memory commands:

```bash
cfctx                  # list all foundations, current one highlighted
cfctx tdc              # target tdc: source om/bosh/credhub env + cf login, done.
cf apps                # works
om staged-products     # works
bosh vms               # works
cfctx ndc              # switch foundations — tokens cached, instant
```

Each terminal gets its own `CF_HOME` directory, so `cf target`, logins, and
OAuth tokens never collide across shells. On first touch of a foundation,
cfctx asks **Ops Manager** via `om` for the CF API URL, BOSH env vars, and CF
admin creds, writes them into the per-context env file, and logs in. Tokens
cache in `$CF_HOME/.cf/config.json`; subsequent switches are sub-second.

<!-- demo: record with `asciinema rec demo.cast` then `asciinema upload demo.cast`
     and replace the ID below. Or embed the generated SVG from svg-term-cli. -->
<!-- [![asciicast](https://asciinema.org/a/<ID>.svg)](https://asciinema.org/a/<ID>) -->

```
  cdc [env]  https://api.sys.cdc.example.com
* ndc [env]  https://api.sys.ndc.example.com         ← current (color-coded in a TTY)
  tdc [env]  https://api.sys.tdc.example.com
```

---

## Why

The CF CLI stashes *everything* — API, org, space, tokens — in a single file
under `$CF_HOME/.cf/config.json`. With `CF_HOME=$HOME` (the default), every
shell on the box shares one target. Run `cf target -o prod` in one tab and
every other tab silently follows. That's how people `cf delete-app` the
wrong foundation.

`cfctx` sets `CF_HOME` to a per-context directory *in the current shell only*.
Sibling shells are unaffected. Tokens persist between switches, so you don't
re-login when bouncing between foundations.

Layered on top of that primitive, cfctx adds:

- Per-context `context.env` file (mode 0600) with `OM_*`, `BOSH_*`, `CREDHUB_*`
  sourced on every switch.
- **Auto-import from `om` YAML env files** you probably already have.
- **Auto-enrichment from Ops Manager**: `BOSH_*` from `om bosh-env`, `CF_API`
  derived from the cf product's `system_domain`, `CF_USERNAME`/`CF_PASSWORD`
  pulled from cf's UAA admin credentials.
- **Auto CF login** on first switch, cached on all subsequent ones.
- **Default `CF_ORG=system` / `CF_SPACE=system`**, overridable per-context.
- **Prompt indicator** (`cfctx prompt zsh >> ~/.zshrc`) with per-context
  colors (`cfctx color prod red`).
- `cfctx doctor` for diagnostics.

---

## Install

### macOS — Homebrew (recommended)

```bash
brew tap nkuhn-vmw/tap
brew install cfctx
echo 'source "$(brew --prefix)/opt/cfctx/libexec/cfctx.sh"' >> ~/.zshrc
exec $SHELL
```

Tanzu CLIs that cfctx orchestrates (if you don't already have them):

```bash
brew install jq                                 # recommended — for CF_API / CF-creds auto-detection
brew install fzf                                # optional — enables `cfctx pick`
brew install cloudfoundry/tap/cf-cli@8
brew install pivotal/tap/om
brew install cloudfoundry/tap/bosh-cli
brew install cloudfoundry/tap/credhub-cli
```

### macOS — from source (for contributors)

```bash
git clone https://github.com/nkuhn-vmw/cfctx.git ~/.local/share/cfctx
bash ~/.local/share/cfctx/install.sh    # idempotently wires ~/.zshrc or ~/.bash_profile
exec $SHELL
```

### Linux (Ubuntu / Debian)

```bash
# Core deps from apt:
sudo apt-get update
sudo apt-get install -y jq curl wget

# cf CLI (Cloud Foundry):
wget -q -O - https://packages.cloudfoundry.org/debian/cli.cloudfoundry.org.key | sudo apt-key add -
echo "deb https://packages.cloudfoundry.org/debian stable main" | sudo tee /etc/apt/sources.list.d/cloudfoundry-cli.list
sudo apt-get update && sudo apt-get install -y cf8-cli

# om CLI (Ops Manager) — binary release from pivotal-cf/om:
OM_VERSION=7.14.2      # https://github.com/pivotal-cf/om/releases
sudo curl -fsSL -o /usr/local/bin/om "https://github.com/pivotal-cf/om/releases/download/${OM_VERSION}/om-linux-amd64-${OM_VERSION}"
sudo chmod +x /usr/local/bin/om

# bosh CLI:
BOSH_VERSION=7.7.1     # https://github.com/cloudfoundry/bosh-cli/releases
sudo curl -fsSL -o /usr/local/bin/bosh "https://s3.amazonaws.com/bosh-cli-artifacts/bosh-cli-${BOSH_VERSION}-linux-amd64"
sudo chmod +x /usr/local/bin/bosh

# credhub CLI (optional but recommended):
CREDHUB_VERSION=2.9.45 # https://github.com/cloudfoundry/credhub-cli/releases
curl -fsSL -o /tmp/credhub.tgz "https://github.com/cloudfoundry/credhub-cli/releases/download/${CREDHUB_VERSION}/credhub-linux-amd64-${CREDHUB_VERSION}.tgz"
sudo tar -xzf /tmp/credhub.tgz -C /usr/local/bin/ credhub && rm /tmp/credhub.tgz

# cfctx itself (same as macOS from here):
git clone https://github.com/nkuhn-vmw/cfctx.git ~/.local/share/cfctx
bash ~/.local/share/cfctx/install.sh    # wires ~/.bashrc (or ~/.zshrc if you use zsh)
exec $SHELL
```

**Linux notes:**
- Default shell is bash, so `install.sh` appends to `~/.bashrc`. For zsh users (`chsh -s $(which zsh)`), it wires `~/.zshrc` instead.
- `bash install.sh` is idempotent — safe to re-run. The source line is bracketed with `# >>> cfctx >>>` / `# <<< cfctx <<<` markers for clean uninstall.
- `jq` is required for automatic `CF_API` / CF-admin-credential detection. BOSH-env enrichment works without jq.
- For air-gapped installs, download the tarballs from a workstation and `scp` them in — cfctx itself has no runtime deps beyond the standard Tanzu CLIs.

### Manual install (any platform)

```bash
git clone https://github.com/nkuhn-vmw/cfctx.git ~/.local/share/cfctx
echo 'source ~/.local/share/cfctx/cfctx.sh' >> ~/.zshrc    # or ~/.bashrc
exec $SHELL
```

If you already keep `om` env files in a single directory, point cfctx at
them so it can auto-discover:

```bash
echo 'export CFCTX_OM_ENV_DIR="$HOME/env"' >> ~/.zshrc
```

Default auto-discovery patterns (for context name `tdc`):
`tdc.yml` → `tdc.yaml` → `om-cli-tdc.yml` → `om-cli-tdc.yaml`. Override with
`CFCTX_OM_ENV_PATTERNS="foundation-NAME.yaml ..."` (`NAME` is the placeholder).

Add the prompt indicator:

```bash
cfctx prompt zsh >> ~/.zshrc       # (or: cfctx prompt bash)
```

---

## Daily use

```bash
cfctx                # list all foundations
cfctx tdc            # target (idempotent — first call does full enrichment)
cf apps              # works
om staged-products   # works (OM_* already in shell)
bosh vms             # works (BOSH_* already in shell)
cfctx ndc            # switch to a different foundation; tokens cached
cfctx                # list again; NDC now the active one
cfctx clear          # unset CF_HOME + OM_*/BOSH_*/CREDHUB_* in this shell
```

### Change org / space

```bash
cfctx tdc --org myteam --space staging    # persist to tdc's context.env
cf target -o otherone                      # temporary (this shell only)
```

### Color-code foundations

```bash
cfctx color lab    green
cfctx color prod   red
cfctx color stg    yellow
```

The prompt segment (if you installed it) will pick up the color on next switch.

### Re-enrich from Ops Manager

If a foundation gets re-paved, certs rotate, or the CF password changes,
refresh the env file in place:

```bash
cfctx enrich tdc
```

Preserves any manual edits outside the `BOSH-FROM-OM` sentinel block.

### Diagnostic

```bash
cfctx doctor              # tools, env, per-context state
cfctx doctor --online     # also probe each foundation's OM reachability
```

---

## Subcommands

| Command | What it does |
|---|---|
| `cfctx` | List all foundations, current highlighted, with `[env]` and target URL. |
| `cfctx <name> [flags]` | Target a foundation: stamp `context.env`, enrich from OM, switch, auto-login. |
| `cfctx target <name>` | Explicit alias for the bare form. |
| `cfctx pick` | fzf-based interactive picker (requires `fzf`). |
| `cfctx enrich [name]` | Re-query Ops Manager to refresh `BOSH_*` / `CF_API` / CF creds. Idempotent. |
| `cfctx edit [name]` | Open `context.env` in `$EDITOR` (stamps a template if absent). |
| `cfctx env [name]` | Print `context.env` with secret-looking values masked. |
| `cfctx init-env <name>` | Stamp only (no switch, no login). `--from-om <file>`, `--force`, `--no-enrich`. |
| `cfctx cp <src> <dst>` | Duplicate a context (including env file). |
| `cfctx mv <old> <new>` | Rename a context. |
| `cfctx rm <name>` | Delete a context. Clears `CF_HOME` if it matched. |
| `cfctx status` | Current-context details (CF_HOME + `cf target` output). |
| `cfctx doctor [--online]` | Health check: tools, env, per-context state (+ OM reachability). |
| `cfctx prompt [zsh\|bash\|starship]` | Emit a prompt snippet. |
| `cfctx color <name> [<color>\|clear]` | Set/clear per-context prompt color. |
| `cfctx clear` | `unset CF_HOME` + `OM_*` / `BOSH_*` / `CREDHUB_*` in this shell. |
| `cfctx version` / `cfctx help` | Self-explanatory. |

Flags on `cfctx <name>` / `cfctx target <name>`:

| Flag | Effect |
|---|---|
| `--from-om <file>` | Pre-fill `OM_*` from a specific `om` env yaml. |
| `--cf-api <url>` | Persist `CF_API` (usually auto-detected — use when OM enrichment can't run). |
| `--org <name>`, `--space <name>` | Persist `CF_ORG` / `CF_SPACE`. |
| `--force` | Re-seed `context.env` from scratch. |
| `--no-login` | Skip CF auto-login for this switch. |
| `--no-enrich` | Skip the OM API calls (yaml-only import). |
| `--create` | Bypass the "create new blank context?" confirmation. |

---

## Interactive picker (fzf)

If you have `fzf` installed, pick a foundation interactively:

```bash
cfctx pick
```

Opens an fzf prompt over all configured contexts with a preview pane showing
`CF_API`, `CF_ORG`, `CF_SPACE`, `OM_TARGET`, `BOSH_ENVIRONMENT` (secrets
redacted). Type to filter, Enter to switch — runs the full `cfctx <name>`
flow (auto-login, wraps, etc.). `Esc` cancels without switching.

If fzf isn't installed, `cfctx pick` prints a clear install hint and exits
non-zero; everything else in cfctx keeps working without fzf.

## Token-expiry awareness

Every `cfctx <name>` silently decodes the cached CF token's JWT `exp` claim.
If it's within 60s of expiring (or already expired), auto-login re-authenticates
transparently — no more "logged out mid-session" surprises after a tab sits
idle overnight. Requires `jq`; without it, tokens are trusted based on
presence only (previous behavior).

`cfctx doctor` surfaces expiry per-context:

```
  tdc
    [✓] CF token cached (expires in 23h)
  cdc
    [!] CF token EXPIRED 2h ago — next switch will re-auth
```

## UAA / `uaac` integration

Each Tanzu foundation has up to four UAAs (cf, ops manager, bosh, credhub).
The CF UAA is the one operators touch most — managing CF users, configuring
SSO providers, etc. cfctx enriches both the CF UAA URL and the OpsMan UAA
URL into `context.env`, plus the CF UAA admin client secret pulled
straight from Ops Manager.

After `cfctx <foundation>`:

```bash
echo $UAA_URL                    # → https://uaa.<system_domain>  (CF UAA)
echo $UAA_ADMIN_CLIENT            # → admin
echo $UAA_ADMIN_CLIENT_SECRET     # → <pulled from .uaa.admin_client_credentials>
echo $OM_UAA_URL                  # → <om_target>/uaa  (OpsMan UAA — rarely used)
```

To target the CF UAA via `uaac` and fetch a token in one step:

```bash
cfctx uaa-login                  # default: CF UAA
# Under the hood:
#   uaac target $UAA_URL [--skip-ssl-validation]
#   uaac token client get $UAA_ADMIN_CLIENT -s $UAA_ADMIN_CLIENT_SECRET
#   uaac context

cfctx uaa-login --om             # explicit: OpsMan UAA (uses OM_CLIENT_ID/SECRET)
```

`uaac` not installed? `gem install cf-uaac`. The subcommand prints a clear
hint if it's missing.

## Non-interactive shells (CI / Claude Code / scripts)

`cfctx` is a sourced shell function — it has to mutate the parent
shell's env. That model doesn't fit non-interactive contexts where
each invocation is a fresh shell:

- CI scripts that spin up disposable bash shells.
- Claude Code (or other agentic tools) where every `Bash` tool call
  is independent.
- One-shot scripts where you don't want to permanently modify your shell.

For those cases, use the **`cfctx-env`** standalone helper — a small
script that prints `export` lines for a foundation, ready to `eval`
in any shell:

```bash
# In any bash/zsh, no sourcing required:
eval "$(cfctx-env tdc)"
cf apps                  # works — CF_HOME + tokens loaded
om staged-products       # works — OM_* loaded
bosh vms                 # works — BOSH_* loaded
```

Also useful:

```bash
cfctx-env --list         # which foundations are configured
cfctx-env tdc            # just print (no eval) — for inspection
cfctx-env --help
```

The script lives at `bin/cfctx-env` in the repo. With Homebrew install
it's on your `PATH` automatically. Without Homebrew, add the repo's
`bin/` to `PATH` or call by full path.

**What `cfctx-env` does NOT do** vs. interactive `cfctx`:

- Doesn't query Ops Manager (no enrichment / re-auth round-trip).
- Doesn't run `cf api` / `cf auth` — relies on cached tokens.
- Doesn't install bosh/cf TERM wraps or terminal affordances.

These would all require shell-function semantics. If your context.env
is stale (foundation re-paved, certs rotated), run an interactive
`cfctx <foundation>` once in your zsh to re-enrich, then `cfctx-env`
in your scripts will pick up the fresh values from disk.

If you're using cfctx with Claude Code, the recommended pattern is:

```bash
# In every Bash tool call that needs CF/OM/BOSH access:
eval "$(cfctx-env tdc)" && cf apps
```

Or wrap it in a one-line shell alias / Claude skill so you don't have
to type the `eval` boilerplate every call.

## Terminal affordances (title / cursor color / clickable URLs)

On every `cfctx <name>`, cfctx emits three OSC escape sequences when
stdout is a TTY:

- **OSC 2** sets the window / tab title to `cfctx:<name>`. Visible in
  the Ghostty tab bar, iTerm2 window titles, tmux status lines,
  gnome-terminal tabs. Permanent per-tab "which foundation is this?"
  without any prompt integration.
- **OSC 12** sets the cursor color from the per-context `.cfctx-color`
  tag. Set it with `cfctx color prod red` — cursor turns red on every
  switch into `prod`. A second always-visible signal on top of the
  prompt color.
- **OSC 8** wraps the target URL in the `cfctx` listing as a clickable
  hyperlink. Cmd-click (macOS) or Ctrl-click (Linux) opens the API in
  your browser.

`cfctx clear` resets the title and cursor to terminal defaults.

These are universal VT/xterm standards supported by Ghostty, iTerm2,
Terminal.app, WezTerm, kitty, tmux, gnome-terminal, and Konsole.
Nothing here is Ghostty-specific — it just looks especially nice
with Ghostty's native tab UI.

Piped output (e.g. `cfctx | grep ndc`) stays clean because all emissions
are gated on `[[ -t 1 ]]`. Disable entirely with `CFCTX_NO_TERM_AFFORDANCES=1`.

## Ghostty / Kitty / Alacritty (`xterm-ghostty` on remote hosts)

If your local terminal sets `TERM=xterm-ghostty` (or `xterm-kitty`,
`alacritty-direct`), remote hosts that don't have that terminfo entry
installed will fail curses-based tools with:

```
Error opening terminal: xterm-ghostty.
```

On switch, cfctx detects an "exotic" TERM and silently installs two
shell-function overrides:

```bash
bosh ssh director-0     # really runs: TERM=xterm-256color command bosh ssh director-0
cf ssh my-app           # really runs: TERM=xterm-256color command cf ssh my-app
```

No typing changes. Local-shell `$TERM` is untouched, so Ghostty's
native features (image protocol, cursor shapes) keep working for
local commands.

Safety:

- Only triggers for specific exotic TERMs (falls through for `xterm-256color`, `tmux-256color`, `screen-256color`, etc.).
- Skips installation if you already have your own `bosh` / `cf` alias or function.
- Marker comment (`__cfctx_term_wrap__`) in the generated functions ensures uninstall only removes our own wraps, not user-defined ones.

Knobs:

```bash
export CFCTX_NO_TERM_WRAPS=1         # disable entirely
export CFCTX_SAFE_TERM=xterm         # use a different fallback TERM
```

Uninstall is automatic on `cfctx clear`. Status is visible in `cfctx doctor`.

## Security posture

- **Per-context env files live at `$CFCTX_ROOT/<name>/context.env` (default
  `~/.cf-homes/<name>/context.env`), mode `0600`.** cfctx refuses to source
  files with looser permissions, and re-applies `0600` after every edit.
- **Never committed to git.** The repo's `.gitignore` excludes `*.env`,
  `context.env`, `.cf-homes/`, `.cf/`, common key filenames.
- **`cfctx env <name>`** masks values for any key matching
  `PASSWORD|SECRET|TOKEN|KEY|CA_CERT|PRIVATE` so output can be pasted safely.
- **CF admin passwords** retrieved from Ops Manager contain special
  characters (`$`, `"`, `\`, backtick) — cfctx escapes them for safe shell
  re-sourcing. Round-trip tested.
- **Prefer a secret manager over plaintext** when possible. `context.env`
  is a regular shell file, so you can use:
  ```bash
  export OM_PASSWORD="$(security find-generic-password -s om-tdc -w)"   # Keychain
  export BOSH_CLIENT_SECRET="$(pass show tanzu/tdc/bosh)"                # pass
  export OM_PASSWORD="$(op read 'op://Private/om-tdc/credential')"       # 1Password
  ```
  These run every time you switch, giving you auto-refresh of short-lived
  creds.

---

## Why each of `om` / `bosh` / `credhub` / `cf` behaves differently

| Tool | How auth persists | Requires env creds per call? |
|---|---|---|
| `cf` | OAuth tokens cached in `$CF_HOME/.cf/config.json` | no — tokens cached |
| `om` | none | **yes** — every call re-auths |
| `bosh` | short-lived refresh tokens in `~/.bosh/config` | **yes** — client/secret still needed |
| `credhub` | none | **yes** |

That's why `OM_*`, `BOSH_*`, and `CREDHUB_*` all live in `context.env` and
get sourced on every switch, while `CF_*` is mostly auto-populated on the
first login and then cached.

---

## Testing

```bash
brew install bats-core
bats tests/
```

The suite includes mock `cf`, `om`, and `fzf` binaries plus a JWT builder
helper, so it runs without network or a real foundation. **112 tests**,
covering: switch/ls/clear, env-file handling, om yaml import, om-enrichment
happy/unreachable paths, CF auto-login (fresh, cached, expired-JWT,
credential-failure, org/space targeting), typo guard, prompt snippet
emission, color tagging, `cfctx doctor`, TERM wraps, JWT expiry parsing,
and the fzf picker.

CI runs six jobs on Ubuntu + macOS: `shellcheck`, `bats` × 2, `zsh-smoke`
× 2 (sources cfctx.sh under real zsh and exercises helpers known to
drift between shells), and `install-smoke` (runs install.sh in a
disposable HOME and asserts idempotency + source-ability).

---

## Repository layout

```
cfctx/
├── README.md
├── LICENSE                           # Apache-2.0
├── cfctx.sh                          # the sourced shell function
├── bin/
│   └── cfctx-env                     # standalone helper for non-interactive shells
├── install.sh                        # idempotent rc-file installer
├── completions/
│   ├── cfctx.zsh
│   └── cfctx.bash
├── examples/
│   └── context.env.example           # annotated template (committed — safe)
├── tests/
│   ├── README.md
│   ├── switch.bats
│   ├── env.bats
│   ├── target.bats
│   ├── autologin.bats
│   ├── enrich.bats
│   ├── default-verb.bats
│   ├── tier1.bats                    # prompt / color / doctor / did-you-mean
│   ├── term-wraps.bats                # bosh/cf TERM overrides on exotic terminals
│   ├── token-expiry.bats              # JWT exp decoding + re-auth flow
│   └── pick.bats                      # fzf picker (uses a mock fzf)
├── docs/
│   ├── tanzu-integration.md
│   └── roadmap.md                     # design doc + pending items
└── .github/
    └── workflows/
        └── ci.yml
```

---

## Status and roadmap

v0.4.0. Production-ready for single-user workstations. Full design doc
and roadmap in [`docs/roadmap.md`](docs/roadmap.md).

**Shipped in v0.4.0:**

- **UAA / `uaac` integration.** Enrichment now writes `UAA_URL`,
  `UAA_ADMIN_CLIENT`, `UAA_ADMIN_CLIENT_SECRET` (from
  `.uaa.admin_client_credentials`), and `OM_UAA_URL` to `context.env`.
  New `cfctx uaa-login` subcommand wraps `uaac target` + `uaac token
  client get` against the CF UAA by default, or OpsMan UAA with `--om`.
- **`set -e` safety.** Internal `cmd; rc=$?` patterns refactored to
  `cmd || rc=$?` so `cfctx enrich` works correctly under bats' set-e
  test mode and CI shells with `set -e`.

**Shipped in v0.3.2:**

- **`cfctx-env` standalone helper** for non-interactive shells (CI,
  Claude Code, scripts). `eval "$(cfctx-env <foundation>)"` loads the
  context env into any shell without sourcing the cfctx function. See
  [Non-interactive shells](#non-interactive-shells-ci--claude-code--scripts).
- Defensive `eval`-wrap around zsh-only syntax in `cfctx.sh` so even
  strict-mode bash setups can source the file cleanly.

**Shipped in v0.3.1:**

- **Terminal affordances** — OSC 2 window title (`cfctx:<name>`),
  OSC 12 cursor color from `.cfctx-color`, OSC 8 clickable URLs in
  the `cfctx` listing. TTY-gated; opt-out via
  `CFCTX_NO_TERM_AFFORDANCES=1`. Works in Ghostty, iTerm2,
  Terminal.app, tmux, WezTerm, gnome-terminal.

**Shipped since v0.2.0:**

- Ghostty/Kitty/Alacritty TERM wraps for remote `bosh ssh` / `cf ssh`.
- Token-expiry awareness via JWT `exp` claim (silent re-auth near expiry).
- `cfctx pick` — fzf-based interactive picker with preview pane.
- Cross-foundation correctness: OM_* env from a previous switch no
  longer leaks into the next foundation's enrichment.
- zsh compatibility hardening (NO_MATCH glob error, `${=var}` word split).
- BSD-vs-GNU `stat` portability across every call site.
- Linux install docs (apt + binary-download recipes).
- CI hardening: zsh-smoke + install-smoke jobs alongside bats on
  ubuntu-latest + macos-latest. 112 tests total.

**Pending:**

- `cfctx lock <name>` — read-only safety rail (prompts on destructive ops).
- direnv bridge (`cfctx direnv`) — auto-switch foundations on `cd`.
- Install.sh `--link` flag (symlink instead of copy — keeps installed
  version in sync with a local clone).
- Windows PowerShell port (deferred).

**Homebrew tap:** available at
[nkuhn-vmw/homebrew-tap](https://github.com/nkuhn-vmw/homebrew-tap).
`brew install nkuhn-vmw/tap/cfctx` is the recommended install path.

---

## License

Apache-2.0. See `LICENSE`.

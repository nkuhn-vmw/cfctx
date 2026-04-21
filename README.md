# cfctx

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

### macOS

```bash
# Tanzu CLIs (adjust tap names if your org uses a mirror):
brew install jq
brew install cloudfoundry/tap/cf-cli@8
brew install pivotal/tap/om
brew install cloudfoundry/tap/bosh-cli
brew install cloudfoundry/tap/credhub-cli

# cfctx itself:
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

The suite includes mock `cf` and `om` binaries, so it runs without network
or a real foundation. 80 tests, covering switch/ls/clear, env-file
handling, om yaml import, om-enrichment happy/unreachable paths, CF
auto-login (fresh, cached, credential-failure, org/space targeting), typo
guard, prompt snippet emission, color tagging, and `cfctx doctor`.

CI runs on Ubuntu + macOS (both bash and zsh-sourced paths exercised
via dual shell tests).

---

## Repository layout

```
cfctx/
├── README.md
├── LICENSE                           # Apache-2.0
├── cfctx.sh                          # the sourced shell function
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
│   └── tier1.bats                    # prompt / color / doctor / did-you-mean
├── docs/
│   └── tanzu-integration.md
└── .github/
    └── workflows/
        └── ci.yml
```

---

## Status and roadmap

v0.2. Production-ready for single-user workstations. Full design doc and
roadmap in [`docs/roadmap.md`](docs/roadmap.md). Pending items include:

- fzf-based picker (`cfctx pick`)
- `cfctx lock <name>` read-only safety rail (prompts on destructive ops)
- direnv bridge (`cfctx direnv`)
- Homebrew tap / formula
- Windows PowerShell port

---

## License

Apache-2.0. See `LICENSE`.

# Tanzu integration — creds in `context.env`

This doc covers the piece most Tanzu operators care about: getting `om`,
`bosh`, and `credhub` to Just Work when you switch contexts, without
re-running `eval "$(om ...)"` in every new terminal.

## The shape of the file

Each context can carry a `context.env` at
`$CFCTX_ROOT/<name>/context.env`. It's a plain shell file sourced by
`cfctx <name>` after `CF_HOME` is set. Mode is `0600`; `cfctx` refuses
to source it otherwise.

```bash
cfctx init-env tdc     # stamps a template
cfctx edit tdc         # opens $EDITOR on the file
cfctx tdc              # switches in this shell → sources the env file
```

## Seeding from your existing `om` env files

If you already drive `om` with env files (`om -e tdc.yml staged-products`),
cfctx can read them directly:

```bash
# Explicit path:
cfctx init-env tdc --from-om ~/env/tdc.yml

# Or point CFCTX_OM_ENV_DIR at the directory once, and auto-discover by name:
export CFCTX_OM_ENV_DIR="$HOME/env"     # add to ~/.zshrc
cfctx init-env tdc                      # picks up $HOME/env/tdc.yml
cfctx init-env cdc                      # picks up $HOME/env/cdc.yml
```

What happens:

- Flat `key: value` lines map to `OM_*` exports (see README for the full table).
- A block-scalar `ca-cert: |` gets extracted to
  `$CFCTX_ROOT/<name>/om-ca.pem` (mode `0600`), and the env file gets
  `export OM_CA_CERT="$(cat $CF_HOME/om-ca.pem)"`. This keeps the context
  env file human-readable and keeps the cert in a separate inspectable file.
- Unknown keys are preserved as comments (`# (unmapped om key: foo: bar)`)
  so nothing is silently dropped.
- BOSH / CredHub sections stay commented out — fill them in with `cfctx
  edit <name>` after import.

Overwrite an already-stamped env file with `--force` (refuses otherwise).

## Do I need CF_USERNAME / CF_PASSWORD?

**No.** The CF CLI authenticates via OAuth tokens stored in
`$CF_HOME/.cf/config.json` — and cfctx has already isolated that directory
per context. So once you `cf login` while switched into `tdc`, returning to
`tdc` later picks up the cached tokens; no re-login.

`CF_USERNAME` / `CF_PASSWORD` are only useful if *you* write shell scripts
that automate `cf login -u "$CF_USERNAME" -p "$CF_PASSWORD"`. Contrast:

| Tool | Token cache | Needs creds in env every call? |
|---|---|---|
| `cf` | `$CF_HOME/.cf/config.json` | no — tokens cached |
| `om` | none | **yes** — every call re-auths |
| `bosh` | refresh token cached briefly, but client/secret still needed | **yes** |
| `credhub` | none | **yes** |

That's why `OM_*`/`BOSH_*`/`CREDHUB_*` are the stars of `context.env`.

## Full example for a TDC-style foundation

```bash
# ~/.cf-homes/tdc/context.env   (mode 0600)

# CF ------------------------------------------------------------------------
export CF_API="https://api.sys.tas-prod.example.com"
export CF_ORG="system"
export CF_SPACE="system"

# Ops Manager --------------------------------------------------------------
export OM_TARGET="https://opsmgr.tas-prod.example.com"
export OM_USERNAME="admin"
export OM_PASSWORD="$(security find-generic-password -s om-tdc -w)"
export OM_SKIP_SSL_VALIDATION="true"

# BOSH ---------------------------------------------------------------------
export BOSH_ENVIRONMENT="10.0.0.10"
export BOSH_CLIENT="ops_manager"
export BOSH_CLIENT_SECRET="$(pass show tanzu/tdc/bosh-client-secret)"
export BOSH_CA_CERT="$(cat ~/.cf-homes/tdc/bosh-ca.pem)"
export BOSH_GW_HOST="10.0.0.11"
export BOSH_GW_USER="jumpbox"
export BOSH_GW_PRIVATE_KEY="$HOME/.ssh/jumpbox_tdc"

# CredHub ------------------------------------------------------------------
export CREDHUB_SERVER="https://credhub.tas-prod.example.com:8844"
export CREDHUB_CLIENT="credhub_admin_client"
export CREDHUB_SECRET="$(pass show tanzu/tdc/credhub)"
```

## Don't store plaintext if you have a vault

The file has mode `0600` in `$HOME`, which is the same posture as your
SSH private keys. For most operators that's fine. If you have stricter
posture or your laptop is shared, shell out to a secret manager from
the env file itself — the above example uses macOS Keychain (`security
find-generic-password`) and `pass`. Other options:

- 1Password CLI:    `export OM_PASSWORD="$(op read 'op://Private/om-tdc/credential')"`
- CredHub itself:   `export BOSH_CLIENT_SECRET="$(credhub get -n /bosh/client_secret -q)"`
- Bitwarden CLI:    `export OM_PASSWORD="$(bw get password 'om-tdc')"`
- AWS SSM:          `export BOSH_CLIENT_SECRET="$(aws ssm get-parameter --name /tdc/bosh --with-decryption --query Parameter.Value --output text)"`

These run every time you `cfctx <name>`, which gives you auto-refresh
of short-lived secrets at switch time.

## Inspecting without leaking

```bash
cfctx env tdc
```

Prints the env file with anything matching `PASSWORD|SECRET|TOKEN|KEY|
CA_CERT|PRIVATE` masked as `s***` so you can share output without
leaking creds. Comments and non-secret keys (like `OM_USERNAME`,
`BOSH_ENVIRONMENT`) come through unchanged.

## Gotcha: refreshing `om bosh-env` output

Today, a common workflow is:

```bash
eval "$(om -e tdc -k bosh-env)"
bosh vms
```

This exports fresh `BOSH_*` vars into your current shell from Ops
Manager. The values change when certs rotate or the director address
moves. A planned `cfctx bosh-env` subcommand (spec v0.4) will run `om
bosh-env` and *persist* its output into the context's `context.env`,
so subsequent `cfctx tdc` in new shells picks up the latest values
automatically.

Until that ships, the manual pattern is:

```bash
cfctx tdc                               # sources OM_* creds
om bosh-env >> ~/.cf-homes/tdc/context.env
cfctx tdc                               # re-source
```

The `om bosh-env` output is already formatted as `export FOO=bar`
lines, so it concatenates cleanly.

## Never commit `context.env`

The repo ships a `.gitignore` that excludes `*.env`, `context.env`, and
`.cf-homes/`. Even so — never point `CFCTX_ROOT` at a path inside a
git repo, and never `cp ~/.cf-homes/tdc/context.env` into a repo tree
for "just a quick check". The template lives at
`examples/context.env.example`; share that instead.

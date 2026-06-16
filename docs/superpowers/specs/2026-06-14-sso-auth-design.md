# cfctx SSO support — design

**Status:** approved (design phase) · **Date:** 2026-06-14 · **Branch:** `sso-auth`

## 1. Problem

We are rolling out SSO (external IdP via SAML/OIDC behind UAA) across every foundation,
at **both** the Ops Manager layer and the Cloud Foundry layer. cfctx's current auth model
assumes password authentication:

- `_cfctx_enrich_from_om` (`cfctx.sh:918`) scrapes the CF admin user/password out of
  Ops Manager (`.uaa.admin_credentials`, ~`cfctx.sh:1010`) and writes
  `CF_USERNAME`/`CF_PASSWORD` into `context.env`.
- `_cfctx_auto_login` (`cfctx.sh:1193`) logs in with `cf auth "$user" "$pass"`
  (`cfctx.sh:1252`) — password-only.

When a foundation's UAA is backed by an external IdP, there is no local admin password to
scrape, and `cf auth user pass` is the wrong flow. cfctx must keep working — seamlessly for
**humans** and deterministically for **heavy automation accounts / agents** — across the SSO
rollout, without storing human passwords on disk.

## 2. Goals / Non-goals

**Goals**
- One context serves both a human (interactive, browser/passcode SSO) and automation
  (non-interactive, UAA client-credentials), with the right flow chosen automatically by
  *who is driving*.
- No human passwords written to disk for SSO foundations.
- Preserve cfctx's sub-second switch promise: no network probe on the hot switch path.
- Preserve the public command surface and muscle memory; additive changes only.
- OpsMan/BOSH ride on **existing, externally-provisioned** UAA service clients — cfctx does
  no UAA admin / client provisioning.

**Non-goals**
- cfctx does not create, rotate, or manage UAA clients or IdP configuration. Those are
  provisioned out-of-band (Terraform / ops-manager config). cfctx only *consumes* them.
- No interactive SSO flow for `om`/`bosh` (they have no native `--sso` passcode). Humans use
  the OpsMan web UI; cfctx uses the service client for the CLIs.
- No change to where tokens are cached (`$CF_HOME/.cf/config.json`).

## 3. Approach (chosen)

A blend of two earlier options:

- **A — declarative per-context auth profile + actor-aware dispatcher** (seamless humans).
- **C — first-class, explicit, deterministic client-credentials path** (CI / service
  accounts / agents).

A context carries an explicit auth mode and the credentials for each supported flow. At
login time a dispatcher picks the flow from `(stored mode) × (human vs automation)`. SSO
capability is detected **once** at enrich time and cached, so the switch path stays fast.

## 4. Design

### 4.1 Per-context auth profile (`context.env` additions)

| Key | Meaning |
|---|---|
| `CF_AUTH_MODE` | `auto` (default) \| `sso` \| `client` \| `password` |
| `CF_UAA_CLIENT_ID` | CF UAA *service client* id (automation identity) |
| `CF_UAA_CLIENT_SECRET` | service client secret (0600, masked) |
| `CF_SSO_CAPABLE` | `0`/`1`, seeded once at enrich time |

OpsMan/BOSH reuse existing keys unchanged: `OM_CLIENT_ID`/`OM_CLIENT_SECRET`,
`BOSH_CLIENT`/`BOSH_CLIENT_SECRET`. Under SSO these are the **only** om/bosh path.

`CF_UAA_CLIENT_*` is deliberately distinct from `UAA_ADMIN_CLIENT*` (admin client used by
`cfctx uaa-login`) and from human `CF_USERNAME`/`CF_PASSWORD`.

### 4.2 Actor detection — `_cfctx_actor()`

Returns `automation` when **any** of:
- not a TTY: `! [ -t 0 ]`
- `CFCTX_NONINTERACTIVE=1`
- `CI` is set (non-empty)
- invoked through `bin/cfctx-env`
- `CF_AUTH_MODE=client` (pin)

Otherwise `human`. This is the hinge that lets a single context serve people and agents.

### 4.3 Login dispatcher (front-door on `_cfctx_auto_login`)

Compute effective mode, then dispatch. The existing token-cache / JWT-exp check
(`cfctx.sh:1209-1226`) runs **first** and short-circuits all flows when a valid token is
cached — both flows write the same `config.json`, so downstream `cf` calls are identical
regardless of how the token was obtained.

| Effective mode | Flow |
|---|---|
| `client` | `cf auth "$CF_UAA_CLIENT_ID" "$CF_UAA_CLIENT_SECRET" --client-credentials` — never prompts |
| `sso` | print clickable `<UAA>/passcode` URL (reuse OSC8 helper `_cfctx_osc8_link`), then run `cf login --sso` and let cf take the code |
| `password` | today's `cf auth "$user" "$pass"` (back-compat) |
| `auto` | resolve: `automation` **and** `CF_UAA_CLIENT_ID` set → `client`; else `CF_SSO_CAPABLE=1` → `sso`; else `password` |

`CF_ORG`/`CF_SPACE` re-targeting after login is unchanged (`cfctx.sh:1259-1274`).

Failure handling: each flow reports a specific, actionable error to stderr and returns 0
(non-fatal, matching current `_cfctx_auto_login` behavior) — a switch must never hard-fail
the shell. `sso` mode under an `automation` actor with no client is an explicit error
("context N is SSO-only; run `cfctx sso N` from a terminal, or set CF_UAA_CLIENT_ID"), not a
hang.

### 4.4 Enrich changes (`_cfctx_enrich_from_om`)

- Skip scraping `.uaa.admin_credentials` (CF admin user/password) when a CF service client is
  configured **or** `CF_AUTH_MODE` ∈ {`sso`,`client`}. No human password on disk for SSO
  foundations.
- Seed `CF_SSO_CAPABLE` once: probe `GET $UAA_URL/login` with `Accept: application/json`; if
  the response advertises external IdP providers (SAML/OIDC links/prompts), set `1`, else `0`.
  This is the **only** network probe, and it happens at enrich time, never on switch.
- Do not clobber `OM_CLIENT_ID`/`OM_CLIENT_SECRET` with username/password when the client
  variant is present.

### 4.5 Subcommands

- `cfctx auth <name> [auto|sso|client|password]` — show (no arg) or set a context's mode.
- `cfctx sso [<name>]` — force the human passcode login **now**, regardless of stored mode.
  (Explicit verb for: an automation/agent context whose human owner needs to act as
  themselves.)
- `cfctx uaa-login [--om]` — unchanged (`cfctx.sh:1918`).

### 4.6 Agent / CI path (`bin/cfctx-env`)

Stays stateless. Two additions:
- Emit `CF_AUTH_MODE` and `CF_UAA_CLIENT_*` alongside the existing CF_*/OM_*/BOSH_*/CREDHUB_*
  exports.
- `cfctx-env --login <foundation>` — perform a **headless client_credentials** `cf auth` to
  refresh an expired token. Never prompts for a passcode. If the context is not
  client-capable, error clearly and exit non-zero (agents fall back to "run `cfctx <f>`
  interactively"). This lets agents/CI self-heal an expired token without a human.

### 4.7 Secrets & masking

- New `*_CLIENT_SECRET` keys stored in `context.env` at mode 0600 like existing secrets.
- Extend the existing `cfctx env` masking layer so `CF_UAA_CLIENT_SECRET` (and any
  `*_CLIENT_SECRET`) is redacted in display, per the standing rule never to surface raw
  secrets.
- Keychain / `pass` indirection remains the documented opt-in (roadmap §v0.4), not in scope
  here.

### 4.8 Doctor (`_cfctx_cmd_doctor`)

Add SSO checks:
- `CF_AUTH_MODE=client` but `CF_UAA_CLIENT_ID`/`SECRET` missing.
- `CF_SSO_CAPABLE=1` but a legacy `CF_PASSWORD` is still present (suggest removing it).
- om/bosh client absent on an SSO-capable foundation.

## 5. Testing

All tests use `cf`/`uaac` stubs on `PATH`; **no real network**, matching
`tests/autologin.bats` and `tests/uaa.bats`.

- `tests/auth-mode.bats` — `cfctx auth` get/set; dispatcher resolution of `auto` for
  human vs automation (drive via `CFCTX_NONINTERACTIVE` / faked non-TTY).
- `tests/sso.bats` — `sso` flow: passcode URL construction, `cf login --sso` invocation
  shape; `cfctx sso` force-login regardless of mode.
- extend client-credentials coverage: `cf auth ... --client-credentials` invocation shape;
  `cfctx-env --login` headless path and its clear error when not client-capable.

CI matrix (bash 3.2 / bash 5 / zsh) unchanged.

## 6. Backward compatibility

- Default `CF_AUTH_MODE=auto`; existing password foundations with no client and
  `CF_SSO_CAPABLE` unset/`0` resolve to `password` — identical to today.
- No renamed/removed commands or env keys. Purely additive.

## 7. Open items (resolved in design)

- **`auto` precedence:** automation+client → client; else SSO-capable → sso; else password.
  (Automation prefers the deterministic client even on SSO-capable foundations.)
- **`cfctx-env --login` exists:** yes — bounded to client_credentials only, so it can never
  block an agent on an interactive prompt.

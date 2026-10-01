# Workspace credential execution

`cfctx-run` is a companion to the existing shell context switcher. It retrieves
one workspace profile, validates it against a reviewed descriptor, authenticates
in isolated state, and launches a command. It does not modify an interactive
cfctx context or import credentials from Ops Manager.

Build from this reviewed checkout with Go 1.23 or newer:

```bash
go build -trimpath -o build/cfctx-run ./cmd/cfctx-run
```

Put the reviewed binary on the agent's PATH through its normal managed tool
installation. The existing `install.sh` continues to install only the sourced
shell function. Hosted packaging should pin the helper binary checksum.

## Descriptor and profile

The non-secret descriptor is supplied by trusted workspace provisioning. Review
its exact targets before using it. Example CF-only descriptor (replace all
placeholders with the portal's actual GUIDs):

```json
{
  "version": 1,
  "workspace": "my-workspace",
  "foundation": "cdc",
  "capability": "deploy",
  "namespace": "/kuhn-labs/ws/my-workspace/contexts/cdc/deploy",
  "targets": {
    "cf": {
      "api": "https://api.example.invalid",
      "orgGuid": "11111111-1111-1111-1111-111111111111",
      "spaceGuid": "22222222-2222-2222-2222-222222222222"
    }
  },
  "credentialFields": ["CF_USERNAME", "CF_PASSWORD"],
  "portalContext": "cdc"
}
```

Store a `json` secret at `<namespace>/config` through the portal's existing
workspace secrets view or `klportal secret set` via stdin. The profile has the
same `version`, `workspace`, `foundation`, `capability` and `targets`, plus a
`credentials` object whose only keys are `CF_USERNAME` and `CF_PASSWORD`.
Use a portal-managed UAA user with the actual workspace CF roles, not an admin.
Do not include descriptor-only keys in the profile. Never commit the profile,
echo it to the terminal or put the value in a command argument.

A combined CF/BOSH profile additionally has `targets.bosh` with `endpoint`
(HTTPS), `directorUuid`, and `team`. Both descriptor and profile must match.
Add `BOSH_CLIENT`, `BOSH_CLIENT_SECRET`, `BOSH_CA_CERT` to `credentialFields`
and the profile credentials. The client must have the approved BOSH team role;
this helper verifies director identity but does not interpret token scopes or
reduce the client's authority. Team admin also allows team-scoped deletion,
lifecycle, SSH, logs and errands. Artifacts must already be uploaded unless
separate upload authority is approved.

## Mac portal provider

Sign into the reviewed portal CLI context using `klportal --ctx cdc auth login`
(the portal's existing device SSO flow). Run:

```bash
cfctx-run --provider portal --workspace my-workspace --foundation cdc \
  --capability deploy --descriptor /path/to/descriptor.json -- cf apps
```

The helper captures `klportal --json secret get` internally and discards raw
provider errors. It clears the `KLPORTAL_TOKEN` environment override so this
path uses the configured human SSO context and CLI refresh behavior. It does
not add a new token store or Mac Keychain integration.

## Hosted MCP provider

Provision a scoped caller-mode CredHub MCP backend and brokered OAuth helper.
At process startup, the buildpack must supply the actual ephemeral loopback URL
as descriptor `mcpEndpoint`, e.g. `http://127.0.0.1:PORT/mcp`. The URL must match
the bound helper, not an arbitrary HTTP listener. Use the same invocation with
`--provider mcp`. Only literal loopback HTTP `/mcp` endpoints are accepted;
proxy environment settings and redirects are disabled for helper traffic.
The helper performs MCP initialize/initialized and `secret_get` without making
the value a model-visible tool response. Stateless JSON and session/SSE are
supported. Stale cached values and MCP errors are refused.

## Isolation and limits

Each invocation reloads credentials. Duplicate/unknown JSON keys, mismatched
selectors, endpoints or GUIDs, unknown credential fields, and NUL values fail
closed. Passwords may contain shell characters: they remain literal environment
values and are never sourced or evaluated.

The helper removes inherited CF/BOSH/OM/UAA/CredHub/CFCTX/portal environment
variables and `VCAP_SERVICES` before platform setup. It creates a private
temporary `CF_HOME` and BOSH config; CF login uses environment credentials,
checks CAPI org/space relationships and the resulting exact CLI configuration,
and refuses TLS-validation bypass. BOSH `/info` must match the director UUID.
Every configured target is checked before the child starts, even if the child
uses only one CLI. Setup output and failure bodies are discarded. The CF
password is removed before starting the child, which uses its isolated token.
BOSH needs its scoped client secret in the child environment.

Normal completion and handled SIGINT/SIGTERM remove the temporary token state.
A forced SIGKILL, host crash or disk failure cannot guarantee cleanup; operating
system temporary-storage protection and expiry are still required. Child stdout
and stderr pass through unchanged, so an explicitly requested command can still
print its credentials. Agents with arbitrary shell/filesystem access can read
credentials granted to them or modify a descriptor they own. Target-side roles
and CredHub ACLs are the authorization boundaries; this helper is not a sandbox.

Exit status follows the child (130 on cancellation). Profile/provider/setup
failure prevents execution and returns a sanitized error. Rotation takes effect
on the next invocation; running commands and already copied secrets require
separate target-side revocation.

## Verification

```bash
go test ./...
bats tests/
```

The Go integration fixtures exercise real subprocess/env/state handling and
loopback MCP protocol. They prove local behavior, not CDC permissions, portal
SSO or a deployed broker; those require the separate live acceptance run.

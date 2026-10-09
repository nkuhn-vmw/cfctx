# Workspace credential execution

`cfctx-run` is a companion to the existing shell context switcher. It retrieves
one workspace profile, validates it against a reviewed descriptor, authenticates
in isolated state, and launches a command. It does not modify an interactive
cfctx context or import credentials from Ops Manager.

Development builds require at least Go 1.27.2; the module retains the Go 1.23 language level. Release builds select exactly Go 1.27.2:

```bash
GOTOOLCHAIN=go1.27.2 go build -trimpath -o build/cfctx-run ./cmd/cfctx-run
```

For a release candidate, run `scripts/release-workspace-helper.sh vX.Y.Z`. The release script selects and verifies the exact pinned toolchain, rather than inheriting an older Go binary from PATH. The build machine needs that toolchain cached or network access to download it.
It produces Linux and macOS amd64/arm64 binaries plus `checksums.json` and
`release.json` in `build/workspace-helper/`. The release metadata records the
source commit and Go version; verify each binary with the listed SHA-256 before
pinning it in a consumer. `cfctx-run --version` prints the embedded version.

Put the reviewed binary on the agent's PATH through its normal managed tool
installation. The existing `install.sh` continues to install only the sourced
shell function. Hosted packaging should pin the helper binary checksum.

## Descriptor and profile

The non-secret descriptor is supplied by trusted workspace provisioning. Review
its exact targets before using it. Example CF-only descriptor (replace all
placeholders with the provisioned workspace's actual values):

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
  "credentialFields": ["CF_USERNAME", "CF_PASSWORD"]
}
```

The hosted MCP provider retrieves the `json` secret at `<namespace>/config`.
The profile has the same `version`, `workspace`, `foundation`, `capability` and
`targets`, plus a `credentials` object whose only keys are `CF_USERNAME` and
`CF_PASSWORD`. Do not include descriptor-only keys in the profile. Never
commit the profile, echo it to the terminal or put the value in a command
argument.

A combined CF/BOSH profile additionally has `targets.bosh` with `endpoint`
(HTTPS), `directorUuid`, and `team`. Both descriptor and profile must match.
Add `BOSH_CLIENT`, `BOSH_CLIENT_SECRET`, `BOSH_CA_CERT` to `credentialFields`
and the profile credentials. The client must have the approved BOSH team role;
this helper verifies director identity but does not interpret token scopes or
reduce the client's authority. Team admin also allows team-scoped deletion,
lifecycle, SSH, logs and errands. Artifacts must already be uploaded unless
separate upload authority is approved.

## Hosted MCP provider

Provision a scoped caller-mode CredHub MCP backend and brokered OAuth helper.
At process startup, the buildpack must supply the actual ephemeral loopback URL
as descriptor `mcpEndpoint`, e.g. `http://127.0.0.1:PORT/mcp`. The URL must match
the bound helper, not an arbitrary HTTP listener. Only literal loopback HTTP
`/mcp` endpoints are accepted; proxy environment settings and redirects are
disabled for helper traffic. Invoke it with the reviewed descriptor:

```bash
cfctx-run --provider mcp --workspace my-workspace --foundation cdc \
  --capability deploy --descriptor /path/to/descriptor.json -- cf apps
```

The helper performs MCP initialize/initialized and `secret_get` without making
the value a model-visible tool response. Stateless JSON and session/SSE are
supported. Stale cached values and MCP errors are refused.

## Producer-supplied CF request v1

`cfctx-run` also accepts the additive generic CF request contract. Check support
before retrieving credentials:

```bash
cfctx-run --contract
# {"schemas":["cfctx.run.request/v1"],"requestMaxBytes":65536,"terminalStdin":"eof"}
```

The producer sends exactly one `cfctx.run.request/v1` JSON object through an
anonymous pipe on file descriptor 3, then closes the pipe. It launches the
runner concurrently with writing the request so the 64 KiB limit cannot fill
the pipe before the runner starts reading. Credentials never belong in argv,
shell text, logs or a request file. For example, when a trusted producer writes
the complete request to stdout:

```bash
cfctx-run --request-fd 3 -- cf apps 3< <(request-producer)
```

The request contains only `schema`, `targets.cf.{api,orgGuid,spaceGuid}`, and
`credentials.{CF_USERNAME,CF_PASSWORD}`. The runner verifies the HTTPS API,
org and space GUID relationship, and the resulting TLS-enabled CF CLI target
before launching the command. It accepts only fd 3, reads at most 65,536 bytes,
and times out after 30 seconds if the producer does not close the pipe. This
mode is CF-only; descriptor-backed MCP invocations remain available while
consumers migrate to request v1.

## Isolation and limits

Each invocation reloads credentials. Duplicate/unknown JSON keys, mismatched
selectors, endpoints or GUIDs, unknown credential fields, and NUL values fail
closed. Passwords may contain shell characters: they remain literal environment
values and are never sourced or evaluated.

The helper removes inherited CF/BOSH/OM/UAA/CredHub/CFCTX/KLPORTAL environment
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
This provider is for noninteractive deployment commands, such as `cf apps`,
`cf push`, and `bosh -n deploy`. When stdin is a terminal, the child receives
EOF so it cannot wait on an interactive prompt or change the caller's job
control. Piped stdin is passed through. The helper does not support interactive
SSH or terminal job control; cancellation kills the isolated child process
group, including its descendants.
The child's home directory stays unchanged. Isolation covers CF/BOSH token
state and the listed environment variables; it does not isolate existing
`om`, `credhub`, `uaac` or Kubernetes files in the user's home directory.

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
loopback MCP protocol. They prove local behavior, not foundation permissions
or a deployed broker; those require a separate live acceptance run.

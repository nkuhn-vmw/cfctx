# cfctx — Design Doc & Roadmap

*Original design brief, preserved for the "why" and the plan through v1.0.*
*Current implementation lives in `cfctx.sh`; see `README.md` for usage.*

**Status:** v0.2 (implemented). Many v0.3+ items still pending — see below.
**Target:** Production-quality tool installable via Homebrew, with tests, CI, and Tanzu integration extensions.
**Primary users:** Platform engineers working across multiple Cloud Foundry / Tanzu foundations (dev / lab / staging / prod / customer environments) from a single workstation.

---

## 1. Background & Problem

The CF CLI stores its entire target state — API endpoint, org, space, auth tokens, refresh tokens, feature flags — in a single config file at `$CF_HOME/.cf/config.json`. `CF_HOME` defaults to `$HOME`, so every shell on the workstation shares one global config.

This creates three recurring pain points for operators managing multiple foundations:

1. **Cross-terminal stomping.** Running `cf target -o X` in one terminal silently reconfigures every other open terminal. Engineers lose their place mid-operation, or worse, run destructive commands against the wrong foundation.
2. **Re-login churn.** Switching contexts means re-authenticating to the original foundation on return, even though valid tokens exist.
3. **Scripted risk.** Background scripts (CI agents, CF Weekly demo automations, BOSH errands) inherit whatever global CF target was last set interactively, making their behavior non-deterministic.

The CF CLI already supports isolation via the `CF_HOME` environment variable — each shell with a distinct `CF_HOME` has a fully independent target. `cfctx` wraps this primitive in an ergonomic shell function so operators can switch contexts with one command and maintain per-shell isolation without thinking about it.

## 2. Goals & Non-Goals

**Goals**
- Provide a single command (`cfctx <name>`) that switches the current shell to a named, isolated CF CLI context.
- Guarantee that contexts never leak across shells — each terminal's state is independent.
- Stay dependency-free: pure POSIX-ish shell, runs on stock macOS and Linux with bash or zsh.
- Ship as an installable tool (Homebrew tap, curl-pipe installer) with versioning and upgrade path.
- Extend cleanly to related Tanzu tooling (`om`, BOSH, CredHub) that suffers from the same global-state problem.

**Non-goals**
- We are not replacing the CF CLI or wrapping its commands. `cfctx` only manages `CF_HOME`; `cf` itself is unchanged.
- We are not storing credentials. Tokens remain wherever the CF CLI puts them, under whichever `CF_HOME` is active.
- We are not syncing contexts across machines. Contexts are local to the workstation.
- We are not managing Kubernetes contexts (`kubectl`, `kubens`) — that space is already well-served by `kubectx`.

## 3. Current Implementation (v0.1)

The prototype is a single sourced shell function in `cfctx.sh`. Install by appending `source ~/.cfctx.sh` to `~/.zshrc` or `~/.bashrc`.

Contexts live under `$CFCTX_ROOT` (default `~/.cf-homes/`), one directory per context. The function sets `CF_HOME` to the selected context directory; the CF CLI writes its config into `$CF_HOME/.cf/` as normal.

Supported subcommands today: `<name>` (switch/create), no-args status, `ls`, `rm <name>`, `clear`, `help`. The switcher autocreates missing context directories, prints current `cf target` output on switch, and has optional zsh tab completion for context names.

The file also ships a commented-out zsh `PROMPT` snippet that surfaces the active context in the shell prompt.

## 4. Architecture

The design rests on three facts about the CF CLI:

- `CF_HOME` is read on every `cf` invocation; it is not cached.
- All mutable state (config, plugins under `CF_PLUGIN_HOME` if separately set, downloaded CLI metadata) lives under `$CF_HOME/.cf/`.
- Environment variables set in a shell do not propagate to sibling shells.

Together these mean that setting `CF_HOME` per shell provides complete isolation with no coordination between shells and no locking. A context is just a directory; deleting it removes the context; copying it duplicates the context.

`cfctx` must be a **shell function**, not a standalone script, because scripts run in a subshell and cannot export variables back to the parent. This is an essential constraint and should be preserved in any rewrite.

## 5. Installation & Distribution Plan

v0.1 is manually sourced. The target distribution model:

**Primary: Homebrew tap.** Publish a tap (e.g. `<you>/tap`) with a formula that installs `cfctx.sh` and prints post-install instructions for adding the `source` line. Consider shipping shell-integration snippets the user can opt into (`cfctx init zsh` / `cfctx init bash`) that emit the correct source line for their shell.

**Secondary: curl-pipe installer.** A `install.sh` hosted on the repo that detects shell and rcfile, appends the source line with an idempotency check, and downloads the latest `cfctx.sh` to `~/.local/share/cfctx/`.

**Tertiary: manual.** Keep the "download one file and source it" path working forever; many enterprise environments block brew and curl-pipe.

## 6. Roadmap

### v0.2 — Hardening & Testing

Introduce a proper test suite using [bats-core](https://github.com/bats-core/bats-core). Test cases must cover: switching to a new context creates the directory; switching between two contexts does not leak `cf target` state; `rm` removes the directory and unsets `CF_HOME` if it matched; `clear` unsets only in the current shell; `ls` marks the current context with `*`. The suite should run in both bash 5.x and zsh.

Add a GitHub Actions workflow that runs the bats suite on `ubuntu-latest` and `macos-latest`, and a shellcheck pass on the source.

Add bash tab completion to match the existing zsh completion.

Address edge cases the prototype glosses over: context names containing `/`, spaces, or leading dashes; `CFCTX_ROOT` pointing at a non-writable location; the user's `CF_HOME` being set to something non-default before `cfctx` was first invoked (respect it, don't clobber).

### v0.3 — Ergonomics

Add `cfctx cp <src> <dst>` to duplicate a context (useful when onboarding a new foundation that shares auth infrastructure with an existing one).

Add `cfctx mv <old> <new>` to rename.

Add `cfctx login <name> <args...>` as a convenience that switches to the context and runs `cf login` with the remaining args in one step.

Add fzf-based picker: `cfctx pick` opens an fzf prompt over available contexts and switches to the selected one. Detect fzf availability at runtime; no hard dependency.

Add context metadata stored in `$CFCTX_ROOT/<name>/.cfctx-meta.json`: description, API URL, last-used timestamp. Surface in `ls` output.

### v0.4 — Tanzu Ecosystem Integration

This is the iteration that matters most for the primary user. Operators rarely use `cf` alone — they pair it with `om` (Ops Manager), `bosh`, and `credhub`, all of which have their own global-state problems. Extend the context concept to cover these tools.

Proposed design: each context directory grows a `context.env` file that exports tool-specific variables. On `cfctx <name>`, source that file after setting `CF_HOME`. The env file can carry `OM_TARGET`, `OM_USERNAME`, `OM_PASSWORD` (or better, `OM_CLIENT_ID` / `OM_CLIENT_SECRET`), `BOSH_ENVIRONMENT`, `BOSH_CLIENT`, `BOSH_CLIENT_SECRET`, `BOSH_CA_CERT`, `CREDHUB_SERVER`, etc.

Introduce `cfctx bosh-env` as a wrapper for `eval "$(om ... bosh-env)"` that writes the BOSH env vars into the current context's `context.env` so subsequent `cfctx <name>` switches pick them up automatically. This directly eliminates the workflow of re-running `eval "$(om ...)"` on every new terminal.

The env-file approach must handle secrets carefully: the files sit on disk under `~/.cf-homes/<name>/` with `0600` perms, and the docs should call out that users with stricter posture should store secrets in macOS Keychain / `pass` / CredHub and have `context.env` shell out to retrieve them.

### v0.5 — Safety Rails

Add a `cfctx lock` command that marks the current context read-only; subsequent `cf` commands that would mutate state (`delete-*`, `unbind-*`, `stop`, `restart`, `push` with certain flags) prompt for confirmation. Implement as a `cf` wrapper function that's optional and opt-in.

Add a prompt-indicator module (`cfctx init prompt`) that emits a ready-to-use prompt snippet for zsh, bash, and starship, color-coded by a per-context tag (e.g. red for `prod`, yellow for `staging`, green for `lab`). Color/tag stored in context metadata.

Add `cfctx doctor` to diagnose common problems: `CF_HOME` set but `cf` not installed; context directory exists but `config.json` is corrupt; `CFCTX_ROOT` on a non-standard path; shell integration not loaded.

### v0.6 — direnv Bridge

Ship `cfctx direnv` that emits a `.envrc` snippet:
```
use cfctx prod
```
backed by a direnv library function that internally calls `cfctx <name>` and exports `CF_HOME`. This gives operators the same auto-switching behavior direnv provides for other tools, without requiring them to hardcode `$HOME/.cf-homes/...` paths in every `.envrc`.

## 7. Testing Strategy

Unit-level shell tests via bats-core, organized by subcommand.

Integration tests that spin up a disposable `CFCTX_ROOT` in `$BATS_TMPDIR`, invoke `cfctx` through a subshell that sources the function, and assert on files created and environment mutations. Since environment mutations don't survive the subshell, the integration tests will need to use `eval` patterns or dump env to a file and inspect it — document the pattern in `tests/README.md`.

A smoke-test matrix in CI running against bash 3.2 (the macOS default for non-upgraded users), bash 5, and zsh 5.8+.

Intentionally out of scope: testing against a real CF API. The tool doesn't call `cf`; it only manages the directory `cf` reads from.

## 8. Open Questions

**Should we support a "global default" context?** Some users want `cfctx` to persist the last-used context across shell restarts (write to a state file, read on shell init). Others find this defeats the point of per-shell isolation. Proposal: leave it off by default, expose as `CFCTX_PERSIST=1` opt-in.

**Plugin isolation.** `CF_PLUGIN_HOME` defaults to `$CF_HOME/.cf/plugins`, so it follows automatically. But plugins themselves may hold their own global state (e.g. the `bosh-cli` plugin). Decide whether `cfctx` should try to isolate plugin state or punt.

**Windows support.** PowerShell equivalent (`cfctx.psm1`) is straightforward but doubles maintenance surface. Defer until there's a user asking for it.

**Naming conflict with `cf` subcommands.** If CF CLI ever ships a `cf ctx` subcommand, our tool name is still fine (different binary), but we should watch for this.

## 9. Repository Layout (target)

```
cfctx/
├── README.md
├── LICENSE                    # Apache-2.0
├── cfctx.sh                   # sourced shell function (the core)
├── install.sh                 # curl-pipe installer
├── completions/
│   ├── cfctx.zsh
│   └── cfctx.bash
├── tests/
│   ├── README.md
│   ├── bats/                  # vendored or submodule
│   ├── switch.bats
│   ├── ls.bats
│   ├── rm.bats
│   └── fixtures/
├── docs/
│   ├── installation.md
│   ├── tanzu-integration.md
│   └── prompt-integration.md
├── .github/
│   └── workflows/
│       └── ci.yml
└── Formula/                   # optional: in-repo Homebrew formula
    └── cfctx.rb
```

## 10. Success Criteria

The v1.0 release ships when:

- `brew install <you>/tap/cfctx` installs cleanly on macOS 13+.
- `cfctx init zsh >> ~/.zshrc` is the only setup step required.
- Bats suite passes on bash 5 + zsh 5.8+, macOS + Ubuntu.
- `cfctx bosh-env` eliminates the `eval "$(om ... bosh-env)"` workflow for the primary user.
- At least three operators have used it for one full week across ≥3 foundations and report zero cross-terminal target-clobber incidents.

## 11. Appendix: v0.1 Source

The current prototype is `cfctx.sh`, ~85 lines of shell. It implements the switch / ls / rm / clear / status / help subcommands, optional zsh completion, and a commented prompt snippet. It is the starting point for all roadmap work above; preserve its public surface (subcommand names and arguments) across refactors so users' muscle memory carries forward.

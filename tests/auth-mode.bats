#!/usr/bin/env bats
# Actor detection + CF auth-mode resolution (pure, no network).
#
# TTY note: under bats, stdin is never a TTY, so _cfctx_actor's
# `! [ -t 0 ]` branch is always true — meaning _cfctx_actor returns
# "automation" by default regardless of which env vars are set.
# The actor-trigger tests below confirm the function returns "automation"
# (still a valid assertion, but all paths converge here in bats).
# The resolver tests use CFCTX_FORCE_ACTOR to pin the actor explicitly
# and carry the real branch coverage for _cfctx_resolve_cf_auth_mode.

setup() {
    export CFCTX_ROOT="$BATS_TEST_TMPDIR/cf-homes"
    mkdir -p "$CFCTX_ROOT"
    unset CF_AUTH_MODE CF_UAA_CLIENT_ID CF_UAA_CLIENT_SECRET CF_SSO_CAPABLE
    unset CFCTX_FORCE_ACTOR CFCTX_NONINTERACTIVE CI
    # shellcheck disable=SC1091
    source "$BATS_TEST_DIRNAME/../cfctx.sh"
}

@test "actor: CFCTX_NONINTERACTIVE → automation" {
    CFCTX_NONINTERACTIVE=1 run _cfctx_actor
    [ "$status" -eq 0 ]
    [ "$output" = "automation" ]
}

@test "actor: CI set → automation" {
    CI=1 run _cfctx_actor
    [ "$status" -eq 0 ]
    [ "$output" = "automation" ]
}

@test "actor: CF_AUTH_MODE=client implies automation" {
    CF_AUTH_MODE=client run _cfctx_actor
    [ "$status" -eq 0 ]
    [ "$output" = "automation" ]
}

@test "actor: CFCTX_FORCE_ACTOR overrides everything" {
    CFCTX_FORCE_ACTOR=human CFCTX_NONINTERACTIVE=1 run _cfctx_actor
    [ "$status" -eq 0 ]
    [ "$output" = "human" ]
}

@test "resolve: explicit sso passes through" {
    CF_AUTH_MODE=sso run _cfctx_resolve_cf_auth_mode
    [ "$status" -eq 0 ]; [ "$output" = "sso" ]
}

@test "resolve: explicit client passes through" {
    CF_AUTH_MODE=client run _cfctx_resolve_cf_auth_mode
    [ "$status" -eq 0 ]; [ "$output" = "client" ]
}

@test "resolve: explicit password passes through" {
    CF_AUTH_MODE=password run _cfctx_resolve_cf_auth_mode
    [ "$status" -eq 0 ]; [ "$output" = "password" ]
}

@test "resolve: auto + automation + client-id → client" {
    CFCTX_FORCE_ACTOR=automation CF_UAA_CLIENT_ID=bot \
        run _cfctx_resolve_cf_auth_mode
    [ "$status" -eq 0 ]
    [ "$output" = "client" ]
}

@test "resolve: auto + human + sso-capable → sso" {
    CFCTX_FORCE_ACTOR=human CF_SSO_CAPABLE=1 \
        run _cfctx_resolve_cf_auth_mode
    [ "$status" -eq 0 ]
    [ "$output" = "sso" ]
}

@test "resolve: auto + automation but no client-id, sso-capable → sso" {
    CFCTX_FORCE_ACTOR=automation CF_SSO_CAPABLE=1 \
        run _cfctx_resolve_cf_auth_mode
    [ "$status" -eq 0 ]
    [ "$output" = "sso" ]
}

@test "resolve: auto fallback → password" {
    CFCTX_FORCE_ACTOR=human run _cfctx_resolve_cf_auth_mode
    [ "$status" -eq 0 ]
    [ "$output" = "password" ]
}

@test "cfctx auth sets and shows CF_AUTH_MODE" {
    mkdir -p "$CFCTX_ROOT/tdc"; : > "$CFCTX_ROOT/tdc/context.env"; chmod 600 "$CFCTX_ROOT/tdc/context.env"
    run cfctx auth tdc client
    [ "$status" -eq 0 ]
    grep -q 'CF_AUTH_MODE="client"' "$CFCTX_ROOT/tdc/context.env"
    run cfctx auth tdc
    [[ "$output" == *"client"* ]]
}

@test "cfctx auth rejects an invalid mode" {
    mkdir -p "$CFCTX_ROOT/tdc"; : > "$CFCTX_ROOT/tdc/context.env"; chmod 600 "$CFCTX_ROOT/tdc/context.env"
    run cfctx auth tdc bogus
    [ "$status" -ne 0 ]
    [[ "$output" == *"invalid mode"* ]]
}

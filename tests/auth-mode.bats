#!/usr/bin/env bats
# Actor detection + CF auth-mode resolution (pure, no network).

setup() {
    export CFCTX_ROOT="$BATS_TEST_TMPDIR/cf-homes"
    mkdir -p "$CFCTX_ROOT"
    unset CF_AUTH_MODE CF_UAA_CLIENT_ID CF_UAA_CLIENT_SECRET CF_SSO_CAPABLE
    unset CFCTX_FORCE_ACTOR CFCTX_NONINTERACTIVE CI
    # shellcheck disable=SC1091
    source "$BATS_TEST_DIRNAME/../cfctx.sh"
}

@test "actor: CFCTX_NONINTERACTIVE forces automation" {
    run env CFCTX_NONINTERACTIVE=1 bash -c \
        'source "'"$BATS_TEST_DIRNAME"'/../cfctx.sh"; _cfctx_actor'
    [ "$output" = "automation" ]
}

@test "actor: CF_AUTH_MODE=client implies automation" {
    CF_AUTH_MODE=client run _cfctx_actor
    [ "$output" = "automation" ]
}

@test "actor: CFCTX_FORCE_ACTOR overrides everything" {
    CFCTX_FORCE_ACTOR=human CFCTX_NONINTERACTIVE=1 run _cfctx_actor
    [ "$output" = "human" ]
}

@test "resolve: explicit modes pass through unchanged" {
    CF_AUTH_MODE=sso      run _cfctx_resolve_cf_auth_mode; [ "$output" = "sso" ]
    CF_AUTH_MODE=client   run _cfctx_resolve_cf_auth_mode; [ "$output" = "client" ]
    CF_AUTH_MODE=password run _cfctx_resolve_cf_auth_mode; [ "$output" = "password" ]
}

@test "resolve: auto + automation + client-id → client" {
    CFCTX_FORCE_ACTOR=automation CF_UAA_CLIENT_ID=bot \
        run _cfctx_resolve_cf_auth_mode
    [ "$output" = "client" ]
}

@test "resolve: auto + human + sso-capable → sso" {
    CFCTX_FORCE_ACTOR=human CF_SSO_CAPABLE=1 \
        run _cfctx_resolve_cf_auth_mode
    [ "$output" = "sso" ]
}

@test "resolve: auto + automation but no client-id, sso-capable → sso" {
    CFCTX_FORCE_ACTOR=automation CF_SSO_CAPABLE=1 \
        run _cfctx_resolve_cf_auth_mode
    [ "$output" = "sso" ]
}

@test "resolve: auto fallback → password" {
    CFCTX_FORCE_ACTOR=human run _cfctx_resolve_cf_auth_mode
    [ "$output" = "password" ]
}

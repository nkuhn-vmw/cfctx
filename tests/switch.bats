#!/usr/bin/env bats
# Core switch / status / ls / clear behavior.

setup() {
    export CFCTX_ROOT="$BATS_TEST_TMPDIR/cf-homes"
    mkdir -p "$CFCTX_ROOT"
    # Make sure cf isn't in PATH so `cf target` doesn't try to run.
    export PATH="$BATS_TEST_TMPDIR/nocf:/usr/bin:/bin"
    mkdir -p "$BATS_TEST_TMPDIR/nocf"
    unset CF_HOME
    # shellcheck disable=SC1091
    source "$BATS_TEST_DIRNAME/../cfctx.sh"
}

@test "status with no context says so" {
    run cfctx status
    [ "$status" -eq 0 ]
    [[ "$output" == *"No context set in this shell"* ]]
}

@test "switch creates the context dir and exports CF_HOME" {
    cfctx tdc
    [ -d "$CFCTX_ROOT/tdc" ]
    [ "$CF_HOME" = "$CFCTX_ROOT/tdc" ]
}

@test "switching again is idempotent and does not duplicate state" {
    cfctx tdc
    cfctx tdc
    [ -d "$CFCTX_ROOT/tdc" ]
    # No stray siblings created
    count=$(ls -1 "$CFCTX_ROOT" | wc -l | tr -d ' ')
    [ "$count" = "1" ]
}

@test "switching between two contexts updates CF_HOME only" {
    cfctx alpha
    [ "$CF_HOME" = "$CFCTX_ROOT/alpha" ]
    cfctx beta
    [ "$CF_HOME" = "$CFCTX_ROOT/beta" ]
}

@test "ls marks the current context with *" {
    cfctx alpha
    cfctx beta
    run cfctx ls
    [ "$status" -eq 0 ]
    [[ "$output" == *"* beta"* ]]
    [[ "$output" == *"  alpha"* ]]
}

@test "clear unsets CF_HOME and Tanzu vars" {
    cfctx alpha
    export OM_PASSWORD="should-be-cleared"
    export BOSH_CLIENT_SECRET="also-cleared"
    cfctx clear
    [ -z "${CF_HOME:-}" ]
    [ -z "${OM_PASSWORD:-}" ]
    [ -z "${BOSH_CLIENT_SECRET:-}" ]
}

@test "rm refuses empty name" {
    run cfctx rm
    [ "$status" -ne 0 ]
}

@test "rm deletes the context and unsets CF_HOME when it matched" {
    cfctx toremove
    # pipe 'y' to answer the confirmation prompt
    run bash -c "source '$BATS_TEST_DIRNAME/../cfctx.sh'; export CFCTX_ROOT='$CFCTX_ROOT'; cfctx toremove >/dev/null; echo y | cfctx rm toremove"
    [ "$status" -eq 0 ]
    [ ! -d "$CFCTX_ROOT/toremove" ]
}

@test "invalid names are rejected" {
    run cfctx "-evil"
    [ "$status" -ne 0 ]
    run cfctx "has/slash"
    [ "$status" -ne 0 ]
    run cfctx "has space"
    [ "$status" -ne 0 ]
}

@test "cp duplicates a context" {
    cfctx alpha
    cfctx cp alpha beta
    [ -d "$CFCTX_ROOT/beta" ]
}

@test "mv renames a context and updates CF_HOME if active" {
    cfctx alpha
    cfctx mv alpha gamma
    [ ! -d "$CFCTX_ROOT/alpha" ]
    [ -d "$CFCTX_ROOT/gamma" ]
    [ "$CF_HOME" = "$CFCTX_ROOT/gamma" ]
}

@test "version prints something" {
    run cfctx version
    [ "$status" -eq 0 ]
    [[ "$output" == cfctx* ]]
}

#!/usr/bin/env bats
# `cfctx target` — adopt (init-env) + switch in one step.

setup() {
    export CFCTX_ROOT="$BATS_TEST_TMPDIR/cf-homes"
    mkdir -p "$CFCTX_ROOT"
    export PATH="$BATS_TEST_TMPDIR/nocf:/usr/bin:/bin"
    mkdir -p "$BATS_TEST_TMPDIR/nocf"
    unset CF_HOME OM_TARGET OM_USERNAME OM_PASSWORD
    # shellcheck disable=SC1091
    source "$BATS_TEST_DIRNAME/../cfctx.sh"
}

@test "target on a new context with no om yaml: stamps blank + switches" {
    cfctx target fresh
    [ -d "$CFCTX_ROOT/fresh" ]
    [ -f "$CFCTX_ROOT/fresh/context.env" ]
    [ "$CF_HOME" = "$CFCTX_ROOT/fresh" ]
}

@test "target auto-imports from CFCTX_OM_ENV_DIR and sources on switch" {
    local om_dir="$BATS_TEST_TMPDIR/om"
    mkdir -p "$om_dir"
    cat > "$om_dir/om-cli-tdc.yml" <<'EOF'
target: https://opsmgr.tdc.example.com
username: admin
password: p4ss
skip-ssl-validation: true
EOF

    CFCTX_OM_ENV_DIR="$om_dir" cfctx target tdc

    [ "$CF_HOME" = "$CFCTX_ROOT/tdc" ]
    [ "$OM_TARGET" = "https://opsmgr.tdc.example.com" ]
    [ "$OM_USERNAME" = "admin" ]
    [ "$OM_PASSWORD" = "p4ss" ]
}

@test "target is idempotent — second run just switches, doesn't re-stamp" {
    cfctx target foo
    local mtime1
    mtime1=$(stat -c '%Y' "$CFCTX_ROOT/foo/context.env" 2>/dev/null \
              || stat -f '%m' "$CFCTX_ROOT/foo/context.env" 2>/dev/null)
    sleep 1
    unset CF_HOME
    cfctx target foo
    local mtime2
    mtime2=$(stat -c '%Y' "$CFCTX_ROOT/foo/context.env" 2>/dev/null \
              || stat -f '%m' "$CFCTX_ROOT/foo/context.env" 2>/dev/null)
    [ "$mtime1" = "$mtime2" ]
    [ "$CF_HOME" = "$CFCTX_ROOT/foo" ]
}

@test "target --from-om on an existing context re-seeds (implies --force) and switches" {
    # First create a stub env file with known contents.
    cfctx target foo
    echo '# placeholder' > "$CFCTX_ROOT/foo/context.env"
    chmod 600 "$CFCTX_ROOT/foo/context.env"

    # Now re-target with a real om yaml
    local om_file="$BATS_TEST_TMPDIR/foo.yml"
    cat > "$om_file" <<'EOF'
target: https://opsmgr.new.example.com
username: bob
password: np
EOF

    run cfctx target foo --from-om "$om_file"
    [ "$status" -eq 0 ]
    grep -q 'OM_TARGET="https://opsmgr.new.example.com"' "$CFCTX_ROOT/foo/context.env"
    [ "$CF_HOME" = "$CFCTX_ROOT/foo" ]
}

@test "target --force re-seeds an existing context" {
    cfctx target foo
    # Mess up the file
    echo 'broken' > "$CFCTX_ROOT/foo/context.env"
    chmod 600 "$CFCTX_ROOT/foo/context.env"

    cfctx target foo --force
    # The force re-stamp should put the standard template back
    grep -q 'cfctx context: foo' "$CFCTX_ROOT/foo/context.env"
}

@test "target with an invalid name fails" {
    run cfctx target "bad name"
    [ "$status" -ne 0 ]
    run cfctx target
    [ "$status" -ne 0 ]
}

@test "target --help prints usage and returns 0" {
    run cfctx target --help
    [ "$status" -eq 0 ]
    [[ "$output" == *"Usage: cfctx"* ]]
    [[ "$output" == *"--from-om"* ]]
    [[ "$output" == *"--cf-api"* ]]
}

@test "adopt is an alias for target" {
    cfctx adopt tdc
    [ "$CF_HOME" = "$CFCTX_ROOT/tdc" ]
    [ -f "$CFCTX_ROOT/tdc/context.env" ]
}

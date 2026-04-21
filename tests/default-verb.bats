#!/usr/bin/env bats
# `cfctx` (no args) lists foundations; `cfctx <name>` = full target+login.

setup() {
    export CFCTX_ROOT="$BATS_TEST_TMPDIR/cf-homes"
    mkdir -p "$CFCTX_ROOT"
    export PATH="$BATS_TEST_TMPDIR/nocf:/usr/bin:/bin"
    mkdir -p "$BATS_TEST_TMPDIR/nocf"
    unset CF_HOME
    # shellcheck disable=SC1091
    source "$BATS_TEST_DIRNAME/../cfctx.sh"
}

@test "cfctx with no args and no contexts prints a hint" {
    run cfctx
    [ "$status" -eq 0 ]
    [[ "$output" == *"No contexts yet"* ]]
}

@test "cfctx with no args lists all contexts with current highlighted" {
    cfctx alpha
    cfctx beta
    run cfctx
    [ "$status" -eq 0 ]
    [[ "$output" == *"* beta"* ]]
    [[ "$output" == *"  alpha"* ]]
}

@test "cfctx with no args shows OM_TARGET / CF_API after each name" {
    mkdir -p "$CFCTX_ROOT/tdc"
    cat > "$CFCTX_ROOT/tdc/context.env" <<'EOF'
export OM_TARGET="https://opsmgr.tdc.example.com"
export CF_API="https://api.sys.tdc.example.com"
EOF
    chmod 600 "$CFCTX_ROOT/tdc/context.env"

    run cfctx
    [ "$status" -eq 0 ]
    # CF_API should be preferred over OM_TARGET when both are set
    [[ "$output" == *"api.sys.tdc.example.com"* ]]
    [[ "$output" == *"[env]"* ]]
}

@test "cfctx with no args falls back to OM_TARGET if CF_API unset" {
    mkdir -p "$CFCTX_ROOT/om-only"
    cat > "$CFCTX_ROOT/om-only/context.env" <<'EOF'
export OM_TARGET="https://opsmgr.only.example.com"
EOF
    chmod 600 "$CFCTX_ROOT/om-only/context.env"

    run cfctx
    [[ "$output" == *"opsmgr.only.example.com"* ]]
}

@test "cfctx status (explicit) still shows current-context details" {
    unset CF_HOME
    run cfctx status
    [ "$status" -eq 0 ]
    [[ "$output" == *"No context set in this shell"* ]]
}

@test "bare cfctx <name> now routes through target (stamps template + switches)" {
    # No CFCTX_OM_ENV_DIR, no om yaml — should still stamp a blank template.
    cfctx newfound
    [ -d "$CFCTX_ROOT/newfound" ]
    [ -f "$CFCTX_ROOT/newfound/context.env" ]
    [ "$CF_HOME" = "$CFCTX_ROOT/newfound" ]

    # Subsequent bare call is idempotent (doesn't re-stamp).
    local mtime1
    mtime1=$(stat -f '%m' "$CFCTX_ROOT/newfound/context.env" 2>/dev/null \
              || stat -c '%Y' "$CFCTX_ROOT/newfound/context.env")
    sleep 1
    cfctx newfound
    local mtime2
    mtime2=$(stat -f '%m' "$CFCTX_ROOT/newfound/context.env" 2>/dev/null \
              || stat -c '%Y' "$CFCTX_ROOT/newfound/context.env")
    [ "$mtime1" = "$mtime2" ]
}

@test "bare cfctx <name> --cf-api persists CF_API and invokes target path" {
    cfctx tdc --cf-api https://api.sys.example.com
    grep -q 'CF_API="https://api.sys.example.com"' "$CFCTX_ROOT/tdc/context.env"
    [ "$CF_HOME" = "$CFCTX_ROOT/tdc" ]
}

@test "bare cfctx <name> auto-imports from CFCTX_OM_ENV_DIR" {
    local om_dir="$BATS_TEST_TMPDIR/om-envs"
    mkdir -p "$om_dir"
    cat > "$om_dir/om-cli-tdc.yml" <<'EOF'
target: https://opsmgr.tdc.example.com
username: admin
password: bare-import
EOF

    CFCTX_OM_ENV_DIR="$om_dir" cfctx tdc
    [ "$OM_PASSWORD" = "bare-import" ]
}

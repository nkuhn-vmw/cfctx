#!/usr/bin/env bats
# cfctx-env: standalone script for non-interactive shells.

setup() {
    export CFCTX_ROOT="$BATS_TEST_TMPDIR/cf-homes"
    mkdir -p "$CFCTX_ROOT"
    CFCTX_ENV="$BATS_TEST_DIRNAME/../bin/cfctx-env"
}

@test "--help prints usage and exits 0" {
    run "$CFCTX_ENV" --help
    [ "$status" -eq 0 ]
    [[ "$output" == *"emit shell export lines"* ]]
}

@test "no args prints usage to stderr and exits non-zero" {
    run "$CFCTX_ENV"
    [ "$status" -ne 0 ]
}

@test "--list with no contexts exits 0 silently" {
    run "$CFCTX_ENV" --list
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

@test "--list prints sorted foundation names" {
    mkdir -p "$CFCTX_ROOT/tdc" "$CFCTX_ROOT/cdc" "$CFCTX_ROOT/ndc"
    run "$CFCTX_ENV" --list
    [ "$status" -eq 0 ]
    # Sorted: cdc, ndc, tdc
    expected="cdc
ndc
tdc"
    [ "$output" = "$expected" ]
}

@test "missing foundation: error exit + helpful 'available' hint" {
    mkdir -p "$CFCTX_ROOT/tdc"
    run "$CFCTX_ENV" ghost
    [ "$status" -ne 0 ]
    [[ "$output" == *"no context 'ghost'"* ]]
    [[ "$output" == *"available"* ]]
    [[ "$output" == *"tdc"* ]]
}

@test "always emits CF_HOME pointing at the context dir" {
    mkdir -p "$CFCTX_ROOT/tdc"
    run "$CFCTX_ENV" tdc
    [ "$status" -eq 0 ]
    [[ "$output" == *"export CF_HOME=$CFCTX_ROOT/tdc"* ]]
}

@test "emits all known cfctx vars from context.env" {
    mkdir -p "$CFCTX_ROOT/tdc"
    cat > "$CFCTX_ROOT/tdc/context.env" <<'EOF'
export CF_API="https://api.example.com"
export CF_USERNAME="admin"
export CF_PASSWORD="pw"
export CF_ORG="system"
export CF_SPACE="system"
export OM_TARGET="https://opsmgr.example.com"
export OM_USERNAME="admin"
export OM_PASSWORD="pw"
export BOSH_ENVIRONMENT="10.0.0.10"
export BOSH_CLIENT="ops_manager"
export BOSH_CLIENT_SECRET="secret"
EOF
    chmod 600 "$CFCTX_ROOT/tdc/context.env"

    run "$CFCTX_ENV" tdc
    [ "$status" -eq 0 ]
    [[ "$output" == *"export CF_API="* ]]
    [[ "$output" == *"export CF_USERNAME="* ]]
    [[ "$output" == *"export CF_PASSWORD="* ]]
    [[ "$output" == *"export OM_TARGET="* ]]
    [[ "$output" == *"export BOSH_ENVIRONMENT="* ]]
    [[ "$output" == *"export BOSH_CLIENT_SECRET="* ]]
}

@test "skips empty / unset vars" {
    mkdir -p "$CFCTX_ROOT/sparse"
    cat > "$CFCTX_ROOT/sparse/context.env" <<'EOF'
export CF_API="https://api.example.com"
EOF
    chmod 600 "$CFCTX_ROOT/sparse/context.env"

    run "$CFCTX_ENV" sparse
    [ "$status" -eq 0 ]
    [[ "$output" == *"CF_API"* ]]
    [[ "$output" != *"BOSH_"* ]]
    [[ "$output" != *"CREDHUB_"* ]]
    [[ "$output" != *"OM_USERNAME"* ]]
}

@test "shell-quotes special chars (\$, \", backslash, backtick)" {
    mkdir -p "$CFCTX_ROOT/special"
    # Build a context.env via printf so we control the literal content.
    printf 'export CF_PASSWORD=%q\n' 'p$w"d`n\back' > "$CFCTX_ROOT/special/context.env"
    chmod 600 "$CFCTX_ROOT/special/context.env"

    # Capture cfctx-env output, eval it, check the value round-trips.
    eval_out=$("$CFCTX_ENV" special)
    [ -n "$eval_out" ]

    # Now actually eval it in a subshell and verify the password matches.
    actual=$(bash -c "$eval_out"$'\n''printf "%s" "$CF_PASSWORD"')
    [ "$actual" = 'p$w"d`n\back' ]
}

@test "doesn't leak unrelated env vars" {
    mkdir -p "$CFCTX_ROOT/tdc"
    cat > "$CFCTX_ROOT/tdc/context.env" <<'EOF'
export CF_API="https://api.example.com"
export USER_HELPER_VAR="should-not-appear"
EOF
    chmod 600 "$CFCTX_ROOT/tdc/context.env"

    run "$CFCTX_ENV" tdc
    [ "$status" -eq 0 ]
    [[ "$output" == *"CF_API"* ]]
    [[ "$output" != *"USER_HELPER_VAR"* ]]
}

@test "rejects invalid foundation names" {
    run "$CFCTX_ENV" "has space"
    [ "$status" -ne 0 ]
    run "$CFCTX_ENV" "has/slash"
    [ "$status" -ne 0 ]
    run "$CFCTX_ENV" "-leadingdash"
    [ "$status" -ne 0 ]
}

@test "eval-roundtrip end-to-end: export then read back" {
    mkdir -p "$CFCTX_ROOT/tdc"
    cat > "$CFCTX_ROOT/tdc/context.env" <<'EOF'
export CF_API="https://api.example.com"
export CF_ORG="system"
export BOSH_ENVIRONMENT="10.0.0.10"
EOF
    chmod 600 "$CFCTX_ROOT/tdc/context.env"

    output=$(bash -c "
        unset CF_HOME CF_API CF_ORG BOSH_ENVIRONMENT
        eval \"\$(\"$CFCTX_ENV\" tdc)\"
        echo \"\$CF_HOME|\$CF_API|\$CF_ORG|\$BOSH_ENVIRONMENT\"
    ")
    [ "$output" = "$CFCTX_ROOT/tdc|https://api.example.com|system|10.0.0.10" ]
}

@test "cfctx-env forwards CF_AUTH_MODE and CF_UAA_CLIENT_* exports" {
    mkdir -p "$CFCTX_ROOT/tdc"
    cat > "$CFCTX_ROOT/tdc/context.env" <<'EOF'
export CF_API="https://api.sys.tdc.example.com"
export CF_AUTH_MODE="client"
export CF_UAA_CLIENT_ID="cfctx-bot"
export CF_UAA_CLIENT_SECRET="s3cr3t"
export CF_SSO_CAPABLE="1"
EOF
    chmod 600 "$CFCTX_ROOT/tdc/context.env"
    run "$CFCTX_ENV" tdc
    [ "$status" -eq 0 ]
    [[ "$output" == *'export CF_AUTH_MODE=client'* ]]
    [[ "$output" == *'export CF_UAA_CLIENT_ID=cfctx-bot'* ]]
    [[ "$output" == *'export CF_UAA_CLIENT_SECRET=s3cr3t'* ]]
    [[ "$output" == *'export CF_SSO_CAPABLE=1'* ]]
}

@test "cfctx-env --login does client_credentials auth and refreshes token" {
    local bindir="$BATS_TEST_TMPDIR/bin"; mkdir -p "$bindir"
    cat > "$bindir/cf" <<'MOCKCF'
#!/usr/bin/env bash
: "${CF_HOME:=$HOME}"; mkdir -p "$CF_HOME/.cf"; cfg="$CF_HOME/.cf/config.json"
log="${CFCTX_MOCK_CF_LOG:-/tmp/cf-mock.log}"; printf '%s\n' "$*" >> "$log"
case "$1" in
    api)  printf '{"Target":"%s","AccessToken":""}\n' "$2" > "$cfg" ;;
    auth) printf '{"Target":"x","AccessToken":"bearer fake-token"}\n' > "$cfg" ;;
    *) exit 0 ;;
esac
MOCKCF
    chmod +x "$bindir/cf"
    export PATH="$bindir:$PATH"
    export CFCTX_MOCK_CF_LOG="$BATS_TEST_TMPDIR/cf.log"; : > "$CFCTX_MOCK_CF_LOG"

    mkdir -p "$CFCTX_ROOT/bot"
    cat > "$CFCTX_ROOT/bot/context.env" <<'EOF'
export CF_API="https://api.sys.x.example.com"
export CF_AUTH_MODE="client"
export CF_UAA_CLIENT_ID="cfctx-bot"
export CF_UAA_CLIENT_SECRET="s3cr3t"
EOF
    chmod 600 "$CFCTX_ROOT/bot/context.env"

    run "$CFCTX_ENV" --login bot
    [ "$status" -eq 0 ]
    grep -q '^auth cfctx-bot s3cr3t --client-credentials' "$CFCTX_MOCK_CF_LOG"
    grep -q 'fake-token' "$CFCTX_ROOT/bot/.cf/config.json"
}

@test "cfctx-env --login errors clearly when context is not client-capable" {
    mkdir -p "$CFCTX_ROOT/dev"
    cat > "$CFCTX_ROOT/dev/context.env" <<'EOF'
export CF_API="https://api.sys.x.example.com"
export CF_AUTH_MODE="sso"
EOF
    chmod 600 "$CFCTX_ROOT/dev/context.env"
    run "$CFCTX_ENV" --login dev
    [ "$status" -ne 0 ]
    [[ "$output" == *"not client-capable"* ]]
    [[ "$output" != *"command not found"* ]]
}

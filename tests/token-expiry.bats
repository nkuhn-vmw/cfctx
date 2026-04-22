#!/usr/bin/env bats
# Token-expiry detection via JWT `exp` claim.

setup() {
    export CFCTX_ROOT="$BATS_TEST_TMPDIR/cf-homes"
    mkdir -p "$CFCTX_ROOT"
    export PATH="$BATS_TEST_TMPDIR/nocf:/usr/bin:/bin:/opt/homebrew/bin:/usr/local/bin"
    mkdir -p "$BATS_TEST_TMPDIR/nocf"
    unset CF_HOME
    # shellcheck disable=SC1091
    source "$BATS_TEST_DIRNAME/../cfctx.sh"
}

# Build a fake JWT "bearer <h>.<p>.<sig>" with the given exp epoch.
_make_jwt() {
    local exp="$1"
    local header='{"alg":"HS256","typ":"JWT"}'
    local payload
    printf -v payload '{"exp":%s,"sub":"test"}' "$exp"
    local h p
    h=$(printf '%s' "$header"  | base64 | tr -d '=' | tr '+/' '-_' | tr -d '\n')
    p=$(printf '%s' "$payload" | base64 | tr -d '=' | tr '+/' '-_' | tr -d '\n')
    printf 'bearer %s.%s.fake-sig' "$h" "$p"
}

_write_config() {
    local dir="$1" target="$2" token="$3"
    mkdir -p "$dir/.cf"
    printf '{"Target":"%s","AccessToken":"%s","RefreshToken":"r","OrganizationFields":{"Name":""},"SpaceFields":{"Name":""}}\n' \
        "$target" "$token" > "$dir/.cf/config.json"
}

@test "_cfctx_token_exp_epoch extracts exp from a valid JWT" {
    if ! command -v jq >/dev/null 2>&1; then skip "jq not installed"; fi
    local exp_want=1999999999   # far-future fixed value
    local dir="$CFCTX_ROOT/foo"
    _write_config "$dir" "https://api.example.com" "$(_make_jwt $exp_want)"
    result=$(_cfctx_token_exp_epoch "$dir/.cf/config.json")
    [ "$result" = "$exp_want" ]
}

@test "_cfctx_token_expired returns 0 for an expired token" {
    if ! command -v jq >/dev/null 2>&1; then skip "jq not installed"; fi
    local dir="$CFCTX_ROOT/expired"
    _write_config "$dir" "https://api.example.com" "$(_make_jwt $(( $(date +%s) - 3600 )))"
    run _cfctx_token_expired "$dir/.cf/config.json"
    [ "$status" -eq 0 ]
}

@test "_cfctx_token_expired returns 1 for a valid future-dated token" {
    if ! command -v jq >/dev/null 2>&1; then skip "jq not installed"; fi
    local dir="$CFCTX_ROOT/valid"
    _write_config "$dir" "https://api.example.com" "$(_make_jwt $(( $(date +%s) + 3600 )))"
    run _cfctx_token_expired "$dir/.cf/config.json"
    [ "$status" -eq 1 ]
}

@test "_cfctx_token_expired returns 2 (can't tell) for non-JWT opaque tokens" {
    local dir="$CFCTX_ROOT/opaque"
    _write_config "$dir" "https://api.example.com" "bearer notajwt"
    run _cfctx_token_expired "$dir/.cf/config.json"
    [ "$status" -eq 2 ]
}

@test "_cfctx_token_expired returns 2 when config.json is missing" {
    run _cfctx_token_expired "$CFCTX_ROOT/nonexistent/config.json"
    [ "$status" -eq 2 ]
}

@test "_cfctx_token_humanize prints 'EXPIRED' for an expired token" {
    if ! command -v jq >/dev/null 2>&1; then skip "jq not installed"; fi
    local dir="$CFCTX_ROOT/ex"
    _write_config "$dir" "https://api.example.com" "$(_make_jwt $(( $(date +%s) - 7200 )))"
    result=$(_cfctx_token_humanize "$dir/.cf/config.json")
    [[ "$result" == *"EXPIRED"* ]]
}

@test "_cfctx_token_humanize prints 'expires in Xh' for valid tokens" {
    if ! command -v jq >/dev/null 2>&1; then skip "jq not installed"; fi
    local dir="$CFCTX_ROOT/ok"
    _write_config "$dir" "https://api.example.com" "$(_make_jwt $(( $(date +%s) + 5400 )))"
    result=$(_cfctx_token_humanize "$dir/.cf/config.json")
    [[ "$result" == *"expires in"* ]]
}

@test "doctor flags an expired token and says next switch will re-auth" {
    if ! command -v jq >/dev/null 2>&1; then skip "jq not installed"; fi
    local dir="$CFCTX_ROOT/stale"
    mkdir -p "$dir"
    cat > "$dir/context.env" <<'EOF'
export CF_API="https://api.example.com"
export CF_USERNAME="admin"
export CF_PASSWORD="pw"
export BOSH_ENVIRONMENT="10.0.0.10"
EOF
    chmod 600 "$dir/context.env"
    _write_config "$dir" "https://api.example.com" "$(_make_jwt $(( $(date +%s) - 3600 )))"
    run cfctx doctor
    [[ "$output" == *"EXPIRED"* ]]
    [[ "$output" == *"next switch will re-auth"* ]]
}

@test "doctor shows remaining time for a valid token" {
    if ! command -v jq >/dev/null 2>&1; then skip "jq not installed"; fi
    local dir="$CFCTX_ROOT/live"
    mkdir -p "$dir"
    cat > "$dir/context.env" <<'EOF'
export CF_API="https://api.example.com"
export CF_USERNAME="admin"
export CF_PASSWORD="pw"
export BOSH_ENVIRONMENT="10.0.0.10"
EOF
    chmod 600 "$dir/context.env"
    _write_config "$dir" "https://api.example.com" "$(_make_jwt $(( $(date +%s) + 7200 )))"
    run cfctx doctor
    [[ "$output" == *"CF token cached (expires in"* ]]
}

@test "auto_login re-auths when cached token is expired" {
    if ! command -v jq >/dev/null 2>&1; then skip "jq not installed"; fi

    # Install a mock cf that records invocations.
    local bindir="$BATS_TEST_TMPDIR/bin"
    mkdir -p "$bindir"
    local log="$BATS_TEST_TMPDIR/cf.log"
    : > "$log"
    cat > "$bindir/cf" <<MOCKCF
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$log"
cfg="\$CF_HOME/.cf/config.json"
mkdir -p "\$CF_HOME/.cf"
case "\$1" in
    api)
        printf '{"Target":"%s","AccessToken":"","RefreshToken":""}\n' "\$2" > "\$cfg"
        echo "Setting api endpoint to \$2..."
        ;;
    auth)
        # Pretend re-auth wrote a valid far-future token.
        header=\$(printf '{"alg":"HS256","typ":"JWT"}' | base64 | tr -d '=' | tr '+/' '-_' | tr -d '\\n')
        payload=\$(printf '{"exp":%s}' \$((\$(date +%s) + 3600)) | base64 | tr -d '=' | tr '+/' '-_' | tr -d '\\n')
        printf '{"Target":"%s","AccessToken":"bearer %s.%s.sig","RefreshToken":"r","OrganizationFields":{"Name":""},"SpaceFields":{"Name":""},"Username":"%s"}\n' \
            "https://api.example.com" "\$header" "\$payload" "\$2" > "\$cfg"
        echo "Authenticating..."
        ;;
    target)
        echo "api endpoint: https://api.example.com"; echo "user: admin"
        ;;
esac
MOCKCF
    chmod +x "$bindir/cf"
    export PATH="$bindir:$PATH"

    # Pre-seed an expired token in the context.
    local dir="$CFCTX_ROOT/tdc"
    mkdir -p "$dir"
    cat > "$dir/context.env" <<'EOF'
export CF_API="https://api.example.com"
export CF_USERNAME="admin"
export CF_PASSWORD="pw"
EOF
    chmod 600 "$dir/context.env"
    _write_config "$dir" "https://api.example.com" "$(_make_jwt $(( $(date +%s) - 60 )))"

    run cfctx tdc --no-enrich
    [[ "$output" == *"cached token expired"* ]]
    # Mock cf should have been called for api + auth (re-auth triggered).
    grep -q '^api ' "$log"
    grep -q '^auth ' "$log"
}

#!/usr/bin/env bats
# `cfctx target` auto-login: cf api + cf auth + cf target, with token-cache skip.
#
# Uses a mock `cf` binary to avoid hitting a real foundation. The mock writes
# every invocation to $BATS_TEST_TMPDIR/cf.log and simulates `cf api` writing
# a config.json so the token-cache skip logic can be exercised.

setup() {
    export CFCTX_ROOT="$BATS_TEST_TMPDIR/cf-homes"
    mkdir -p "$CFCTX_ROOT"

    # Install the mock cf.
    local bindir="$BATS_TEST_TMPDIR/bin"
    mkdir -p "$bindir"
    cat > "$bindir/cf" <<'MOCKCF'
#!/usr/bin/env bash
# Minimal mock of the cf CLI — logs invocations and simulates state.
: "${CF_HOME:=$HOME}"
mkdir -p "$CF_HOME/.cf"
cfg="$CF_HOME/.cf/config.json"
log="${CFCTX_MOCK_CF_LOG:-/tmp/cf-mock.log}"

# Record this call
printf '%s\n' "$*" >> "$log"

case "$1" in
    api)
        # cf api <url> [--skip-ssl-validation]
        url="$2"
        # If a failure URL was requested, exit nonzero.
        if [[ "$url" == *"fail"* ]]; then exit 1; fi
        # Write a minimal config.json with the target set, no token yet.
        printf '{"Target":"%s","AccessToken":"","RefreshToken":"","OrganizationFields":{"Name":""},"SpaceFields":{"Name":""}}\n' "$url" > "$cfg"
        echo "Setting api endpoint to $url..."
        ;;
    auth)
        # cf auth <user> <pass>
        user="$2"; pass="$3"
        if [[ "$pass" == "wrong" ]]; then exit 1; fi
        # Rewrite config.json with a fake access token and user.
        target=$(awk -F'"' '/"Target":/ {print $4; exit}' "$cfg" 2>/dev/null)
        printf '{"Target":"%s","AccessToken":"bearer fake-token","RefreshToken":"refresh","OrganizationFields":{"Name":""},"SpaceFields":{"Name":""},"Username":"%s"}\n' "$target" "$user" > "$cfg"
        echo "Authenticating..."
        echo "OK"
        ;;
    target)
        # Read config.json and print target info.
        target=$(awk -F'"' '/"Target":/ {print $4; exit}' "$cfg" 2>/dev/null)
        user=$(awk -F'"' '/"Username":/ {print $4; exit}' "$cfg" 2>/dev/null)
        org=""
        space=""
        # Handle -o and -s updates
        while (( $# )); do
            case "$2" in
                -o) org="$3"; shift 2;;
                -s) space="$3"; shift 2;;
                *) shift;;
            esac
        done
        # If -o/-s were set, rewrite the config.
        if [[ -n "$org$space" ]]; then
            printf '{"Target":"%s","AccessToken":"bearer fake-token","RefreshToken":"refresh","OrganizationFields":{"Name":"%s"},"SpaceFields":{"Name":"%s"},"Username":"%s"}\n' "$target" "$org" "$space" "$user" > "$cfg"
        fi
        org=$(awk -F'"' '/"OrganizationFields":.*"Name":/ {match($0,/"Name":"[^"]*"/); print substr($0,RSTART+8,RLENGTH-9); exit}' "$cfg" 2>/dev/null)
        space=$(awk -F'"' '/"SpaceFields":.*"Name":/ {match($0,/"Name":"[^"]*"/); print substr($0,RSTART+8,RLENGTH-9); exit}' "$cfg" 2>/dev/null)
        echo "api endpoint: $target"
        [[ -n "$user" ]] && echo "user: $user"
        [[ -n "$org" ]] && echo "org: $org"
        [[ -n "$space" ]] && echo "space: $space"
        ;;
    *)
        echo "mock cf: unhandled: $*" >&2
        exit 2
        ;;
esac
MOCKCF
    chmod +x "$bindir/cf"
    export PATH="$bindir:/usr/bin:/bin"
    export CFCTX_MOCK_CF_LOG="$BATS_TEST_TMPDIR/cf.log"
    : > "$CFCTX_MOCK_CF_LOG"

    unset CF_HOME CF_API CF_USERNAME CF_PASSWORD CF_ORG CF_SPACE
    unset OM_USERNAME OM_PASSWORD OM_SKIP_SSL_VALIDATION
    unset CFCTX_NO_AUTO_LOGIN
    # shellcheck disable=SC1091
    source "$BATS_TEST_DIRNAME/../cfctx.sh"
}

@test "target --cf-api persists CF_API into context.env and triggers login" {
    # Pre-stamp with an om yaml that has OM_USERNAME/OM_PASSWORD set.
    local om_file="$BATS_TEST_TMPDIR/tdc.yml"
    cat > "$om_file" <<'EOF'
target: https://opsmgr.tdc.example.com
username: admin
password: secret
skip-ssl-validation: true
EOF

    cfctx target tdc --from-om "$om_file" --cf-api https://api.sys.tdc.example.com
    grep -q 'CF_API="https://api.sys.tdc.example.com"' "$CFCTX_ROOT/tdc/context.env"

    # Mock cf should have received: api, auth, target
    grep -q '^api https://api.sys.tdc.example.com' "$CFCTX_MOCK_CF_LOG"
    grep -q '^auth admin secret' "$CFCTX_MOCK_CF_LOG"

    # Token should now be cached
    grep -q 'fake-token' "$CFCTX_ROOT/tdc/.cf/config.json"
}

@test "second target reuses cached token — no new api/auth calls" {
    local om_file="$BATS_TEST_TMPDIR/tdc.yml"
    cat > "$om_file" <<'EOF'
target: https://opsmgr.tdc.example.com
username: admin
password: secret
EOF
    cfctx target tdc --from-om "$om_file" --cf-api https://api.sys.tdc.example.com

    # Clear the mock log, then target again.
    : > "$CFCTX_MOCK_CF_LOG"
    unset CF_HOME CF_API OM_USERNAME OM_PASSWORD
    run cfctx target tdc
    [ "$status" -eq 0 ]
    [[ "$output" == *"using cached token"* ]]

    # Mock should have been called only for `cf target` (the status print),
    # NOT `cf api` or `cf auth`.
    ! grep -q '^api ' "$CFCTX_MOCK_CF_LOG"
    ! grep -q '^auth ' "$CFCTX_MOCK_CF_LOG"
}

@test "--no-login skips cf calls entirely" {
    local om_file="$BATS_TEST_TMPDIR/tdc.yml"
    cat > "$om_file" <<'EOF'
target: https://opsmgr.tdc.example.com
username: admin
password: secret
EOF

    cfctx target tdc --from-om "$om_file" --cf-api https://api.sys.tdc.example.com --no-login
    ! grep -q '^api ' "$CFCTX_MOCK_CF_LOG"
    ! grep -q '^auth ' "$CFCTX_MOCK_CF_LOG"
}

@test "CFCTX_NO_AUTO_LOGIN=1 also skips" {
    local om_file="$BATS_TEST_TMPDIR/tdc.yml"
    cat > "$om_file" <<'EOF'
target: https://opsmgr.tdc.example.com
username: admin
password: secret
EOF

    CFCTX_NO_AUTO_LOGIN=1 cfctx target tdc \
        --from-om "$om_file" --cf-api https://api.sys.tdc.example.com
    ! grep -q '^api ' "$CFCTX_MOCK_CF_LOG"
    ! grep -q '^auth ' "$CFCTX_MOCK_CF_LOG"
}

@test "falls back to OM_USERNAME/OM_PASSWORD when CF_* not set" {
    local om_file="$BATS_TEST_TMPDIR/tdc.yml"
    cat > "$om_file" <<'EOF'
target: https://opsmgr.tdc.example.com
username: om-admin
password: om-secret
EOF

    cfctx target tdc --from-om "$om_file" --cf-api https://api.sys.tdc.example.com
    grep -q '^auth om-admin om-secret' "$CFCTX_MOCK_CF_LOG"
}

@test "cf api failure is reported but does not fail the switch" {
    local om_file="$BATS_TEST_TMPDIR/bad.yml"
    cat > "$om_file" <<'EOF'
target: https://opsmgr.bad.example.com
username: admin
password: secret
EOF

    run cfctx target bad --from-om "$om_file" --cf-api https://api.sys.fail.example.com
    [ "$status" -eq 0 ]
    [[ "$output" == *"cf api failed"* ]]
    # CF_HOME still got set
    [[ "$output" == *"CF_HOME=$CFCTX_ROOT/bad"* ]]
}

@test "cf auth failure is reported but does not fail the switch" {
    # Use password 'wrong' which the mock rejects.
    local om_file="$BATS_TEST_TMPDIR/ok.yml"
    cat > "$om_file" <<'EOF'
target: https://opsmgr.ok.example.com
username: admin
password: wrong
EOF

    run cfctx target ok --from-om "$om_file" --cf-api https://api.sys.ok.example.com
    [ "$status" -eq 0 ]
    [[ "$output" == *"cf auth failed"* ]]
}

@test "CF_ORG/CF_SPACE targets org/space after auth" {
    local om_file="$BATS_TEST_TMPDIR/tdc.yml"
    cat > "$om_file" <<'EOF'
target: https://opsmgr.tdc.example.com
username: admin
password: secret
EOF
    cfctx target tdc --from-om "$om_file" --cf-api https://api.sys.tdc.example.com
    # Manually add CF_ORG/CF_SPACE and force re-target (tokens cached, so no
    # new auth; but cf target -o/-s should fire).
    cat >> "$CFCTX_ROOT/tdc/context.env" <<'EOF'
export CF_ORG="system"
export CF_SPACE="dev"
EOF
    chmod 600 "$CFCTX_ROOT/tdc/context.env"

    # Invalidate the token so the flow re-auths.
    echo '{}' > "$CFCTX_ROOT/tdc/.cf/config.json"
    : > "$CFCTX_MOCK_CF_LOG"
    unset CF_HOME CF_API
    cfctx target tdc
    grep -q '^target -o system -s dev' "$CFCTX_MOCK_CF_LOG"
}

@test "hint is printed when CF_API is unset on a fresh context" {
    run cfctx target blank
    [ "$status" -eq 0 ]
    [[ "$output" == *"tip: set CF_API"* ]]
}

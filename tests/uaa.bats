#!/usr/bin/env bats
# UAA integration: enrichment of UAA_URL / UAA_ADMIN_CLIENT_SECRET / OM_UAA_URL,
# and `cfctx uaa-login` subcommand.

setup() {
    export CFCTX_ROOT="$BATS_TEST_TMPDIR/cf-homes"
    mkdir -p "$CFCTX_ROOT"

    # Mock om — extend the existing one to also serve admin_client_credentials.
    local bindir="$BATS_TEST_TMPDIR/bin"
    mkdir -p "$bindir"
    cat > "$bindir/om" <<'MOCKOM'
#!/usr/bin/env bash
e_file=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        -e) e_file="$2"; shift 2;;
        *) break;;
    esac
done
sub="$1"; shift
case "$sub" in
    bosh-env)
        cat <<'BEOF'
export BOSH_CLIENT=ops_manager
export BOSH_CLIENT_SECRET=bosh-secret-123
export BOSH_ENVIRONMENT=10.0.0.10
BEOF
        ;;
    curl)
        while [[ $# -gt 0 ]]; do
            case "$1" in -p) path="$2"; shift 2;; *) shift;; esac
        done
        case "$path" in
            /api/v0/staged/products) echo '[{"guid":"cf-uaa","type":"cf"}]' ;;
            /api/v0/staged/products/cf-uaa/properties)
                echo '{"properties":{".cloud_controller.system_domain":{"value":"sys.tdc.example.com"}}}'
                ;;
            /api/v0/deployed/products/cf-uaa/credentials/.uaa.admin_credentials)
                echo '{"credential":{"value":{"identity":"admin","password":"cf-admin-pw"}}}'
                ;;
            /api/v0/deployed/products/cf-uaa/credentials/.uaa.admin_client_credentials)
                echo '{"credential":{"value":{"identity":"admin","password":"uaa-client-secret-XYZ"}}}'
                ;;
        esac
        ;;
esac
MOCKOM
    chmod +x "$bindir/om"

    export PATH="$bindir:/usr/bin:/bin"
    unset CF_HOME UAA_URL UAA_ADMIN_CLIENT UAA_ADMIN_CLIENT_SECRET OM_UAA_URL
    # shellcheck disable=SC1091
    source "$BATS_TEST_DIRNAME/../cfctx.sh"
}

@test "enrichment writes UAA_URL derived from system_domain" {
    if ! command -v jq >/dev/null 2>&1; then skip "jq required"; fi
    local om_file="$BATS_TEST_TMPDIR/tdc.yml"
    cat > "$om_file" <<'EOF'
target: https://opsmgr.tdc.example.com
username: admin
password: pw
EOF
    cfctx tdc --from-om "$om_file" --no-login
    grep -q 'UAA_URL="https://uaa.sys.tdc.example.com"' "$CFCTX_ROOT/tdc/context.env"
    grep -q 'UAA_ADMIN_CLIENT="admin"' "$CFCTX_ROOT/tdc/context.env"
}

@test "enrichment pulls UAA_ADMIN_CLIENT_SECRET from cf product" {
    if ! command -v jq >/dev/null 2>&1; then skip "jq required"; fi
    local om_file="$BATS_TEST_TMPDIR/tdc.yml"
    cat > "$om_file" <<'EOF'
target: https://opsmgr.tdc.example.com
username: admin
password: pw
EOF
    cfctx tdc --from-om "$om_file" --no-login
    grep -q 'UAA_ADMIN_CLIENT_SECRET="uaa-client-secret-XYZ"' "$CFCTX_ROOT/tdc/context.env"
}

@test "enrichment derives OM_UAA_URL from OM_TARGET" {
    if ! command -v jq >/dev/null 2>&1; then skip "jq required"; fi
    local om_file="$BATS_TEST_TMPDIR/tdc.yml"
    cat > "$om_file" <<'EOF'
target: https://opsmgr.tdc.example.com
username: admin
password: pw
EOF
    cfctx tdc --from-om "$om_file" --no-login
    grep -q 'OM_UAA_URL="https://opsmgr.tdc.example.com/uaa"' "$CFCTX_ROOT/tdc/context.env"
}

@test "switching sources UAA vars into the shell" {
    if ! command -v jq >/dev/null 2>&1; then skip "jq required"; fi
    local om_file="$BATS_TEST_TMPDIR/tdc.yml"
    cat > "$om_file" <<'EOF'
target: https://opsmgr.tdc.example.com
username: admin
password: pw
EOF
    cfctx tdc --from-om "$om_file" --no-login
    [ "$UAA_URL" = "https://uaa.sys.tdc.example.com" ]
    [ "$UAA_ADMIN_CLIENT" = "admin" ]
    [ "$UAA_ADMIN_CLIENT_SECRET" = "uaa-client-secret-XYZ" ]
    [ "$OM_UAA_URL" = "https://opsmgr.tdc.example.com/uaa" ]
}

@test "cfctx clear unsets UAA vars" {
    if ! command -v jq >/dev/null 2>&1; then skip "jq required"; fi
    local om_file="$BATS_TEST_TMPDIR/tdc.yml"
    cat > "$om_file" <<'EOF'
target: https://opsmgr.tdc.example.com
username: admin
password: pw
EOF
    cfctx tdc --from-om "$om_file" --no-login
    [ -n "$UAA_URL" ]
    cfctx clear
    [ -z "${UAA_URL:-}" ]
    [ -z "${UAA_ADMIN_CLIENT:-}" ]
    [ -z "${UAA_ADMIN_CLIENT_SECRET:-}" ]
    [ -z "${OM_UAA_URL:-}" ]
}

# ---- cfctx uaa-login ------------------------------------------------------

@test "uaa-login --help prints usage" {
    run cfctx uaa-login --help
    [ "$status" -eq 0 ]
    [[ "$output" == *"Target a UAA"* ]]
    [[ "$output" == *"--om"* ]]
}

@test "uaa-login: errors clearly when uaac is not installed" {
    # uaac isn't in our mock PATH.
    run cfctx uaa-login
    [ "$status" -ne 0 ]
    [[ "$output" == *"uaac"* ]]
    [[ "$output" == *"not installed"* ]]
}

@test "uaa-login: errors when UAA_URL is unset" {
    # Install a no-op uaac so we get past the install check.
    cat > "$BATS_TEST_TMPDIR/bin/uaac" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
    chmod +x "$BATS_TEST_TMPDIR/bin/uaac"

    unset UAA_URL UAA_ADMIN_CLIENT_SECRET
    run cfctx uaa-login
    [ "$status" -ne 0 ]
    [[ "$output" == *"UAA_URL is unset"* ]]
}

@test "uaa-login: errors when UAA_ADMIN_CLIENT_SECRET is unset" {
    cat > "$BATS_TEST_TMPDIR/bin/uaac" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
    chmod +x "$BATS_TEST_TMPDIR/bin/uaac"

    export UAA_URL="https://uaa.example.com"
    unset UAA_ADMIN_CLIENT_SECRET
    run cfctx uaa-login
    [ "$status" -ne 0 ]
    [[ "$output" == *"UAA_ADMIN_CLIENT_SECRET is unset"* ]]
}

@test "uaa-login: invokes uaac target + token client get with CF UAA values" {
    local log="$BATS_TEST_TMPDIR/uaac.log"
    cat > "$BATS_TEST_TMPDIR/bin/uaac" <<MOCKUAAC
#!/usr/bin/env bash
echo "\$@" >> "$log"
case "\$1" in
    target)  echo "Target: \$2" ;;
    token)   echo "Got token" ;;
    context) echo "  user: admin"; echo "  client_id: admin" ;;
esac
exit 0
MOCKUAAC
    chmod +x "$BATS_TEST_TMPDIR/bin/uaac"
    : > "$log"

    export UAA_URL="https://uaa.tdc.example.com"
    export UAA_ADMIN_CLIENT="admin"
    export UAA_ADMIN_CLIENT_SECRET="secret123"

    run cfctx uaa-login
    [ "$status" -eq 0 ]
    grep -q "^target https://uaa.tdc.example.com" "$log"
    grep -q "^token client get admin -s secret123" "$log"
}

@test "uaa-login --om: uses OM_UAA_URL + OM_CLIENT_ID/SECRET" {
    local log="$BATS_TEST_TMPDIR/uaac.log"
    cat > "$BATS_TEST_TMPDIR/bin/uaac" <<MOCKUAAC
#!/usr/bin/env bash
echo "\$@" >> "$log"
exit 0
MOCKUAAC
    chmod +x "$BATS_TEST_TMPDIR/bin/uaac"
    : > "$log"

    export OM_UAA_URL="https://opsmgr.tdc.example.com/uaa"
    export OM_CLIENT_ID="om-client"
    export OM_CLIENT_SECRET="om-secret"

    run cfctx uaa-login --om
    [ "$status" -eq 0 ]
    grep -q "^target https://opsmgr.tdc.example.com/uaa" "$log"
    grep -q "^token client get om-client -s om-secret" "$log"
}

@test "uaa-login --om: errors when OM_CLIENT_ID is unset" {
    cat > "$BATS_TEST_TMPDIR/bin/uaac" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
    chmod +x "$BATS_TEST_TMPDIR/bin/uaac"

    export OM_UAA_URL="https://opsmgr.example.com/uaa"
    unset OM_CLIENT_ID OM_CLIENT_SECRET
    run cfctx uaa-login --om
    [ "$status" -ne 0 ]
    [[ "$output" == *"OM_CLIENT_ID"* ]]
}

@test "uaa-login: respects OM_SKIP_SSL_VALIDATION=true" {
    local log="$BATS_TEST_TMPDIR/uaac.log"
    cat > "$BATS_TEST_TMPDIR/bin/uaac" <<MOCKUAAC
#!/usr/bin/env bash
echo "\$@" >> "$log"
exit 0
MOCKUAAC
    chmod +x "$BATS_TEST_TMPDIR/bin/uaac"
    : > "$log"

    export UAA_URL="https://uaa.example.com"
    export UAA_ADMIN_CLIENT="admin"
    export UAA_ADMIN_CLIENT_SECRET="secret"
    export OM_SKIP_SSL_VALIDATION="true"

    cfctx uaa-login >/dev/null 2>&1
    grep -q -- "--skip-ssl-validation" "$log"
}

# ---- doctor passes through uaac status ------------------------------------

@test "doctor mentions uaac when not installed" {
    run cfctx doctor
    [[ "$output" == *"uaac NOT in PATH"* ]]
    [[ "$output" == *"gem install cf-uaac"* ]]
}

# ---- cfctx-env passes UAA vars through ------------------------------------

@test "cfctx-env emits UAA_* exports" {
    mkdir -p "$CFCTX_ROOT/tdc"
    cat > "$CFCTX_ROOT/tdc/context.env" <<'EOF'
export UAA_URL="https://uaa.example.com"
export UAA_ADMIN_CLIENT="admin"
export UAA_ADMIN_CLIENT_SECRET="secret"
export OM_UAA_URL="https://opsmgr.example.com/uaa"
EOF
    chmod 600 "$CFCTX_ROOT/tdc/context.env"

    run "$BATS_TEST_DIRNAME/../bin/cfctx-env" tdc
    [ "$status" -eq 0 ]
    [[ "$output" == *"export UAA_URL="* ]]
    [[ "$output" == *"export UAA_ADMIN_CLIENT="* ]]
    [[ "$output" == *"export UAA_ADMIN_CLIENT_SECRET="* ]]
    [[ "$output" == *"export OM_UAA_URL="* ]]
}

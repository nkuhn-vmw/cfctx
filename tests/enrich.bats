#!/usr/bin/env bats
# `om`-based enrichment: auto-populate BOSH_* and CF_API from Ops Manager.

setup() {
    export CFCTX_ROOT="$BATS_TEST_TMPDIR/cf-homes"
    mkdir -p "$CFCTX_ROOT"

    # Mock om — returns canned responses depending on subcommand.
    local bindir="$BATS_TEST_TMPDIR/bin"
    mkdir -p "$bindir"
    cat > "$bindir/om" <<'MOCKOM'
#!/usr/bin/env bash
# Minimal om mock. Supports: bosh-env, curl -p <path>
# Usage pattern from cfctx: om -e <file> <subcommand> ...
e_file=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        -e) e_file="$2"; shift 2;;
        *) break;;
    esac
done

sub="$1"; shift

# Simulate unreachable OM if the env file mentions "unreachable".
if grep -q "unreachable" "$e_file" 2>/dev/null; then
    exit 1
fi

case "$sub" in
    bosh-env)
        cat <<'BEOF'
export BOSH_CLIENT=ops_manager
export BOSH_CLIENT_SECRET=bosh-secret-123
export BOSH_ENVIRONMENT=10.0.0.10
export BOSH_CA_CERT='-----BEGIN CERTIFICATE-----
MIIMOCK
-----END CERTIFICATE-----'
BEOF
        ;;
    curl)
        # cfctx calls: curl -p /path
        while [[ $# -gt 0 ]]; do
            case "$1" in
                -p) path="$2"; shift 2;;
                *) shift;;
            esac
        done
        case "$path" in
            /api/v0/staged/products)
                cat <<'JEOF'
[
  {"guid": "p-bosh-abc123", "type": "p-bosh", "product_version": "2.10.0"},
  {"guid": "cf-guid-xyz789", "type": "cf", "product_version": "2.12.0"}
]
JEOF
                ;;
            /api/v0/staged/products/cf-guid-xyz789/properties)
                cat <<'JEOF'
{
  "properties": {
    ".cloud_controller.system_domain": {"value": "sys.tdc.example.com"},
    ".cloud_controller.apps_domain": {"value": "apps.tdc.example.com"}
  }
}
JEOF
                ;;
            /api/v0/deployed/products/cf-guid-xyz789/credentials/.uaa.admin_credentials)
                cat <<'JEOF'
{
  "credential": {
    "type": "simple_credentials",
    "value": {
      "identity": "admin",
      "password": "real-cf-password-$!"
    }
  }
}
JEOF
                ;;
            *)
                echo "mock om: unknown path: $path" >&2
                exit 1
                ;;
        esac
        ;;
    *)
        echo "mock om: unsupported: $sub" >&2
        exit 2
        ;;
esac
MOCKOM
    chmod +x "$bindir/om"
    export PATH="$bindir:/usr/bin:/bin"

    unset CF_HOME CF_API CFCTX_NO_AUTO_LOGIN CFCTX_NO_OM_ENRICH
    # shellcheck disable=SC1091
    source "$BATS_TEST_DIRNAME/../cfctx.sh"
}

@test "init-env --from-om runs enrichment and populates BOSH_* + CF_API + CF creds" {
    # Requires jq for CF_API + CF_USERNAME/CF_PASSWORD detection.
    local om_file="$BATS_TEST_TMPDIR/tdc.yml"
    cat > "$om_file" <<'EOF'
target: https://opsmgr.tdc.example.com
username: admin
password: s3cret
EOF

    run cfctx tdc --from-om "$om_file" --no-login
    [ "$status" -eq 0 ]

    # BOSH_* written in the managed section
    grep -q '^# ---- BOSH-FROM-OM' "$CFCTX_ROOT/tdc/context.env"
    grep -q '^export BOSH_CLIENT=ops_manager' "$CFCTX_ROOT/tdc/context.env"
    grep -q '^export BOSH_CLIENT_SECRET=bosh-secret-123' "$CFCTX_ROOT/tdc/context.env"
    grep -q '^export BOSH_ENVIRONMENT=10.0.0.10' "$CFCTX_ROOT/tdc/context.env"

    if command -v jq >/dev/null 2>&1; then
        grep -q 'CF_API="https://api.sys.tdc.example.com"' "$CFCTX_ROOT/tdc/context.env"
        grep -q 'CF_USERNAME="admin"' "$CFCTX_ROOT/tdc/context.env"
        # Special chars in the password must be escaped for safe shell sourcing.
        grep -q 'CF_PASSWORD="real-cf-password-\\$!"' "$CFCTX_ROOT/tdc/context.env"
    fi
}

@test "enrichment defaults CF_ORG=system and CF_SPACE=system" {
    if ! command -v jq >/dev/null 2>&1; then skip "jq needed"; fi
    local om_file="$BATS_TEST_TMPDIR/tdc.yml"
    cat > "$om_file" <<'EOF'
target: https://opsmgr.tdc.example.com
username: admin
password: pw
EOF
    cfctx tdc --from-om "$om_file" --no-login
    grep -q 'CF_ORG="system"' "$CFCTX_ROOT/tdc/context.env"
    grep -q 'CF_SPACE="system"' "$CFCTX_ROOT/tdc/context.env"
}

@test "enrichment does not overwrite user-set CF_ORG" {
    if ! command -v jq >/dev/null 2>&1; then skip "jq needed"; fi
    local om_file="$BATS_TEST_TMPDIR/tdc.yml"
    cat > "$om_file" <<'EOF'
target: https://opsmgr.tdc.example.com
username: admin
password: pw
EOF
    cfctx tdc --from-om "$om_file" --no-login
    # User customizes.
    sed -i.bak 's/CF_ORG="system"/CF_ORG="myteam"/' "$CFCTX_ROOT/tdc/context.env"
    # Re-enrich.
    cfctx enrich tdc
    grep -q 'CF_ORG="myteam"' "$CFCTX_ROOT/tdc/context.env"
    ! grep -q 'CF_ORG="system"' "$CFCTX_ROOT/tdc/context.env"
}

@test "enrichment ignores leaked OM_* from previous context (switches use -e yaml only)" {
    # Simulate leaking env from a previous `cfctx tdc` switch.
    export OM_TARGET="https://opsmgr.TDC-LEAKED.example.com"
    export OM_USERNAME="tdc-admin"
    export OM_PASSWORD="tdc-leaked-pw"

    # Extend the mock om to fail loudly if it sees TDC-LEAKED in its effective
    # env or args, so the test catches the regression if leakage recurs.
    cat > "$BATS_TEST_TMPDIR/bin/om" <<'MOCKOM'
#!/usr/bin/env bash
# Refuse to run if leaked OM_TARGET is visible via the env.
if [[ "$OM_TARGET" == *"TDC-LEAKED"* ]]; then
    echo "mock om: LEAKAGE DETECTED — OM_TARGET=$OM_TARGET" >&2
    exit 99
fi
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
        while [[ $# -gt 0 ]]; do case "$1" in -p) path="$2"; shift 2;; *) shift;; esac; done
        case "$path" in
            /api/v0/staged/products) echo '[{"guid":"cf-ndc","type":"cf"}]' ;;
            /api/v0/staged/products/cf-ndc/properties)
                echo '{"properties":{".cloud_controller.system_domain":{"value":"sys.ndc.example.com"}}}'
                ;;
            /api/v0/deployed/products/cf-ndc/credentials/.uaa.admin_credentials)
                echo '{"credential":{"value":{"identity":"admin","password":"ndc-pw"}}}'
                ;;
        esac
        ;;
esac
MOCKOM
    chmod +x "$BATS_TEST_TMPDIR/bin/om"

    local om_file="$BATS_TEST_TMPDIR/ndc.yml"
    cat > "$om_file" <<'EOF'
target: https://opsmgr.ndc.example.com
username: ndc-admin
password: ndc-pw
EOF

    run cfctx ndc --from-om "$om_file" --no-login
    [ "$status" -eq 0 ]

    # Must have populated the NDC system domain, not anything TDC-shaped.
    if command -v jq >/dev/null 2>&1; then
        grep -q 'CF_API="https://api.sys.ndc.example.com"' "$CFCTX_ROOT/ndc/context.env"
        ! grep -q 'TDC-LEAKED' "$CFCTX_ROOT/ndc/context.env"
    fi
}

@test "--org and --space flags persist to context.env" {
    local om_file="$BATS_TEST_TMPDIR/tdc.yml"
    cat > "$om_file" <<'EOF'
target: https://opsmgr.tdc.example.com
username: admin
password: pw
EOF
    cfctx tdc --from-om "$om_file" --org staging --space dev --no-login
    grep -q 'CF_ORG="staging"' "$CFCTX_ROOT/tdc/context.env"
    grep -q 'CF_SPACE="dev"' "$CFCTX_ROOT/tdc/context.env"
}

@test "CF_PASSWORD with special chars round-trips correctly through source" {
    if ! command -v jq >/dev/null 2>&1; then
        skip "jq not available"
    fi
    local om_file="$BATS_TEST_TMPDIR/tdc.yml"
    cat > "$om_file" <<'EOF'
target: https://opsmgr.tdc.example.com
username: admin
password: pw
EOF
    cfctx tdc --from-om "$om_file" --no-login
    # Re-source and verify the value matches what Ops Manager returned.
    unset CF_PASSWORD
    # shellcheck disable=SC1091
    source "$CFCTX_ROOT/tdc/context.env"
    [ "$CF_PASSWORD" = "real-cf-password-\$!" ]
}

@test "BOSH_* values land in the shell after switch" {
    local om_file="$BATS_TEST_TMPDIR/tdc.yml"
    cat > "$om_file" <<'EOF'
target: https://opsmgr.tdc.example.com
username: admin
password: pw
EOF

    cfctx tdc --from-om "$om_file" --no-login
    [ "$BOSH_CLIENT" = "ops_manager" ]
    [ "$BOSH_CLIENT_SECRET" = "bosh-secret-123" ]
    [ "$BOSH_ENVIRONMENT" = "10.0.0.10" ]
}

@test "--no-enrich skips om entirely" {
    local om_file="$BATS_TEST_TMPDIR/tdc.yml"
    cat > "$om_file" <<'EOF'
target: https://opsmgr.tdc.example.com
username: admin
password: pw
EOF

    cfctx tdc --from-om "$om_file" --no-enrich --no-login
    ! grep -q 'BOSH-FROM-OM' "$CFCTX_ROOT/tdc/context.env"
    ! grep -q '^export BOSH_CLIENT=' "$CFCTX_ROOT/tdc/context.env"
}

@test "CFCTX_NO_OM_ENRICH=1 also skips" {
    local om_file="$BATS_TEST_TMPDIR/tdc.yml"
    cat > "$om_file" <<'EOF'
target: https://opsmgr.tdc.example.com
username: admin
password: pw
EOF

    CFCTX_NO_OM_ENRICH=1 cfctx tdc --from-om "$om_file" --no-login
    ! grep -q 'BOSH-FROM-OM' "$CFCTX_ROOT/tdc/context.env"
}

@test "unreachable OM: enrichment fails gracefully, switch still succeeds" {
    local om_file="$BATS_TEST_TMPDIR/unreachable.yml"
    cat > "$om_file" <<'EOF'
target: https://opsmgr.unreachable.example.com
username: admin
password: pw
EOF

    run cfctx unreachable --from-om "$om_file" --no-login
    [ "$status" -eq 0 ]
    [[ "$output" == *"OM is unreachable"* ]] || [[ "$output" == *"om bosh-env returned nothing"* ]]
    # Context.env was still stamped from yaml.
    grep -q 'OM_TARGET="https://opsmgr.unreachable.example.com"' "$CFCTX_ROOT/unreachable/context.env"
    # But no BOSH-FROM-OM section.
    ! grep -q 'BOSH-FROM-OM' "$CFCTX_ROOT/unreachable/context.env"
}

@test "cfctx enrich re-runs against an existing context using the om-source marker" {
    local om_file="$BATS_TEST_TMPDIR/tdc.yml"
    cat > "$om_file" <<'EOF'
target: https://opsmgr.tdc.example.com
username: admin
password: pw
EOF

    cfctx tdc --from-om "$om_file" --no-login

    # Remove the BOSH section and re-run enrich to verify idempotency.
    sed -i.bak '/BOSH-FROM-OM/,/END BOSH-FROM-OM/d' "$CFCTX_ROOT/tdc/context.env" 2>/dev/null || true

    run cfctx enrich tdc
    [ "$status" -eq 0 ]
    grep -q 'BOSH-FROM-OM' "$CFCTX_ROOT/tdc/context.env"
}

@test "enrich is idempotent — no duplicated BOSH sections" {
    local om_file="$BATS_TEST_TMPDIR/tdc.yml"
    cat > "$om_file" <<'EOF'
target: https://opsmgr.tdc.example.com
username: admin
password: pw
EOF
    cfctx tdc --from-om "$om_file" --no-login
    cfctx enrich tdc
    cfctx enrich tdc
    local count
    count=$(grep -c '^# ---- BOSH-FROM-OM' "$CFCTX_ROOT/tdc/context.env")
    [ "$count" -eq 1 ]
}

@test "cfctx enrich works from inside a context (no name arg)" {
    local om_file="$BATS_TEST_TMPDIR/tdc.yml"
    cat > "$om_file" <<'EOF'
target: https://opsmgr.tdc.example.com
username: admin
password: pw
EOF
    cfctx tdc --from-om "$om_file" --no-login
    # Remove BOSH section.
    sed -i.bak '/BOSH-FROM-OM/,/END BOSH-FROM-OM/d' "$CFCTX_ROOT/tdc/context.env" 2>/dev/null || true
    cfctx enrich
    grep -q 'BOSH-FROM-OM' "$CFCTX_ROOT/tdc/context.env"
}

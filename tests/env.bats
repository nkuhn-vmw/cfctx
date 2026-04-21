#!/usr/bin/env bats
# context.env sourcing, perms enforcement, masking.

setup() {
    export CFCTX_ROOT="$BATS_TEST_TMPDIR/cf-homes"
    mkdir -p "$CFCTX_ROOT"
    export PATH="$BATS_TEST_TMPDIR/nocf:/usr/bin:/bin"
    mkdir -p "$BATS_TEST_TMPDIR/nocf"
    unset CF_HOME OM_PASSWORD OM_USERNAME BOSH_CLIENT BOSH_CLIENT_SECRET
    # shellcheck disable=SC1091
    source "$BATS_TEST_DIRNAME/../cfctx.sh"
}

@test "init-env stamps a 0600 template" {
    cfctx init-env foundationA
    [ -f "$CFCTX_ROOT/foundationA/context.env" ]
    perms=$(stat -f '%Lp' "$CFCTX_ROOT/foundationA/context.env" 2>/dev/null \
             || stat -c '%a' "$CFCTX_ROOT/foundationA/context.env")
    [ "$perms" = "600" ]
}

@test "init-env refuses to overwrite" {
    cfctx init-env foundationA
    run cfctx init-env foundationA
    [ "$status" -ne 0 ]
}

@test "switching sources context.env and exports its vars" {
    mkdir -p "$CFCTX_ROOT/foundationA"
    cat > "$CFCTX_ROOT/foundationA/context.env" <<'EOF'
export OM_USERNAME="admin"
export OM_PASSWORD="s3cret"
BOSH_CLIENT="ops_manager"
EOF
    chmod 600 "$CFCTX_ROOT/foundationA/context.env"

    cfctx foundationA
    [ "$OM_USERNAME" = "admin" ]
    [ "$OM_PASSWORD" = "s3cret" ]
    # set -a in the sourcer should auto-export even unprefixed assignments
    [ "$BOSH_CLIENT" = "ops_manager" ]
}

@test "switching refuses to source a world-readable env file" {
    mkdir -p "$CFCTX_ROOT/leaky"
    echo 'export OM_PASSWORD="nope"' > "$CFCTX_ROOT/leaky/context.env"
    chmod 644 "$CFCTX_ROOT/leaky/context.env"

    run cfctx leaky
    [[ "$output" == *"refusing to source"* ]]
    [ -z "${OM_PASSWORD:-}" ]
}

@test "env masks secret-looking values" {
    mkdir -p "$CFCTX_ROOT/maskme"
    cat > "$CFCTX_ROOT/maskme/context.env" <<'EOF'
# demo
export OM_USERNAME="admin"
export OM_PASSWORD="supersecret"
export BOSH_CLIENT_SECRET="abc123xyz"
EOF
    chmod 600 "$CFCTX_ROOT/maskme/context.env"

    run cfctx env maskme
    [ "$status" -eq 0 ]
    [[ "$output" == *"OM_USERNAME=\"admin\""* ]]
    [[ "$output" != *"supersecret"* ]]
    [[ "$output" != *"abc123xyz"* ]]
    [[ "$output" == *"OM_PASSWORD="* ]]
}

@test "ls marks contexts that have an env file" {
    mkdir -p "$CFCTX_ROOT/withenv" "$CFCTX_ROOT/plain"
    touch "$CFCTX_ROOT/withenv/context.env"
    chmod 600 "$CFCTX_ROOT/withenv/context.env"

    run cfctx ls
    [[ "$output" == *"withenv [env]"* ]]
    [[ "$output" == *"  plain"* ]]
    [[ "$output" != *"plain [env]"* ]]
}

@test "cp carries the env file and keeps 0600" {
    cfctx init-env src
    cfctx cp src dst
    [ -f "$CFCTX_ROOT/dst/context.env" ]
    perms=$(stat -f '%Lp' "$CFCTX_ROOT/dst/context.env" 2>/dev/null \
             || stat -c '%a' "$CFCTX_ROOT/dst/context.env")
    [ "$perms" = "600" ]
}

@test "init-env --from-om seeds OM_* from a flat om yaml" {
    local om_file="$BATS_TEST_TMPDIR/tdc.yml"
    cat > "$om_file" <<'EOF'
target: https://opsmgr.tdc.example.com
username: admin
password: hunter2
skip-ssl-validation: true
client-id: uaa-admin
client-secret: s3cret
decryption-passphrase: phrase
connect-timeout: 30
# unknown key should be noted as a comment
custom-thing: value
EOF

    run cfctx init-env tdc --from-om "$om_file"
    [ "$status" -eq 0 ]
    [ -f "$CFCTX_ROOT/tdc/context.env" ]

    # File permissions
    perms=$(stat -f '%Lp' "$CFCTX_ROOT/tdc/context.env" 2>/dev/null \
             || stat -c '%a' "$CFCTX_ROOT/tdc/context.env")
    [ "$perms" = "600" ]

    # Content
    grep -q 'export OM_TARGET="https://opsmgr.tdc.example.com"' "$CFCTX_ROOT/tdc/context.env"
    grep -q 'export OM_USERNAME="admin"' "$CFCTX_ROOT/tdc/context.env"
    grep -q 'export OM_PASSWORD="hunter2"' "$CFCTX_ROOT/tdc/context.env"
    grep -q 'export OM_SKIP_SSL_VALIDATION="true"' "$CFCTX_ROOT/tdc/context.env"
    grep -q 'export OM_CLIENT_ID="uaa-admin"' "$CFCTX_ROOT/tdc/context.env"
    grep -q 'export OM_CLIENT_SECRET="s3cret"' "$CFCTX_ROOT/tdc/context.env"
    grep -q 'export OM_DECRYPTION_PASSPHRASE="phrase"' "$CFCTX_ROOT/tdc/context.env"
    grep -q 'export OM_CONNECT_TIMEOUT="30"' "$CFCTX_ROOT/tdc/context.env"
    grep -q 'unmapped om key: custom-thing' "$CFCTX_ROOT/tdc/context.env"

    # Switching sources it
    cfctx tdc
    [ "$OM_USERNAME" = "admin" ]
    [ "$OM_PASSWORD" = "hunter2" ]
}

@test "init-env --from-om extracts block-scalar ca-cert to a sibling pem file" {
    local om_file="$BATS_TEST_TMPDIR/cdc.yml"
    cat > "$om_file" <<'EOF'
target: https://opsmgr.cdc.example.com
username: admin
password: pw
ca-cert: |
  -----BEGIN CERTIFICATE-----
  MIIBvjCCAS
  -----END CERTIFICATE-----
EOF

    run cfctx init-env cdc --from-om "$om_file"
    [ "$status" -eq 0 ]
    [ -f "$CFCTX_ROOT/cdc/om-ca.pem" ]
    grep -q 'BEGIN CERTIFICATE' "$CFCTX_ROOT/cdc/om-ca.pem"

    perms=$(stat -f '%Lp' "$CFCTX_ROOT/cdc/om-ca.pem" 2>/dev/null \
             || stat -c '%a' "$CFCTX_ROOT/cdc/om-ca.pem")
    [ "$perms" = "600" ]

    # Env file references the pem via $CF_HOME
    grep -q 'OM_CA_CERT="\$(cat "\$CF_HOME/om-ca.pem")"' "$CFCTX_ROOT/cdc/context.env"
}

@test "init-env auto-discovers via CFCTX_OM_ENV_DIR (<name>.yml)" {
    local om_dir="$BATS_TEST_TMPDIR/om-envs"
    mkdir -p "$om_dir"
    cat > "$om_dir/dev210.yml" <<'EOF'
target: https://opsmgr.dev210.example.com
username: admin
password: auto
EOF

    CFCTX_OM_ENV_DIR="$om_dir" cfctx init-env dev210
    [ -f "$CFCTX_ROOT/dev210/context.env" ]
    grep -q 'OM_TARGET="https://opsmgr.dev210.example.com"' "$CFCTX_ROOT/dev210/context.env"
}

@test "init-env auto-discovers via CFCTX_OM_ENV_DIR (om-cli-<name>.yml)" {
    local om_dir="$BATS_TEST_TMPDIR/om-envs"
    mkdir -p "$om_dir"
    cat > "$om_dir/om-cli-tdc.yml" <<'EOF'
target: https://opsmgr.tdc.example.com
username: admin
password: via-om-cli-prefix
EOF

    CFCTX_OM_ENV_DIR="$om_dir" cfctx init-env tdc
    [ -f "$CFCTX_ROOT/tdc/context.env" ]
    grep -q 'OM_PASSWORD="via-om-cli-prefix"' "$CFCTX_ROOT/tdc/context.env"
}

@test "init-env honors custom CFCTX_OM_ENV_PATTERNS" {
    local om_dir="$BATS_TEST_TMPDIR/om-envs"
    mkdir -p "$om_dir"
    cat > "$om_dir/foundation-cdc.yaml" <<'EOF'
target: https://opsmgr.cdc.example.com
username: admin
password: custom-pattern
EOF

    CFCTX_OM_ENV_DIR="$om_dir" \
    CFCTX_OM_ENV_PATTERNS="foundation-NAME.yaml" \
        cfctx init-env cdc
    [ -f "$CFCTX_ROOT/cdc/context.env" ]
    grep -q 'OM_PASSWORD="custom-pattern"' "$CFCTX_ROOT/cdc/context.env"
}

@test "init-env refuses overwrite without --force, accepts with" {
    cfctx init-env foo
    run cfctx init-env foo
    [ "$status" -ne 0 ]

    local om_file="$BATS_TEST_TMPDIR/foo.yml"
    echo 'target: https://new.example.com' > "$om_file"
    run cfctx init-env foo --force --from-om "$om_file"
    [ "$status" -eq 0 ]
    grep -q 'OM_TARGET="https://new.example.com"' "$CFCTX_ROOT/foo/context.env"
}

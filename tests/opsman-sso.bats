#!/usr/bin/env bats
# OpsMan-layer SSO detection in `cfctx doctor --online`. Mock curl returns a
# UAA /login JSON; no real network.

setup() {
    export CFCTX_ROOT="$BATS_TEST_TMPDIR/cf-homes"
    mkdir -p "$CFCTX_ROOT"
    local bindir="$BATS_TEST_TMPDIR/bin"; mkdir -p "$bindir"
    # curl mock: emit $CFCTX_MOCK_CURL_BODY (exit 0) else exit 1.
    cat > "$bindir/curl" <<'MOCK'
#!/usr/bin/env bash
if [[ -n "${CFCTX_MOCK_CURL_BODY:-}" ]]; then printf '%s' "$CFCTX_MOCK_CURL_BODY"; exit 0; fi
exit 1
MOCK
    chmod +x "$bindir/curl"
    export PATH="$bindir:$PATH"
    unset CF_HOME
    # shellcheck disable=SC1091
    source "$BATS_TEST_DIRNAME/../cfctx.sh"
}

# passcode-only OpsMan UAA = SSO (password grant disabled)
SSO_LOGIN='{"prompts":{"passcode":["password","One Time Code"]}}'
# normal UAA still offers password
PW_LOGIN='{"prompts":{"username":["text","Email"],"password":["password","Password"],"passcode":["password","One Time Code"]}}'

seed() {  # seed <name> <extra context.env lines...>
    local name="$1"; shift
    mkdir -p "$CFCTX_ROOT/$name"
    { printf '%s\n' "$@"; } > "$CFCTX_ROOT/$name/context.env"
    chmod 600 "$CFCTX_ROOT/$name/context.env"
    export CF_HOME="$CFCTX_ROOT/$name"
}

@test "doctor --online flags OpsMan SSO with no OM_CLIENT_ID" {
    seed cdc 'export OM_TARGET="https://cdc.example.com"' 'export OM_SKIP_SSL_VALIDATION="true"'
    CFCTX_MOCK_CURL_BODY="$SSO_LOGIN" run cfctx doctor --online
    [ "$status" -ne 0 ]
    [[ "$output" == *"OpsMan UAA password login disabled (SSO) but OM_CLIENT_ID unset"* ]]
}

@test "doctor --online is happy when OpsMan SSO has an OM_CLIENT_ID" {
    seed cdc 'export OM_TARGET="https://cdc.example.com"' \
             'export OM_SKIP_SSL_VALIDATION="true"' \
             'export OM_CLIENT_ID="om-automation"'
    CFCTX_MOCK_CURL_BODY="$SSO_LOGIN" run cfctx doctor --online
    [[ "$output" == *"OpsMan UAA is SSO (password grant off); om/bosh use OM_CLIENT_ID=om-automation"* ]]
    [[ "$output" != *"will fail"* ]]
}

@test "doctor --online: password-login UAA is not flagged" {
    seed cdc 'export OM_TARGET="https://cdc.example.com"' 'export OM_SKIP_SSL_VALIDATION="true"'
    CFCTX_MOCK_CURL_BODY="$PW_LOGIN" run cfctx doctor --online
    [[ "$output" == *"OpsMan UAA password login enabled"* ]]
    [[ "$output" != *"will fail"* ]]
}

@test "doctor without --online does not probe OpsMan UAA" {
    seed cdc 'export OM_TARGET="https://cdc.example.com"'
    CFCTX_MOCK_CURL_BODY="$SSO_LOGIN" run cfctx doctor
    [[ "$output" != *"OpsMan UAA"* ]]
}

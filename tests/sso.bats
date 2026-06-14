#!/usr/bin/env bats
# CF SSO + client_credentials login dispatch. Mock `cf` logs invocations and
# simulates `cf api` / `cf auth ... --client-credentials` / `cf login --sso`
# writing a config.json so the token-cache path is exercised. No real network.

setup() {
    export CFCTX_ROOT="$BATS_TEST_TMPDIR/cf-homes"
    mkdir -p "$CFCTX_ROOT"
    local bindir="$BATS_TEST_TMPDIR/bin"
    mkdir -p "$bindir"
    cat > "$bindir/cf" <<'MOCKCF'
#!/usr/bin/env bash
: "${CF_HOME:=$HOME}"
mkdir -p "$CF_HOME/.cf"
cfg="$CF_HOME/.cf/config.json"
log="${CFCTX_MOCK_CF_LOG:-/tmp/cf-mock.log}"
printf '%s\n' "$*" >> "$log"
write_token() {
    local target; target=$(awk -F'"' '/"Target":/ {print $4; exit}' "$cfg" 2>/dev/null)
    printf '{"Target":"%s","AccessToken":"bearer fake-token","RefreshToken":"r","OrganizationFields":{"Name":""},"SpaceFields":{"Name":""},"Username":"%s"}\n' "$target" "${1:-user}" > "$cfg"
}
case "$1" in
    api)
        printf '{"Target":"%s","AccessToken":"","RefreshToken":"","OrganizationFields":{"Name":""},"SpaceFields":{"Name":""}}\n' "$2" > "$cfg" ;;
    auth)
        # cf auth <id> <secret> [--client-credentials]
        write_token "$2" ;;
    login)
        # cf login --sso  (mock: no passcode prompt, just succeed)
        write_token "sso-user" ;;
    target)
        target=$(awk -F'"' '/"Target":/ {print $4; exit}' "$cfg" 2>/dev/null)
        user=$(awk -F'"' '/"Username":/ {print $4; exit}' "$cfg" 2>/dev/null)
        echo "api endpoint: $target"; [[ -n "$user" ]] && echo "user: $user" ;;
    *) echo "mock cf: unhandled: $*" >&2; exit 2 ;;
esac
MOCKCF
    chmod +x "$bindir/cf"
    export PATH="$bindir:/usr/bin:/bin"
    export CFCTX_MOCK_CF_LOG="$BATS_TEST_TMPDIR/cf.log"
    : > "$CFCTX_MOCK_CF_LOG"
    unset CF_HOME CF_API CF_USERNAME CF_PASSWORD CF_ORG CF_SPACE
    unset CF_AUTH_MODE CF_UAA_CLIENT_ID CF_UAA_CLIENT_SECRET CF_SSO_CAPABLE
    unset CFCTX_FORCE_ACTOR CFCTX_NONINTERACTIVE CI CFCTX_NO_AUTO_LOGIN
    # shellcheck disable=SC1091
    source "$BATS_TEST_DIRNAME/../cfctx.sh"
}

seed_ctx() {  # seed_ctx <name> <extra context.env lines...>
    local name="$1"; shift
    mkdir -p "$CFCTX_ROOT/$name"
    {
        echo 'export CF_API="https://api.sys.x.example.com"'
        echo 'export UAA_URL="https://uaa.sys.x.example.com"'
        printf '%s\n' "$@"
    } > "$CFCTX_ROOT/$name/context.env"
    chmod 600 "$CFCTX_ROOT/$name/context.env"
}

@test "client mode logs in with --client-credentials" {
    seed_ctx bot 'export CF_AUTH_MODE="client"' \
                 'export CF_UAA_CLIENT_ID="cfctx-bot"' \
                 'export CF_UAA_CLIENT_SECRET="s3cr3t"'
    run cfctx target bot
    [ "$status" -eq 0 ]
    grep -q '^auth cfctx-bot s3cr3t --client-credentials' "$CFCTX_MOCK_CF_LOG"
    grep -q 'fake-token' "$CFCTX_ROOT/bot/.cf/config.json"
}

@test "client mode with missing secret reports, does not crash switch" {
    seed_ctx bot 'export CF_AUTH_MODE="client"' 'export CF_UAA_CLIENT_ID="cfctx-bot"'
    run cfctx target bot
    [ "$status" -eq 0 ]
    [[ "$output" == *"CF_UAA_CLIENT_ID/SECRET unset"* ]]
    ! grep -q '^auth ' "$CFCTX_MOCK_CF_LOG"
}

@test "sso mode (human) runs cf login --sso and prints passcode URL" {
    seed_ctx dev 'export CF_AUTH_MODE="sso"'
    run env CFCTX_FORCE_ACTOR=human bash -c \
        'source "'"$BATS_TEST_DIRNAME"'/../cfctx.sh"; cfctx target dev'
    [ "$status" -eq 0 ]
    grep -q '^login --sso' "$CFCTX_MOCK_CF_LOG"
    [[ "$output" == *"uaa.sys.x.example.com/passcode"* ]]
}

@test "sso mode under automation errors instead of hanging" {
    seed_ctx dev 'export CF_AUTH_MODE="sso"'
    run env CFCTX_FORCE_ACTOR=automation bash -c \
        'source "'"$BATS_TEST_DIRNAME"'/../cfctx.sh"; cfctx target dev'
    [ "$status" -eq 0 ]
    [[ "$output" == *"SSO-only and this is non-interactive"* ]]
    ! grep -q '^login ' "$CFCTX_MOCK_CF_LOG"
}

@test "cfctx sso forces login --sso even when mode is client" {
    seed_ctx bot 'export CF_AUTH_MODE="client"' \
                 'export CF_UAA_CLIENT_ID="cfctx-bot"' \
                 'export CF_UAA_CLIENT_SECRET="s3cr3t"'
    run env CFCTX_FORCE_ACTOR=human bash -c \
        'source "'"$BATS_TEST_DIRNAME"'/../cfctx.sh"; cfctx sso bot'
    [ "$status" -eq 0 ]
    grep -q '^login --sso' "$CFCTX_MOCK_CF_LOG"
    ! grep -q -- '--client-credentials' "$CFCTX_MOCK_CF_LOG"
    # The CF_HOME fix directs cf's token store to the per-context dir; the mock
    # writes the fake token to $CF_HOME/.cf/config.json, so it must land here.
    grep -q 'fake-token' "$CFCTX_ROOT/bot/.cf/config.json"
}

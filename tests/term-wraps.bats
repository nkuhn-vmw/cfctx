#!/usr/bin/env bats
# TERM wraps for bosh/cf on exotic terminals (Ghostty/Kitty/Alacritty).

setup() {
    export CFCTX_ROOT="$BATS_TEST_TMPDIR/cf-homes"
    mkdir -p "$CFCTX_ROOT"

    # Fake bosh + cf binaries in PATH so command -v succeeds.
    local bindir="$BATS_TEST_TMPDIR/bin"
    mkdir -p "$bindir"
    # Mock bosh / cf — record the TERM they were invoked with.
    cat > "$bindir/bosh" <<'BOSH'
#!/usr/bin/env bash
printf 'bosh-invoked-with-TERM=%s\n' "${TERM:-(unset)}"
BOSH
    cat > "$bindir/cf" <<'CF'
#!/usr/bin/env bash
printf 'cf-invoked-with-TERM=%s\n' "${TERM:-(unset)}"
CF
    chmod +x "$bindir/bosh" "$bindir/cf"
    export PATH="$bindir:/usr/bin:/bin"

    unset CF_HOME CFCTX_NO_AUTO_LOGIN CFCTX_NO_TERM_WRAPS CFCTX_SAFE_TERM
    # shellcheck disable=SC1091
    source "$BATS_TEST_DIRNAME/../cfctx.sh"
}

teardown() {
    # Always clean up wraps so one test's state doesn't leak into another.
    _cfctx_uninstall_term_wraps 2>/dev/null || true
}

@test "_cfctx_term_is_exotic: matches known-problematic TERMs" {
    TERM=xterm-ghostty     run _cfctx_term_is_exotic; [ "$status" -eq 0 ]
    TERM=xterm-kitty       run _cfctx_term_is_exotic; [ "$status" -eq 0 ]
    TERM=alacritty         run _cfctx_term_is_exotic; [ "$status" -eq 0 ]
    TERM=alacritty-direct  run _cfctx_term_is_exotic; [ "$status" -eq 0 ]
}

@test "_cfctx_term_is_exotic: does NOT match common TERMs" {
    TERM=xterm-256color    run _cfctx_term_is_exotic; [ "$status" -ne 0 ]
    TERM=screen-256color   run _cfctx_term_is_exotic; [ "$status" -ne 0 ]
    TERM=tmux-256color     run _cfctx_term_is_exotic; [ "$status" -ne 0 ]
    TERM=xterm             run _cfctx_term_is_exotic; [ "$status" -ne 0 ]
    TERM=linux             run _cfctx_term_is_exotic; [ "$status" -ne 0 ]
    TERM=                  run _cfctx_term_is_exotic; [ "$status" -ne 0 ]
}

@test "install: on xterm-ghostty, wraps both bosh and cf" {
    TERM=xterm-ghostty _cfctx_install_term_wraps
    declare -f bosh >/dev/null
    declare -f cf   >/dev/null
    declare -f bosh | grep -q __cfctx_term_wrap__
    declare -f cf   | grep -q __cfctx_term_wrap__
}

@test "install: on xterm-256color, wraps neither" {
    TERM=xterm-256color _cfctx_install_term_wraps
    ! declare -f bosh >/dev/null
    ! declare -f cf   >/dev/null
}

@test "install: CFCTX_NO_TERM_WRAPS=1 disables even on ghostty" {
    TERM=xterm-ghostty CFCTX_NO_TERM_WRAPS=1 _cfctx_install_term_wraps
    ! declare -f bosh >/dev/null
    ! declare -f cf   >/dev/null
}

@test "wrap: bosh invocation receives CFCTX_SAFE_TERM" {
    TERM=xterm-ghostty _cfctx_install_term_wraps
    run bosh
    [ "$status" -eq 0 ]
    [[ "$output" == *"bosh-invoked-with-TERM=xterm-256color"* ]]
}

@test "wrap: CFCTX_SAFE_TERM override is honoured at call time" {
    TERM=xterm-ghostty _cfctx_install_term_wraps
    CFCTX_SAFE_TERM=xterm run bosh
    [[ "$output" == *"bosh-invoked-with-TERM=xterm"* ]]
}

@test "wrap: cf invocation receives CFCTX_SAFE_TERM" {
    TERM=xterm-ghostty _cfctx_install_term_wraps
    run cf
    [[ "$output" == *"cf-invoked-with-TERM=xterm-256color"* ]]
}

@test "wrap: uninstall removes ONLY our wraps, not user-defined" {
    TERM=xterm-ghostty _cfctx_install_term_wraps
    declare -f bosh >/dev/null

    # Simulate user redefining bosh AFTER the wrap was installed (last def wins).
    bosh() { echo "user-defined-bosh"; }

    _cfctx_uninstall_term_wraps

    # User definition should still be active — uninstall should have skipped it
    # because the marker is gone.
    [ "$(bosh)" = "user-defined-bosh" ]

    # Clean up for next test.
    unset -f bosh
}

@test "install: does NOT clobber a pre-existing user-defined bosh" {
    # User defined bosh before cfctx got involved.
    bosh() { echo "user-bosh"; }

    TERM=xterm-ghostty _cfctx_install_term_wraps

    # Our install should have detected the existing function and skipped.
    [ "$(bosh)" = "user-bosh" ]
    ! declare -f bosh | grep -q __cfctx_term_wrap__

    unset -f bosh
}

@test "install: idempotent (re-run is safe)" {
    TERM=xterm-ghostty _cfctx_install_term_wraps
    TERM=xterm-ghostty _cfctx_install_term_wraps
    TERM=xterm-ghostty _cfctx_install_term_wraps
    declare -f bosh | grep -q __cfctx_term_wrap__
    # Call still works cleanly.
    run bosh
    [[ "$output" == *"xterm-256color"* ]]
}

@test "cfctx clear uninstalls term wraps" {
    TERM=xterm-ghostty _cfctx_install_term_wraps
    declare -f bosh >/dev/null

    cfctx clear

    ! declare -f bosh >/dev/null
    ! declare -f cf   >/dev/null
}

@test "switch installs wraps on ghostty terminals" {
    TERM=xterm-ghostty cfctx mycontext --create --no-enrich --no-login >/dev/null 2>&1
    declare -f bosh | grep -q __cfctx_term_wrap__
    declare -f cf   | grep -q __cfctx_term_wrap__
}

@test "switch does NOT install wraps on standard terminals" {
    TERM=xterm-256color cfctx mycontext --create --no-enrich --no-login >/dev/null 2>&1
    ! declare -f bosh >/dev/null
    ! declare -f cf   >/dev/null
}

@test "doctor reports wrap status" {
    TERM=xterm-ghostty _cfctx_install_term_wraps
    TERM=xterm-ghostty run cfctx doctor
    [[ "$output" == *"TERM wraps active"* ]]
}

@test "doctor reports 'not needed' on standard terminals" {
    TERM=xterm-256color run cfctx doctor
    [[ "$output" == *"TERM wraps not needed"* ]]
}

@test "doctor reports opt-out clearly when CFCTX_NO_TERM_WRAPS=1" {
    TERM=xterm-ghostty CFCTX_NO_TERM_WRAPS=1 run cfctx doctor
    [[ "$output" == *"CFCTX_NO_TERM_WRAPS is set"* ]]
}

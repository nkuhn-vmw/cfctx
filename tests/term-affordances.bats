#!/usr/bin/env bats
# Terminal affordances: OSC 2 window title, OSC 12 cursor color, OSC 8 hyperlinks.

setup() {
    export CFCTX_ROOT="$BATS_TEST_TMPDIR/cf-homes"
    mkdir -p "$CFCTX_ROOT"
    export PATH="$BATS_TEST_TMPDIR/nocf:/usr/bin:/bin"
    mkdir -p "$BATS_TEST_TMPDIR/nocf"
    unset CF_HOME CFCTX_NO_TERM_AFFORDANCES CFCTX_FORCE_TERM_AFFORDANCES
    # shellcheck disable=SC1091
    source "$BATS_TEST_DIRNAME/../cfctx.sh"
}

# ---- _cfctx_color_hex ------------------------------------------------------

@test "color_hex returns the right hex for every known name" {
    [ "$(_cfctx_color_hex red)"     = "#ff5555" ]
    [ "$(_cfctx_color_hex green)"   = "#50fa7b" ]
    [ "$(_cfctx_color_hex yellow)"  = "#f1fa8c" ]
    [ "$(_cfctx_color_hex blue)"    = "#6272a4" ]
    [ "$(_cfctx_color_hex magenta)" = "#ff79c6" ]
    [ "$(_cfctx_color_hex cyan)"    = "#8be9fd" ]
    [ "$(_cfctx_color_hex white)"   = "#f8f8f2" ]
    [ "$(_cfctx_color_hex black)"   = "#282a36" ]
}

@test "color_hex returns nonzero for unknown names" {
    run _cfctx_color_hex purple
    [ "$status" -ne 0 ]
}

# ---- _cfctx_term_affordances_enabled --------------------------------------

@test "affordances disabled by default when stdout is not a TTY" {
    # In bats, stdout is captured — not a TTY.
    run _cfctx_term_affordances_enabled
    [ "$status" -ne 0 ]
}

@test "affordances enabled when CFCTX_FORCE_TERM_AFFORDANCES=1" {
    CFCTX_FORCE_TERM_AFFORDANCES=1 run _cfctx_term_affordances_enabled
    [ "$status" -eq 0 ]
}

@test "affordances disabled via CFCTX_NO_TERM_AFFORDANCES=1 even when forced" {
    CFCTX_NO_TERM_AFFORDANCES=1 CFCTX_FORCE_TERM_AFFORDANCES=1 \
        run _cfctx_term_affordances_enabled
    [ "$status" -ne 0 ]
}

# ---- _cfctx_emit_terminal_affordances --------------------------------------

@test "emit: writes OSC 2 with cfctx:<name> title" {
    mkdir -p "$CFCTX_ROOT/tdc"
    output=$(CFCTX_FORCE_TERM_AFFORDANCES=1 _cfctx_emit_terminal_affordances tdc "$CFCTX_ROOT/tdc")
    # Expect ESC ] 2 ; cfctx:tdc BEL
    [[ "$output" == *$'\033]2;cfctx:tdc\007'* ]]
}

@test "emit: no OSC 12 cursor color when .cfctx-color absent" {
    mkdir -p "$CFCTX_ROOT/tdc"
    output=$(CFCTX_FORCE_TERM_AFFORDANCES=1 _cfctx_emit_terminal_affordances tdc "$CFCTX_ROOT/tdc")
    [[ "$output" != *$'\033]12;'* ]]
}

@test "emit: OSC 12 uses hex from .cfctx-color when present" {
    mkdir -p "$CFCTX_ROOT/prod"
    echo "red" > "$CFCTX_ROOT/prod/.cfctx-color"
    output=$(CFCTX_FORCE_TERM_AFFORDANCES=1 _cfctx_emit_terminal_affordances prod "$CFCTX_ROOT/prod")
    [[ "$output" == *$'\033]12;#ff5555\007'* ]]
}

@test "emit: unknown color in .cfctx-color skips the OSC 12 (no crash)" {
    mkdir -p "$CFCTX_ROOT/weird"
    echo "chartreuse" > "$CFCTX_ROOT/weird/.cfctx-color"
    output=$(CFCTX_FORCE_TERM_AFFORDANCES=1 _cfctx_emit_terminal_affordances weird "$CFCTX_ROOT/weird")
    [[ "$output" != *$'\033]12;'* ]]
    # Title still gets emitted.
    [[ "$output" == *$'\033]2;cfctx:weird\007'* ]]
}

@test "emit: silent when CFCTX_NO_TERM_AFFORDANCES=1" {
    mkdir -p "$CFCTX_ROOT/tdc"
    output=$(CFCTX_NO_TERM_AFFORDANCES=1 CFCTX_FORCE_TERM_AFFORDANCES=1 \
              _cfctx_emit_terminal_affordances tdc "$CFCTX_ROOT/tdc")
    [ -z "$output" ]
}

@test "emit: silent when stdout isn't a TTY and not forced" {
    mkdir -p "$CFCTX_ROOT/tdc"
    output=$(_cfctx_emit_terminal_affordances tdc "$CFCTX_ROOT/tdc")
    [ -z "$output" ]
}

# ---- _cfctx_reset_terminal_affordances -------------------------------------

@test "reset: emits empty title + OSC 112 (cursor default)" {
    output=$(CFCTX_FORCE_TERM_AFFORDANCES=1 _cfctx_reset_terminal_affordances)
    [[ "$output" == *$'\033]2;\007'* ]]
    [[ "$output" == *$'\033]112\007'* ]]
}

@test "reset: silent when CFCTX_NO_TERM_AFFORDANCES=1" {
    output=$(CFCTX_NO_TERM_AFFORDANCES=1 CFCTX_FORCE_TERM_AFFORDANCES=1 \
              _cfctx_reset_terminal_affordances)
    [ -z "$output" ]
}

# ---- OSC 8 hyperlink helper + listing -------------------------------------

@test "osc8_link wraps URL with OSC 8 when affordances enabled" {
    output=$(CFCTX_FORCE_TERM_AFFORDANCES=1 _cfctx_osc8_link "https://api.tdc.example.com")
    [[ "$output" == *$'\033]8;;https://api.tdc.example.com\007'*$'\033]8;;\007'* ]]
}

@test "osc8_link falls back to plain text when piped" {
    output=$(_cfctx_osc8_link "https://api.tdc.example.com")
    [ "$output" = "https://api.tdc.example.com" ]
}

@test "osc8_link accepts distinct text vs url" {
    output=$(CFCTX_FORCE_TERM_AFFORDANCES=1 _cfctx_osc8_link "https://x" "click here")
    [[ "$output" == *"click here"* ]]
    [[ "$output" == *$'\033]8;;https://x\007'* ]]
}

@test "listing wraps URLs as OSC 8 links when affordances enabled" {
    mkdir -p "$CFCTX_ROOT/tdc"
    cat > "$CFCTX_ROOT/tdc/context.env" <<'EOF'
export CF_API="https://api.sys.tdc.example.com"
EOF
    chmod 600 "$CFCTX_ROOT/tdc/context.env"

    output=$(CFCTX_FORCE_TERM_AFFORDANCES=1 cfctx)
    # The URL should be wrapped with OSC 8 begin + end.
    [[ "$output" == *$'\033]8;;https://api.sys.tdc.example.com\007'* ]]
    [[ "$output" == *$'\033]8;;\007'* ]]
}

@test "listing without TTY prints URLs as plain text (no escape bytes)" {
    mkdir -p "$CFCTX_ROOT/tdc"
    cat > "$CFCTX_ROOT/tdc/context.env" <<'EOF'
export CF_API="https://api.sys.tdc.example.com"
EOF
    chmod 600 "$CFCTX_ROOT/tdc/context.env"

    output=$(cfctx)   # no force; stdout is captured pipe
    [[ "$output" != *$'\033]8;;'* ]]
    [[ "$output" == *"https://api.sys.tdc.example.com"* ]]
}

# ---- Integration with switch + clear ---------------------------------------

@test "switch emits terminal affordances (window title)" {
    output=$(CFCTX_FORCE_TERM_AFFORDANCES=1 cfctx mycontext --create --no-enrich --no-login 2>&1)
    [[ "$output" == *$'\033]2;cfctx:mycontext\007'* ]]
}

@test "switch emits OSC 12 when context has a color tag" {
    mkdir -p "$CFCTX_ROOT/prod"
    echo "red" > "$CFCTX_ROOT/prod/.cfctx-color"
    touch "$CFCTX_ROOT/prod/context.env"
    chmod 600 "$CFCTX_ROOT/prod/context.env"

    output=$(CFCTX_FORCE_TERM_AFFORDANCES=1 cfctx prod 2>&1)
    [[ "$output" == *$'\033]12;#ff5555\007'* ]]
}

@test "clear resets the title + cursor color" {
    output=$(CFCTX_FORCE_TERM_AFFORDANCES=1 cfctx clear 2>&1)
    [[ "$output" == *$'\033]2;\007'* ]]
    [[ "$output" == *$'\033]112\007'* ]]
}

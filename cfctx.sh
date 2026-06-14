# cfctx — per-shell CF CLI context switcher
#
# Install:
#   1. Save this file somewhere, e.g. ~/.cfctx.sh
#   2. Add to ~/.zshrc (or ~/.bashrc):   source ~/.cfctx.sh
#   3. Open new terminals and use:       cfctx <name>
#
# Each shell gets its own CF_HOME, so logins / targets / tokens never
# collide across terminals. Contexts live under ~/.cf-homes/<name>/.
#
# Each context may optionally carry a `context.env` file with credentials
# for `om`, `bosh`, `credhub`, etc. The file is sourced on every switch.
# It lives inside the context directory with mode 0600 and is never
# meant to be committed to any repo.

CFCTX_VERSION="0.4.0"

cfctx() {
    local CFCTX_ROOT="${CFCTX_ROOT:-$HOME/.cf-homes}"

    if ! mkdir -p "$CFCTX_ROOT" 2>/dev/null; then
        echo "cfctx: cannot create root '$CFCTX_ROOT' — set CFCTX_ROOT to a writable path" >&2
        return 1
    fi

    # No args → list all foundations with the current one highlighted (kubectx-style).
    # Explicit `cfctx status` still prints the current-context details.
    if [[ $# -eq 0 ]]; then
        _cfctx_cmd_ls "$CFCTX_ROOT"
        return $?
    fi

    local cmd="$1"
    case "$cmd" in

        status|current)
            _cfctx_cmd_status
            ;;

        ls|list)
            _cfctx_cmd_ls "$CFCTX_ROOT"
            ;;

        rm|remove|delete)
            shift
            _cfctx_cmd_rm "$CFCTX_ROOT" "$@"
            ;;

        cp|copy)
            shift
            _cfctx_cmd_cp "$CFCTX_ROOT" "$@"
            ;;

        mv|rename)
            shift
            _cfctx_cmd_mv "$CFCTX_ROOT" "$@"
            ;;

        edit)
            shift
            _cfctx_cmd_edit "$CFCTX_ROOT" "$@"
            ;;

        env|show-env)
            shift
            _cfctx_cmd_env "$CFCTX_ROOT" "$@"
            ;;

        init-env)
            shift
            _cfctx_cmd_init_env "$CFCTX_ROOT" "$@"
            ;;

        enrich)
            shift
            _cfctx_cmd_enrich "$CFCTX_ROOT" "$@"
            ;;

        target|adopt)
            shift
            _cfctx_cmd_target "$CFCTX_ROOT" "$@"
            ;;

        pick)
            shift
            _cfctx_cmd_pick "$CFCTX_ROOT" "$@"
            ;;

        uaa-login|uaac-login)
            shift
            _cfctx_cmd_uaa_login "$@"
            ;;

        doctor)
            shift
            _cfctx_cmd_doctor "$CFCTX_ROOT" "$@"
            ;;

        prompt)
            shift
            _cfctx_cmd_prompt "$@"
            ;;

        color)
            shift
            _cfctx_cmd_color "$CFCTX_ROOT" "$@"
            ;;

        clear|unset)
            unset CF_HOME CF_API CF_ORG CF_SPACE CF_USERNAME CF_PASSWORD \
                  CF_AUTH_MODE CF_UAA_CLIENT_ID CF_UAA_CLIENT_SECRET CF_SSO_CAPABLE
            # Best-effort: clear common Tanzu env vars we may have sourced.
            unset OM_TARGET OM_USERNAME OM_PASSWORD OM_CLIENT_ID OM_CLIENT_SECRET OM_SKIP_SSL_VALIDATION \
                  OM_DECRYPTION_PASSPHRASE OM_CONNECT_TIMEOUT OM_REQUEST_TIMEOUT OM_TRACE OM_VARS_ENV OM_CA_CERT \
                  OM_UAA_URL
            unset UAA_URL UAA_ADMIN_CLIENT UAA_ADMIN_CLIENT_SECRET
            unset BOSH_ENVIRONMENT BOSH_CLIENT BOSH_CLIENT_SECRET BOSH_CA_CERT BOSH_DEPLOYMENT \
                  BOSH_GW_HOST BOSH_GW_USER BOSH_GW_PRIVATE_KEY
            unset CREDHUB_SERVER CREDHUB_CLIENT CREDHUB_SECRET CREDHUB_CA_CERT
            _cfctx_uninstall_term_wraps
            _cfctx_reset_terminal_affordances
            echo "CF_HOME and related Tanzu env unset in this shell"
            ;;

        version|--version|-v)
            echo "cfctx $CFCTX_VERSION"
            ;;

        help|-h|--help)
            _cfctx_cmd_help
            ;;

        *)
            # Bare name — route to `target` so `cfctx tdc` = `cfctx target tdc`
            # (init-env if missing, switch, source env, auto-login to CF).
            _cfctx_cmd_target "$CFCTX_ROOT" "$@"
            ;;
    esac
}

# -----------------------------------------------------------------------------
# Internal helpers (prefixed `_cfctx_`; treat as private).
# -----------------------------------------------------------------------------

_cfctx_valid_name() {
    local name="$1"
    if [[ -z "$name" ]]; then
        echo "cfctx: context name is required" >&2
        return 1
    fi
    case "$name" in
        -*|.*|*/*|*' '*|*$'\t'*)
            echo "cfctx: invalid context name '$name' (no leading -/., no slashes, no whitespace)" >&2
            return 1
            ;;
    esac
    return 0
}

_cfctx_source_env() {
    # Source the env file safely: enforce 0600 before reading, isolate shell options.
    local env_file="$1"
    [[ -f "$env_file" ]] || return 0

    # Enforce 0600 — refuse to source a world-readable creds file.
    # GNU stat (Linux) uses -c; BSD stat (macOS) uses -f. Try GNU first
    # because `stat -f '%Lp'` on GNU silently dumps filesystem info to
    # stdout with exit code 1 — that would pollute $perms on the || path.
    local perms
    if perms=$(stat -c '%a' "$env_file" 2>/dev/null); then :
    elif perms=$(stat -f '%Lp' "$env_file" 2>/dev/null); then :
    else perms=""; fi

    if [[ -n "$perms" && "$perms" != "600" && "$perms" != "400" ]]; then
        echo "cfctx: refusing to source $env_file — perms are $perms, expected 600" >&2
        echo "       fix with: chmod 600 \"$env_file\"" >&2
        return 1
    fi

    # Auto-export anything set in the file.
    set -a
    # shellcheck disable=SC1090
    . "$env_file"
    set +a
    return 0
}

_cfctx_cmd_status() {
    if [[ -z "${CF_HOME:-}" || "$CF_HOME" == "$HOME" ]]; then
        echo "No context set in this shell (using default \$HOME)"
        return 0
    fi
    local name
    name=$(basename "$CF_HOME")
    echo "Context: $name"
    echo "CF_HOME=$CF_HOME"
    if [[ -f "$CF_HOME/context.env" ]]; then
        echo "Env file: $CF_HOME/context.env (sourced on switch)"
    fi
    if [[ -f "$CF_HOME/.cf/config.json" ]] && command -v cf >/dev/null 2>&1; then
        cf target 2>/dev/null | sed 's/^/  /'
    fi
}

_cfctx_cmd_ls() {
    local root="$1"
    if [[ ! -d "$root" ]] || [[ -z "$(ls -A "$root" 2>/dev/null)" ]]; then
        echo "No contexts yet. Create one with:"
        echo "  cfctx <name> --cf-api https://api.sys.<foundation>"
        return 0
    fi

    # Color only when writing to a terminal.
    local c_curr="" c_dim="" c_off=""
    if [[ -t 1 ]]; then
        c_curr=$'\033[1;36m'   # bold cyan: current context
        c_dim=$'\033[2m'        # dim: target URL + [env] tag
        c_off=$'\033[0m'
    fi

    local dir name is_current has_env target_url
    for dir in "$root"/*/; do
        [[ -d "$dir" ]] || continue
        name=$(basename "$dir")
        is_current=0
        has_env=0
        target_url=""
        [[ "${CF_HOME:-}" == "${dir%/}" ]] && is_current=1
        if [[ -f "${dir}context.env" ]]; then
            has_env=1
            target_url=$(_cfctx_read_env_var "${dir}context.env" CF_API)
            [[ -z "$target_url" ]] && target_url=$(_cfctx_read_env_var "${dir}context.env" OM_TARGET)
        fi

        # Marker + name, current highlighted.
        if (( is_current )); then
            printf '%s* %s%s' "$c_curr" "$name" "$c_off"
        else
            printf '  %s' "$name"
        fi
        (( has_env )) && printf ' %s[env]%s' "$c_dim" "$c_off"
        if [[ -n "$target_url" ]]; then
            # Wrap the URL as an OSC 8 clickable hyperlink in TTYs that
            # support it (Ghostty, iTerm2, WezTerm, tmux, recent gnome-terminal).
            printf '  %s%s%s' "$c_dim" "$(_cfctx_osc8_link "$target_url")" "$c_off"
        fi
        printf '\n'
    done
}

# Extract the value of an env-file variable (`export KEY="V"` or `KEY=V`)
# without sourcing the file. Returns empty if not found or commented out.
_cfctx_read_env_var() {
    local env_file="$1" key="$2"
    [[ -f "$env_file" ]] || return 0
    awk -v k="$key" '
        /^[[:space:]]*#/ { next }
        {
            line = $0
            sub(/^[[:space:]]*export[[:space:]]+/, "", line)
            if (match(line, "^" k "=")) {
                val = substr(line, length(k) + 2)
                # Strip surrounding quotes.
                if (val ~ /^".*"$/) { val = substr(val, 2, length(val) - 2) }
                else if (val ~ /^'\''.*'\''$/) { val = substr(val, 2, length(val) - 2) }
                print val
                exit
            }
        }
    ' "$env_file"
}

_cfctx_cmd_rm() {
    local root="$1" name="$2"
    _cfctx_valid_name "$name" || return 1
    local target="$root/$name"
    if [[ ! -d "$target" ]]; then
        echo "Not found: $name" >&2
        return 1
    fi
    printf "Delete context '%s' and all its state (incl. creds)? [y/N] " "$name"
    local reply
    read -r reply
    if [[ "$reply" == "y" || "$reply" == "Y" ]]; then
        rm -rf "$target"
        echo "Deleted: $name"
        [[ "${CF_HOME:-}" == "$target" ]] && unset CF_HOME
    else
        echo "Cancelled."
    fi
}

_cfctx_cmd_cp() {
    local root="$1" src="$2" dst="$3"
    _cfctx_valid_name "$src" || return 1
    _cfctx_valid_name "$dst" || return 1
    local src_dir="$root/$src" dst_dir="$root/$dst"
    [[ -d "$src_dir" ]] || { echo "Not found: $src" >&2; return 1; }
    [[ -e "$dst_dir" ]] && { echo "Already exists: $dst" >&2; return 1; }
    cp -R "$src_dir" "$dst_dir"
    [[ -f "$dst_dir/context.env" ]] && chmod 600 "$dst_dir/context.env"
    echo "Copied $src → $dst"
}

_cfctx_cmd_mv() {
    local root="$1" old="$2" new="$3"
    _cfctx_valid_name "$old" || return 1
    _cfctx_valid_name "$new" || return 1
    local old_dir="$root/$old" new_dir="$root/$new"
    [[ -d "$old_dir" ]] || { echo "Not found: $old" >&2; return 1; }
    [[ -e "$new_dir" ]] && { echo "Already exists: $new" >&2; return 1; }
    mv "$old_dir" "$new_dir"
    [[ "${CF_HOME:-}" == "$old_dir" ]] && export CF_HOME="$new_dir"
    echo "Renamed $old → $new"
}

_cfctx_cmd_edit() {
    local root="$1" name="${2:-}"
    if [[ -z "$name" ]]; then
        if [[ -n "${CF_HOME:-}" && "$CF_HOME" != "$HOME" && "$CF_HOME" == "$root"/* ]]; then
            name=$(basename "$CF_HOME")
        else
            echo "Usage: cfctx edit <name>  (or switch into a context first)" >&2
            return 1
        fi
    fi
    _cfctx_valid_name "$name" || return 1
    local ctx_dir="$root/$name" env_file="$root/$name/context.env"
    mkdir -p "$ctx_dir"
    chmod 700 "$ctx_dir" 2>/dev/null || true
    if [[ ! -f "$env_file" ]]; then
        _cfctx_write_template "$env_file" "$name"
    fi
    chmod 600 "$env_file"
    "${EDITOR:-vi}" "$env_file"
    chmod 600 "$env_file"
    echo "Saved $env_file (0600). Re-source with: cfctx $name"
}

_cfctx_cmd_init_env() {
    local root="$1"; shift
    local name="" om_file="" force=0 no_enrich=0
    # Parse flags.
    while (( $# )); do
        case "$1" in
            --from-om)
                om_file="${2:-}"
                shift 2 || { echo "cfctx: --from-om needs a file path" >&2; return 1; }
                ;;
            --force|-f)
                force=1
                shift
                ;;
            --no-enrich)
                no_enrich=1
                shift
                ;;
            -h|--help)
                cat <<'EOF'
Usage: cfctx init-env <name> [--from-om <file>] [--force] [--no-enrich]

Stamp a context.env for <name> (mode 0600). Does NOT switch into the context.

Options:
  --from-om <file>   Pre-fill OM_* values from an `om -e` YAML env file.
                     (Or set CFCTX_OM_ENV_DIR and we'll auto-discover
                     $CFCTX_OM_ENV_DIR/<name>.yml.)
  --force            Overwrite an existing context.env.
  --no-enrich        Skip the optional `om bosh-env` + CF_API detection step.
                     (Auto-skipped if om/jq aren't installed.)
EOF
                return 0
                ;;
            -*)
                echo "cfctx: unknown flag '$1'" >&2
                return 1
                ;;
            *)
                if [[ -z "$name" ]]; then name="$1"
                else echo "cfctx: unexpected arg '$1'" >&2; return 1
                fi
                shift
                ;;
        esac
    done

    _cfctx_valid_name "$name" || return 1
    local ctx_dir="$root/$name" env_file="$root/$name/context.env"
    mkdir -p "$ctx_dir"
    chmod 700 "$ctx_dir" 2>/dev/null || true

    if [[ -f "$env_file" && $force -eq 0 ]]; then
        echo "Already exists: $env_file  (use --force to overwrite)" >&2
        return 1
    fi

    # Auto-discover om env file if CFCTX_OM_ENV_DIR is set and --from-om not given.
    # Delegated to helper so both init-env and enrich use the same logic.
    if [[ -z "$om_file" && -n "${CFCTX_OM_ENV_DIR:-}" ]]; then
        local _discovered
        if _discovered=$(_cfctx_discover_om_file "$CFCTX_OM_ENV_DIR" "$name"); then
            om_file="$_discovered"
            echo "  auto-discovered om env: $om_file"
        fi
    fi

    if [[ -n "$om_file" ]]; then
        if [[ ! -f "$om_file" ]]; then
            echo "cfctx: om env file not found: $om_file" >&2
            return 1
        fi
        _cfctx_write_template_from_om "$env_file" "$name" "$om_file" "$ctx_dir" || return 1
    else
        _cfctx_write_template "$env_file" "$name"
    fi

    chmod 600 "$env_file"
    echo "Stamped: $env_file (0600)"

    # Query Ops Manager to auto-populate BOSH_* and CF_API (only when we
    # have a real om source — blank templates have no way to reach OM).
    if [[ -n "$om_file" && $no_enrich -eq 0 ]]; then
        _cfctx_enrich_from_om "$env_file" "$om_file"
    fi

    echo "Edit with: cfctx edit $name"
}

# Re-query Ops Manager and refresh BOSH_*/CF_API in an existing context.env.
# Source om yaml comes from the `# cfctx:om-source:` marker written at init,
# falling back to CFCTX_OM_ENV_DIR auto-discovery.
_cfctx_cmd_enrich() {
    local root="$1" name="${2:-}"
    if [[ -z "$name" ]]; then
        if [[ -n "${CF_HOME:-}" && "$CF_HOME" == "$root"/* ]]; then
            name=$(basename "$CF_HOME")
        else
            echo "Usage: cfctx enrich <name>  (or run from inside the context)" >&2
            return 1
        fi
    fi
    _cfctx_valid_name "$name" || return 1

    local env_file="$root/$name/context.env"
    if [[ ! -f "$env_file" ]]; then
        echo "cfctx: no context.env for '$name' — run 'cfctx $name' first" >&2
        return 1
    fi

    # Find the om source: marker first, then auto-discovery.
    local om_file
    om_file=$(awk -F': ' '/^# cfctx:om-source:/ {sub(/^[[:space:]]+/, "", $2); print $2; exit}' "$env_file")
    if [[ -z "$om_file" || ! -f "$om_file" ]]; then
        if [[ -n "${CFCTX_OM_ENV_DIR:-}" ]]; then
            local _discovered
            if _discovered=$(_cfctx_discover_om_file "$CFCTX_OM_ENV_DIR" "$name"); then
                om_file="$_discovered"
            fi
        fi
    fi

    if [[ -z "$om_file" || ! -f "$om_file" ]]; then
        echo "cfctx: can't locate an om yaml for '$name' (no marker and no CFCTX_OM_ENV_DIR hit)" >&2
        return 1
    fi

    echo "Enriching $name from $om_file ..."
    _cfctx_enrich_from_om "$env_file" "$om_file"
    echo "Done. Re-source with: cfctx $name"
}

# Run `om` with all OM_* env vars unset so that only the `-e <file>` and
# command-line flags apply. Prevents leakage of OM_TARGET etc. from a
# previously-active cfctx context (which would otherwise steer om at the
# wrong foundation per om's env>yaml precedence). Subshell scope — the
# caller's env is unchanged.
_cfctx_om_clean() {
    (
        unset OM_TARGET OM_USERNAME OM_PASSWORD OM_CLIENT_ID OM_CLIENT_SECRET \
              OM_SKIP_SSL_VALIDATION OM_DECRYPTION_PASSPHRASE OM_CA_CERT \
              OM_CONNECT_TIMEOUT OM_REQUEST_TIMEOUT OM_TRACE OM_VARS_ENV
        om "$@"
    )
}

# Locate a matching om env file under $dir for context $name. Prints the
# path and returns 0 on success; returns 1 if nothing matches.
#
# Works in both bash and zsh. In zsh, unquoted `$var` does NOT word-split
# by default (differs from bash) — so we use arrays explicitly. In zsh,
# `${=var}` forces word-split; in bash, the plain `($var)` splits naturally.
#
# Custom patterns via CFCTX_OM_ENV_PATTERNS use the literal string `NAME`
# as the placeholder (was `<name>`; changed because `<...>` conflicts with
# zsh's numeric-range glob syntax).
_cfctx_discover_om_file() {
    local dir="$1" name="$2"
    local -a candidates

    if [[ -n "${CFCTX_OM_ENV_PATTERNS:-}" ]]; then
        local -a patterns
        if [[ -n "${ZSH_VERSION:-}" ]]; then
            # zsh-only ${=var} word-split — wrap in `eval` so bash never has
            # to PARSE this syntax (some strict-mode bash setups choke at
            # parse time even when the branch is unreachable).
            # shellcheck disable=SC2296,SC2206
            eval 'patterns=(${=CFCTX_OM_ENV_PATTERNS})'
        else
            # shellcheck disable=SC2206  # intentional word-split in bash
            patterns=($CFCTX_OM_ENV_PATTERNS)
        fi
        local p
        for p in "${patterns[@]}"; do
            candidates+=("$dir/${p//NAME/$name}")
        done
    else
        candidates=(
            "$dir/$name.yml"
            "$dir/$name.yaml"
            "$dir/om-cli-$name.yml"
            "$dir/om-cli-$name.yaml"
        )
    fi

    local c
    for c in "${candidates[@]}"; do
        if [[ -f "$c" ]]; then
            printf '%s\n' "$c"
            return 0
        fi
    done
    return 1
}

# Parse a flat `om -e` YAML file, emit shell export lines to stdout.
# Side effect: block-scalar `ca-cert` is written to $ctx_dir/om-ca.pem (0600).
_cfctx_om_yaml_to_env() {
    local om_file="$1" ctx_dir="$2"
    awk -v ctx_dir="$ctx_dir" '
        BEGIN {
            m["target"]                = "OM_TARGET"
            m["username"]              = "OM_USERNAME"
            m["password"]              = "OM_PASSWORD"
            m["client-id"]             = "OM_CLIENT_ID"
            m["client-secret"]         = "OM_CLIENT_SECRET"
            m["skip-ssl-validation"]   = "OM_SKIP_SSL_VALIDATION"
            m["decryption-passphrase"] = "OM_DECRYPTION_PASSPHRASE"
            m["connect-timeout"]       = "OM_CONNECT_TIMEOUT"
            m["request-timeout"]       = "OM_REQUEST_TIMEOUT"
            m["trace"]                 = "OM_TRACE"
            m["vars-env"]              = "OM_VARS_ENV"
            in_block = 0
            block_key = ""
            block_indent = -1
            ca_file = ctx_dir "/om-ca.pem"
            ca_written = 0
        }
        # Collect block scalar for ca-cert
        in_block == 1 {
            # Determine indent of this line
            match($0, /^[[:space:]]*/)
            this_indent = RLENGTH
            if (this_indent >= block_indent && length($0) > 0) {
                # Strip the block indent and append
                content = substr($0, block_indent + 1)
                if (block_key == "ca-cert") {
                    print content >> ca_file
                    ca_written = 1
                }
                next
            } else {
                in_block = 0
                block_key = ""
                # fall through to process this line
            }
        }
        /^[[:space:]]*#/ || /^[[:space:]]*$/ { next }
        /^[a-zA-Z_][a-zA-Z0-9_-]*:/ {
            line = $0
            colon = index(line, ":")
            key = substr(line, 1, colon - 1)
            val = substr(line, colon + 1)
            sub(/^[[:space:]]+/, "", val)
            sub(/[[:space:]]+$/, "", val)
            # Block scalar indicator?
            if (val == "|" || val == ">" || val ~ /^[|>][0-9+-]*$/) {
                if (key == "ca-cert") {
                    in_block = 1
                    block_key = key
                    # Guess indent: next nonblank line sets it; default 2
                    block_indent = 2
                    # Truncate the ca file
                    printf "" > ca_file
                } else {
                    print "# SKIPPED block scalar for unsupported key: " key > "/dev/stderr"
                }
                next
            }
            # Strip surrounding quotes.
            if (val ~ /^".*"$/) { val = substr(val, 2, length(val) - 2) }
            else if (val ~ /^'\''.*'\''$/) { val = substr(val, 2, length(val) - 2) }

            if (key in m) {
                # Shell-quote: escape any embedded double quotes.
                gsub(/"/, "\\\"", val)
                print "export " m[key] "=\"" val "\""
            } else {
                print "# (unmapped om key: " key ": " val ")"
            }
        }
        END {
            if (ca_written) {
                print "export OM_CA_CERT=\"$(cat \"$CF_HOME/om-ca.pem\")\""
                print "# (CA cert extracted to $CF_HOME/om-ca.pem; 0600)"
            }
        }
    ' "$om_file"
}

_cfctx_write_template_from_om() {
    local env_file="$1" name="$2" om_file="$3" ctx_dir="$4"

    # First, generate the OM section.
    local om_section
    if ! om_section=$(_cfctx_om_yaml_to_env "$om_file" "$ctx_dir"); then
        echo "cfctx: failed to parse $om_file" >&2
        return 1
    fi

    # Lock the CA file if it got written.
    [[ -f "$ctx_dir/om-ca.pem" ]] && chmod 600 "$ctx_dir/om-ca.pem"

    # Remember which om yaml we seeded from — lets `cfctx enrich <name>`
    # re-query the same Ops Manager later without the user re-specifying it.
    local source_marker="# cfctx:om-source: $om_file"

    cat > "$env_file" <<EOF
# cfctx context: $name
# Seeded from om env file: $om_file
$source_marker
# Mode should stay 0600. Never commit this file.

# ---- CF CLI ---------------------------------------------------------------
# Set CF_API to let 'cfctx target $name' auto-run 'cf api' + 'cf auth' on
# first use (CF_USERNAME/CF_PASSWORD optional — falls back to the OM_* creds
# above). After the first successful login, tokens cache in \$CF_HOME/.cf/
# and subsequent switches skip login.
# export CF_API=""                 # e.g. https://api.sys.<foundation>.example.com
# export CF_ORG="system"
# export CF_SPACE="system"
# export CF_USERNAME=""            # optional; falls back to OM_USERNAME
# export CF_PASSWORD=""            # optional; falls back to OM_PASSWORD

# ---- Ops Manager (om) — imported from $(basename "$om_file") --------------
$om_section

# ---- BOSH Director (populate manually or via \`om bosh-env\`) --------------
# export BOSH_ENVIRONMENT=""
# export BOSH_CLIENT=""
# export BOSH_CLIENT_SECRET=""
# export BOSH_CA_CERT=""
# export BOSH_GW_HOST=""
# export BOSH_GW_USER="jumpbox"
# export BOSH_GW_PRIVATE_KEY="\$HOME/.ssh/${name}_jumpbox"

# ---- CredHub --------------------------------------------------------------
# export CREDHUB_SERVER=""
# export CREDHUB_CLIENT=""
# export CREDHUB_SECRET=""
# export CREDHUB_CA_CERT=""
EOF
}

_cfctx_cmd_env() {
    local root="$1" name="${2:-}"
    if [[ -z "$name" ]]; then
        if [[ -n "${CF_HOME:-}" && "$CF_HOME" != "$HOME" ]]; then
            name=$(basename "$CF_HOME")
        else
            echo "Usage: cfctx env <name>" >&2
            return 1
        fi
    fi
    _cfctx_valid_name "$name" || return 1
    local env_file="$root/$name/context.env"
    if [[ ! -f "$env_file" ]]; then
        echo "No env file for '$name' — create with: cfctx init-env $name" >&2
        return 1
    fi
    echo "# $env_file"
    # Portable masking: strip `export `, split on first `=`, mask value if key looks secret.
    # Works with BSD awk (macOS default) and gawk.
    awk '
        /^[[:space:]]*#/ || /^[[:space:]]*$/ { print; next }
        {
            line = $0
            prefix = ""
            rest = line
            if (rest ~ /^[[:space:]]*export[[:space:]]+/) {
                sub(/^[[:space:]]*export[[:space:]]+/, "", rest)
                prefix = "export "
            }
            eq = index(rest, "=")
            if (eq == 0) { print line; next }
            key = substr(rest, 1, eq - 1)
            val = substr(rest, eq + 1)
            if (key ~ /(PASSWORD|SECRET|TOKEN|KEY|CA_CERT|PRIVATE)/) {
                if (length(val) > 2) {
                    masked = substr(val,1,1) "***" substr(val,length(val),1)
                } else {
                    masked = "***"
                }
                print prefix key "=" masked
            } else {
                print line
            }
        }
    ' "$env_file"
}

_cfctx_cmd_target() {
    local root="$1"; shift
    local name="" om_file="" cf_api="" cf_org="" cf_space=""
    local force=0 no_login=0 no_enrich=0 create=0
    while (( $# )); do
        case "$1" in
            -h|--help)
                cat <<'HELP'
Usage: cfctx <name> [--from-om <file>] [--cf-api <url>]
                    [--org <name>] [--space <name>]
                    [--force] [--no-login] [--no-enrich] [--create]

Target a foundation in one step: stamp context.env (auto-importing from
CFCTX_OM_ENV_DIR or --from-om), query Ops Manager via om to auto-populate
BOSH_* / CF_API / CF admin creds (with CF_ORG/CF_SPACE defaulted to 'system'),
switch the shell, and log in to CF. After first login, tokens are cached —
subsequent switches re-use them.

Options:
  --from-om <file>   Pre-fill OM_* from an om-cli env yaml.
  --cf-api <url>     Override/persist CF_API (usually auto-detected).
  --org <name>       Set/persist CF_ORG (default: system).
  --space <name>     Set/persist CF_SPACE (default: system).
  --force            Re-seed an existing context.env from scratch.
  --no-login         Skip CF auto-login for this switch.
  --no-enrich        Skip 'om bosh-env' + CF_API/creds detection.
  --create           Skip the "blank context?" confirmation prompt (for
                     scripted use on new foundations with no om yaml).

Env:
  CFCTX_OM_ENV_DIR       Auto-discover om env files from here.
  CFCTX_OM_ENV_PATTERNS  Filename patterns ('NAME' placeholder).
  CFCTX_NO_AUTO_LOGIN=1  Globally disable CF auto-login.
  CFCTX_NO_OM_ENRICH=1   Globally disable om enrichment.
HELP
                return 0
                ;;
            --from-om)
                om_file="${2:-}"
                shift 2 || { echo "cfctx: --from-om needs a file path" >&2; return 1; }
                ;;
            --cf-api)
                cf_api="${2:-}"
                shift 2 || { echo "cfctx: --cf-api needs a URL" >&2; return 1; }
                ;;
            --org|-o)
                cf_org="${2:-}"
                shift 2 || { echo "cfctx: --org needs a value" >&2; return 1; }
                ;;
            --space|-s)
                cf_space="${2:-}"
                shift 2 || { echo "cfctx: --space needs a value" >&2; return 1; }
                ;;
            --no-login)
                no_login=1
                shift
                ;;
            --no-enrich)
                no_enrich=1
                shift
                ;;
            --force|-f)
                force=1
                shift
                ;;
            --create)
                create=1
                shift
                ;;
            -*)
                echo "cfctx: unknown flag '$1'" >&2
                return 1
                ;;
            *)
                if [[ -z "$name" ]]; then name="$1"
                else echo "cfctx: unexpected arg '$1'" >&2; return 1
                fi
                shift
                ;;
        esac
    done

    _cfctx_valid_name "$name" || return 1

    # NOTE: split into two `local` lines — bash expands `$ctx_dir` before
    # `local` assigns it, so a single `local a=... b="$a/..."` leaves b broken.
    local ctx_dir="$root/$name"
    local env_file="$ctx_dir/context.env"

    # --from-om on an existing context implies --force (fresh seed + switch).
    if [[ -n "$om_file" && -f "$env_file" ]]; then
        force=1
    fi

    local need_init=0
    if [[ ! -f "$env_file" ]] || (( force )); then
        need_init=1
    fi

    if (( need_init )); then
        # Peek auto-discovery BEFORE the did-you-mean guard — otherwise
        # `cfctx dev211` with a matching om-cli-dev211.yml in CFCTX_OM_ENV_DIR
        # would wrongly trigger the "no om yaml" prompt, since init-env's
        # own discovery hasn't run yet at this point.
        local _peek_om=""
        if [[ -z "$om_file" && -n "${CFCTX_OM_ENV_DIR:-}" ]]; then
            _peek_om=$(_cfctx_discover_om_file "$CFCTX_OM_ENV_DIR" "$name" 2>/dev/null || true)
        fi

        # Did-you-mean guard: only for truly blank creation paths —
        # fresh ctx, no --from-om, no auto-discoverable yaml, interactive, not --create.
        if [[ ! -d "$ctx_dir" && -z "$om_file" && -z "$_peek_om" && $create -eq 0 && -t 0 ]]; then
            if ! _cfctx_confirm_new_blank "$root" "$name"; then
                return 1
            fi
        fi

        local -a init_args=("$name")
        (( force )) && init_args+=("--force")
        (( no_enrich )) && init_args+=("--no-enrich")
        [[ -n "$om_file" ]] && init_args+=("--from-om" "$om_file")
        _cfctx_cmd_init_env "$root" "${init_args[@]}" || return 1
    fi

    # Persist any --cf-api / --org / --space overrides BEFORE the switch
    # sources context.env, so they take effect this run.
    if [[ -n "$cf_api" ]]; then
        _cfctx_set_env_var "$env_file" "CF_API" "$cf_api" || return 1
        echo "  set CF_API=$cf_api in $env_file"
    fi
    if [[ -n "$cf_org" ]]; then
        _cfctx_set_env_var "$env_file" "CF_ORG" "$cf_org" || return 1
        echo "  set CF_ORG=$cf_org in $env_file"
    fi
    if [[ -n "$cf_space" ]]; then
        _cfctx_set_env_var "$env_file" "CF_SPACE" "$cf_space" || return 1
        echo "  set CF_SPACE=$cf_space in $env_file"
    fi

    if (( no_login )); then
        CFCTX_NO_AUTO_LOGIN=1 _cfctx_cmd_switch "$root" "$name"
    else
        _cfctx_cmd_switch "$root" "$name"
    fi
}

# Set or replace `export KEY="VALUE"` in a context.env, preserving the rest.
# Values with shell-special chars (\ " $ `) are escaped so auto-generated
# passwords don't corrupt the file or get silently rewritten on source.
# Uses ENVIRON[] (not awk's -v) because -v pre-interprets backslash escapes.
_cfctx_set_env_var() {
    local env_file="$1" key="$2" value="$3"
    [[ -f "$env_file" ]] || { echo "cfctx: no such env file: $env_file" >&2; return 1; }
    local tmp="$env_file.tmp.$$"
    CFCTX_SET_VAL="$value" awk -v k="$key" '
        BEGIN {
            v = ENVIRON["CFCTX_SET_VAL"]
            # Order matters: backslash first, else subsequent escapes double.
            gsub(/\\/, "\\\\", v)
            gsub(/"/,  "\\\"", v)
            gsub(/[$]/, "\\$", v)
            gsub(/`/,  "\\`", v)
            found = 0
        }
        {
            line = $0
            stripped = line
            sub(/^[[:space:]]*#[[:space:]]*/, "", stripped)
            sub(/^[[:space:]]*export[[:space:]]+/, "", stripped)
            if (match(stripped, "^" k "=")) {
                print "export " k "=\"" v "\""
                found = 1
            } else {
                print line
            }
        }
        END {
            if (!found) {
                print ""
                print "# Added by cfctx"
                print "export " k "=\"" v "\""
            }
        }
    ' "$env_file" > "$tmp" || { rm -f "$tmp"; return 1; }
    mv "$tmp" "$env_file"
    chmod 600 "$env_file"
}

# Query Ops Manager via `om` to enrich context.env with:
#   - BOSH_* (from `om bosh-env`)
#   - CF_API (derived from the `cf` product's .cloud_controller.system_domain)
# Silent-graceful if om/jq missing, network down, or user opted out.
#
# IMPORTANT: every `om` invocation runs via _cfctx_om_clean, which unsets
# OM_* env vars in a subshell first. Without this, the previous context's
# OM_TARGET (still exported in the shell) would override `-e $om_file` per
# om's docs precedence: CLI flags > env vars > yaml. Symptom was NDC's
# enrichment querying TDC's Ops Manager.
_cfctx_enrich_from_om() {
    local env_file="$1" om_file="$2"

    [[ -z "${CFCTX_NO_OM_ENRICH:-}" ]] || return 0
    if ! command -v om >/dev/null 2>&1; then
        echo "  (skipping om enrichment — om CLI not in PATH)"
        return 0
    fi
    if [[ ! -f "$om_file" ]]; then
        echo "  (skipping om enrichment — om source '$om_file' not found)"
        return 0
    fi

    # Surface which OM we're actually querying — helps diagnose if a yaml
    # silently points at the wrong foundation.
    local om_target
    om_target=$(awk '/^target:/ {sub(/^target:[[:space:]]*/, ""); gsub(/"/,""); print; exit}' "$om_file")
    echo "  querying Ops Manager at ${om_target:-(target unknown)} via om ..."

    # 1) BOSH_* — om bosh-env emits ready-to-source `export BOSH_*=...` lines.
    local bosh_output bosh_rc
    bosh_output=$(_cfctx_om_clean -e "$om_file" bosh-env 2>/dev/null)
    bosh_rc=$?
    if (( bosh_rc == 0 )) && [[ -n "$bosh_output" ]]; then
        # Strip any existing auto-BOSH section — re-running enrich is idempotent.
        _cfctx_strip_section "$env_file" "BOSH-FROM-OM"
        {
            echo ""
            echo "# ---- BOSH-FROM-OM ----"
            echo "# Auto-populated by 'om bosh-env'. Re-run 'cfctx enrich <name>' to refresh."
            echo "$bosh_output"
            echo "# ---- END BOSH-FROM-OM ----"
        } >> "$env_file"
        echo "    ✓ BOSH_* populated from om bosh-env"
    else
        echo "    (om bosh-env returned nothing — BOSH_* left as placeholders;"
        echo "     often means no jumpbox is configured or OM is unreachable)"
    fi

    # 2) CF_API — requires jq to parse Ops Manager's JSON.
    if ! command -v jq >/dev/null 2>&1; then
        echo "    (jq not installed — skipping CF_API detection; 'brew install jq' to enable)"
        return 0
    fi

    # Query STAGED (not deployed) — /deployed/<guid>/properties doesn't exist
    # in Ops Manager's API; properties live under /staged/<guid>/properties.
    # The staged GUID and deployed GUID match for a deployed foundation.
    local products cf_guid props system_domain cf_api stderr_file rc
    stderr_file=$(mktemp)

    rc=0
    products=$(_cfctx_om_clean -e "$om_file" curl -p '/api/v0/staged/products' 2>"$stderr_file") || rc=$?
    if (( rc != 0 )) || [[ -z "$products" ]]; then
        echo "    (om curl failed fetching staged products — CF_API skipped)"
        [[ -s "$stderr_file" ]] && sed 's/^/      om: /' "$stderr_file"
        rm -f "$stderr_file"
        return 0
    fi
    cf_guid=$(printf '%s' "$products" | jq -r '.[] | select(.type=="cf") | .guid' 2>/dev/null)
    if [[ -z "$cf_guid" || "$cf_guid" == "null" ]]; then
        echo "    (no 'cf' product staged on this foundation — CF_API skipped)"
        rm -f "$stderr_file"
        return 0
    fi

    rc=0
    props=$(_cfctx_om_clean -e "$om_file" curl -p "/api/v0/staged/products/$cf_guid/properties" 2>"$stderr_file") || rc=$?
    if (( rc != 0 )) || [[ -z "$props" ]]; then
        echo "    (om curl failed fetching cf properties — CF_API skipped)"
        [[ -s "$stderr_file" ]] && sed 's/^/      om: /' "$stderr_file"
        rm -f "$stderr_file"
        return 0
    fi
    rm -f "$stderr_file"

    # The property key is literally .cloud_controller.system_domain (with dots, quoted).
    system_domain=$(printf '%s' "$props" | jq -r '.properties[".cloud_controller.system_domain"].value // empty' 2>/dev/null)
    if [[ -z "$system_domain" ]]; then
        echo "    (cf system_domain not found in properties — CF_API skipped)"
        return 0
    fi

    cf_api="https://api.$system_domain"
    _cfctx_set_env_var "$env_file" "CF_API" "$cf_api"
    echo "    ✓ CF_API set to $cf_api"

    # 3) CF admin user credentials (distinct from OM admin — they live in
    # the cf product's own UAA). Required for `cf auth` to succeed.
    local cf_creds cf_user cf_pass
    stderr_file=$(mktemp)
    rc=0
    cf_creds=$(_cfctx_om_clean -e "$om_file" curl -p "/api/v0/deployed/products/$cf_guid/credentials/.uaa.admin_credentials" 2>"$stderr_file") || rc=$?
    if (( rc == 0 )) && [[ -n "$cf_creds" ]]; then
        cf_user=$(printf '%s' "$cf_creds" | jq -r '.credential.value.identity // empty' 2>/dev/null)
        cf_pass=$(printf '%s' "$cf_creds" | jq -r '.credential.value.password // empty' 2>/dev/null)
        if [[ -n "$cf_user" && -n "$cf_pass" ]]; then
            _cfctx_set_env_var "$env_file" "CF_USERNAME" "$cf_user"
            _cfctx_set_env_var "$env_file" "CF_PASSWORD" "$cf_pass"
            echo "    ✓ CF_USERNAME/CF_PASSWORD pulled from Ops Manager"
        else
            echo "    (cf admin_credentials response missing identity/password fields)"
        fi
    else
        echo "    (couldn't fetch CF admin creds from OM — auto-login will try OM_* fallback)"
        [[ -s "$stderr_file" ]] && sed 's/^/      om: /' "$stderr_file"
    fi
    rm -f "$stderr_file"

    # 4) Default CF_ORG / CF_SPACE = system — only if the user hasn't set them.
    # Change later with: cfctx tdc --org foo --space bar  (or cfctx edit tdc)
    if ! _cfctx_env_var_is_set "$env_file" "CF_ORG"; then
        _cfctx_set_env_var "$env_file" "CF_ORG" "system"
        echo "    ✓ CF_ORG defaulted to 'system'"
    fi
    if ! _cfctx_env_var_is_set "$env_file" "CF_SPACE"; then
        _cfctx_set_env_var "$env_file" "CF_SPACE" "system"
        echo "    ✓ CF_SPACE defaulted to 'system'"
    fi

    # 5) UAA URLs + admin client secret. Two UAAs per foundation:
    #    - CF UAA at https://uaa.<system_domain>  (the common one — manage CF users / SSO)
    #    - OM UAA at $OM_TARGET/uaa               (rare — manage Ops Manager users)
    # Default `cfctx uaa-login` targets CF UAA. `--om` flag targets the other.
    _cfctx_set_env_var "$env_file" "UAA_URL" "https://uaa.$system_domain"
    _cfctx_set_env_var "$env_file" "UAA_ADMIN_CLIENT" "admin"
    echo "    ✓ UAA_URL set to https://uaa.$system_domain (CF UAA)"

    # OM UAA URL — derive from OM_TARGET (already in context.env via yaml import).
    local om_target_for_uaa
    om_target_for_uaa=$(_cfctx_read_env_var "$env_file" OM_TARGET)
    if [[ -n "$om_target_for_uaa" ]]; then
        # Strip any trailing slash, then append /uaa.
        om_target_for_uaa="${om_target_for_uaa%/}"
        _cfctx_set_env_var "$env_file" "OM_UAA_URL" "$om_target_for_uaa/uaa"
        echo "    ✓ OM_UAA_URL set to $om_target_for_uaa/uaa"
    fi

    # CF UAA admin client secret — distinct credential from .uaa.admin_credentials
    # (which is the user). uaac uses client_credentials grant against the client.
    local uaa_client_creds uaa_admin_secret
    stderr_file=$(mktemp)
    rc=0
    uaa_client_creds=$(_cfctx_om_clean -e "$om_file" curl -p "/api/v0/deployed/products/$cf_guid/credentials/.uaa.admin_client_credentials" 2>"$stderr_file") || rc=$?
    if (( rc == 0 )) && [[ -n "$uaa_client_creds" ]]; then
        uaa_admin_secret=$(printf '%s' "$uaa_client_creds" | jq -r '.credential.value.password // empty' 2>/dev/null)
        if [[ -n "$uaa_admin_secret" ]]; then
            _cfctx_set_env_var "$env_file" "UAA_ADMIN_CLIENT_SECRET" "$uaa_admin_secret"
            echo "    ✓ UAA_ADMIN_CLIENT_SECRET pulled from Ops Manager"
        else
            echo "    (uaa.admin_client_credentials response missing password — UAA_ADMIN_CLIENT_SECRET not set)"
        fi
    else
        echo "    (couldn't fetch UAA admin client creds — 'cfctx uaa-login' will need a manual secret)"
        [[ -s "$stderr_file" ]] && sed 's/^/      om: /' "$stderr_file"
    fi
    rm -f "$stderr_file"
}

# Test whether context.env contains an uncommented `[export ]KEY=...` line.
# Used to avoid clobbering user-customized values during enrichment.
_cfctx_env_var_is_set() {
    local env_file="$1" key="$2"
    [[ -f "$env_file" ]] || return 1
    awk -v k="$key" '
        /^[[:space:]]*#/ { next }
        {
            line = $0
            sub(/^[[:space:]]*export[[:space:]]+/, "", line)
            if (match(line, "^" k "=")) { found = 1; exit }
        }
        END { exit (found ? 0 : 1) }
    ' "$env_file"
}

# Remove a `# ---- <TAG> ----` ... `# ---- END <TAG> ----` block from an env file.
# Used to make om-enrichment re-runs idempotent.
_cfctx_strip_section() {
    local env_file="$1" tag="$2"
    [[ -f "$env_file" ]] || return 0
    local tmp="$env_file.tmp.$$"
    awk -v tag="$tag" '
        $0 ~ ("^# ---- " tag " ----")     { skip = 1; next }
        $0 ~ ("^# ---- END " tag " ----") { skip = 0; next }
        !skip { print }
    ' "$env_file" > "$tmp" && mv "$tmp" "$env_file"
    chmod 600 "$env_file"
}

# Decode the JWT `exp` claim from the cached CF AccessToken in $cfg.
# Prints the Unix-epoch expiry on stdout; empty output + nonzero exit if
# the file/token is missing, the token isn't a JWT, jq is absent, or the
# base64 decode failed. All failure modes are non-fatal — callers that
# can't determine expiry should *trust* the cache (don't force re-auth).
# Extract a top-level JSON string field from a single-line JSON file.
# Used for pulling AccessToken / Target out of $CF_HOME/.cf/config.json.
# Prefers jq, falls back to sed. Handles one-line JSON only (what cf writes).
_cfctx_json_str() {
    local cfg="$1" key="$2"
    [[ -f "$cfg" ]] || return 1
    if command -v jq >/dev/null 2>&1; then
        jq -r ".$key // empty" "$cfg" 2>/dev/null
    else
        sed -n 's/.*"'"$key"'":"\([^"]*\)".*/\1/p' "$cfg" 2>/dev/null | head -1
    fi
}

_cfctx_token_exp_epoch() {
    local cfg="$1"
    [[ -f "$cfg" ]] || return 1
    command -v jq >/dev/null 2>&1 || return 1

    local raw payload decoded
    raw=$(_cfctx_json_str "$cfg" AccessToken)
    # AccessToken is formatted "bearer <jwt>" (case varies).
    raw="${raw#bearer }"
    raw="${raw#Bearer }"
    [[ -n "$raw" ]] || return 1

    # JWT: header.payload.signature — take the middle segment.
    payload="${raw#*.}"
    payload="${payload%.*}"
    [[ -n "$payload" && "$payload" != "$raw" ]] || return 1

    # URL-safe base64 → standard base64; pad to a 4-byte boundary.
    payload=$(printf '%s' "$payload" | tr -- '-_' '+/')
    while (( ${#payload} % 4 )); do payload="${payload}="; done

    # GNU base64 uses -d; BSD uses -D. Try both.
    decoded=$(printf '%s' "$payload" | base64 -d 2>/dev/null) || \
    decoded=$(printf '%s' "$payload" | base64 -D 2>/dev/null) || return 1

    printf '%s' "$decoded" | jq -r '.exp // empty' 2>/dev/null
}

# Returns 0 if the cached CF token is expired (or within $grace seconds of
# expiring), 1 if valid, 2 if we can't tell. Callers should treat 2 as
# "trust the cache" — don't re-auth when we lack info.
_cfctx_token_expired() {
    local cfg="$1" grace="${2:-60}"
    local exp now
    exp=$(_cfctx_token_exp_epoch "$cfg") || return 2
    [[ -n "$exp" ]] || return 2
    now=$(date +%s)
    (( now + grace >= exp )) && return 0
    return 1
}

# Human-readable "expires in Xh" / "expired Ys ago" for doctor output.
_cfctx_token_humanize() {
    local cfg="$1"
    local exp now secs
    exp=$(_cfctx_token_exp_epoch "$cfg") || return 1
    [[ -n "$exp" ]] || return 1
    now=$(date +%s)
    secs=$((exp - now))
    if (( secs < 0 )); then
        secs=$(( -secs ))
        if   (( secs < 60 ));    then printf 'EXPIRED %ss ago' "$secs"
        elif (( secs < 3600 ));  then printf 'EXPIRED %sm ago' $((secs/60))
        else                          printf 'EXPIRED %sh ago' $((secs/3600))
        fi
    else
        if   (( secs < 60 ));    then printf 'expires in %ss' "$secs"
        elif (( secs < 3600 ));  then printf 'expires in %sm' $((secs/60))
        elif (( secs < 86400 )); then printf 'expires in %sh' $((secs/3600))
        else                          printf 'expires in %sd' $((secs/86400))
        fi
    fi
}

# Decide whether a human or automation is driving this switch. Used to pick
# the CF login flow (interactive SSO passcode vs client_credentials).
#   CFCTX_FORCE_ACTOR  — test/override hook; echoed verbatim if set.
_cfctx_actor() {
    if [[ -n "${CFCTX_FORCE_ACTOR:-}" ]]; then
        printf '%s' "$CFCTX_FORCE_ACTOR"; return 0
    fi
    if [[ "${CF_AUTH_MODE:-}" == "client" ]] \
        || [[ -n "${CFCTX_NONINTERACTIVE:-}" ]] \
        || [[ -n "${CI:-}" ]] \
        || ! [ -t 0 ]; then
        printf 'automation'
    else
        printf 'human'
    fi
}

# Resolve the effective CF auth mode from CF_AUTH_MODE (default 'auto') and,
# for 'auto', the actor + available credentials. Prints one of:
#   client | sso | password
_cfctx_resolve_cf_auth_mode() {
    local mode="${CF_AUTH_MODE:-auto}"
    case "$mode" in
        sso|client|password) printf '%s' "$mode"; return 0 ;;
    esac
    local actor; actor=$(_cfctx_actor)
    if [[ "$actor" == "automation" && -n "${CF_UAA_CLIENT_ID:-}" ]]; then
        printf 'client'
    elif [[ "${CF_SSO_CAPABLE:-0}" == "1" ]]; then
        printf 'sso'
    else
        printf 'password'
    fi
}

# Auto-login to CF using CF_API + (CF_USERNAME or OM_USERNAME) +
# (CF_PASSWORD or OM_PASSWORD). Called from _cfctx_cmd_switch after
# context.env has been sourced. Silent if cf is not installed, CF_API
# is unset, or tokens are already cached.
_cfctx_auto_login() {
    local ctx_dir="$1"

    [[ -z "${CFCTX_NO_AUTO_LOGIN:-}" ]] || return 0
    command -v cf >/dev/null 2>&1 || return 0

    if [[ -z "${CF_API:-}" ]]; then
        if [[ ! -s "$ctx_dir/.cf/config.json" ]]; then
            local _n
            _n=$(basename "$ctx_dir")
            echo "  (tip: set CF_API for auto-login:"
            echo "        cfctx target $_n --cf-api https://api.sys.<foundation>)"
        fi
        return 0
    fi

    # Decide if we need to re-auth. Skip if token is cached AND not expired.
    local cfg="$ctx_dir/.cf/config.json"
    local needs_login=1
    if [[ -f "$cfg" ]]; then
        local current_api access_token
        current_api=$(_cfctx_json_str "$cfg" Target)
        access_token=$(_cfctx_json_str "$cfg" AccessToken)
        if [[ "$current_api" == "$CF_API" && -n "$access_token" ]]; then
            # Honour JWT `exp` claim; fall through to re-auth if expired.
            # If we can't decode (no jq / not a JWT), trust the cache.
            if _cfctx_token_expired "$cfg"; then
                echo "  cf: cached token expired — re-authenticating"
            else
                needs_login=0
                echo "  cf: using cached token for $CF_API"
            fi
        fi
    fi

    if (( needs_login )); then
        # Fall back to OM creds if CF_USERNAME/CF_PASSWORD not set.
        local user="${CF_USERNAME:-${OM_USERNAME:-}}"
        local pass="${CF_PASSWORD:-${OM_PASSWORD:-}}"

        local skip_ssl_flag=""
        case "${CF_SKIP_SSL_VALIDATION:-${OM_SKIP_SSL_VALIDATION:-}}" in
            true|yes|1|True|TRUE) skip_ssl_flag="--skip-ssl-validation" ;;
        esac

        echo "  cf: logging in to $CF_API ..."

        # shellcheck disable=SC2086  # intentional word-split on skip_ssl_flag
        if ! cf api "$CF_API" $skip_ssl_flag >/dev/null 2>&1; then
            echo "  cf api failed — check CF_API and network" >&2
            echo "  diagnose: cf api \"$CF_API\" $skip_ssl_flag" >&2
            return 0
        fi

        if [[ -z "$user" || -z "$pass" ]]; then
            echo "  cf api set, but no CF_USERNAME/CF_PASSWORD (or OM_* fallback) — run 'cf login'"
            return 0
        fi

        if ! cf auth "$user" "$pass" >/dev/null 2>&1; then
            echo "  cf auth failed — verify CF_USERNAME/CF_PASSWORD in context.env" >&2
            echo "  (OM_USERNAME/OM_PASSWORD fallback may not be a valid CF UAA identity)" >&2
            return 0
        fi
    fi

    # Apply CF_ORG / CF_SPACE if they're set in env and differ from current.
    # This makes context.env authoritative — if you change CF_ORG, the next
    # switch re-targets. Only calls `cf target` when a change is needed.
    if [[ -n "${CF_ORG:-}" ]]; then
        local current_org="" current_space=""
        if [[ -f "$cfg" ]]; then
            current_org=$(awk 'BEGIN{RS=","} /"OrganizationFields":/,/\}/ {if (match($0, /"Name":"[^"]*"/)) {print substr($0,RSTART+8,RLENGTH-9); exit}}' "$cfg" 2>/dev/null)
            current_space=$(awk 'BEGIN{RS=","} /"SpaceFields":/,/\}/ {if (match($0, /"Name":"[^"]*"/)) {print substr($0,RSTART+8,RLENGTH-9); exit}}' "$cfg" 2>/dev/null)
        fi
        if [[ "$current_org" != "$CF_ORG" || "$current_space" != "${CF_SPACE:-}" ]]; then
            local -a target_args=(-o "$CF_ORG")
            [[ -n "${CF_SPACE:-}" ]] && target_args+=(-s "$CF_SPACE")
            cf target "${target_args[@]}" >/dev/null 2>&1 || \
                echo "  cf target -o $CF_ORG${CF_SPACE:+ -s $CF_SPACE} failed (org/space may not exist)"
        fi
    fi

    cf target 2>/dev/null | awk '/^(user|org|space):/' | sed 's/^/    /'
    if (( needs_login )); then
        echo "  ✓ cf logged in"
    fi
    return 0
}

# ---------------------------------------------------------------------------
# TERM wraps for bosh/cf — overlay shell functions that prepend a "safe"
# TERM to every invocation, when the local terminal (Ghostty/Kitty/Alacritty)
# uses a terminfo name that remote hosts typically don't have.
#
# Why this exists:
#   Error opening terminal: xterm-ghostty.    (seen on `bosh ssh`, `cf ssh`)
#
# Design:
#   - Trigger only for a conservative list of known-problematic TERMs.
#   - Never clobber a user-defined alias/function — skip if one exists.
#   - Mark our wrappers with a sentinel comment so uninstall only removes
#     our own functions and leaves user customization alone.
#   - Silent: no output on install/uninstall (doctor surfaces status).
#
# Opt-outs:
#   CFCTX_NO_TERM_WRAPS=1    — disable entirely
#   CFCTX_SAFE_TERM=<value>  — override the replacement TERM (default: xterm-256color)
# ---------------------------------------------------------------------------

_cfctx_term_is_exotic() {
    # shellcheck disable=SC2194  # intentional: constant list as the case word, TERM-substring as pattern
    case " xterm-ghostty xterm-kitty alacritty-direct alacritty " in
        *" ${TERM:-} "*) return 0 ;;
        *) return 1 ;;
    esac
}

_cfctx_can_wrap() {
    local cmd="$1"
    # No existing alias or function — safe to install.
    if ! alias "$cmd" >/dev/null 2>&1 && ! declare -f "$cmd" >/dev/null 2>&1; then
        return 0
    fi
    # Already our own wrap (idempotent re-install).
    declare -f "$cmd" 2>/dev/null | grep -q __cfctx_term_wrap__ && return 0
    # User-defined — leave it alone.
    return 1
}

_cfctx_install_term_wraps() {
    [[ -z "${CFCTX_NO_TERM_WRAPS:-}" ]] || return 0
    _cfctx_term_is_exotic || return 0

    # shellcheck disable=SC2329  # bosh() / cf() are user-facing wraps — invoked interactively
    if command -v bosh >/dev/null 2>&1 && _cfctx_can_wrap bosh; then
        bosh() {
            : __cfctx_term_wrap__
            TERM="${CFCTX_SAFE_TERM:-xterm-256color}" command bosh "$@"
        }
    fi
    # shellcheck disable=SC2329
    if command -v cf >/dev/null 2>&1 && _cfctx_can_wrap cf; then
        cf() {
            : __cfctx_term_wrap__
            TERM="${CFCTX_SAFE_TERM:-xterm-256color}" command cf "$@"
        }
    fi
}

_cfctx_uninstall_term_wraps() {
    local cmd
    for cmd in bosh cf; do
        # Only remove if it's our wrap — leave user-defined functions alone.
        if declare -f "$cmd" 2>/dev/null | grep -q __cfctx_term_wrap__; then
            unset -f "$cmd" 2>/dev/null || true
        fi
    done
}

# ---------------------------------------------------------------------------
# Terminal affordances — OSC escape sequences for window title + cursor color.
# These are universal VT100/xterm standards (supported in Ghostty, iTerm2,
# Terminal.app, tmux, gnome-terminal, WezTerm, kitty, Konsole, etc.) — NOT
# Ghostty-specific. Gated on stdout-is-a-TTY so piped output stays clean.
#
# OSC 2  sets window title: '\033]2;<text>\007'
# OSC 8  emits a clickable hyperlink (used in the `cfctx` listing): '\033]8;;<url>\007<text>\033]8;;\007'
# OSC 12 sets cursor color:  '\033]12;<color>\007'
# OSC 112 resets cursor color to the terminal default.
#
# Opt-out:  CFCTX_NO_TERM_AFFORDANCES=1
# Testing:  CFCTX_FORCE_TERM_AFFORDANCES=1 bypasses the TTY gate (tests only).
# ---------------------------------------------------------------------------

_cfctx_term_affordances_enabled() {
    [[ -z "${CFCTX_NO_TERM_AFFORDANCES:-}" ]] || return 1
    [[ -n "${CFCTX_FORCE_TERM_AFFORDANCES:-}" ]] && return 0
    [[ -t 1 ]]
}

# Map a friendly color name to a hex code for OSC 12. Uses a Dracula-ish
# palette so the cursor stays legible on common dark themes. Returns 1 for
# unknown names (caller should skip emission).
_cfctx_color_hex() {
    case "$1" in
        black)   printf '#282a36' ;;
        red)     printf '#ff5555' ;;
        green)   printf '#50fa7b' ;;
        yellow)  printf '#f1fa8c' ;;
        blue)    printf '#6272a4' ;;
        magenta) printf '#ff79c6' ;;
        cyan)    printf '#8be9fd' ;;
        white)   printf '#f8f8f2' ;;
        *)       return 1 ;;
    esac
}

# Called from _cfctx_cmd_switch: sets the window title to "cfctx:<name>"
# and the cursor color from the per-context .cfctx-color tag (if present).
_cfctx_emit_terminal_affordances() {
    local name="$1" ctx_dir="$2"
    _cfctx_term_affordances_enabled || return 0

    # OSC 2 — window / tab title. Visible in the Ghostty tab bar, iTerm2
    # tabs, Terminal.app windows, tmux status bar.
    printf '\033]2;cfctx:%s\007' "$name"

    # OSC 12 — cursor color, if the context has a color tag.
    if [[ -f "$ctx_dir/.cfctx-color" ]]; then
        local color hex
        color=$(cat "$ctx_dir/.cfctx-color" 2>/dev/null)
        if hex=$(_cfctx_color_hex "$color"); then
            printf '\033]12;%s\007' "$hex"
        fi
    fi
}

# Called from `cfctx clear`: blank the title and reset cursor color.
_cfctx_reset_terminal_affordances() {
    _cfctx_term_affordances_enabled || return 0
    printf '\033]2;\007'        # empty title
    printf '\033]112\007'       # reset cursor color to terminal default
}

# Format a URL as an OSC 8 clickable hyperlink. Used by _cfctx_cmd_ls.
# Falls back to plain text when affordances are disabled / piped.
_cfctx_osc8_link() {
    local url="$1" text="${2:-$1}"
    if _cfctx_term_affordances_enabled; then
        printf '\033]8;;%s\007%s\033]8;;\007' "$url" "$text"
    else
        printf '%s' "$text"
    fi
}

_cfctx_cmd_switch() {
    local root="$1" name="$2"
    _cfctx_valid_name "$name" || return 1
    local ctx_dir="$root/$name"
    local is_new=0
    [[ -d "$ctx_dir" ]] || is_new=1
    mkdir -p "$ctx_dir"
    chmod 700 "$ctx_dir" 2>/dev/null || true
    export CF_HOME="$ctx_dir"
    _cfctx_emit_terminal_affordances "$name" "$ctx_dir"
    echo "→ $name    (CF_HOME=$CF_HOME)"

    # Source per-context env file if present.
    if [[ -f "$ctx_dir/context.env" ]]; then
        if _cfctx_source_env "$ctx_dir/context.env"; then
            echo "  sourced $ctx_dir/context.env"
        fi
    fi

    if [[ $is_new -eq 1 ]]; then
        echo "  new context — run 'cfctx init-env $name' (or 'cfctx target $name') to add Tanzu creds"
    fi

    # Attempt CF auto-login (no-op if CF_API unset, cf not installed, or tokens cached).
    _cfctx_auto_login "$ctx_dir"

    # Install TERM wraps for bosh/cf if the local shell uses an "exotic" TERM
    # that remote hosts probably don't have in their terminfo DB. No-op for
    # xterm-256color and friends.
    _cfctx_install_term_wraps
}

_cfctx_write_template() {
    local env_file="$1" name="$2"
    cat > "$env_file" <<EOF
# cfctx context: $name
# This file is sourced by cfctx on every switch into this context.
# Mode should stay 0600. Never commit this file.
#
# Tip: shell out to a secret manager instead of storing plaintext:
#   export OM_PASSWORD="\$(security find-generic-password -s om-$name -w)"
#   export BOSH_CLIENT_SECRET="\$(pass show tanzu/$name/bosh)"

# ---- CF CLI ----------------------------------------------------------------
# Set CF_API to enable cfctx's one-shot auto-login on switch. If CF_USERNAME
# and CF_PASSWORD are also set, 'cfctx target $name' will run cf api + cf auth
# + cf target on first use, cache tokens under \$CF_HOME/.cf/, and skip login
# on subsequent switches (kubectx-style). If CF_USERNAME/CF_PASSWORD are unset,
# cfctx falls back to OM_USERNAME/OM_PASSWORD (most foundations share admin
# creds between Ops Manager UAA and CF UAA).
# export CF_API="https://api.sys.example.com"
# export CF_ORG="system"
# export CF_SPACE="system"
# export CF_USERNAME=""     # optional; falls back to OM_USERNAME
# export CF_PASSWORD=""     # optional; falls back to OM_PASSWORD

# ---- Ops Manager (om) — REQUIRED for every om invocation -------------------
# (om does not cache tokens; every call re-auths from these vars.)
# export OM_TARGET="https://opsmgr.example.com"
# export OM_USERNAME="admin"
# export OM_PASSWORD=""
# export OM_SKIP_SSL_VALIDATION="true"
# export OM_DECRYPTION_PASSPHRASE=""
# # Prefer client-credentials if the foundation has a UAA client:
# # export OM_CLIENT_ID=""
# # export OM_CLIENT_SECRET=""

# ---- BOSH Director — REQUIRED for every bosh invocation --------------------
# export BOSH_ENVIRONMENT=""
# export BOSH_CLIENT=""
# export BOSH_CLIENT_SECRET=""
# export BOSH_CA_CERT=""
# export BOSH_GW_HOST=""
# export BOSH_GW_USER="jumpbox"
# export BOSH_GW_PRIVATE_KEY="\$HOME/.ssh/${name}_jumpbox"

# ---- CredHub — REQUIRED for every credhub invocation -----------------------
# export CREDHUB_SERVER=""
# export CREDHUB_CLIENT=""
# export CREDHUB_SECRET=""
# export CREDHUB_CA_CERT=""
EOF
}

# Interactive "did you mean?" guard — triggered when user is about to create
# a brand-new context with no om yaml discovered. Lists existing contexts and
# discoverable yamls so they can recognise a typo before it stamps junk.
#
# Uses `find` instead of shell globs because zsh's default NO_MATCH option
# makes `for d in dir/*.yaml` error out when there are no matches — bash
# silently leaves the glob literal, zsh aborts the function.
_cfctx_confirm_new_blank() {
    local root="$1" name="$2"
    local -a existing=() yamls=()
    local d base

    if [[ -d "$root" ]]; then
        while IFS= read -r d; do
            [[ -n "$d" ]] && existing+=("$(basename "$d")")
        done < <(find "$root" -mindepth 1 -maxdepth 1 -type d 2>/dev/null)
    fi
    if [[ -n "${CFCTX_OM_ENV_DIR:-}" && -d "$CFCTX_OM_ENV_DIR" ]]; then
        while IFS= read -r d; do
            [[ -n "$d" ]] || continue
            base=$(basename "$d")
            base=${base%.yml}
            base=${base%.yaml}
            base=${base#om-cli-}
            yamls+=("$base")
        done < <(find "$CFCTX_OM_ENV_DIR" -maxdepth 1 \( -name '*.yml' -o -name '*.yaml' \) 2>/dev/null)
    fi

    echo
    echo "  '$name' doesn't match any existing context or discoverable om yaml."
    if (( ${#existing[@]} )); then
        echo "  Existing contexts: $(printf '%s, ' "${existing[@]}" | sed 's/, $//')"
    fi
    if (( ${#yamls[@]} )); then
        echo "  Available om yamls: $(printf '%s, ' "${yamls[@]}" | sort -u | sed 's/, $//')"
    fi
    printf "  Create '%s' as a new blank context? [y/N] " "$name"
    local reply
    read -r reply
    case "$reply" in
        y|Y|yes|YES) return 0 ;;
        *) echo "  Cancelled."; return 1 ;;
    esac
}

# `cfctx doctor` — run a battery of diagnostic checks and print a report.
# Default is fast (no network). Pass --online to probe Ops Manager reachability
# for each context (slow but authoritative).
_cfctx_cmd_doctor() {
    local root="$1"; shift
    local online=0
    while (( $# )); do
        case "$1" in
            --online) online=1; shift;;
            -h|--help) echo "Usage: cfctx doctor [--online]"; return 0;;
            *) echo "cfctx: unknown flag '$1'" >&2; return 1;;
        esac
    done

    local c_ok="" c_warn="" c_err="" c_dim="" c_off=""
    if [[ -t 1 ]]; then
        c_ok=$'\033[32m'; c_warn=$'\033[33m'; c_err=$'\033[31m'
        c_dim=$'\033[2m'; c_off=$'\033[0m'
    fi
    local issues=0
    local _tick="${c_ok}✓${c_off}" _warn="${c_warn}!${c_off}" _cross="${c_err}✗${c_off}"

    echo "=== cfctx doctor ==="

    # --- Environment ---
    echo "[${_tick}] cfctx version: $CFCTX_VERSION"
    if [[ -w "$root" ]]; then
        echo "[${_tick}] CFCTX_ROOT=$root (writable)"
    else
        echo "[${_cross}] CFCTX_ROOT=$root NOT writable"; issues=$((issues+1))
    fi
    if [[ -n "${CFCTX_OM_ENV_DIR:-}" ]]; then
        if [[ -d "$CFCTX_OM_ENV_DIR" ]]; then
            local yaml_count
            yaml_count=$(find "$CFCTX_OM_ENV_DIR" -maxdepth 1 \( -name '*.yml' -o -name '*.yaml' \) 2>/dev/null | wc -l | tr -d ' ')
            echo "[${_tick}] CFCTX_OM_ENV_DIR=$CFCTX_OM_ENV_DIR ($yaml_count yaml file(s))"
        else
            echo "[${_cross}] CFCTX_OM_ENV_DIR=$CFCTX_OM_ENV_DIR — directory does not exist"
            issues=$((issues+1))
        fi
    else
        echo "[${_warn}] CFCTX_OM_ENV_DIR is unset — om auto-discovery disabled"
    fi

    # --- Tools ---
    echo
    echo "-- Tools --"
    local t
    for t in cf om jq bosh credhub uaac awk sed; do
        if command -v "$t" >/dev/null 2>&1; then
            echo "[${_tick}] $t: $(command -v "$t")"
        else
            case "$t" in
                cf|om) echo "[${_cross}] $t NOT in PATH (required)"; issues=$((issues+1));;
                jq)    echo "[${_warn}] jq NOT in PATH — CF_API/creds detection will be skipped";;
                bosh|credhub) echo "[${_warn}] $t NOT in PATH — will work if you don't use $t directly";;
                uaac)  echo "[${_warn}] uaac NOT in PATH — 'cfctx uaa-login' will be unavailable (gem install cf-uaac)";;
                *)     echo "[${_cross}] $t NOT in PATH"; issues=$((issues+1));;
            esac
        fi
    done

    # --- Terminal / TERM wrap status ---
    echo
    echo "-- Terminal --"
    echo "[${_tick}] TERM=${TERM:-(unset)}"
    if [[ -n "${CFCTX_NO_TERM_WRAPS:-}" ]]; then
        echo "[${_warn}] CFCTX_NO_TERM_WRAPS is set — bosh/cf wraps disabled"
    elif _cfctx_term_is_exotic; then
        local safe_term="${CFCTX_SAFE_TERM:-xterm-256color}"
        local bosh_wrapped=0 cf_wrapped=0
        declare -f bosh 2>/dev/null | grep -q __cfctx_term_wrap__ && bosh_wrapped=1
        declare -f cf   2>/dev/null | grep -q __cfctx_term_wrap__ && cf_wrapped=1
        if (( bosh_wrapped || cf_wrapped )); then
            echo "[${_tick}] TERM wraps active ($TERM → $safe_term for bosh/cf)"
        else
            echo "[${_warn}] TERM=$TERM is exotic but wraps aren't installed yet — run 'cfctx <name>' to activate"
        fi
    else
        echo "[${c_dim}-${c_off}] TERM wraps not needed (TERM is broadly compatible)"
    fi

    # --- Contexts ---
    echo
    echo "-- Contexts --"
    if [[ ! -d "$root" ]] || [[ -z "$(ls -A "$root" 2>/dev/null)" ]]; then
        echo "(no contexts yet)"
    else
        local dir name env_file perms cf_api
        for dir in "$root"/*/; do
            [[ -d "$dir" ]] || continue
            name=$(basename "$dir")
            env_file="${dir}context.env"
            echo
            echo "  $name"
            if [[ ! -f "$env_file" ]]; then
                echo "    [${_warn}] no context.env — run 'cfctx $name' to stamp"
                issues=$((issues+1))
                continue
            fi
            # Perms
            perms=$(stat -c '%a' "$env_file" 2>/dev/null || stat -f '%Lp' "$env_file" 2>/dev/null)
            if [[ "$perms" == "600" || "$perms" == "400" ]]; then
                echo "    [${_tick}] context.env mode $perms"
            else
                echo "    [${_cross}] context.env mode $perms (fix: chmod 600 $env_file)"
                issues=$((issues+1))
            fi
            # CF_API
            cf_api=$(_cfctx_read_env_var "$env_file" CF_API)
            if [[ -n "$cf_api" ]]; then
                echo "    [${_tick}] CF_API=$cf_api"
            else
                echo "    [${_warn}] CF_API unset — run 'cfctx $name --force' to enrich"
                issues=$((issues+1))
            fi
            # CF creds
            if _cfctx_env_var_is_set "$env_file" "CF_USERNAME" && _cfctx_env_var_is_set "$env_file" "CF_PASSWORD"; then
                echo "    [${_tick}] CF_USERNAME / CF_PASSWORD set"
            else
                echo "    [${_warn}] CF_USERNAME or CF_PASSWORD missing (auto-login may fail)"
            fi
            # BOSH
            if _cfctx_env_var_is_set "$env_file" "BOSH_ENVIRONMENT"; then
                echo "    [${_tick}] BOSH_* populated"
            else
                echo "    [${_warn}] BOSH_* missing — run 'cfctx enrich $name'"
            fi
            # Cached token + expiry (JWT exp claim, if decodable)
            if [[ -f "${dir}.cf/config.json" ]]; then
                local tok cfg="${dir}.cf/config.json" human
                tok=$(_cfctx_json_str "$cfg" AccessToken)
                if [[ -n "$tok" ]]; then
                    if _cfctx_token_expired "$cfg"; then
                        human=$(_cfctx_token_humanize "$cfg" 2>/dev/null)
                        echo "    [${_warn}] CF token ${human:-EXPIRED} — next switch will re-auth"
                    else
                        human=$(_cfctx_token_humanize "$cfg" 2>/dev/null)
                        if [[ -n "$human" ]]; then
                            echo "    [${_tick}] CF token cached ($human)"
                        else
                            echo "    [${_tick}] CF token cached (expiry unknown — install jq for details)"
                        fi
                    fi
                else
                    echo "    [${_warn}] .cf/config.json present but no AccessToken"
                fi
            else
                echo "    [${c_dim}-${c_off}] no cf config yet (run 'cfctx $name' to log in)"
            fi
            # Online check
            if (( online )); then
                local om_target
                om_target=$(_cfctx_read_env_var "$env_file" OM_TARGET)
                if [[ -n "$om_target" ]]; then
                    if curl -s -o /dev/null -k --max-time 5 "$om_target/api/v0/info" 2>/dev/null; then
                        echo "    [${_tick}] OM reachable at $om_target"
                    else
                        echo "    [${_cross}] OM unreachable at $om_target"
                        issues=$((issues+1))
                    fi
                fi
            fi
        done
    fi

    echo
    if (( issues == 0 )); then
        echo "${c_ok}All checks passed.${c_off}"
    else
        echo "${c_warn}$issues issue(s) found.${c_off} Suggested fixes shown above."
        return 1
    fi
}

# `cfctx prompt [zsh|bash|starship|auto]` — emit a shell prompt snippet
# showing the current foundation. Pipe to your rc file once:
#    cfctx prompt zsh >> ~/.zshrc
_cfctx_cmd_prompt() {
    local kind="${1:-auto}"
    if [[ "$kind" == "auto" ]]; then
        if [[ -n "${ZSH_VERSION:-}" ]]; then kind=zsh
        elif [[ -n "${BASH_VERSION:-}" ]]; then kind=bash
        else kind=bash; fi
    fi
    case "$kind" in
        zsh)
            cat <<'SNIP'
# === cfctx prompt integration (zsh) ===
setopt prompt_subst 2>/dev/null
_cfctx_prompt_segment() {
    [[ -n "${CF_HOME:-}" && "$CF_HOME" != "$HOME" ]] || return 0
    local name color color_file
    name=$(basename "$CF_HOME")
    color_file="$CF_HOME/.cfctx-color"
    color="cyan"
    [[ -f "$color_file" ]] && color=$(<"$color_file")
    printf '%%F{%s}[cf:%s]%%f ' "$color" "$name"
}
# Prepend to your PROMPT:
PROMPT='$(_cfctx_prompt_segment)'$PROMPT
# === end cfctx ===
SNIP
            ;;
        bash)
            cat <<'SNIP'
# === cfctx prompt integration (bash) ===
_cfctx_prompt_segment() {
    [[ -n "${CF_HOME:-}" && "$CF_HOME" != "$HOME" ]] || return 0
    local name color color_file
    name=$(basename "$CF_HOME")
    color_file="$CF_HOME/.cfctx-color"
    color="36"  # cyan
    if [[ -f "$color_file" ]]; then
        case "$(cat "$color_file")" in
            black)   color="30" ;;
            red)     color="31" ;;
            green)   color="32" ;;
            yellow)  color="33" ;;
            blue)    color="34" ;;
            magenta) color="35" ;;
            cyan)    color="36" ;;
            white)   color="37" ;;
        esac
    fi
    # Use SOH (\001) / STX (\002) directly: bash only interprets \[ \] in
    # the literal PS1, not in command-substitution output, so the latter
    # would leak through as visible characters. SOH/STX work either way.
    printf '\001\e[1;%sm\002[cf:%s]\001\e[0m\002 ' "$color" "$name"
}
# Prepend to your PS1:
PS1='$(_cfctx_prompt_segment)'"$PS1"
# === end cfctx ===
SNIP
            ;;
        starship)
            cat <<'SNIP'
# Add to ~/.config/starship.toml:
[custom.cfctx]
command = 'basename "$CF_HOME"'
when = '[[ -n "$CF_HOME" && "$CF_HOME" != "$HOME" ]]'
format = '[\[cf:$output\]]($style) '
style = 'cyan bold'
SNIP
            ;;
        *)
            echo "Usage: cfctx prompt [zsh|bash|starship|auto]" >&2
            return 1
            ;;
    esac
}

# `cfctx color <name> [<color>|clear]` — tag a context with a display color.
# Stored in $CFCTX_ROOT/<name>/.cfctx-color. Read by the prompt snippet.
_cfctx_cmd_color() {
    local root="$1"; shift
    local name="${1:-}"; shift 2>/dev/null || true
    local color="${1:-}"
    if [[ -z "$name" ]]; then
        echo "Usage: cfctx color <name> [red|green|yellow|blue|magenta|cyan|white|black|clear]" >&2
        return 1
    fi
    _cfctx_valid_name "$name" || return 1
    local ctx_dir="$root/$name"
    local color_file="$ctx_dir/.cfctx-color"
    if [[ ! -d "$ctx_dir" ]]; then
        echo "cfctx: no such context: $name" >&2
        return 1
    fi
    if [[ -z "$color" ]]; then
        if [[ -f "$color_file" ]]; then
            cat "$color_file"
        else
            echo "(default)"
        fi
        return 0
    fi
    case "$color" in
        clear|none|-)
            rm -f "$color_file"
            echo "Cleared color for $name"
            ;;
        red|green|yellow|blue|magenta|cyan|white|black)
            printf '%s\n' "$color" > "$color_file"
            chmod 644 "$color_file"
            echo "Set color=$color for $name"
            ;;
        *)
            echo "cfctx: invalid color '$color'. Valid: red, green, yellow, blue, magenta, cyan, white, black, clear" >&2
            return 1
            ;;
    esac
}

# `cfctx pick` — fzf-based interactive context picker. Opens fzf with the
# list of foundations; on Enter, runs `cfctx <name>` (full target path, so
# env gets sourced + cf auto-logs-in). Graceful fallback if fzf is missing.
_cfctx_cmd_pick() {
    local root="$1"
    if ! command -v fzf >/dev/null 2>&1; then
        cat >&2 <<EOF
cfctx pick: fzf is not installed.
  macOS:  brew install fzf
  Linux:  sudo apt install fzf  (or https://github.com/junegunn/fzf#installation)
Without fzf, use bare cfctx (to list) or cfctx <name> (to switch).
EOF
        return 1
    fi
    if [[ ! -d "$root" ]] || [[ -z "$(ls -A "$root" 2>/dev/null)" ]]; then
        echo "No contexts yet. Create one with: cfctx <name> --cf-api <url>" >&2
        return 1
    fi

    # Build lines: marker<TAB>name<TAB>target_url
    local dir name is_current target_url line input=""
    for dir in "$root"/*/; do
        [[ -d "$dir" ]] || continue
        name=$(basename "$dir")
        is_current=" "
        [[ "${CF_HOME:-}" == "${dir%/}" ]] && is_current="●"
        target_url=""
        if [[ -f "${dir}context.env" ]]; then
            target_url=$(_cfctx_read_env_var "${dir}context.env" CF_API)
            [[ -z "$target_url" ]] && target_url=$(_cfctx_read_env_var "${dir}context.env" OM_TARGET)
        fi
        printf -v line '%s\t%s\t%s' "$is_current" "$name" "${target_url:-(no env)}"
        input+="$line"$'\n'
    done

    # Preview: show non-secret highlights from the selected context's env file.
    # fzf runs preview in sh -c; $f is expanded by THAT subshell, not this one —
    # single quotes are intentional.
    local preview_cmd
    # shellcheck disable=SC2016  # $f expanded by fzf preview sh, not here
    preview_cmd='f='"'$root/'"'{2}/context.env; if [ -f "$f" ]; then
        grep -E "^(export )?(CF_API|CF_ORG|CF_SPACE|OM_TARGET|BOSH_ENVIRONMENT|BOSH_CLIENT)=" "$f" | sed "s/^export //"
        printf "\n(secrets redacted; run: cfctx env '"'"'{2}'"'"' for full masked view)\n"
    else
        echo "(no context.env for '"'"'{2}'"'"')"
    fi'

    local chosen name_picked
    chosen=$(printf '%s' "$input" | fzf \
        --header='cfctx pick — Enter=switch, Esc=cancel' \
        --delimiter=$'\t' \
        --with-nth=1,2,3 \
        --preview="$preview_cmd" \
        --preview-window='right:50%:wrap') || return 0

    name_picked=$(printf '%s' "$chosen" | awk -F'\t' '{print $2}')
    [[ -n "$name_picked" ]] || return 0
    _cfctx_cmd_target "$root" "$name_picked"
}

# `cfctx uaa-login [--om]` — target a UAA and fetch a token via uaac.
#
# Default targets the CF product's UAA (the common case — managing CF users,
# SSO, scopes). `--om` targets Ops Manager's UAA instead (rarely needed).
# Honors $UAA_URL / $OM_UAA_URL / $UAA_ADMIN_CLIENT_SECRET / $OM_CLIENT_SECRET
# from the currently-active context.env (run `cfctx <foundation>` first).
_cfctx_cmd_uaa_login() {
    local target="cf" client="" secret="" url=""
    while (( $# )); do
        case "$1" in
            -h|--help)
                cat <<'HELP'
Usage: cfctx uaa-login [--om]

Target a UAA via the `uaac` CLI and fetch a token using client_credentials.

By default, targets the CF product's UAA at $UAA_URL using the admin client
($UAA_ADMIN_CLIENT / $UAA_ADMIN_CLIENT_SECRET — populated by `cfctx enrich`).

  --om     Target Ops Manager's UAA at $OM_UAA_URL using $OM_CLIENT_ID /
           $OM_CLIENT_SECRET. Errors if those aren't set (e.g. when om-cli
           yaml uses username/password rather than client credentials).

Requires `uaac` (cf-uaac gem):  gem install cf-uaac
HELP
                return 0
                ;;
            --om)
                target="om"; shift ;;
            *)
                echo "cfctx: unknown flag '$1' (try cfctx uaa-login --help)" >&2
                return 1
                ;;
        esac
    done

    if ! command -v uaac >/dev/null 2>&1; then
        cat >&2 <<EOF
cfctx uaa-login: 'uaac' is not installed.
  Install:  gem install cf-uaac
  Or via brew:  brew install cf-uaac    (if available in your tap set)
EOF
        return 1
    fi

    case "$target" in
        cf)
            url="${UAA_URL:-}"
            client="${UAA_ADMIN_CLIENT:-admin}"
            secret="${UAA_ADMIN_CLIENT_SECRET:-}"
            if [[ -z "$url" ]]; then
                echo "cfctx uaa-login: UAA_URL is unset — run 'cfctx <foundation>' first (or 'cfctx enrich <name>' to refresh)" >&2
                return 1
            fi
            if [[ -z "$secret" ]]; then
                echo "cfctx uaa-login: UAA_ADMIN_CLIENT_SECRET is unset — 'cfctx enrich <name>' to pull it from Ops Manager" >&2
                return 1
            fi
            ;;
        om)
            url="${OM_UAA_URL:-}"
            client="${OM_CLIENT_ID:-}"
            secret="${OM_CLIENT_SECRET:-}"
            if [[ -z "$url" ]]; then
                echo "cfctx uaa-login: OM_UAA_URL is unset — run 'cfctx <foundation>' first" >&2
                return 1
            fi
            if [[ -z "$client" || -z "$secret" ]]; then
                cat >&2 <<EOF
cfctx uaa-login --om: OM_CLIENT_ID / OM_CLIENT_SECRET aren't set.
This foundation uses username/password for OpsMan (OM_USERNAME / OM_PASSWORD)
rather than client credentials. uaac client_credentials grant requires the
client variant. Workaround: provision a UAA client in OpsMan UAA and add
client-id / client-secret to the om-cli yaml.
EOF
                return 1
            fi
            ;;
    esac

    # Respect SSL skip flag from OM_SKIP_SSL_VALIDATION (lab foundations).
    local skip_ssl=""
    case "${OM_SKIP_SSL_VALIDATION:-${CF_SKIP_SSL_VALIDATION:-}}" in
        true|yes|1|True|TRUE) skip_ssl="--skip-ssl-validation" ;;
    esac

    echo "  uaac: targeting $url ($target UAA)"
    # shellcheck disable=SC2086  # intentional word-split on skip_ssl
    if ! uaac target "$url" $skip_ssl >/dev/null 2>&1; then
        echo "  uaac target failed — check $url and network reachability" >&2
        return 1
    fi

    echo "  uaac: client_credentials grant for client '$client'"
    if ! uaac token client get "$client" -s "$secret" >/dev/null 2>&1; then
        echo "  uaac auth failed — verify the client + secret" >&2
        return 1
    fi

    echo "  ✓ uaac authenticated"
    uaac context 2>/dev/null | sed 's/^/    /'
}

_cfctx_cmd_help() {
    cat <<USAGE
cfctx $CFCTX_VERSION — per-shell CF CLI / Tanzu context switcher

  cfctx                 List all foundations (current one highlighted).
  cfctx <name> [flags]  Target a foundation: stamp context.env (auto-import
                        from CFCTX_OM_ENV_DIR if set, or --from-om <file>),
                        switch this shell, and run cf api/auth/target if
                        CF_API is set (or --cf-api <url> passed). After
                        first login, tokens are cached — re-runs are instant.
  cfctx target <name>   Explicit alias for the bare form above.
  cfctx pick            Open fzf to fuzzy-pick a foundation interactively.
  cfctx uaa-login [--om]  Target a UAA via uaac and fetch a token. Default
                          targets CF UAA; --om targets OpsMan UAA.
  cfctx status          Show current context details (CF_HOME + cf target).
  cfctx ls              List all contexts (* marks current, [env] = has env file)
  cfctx rm <name>       Delete a context (prompts for confirmation)
  cfctx cp <src> <dst>  Copy a context (including its env file)
  cfctx mv <old> <new>  Rename a context
  cfctx edit [name]     Edit context.env (stamps template if absent)
  cfctx init-env <name> [--from-om <file>] [--force]
                        Stamp a context.env template (0600). --from-om seeds
                        OM_* values from an \`om -e\` YAML env file. Set
                        CFCTX_OM_ENV_DIR to auto-discover <dir>/<name>.yml.
  cfctx env [name]      Print context.env with secret values masked
  cfctx enrich [name]   Re-query Ops Manager to refresh BOSH_*/CF_API/CF creds
  cfctx doctor [--online]  Diagnose cfctx/context state (add --online for reachability probes)
  cfctx prompt [zsh|bash|starship|auto]  Emit a shell prompt snippet
                        showing the current context (pipe to your rc file)
  cfctx color <name> [<color>|clear]  Set/clear a per-context color used
                        by the prompt (e.g. red for prod, green for lab)
  cfctx clear           Unset CF_HOME + common Tanzu env vars in this shell
  cfctx version         Print version
  cfctx help            Show this help

Storage:  \$CFCTX_ROOT  (default: \$HOME/.cf-homes; override by exporting CFCTX_ROOT)
Env file: \$CFCTX_ROOT/<name>/context.env  (mode 0600, NEVER commit)

Env vars:
  CFCTX_OM_ENV_DIR        Auto-discover om env files from this dir
  CFCTX_OM_ENV_PATTERNS   Filename patterns ('NAME' placeholder; space-separated)
  CFCTX_NO_AUTO_LOGIN=1   Skip CF auto-login on switch
  CFCTX_NO_OM_ENRICH=1    Skip Ops Manager enrichment on init-env
  CFCTX_NO_TERM_WRAPS=1   Skip bosh/cf TERM wraps even on exotic terminals
  CFCTX_SAFE_TERM=<TERM>  Replacement TERM used by the wraps (default: xterm-256color)
  CFCTX_NO_TERM_AFFORDANCES=1  Skip terminal window-title / cursor-color / OSC 8 hyperlinks
USAGE
}

# -----------------------------------------------------------------------------
# zsh tab-completion for context names and subcommands.
#
# Whole block wrapped in `eval` so bash never has to PARSE the zsh-only
# syntax inside (${+functions[compdef]}, ${(f)...}, etc.). The outer
# guard short-circuits in bash so eval is unreachable there.
# -----------------------------------------------------------------------------
if [[ -n "${ZSH_VERSION:-}" ]]; then
    # shellcheck disable=SC2034,SC2206,SC2296  # zsh-only syntax; file is dual-shell
    eval '
        if (( ${+functions[compdef]} )); then
            _cfctx() {
                local root="${CFCTX_ROOT:-$HOME/.cf-homes}"
                local -a subs ctxs
                subs=(status ls rm cp mv edit init-env env clear version help)
                [[ -d "$root" ]] && ctxs=(${(f)"$(ls -1 "$root" 2>/dev/null)"})
                _describe "subcommand" subs
                _describe "context" ctxs
            }
            compdef _cfctx cfctx
        fi
    '
fi

# -----------------------------------------------------------------------------
# Optional: show active context in your prompt.
# For zsh, add to ~/.zshrc (after sourcing this file):
#   setopt prompt_subst
#   PROMPT='%F{cyan}$([[ -n "$CF_HOME" && "$CF_HOME" != "$HOME" ]] && echo "[cf:$(basename "$CF_HOME")] ")%f'"$PROMPT"

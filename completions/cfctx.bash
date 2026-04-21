# bash completion for cfctx
#
# Install: put this somewhere that bash-completion loads from, or source it
# explicitly from ~/.bashrc:
#   source /path/to/completions/cfctx.bash

# shellcheck disable=SC2207  # COMPREPLY=( $(compgen ...) ) is the idiomatic form
_cfctx_complete() {
    local cur prev
    COMPREPLY=()
    cur="${COMP_WORDS[COMP_CWORD]}"
    prev="${COMP_WORDS[COMP_CWORD-1]}"

    local subs="status ls rm cp mv edit init-env enrich target doctor prompt color env clear version help"
    local root="${CFCTX_ROOT:-$HOME/.cf-homes}"

    local contexts=""
    if [[ -d "$root" ]]; then
        contexts=$(ls -1 "$root" 2>/dev/null)
    fi

    case $COMP_CWORD in
        1)
            COMPREPLY=( $(compgen -W "$subs $contexts" -- "$cur") )
            ;;
        2)
            case "$prev" in
                rm|edit|env|init-env|enrich|target|color|mv|cp)
                    COMPREPLY=( $(compgen -W "$contexts" -- "$cur") )
                    ;;
            esac
            ;;
        3)
            case "${COMP_WORDS[1]}" in
                mv|cp)
                    COMPREPLY=( $(compgen -W "$contexts" -- "$cur") )
                    ;;
            esac
            ;;
    esac
}

complete -F _cfctx_complete cfctx

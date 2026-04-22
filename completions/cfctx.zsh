#compdef cfctx
# zsh completion for cfctx
#
# Install: place this file in a directory on $fpath (e.g. one of the
# site-functions dirs, or a private dir you've added) and make sure
# compinit runs. Or just source it from ~/.zshrc after sourcing cfctx.sh.

_cfctx() {
    local root="${CFCTX_ROOT:-$HOME/.cf-homes}"
    local -a subs ctxs

    subs=(
        'status:show current context'
        'ls:list all contexts'
        'rm:delete a context'
        'cp:copy a context (incl. env file)'
        'mv:rename a context'
        'edit:edit context.env in $EDITOR'
        'init-env:stamp a context.env template'
        'enrich:re-query Ops Manager to refresh BOSH_*/CF_API'
        'target:init-env (if missing) + switch in one step'
        'pick:fzf-based interactive foundation picker'
        'doctor:diagnose cfctx / context state'
        'prompt:emit a shell prompt snippet (zsh|bash|starship)'
        'color:set/clear per-context color for the prompt'
        'env:print context.env with secrets masked'
        'clear:unset CF_HOME and related vars'
        'version:print cfctx version'
        'help:show usage'
    )
    [[ -d "$root" ]] && ctxs=(${(f)"$(ls -1 "$root" 2>/dev/null)"})

    if (( CURRENT == 2 )); then
        _describe 'subcommand' subs
        _describe 'context' ctxs
    else
        case "${words[2]}" in
            rm|edit|env|init-env|enrich|target|color|mv|cp)
                _describe 'context' ctxs
                ;;
        esac
    fi
}

compdef _cfctx cfctx

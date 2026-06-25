#!/usr/bin/env bash
# Bash completion for wiggum

_wiggum() {
    local cur prev words cword
    _init_completion || return

    local commands="init plan execute check docs run status watch kill chain top help"
    local presets="node next python astro bash"
    local efforts="low medium high xhigh max"
    local perms="acceptEdits auto bypassPermissions default dontAsk plan"

    # First argument: command
    if [[ $cword -eq 1 ]]; then
        mapfile -t COMPREPLY < <(compgen -W "$commands" -- "$cur")
        return
    fi

    local cmd="${words[1]}"

    # Options that take a value, common to several commands.
    case "$prev" in
        --effort)
            mapfile -t COMPREPLY < <(compgen -W "$efforts" -- "$cur")
            return
            ;;
        --permission-mode)
            mapfile -t COMPREPLY < <(compgen -W "$perms" -- "$cur")
            return
            ;;
    esac

    case "$cmd" in
        help)
            if [[ $cword -eq 2 ]]; then
                mapfile -t COMPREPLY < <(compgen -W "$commands" -- "$cur")
            fi
            return
            ;;
        init)
            if [[ $cword -eq 2 ]]; then
                mapfile -t COMPREPLY < <(compgen -W "$presets" -- "$cur")
            fi
            return
            ;;
        plan)
            case "$prev" in
                --plan-file)
                    _filedir md
                    return
                    ;;
            esac
            if [[ "$cur" == -* ]]; then
                mapfile -t COMPREPLY < <(compgen -W "--plan-file --effort --permission-mode --verbose --help" -- "$cur")
            else
                _filedir md
            fi
            return
            ;;
        execute)
            case "$prev" in
                --summary-file)
                    _filedir md
                    return
                    ;;
                --max-iterations|--iterations)
                    mapfile -t COMPREPLY < <(compgen -W "1 2 3 5 10" -- "$cur")
                    return
                    ;;
                --update-docs)
                    _filedir md
                    return
                    ;;
            esac
            if [[ "$cur" == -* ]]; then
                mapfile -t COMPREPLY < <(compgen -W "--max-iterations --summary-file --update-docs --background --no-verify --no-commit --effort --permission-mode --verbose --help" -- "$cur")
            else
                _filedir md
            fi
            return
            ;;
        status|kill)
            _filedir md
            return
            ;;
        top)
            # optional dirs or plan files
            if [[ "$cur" != -* ]]; then
                _filedir
            fi
            return
            ;;
        watch)
            case "$prev" in
                --timeout|--poll-interval)
                    return
                    ;;
            esac
            if [[ "$cur" == -* ]]; then
                mapfile -t COMPREPLY < <(compgen -W "--timeout --kill-on-timeout --poll-interval --help" -- "$cur")
            else
                _filedir md
            fi
            return
            ;;
        chain)
            if [[ "$cur" == -* ]]; then
                mapfile -t COMPREPLY < <(compgen -W "--max-iterations --no-verify --no-commit --effort --permission-mode --verbose --help" -- "$cur")
            else
                _filedir md
            fi
            return
            ;;
        check)
            if [[ "$cur" == -* ]]; then
                mapfile -t COMPREPLY < <(compgen -W "--max-validation-retries --no-commit --effort --permission-mode --verbose --help" -- "$cur")
            fi
            return
            ;;
        docs)
            case "$prev" in
                -i|-o)
                    _filedir md
                    return
                    ;;
            esac
            if [[ "$cur" == -* ]]; then
                mapfile -t COMPREPLY < <(compgen -W "-i -o --effort --permission-mode --verbose --help" -- "$cur")
            else
                _filedir
            fi
            return
            ;;
        run)
            case "$prev" in
                -f|--prompts-file|--session-file)
                    _filedir
                    return
                    ;;
            esac
            if [[ "$cur" == -* ]]; then
                mapfile -t COMPREPLY < <(compgen -W "-f --prompts-file --session-file --new-session --delimiter --effort --permission-mode --verbose --help" -- "$cur")
            fi
            return
            ;;
    esac
}

complete -F _wiggum wiggum

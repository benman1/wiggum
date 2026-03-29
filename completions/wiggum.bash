#!/usr/bin/env bash
# Bash completion for wiggum

_wiggum() {
    local cur prev words cword
    _init_completion || return

    local commands="init plan execute docs help"
    local presets="node next python astro bash"

    # First argument: command
    if [[ $cword -eq 1 ]]; then
        mapfile -t COMPREPLY < <(compgen -W "$commands" -- "$cur")
        return
    fi

    local cmd="${words[1]}"

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
                mapfile -t COMPREPLY < <(compgen -W "--plan-file --verbose --help" -- "$cur")
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
                --iterations)
                    mapfile -t COMPREPLY < <(compgen -W "1 2 3 5 10" -- "$cur")
                    return
                    ;;
                --update-docs)
                    _filedir md
                    return
                    ;;
            esac
            if [[ "$cur" == -* ]]; then
                mapfile -t COMPREPLY < <(compgen -W "--iterations --summary-file --update-docs --verbose --help" -- "$cur")
            else
                _filedir md
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
                mapfile -t COMPREPLY < <(compgen -W "-i -o --verbose --help" -- "$cur")
            else
                _filedir
            fi
            return
            ;;
    esac
}

complete -F _wiggum wiggum

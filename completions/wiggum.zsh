#compdef wiggum
# Zsh completion for wiggum

_wiggum() {
    local -a commands presets

    commands=(
        'init:Generate a .wiggumrc for a standard project setup'
        'plan:Create a workplan from issue/spec files'
        'execute:Implement a workplan with iterative validation'
        'docs:Update documentation from input files'
        'help:Show help for a command'
    )

    presets=(node next python astro bash)

    if (( CURRENT == 2 )); then
        _describe 'command' commands
        return
    fi

    case "${words[2]}" in
        help)
            if (( CURRENT == 3 )); then
                _describe 'command' commands
            fi
            ;;
        init)
            if (( CURRENT == 3 )); then
                _describe 'preset' presets
            fi
            ;;
        plan)
            _arguments \
                '--plan-file[Output path for the plan]:file:_files -g "*.md"' \
                '--verbose[Pass --verbose to Claude Code]' \
                '(-h --help)'{-h,--help}'[Show help]' \
                '*:input files:_files -g "*.md"'
            ;;
        execute)
            _arguments \
                '--max-iterations[Maximum implementation iterations]:count:(1 2 3 5 10)' \
                '--summary-file[Output path for the summary]:file:_files -g "*.md"' \
                '--update-docs[Comma-separated doc files to update]:files:_files -g "*.md"' \
                '--verbose[Pass --verbose to Claude Code]' \
                '(-h --help)'{-h,--help}'[Show help]' \
                '*:plan files:_files -g "*.md"'
            ;;
        docs)
            _arguments \
                '-i[Input files]:*:input files:_files -g "*.md"' \
                '-o[Output doc files to update]:*:output files:_files -g "*.md"' \
                '--verbose[Pass --verbose to Claude Code]' \
                '(-h --help)'{-h,--help}'[Show help]'
            ;;
    esac
}

_wiggum "$@"

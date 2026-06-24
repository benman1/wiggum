#compdef wiggum
# Zsh completion for wiggum

_wiggum() {
    local -a commands presets effort_opt perm_opt

    commands=(
        'init:Generate a .wiggumrc for a standard project setup'
        'plan:Create a workplan from issue/spec files'
        'execute:Implement a workplan with iterative validation'
        'check:Run verification waterfall and fix issues'
        'docs:Update documentation from input files'
        'run:Feed a series of prompts to Claude in one continuous session'
        'status:Show task progress and run state for a plan'
        'watch:Follow a background run until it finishes'
        'kill:Stop a background run (only that run process)'
        'chain:Execute several workplans back to back'
        'help:Show help for a command'
    )

    presets=(node next python astro bash)

    effort_opt='--effort[Reasoning effort level]:level:(low medium high xhigh max)'
    perm_opt='--permission-mode[Claude permission mode]:mode:(acceptEdits auto bypassPermissions default dontAsk plan)'

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
                "$effort_opt" \
                "$perm_opt" \
                '--verbose[Pass --verbose to Claude Code]' \
                '(-h --help)'{-h,--help}'[Show help]' \
                '*:input files:_files -g "*.md"'
            ;;
        execute)
            _arguments \
                '--max-iterations[Maximum implementation iterations]:count:(1 2 3 5 10)' \
                '--summary-file[Output path for the summary]:file:_files -g "*.md"' \
                '--update-docs[Comma-separated doc files to update]:files:_files -g "*.md"' \
                '(-b --background)'{-b,--background}'[Run detached; supervise with status/watch/kill]' \
                '--no-verify[Skip the verification waterfall]' \
                '--no-commit[Skip wiggum-issued git commits]' \
                "$effort_opt" \
                "$perm_opt" \
                '--verbose[Pass --verbose to Claude Code]' \
                '(-h --help)'{-h,--help}'[Show help]' \
                '*:plan files:_files -g "*.md"'
            ;;
        status)
            _arguments '*:plan file:_files -g "*.md"'
            ;;
        kill)
            _arguments '*:plan file:_files -g "*.md"'
            ;;
        watch)
            _arguments \
                '--timeout[Stop watching after N seconds (0 = forever)]:seconds:' \
                '--kill-on-timeout[Kill the run if the timeout is reached]' \
                '--poll-interval[How often to poll for new output]:seconds:' \
                '(-h --help)'{-h,--help}'[Show help]' \
                '*:plan file:_files -g "*.md"'
            ;;
        chain)
            _arguments \
                '--max-iterations[Maximum implementation iterations]:count:(1 2 3 5 10)' \
                '--no-verify[Skip the verification waterfall]' \
                '--no-commit[Skip wiggum-issued git commits]' \
                "$effort_opt" \
                "$perm_opt" \
                '--verbose[Pass --verbose to Claude Code]' \
                '(-h --help)'{-h,--help}'[Show help]' \
                '*:plan files:_files -g "*.md"'
            ;;
        check)
            _arguments \
                '--max-validation-retries[Max fix attempts per step]:count:(1 2 3 5 10)' \
                '--no-commit[Skip the post-fix wiggum commit]' \
                "$effort_opt" \
                "$perm_opt" \
                '--verbose[Pass --verbose to Claude Code]' \
                '(-h --help)'{-h,--help}'[Show help]'
            ;;
        docs)
            _arguments \
                '-i[Input files]:*:input files:_files -g "*.md"' \
                '-o[Output doc files to update]:*:output files:_files -g "*.md"' \
                "$effort_opt" \
                "$perm_opt" \
                '--verbose[Pass --verbose to Claude Code]' \
                '(-h --help)'{-h,--help}'[Show help]'
            ;;
        run)
            _arguments \
                '(-f --prompts-file)'{-f,--prompts-file}'[Read prompts from a file]:file:_files' \
                '--session-file[Persist/resume the session id]:file:_files' \
                '--new-session[Ignore an existing --session-file and start fresh]' \
                '--delimiter[Prompt separator line for -f/stdin]:delimiter:' \
                "$effort_opt" \
                "$perm_opt" \
                '--verbose[Pass --verbose to Claude Code]' \
                '(-h --help)'{-h,--help}'[Show help]' \
                '*:prompts:'
            ;;
    esac
}

_wiggum "$@"

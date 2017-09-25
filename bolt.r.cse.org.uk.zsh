if [[ "$TERM" != dumb ]] && [[ -z "$TMUX" ]] && [[ -n "$SSH_CONNECTION" ]]; then
    tmux start

    tmux list-windows -a -F '#{session_attached} #{session_id} #{window_id} #{session_name}' | sort -r |
        () { local -A window_sessions
             local -A all_sessions
             while read -r attd session window name; do
                 if [[ -z ${all_sessions[(i)$session]} ]]; then
                     if [[ $attd == 1 ]] || [[ $name == "main" ]]; then
                         all_sessions[$session]=1
                     else
                         all_sessions[$session]=0
                     fi

                 fi
                 if [[ -z ${window_sessions[(i)$window]} ]]; then
                     window_sessions[$window]=$session
                     all_sessions[$session]=$(( $all_sessions[$session]+1 ))
                 fi
             done

             for session (${(k)all_sessions}); do
                 if [[ 0 == ${all_sessions[$session]} ]]; then
                     tmux kill-session -t "$session"
                 fi
             done
           }
    if ! tmux has-session -t main; then
        exec tmux new-session -s main
    else
        local main_attached=$(tmux list-sessions -F '#{session_name} #{session_attached}' | grep main)
        if [[ $main_attached == "main 1" ]]; then
            exec tmux new-session -t main \; set-option destroy-unattached
        else
            exec tmux attach -t main
        fi
    fi
fi

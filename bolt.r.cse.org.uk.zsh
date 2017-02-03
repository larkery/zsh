if [[ -z "$TMUX" ]] && [[ -n "$SSH_CONNECTION" ]]; then
    join -v2 \
         <(tmux list-windows -a -F '#{session_id}' | sort | uniq) \
         <(tmux list-sessions -F '#{session_id}'| sort | uniq) |
        while read -r session; do
            tmux kill-session -t "$session"
        done
    session=$(tmux list-sessions -F '#{session_id}' | head -n 1)
    if [[ -z $session ]]; then
        exec tmux new-session main
    fi
    exec tmux new-session -t "$session"
fi

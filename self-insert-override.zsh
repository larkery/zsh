zmodload -i zsh/zleparameter

for k in $keymaps
do
    if (( $+widgets[self-insert-$k] == 0 ))
    then zle -A self-insert self-insert-$k
    fi
done

self-insert-by-keymap() {
    if (( $+widgets[$WIDGET-$KEYMAP] == 1 ))
    then zle $WIDGET-$KEYMAP "$@"
    else zle .$WIDGET "$@"
    fi
}

zle -N self-insert self-insert-by-keymap

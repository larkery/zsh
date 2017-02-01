which sqlite3 >/dev/null 2>&1 || return;

typeset -g HISTDB_QUERY=""
typeset -g HISTDB_FILE="${HOME}/.zsh/history.db"
typeset -g HISTDB_SESSION=""

typeset -gA HISTDB_RESULT

sql_escape () {
    sed -e "s/'/''/g" <<< "$@"
}

_histdb () {
    sqlite3 "${HISTDB_FILE}" "$@"
    [[ "$?" -ne 0 ]] && echo "error in $@"
}

_histdb_init () {
    if ! [[ -e "${HISTDB_FILE}" ]]; then
        _histdb 'create table hist (
             id integer primary key,
             sess integer,
             cmd text,
             pwd text,
             ret integer,
             start integer,
             end integer
           );'
    fi
    if [[ -z "${HISTDB_SESSION}" ]]; then
        HISTDB_SESSION=$(_histdb 'select 1+max(sess) from hist')
        HISTDB_SESSION="${HISTDB_SESSION:-0}"
        readonly HISTDB_SESSION
    fi
}

zshaddhistory () {
    local retval=$?
    local cmd="${1[0,-2]}"
    local now="$(date +%s)"
    _histdb_init
    [[ -z "$cmd" ]] ||
        _histdb "insert into hist (sess, cmd, pwd, ret, start, end)
                values (
                   ${HISTDB_SESSION},
                   '$(sql_escape ${cmd})',
                   '$(sql_escape ${PWD})',
                   ${retval}, ${_STARTED:-${now}}, ${_FINISHED:-${now}}
                );"
    return 0
}

_histdb_query () {
    local tab="	"
    local pwd
    local ret
    local start
    local cmd

    IFS=$tab read -r -d '' pwd ret start cmd < \
       <(_histdb -separator $tab \
                 "select pwd, ret, start, cmd from hist where $1 limit 1;")

    HISTDB_RESULT[pwd]="$pwd"
    HISTDB_RESULT[ret]="$ret"
    HISTDB_RESULT[start]="$start"
    HISTDB_RESULT[cmd]="${cmd[0,-2]}"

    return 0
}

_histdb_gen_sql () {
    echo "cmd like '%$(sql_escape $@)%' order by rowid desc"
}

_histdb_render () {
    POSTDISPLAY="
search: ${HISTDB_QUERY}"
    BUFFER="${HISTDB_RESULT[cmd]:-no result} [${HISTDB_RESULT[pwd]}]"
}

_histdb_update_state () {
    _histdb_query "$(_histdb_gen_sql ${HISTDB_QUERY})"
    _histdb_render
}

self-insert-histdb () {
    HISTDB_QUERY="${HISTDB_QUERY}${KEYS}"
    # TODO handle backspace etc. because we are using BUFFER to
    # display the result this is a bit tricky - perhaps it would be
    # better to use BUFFER to store the query string and to display
    # the result in PREDISPLAY or POSTDISPLAY.

    _histdb_update_state
}

histdb-search () {
    bindkey -N histdb $KEYMAP
    HISTDB_QUERY="$BUFFER"
    BUFFER=""
    _histdb_update_state
    zle recursive-edit -K histdb
}

zle -N self-insert-histdb
zle -N histdb-search

bindkey '^h' histdb-search

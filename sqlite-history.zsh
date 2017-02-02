which sqlite3 >/dev/null 2>&1 || return;

typeset -g HISTDB_QUERY=""
typeset -g HISTDB_FILE="${HOME}/.zsh/history.db"
typeset -g HISTDB_SESSION=""
typeset -g HISTDB_MAX_ROWID=""

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

    IFS=$tab read -r -d '' rowid pwd ret start cmd < \
       <(_histdb -separator $tab \
                 "select rowid, pwd, ret, start, cmd from hist where $1 limit 1;")

    HISTDB_RESULT[rowid]="$rowid"
    HISTDB_RESULT[pwd]="$pwd"
    HISTDB_RESULT[ret]="$ret"
    HISTDB_RESULT[start]="$start"
    HISTDB_RESULT[cmd]="${cmd[0,-2]}"

    return 0
}

_histdb_gen_sql () {
    local rowid_part
    if [[ -n ${HISTDB_MAX_ROWID} ]]; then
        rowid_part="and rowid < ${HISTDB_MAX_ROWID}"
    fi
    echo "cmd like '%$(sql_escape $@)%' $rowid_part order by rowid desc"
}

_histdb_render () {
    POSTDISPLAY="
>> ${HISTDB_RESULT[cmd]} [${HISTDB_RESULT[pwd]}] ${HISTDB_RESULT[rowid]}"
}

_histdb_update_state () {
    _histdb_query "$(_histdb_gen_sql ${BUFFER})"
    _histdb_render
}

self-insert-histdb () {
    zle .self-insert
    _histdb_update_state
}

histdb-backwards () {
    HISTDB_MAX_ROWID=${HISTDB_RESULT[rowid]}
    _histdb_update_state
    if [[ -z $HISTDB_RESULT[rowid] ]] ; then
        HISTDB_MAX_ROWID=""
        _histdb_update_state
    fi
}

histdb-search () {
    bindkey -N histdb $KEYMAP
    bindkey -M histdb '^h' histdb-backwards

    HISTDB_MAX_ROWID=""

    # ideally, iterate on keymap and hook all editing commands to refresh
    _histdb_update_state
    zle recursive-edit -K histdb
}

zle -N histdb-backwards
zle -N self-insert-histdb
zle -N histdb-search

bindkey '^h' histdb-search

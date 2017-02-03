which sqlite3 >/dev/null 2>&1 || return;

typeset -g HISTDB_QUERY=""
typeset -g HISTDB_FILE="${HOME}/.zsh/history.db"
typeset -g HISTDB_SESSION=""
typeset -g HISTDB_MAX_ROWID=""
typeset -g HISTDB_HOST=""

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
        _histdb <<-EOF
create table commands (argv text, unique(argv) on conflict ignore);
create table places   (host text, dir text, unique(host, dir) on conflict ignore);
create table history  (session int,
                       command_id int references commands (rowid),
                       place_id int references places (rowid),
                       exit_status int,
                       start_time int,
                       duration int);
EOF
    fi
    if [[ -z "${HISTDB_SESSION}" ]]; then
        HISTDB_HOST="'$(sql_escape ${HOST})'"
        HISTDB_SESSION=$(_histdb "select 1+max(session) from history inner join places on places.rowid=history.place_id where places.host = ${HISTDB_HOST}")
        HISTDB_SESSION="${HISTDB_SESSION:-0}"
        readonly HISTDB_SESSION
    fi
}

zshaddhistory () {
    local retval=$?
    local cmd="'$(sql_escape ${1[0, -2]})'"
    local pwd="'$(sql_escape ${PWD})'"
    local now="${_FINISHED:-$(date +%s)}"
    local started=${_STARTED:-${now}}
    _histdb_init
    if [[ "$cmd" != "''" ]]; then
        _histdb \
"insert into commands (argv) values (${cmd});
insert into places   (host, dir) values (${HISTDB_HOST}, ${pwd});
insert into history
  (session, command_id, place_id, exit_status, start_time, duration)
select
  ${HISTDB_SESSION},
  commands.rowid,
  places.rowid,
  ${retval},
  ${started},
  ${now} - ${started}
from
  commands, places
where
  commands.argv = ${cmd} and
  places.host = ${HISTDB_HOST} and
  places.dir = ${pwd}
;"

    fi
    return 0
}

histdb () {
    local -a opts
    local -a hosts
    local -a indirs
    local -a atdirs
    local -a sessions

    zparseopts -E -D -a opts -host+::=hosts -in+::=indirs -at+::=atdirs d s+::=sessions -from:- -until:- -limit:-

    # TODO replace of ~ is a bit wrong
    # TODO the time calculation here is bound to be a bit slow

    local selcols="session, dir"
    local cols="session, replace(places.dir, '$HOME', '~') as dir"
    local where="not (commands.argv like 'histdb%')"
    local limit="${LINES:-25}"

    if [[ -n "$*" ]]; then
        where="${where} and commands.argv like '%$(sql_escape $@)%'"
    fi

    if (( ${#hosts} )); then
        local hostwhere=""
        for host ($hosts); do
            host="${${host#--host}#=}"
            hostwhere="${hostwhere}${hostwhere:+ or }places.host='$(sql_escape ${host:-$HOST})'"
        done
        where="${where}${hostwhere:+ and (${hostwhere})}"
        cols="${cols}, places.host as host"
        selcols="${selcols}, host"
    else
        where="${where} and places.host=${HISTDB_HOST}"
    fi

    if (( ${#indirs} + ${#atdirs} )); then
        local dirwhere=""
        for dir ($indirs); do
            dir="${${${dir#--in}#=}:-$PWD}"
            dirwhere="${dirwhere}${dirwhere:+ or }places.dir like '$(sql_escape $dir)%'"
        done
        for dir ($atdirs); do
            dir="${${${dir#--at}#=}:-$PWD}"
            dirwhere="${dirwhere}${dirwhere:+ or }places.dir = '$(sql_escape $dir)'"
        done
        where="${where}${dirwhere:+ and (${dirwhere})}"
    fi

    if (( ${#sessions} )); then
        local sin=""
        for ses ($sessions); do
            ses="${${${ses#-s}#=}:-${HISTDB_SESSION}}"
            sin="${sin}${sin:+, }$ses"
        done
        where="${where}${sin:+ and session in ($sin)}"
    fi

    local debug=0
    for opt ($opts); do
        case $opt in
            --from=*)
                local from=${opt#--from=}
                case $from in
                    -*)
                        from="datetime('now', '$from')"
                        ;;
                    today)
                        from="datetime('now', 'start of day')"
                        ;;
                    yesterday)
                        from="datetime('now', 'start of day', '-1 day')"
                        ;;
                esac
                where="${where} and datetime(start_time, 'unixepoch') >= $from"
            ;;
            --until=*)
                local until=${opt#--until=}
                case $until in
                    -*)
                        until="datetime('now', '$until')"
                        ;;
                    today)
                        until="datetime('now', 'start of day')"
                        ;;
                    yesterday)
                        until="datetime('now', 'start of day', '-1 day')"
                        ;;
                esac
                where="${where} and datetime(start_time, 'unixepoch') <= $until"
            ;;
            -d)
                debug=1
                ;;
            --limit=*)
                limit=${opt#--limit=}
                ;;
        esac
    done

    sep=$'\x1f'
    cols="${cols}, replace(commands.argv, '
', '
$sep$sep$sep') as argv, max(start_time) as max_start"

    local mst="datetime(max_start, 'unixepoch')"
    local dst="datetime('now', 'start of day')"
    local timecol="strftime(case when $mst > $dst then '%H:%M' else '%d/%m' end, max_start, 'unixepoch') as ts"

    selcols="${timecol}, ${selcols}, argv"

    query="select ${selcols} from (select ${cols}
from
  history
  left join commands on history.command_id = commands.rowid
  left join places on history.place_id = places.rowid
where ${where}
group by history.command_id, history.place_id
order by max_start desc
limit $limit) order by max_start asc" #TODO limit limits the top

    if [[ $debug = 1 ]]; then
        echo "$query"
    else
#            sed "/^[0-9]/! s/^/$sep$sep$sep/g" |
        _histdb -separator $sep "$query" |
            column -t -s $sep
    fi
}

# TODO interactive search
# TODO more forms of date query?

bindkey '^h' histdb-search

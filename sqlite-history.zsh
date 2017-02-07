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

declare -a _BORING_COMMANDS
_BORING_COMMANDS=("^ls$" "^cd$" "^ " "^histdb" "^top$" "^htop$")

zshaddhistory () {
    local retval=$?
    local cmd="${1[0, -2]}"

    for boring ($_BORING_COMMANDS); do
        if [[ "$cmd" =~ $boring ]]; then
            return 0
        fi
    done

    local cmd="'$(sql_escape $cmd)'"
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

histdb-top () {
    _histdb_init
    local sep=$'\x1f'
    local field
    local join
    local table
    1=${1:-cmd}
    case "$1" in
        dir)
            field=places.dir
            join='places.rowid = history.place_id'
            table=places
            ;;
        cmd)
            field=commands.argv
            join='commands.rowid = history.command_id'
            table=commands
            ;;;
    esac
    _histdb -separator "$sep" \
            -header \
            "select count(*) as count, places.host, replace($field, '
', '
$sep$sep') as ${1:-cmd} from history left join commands on history.command_id=commands.rowid left join places on history.place_id=places.rowid group by places.host, $field order by count(*)" |
        column -t -s "$sep"
}

histdb () {
    _histdb_init
    local -a opts
    local -a hosts
    local -a indirs
    local -a atdirs
    local -a sessions

    zparseopts -E -D -a opts -host+::=hosts -in+::=indirs -at+::=atdirs d s+::=sessions -from:- -until:- -limit:-

    local selcols="session as ses, dir"
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
            hostwhere="${hostwhere}${host:+${hostwhere:+ or }places.host='$(sql_escape ${host})'}"
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
    local timecol="strftime(case when $mst > $dst then '%H:%M' else '%d/%m' end, max_start, 'unixepoch') as time"

    selcols="${timecol}, ${selcols}, argv as cmd"

    query="select ${selcols} from (select ${cols}
from
  history
  left join commands on history.command_id = commands.rowid
  left join places on history.place_id = places.rowid
where ${where}
group by history.command_id, history.place_id
order by max_start desc
limit $limit) order by max_start asc"

    if [[ $debug = 1 ]]; then
        echo "$query"
    else
        _histdb -header -separator $sep "$query" | column -t -s $sep
    fi
}

# merge encrypted history databases

_histdb_merge () {
    local ancestor=${1:?three databases required}; shift
    local ours=${1:?three databases required}; shift
    local theirs=${1:?three databases required}
    KEY="AAAAB3NzaC1yc2EAAAADAQABAAABAQC8B1DrrW4CIKEu+ZLkvk8C+1cdgMLHoDUpIzFaWhOiRimpsZ9KAX9a4LY0oCYziWCfxIKYILtz+Z93O/7zEyTQSa1Hu0ygh5t05qBY//o7NwhdvMikw5mGEgEcXgE8VC0tlfgZmz+c7n0sRwAQW2Gezqo9L5LhKaxtpNXWcYP/RYahR/RYqG7nK/cErurNG2qZznawWFnYivB+MSX2J3dl0dJXe8zsLmKens0wuDbsxoRJrvL24TlPktXWzGz324PEiCK5lvGdbl/s6wVAzJHHagqyschqGq7NXyI+jNUgJB8SxisHjYDq6LOJyc2i6VXZ39N1oqcDZ3I1QF78s0tD"
    $ZSH/encrypt-filter "$KEY" decrypt "$ancestor" | cat > "$ancestor"
    $ZSH/encrypt-filter "$KEY" decrypt "$ours" | cat > "$ours"
    $ZSH/encrypt-filter "$KEY" decrypt "$theirs" | cat > "$theirs"

    sqlite3 "${ours}" <<EOF
ATTACH DATABASE '${theirs}' AS o;
ATTACH DATABASE '${ancestor}' AS a;

-- copy missing commands and places
INSERT INTO commands (argv) SELECT argv FROM o.commands;
INSERT INTO places (host, dir) SELECT host, dir FROM o.places;

-- insert missing history, rewriting IDs
-- could uniquify sessions by host in this way too

INSERT INTO history (session, command_id, place_id, exit_status, start_time, duration)
SELECT HO.session, C.rowid, P.rowid, HO.exit_status, HO.start_time, HO.duration
FROM o.history HO
     LEFT JOIN o.places PO ON HO.place_id = PO.rowid
     LEFT JOIN o.commands CO ON HO.command_id = CO.rowid
     LEFT JOIN commands C ON C.argv = CO.argv
     LEFT JOIN places P ON (P.host = PO.host
                             AND P.dir = PO.dir)
WHERE HO.rowid > (SELECT MAX(rowid) FROM a.history)
;
EOF

    $ZSH/encrypt-filter "$KEY" encrypt "$ours" | cat > "$ours"
}

# (
# WITH RECURSIVE left (start_time, host) AS
#   (SELECT history.start_time, places.host
#    FROM history LEFT JOIN places ON history.place_id = places.rowid),
# right (id, start_time, host) AS
#   (SELECT o.history.rowid as id, o.history.start_time, o.places.host
#    FROM o.history LEFT JOIN o.places ON o.history.place_id = o.places.rowid)
# SELECT right.id FROM left INNER JOIN right ON left.start_time=right.start_time AND left.host = right.host
# )


# TODO interactive search
# TODO more forms of date query?

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

# merge two history databases

_histdb_merge () {
    local first=${1:?two databases required}; shift
    local second=${1:?two databases required}

    echo "merge $first $second"

    sqlite3 "${first}" <<EOF
ATTACH DATABASE '${second}' AS o;

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
WHERE HO.rowid >
(
WITH RECURSIVE left (start_time) AS
  (SELECT history.start_time
   FROM history LEFT JOIN places ON history.place_id = places.rowid
   WHERE places.host = ${HISTDB_HOST}),
right (id, start_time) AS
  (SELECT o.history.rowid as id, o.history.start_time
   FROM o.history LEFT JOIN o.places ON o.history.place_id = o.places.rowid
   WHERE o.places.host = ${HISTDB_HOST})
SELECT max(right.id) FROM left INNER JOIN right ON left.start_time=right.start_time
)
;
EOF
}

# TODO interactive search
# TODO more forms of date query?

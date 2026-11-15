#!/usr/bin/env bash
set -euo pipefail

MIN_ID=1073741824 # 2^30 (0x40000000)
MAX_ID=2147483647 # 2^31 - 1 (0x7fffffff)
SW_DIR="${SW_DIR:-$(dirname "$(realpath "$0")")/sw}"

usage() {
    echo "Usage: $0 [--check|-c]" >&2
    exit 2
}

check_only=0
if (( $# > 0 ))
then
    case "$1" in
        --check|-c)
            check_only=1
            shift
            ;;
        *)
            usage
            ;;
    esac
fi
(( $# == 0 )) || usage

declare -A seen_user_file=()
declare -A seen_uid_file=()
declare -A seen_uid_user=()
declare -A seen_group_file=()
declare -A seen_gid_file=()
declare -A seen_gid_group=()
declare -A used_ids=()
declare -a pending_primary_gids=()
declare -a pending_group_members=()

errors=0
err() {
    echo "mkuid: error: $*" >&2
    errors=$(( errors + 1 ))
}

shopt -s nullglob
passwd_files=("$SW_DIR"/*.passwd)
group_files=("$SW_DIR"/*.group)
shopt -u nullglob

for f in "${group_files[@]}"
do
    base="$(basename "$f" .group)"
    if [[ ! -f "$SW_DIR/$base" ]]
    then
        err "$f: no matching package recipe '$SW_DIR/$base'"
    fi

    lineno=0
    while IFS= read -r line || [[ -n "$line" ]]
    do
        lineno=$(( lineno + 1 ))
        loc="$f:$lineno"

        if [[ -z "$line" || "$line" == \#* || "$line" == +* || "$line" == -* ]]
        then
            err "$loc: blank, comment, or NIS (+/-) lines are not valid in group(5)"
            continue
        fi

        IFS=: read -r gname gpass gid gmembers extra <<< "$line"
        colons="${line//[^:]/}"
        if (( ${#colons} != 3 )) || [[ -n "${extra:-}" ]]
        then
            err "$loc: expected 4 colon-separated fields (name:passwd:gid:members)"
            continue
        fi

        if [[ ! "$gname" =~ ^[a-z_][a-z0-9_-]*$ ]]
        then
            err "$loc: invalid group name '$gname'"
        fi

        if [[ "$gpass" != "x" && "$gpass" != "*" ]]
        then
            err "$loc: group '$gname' password field must be 'x' or '*' (got '$gpass')"
        fi

        if [[ ! "$gid" =~ ^(0|[1-9][0-9]*)$ ]]
        then
            err "$loc: group '$gname' has non-numeric GID '$gid'"
            continue
        fi

        if [[ "$gname" == "root" ]]
        then
            (( gid == 0 )) || err "$loc: group 'root' must have GID 0 (got $gid)"
        elif [[ "$gname" == "tty" ]]
        then
            (( gid == 5 )) || err "$loc: group 'tty' must have GID 5 (got $gid)"
        elif [[ "$gname" == "nogroup" ]]
        then
            (( gid == 65534 )) || err "$loc: group 'nogroup' must have GID 65534 (got $gid)"
        else
            if (( gid < MIN_ID || gid > MAX_ID ))
            then
                err "$loc: group '$gname' GID $gid outside [$MIN_ID, $MAX_ID]"
            fi
        fi

        if [[ -n "${seen_group_file[$gname]:-}" ]]
        then
            err "$loc: duplicate group name '$gname' (already in ${seen_group_file[$gname]})"
        else
            seen_group_file[$gname]="$loc"
        fi

        if [[ -n "${seen_gid_file[$gid]:-}" ]]
        then
            err "$loc: duplicate GID $gid for '$gname' (already used by '${seen_gid_group[$gid]}' in ${seen_gid_file[$gid]})"
        else
            seen_gid_file[$gid]="$loc"
            seen_gid_group[$gid]="$gname"
        fi

        if [[ -n "$gmembers" ]]
        then
            pending_group_members+=("$loc|$gname|$gmembers")
        fi

        used_ids[$gid]=1
    done < "$f"
done

for f in "${passwd_files[@]}"
do
    base="$(basename "$f" .passwd)"
    if [[ ! -f "$SW_DIR/$base" ]]
    then
        err "$f: no matching package recipe '$SW_DIR/$base'"
    fi

    lineno=0
    while IFS= read -r line || [[ -n "$line" ]]
    do
        lineno=$(( lineno + 1 ))
        loc="$f:$lineno"

        if [[ -z "$line" || "$line" == \#* || "$line" == +* || "$line" == -* ]]
        then
            err "$loc: blank, comment, or NIS (+/-) lines are not valid in passwd(5)"
            continue
        fi

        IFS=: read -r uname upass uid gid gecos home shell extra <<< "$line"
        colons="${line//[^:]/}"
        if (( ${#colons} != 6 )) || [[ -n "${extra:-}" ]]
        then
            err "$loc: expected 7 colon-separated fields (name:passwd:uid:gid:gecos:dir:shell)"
            continue
        fi

        if [[ ! "$uname" =~ ^[a-z_][a-z0-9_-]*$ ]]
        then
            err "$loc: invalid user name '$uname'"
        fi

        if [[ ! "$uid" =~ ^(0|[1-9][0-9]*)$ ]]
        then
            err "$loc: user '$uname' has non-numeric UID '$uid'"
            continue
        fi

        if [[ ! "$gid" =~ ^(0|[1-9][0-9]*)$ ]]
        then
            err "$loc: user '$uname' has non-numeric GID '$gid'"
            continue
        fi

        if [[ "$uname" == "root" ]]
        then
            (( uid == 0 )) || err "$loc: user 'root' must have UID 0 (got $uid)"
            (( gid == 0 )) || err "$loc: user 'root' must have GID 0 (got $gid)"
            [[ "$upass" == "x" ]] || err "$loc: user 'root' password field must be 'x' (got '$upass')"
        elif [[ "$uname" == "nobody" ]]
        then
            (( uid == 65534 )) || err "$loc: user 'nobody' must have UID 65534 (got $uid)"
            (( gid == 65534 )) || err "$loc: user 'nobody' must have GID 65534 (got $gid)"
            [[ "$upass" == "*" ]] || err "$loc: user 'nobody' password field must be '*' (got '$upass')"
        else
            if (( uid < MIN_ID || uid > MAX_ID ))
            then
                err "$loc: user '$uname' UID $uid outside [$MIN_ID, $MAX_ID]"
            fi
            if [[ "$upass" != "*" ]]
            then
                err "$loc: vendor user '$uname' password field must be '*' (unshadowed locked account; got '$upass')"
            fi
        fi

        if [[ "$home" != /* ]]
        then
            err "$loc: user '$uname' home directory '$home' must be an absolute path"
        fi

        if [[ "$shell" != /* ]]
        then
            err "$loc: user '$uname' shell '$shell' must be an absolute path"
        fi

        if [[ -n "${seen_user_file[$uname]:-}" ]]
        then
            err "$loc: duplicate user name '$uname' (already in ${seen_user_file[$uname]})"
        else
            seen_user_file[$uname]="$loc"
        fi

        if [[ -n "${seen_uid_file[$uid]:-}" ]]
        then
            err "$loc: duplicate UID $uid for '$uname' (already used by '${seen_uid_user[$uid]}' in ${seen_uid_file[$uid]})"
        else
            seen_uid_file[$uid]="$loc"
            seen_uid_user[$uid]="$uname"
        fi

        used_ids[$uid]=1
        pending_primary_gids+=("$loc|$uname|$gid")
    done < "$f"
done

for entry in "${pending_primary_gids[@]}"
do
    IFS='|' read -r loc uname gid <<< "$entry"
    if [[ -z "${seen_gid_file[$gid]:-}" ]]
    then
        err "$loc: user '$uname' references primary GID $gid not defined in any $SW_DIR/*.group"
    fi
done

for entry in "${pending_group_members[@]}"
do
    IFS='|' read -r loc gname gmembers <<< "$entry"
    IFS=',' read -ra members <<< "$gmembers"
    for m in "${members[@]}"
    do
        if [[ -z "$m" || -z "${seen_user_file[$m]:-}" ]]
        then
            err "$loc: group '$gname' lists unknown member '$m' not defined in any $SW_DIR/*.passwd"
        fi
    done
done

if (( errors > 0 ))
then
    exit 1
fi

if (( check_only == 1 ))
then
    exit 0
fi

while true
do
    rand32=$(od -An -tu4 -N4 /dev/urandom | tr -d '[:space:]')
    candidate=$(( MIN_ID + (rand32 & 1073741823) ))
    if [[ -z "${used_ids[$candidate]:-}" ]]
    then
        echo "$candidate"
        exit 0
    fi
done

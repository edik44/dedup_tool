#!/bin/bash
# SPDX-License-Identifier: LicenseRef-dedup-tool
#
# dedup_tool.sh — prepares big wordlists (password and login dictionaries, any line
# lists, gigabytes) and removes the lines that are already in reference files.
# Russian and English interface. Run it without arguments for the menu, or with
# --help. Free to use; selling and donations are not allowed, see LICENSE.

if [[ "${BASH_SOURCE[0]}" != "$0" ]]; then
    echo "Запускайте файлом / Run it as a file: bash ${BASH_SOURCE[0]##*/}" >&2
    return 1 2>/dev/null || exit 1
fi
case $- in *i*) exec "$BASH" -- "$0" "$@" ;; esac

set -o pipefail
shopt -s extglob

# Colours — only when stdout is a terminal (NO_COLOR turns them off).
GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; RED='\033[0;31m'; CYAN='\033[1;36m'; NC='\033[0m'
if [[ ! -t 1 || -n "${NO_COLOR:-}" ]]; then
    GREEN=''; YELLOW=''; BLUE=''; RED=''; CYAN=''; NC=''
fi

# Settings. DEDUP_WORK_ROOT — where the WSL temp folders go.
VERSION="1.3.0"
SCRIPT_NAME="$(basename "$0")"
DEFAULT_TIMEOUT=20
DEFAULT_SPLIT_SIZE="2G"
COMPARE_DIR="Compare Files"
UNSORTED_DIR="UNSORTED"
LOG_DIR="logs"
WORK_ROOT="${DEDUP_WORK_ROOT:-$HOME/dedup_work}"

# Interface language: ru or en. Order: --lang, DEDUP_LANG, the choice saved
# from the menu, the system language (LC_ALL/LC_MESSAGES/LANG; in Git Bash and
# WSL the Windows language).
UI_LANG=""
LANG_FILE="${XDG_CONFIG_HOME:-$HOME/.config}/dedup_tool/lang"
lang_norm() { case "${1,,}" in ru*) REPLY=ru ;; en*) REPLY=en ;; *) REPLY="" ;; esac; }
in_wsl() { grep -qi microsoft /proc/version 2>/dev/null; }
lang_windows() {
    local v="" reg="" m
    REPLY=""
    if [[ -n "${DEDUP_TEST_WINLANG+x}" ]]; then
        v="$DEDUP_TEST_WINLANG"
    elif in_wsl; then
        if ! reg="$(command -v reg.exe 2>/dev/null)"; then
            for m in /mnt/[a-z]; do
                [[ -x "$m/Windows/System32/reg.exe" ]] && { reg="$m/Windows/System32/reg.exe"; break; }
            done
        fi
        [[ -n "$reg" ]] && v="$("$reg" query 'HKCU\Control Panel\International' /v LocaleName </dev/null 2>/dev/null | tr -d '\r' | awk '$1 == "LocaleName" { print $3 }')"
    else
        case "$(uname -s 2>/dev/null)" in
            MINGW*|MSYS*|CYGWIN*) v="$(locale -uU 2>/dev/null)" ;;
        esac
    fi
    v="${v,,}"
    case "$v" in ru*) REPLY=ru ;; ?*) REPLY=en ;; esac
}
lang_detect() {
    local v=""
    lang_norm "${DEDUP_LANG:-}"
    [[ -n "$REPLY" ]] && { UI_LANG="$REPLY"; return; }
    if [[ -r "$LANG_FILE" ]]; then
        read -r v < "$LANG_FILE"
        lang_norm "$v"
        [[ -n "$REPLY" ]] && { UI_LANG="$REPLY"; return; }
    fi
    v="${LC_ALL:-${LC_MESSAGES:-${LANG:-}}}"
    case "${v,,}" in ru*) UI_LANG=ru; return ;; esac
    if [[ -n "$v" && "${v^^}" != C* && "${v^^}" != POSIX ]] && ! in_wsl; then UI_LANG=en; return; fi
    lang_windows
    UI_LANG="${REPLY:-en}"
}
L() { if [[ "$UI_LANG" == en ]]; then printf -v "$1" '%s' "$3"; else printf -v "$1" '%s' "$2"; fi; }
case "${1:-}" in
    --lang|--lang=*)
        if [[ "$1" == --lang ]]; then lang_norm "${2:-}"; shift; else lang_norm "${1#--lang=}"; fi
        shift
        if [[ -z "$REPLY" ]]; then
            echo "--lang: ru | en" >&2
            exit 2
        fi
        DEDUP_LANG="$REPLY"
        ;;
esac
lang_detect

declare -a IN_PROGRESS=()
declare -a TMP_DIRS=()
declare -a COUNTER_PIDS=()
# Ctrl+C: remove unfinished files, temp folders and background counters; log it.
on_interrupt() {
    [[ -n "${PROGRESS_PID:-}" ]] && kill "$PROGRESS_PID" 2>/dev/null
    (( ${#COUNTER_PIDS[@]} > 0 )) && kill "${COUNTER_PIDS[@]}" 2>/dev/null
    (( ${#IN_PROGRESS[@]} > 0 )) && rm -f -- "${IN_PROGRESS[@]}"
    (( ${#TMP_DIRS[@]} > 0 )) && rm -rf -- "${TMP_DIRS[@]}"
    if (( BASH_SUBSHELL == 0 )); then
        local m
        out "\n${YELLOW}Прервано пользователем${NC}" "\n${YELLOW}Interrupted by the user${NC}"
        [[ -n "$WSL_TEMP_DIR" ]] && out "Временная папка: $WSL_TEMP_DIR" "Temp folder: $WSL_TEMP_DIR"
        L m "ПРЕРВАНО пользователем (Ctrl+C)" "INTERRUPTED by the user (Ctrl+C)"; log_line "$m"
        L m "прервано" "interrupted"; log_footer "$m"
    fi
    exit 130
}
trap on_interrupt INT

declare -a RESULT_FILES=() ACTION_FILES=() WSL_RETURNED=()
FINAL_DIR=""
WSL_TEMP_DIR=""
WSL_REFS_BACK=true
ACTION_ORIG_DIR=""
ACTION_KIND=""
declare -a EXTRA_REFS=() QUEUE_REFS=() QUEUE_REF_SKIP=()
declare -a PREP_REF_NAMES=() PREP_REF_HITS=()
declare -A MEMO=() MEMO_NEW=()
QUEUE_ON=false
QUEUE_REFS_READY=false
MEMO_ON=false

LOG_FILE=""
LOG_T0=0

# One line to the action log only: with the time, without colour codes.
log_line() {
    [[ -n "$LOG_FILE" ]] || return 0
    local s ts nl=$'\n' esc=$'\e'
    printf -v s '%b' "$*"
    s="${s//$esc\[*([0-9;])m/}"
    s="${s##+($nl)}"
    [[ -n "$s" ]] || return 0
    printf -v ts '%(%H:%M:%S)T' -1
    printf '%s  %s\n' "$ts" "${s//$nl/$nl$ts  }" >> "$LOG_FILE" 2>/dev/null
    return 0
}

# say "ru" "en": print (like echo -e) and log the text in the UI language.
say() { local m="$1"; [[ "$UI_LANG" == en && $# -gt 1 ]] && m="$2"; echo -e "$m"; log_line "$m"; }
# out "ru" "en": print only, without logging (menus).
out() { local m="$1"; [[ "$UI_LANG" == en && $# -gt 1 ]] && m="$2"; echo -e "$m"; }

# Current time in milliseconds into REPLY, without a subshell.
ms_now() {
    if [[ -n "${EPOCHREALTIME:-}" ]]; then
        local t="${EPOCHREALTIME/[.,]/}"
        REPLY=$(( 10#${t%???} ))
    else
        REPLY=$(( SECONDS * 1000 ))
    fi
}

# Duration in ms → "1.4 s", "2 min 05 s", "1 h 05 min".
fmt_dur() {
    local ms="${1:-0}" s c="," u_s="с" u_m="мин" u_h="ч"
    [[ "$UI_LANG" == en ]] && { c="."; u_s="s"; u_m="min"; u_h="h"; }
    (( ms < 0 )) && ms=0
    if (( ms < 60000 )); then
        printf "%d${c}%d ${u_s}" $(( ms / 1000 )) $(( ms % 1000 / 100 ))
    else
        s=$(( ms / 1000 ))
        if (( s < 3600 )); then
            printf "%d ${u_m} %02d ${u_s}" $(( s / 60 )) $(( s % 60 ))
        else
            printf "%d ${u_h} %02d ${u_m}" $(( s / 3600 )) $(( s % 3600 / 60 ))
        fi
    fi
}

# 1234567 → "1 234 567" (ru) or "1,234,567" (en).
fmt_num() {
    local n="${1:-0}" out="" sep=" "
    [[ "$UI_LANG" == en ]] && sep=","
    while (( ${#n} > 3 )); do out="${sep}${n: -3}${out}"; n="${n:0:${#n}-3}"; done
    printf '%s' "${n}${out}"
}

# Size in bytes → "246 B", "57 MB", "6.5 GB".
fmt_size() {
    local b="${1:-0}" c="," ug="ГБ" um="МБ" uk="КБ" ub="Б"
    [[ "$UI_LANG" == en ]] && { c="."; ug="GB"; um="MB"; uk="KB"; ub="B"; }
    if (( b >= 1073741824 )); then
        printf "%d${c}%d ${ug}" $(( b / 1073741824 )) $(( b % 1073741824 * 10 / 1073741824 ))
    elif (( b >= 1048576 )); then
        printf "%d ${um}" $(( (b + 524288) / 1048576 ))
    elif (( b >= 1024 )); then
        printf "%d ${uk}" $(( (b + 512) / 1024 ))
    else
        printf "%d ${ub}" "$b"
    fi
}

# Size in MB with two decimals: 94465 → "0.09 MB", below 0.01 → "< 0.01 MB".
fmt_mb() {
    local b="${1:-0}" c d="," u="МБ"
    [[ "$UI_LANG" == en ]] && { d="."; u="MB"; }
    c=$(( (b * 100 + 524288) / 1048576 ))
    if (( c == 0 && b > 0 )); then printf '< 0%s01 %s' "$d" "$u"; return; fi
    printf "%d${d}%02d ${u}" $(( c / 100 )) $(( c % 100 ))
}

file_size() { stat -L -c %s -- "$1" 2>/dev/null || echo 0; }

PROGRESS_PID=""
PROGRESS_EVERY="${DEDUP_PROGRESS_EVERY:-5}"
# Bytes already read from the given files (Linux /proc/<pid>/fdinfo) into REPLY; -1 if unknown.
progress_read_pos() {
    local f p link pos sum=-1
    local -a expr=()
    REPLY=-1
    [[ -r /proc/self/fdinfo/0 ]] || return 0
    for f in "$@"; do
        p="${f//\\/\\\\}"; p="${p//\*/\\*}"; p="${p//\?/\\?}"; p="${p//\[/\\[}"
        (( ${#expr[@]} > 0 )) && expr+=(-o)
        expr+=(-lname "$p")
    done
    while IFS= read -r link; do
        pos=""
        while read -r f p; do [[ "$f" == pos: ]] && { pos="$p"; break; }; done < "${link/\/fd\//\/fdinfo\/}" 2>/dev/null
        [[ "$pos" =~ ^[0-9]+$ ]] || continue
        (( sum < 0 )) && sum=0
        sum=$(( sum + pos ))
    done < <(find /proc/[0-9]*/fd -maxdepth 1 \( "${expr[@]}" \) 2>/dev/null)
    REPLY=$sum
}
# Progress line of a long step, rewritten every few seconds; terminal (stderr) only.
progress_start() {
    progress_stop
    [[ -t 2 || -n "${DEDUP_FORCE_PROGRESS:-}" ]] || return 0
    local what="$1" total="${2:-0}" mode="${3:-size}" main=$$ f
    shift 3
    local -a paths=()
    for f in "$@"; do
        if [[ $mode == read ]]; then paths+=("$(realpath -- "$f" 2>/dev/null || printf '%s' "$f")"); else paths+=("$f"); fi
    done
    (
        local sl="" t0 el done_b s t line seen=false word
        L word скопировано copied
        [[ $mode == read ]] && L word прочитано read
        trap 'kill "$sl" 2>/dev/null; exit 0' TERM
        ms_now; t0=$REPLY
        while :; do
            sleep "$PROGRESS_EVERY" & sl=$!
            wait "$sl"
            kill -0 "$main" 2>/dev/null || exit 0
            ms_now; el=$(( REPLY - t0 ))
            L line "  … ${what}: прошло $(fmt_dur "$el")" "  … ${what}: $(fmt_dur "$el") elapsed"
            if (( total > 0 )); then
                done_b=0
                if [[ $mode == size ]]; then
                    for f in "${paths[@]}"; do s=$(file_size "$f"); done_b=$(( done_b + s )); done
                else
                    progress_read_pos "${paths[@]}"; done_b=$REPLY
                    if (( done_b >= 0 )); then seen=true
                    elif $seen; then done_b=$total
                    fi
                fi
                (( done_b > total )) && done_b=$total
                if (( done_b >= total )) && [[ $mode == read ]]; then
                    L t ", вход прочитан — идёт сортировка и запись" ", input read — sorting and writing"; line+="$t"
                elif (( done_b > 0 )); then
                    L t ", ${word} $(fmt_size "$done_b") из $(fmt_size "$total") ($(( done_b * 100 / total )) %)" ", ${word} $(fmt_size "$done_b") of $(fmt_size "$total") ($(( done_b * 100 / total ))%)"; line+="$t"
                    (( done_b < total )) && { L t ", осталось около $(fmt_dur $(( el * (total - done_b) / done_b )))" ", about $(fmt_dur $(( el * (total - done_b) / done_b ))) left"; line+="$t"; }
                fi
            fi
            printf '\r\033[K%s' "$line" >&2
        done
    ) >/dev/null &
    PROGRESS_PID=$!
    COUNTER_PIDS+=("$PROGRESS_PID")
}
# Stop the progress line and clear it.
progress_stop() {
    [[ -n "$PROGRESS_PID" ]] || return 0
    local p
    local -a keep=()
    kill "$PROGRESS_PID" 2>/dev/null
    wait "$PROGRESS_PID" 2>/dev/null
    printf '\r\033[K' >&2
    for p in "${COUNTER_PIDS[@]}"; do [[ "$p" == "$PROGRESS_PID" ]] || keep+=("$p"); done
    COUNTER_PIDS=("${keep[@]}")
    PROGRESS_PID=""
}

# Environment for the log header: WSL, Git Bash or the OS.
env_name() {
    if grep -qi microsoft /proc/version 2>/dev/null; then
        echo "WSL (${WSL_DISTRO_NAME:-Linux})"
    else
        case "$(uname -s 2>/dev/null)" in
            MINGW*|MSYS*|CYGWIN*) echo "Git Bash ($(uname -s))" ;;
            *) echo "$(uname -s 2>/dev/null) $(uname -r 2>/dev/null)" ;;
        esac
    fi
}

# New log logs/<name>_<action>_<date>_<time>.log with a header.
log_open() {
    local kind="$1" name="$2" dir stamp f n=2
    shift 2
    LOG_FILE=""
    dir="$(pwd)/$LOG_DIR"
    if ! mkdir -p "$dir" 2>/dev/null; then
        out "${YELLOW}⚠ Не удалось создать папку $LOG_DIR/ — лог не пишется${NC}" "${YELLOW}⚠ Could not create the $LOG_DIR/ folder — no log is written${NC}" >&2
        return 0
    fi
    printf -v stamp '%(%Y-%m-%d_%H-%M-%S)T' -1
    f="$dir/${name}_${kind}_${stamp}.log"
    while [[ -e "$f" ]]; do f="$dir/${name}_${kind}_${stamp}_${n}.log"; n=$((n + 1)); done
    {
        echo "==== ${SCRIPT_NAME} v${VERSION} ===="
        local m
        L m 'Начало:   ' 'Started:  '; printf '%s%(%Y-%m-%d %H:%M:%S)T\n' "$m" -1
        L m "Действие: $kind $*" "Action:   $kind $*"; echo "$m"
        L m "Папка:    " "Folder:   "; echo "$m$(pwd)"
        if [[ "$UI_LANG" == en ]]; then echo "Env:      $(env_name), bash ${BASH_VERSION%%(*}, UTF-8 locale: ${UTF8_LOCALE:-none}, interface: English"
        else echo "Среда:    $(env_name), bash ${BASH_VERSION%%(*}, UTF-8 локаль: ${UTF8_LOCALE:-нет}, язык: русский"; fi
        echo
    } >> "$f" 2>/dev/null && LOG_FILE="$f"
}

# Last log line: how the action ended and how long it took.
log_footer() {
    [[ -n "$LOG_FILE" ]] || return 0
    ms_now
    local m
    L m '\n==== Итог: %s, время %s ====\n' '\n==== Result: %s, time %s ====\n'
    printf "$m" "$1" "$(fmt_dur $(( REPLY - LOG_T0 )))" >> "$LOG_FILE" 2>/dev/null
}

# A UTF-8 locale for character-aware grep (length filter, UTF-8 check).
pick_utf8_locale() {
    local all
    all="$(locale -a 2>/dev/null)" || return 1
    local cand hit
    for cand in '^C\.utf-?8$' '^en_US\.utf-?8$' '^ru_RU\.utf-?8$'; do
        hit="$(grep -iE "$cand" <<<"$all" | head -1)"
        [[ -n "$hit" ]] && { printf '%s' "$hit"; return 0; }
    done
    hit="$(grep -iE 'utf-?8' <<<"$all" | head -1)"
    [[ -n "$hit" ]] && { printf '%s' "$hit"; return 0; }
    return 1
}
UTF8_LOCALE="$(pick_utf8_locale || true)"
if [[ -z "$UTF8_LOCALE" ]]; then
    out "${YELLOW}⚠ UTF-8 локаль не найдена (locale -a). Фильтр длины строк будет считать байты, а не символы — для кириллицы/эмодзи результат может быть неверным.${NC}" "${YELLOW}⚠ No UTF-8 locale found (locale -a). The length filter will count bytes, not characters — wrong for Cyrillic or emoji.${NC}" >&2
fi
if ! command -v iconv >/dev/null 2>&1; then
    out "${YELLOW}⚠ iconv не найден — конвертация кодировки будет недоступна (проверка/удаление нечитаемых строк всё равно работает).${NC}" "${YELLOW}⚠ iconv not found — encoding conversion is unavailable (the check and removal of unreadable lines still work).${NC}" >&2
fi

CR_CHR=$'\r'
has_crlf() { LC_ALL=C grep -qaU "${CR_CHR}\$" -- "$1" 2>/dev/null; }

has_bom() { [[ "$(head -c3 "$1" 2>/dev/null)" == $'\xef\xbb\xbf' ]]; }

# Remove CRLF and the UTF-8 BOM in place (references only, after a question).
strip_cr_bom() {
    if ! LC_ALL=C sed -i -e '1s/^\xEF\xBB\xBF//' -e 's/\r$//' "$1"; then
        say "${RED}✘ не удалось убрать CRLF/BOM в ${1##*/}${NC}" "${RED}✘ could not remove CRLF/BOM in ${1##*/}${NC}" >&2
        return 1
    fi
}

# Print UTF-16LE or UTF-16BE if the file looks like UTF-16 (BOM or many null bytes).
detect_utf16() {
    head -c 65536 "$1" 2>/dev/null | od -An -v -tx1 -w2 | awk '
        NR == 1 && $1 == "ff" && $2 == "fe" { print "UTF-16LE"; bom = 1; exit }
        NR == 1 && $1 == "fe" && $2 == "ff" { print "UTF-16BE"; bom = 1; exit }
        { n++; if ($2 == "00") le++; if ($1 == "00") be++ }
        END {
            if (bom || n == 0) exit
            if ((le + be) * 100 / n >= 5) print (le >= be ? "UTF-16LE" : "UTF-16BE")
        }'
}

iconv_known() { iconv -f "$1" -t UTF-8 </dev/null >/dev/null 2>&1; }

# Pipeline stages: each reads stdin and writes stdout; parameters are in P_* variables.
_st_iconv() { iconv -f "$P_ENC" -t UTF-8 -c; }
_st_strip() { LC_ALL=C sed -e '1s/^\xEF\xBB\xBF//' -e 's/\r$//'; }
_st_strip_all() { LC_ALL=C sed -e 's/\xEF\xBB\xBF//g' -e 's/\r$//'; }
BOM_CHR=$'\xef\xbb\xbf'
_st_valid() { LC_ALL="$UTF8_LOCALE" grep -ax '.*'; }
_st_fffd() { LC_ALL=C grep -av $'\xef\xbf\xbd'; }
CTRL_RE=$'[\x01-\x08\x0b\x0c\x0e-\x1f\x7f]'
C1_RE=$'\xc2[\x80-\x9f]'
_st_ctrl() { LC_ALL=C grep -av -e "$CTRL_RE" -e "$C1_RE"; }
# Make control characters visible in examples: ␀…␟, ␡ and □ for U+0080–U+009F.
ctrl_visible() {
    local -a ex=(-e 's/\r$//')
    local c e
    for (( c = 0; c < 32; c++ )); do
        (( c == 9 || c == 10 )) && continue
        printf -v e 's/\\x%02x/\\xe2\\x90\\x%02x/g' "$c" $(( 0x80 + c ))
        ex+=(-e "$e")
    done
    LC_ALL=C sed -b "${ex[@]}" -e 's/\x7f/\xe2\x90\xa1/g' -e 's/\xc2[\x80-\x9f]/\xe2\x96\xa1/g'
}
MOJI_CONT=$'(\xc2[\x80-\xbf]|\xe2\x80[\x93\x94\x98\x99\x9a\x9c\x9d\x9e\xa0\xa1\xa2\xa6\xb0\xb9\xba]|\xe2\x82\xac|\xe2\x84\xa2|\xc5[\x92\x93\xa0\xa1\xb8\xbd\xbe]|\xc6\x92|\xcb[\x86\x9c])'
MOJI_CHAR=$'(\xc3[\x82-\x9f]'"$MOJI_CONT"$'|\xc3[\xa0-\xaf]'"$MOJI_CONT$MOJI_CONT"$'|\xc3[\xb0-\xb4]'"$MOJI_CONT$MOJI_CONT$MOJI_CONT"')'
MOJI_RE=$'^([\x09\x20-\x7e]|'"$MOJI_CHAR"$')+\r?$'
MOJI_LEAD=$'\xc3[\x82-\xb4]'
MOJI_CYR=$'\xc3[\x90\x91]'
declare -a MOJI_SED=()
# sed program that restores UTF-8 read as Windows-1252 or Latin-1 (MOJI_SED).
moji_sed_build() {
    local b e p h i
    local sp="e282ac:80 e2809a:82 c692:83 e2809e:84 e280a6:85 e280a0:86 e280a1:87
              cb86:88 e280b0:89 c5a0:8A e280b9:8B c592:8C c5bd:8E e28098:91 e28099:92
              e2809c:93 e2809d:94 e280a2:95 e28093:96 e28094:97 cb9c:98 e284a2:99
              c5a1:9A e280ba:9B c593:9C c5be:9E c5b8:9F"
    MOJI_SED=(-e ':a' -e "/${MOJI_LEAD}/"'!b' -e "/${MOJI_RE}/"'!b')
    for (( b = 0x80; b <= 0xbf; b++ )); do
        printf -v e 's/\\xc2\\x%02x/\\x01%02X/g' "$b" "$b"; MOJI_SED+=(-e "$e")
    done
    for (( b = 0xc0; b <= 0xff; b++ )); do
        printf -v e 's/\\xc3\\x%02x/\\x01%02X/g' $(( b - 0x40 )) "$b"; MOJI_SED+=(-e "$e")
    done
    for p in $sp; do
        h="${p%:*}"; e="s/"
        for (( i = 0; i < ${#h}; i += 2 )); do e+="\\x${h:i:2}"; done
        MOJI_SED+=(-e "${e}/\\x01${p#*:}/g")
    done
    for (( b = 0x80; b <= 0xff; b++ )); do
        printf -v e 's/\\x01%02X/\\x%02x/g' "$b" "$b"; MOJI_SED+=(-e "$e")
    done
    MOJI_SED+=(-e 's/\xef\xbb\xbf//g' -e 'ba')
}
moji_sed_build
_st_moji() { LC_ALL=C sed -b -E "${MOJI_SED[@]}"; }
W1251_HI="80:d082 81:d083 82:e2809a 83:d193 84:e2809e 85:e280a6 86:e280a0 87:e280a1
          88:e282ac 89:e280b0 8a:d089 8b:e280b9 8c:d08a 8d:d08c 8e:d08b 8f:d08f
          90:d192 91:e28098 92:e28099 93:e2809c 94:e2809d 95:e280a2 96:e28093 97:e28094
          98:c298 99:e284a2 9a:d199 9b:e280ba 9c:d19a 9d:d19c 9e:d19b 9f:d19f
          a0:c2a0 a1:d08e a2:d19e a3:d088 a4:c2a4 a5:d290 a6:c2a6 a7:c2a7
          a8:d081 a9:c2a9 aa:d084 ab:c2ab ac:c2ac ad:c2ad ae:c2ae af:d087
          b0:c2b0 b1:c2b1 b2:d086 b3:d196 b4:d291 b5:c2b5 b6:c2b6 b7:c2b7
          b8:d191 b9:e28496 ba:d194 bb:c2bb bc:d198 bd:d085 be:d195 bf:d197"
DOS_GS=$'(\xd0[\x82\x83\x88-\x8c\x8f]|\xd1[\x92\x93\x99-\x9c\x9f])'
DOS_GB=$'(\xd0\x8e|\xd1\x9e)'
DOS_GU=$'(\xd2\x90|\xd0[\x84\x87])'
DOS_GR=$'\xd0\x81'
DOS_PUNCT=$'(\xc2[\x98\xa0\xa4\xa6\xa7\xa9\xab-\xae]|\xe2\x80[\x93\x94\x98-\x9a\x9c-\x9e\xa0-\xa2\xa6\xb0\xb9\xba]|\xe2\x82\xac|\xe2\x84\xa2)'
DOS_SYM="(${DOS_GS}|${DOS_GB}|${DOS_GU}|${DOS_PUNCT})"
DOS_RE=$'^([\x09\x20-\x7e]|\xd0[\x81\xb0-\xbf]|'"$DOS_SYM"$')+\r?$'
DOS_CYR=$'[\xd0-\xd2]'
DOS_APP=$'\xd0[\xb0-\xbf]'
U8_P=$'(\xc2[\x98\xa0\xa4\xa6\xa7\xa9\xab-\xae\xb0\xb1\xb5-\xb7\xbb]|\xd0[\x81\x83-\x88\x8e]|\xd1[\x91\x92\x94-\x9c\x9e\x9f]|\xd2[\x90\x91]|\xe2\x80[\x93\x94\x98\x99\x9c\x9d\xa2\xba]|\xe2\x84[\x96\xa2])'
U8_S=$'(\xd0[\x82\x83\x89-\x8c\x8f]|\xd1\x93|\xe2\x80[\x98\x9a\x9e\xa0\xa1\xa6\xb0\xb9]|\xe2\x82\xac)'
U8_PAIR=$'(\xd0\xa0'"$U8_P"$'|\xd0\xa1'"$U8_S"')'
U8_RE=$'^([\x09\x20-\x7e]|'"$U8_PAIR"$')+\r?$'
W_80_8F=$'\xd0[\x82\x83\x89-\x8c\x8f]|\xd1\x93|\xe2\x80[\x9a\x9e\xa0\xa1\xa6\xb0\xb9]|\xe2\x82\xac'
W_90_9F=$'\xd1[\x92\x99-\x9c\x9f]|\xe2\x80[\x93\x94\x98\x99\x9c\x9d\xa2\xba]|\xc2\x98|\xe2\x84\xa2'
W_A0_BF=$'\xc2[\xa0\xa4\xa6\xa7\xa9\xab-\xae\xb0\xb1\xb5-\xb7\xbb]|\xd0[\x81\x84-\x88\x8e]|\xd1[\x91\x94-\x98\x9e]|\xd2[\x90\x91]|\xe2\x84\x96'
W_ANY="(${W_80_8F}|${W_90_9F}|${W_A0_BF})"
U8X_START=$'(\xd0[\x92-\xbf]|\xd1[\x80-\x84])'"$W_ANY"
U8X_CHAR=$'(\xd0\x92('"$W_A0_BF"$')|\xd0[\x93-\xaf]'"$W_ANY"$'|\xd0\xb0('"$W_A0_BF"')'"$W_ANY"$'|\xd0[\xb1-\xbc\xbe\xbf]'"$W_ANY$W_ANY"$'|\xd0\xbd('"$W_80_8F|$W_90_9F"')'"$W_ANY"$'|\xd1\x80('"$W_90_9F|$W_A0_BF"')'"$W_ANY$W_ANY"$'|\xd1[\x81-\x83]'"$W_ANY$W_ANY$W_ANY"$'|\xd1\x84('"$W_80_8F"')'"$W_ANY$W_ANY"')'
U8X_RE=$'^([\x09\x20-\x7e]|'"$U8X_CHAR"$')+\r?$'
DOSP_RE=$'^('"$DOS_PUNCT"$'){3,}\r?$'
U8X_LAT=$'\xd0[\x93-\x95]'"$W_ANY"
U8X_G="[A-Za-z].*${U8X_LAT}|${U8X_LAT}.*[A-Za-z]|${W_80_8F}|${W_90_9F}"$'|\xc2[\xb0\xb1\xb5-\xb7\xbb]|\xd0[\x92-\xaf]\xc2[\xa0\xa4\xa6\xa7\xa9\xab-\xae]|\xd0\xbf\xd1\x97\xd0\x85'
declare -a CYR_SED=() DOS_SEL=() U8_SEL=() DOSP_SED=()
# sed program for mojibake through Windows-1251: Russian DOS text and UTF-8 (CYR_SED).
cyr_sed_build() {
    local p h i b e hx
    local -A u=()
    for p in $W1251_HI; do
        h="${p#*:}"; e=""
        for (( i = 0; i < ${#h}; i += 2 )); do e+="\\x${h:i:2}"; done
        u[${p%%:*}]="$e"
    done
    CYR_SED=(-e "/${DOS_SYM}|${U8X_START}/"'!b' -e "/${U8_RE}/"'!bx8')
    for (( b = 0x90; b <= 0xbf; b++ )); do
        (( b == 0xa0 || b == 0xa1 )) && continue
        printf -v hx '%02x' "$b"
        CYR_SED+=(-e "s/\\xd0\\xa0${u[$hx]}/\\xd0\\x${hx}/g")
    done
    CYR_SED+=(-e "s/\\xd0\\xa0${u[81]}/\\xd0\\x81/g")
    for (( b = 0x80; b <= 0x8f; b++ )); do
        printf -v hx '%02x' "$b"
        CYR_SED+=(-e "s/\\xd0\\xa1${u[$hx]}/\\xd1\\x${hx}/g")
    done
    CYR_SED+=(-e "s/\\xd0\\xa1${u[91]}/\\xd1\\x91/g")
    CYR_SED+=(-e "s/\\xd0\\xa0${u[a0]}/\\xd0\\xa0/g" -e "s/\\xd0\\xa0${u[a1]}/\\xd0\\xa1/g" -e 'b')
    CYR_SED+=(-e ':x8' -e "/${U8X_RE}/"'!bd' -e "/${U8X_G}/"'!bd')
    for p in $W1251_HI; do
        CYR_SED+=(-e "s/${u[${p%%:*}]}/\\x01${p%%:*}/g")
    done
    for (( b = 0xc2; b <= 0xef; b++ )); do
        printf -v e 's/\\xd0\\x%02x/\\x01%02x/g' $(( b - 0x30 )) "$b"; CYR_SED+=(-e "$e")
    done
    for (( b = 0xf0; b <= 0xf4; b++ )); do
        printf -v e 's/\\xd1\\x%02x/\\x01%02x/g' $(( b - 0x70 )) "$b"; CYR_SED+=(-e "$e")
    done
    for (( b = 0x80; b <= 0xf4; b++ )); do
        printf -v e 's/\\x01%02x/\\x%02x/g' "$b" "$b"; CYR_SED+=(-e "$e")
    done
    CYR_SED+=(-e 's/\xef\xbb\xbf//g' -e 'b')
    local -a rule
    rule=(-e "/${DOS_SYM}/"'!b' -e "/${DOS_RE}/"'!b' -e "/${DOS_CYR}/"'!b' -e '/[A-Za-z]/b'
          -e "/${DOS_PUNCT}/bx" -e "/${DOS_APP}/"'!bx'
          -e "/${DOS_GS}/"'!bg1' -e "/${DOS_GB}|${DOS_GU}|${DOS_GR}/bx" -e ':g1'
          -e "/${DOS_GB}/"'!bg2' -e "/${DOS_GU}|${DOS_GR}/bx" -e ':g2'
          -e "/${DOS_GU}/"'!b' -e "/${DOS_GR}/bx" -e 'b' -e ':x')
    DOS_SEL=(-e "/${U8X_RE}/{" -e "/${U8X_G}/b" -e '}' "${rule[@]}" -e 'p')
    U8_SEL=(-e "/${U8_RE}/{" -e 'p' -e 'b' -e '}' -e "/${U8X_RE}/{" -e "/${U8X_G}/p" -e '}')
    CYR_SED+=(-e ':d' "${rule[@]}")
    for (( i = 0; i < 16; i++ )); do
        printf -v e 's/\\xd0\\x%02x/\\xd1\\x%02x/g' $(( 0xb0 + i )) $(( 0x80 + i ))
        CYR_SED+=(-e "$e")
    done
    DOSP_SED=(-e "/${DOSP_RE}/"'!b' -e '/^(.+)\1+\r?$/b')
    for (( b = 0x80; b <= 0xaf; b++ )); do
        printf -v hx '%02x' "$b"
        printf -v e 's/%s/\\xd0\\x%02x/g' "${u[$hx]}" $(( b + 0x10 ))
        CYR_SED+=(-e "$e")
        DOSP_SED+=(-e "$e")
    done
}
cyr_sed_build
_st_cyr() { LC_ALL=C sed -b -E "${CYR_SED[@]}"; }
_st_dos_sel() { LC_ALL=C sed -n -b -E "${DOS_SEL[@]}"; }
_st_u8_sel() { LC_ALL=C sed -n -b -E "${U8_SEL[@]}"; }
_st_dosp() { LC_ALL=C sed -b -E "${DOSP_SED[@]}"; }
_st_dosp_sel() { LC_ALL=C sed -n -b -E -e '/^(.+)\1+\r?$/!p'; }
KOI_BI='479787685789893799956766650004880733348337137558275465234243532330933248358266479457561343941832250823327007336359173261102200112100846348548355478576462344312632341569787675889997799955656651202540622157207241253222142211000321200856566337245677452350112203521230669678586888897689945778640113570233344132254464347644244510101310925126239147359286782341301112320953449339467459516573313111592671853218029445568636283223420722140944679349372299438884465331962460489998676889996899956657660004550814148137247459595574135210533340955669549265679657784545532643461746337218097668747974444412572290957349129465479597574434322782451466666654467664777735636650003830643116007424226453543203520222110715235326035457355452222201313200623027017251114101140110000510010752008107363373422352201130231101714108008064355312561000100161100601007008051131020151003000100000001004000010010120001000000000130047447342855841556510714520100020033346033061583317504244330010550123223110455452343402200100001100143234221343333245601324380002200135455451355561356611434350000530001000000000020010100100000000000'
KOI_SEP=$'[\x09\x20-\x40\x5b-\x60\x7b-\x7e]'
KOI_UP=$'\xd0[\x88\x90-\xaf]'
KOI_LO=$'(\xd0[\xb0-\xbf]|\xd1[\x80-\x8f\x96])'
KOI_WORD="${KOI_LO}?(${KOI_UP})+"
KOI_RE="^${KOI_SEP}*${KOI_WORD}(${KOI_SEP}+${KOI_WORD})*${KOI_SEP}*"$'\r?$'
KOI_AWK='
function koi(s,    i, n, c, ch, r, t, pr, pt, sr, st, out) {
    n = length(s); pr = -1; pt = -1; sr = 0; st = 0; out = ""; LET = 0
    for (i = 1; i <= n; i++) {
        c = substr(s, i, 1)
        if (c == D0 || c == D1) {
            ch = substr(s, i, 2); i++
            r = RAW[ch]; t = TI[ch]; out = out TO[ch]; LET++
            if (pt >= 0) {
                if (pr >= 0 && r >= 0) sr += T[pr * 33 + r]
                st += T[pt * 33 + t]
            }
            pr = r; pt = t
        } else out = out c
    }
    OUT = out
    return LET >= 3 && st > sr
}
BEGIN {
    D0 = "\320"; D1 = "\321"; M1 = "\001"; M2 = "\002"
    abc = "абвгдежзийклмнопрстуфхцчшщъыьэюяё"
    up = "АБВГДЕЖЗИЙКЛМНОПРСТУФХЦЧШЩЪЫЬЭЮЯ"
    tl = "юабцдефгхийклмнопярстужвьызшэщчъ"
    tu = "ЮАБЦДЕФГХИЙКЛМНОПЯРСТУЖВЬЫЗШЭЩЧЪ"
    for (i = 0; i < 33; i++) IX[substr(abc, 2 * i + 1, 2)] = i
    for (i = 0; i < 32; i++) {
        c = substr(up, 2 * i + 1, 2); d = substr(abc, 2 * i + 1, 2); t = substr(tl, 2 * i + 1, 2)
        RAW[c] = i; RAW[d] = i
        TO[c] = t; TO[d] = substr(tu, 2 * i + 1, 2)
        TI[c] = IX[t]; TI[d] = IX[t]
    }
    RAW["Ј"] = -1; RAW["і"] = -1; TO["Ј"] = "ё"; TO["і"] = "Ё"; TI["Ј"] = 32; TI["і"] = 32
    for (i = 0; i < 1089; i++) T[i] = substr(bi, i + 1, 1) + 0
}
{
    if (mode == "fix") {
        c = substr($0, 1, 1)
        if (c == M1) { s = substr($0, 2); print (koi(s) ? OUT : s) }
        else if (c == M2) print substr($0, 2)
        else print
    } else if (mode == "sel") {
        if (koi($0)) print
    } else {
        if (koi($0)) vote++
        if (LET >= 3) cand++
    }
}
END { if (mode == "count") print cand + 0, vote + 0, NR + 0 }
'
_st_koi() {
    LC_ALL=C sed -b -E -e '/^[\x01\x02]/{' -e 's/^/\x02/' -e 'b' -e '}' -e "/${KOI_RE}/s/^/\\x01/" \
        | LC_ALL=C awk -v BINMODE=3 -v mode=fix -v bi="$KOI_BI" "$KOI_AWK"
}
_koi_cands() { LC_ALL=C grep -a -E "$KOI_RE" -- "$1" 2>/dev/null; }
_koi_awk() { LC_ALL=C awk -v BINMODE=3 -v mode="$1" -v bi="$KOI_BI" "$KOI_AWK"; }
# KOI8-R text read as Windows-1251: only if most all-caps lines of the file look so.
KOI_ALL=0; KOI_REST=0
detect_koi() {
    local cand=0 vote=0 lines=0
    KOI_ALL=0; KOI_REST=0
    read -r cand vote lines < <(_koi_cands "$1" | head -n 200000 | _koi_awk count)
    [[ "$cand" =~ ^[0-9]+$ && "$vote" =~ ^[0-9]+$ ]] || return 0
    (( cand >= 20 && vote * 100 >= cand * 70 )) || return 0
    if (( lines >= 200000 )); then
        read -r cand vote lines < <(_koi_cands "$1" | _koi_awk count)
        [[ "$cand" =~ ^[0-9]+$ && "$vote" =~ ^[0-9]+$ ]] || return 0
        (( vote * 100 >= cand * 70 )) || return 0
    fi
    KOI_ALL=$vote; KOI_REST=$(( cand - vote ))
    return 0
}
_st_unmoji() { _st_moji | _st_cyr | { if (( ${dosp_all:-0} > 0 )); then _st_dosp; else cat; fi; } | { if (( ${s7_all:-0} > 0 )); then _st_s7; else cat; fi; }; }
S7_SET='\x00-\x09\x0b-\x2f\x60-\x6f\x71'
S7_LINE_RE='^(?!\r?$)[\x00-\x09\x0b-\x2f\x60-\x6f\x71]+$'
declare -a S7_SED=()
# sed program that restores the lines of Russian CP866 text without the high bit.
s7_sed_build() {
    (( ${#S7_SED[@]} > 0 )) && return 0
    local b e
    S7_SED=(-e "/^[${S7_SET}]*\$/"'!b' -e ':a' -e 's/\r(.)/\xd0\x9d\1/g' -e 'ta')
    [[ "${1:-false}" == true ]] && S7_SED+=(-e 's/\r$/\xd0\x9d/')
    for (( b = 0; b <= 0x2f; b++ )); do
        (( b == 0x0a || b == 0x0d )) && continue
        printf -v e 's/[\\x%02x]/\\xd0\\x%02x/g' "$b" $(( 0x90 + b ))
        S7_SED+=(-e "$e")
    done
    for (( b = 0x60; b <= 0x6f; b++ )); do
        printf -v e 's/[\\x%02x]/\\xd1\\x%02x/g' "$b" $(( 0x80 + b - 0x60 ))
        S7_SED+=(-e "$e")
    done
    S7_SED+=(-e 's/[\x71]/\xd1\x91/g')
}
_st_s7() { LC_ALL=C sed -b -E "${S7_SED[@]}"; }
_st_crsplit() { LC_ALL=C sed -b -E -e ':a' -e 's/\r(.)/\n\1/g' -e 'ta'; }
BLANK_RE='^[ \t]*\r?$'
_st_blank() { LC_ALL=C grep -a -U -v -P "$BLANK_RE"; }
# Up to three "before → after" examples of restored lines.
moji_examples() {
    local fix="$1" first="${2:-}" cand raw="" mi
    local -a ex=() fx=()
    cand="$(LC_ALL=C grep -a -m 50 -E '^.{1,60}$' | LC_ALL=C sed -b 's/\r$//')"
    [[ -n "$first" ]] && raw="$(LC_ALL=C grep -a -m 3 -E "$first" <<<"$cand")"
    [[ -n "$raw" ]] || raw="$(head -n 3 <<<"$cand")"
    [[ -n "$raw" ]] || return 0
    mapfile -t ex < <(printf '%s\n' "$raw" | ctrl_visible)
    mapfile -t fx < <(printf '%s\n' "$raw" | "$fix" | ctrl_visible)
    say "  Например:" "  For example:"
    for (( mi = 0; mi < ${#ex[@]}; mi++ )); do
        say "   «${ex[mi]//\\/\\\\}» → «${fx[mi]//\\/\\\\}»"
    done
}
NUL_WORD_RE='^\x00?(?:[\x20-\x7e]\x00)+\r?$|^(?:\x00[\x20-\x7e])+\r?$'
NUL_JUNK_RE='^(?!\x00?(?:[\x20-\x7e]\x00)+\r?$|(?:\x00[\x20-\x7e])+\r?$).*\x00'
_st_nul() { LC_ALL=C tr -d '\000'; }
_st_nul_words() { LC_ALL=C sed -b -E '/^\x00?([ -~]\x00)+\r?$|^(\x00[ -~])+\r?$/s/\x00//g'; }
_st_nuldel() { LC_ALL=C grep -avP "$P_NUL_RE"; }
# Length filter, in characters (UTF-8 locale).
_st_len() {
    if [[ -n "$UTF8_LOCALE" ]]; then
        LC_ALL="$UTF8_LOCALE" grep -aE "^.{${P_MIN},${P_MAX}}\$"
    else
        grep -aE "^.{${P_MIN},${P_MAX}}\$"
    fi
}
_st_dig() { LC_ALL=C grep -avE "$P_DIG_RE"; }
_st_count() { tee "${P_FIFO[$1]}"; }
_st_save() { tee "${P_SAVE[$1]}"; }

# Help in the interface language.
show_help() { if [[ "$UI_LANG" == en ]]; then show_help_en; else show_help_ru; fi; }

# Help in Russian.
show_help_ru() {
    echo -e "${CYAN}${SCRIPT_NAME} v${VERSION} — очистка и дедупликация больших текстовых файлов${NC}"
    echo -e "${CYAN}============================================================${NC}"
    echo
    echo -e "${GREEN}ЗАПУСК:${NC}"
    echo "  ./${SCRIPT_NAME}               главное меню — обычный способ работы"
    echo "  ./${SCRIPT_NAME} --help | -h   эта справка"
    echo "  ./${SCRIPT_NAME} --version     показать версию и выйти"
    echo "  ./${SCRIPT_NAME} --lang en     интерфейс по-английски (--lang ru — по-русски)"
    echo "  Язык сам выбирается по языку системы (в Git Bash и WSL — по языку Windows)."
    echo "  Пункт 8 меню «Язык / Language» меняет его и запоминает выбор; ещё можно"
    echo "  задать переменную DEDUP_LANG=ru или en."
    echo "  Первый запуск в Windows: dedup_tool_first_windows_start.bat рядом со скриптом —"
    echo "  двойное нажатие. Он найдёт Git for Windows (нет — предложит установить) и"
    echo "  запустит скрипт в своей папке. Потом этот файл не нужен: скрипт запускается и"
    echo "  сам — двойным нажатием на файл в Проводнике."
    echo
    echo -e "${GREEN}─── Меню ───────────────────────────────────────────────────${NC}"
    echo "  1  Полная обработка: подготовка → сортировка → сравнение с эталонами"
    echo "     → <имя>_final.txt"
    echo "  2  Только подготовка → <имя>_prep.txt (если такой уже есть — спросит:"
    echo "     перезаписать или сохранить как <имя>_prep_2.txt, Enter — второе)"
    echo "  3  Только сравнение с эталонами (один файл или все) → <имя>_final.txt."
    echo "     Файл берётся как есть, без подготовки: мусор (NUL, U+FFFD, управляющие"
    echo "     символы), короткие строки и строки из цифр в итоге остаются. Сырой файл —"
    echo "     в пункт 1. Пункт 2, а потом 3 на <имя>_prep.txt — то же, что пункт 1."
    echo "     Если в файле есть такой мусор или строки не в UTF-8, скрипт предупредит."
    echo "  4  Несколько словарей по очереди → <имя>_final.txt у каждого. Каждый файл —"
    echo "     как пункт 1, но чистится и от итогов всех предыдущих: первый остаётся"
    echo "     целым, в следующих нет строк, которые уже были раньше. Список идёт от"
    echo "     большого файла к меньшему. Порядок — номера через пробел (3 1 2), Enter —"
    echo "     все по списку, кроме итогов _final, файлов объединения и убранных строк"
    echo "     (_short, _digits, _notutf8); перед началом его покажут ещё раз."
    echo "     Вопросы — один раз: для следующих файлов берётся тот же ответ. Итоги"
    echo "     остаются в рабочей папке, в '$COMPARE_DIR/' ничего не добавляется;"
    echo "     эталонов может и не быть — тогда файлы чистятся только друг от друга."
    echo "     Когда очередь пройдена целиком, исходные словари уходят в новую папку"
    echo "     originals_<дата-время>/ — в рабочей папке остаются итоги."
    echo "  5  Объединить итоги _final в один файл → merged.txt и merged_list.txt."
    echo "     Файлы склеиваются без повторов; в merged_list.txt — из каких файлов"
    echo "     собран merged.txt, по имени в строке. Номера через пробел, Enter — все"
    echo "     итоги _final. Если merged.txt уже есть — merged_2.txt и т.д."
    echo "  6  Разделить готовый файл на части → папка <имя>_parts/"
    echo "  7  Работа со словарями: логины, раскладка, регистр, алфавиты, поиск — см. ниже"
    echo "  8  Язык / Language      9  Справка      0  Выход"
    echo "  Если рабочий файл — копия эталона из '$COMPARE_DIR/', скрипт предупредит до"
    echo "  вопросов: такой файл сравнится сам с собой, и его итог будет пустым."
    echo "  Если файл — архив под видом .txt (gzip, zip, 7z, rar, bzip2, xz, zstd),"
    echo "  действие не начнётся, а скрипт подскажет, как его распаковать."
    echo "  Рабочий файл выбирается из *.txt текущей папки: если он один — берётся"
    echo "  сам, иначе — по номеру из списка (итоги _final, merged и списки помечены)."
    echo "  Меню и выбор файла ждут ответа без таймаута; после действия — снова меню."
    echo "  Промежуточных файлов нет: пункты 1, 3 и 4 идут одним проходом от входа до"
    echo "  итога, на диск пишется только <имя>_final.txt. Нужен файл после подготовки —"
    echo "  это пункт 2."
    echo
    echo -e "${GREEN}─── Подготовка (пункты 1, 2 и 4) ──────────────────────────${NC}"
    echo "  Сначала все вопросы — ответы только запоминаются. Потом файл ОДИН раз"
    echo "  проходит через конвейер из выбранных шагов: у пункта 2 — в <имя>_prep.txt,"
    echo "  у пунктов 1 и 4 — дальше, через сортировку и сравнение, прямо в итог."
    echo
    echo "   • UTF-16 → UTF-8   [вопрос, только если файл похож на UTF-16; Enter: ДА]"
    echo "     Определяется по BOM или по нулевым байтам 00H."
    echo "   • CRLF и BOM       [вопрос, только если найдены; Enter: ДА]"
    echo "     Убирает \\r в конце строк и UTF-8 BOM — невидимый U+FEFF — в начале файла"
    echo "     и внутри него (так бывает, когда список склеен из файлов с BOM)."
    echo "   • CR внутри строки [вопрос, только если найден; Enter: ДА]"
    echo "     Редакторы показывают такой CR как перенос: одна строка выглядит как две,"
    echo "     а если CR в начале — как пустая строка перед словом. Такие строки разбиваются."
    echo "   • Слова в UTF-16   [вопрос, только если найдены; Enter: ДА]"
    echo "     Строки, где после каждой буквы байт NUL (00H): «␀p␀a␀s␀s» → «pass»."
    echo "     Из-за них редакторы считают файл двоичным, а с эталоном они не совпадают."
    echo "   • Кракозябры       [вопрос, только если найдены; Enter: ДА]"
    echo "     Текст, который прочитали не в той кодировке и снова записали в UTF-8:"
    echo "      – UTF-8 как Windows-1252 или Latin-1: «Ð¿Ð°Ñ€Ð¾Ð»ÑŒ» → «пароль»;"
    echo "      – русский текст из DOS (CP866) как Windows-1251: «ЏаЁўҐв» → «Привет»; строка"
    echo "        из одних знаков (¤®¬ → дом) — только если в файле уже есть такие строки;"
    echo "      – UTF-8 как Windows-1251: «РџСЂРёРІРµС‚» → «Привет», и другие знаки: «cafГ©» →"
    echo "        «café». Настоящие слова вроде «дії» не трогаются;"
    echo "      – русский текст в KOI8-R как Windows-1251: «РТЙЧЕФ» → «привет». Только если"
    echo "        так выглядит большинство строк заглавными, а каждую строку проверяет"
    echo "        частота сочетаний букв: настоящее слово заглавными изредка тоже будет"
    echo "        переведено, короткое — чаще;"
    echo "      – русский текст в DOS (CP866) без старшего бита: «а» стала пробелом, другие"
    echo "        буквы — знаками. Узнаётся по всему файлу, а не по строке; настоящие дефис"
    echo "        и пробел станут буквами, строки с цифрами и латиницей не трогаются."
    echo "     Сколько строк каждого вида и примеры — до вопроса, вопрос один на все."
    echo "     Восстанавливаются только строки, целиком состоящие из таких знаков"
    echo "     (и латиницы, цифр): обычный текст и смесь не трогаются."
    echo "     Это идёт до фильтров: длина считается по восстановленному тексту."
    echo "   • Кириллица не в UTF-8  [сама находит WINDOWS-1251, KOI8-R или CP866]"
    echo "     Если строки не в UTF-8, скрипт по частым русским буквам узнаёт кодировку"
    echo "     и показывает пару строк после перевода. Весь файл в ней — она"
    echo "     подставится по Enter на вопросе о кодировке. Если рядом и строки в"
    echo "     UTF-8 (смешанный файл) — спросит, перекодировать ли только строки не в"
    echo "     UTF-8 (Enter: ДА); остальные не трогаются. В редакторе эти кодировки —"
    echo "     «Кириллица (Windows)», «Кириллица (KOI8-R)», «Кириллица (DOS)»."
    echo "   • Проверка UTF-8   [Enter: НЕТ; если UTF-16 не сконвертирован или"
    echo "     кодировка найдена — ДА]"
    echo "     Можно указать исходную кодировку (например WINDOWS-1251, KOI8-R, CP866,"
    echo "     ISO-8859-5, MACCYRILLIC) — тогда сначала iconv. Убирает строки с"
    echo "     невалидными UTF-8-байтами, с символом-заменителем U+FFFD (след уже"
    echo "     случившейся плохой перекодировки) и с байтами NUL, если их не"
    echo "     восстановили. Отдельным шагом — строки с управляющими символами:"
    echo "     коды 01–1F (кроме таба), 7F и U+0080–U+009F."
    echo "     В редакторе это непонятные значки, в итоге они шли бы первыми."
    echo "     Сколько таких строк и примеры — до вопроса. Если кодировка не определилась,"
    echo "     до вопроса будет сказано, сколько строк не в UTF-8 уберёт проверка."
    echo "   • Пустые строки    [вопрос, только если найдены; Enter: ДА]"
    echo "     Пустые строки и строки из одних пробелов и табов. Строки с пробелами только"
    echo "     по краям слова не трогает: их считает проверка итога."
    echo "   • Длина строки     [Enter: НЕТ] оставляет строки от N до M символов"
    echo "     (спросит оба числа, по умолчанию 8 и 16). Считает символы, не байты."
    echo "   • Только цифры     [Enter: НЕТ] удаляет строки из одних цифр. Какие —"
    echo "     спросит: 8 — до 8 цифр включительно, 8-10 — от 8 до 10, Enter — все."
    echo "     Строку с пробелом по краям («80808080 ») не трогает: такие строки"
    echo "     посчитает проверка итога."
    echo "   • Убранные строки  [вопрос, если включён фильтр длины или цифр или проверка"
    echo "     уберёт строки не в UTF-8; Enter: НЕТ]"
    echo "     Строки короче минимума — в <имя>_short.txt, строки из цифр — в"
    echo "     <имя>_digits.txt, без повторов. Длиннее максимума не сохраняются. Строки"
    echo "     не в UTF-8 — в <имя>_notutf8.txt, как есть."
    echo "  После прохода — статистика: сколько строк убрал каждый шаг."
    echo
    echo -e "${GREEN}─── Сравнение (пункты 1, 3 и 4) ───────────────────────────${NC}"
    echo "  Каждый эталон из '$COMPARE_DIR/' — одно поколение сравнения, по порядку имён:"
    echo "   1. Эталоны проверяются всегда: CRLF и BOM, порядок строк (побайтово,"
    echo "      LC_ALL=C), дубли. Эталон, который и так в порядке, не трогается."
    echo "      Исправляется только с вашего согласия  [вопрос, Enter: ДА]: CRLF/BOM —"
    echo "      на месте; пересортированный — в <имя>_sorted.txt рядом, оригинал — в"
    echo "      $COMPARE_DIR/${UNSORTED_DIR}/. Неотсортированный эталон без исправления"
    echo "      пропускается: comm с ним работать не может."
    echo "   2. Рабочий файл проходит один раз: [подготовка →] sort -u (без вопроса:"
    echo "      без сортировки сравнивать нельзя, а -u убирает дубли внутри файла) →"
    echo "      comm -13 с каждым эталоном по очереди — остаётся то, чего нет ни в"
    echo "      одном. Ваш файл не меняется и никуда не переносится. У пункта 3 файл"
    echo "      идёт как есть: убираются только CRLF и BOM в начале."
    echo "      Сортировке — до половины свободной памяти и до 8 потоков. Что не влезло,"
    echo "      она сортирует кусками во временные файлы рядом с итогом и сама их"
    echo "      удаляет: места на это нужно примерно с размер словаря."
    echo "   3. Итог — <имя>_final.txt. Пишется во временный файл рядом и в конце"
    echo "      переименовывается: прерванный прогон обрезанного итога не оставит."
    echo "      Если такой итог уже есть — спросит; по умолчанию сохранит как"
    echo "      <имя>_final_2.txt. Повторный прогон на _final не даёт _final_final."
    echo "   4. Итог проверяется на строки с пробелами или табами в начале или в конце:"
    echo "      в редакторе их не видно, а «80808080 » и «80808080» — разные строки."
    echo "      Если такие есть — сколько их и сколько места, примеры — в логе. Вопроса нет:"
    echo "      убрать или обрезать их — пункт 7, утилита 14."
    echo
    echo -e "${GREEN}─── Деление (пункт 6) ──────────────────────────────────────${NC}"
    echo "  Число — столько частей (split -n l/N); размер с единицей K/M/G/T — части"
    echo "  такого размера (split -C). Строки не разрываются. Части <имя>_partNN.txt"
    echo "  кладутся в папку <имя>_parts/. Нужно только по внешним причинам: редактор"
    echo "  не открывает большой файл, FAT32 (предел 4 ГБ), пересылка по частям."
    echo "  Обработке деление не помогает: целый файл обрабатывается быстрее и без"
    echo "  дублей между частями."
    echo
    echo -e "${GREEN}─── Работа со словарями (пункт 7) ──────────────────────────${NC}"
    echo "  Исходный файл не меняется (кроме утилиты 14, если попросить), результат — новый"
    echo "  файл <имя>_<что>.txt (имя занято — _2). Логины, пароли, части строк и адреса — без"
    echo "  повторов и по порядку байтов; остальное — строка в строку, в прежнем порядке."
    echo "  После утилит 1–4 можно сохранить словарь без строк, из которых что-то извлечено:"
    echo "  строка убирается целиком, файл _rest  [вопрос, Enter: НЕТ]."
    echo "   1  Почта → логины: часть до @ у каждого адреса в строке → _logins"
    echo "   2  user:pass → _logins и _passwords: строка делится по первому «:» или «;»"
    echo "   3  Любой разделитель (: / ; --- (at)): левая часть → _left, правая → _right;"
    echo "      правая — всё после первого разделителя"
    echo "   4  Вырезать из дампа почту → _emails, ссылки → _urls, адреса IP → _ip"
    echo "   5  Раскладка: RU → EN («привет» → «ghbdtn») → _en, только строки с кириллицей;"
    echo "      EN → RU → _ru, только строки с латиницей"
    echo "   6  Регистр → _lower, _upper, _cap (первая большая), _uncap (первая маленькая)"
    echo "      или все четыре файла сразу"
    echo "   7  Строки с пробелом или табом: убрать → _nospace, первое слово → _firstword"
    echo "   8  Обрезать пробелы и табы по краям, сдвоенные внутри — в один → _trim"
    echo "   9  Убрать строки с заданными кусками (через пробел: - _ admin) → _filtered."
    echo "      Строка уходит, если есть хоть один кусок; «-admin» — один кусок, «- admin» — два"
    echo "  10  По алфавитам: _latin (и ASCII), _cyr, _greek, _hebrew, _arabic, _cjk, _other;"
    echo "      цифры и знаки алфавит не меняют, два алфавита в строке — _mixed"
    echo "  11  Самые частые строки → _top: сколько раз, для нескольких файлов — и в скольких."
    echo "      Если у конца списка счётчик тот же, что и за ним, скрипт об этом скажет"
    echo "  12  Повторы без сортировки, порядок прежний → _uniq; память и диск — как у"
    echo "      сортировки, времени вдвое больше"
    echo "  13  Найти строку в *.txt папки и в эталонах: где и сколько раз, только счёт."
    echo "      Поиск по байтам: словарь в другой кодировке так не найти
  14  Пробелы и табы по краям: вынести такие строки → _edge и убрать из словаря → _noedge,
      обрезать справа → _rtrim, обрезать слева → _ltrim. Можно заменить сам файл
      [вопрос, Enter: НЕТ]: только через временный файл, после успешной записи.
      Отсортированный файл после обрезки сортируется заново; с эталонами заново не
      сверяется
  15  Убрать из файла строки других словарей → _minus, отсортированный и без повторов.
      Словари — *.txt этой папки и эталоны, без подготовки: снимаются только CRLF и BOM"
    echo "  Раскладка, регистр и алфавиты ждут UTF-8: иначе сначала пункт 2."
    echo
    echo -e "${GREEN}─── WSL и диски Windows ───────────────────────────────────${NC}"
    echo "  Если скрипт запущен в WSL в папке на диске Windows (/mnt/c, /mnt/d ...),"
    echo "  он предупредит и предложит работать во временной папке Linux"
    echo "  (${WORK_ROOT}/<имя>_<дата-время>): туда копируются рабочий файл и"
    echo "  эталоны, обратно — только итог и эталоны, которые пришлось исправить."
    echo "  Через /mnt построчная запись идёт в сотни раз медленнее, а большой cp —"
    echo "  быстрый. После работы копии ваших файлов и эталонов и вернувшийся итог из"
    echo "  временной папки удаляются, а пустая папка удаляется сама. Объединению"
    echo "  (пункт 5) эталоны не нужны."
    echo
    echo -e "${GREEN}─── Большие словари (гигабайты) ────────────────────────────${NC}"
    echo "  Git Bash или WSL: словари примерно до 1 ГБ удобно обрабатывать и в Git Bash,"
    echo "  прямо в Windows (это зависит от ПК). С большими лучше WSL: там та же работа"
    echo "  идёт в 3–4 раза быстрее."
    echo "  На долгих шагах — копирование в папку Linux и обратно, сортировка эталона,"
    echo "  проход, объединение — нижняя строка раз в 5 с показывает, сколько прошло"
    echo "  и сколько готово: скрипт не завис."
    echo "  Память: сортировка берёт до половины свободной, остальное Linux занимает"
    echo "  кэшем файлов, поэтому WSL в диспетчере задач почти на пределе — это"
    echo "  нормально. Если после работы память не освободилась — wsl --shutdown."
    echo "  Диск: словарь 6,5 ГБ с эталоном 8,1 ГБ в WSL — по оценке около 70 ГБ записи"
    echo "  в первый раз (копии в папку Linux и обратно, сортировка эталона, временные"
    echo "  файлы sort, итог) и около 40 ГБ потом, когда эталон уже отсортирован."
    echo "  Свободного места нужно примерно втрое больше словаря и эталонов вместе —"
    echo "  в WSL скрипт проверяет это перед копированием. Без копирования и с меньшей"
    echo "  записью — если держать большие словари и эталоны прямо в Linux (в Проводнике"
    echo "  это \\\\wsl.localhost\\<дистрибутив>\\home\\<пользователь>)."
    echo "  HDD: работать будет, но медленнее — особенно копирование, если словари и"
    echo "  диск Linux лежат на одном HDD, и сортировка больших файлов. Если есть SSD —"
    echo "  держите на нём диск Linux (ext4.vhdx) и рабочую папку и не запускайте"
    echo "  одновременно другую тяжёлую работу с диском."
    echo
    echo -e "${GREEN}─── Лог ────────────────────────────────────────────────────${NC}"
    echo "  Каждое действие пишет ${LOG_DIR}/<имя>_<действие>_<дата>_<время>.log: всё, что"
    echo "  было на экране, плюс вопросы с ответами, время шагов, итоговый файл, ошибки."
    echo
    echo -e "${GREEN}─── Скрытые команды (для тестов и автоматизации) ───────────${NC}"
    echo "  ./${SCRIPT_NAME} full <file>              = пункт 1"
    echo "  ./${SCRIPT_NAME} clean <file>             = пункт 2"
    echo "  ./${SCRIPT_NAME} compare [file...]        = пункт 3 (без файлов — все *.txt папки)"
    echo "  ./${SCRIPT_NAME} split <file> <N|размер>  = пункт 6"
    echo "  ./${SCRIPT_NAME} queue <file1> <file2>... = пункт 4, файлы в этом порядке"
    echo "  ./${SCRIPT_NAME} merge [file...]          = пункт 5 (без файлов — все итоги _final)"
    echo "  ./${SCRIPT_NAME} tool logins|userpass|trim|alphabets|uniq <file>  = пункт 7"
    echo "  ./${SCRIPT_NAME} tool cut <file> <разделитель> [left|right|both]"
    echo "  ./${SCRIPT_NAME} tool extract <file> [emails] [urls] [ip]"
    echo "  ./${SCRIPT_NAME} tool layout <file> [ru2en|en2ru]"
    echo "  ./${SCRIPT_NAME} tool case <file> lower|upper|cap|uncap|all"
    echo "  ./${SCRIPT_NAME} tool spaces <file> remove|first"
    echo "  ./${SCRIPT_NAME} tool filter <file> <кусок>..."
    echo "  ./${SCRIPT_NAME} tool top [N] <file>..."
    echo "  ./${SCRIPT_NAME} tool find <строка> [file...]"
    echo "  ./${SCRIPT_NAME} tool edge <file> move|right|left [replace]"
    echo "  ./${SCRIPT_NAME} tool minus <file> <словарь>..."
    echo "  Ответы на вопросы можно подать через stdin, например:"
    echo "    printf 'y\\nn\\nn\\n' | ./${SCRIPT_NAME} full raw.txt"
    echo
    echo -e "${GREEN}─── Структура папок ───────────────────────────────────────${NC}"
    echo "    ./                 ← рабочие файлы (*.txt) — из них удаляются дубли"
    echo "    ./$COMPARE_DIR/    ← эталонные файлы (*.txt), с которыми сравниваем"
    echo "    ./$COMPARE_DIR/$UNSORTED_DIR/ ← оригиналы пересортированных эталонов (создаётся сама)"
    echo "    ./$LOG_DIR/             ← логи"
    echo "  Посторонних .txt в корне не держите: compare без аргументов берёт все,"
    echo "  кроме списков объединения merged_list.txt."
    echo
    echo -e "${YELLOW}Вопросы:${NC} ждут ответа без таймаута. Enter — вариант по умолчанию: [Y/n] — да,"
    echo "  [y/N] — нет. Исключение — вопрос о временной папке Linux в WSL: через ${DEFAULT_TIMEOUT} сек"
    echo "  сработает «да». Для запуска без присмотра ответы можно подать заранее через stdin,"
    echo "  а с </dev/null у всех вопросов будет вариант по умолчанию."
    echo
    echo -e "${RED}Предупреждение:${NC} эталоны с вашего согласия исправляются на месте или переносятся"
    echo "  в ${UNSORTED_DIR}/. Рабочие файлы скрипт не меняет, кроме утилиты 14, если вы попросите"
    echo "  заменить файл; после очереди (пункт 4) исходные словари переносятся в папку"
    echo "  originals_<дата-время>/. Делайте бэкап эталонов."
    echo
    echo -e "${BLUE}Требования:${NC} Bash 4.2+, GNU coreutils (sort, comm, split, od, stat, mkfifo, df),"
    echo "  grep, sed, awk; iconv — для конвертации кодировок"
}

# Help in English.
show_help_en() {
    echo -e "${CYAN}${SCRIPT_NAME} v${VERSION} — cleaning and deduplication of big text files${NC}"
    echo -e "${CYAN}============================================================${NC}"
    echo
    echo -e "${GREEN}RUN:${NC}"
    echo "  ./${SCRIPT_NAME}               main menu — the usual way to work"
    echo "  ./${SCRIPT_NAME} --help | -h   this help"
    echo "  ./${SCRIPT_NAME} --version     show the version and exit"
    echo "  ./${SCRIPT_NAME} --lang ru     Russian interface (--lang en — English)"
    echo "  The language follows the system language (in Git Bash and WSL — the Windows"
    echo "  language). Menu item 8 \"Language / Язык\" changes it and remembers the choice;"
    echo "  the DEDUP_LANG=ru or en variable works too."
    echo "  First start on Windows: double-click dedup_tool_first_windows_start.bat next"
    echo "  to the script. It finds Git for Windows (if it is missing, offers to install it)"
    echo "  and runs the script in its folder. After that this file is not needed: a double"
    echo "  click on the script in Explorer works too."
    echo
    echo -e "${GREEN}─── Menu ───────────────────────────────────────────────────${NC}"
    echo "  1  Full processing: preparation → sort → comparison with references"
    echo "     → <name>_final.txt"
    echo "  2  Preparation only → <name>_prep.txt (if it already exists, asks whether"
    echo "     to overwrite it or save as <name>_prep_2.txt; Enter — the latter)"
    echo "  3  Comparison with references only (one file or all) → <name>_final.txt."
    echo "     The file is taken as is, without preparation: garbage (NUL, U+FFFD,"
    echo "     control characters), short lines and digit lines stay in the result."
    echo "     A raw file belongs in item 1. Item 2 and then item 3 on <name>_prep.txt"
    echo "     is the same as item 1. If the file has such garbage or lines that are"
    echo "     not UTF-8, the script warns."
    echo "  4  Several dictionaries in a queue → <name>_final.txt for each. Each file is"
    echo "     processed like item 1 but is also cleaned of the results of all previous"
    echo "     ones: the first stays whole, the next ones have no lines seen earlier."
    echo "     The list goes from the biggest file to the smallest. Order — numbers"
    echo "     separated by spaces (3 1 2); Enter — all in the list except _final results,"
    echo "     merge files and removed lines (_short, _digits, _notutf8); the order is"
    echo "     shown once more before the start."
    echo "     Questions are asked once: the next files get the same answers. Results"
    echo "     stay in the working folder, nothing is added to '$COMPARE_DIR/';"
    echo "     there may be no references — then the files are cleaned of each other."
    echo "     When the whole queue is done, the source dictionaries move to a new"
    echo "     folder originals_<date-time>/ — the results stay in the working folder."
    echo "  5  Merge _final results into one file → merged.txt and merged_list.txt."
    echo "     The files are joined without duplicates; merged_list.txt lists the files"
    echo "     merged.txt was built from, one name per line. Numbers separated by"
    echo "     spaces, Enter — all _final results. If merged.txt exists — merged_2.txt."
    echo "  6  Split a finished file into parts → folder <name>_parts/"
    echo "  7  Dictionary tools: logins, keyboard layout, case, alphabets, search — see below"
    echo "  8  Language / Язык      9  Help      0  Exit"
    echo "  If a working file is a copy of a reference from '$COMPARE_DIR/', the script"
    echo "  warns before the questions: such a file is compared with itself, and its"
    echo "  result is empty."
    echo "  If a file is an archive disguised as .txt (gzip, zip, 7z, rar, bzip2, xz,"
    echo "  zstd), the action does not start, and the script tells how to unpack it."
    echo "  The working file is chosen from the *.txt files of the current folder: if"
    echo "  there is one, it is taken, otherwise by its number in the list (_final"
    echo "  results, merged files and lists are marked)."
    echo "  The menu and file choice wait for an answer without a timeout; after an"
    echo "  action — the menu again."
    echo "  There are no intermediate files: items 1, 3 and 4 run in one pass from the"
    echo "  input to the result, only <name>_final.txt is written. For the file after"
    echo "  preparation use item 2."
    echo
    echo -e "${GREEN}─── Preparation (items 1, 2 and 4) ────────────────────────${NC}"
    echo "  First all questions — answers are only remembered. Then the file goes ONCE"
    echo "  through a pipeline of the chosen steps: for item 2 — into <name>_prep.txt,"
    echo "  for items 1 and 4 — on through sorting and comparison straight to the result."
    echo
    echo "   • UTF-16 → UTF-8   [asked only if the file looks like UTF-16; Enter: YES]"
    echo "     Detected by the BOM or by 00H null bytes."
    echo "   • CRLF and BOM     [asked only if found; Enter: YES]"
    echo "     Removes \\r at line ends and the UTF-8 BOM — the invisible U+FEFF — at the"
    echo "     start of the file and inside it (happens when a list is glued from files"
    echo "     with a BOM)."
    echo "   • CR inside a line [asked only if found; Enter: YES]"
    echo "     Editors show such a CR as a line break: one line looks like two, and a CR"
    echo "     at the start looks like an empty line before the word. Such lines are split."
    echo "   • Words in UTF-16  [asked only if found; Enter: YES]"
    echo "     Lines with a NUL byte (00H) after each letter: «␀p␀a␀s␀s» → «pass»."
    echo "     Editors treat the file as binary because of them, and they never match"
    echo "     a reference."
    echo "   • Mojibake         [asked only if found; Enter: YES]"
    echo "     Text read in the wrong encoding and saved to UTF-8 again:"
    echo "      – UTF-8 read as Windows-1252 or Latin-1: «Ã©tÃ©» → «été»;"
    echo "      – Russian DOS text (CP866) read as Windows-1251: «ЏаЁўҐв» → «Привет»; a line of"
    echo "        signs only (¤®¬ → дом) — only if the file already has such lines;"
    echo "      – UTF-8 read as Windows-1251: «РџСЂРёРІРµС‚» → «Привет», and other characters:"
    echo "        «cafГ©» → «café». Real words like «дії» are not touched;"
    echo "      – Russian KOI8-R text read as Windows-1251: «РТЙЧЕФ» → «привет». Only if most"
    echo "        lines in capitals look so, and letter pair frequencies check each line: a"
    echo "        real word in capitals is sometimes converted too, a short one more often;"
    echo "      – Russian DOS text (CP866) without the high bit: «а» became a space, other"
    echo "        letters became signs. Detected by the whole file, not by a line; real"
    echo "        hyphens and spaces become letters, lines with digits or Latin stay as is."
    echo "     The count and examples of each kind come before the question, one"
    echo "     question for all. Only lines made entirely of such characters (and"
    echo "     Latin letters, digits) are restored: normal text and mixes are kept."
    echo "     This runs before the filters: the length is counted on restored text."
    echo "   • Cyrillic not in UTF-8  [WINDOWS-1251, KOI8-R or CP866 found automatically]"
    echo "     If lines are not UTF-8, the script recognizes the encoding by the"
    echo "     frequent Russian letters and shows a couple of lines after conversion."
    echo "     If the whole file is in it, it is used when you press Enter at the"
    echo "     encoding question. If UTF-8 lines are there too (a mixed file), the"
    echo "     script asks whether to convert only the non-UTF-8 lines (Enter: YES);"
    echo "     the others are not touched. In an editor these encodings are"
    echo "     \"Cyrillic (Windows)\", \"Cyrillic (KOI8-R)\", \"Cyrillic (DOS)\"."
    echo "   • UTF-8 check      [Enter: NO; if UTF-16 is not converted or an encoding"
    echo "     was found — YES]"
    echo "     You can give the source encoding (for example WINDOWS-1251, KOI8-R, CP866,"
    echo "     ISO-8859-5, MACCYRILLIC) — then iconv goes first. Removes lines with"
    echo "     invalid UTF-8 bytes, with the replacement character U+FFFD (a trace of an"
    echo "     earlier bad conversion) and with NUL bytes if they were not restored. A"
    echo "     separate step removes lines with control characters: codes 01–1F"
    echo "     (except tab), 7F and U+0080–U+009F. In an editor they are odd symbols,"
    echo "     and in the result they would come first."
    echo "     The count and examples come before the question. If the encoding was not"
    echo "     found, you are told before the question how many non-UTF-8 lines it removes."
    echo "   • Empty lines      [asked only if found; Enter: YES]"
    echo "     Empty lines and lines of only spaces and tabs. Lines with spaces only at the"
    echo "     edges of a word stay: the check of the result counts them."
    echo "   • Line length      [Enter: NO] keeps lines of N to M characters"
    echo "     (asks for both, 8 and 16 by default). Counts characters, not bytes."
    echo "   • Digits only      [Enter: NO] removes lines made of digits only. Which —"
    echo "     it asks: 8 — up to 8 digits inclusive, 8-10 — from 8 to 10, Enter — all."
    echo "     A line with a space at the edge («80808080 ») is kept: the check of the"
    echo "     result counts such lines."
    echo "   • Removed lines    [asked if the length or digits filter is on or the check"
    echo "     removes non-UTF-8 lines; Enter: NO]"
    echo "     Lines shorter than the minimum go to <name>_short.txt, digit lines — to"
    echo "     <name>_digits.txt, without duplicates. Longer than the maximum are not"
    echo "     saved. Lines not in UTF-8 go to <name>_notutf8.txt, as they are."
    echo "  After the pass — statistics: how many lines each step removed."
    echo
    echo -e "${GREEN}─── Comparison (items 1, 3 and 4) ─────────────────────────${NC}"
    echo "  Each reference in '$COMPARE_DIR/' is one generation of the comparison, in"
    echo "  name order:"
    echo "   1. References are always checked: CRLF and BOM, line order (bytewise,"
    echo "      LC_ALL=C), duplicates. A reference already in order is not touched."
    echo "      It is fixed only with your consent  [question, Enter: YES]: CRLF/BOM —"
    echo "      in place; a re-sorted one — into <name>_sorted.txt next to it, the"
    echo "      original — to $COMPARE_DIR/${UNSORTED_DIR}/. An unsorted reference that"
    echo "      you did not let fix is skipped: comm cannot work with it."
    echo "   2. The working file goes through once: [preparation →] sort -u (no"
    echo "      question: comparing needs sorting, and -u removes duplicates inside the"
    echo "      file) → comm -13 with each reference in turn — what remains is in none"
    echo "      of them. Your file is not changed or moved. For item 3 the file goes as"
    echo "      is: only CRLF and the BOM at the start are removed."
    echo "      The sort gets up to half of the free memory and up to 8 threads. What"
    echo "      does not fit, it sorts in chunks into temporary files next to the"
    echo "      result and deletes them itself: that needs about the size of the"
    echo "      dictionary in free space."
    echo "   3. The result is <name>_final.txt. It is written to a temporary file next"
    echo "      to it and renamed at the end: an interrupted run leaves no cut result."
    echo "      If such a result exists — asks; by default saves as <name>_final_2.txt."
    echo "      A repeated run on _final does not give _final_final."
    echo "   4. The result is checked for lines with spaces or tabs at the start or"
    echo "      end: they are invisible in an editor, and «80808080 » and «80808080»"
    echo "      are different lines. If there are any — how many and how much space,"
    echo "      examples go to the log. No question: to remove or trim them use item 7,"
    echo "      tool 14."
    echo
    echo -e "${GREEN}─── Split (item 6) ────────────────────────────────────────${NC}"
    echo "  A number — that many parts (split -n l/N); a size with a unit K/M/G/T —"
    echo "  parts of that size (split -C). Lines are not cut. Parts <name>_partNN.txt"
    echo "  go to the folder <name>_parts/. Needed only for outside reasons: an editor"
    echo "  cannot open a big file, FAT32 (4 GB limit), sending in parts."
    echo "  Splitting does not help processing: a whole file is processed faster and"
    echo "  without duplicates between parts."
    echo
    echo -e "${GREEN}─── Dictionary tools (item 7) ──────────────────────────────${NC}"
    echo "  The source file stays unchanged (except tool 14, if you ask), the result is a new"
    echo "  file <name>_<what>.txt (if taken — _2). Logins, passwords, line parts and addresses"
    echo "  come without duplicates in byte order; the rest line for line, in the same order."
    echo "  After tools 1–4 you can save the dictionary without the lines something was"
    echo "  extracted from: a line goes as a whole, the file _rest  [question, Enter: NO]."
    echo "   1  Email → logins: the part before @ of each address in a line → _logins"
    echo "   2  user:pass → _logins and _passwords: split at the first \":\" or \";\""
    echo "   3  Any separator (: / ; --- (at)): left part → _left, right part → _right;"
    echo "      the right part is everything after the first separator"
    echo "   4  Cut out of a dump: emails → _emails, links → _urls, IP addresses → _ip"
    echo "   5  Keyboard layout: RU → EN («привет» → «ghbdtn») → _en, only lines with"
    echo "      Cyrillic; EN → RU → _ru, only lines with Latin letters"
    echo "   6  Case → _lower, _upper, _cap (first upper), _uncap (first lower)"
    echo "      or all four files at once"
    echo "   7  Lines with a space or tab: remove → _nospace, first word → _firstword"
    echo "   8  Trim spaces and tabs at the edges, double ones inside into one → _trim"
    echo "   9  Remove lines with the given pieces (separated by spaces: - _ admin) → _filtered."
    echo "      A line goes if it has at least one; «-admin» is one piece, «- admin» is two"
    echo "  10  By alphabets: _latin (and ASCII), _cyr, _greek, _hebrew, _arabic, _cjk, _other;"
    echo "      digits and signs do not count, two alphabets in a line — _mixed"
    echo "  11  The most frequent lines → _top: how many times and, for several files, in how many."
    echo "      If the end of the list has the same count as the lines after it, you are told"
    echo "  12  Duplicates without sorting, the order kept → _uniq; memory and disk as for a"
    echo "      sort, twice the time"
    echo "  13  Find a line in the *.txt of the folder and in references: where and how many"
    echo "      times, counts only. Byte search: a dictionary in another encoding is not found
  14  Spaces and tabs at the edges: move such lines → _edge and remove them from the
      dictionary → _noedge, trim on the right → _rtrim, trim on the left → _ltrim. You can
      replace the file itself [question, Enter: NO]: only through a temporary file, after a
      successful write. A sorted file is sorted again after trimming; it is not compared
      with the references again
  15  Remove from a file the lines of other dictionaries → _minus, sorted, without
      duplicates. Dictionaries: *.txt of this folder and references, without preparation:
      only CRLF and BOM are removed"
    echo "  Layout, case and alphabets expect UTF-8: otherwise use item 2 first."
    echo
    echo -e "${GREEN}─── WSL and Windows drives ────────────────────────────────${NC}"
    echo "  If the script runs in WSL in a folder on a Windows drive (/mnt/c, /mnt/d ...),"
    echo "  it warns and offers to work in a Linux temp folder"
    echo "  (${WORK_ROOT}/<name>_<date-time>): the working file and the references are"
    echo "  copied there, and only the result and the references that had to be fixed"
    echo "  are copied back. Line-by-line writing through /mnt is hundreds of times"
    echo "  slower, while a big cp is fast. After the work the copies of your files and"
    echo "  references and the returned result are deleted from the temp folder, and an"
    echo "  empty folder is deleted too. Merging (item 5) does not need references."
    echo
    echo -e "${GREEN}─── Big dictionaries (gigabytes) ──────────────────────────${NC}"
    echo "  Git Bash or WSL: dictionaries up to about 1 GB are fine in Git Bash, right on"
    echo "  Windows (it depends on the PC). Bigger ones are better in WSL: the same work"
    echo "  runs there 3–4 times faster."
    echo "  During long steps — copying to the Linux folder and back, sorting a"
    echo "  reference, the pass, merging — the bottom line shows every 5 s how much"
    echo "  time has passed and how much is done: the script is not stuck."
    echo "  Memory: sorting takes up to half of the free memory, the rest is taken by"
    echo "  the Linux file cache, so WSL looks almost full in the Task Manager — this"
    echo "  is normal. If the memory is not freed after the work — wsl --shutdown."
    echo "  Disk: a 6.5 GB dictionary with an 8.1 GB reference in WSL is, by estimate,"
    echo "  about 70 GB written the first time (copies to the Linux folder and back,"
    echo "  sorting the reference, sort's temporary files, the result) and about 40 GB"
    echo "  later, when the reference is already sorted. You need about three times"
    echo "  the size of the dictionary and references together in free space — in WSL"
    echo "  the script checks it before copying. No copying and less writing — if you"
    echo "  keep big dictionaries and references right in Linux (in Explorer it is"
    echo "  \\\\wsl.localhost\\<distribution>\\home\\<user>)."
    echo "  HDD: it works, but slower — especially copying when the dictionaries and"
    echo "  the Linux disk are on the same HDD, and sorting big files. If you have an"
    echo "  SSD, keep the Linux disk (ext4.vhdx) and the working folder there, and do"
    echo "  not run other heavy disk work at the same time."
    echo
    echo -e "${GREEN}─── Log ────────────────────────────────────────────────────${NC}"
    echo "  Each action writes ${LOG_DIR}/<name>_<action>_<date>_<time>.log: everything"
    echo "  shown on the screen plus the questions with answers, step times, the result"
    echo "  file, errors."
    echo
    echo -e "${GREEN}─── Hidden commands (for tests and automation) ─────────────${NC}"
    echo "  ./${SCRIPT_NAME} full <file>              = item 1"
    echo "  ./${SCRIPT_NAME} clean <file>             = item 2"
    echo "  ./${SCRIPT_NAME} compare [file...]        = item 3 (without files — all *.txt of the folder)"
    echo "  ./${SCRIPT_NAME} split <file> <N|size>    = item 6"
    echo "  ./${SCRIPT_NAME} queue <file1> <file2>... = item 4, files in this order"
    echo "  ./${SCRIPT_NAME} merge [file...]          = item 5 (without files — all _final results)"
    echo "  ./${SCRIPT_NAME} tool logins|userpass|trim|alphabets|uniq <file>  = item 7"
    echo "  ./${SCRIPT_NAME} tool cut <file> <separator> [left|right|both]"
    echo "  ./${SCRIPT_NAME} tool extract <file> [emails] [urls] [ip]"
    echo "  ./${SCRIPT_NAME} tool layout <file> [ru2en|en2ru]"
    echo "  ./${SCRIPT_NAME} tool case <file> lower|upper|cap|uncap|all"
    echo "  ./${SCRIPT_NAME} tool spaces <file> remove|first"
    echo "  ./${SCRIPT_NAME} tool filter <file> <piece>..."
    echo "  ./${SCRIPT_NAME} tool top [N] <file>..."
    echo "  ./${SCRIPT_NAME} tool find <line> [file...]"
    echo "  ./${SCRIPT_NAME} tool edge <file> move|right|left [replace]"
    echo "  ./${SCRIPT_NAME} tool minus <file> <dictionary>..."
    echo "  Answers to the questions can be given through stdin, for example:"
    echo "    printf 'y\\nn\\nn\\n' | ./${SCRIPT_NAME} full raw.txt"
    echo
    echo -e "${GREEN}─── Folders ───────────────────────────────────────────────${NC}"
    echo "    ./                 ← working files (*.txt) — duplicates are removed from them"
    echo "    ./$COMPARE_DIR/    ← reference files (*.txt) to compare with"
    echo "    ./$COMPARE_DIR/$UNSORTED_DIR/ ← originals of re-sorted references (created by itself)"
    echo "    ./$LOG_DIR/             ← logs"
    echo "  Do not keep unrelated .txt files in the root: compare without arguments"
    echo "  takes them all, except the merge lists merged_list.txt."
    echo
    echo -e "${YELLOW}Questions:${NC} wait for an answer without a timeout. Enter — the default: [Y/n] —"
    echo "  yes, [y/N] — no. The exception is the question about the Linux temp folder in"
    echo "  WSL: after ${DEFAULT_TIMEOUT} s it takes \"yes\". For unattended runs the answers can"
    echo "  be given through stdin, and with </dev/null every question gets its default."
    echo
    echo -e "${RED}Warning:${NC} with your consent references are fixed in place or moved to"
    echo "  ${UNSORTED_DIR}/. The script does not change working files, except tool 14 if you ask"
    echo "  to replace a file; after a queue (item 4) the source dictionaries move to"
    echo "  originals_<date-time>/. Back up your references."
    echo
    echo -e "${BLUE}Requirements:${NC} Bash 4.2+, GNU coreutils (sort, comm, split, od, stat, mkfifo, df),"
    echo "  grep, sed, awk; iconv — for encoding conversion"
}

# Yes/no question: the default on Enter or end of input; remembered within a queue.
confirm_action() {
    local prompt="$1" default="${2:-y}" key="${3:-$1}" tmo="${4:-}" yn hint="[Y/n]" rc ans how="" w_yes w_no w_memo m
    L w_yes да yes; L w_no нет no; L w_memo "(как раньше в этой очереди)" "(same as earlier in this queue)"
    [[ "$default" == "n" ]] && hint="[y/N]"
    if $MEMO_ON && [[ -n "${MEMO[$key]+x}" ]]; then
        ans="${MEMO[$key]}"
        how="$w_yes"; [[ "$ans" == y ]] || how="$w_no"
        printf '▐► %s → %s %b\n' "$prompt" "$how" "${BLUE}${w_memo}${NC}"
        log_line "? ${prompt} → ${how} ${w_memo}"
        [[ "$ans" == y ]]
        return
    fi
    while true; do
        if [[ -n "$tmo" ]]; then
            L m "(авто ${default^^} через ${tmo} сек)" "(auto ${default^^} in ${tmo} s)"
            read -r -t "$tmo" -p "▐► ${prompt} ${hint} ${m} " yn
        else
            read -r -p "▐► ${prompt} ${hint} " yn
        fi
        rc=$?
        if (( rc > 128 )) || { (( rc != 0 )) && [[ -z "$yn" ]]; }; then
            echo
            ans="$default"
            if (( rc > 128 )); then L how " (по умолчанию: нет ответа)" " (default: no answer)"; else L how " (по умолчанию: ввод закончился)" " (default: end of input)"; fi
            break
        fi
        case "$yn" in
            "") ans="$default"; L how " (по умолчанию)" " (default)"; break ;;
            [Yy]*) ans=y; break ;;
            [Nn]*) ans=n; break ;;
            *) out "▐► Введите Y или N" "▐► Type Y or N" ;;
        esac
    done
    if [[ "$ans" == y ]]; then log_line "? ${prompt} → ${w_yes}${how}"; else log_line "? ${prompt} → ${w_no}${how}"; fi
    $MEMO_ON && MEMO_NEW[$key]="$ans"
    [[ "$ans" == y ]]
}

# Question with a typed answer into REPLY; remembered within a queue.
ask_value() {
    local prompt="$1" def="${2:-}" v="" rc how="" key="v:$1" e
    local p="${prompt%%+( )}"
    if $MEMO_ON && [[ -n "${MEMO[$key]+x}" ]]; then
        v="${MEMO[$key]}"
        L how "(как раньше в этой очереди)" "(same as earlier in this queue)"
        printf '%s%s %b\n' "$prompt" "${v:-Enter}" "${BLUE}${how}${NC}"
        L e пусто empty
        log_line "? ${p%:} → ${v:-$e} ${how}"
        REPLY="$v"
        return 0
    fi
    read -r -p "$prompt" v
    rc=$?
    if (( rc != 0 )) && [[ -z "$v" ]]; then
        L how " (ввод закончился)" " (end of input)"
    fi
    if [[ -z "$v" ]]; then
        v="$def"
        [[ -z "$how" ]] && how=" (Enter)"
    fi
    L e пусто empty
    log_line "? ${p%:} → ${v:-$e}${how}"
    $MEMO_ON && MEMO_NEW[$key]="$v"
    REPLY="$v"
}

# Run a command that must succeed; report it otherwise.
must_run() {
    local desc="$1"; shift
    if ! "$@"; then
        say "${RED}✘ ${desc}${NC}" >&2
        return 1
    fi
}

declare -a SORT_OPTS=()
SORT_MEM_KB=0
# sort buffer (half of the available memory) and threads (up to 8) into SORT_OPTS.
sort_opts() {
    local kb n
    kb="$(awk '/^MemAvailable:/ { a = $2 } /^MemFree:/ { f = $2 } END { print (a != "" ? a : f) }' /proc/meminfo 2>/dev/null)"
    n="$(nproc 2>/dev/null || echo 4)"
    [[ "$n" =~ ^[0-9]+$ ]] || n=4
    (( n > 8 )) && n=8
    SORT_OPTS=(--parallel="$n")
    SORT_MEM_KB=0
    if [[ "$kb" =~ ^[0-9]+$ ]] && (( kb / 2 >= 65536 )); then
        SORT_MEM_KB=$(( kb / 2 ))
        SORT_OPTS+=(-S "${SORT_MEM_KB}K")
    fi
}

# Check a reference: CRLF/BOM, order, duplicates; fix with consent. Prints the path to use.
process_file() {
    local file="$1" context="$2" skip_crlf="${3:-false}" is_ref=false strip=false ctx q
    [[ "$context" == "Эталон" ]] && is_ref=true
    ctx="$context"
    [[ "$UI_LANG" == en ]] && { if $is_ref; then ctx=Reference; else ctx="Working file"; fi; }
    trap on_interrupt INT
    {
        say "▬▬▬▬▬▬▬▬▬▬▬▬▬▬▬▬▬▬▬▬▬▬▬▬▬▬▬▬▬▬▬▬▬▬▬▬▬"
        say " [${ctx}] Обработка: ${file##*/} ($(fmt_size "$(file_size "$file")"))" " [${ctx}] Processing: ${file##*/} ($(fmt_size "$(file_size "$file")"))"
        say "├─ Шаг 1/2: Проверка CRLF и BOM..." "├─ Step 1/2: checking CRLF and BOM..."
    } >&2

    if [[ "$skip_crlf" == "true" ]]; then
        say "│  └─ Решено на подготовке — пропускаю" "│  └─ Decided during preparation — skipping" >&2
    elif has_crlf "$file" || has_bom "$file"; then
        say "│  ├─ Найдены CRLF и/или BOM" "│  ├─ CRLF and/or BOM found" >&2
        if ! $is_ref; then
            strip=true
            say "│  └─ Уберу в копии вместе с сортировкой — исходный файл не меняется" "│  └─ Will remove them in the sorted copy — the source file stays unchanged" >&2
        elif L q "Эталон ${file##*/}: убрать CRLF и BOM (файл изменится на месте)?" "Reference ${file##*/}: remove CRLF and BOM (the file changes in place)?"; confirm_action "$q" y >&2; then
            strip_cr_bom "$file" || return 1
            say "│  └─ Успешно очищено!" "│  └─ Cleaned!" >&2
        else
            say "│  └─ Оставлены: такие строки не совпадут со строками рабочих файлов" "│  └─ Kept: such lines will not match the lines of working files" >&2
        fi
    else
        say "│  └─ CRLF и BOM не обнаружены" "│  └─ No CRLF or BOM" >&2
    fi

    say "└─ Шаг 2/2: Проверка сортировки и дублей..." "└─ Step 2/2: checking order and duplicates..." >&2
    local sorted_ok=false fsz
    fsz=$(file_size "$file")
    if ! $strip; then
        L q "проверка порядка ${file##*/}" "checking order of ${file##*/}"
        progress_start "$q" "$fsz" read "$file"
        LC_ALL=C sort -cu "$file" 2>/dev/null && sorted_ok=true
        progress_stop
    fi
    if $sorted_ok; then
        say "   └─ Файл уже отсортирован, дублей нет" "   └─ Already sorted, no duplicates" >&2
        printf '%s' "$file"
        return 0
    fi

    local dir base sorted_file unsorted_dir tmp t0
    local -a st=()
    dir="$(dirname "$file")"
    base="$(basename "$file" .txt)"
    if [[ "$dir" == "." ]]; then
        sorted_file="${base}_sorted.txt"
    else
        sorted_file="${dir}/${base}_sorted.txt"
    fi

    L q "Эталон ${file##*/} не отсортирован или в нём есть дубли. Отсортировать (${sorted_file##*/} рядом, оригинал — в ${UNSORTED_DIR}/)?" "Reference ${file##*/} is not sorted or has duplicates. Sort it (${sorted_file##*/} next to it, the original goes to ${UNSORTED_DIR}/)?"
    if $is_ref && ! confirm_action "$q" y >&2; then
        if LC_ALL=C sort -c "$file" 2>/dev/null; then
            say "   └─ Оставлен как есть: порядок верный, дубли сравнению не мешают" "   └─ Kept as is: the order is right, duplicates do not hurt the comparison" >&2
            printf '%s' "$file"
            return 0
        fi
        say "   └─ Оставлен как есть — без порядка comm с ним работать не может" "   └─ Kept as is — comm cannot work with it unsorted" >&2
        return 2
    fi
    if $strip; then
        say "   ├─ Сортирую в копию без CRLF/BOM и дублей..." "   ├─ Sorting into a copy without CRLF/BOM and duplicates..." >&2
    else
        say "   ├─ Нужна сортировка и/или удаление дублей — выполняю..." "   ├─ Sorting and removing duplicates..." >&2
    fi

    tmp="$(mktemp "${dir}/.dedup_tool.XXXXXX")" || { say "   └─ Не удалось создать временный файл" "   └─ Could not create a temporary file" >&2; return 1; }
    IN_PROGRESS=("$tmp")
    sort_opts
    ms_now; t0=$REPLY
    L q "сортировка ${file##*/}" "sorting ${file##*/}"
    progress_start "$q" "$fsz" read "$file"
    if $strip; then
        _st_strip < "$file" | LC_ALL=C sort -u -T "$dir" "${SORT_OPTS[@]}" > "$tmp"
        st=("${PIPESTATUS[@]}")
    else
        LC_ALL=C sort -u -T "$dir" "${SORT_OPTS[@]}" "$file" > "$tmp"
        st=("$?")
    fi
    progress_stop
    if (( st[0] != 0 || ${st[1]:-0} != 0 )); then
        say "   └─ Ошибка сортировки — файл не тронут" "   └─ Sort error — the file is untouched" >&2
        rm -f "$tmp"
        return 1
    fi

    L q "не удалось сохранить результат сортировки ($sorted_file)" "could not save the sorted result ($sorted_file)"
    if ! must_run "$q" mv "$tmp" "$sorted_file"; then
        rm -f "$tmp"
        return 1
    fi
    IN_PROGRESS=()
    ms_now

    if $is_ref; then
        unsorted_dir="${dir}/${UNSORTED_DIR}"
        mkdir -p "$unsorted_dir" 2>/dev/null
        if ! mv "$file" "$unsorted_dir/" 2>/dev/null; then
            say "   ⚠ Не удалось перенести оригинал в ${unsorted_dir}/ — остался на месте (результат это не портит)" "   ⚠ Could not move the original to ${unsorted_dir}/ — it stays in place (the result is fine)" >&2
        else
            say "   ├─ Оригинал перемещён в ${unsorted_dir}/" "   ├─ The original moved to ${unsorted_dir}/" >&2
        fi
    fi

    say "   └─ Создан: ${sorted_file##*/} (сортировка $(fmt_dur $(( REPLY - t0 ))))" "   └─ Created: ${sorted_file##*/} (sorting $(fmt_dur $(( REPLY - t0 ))))" >&2
    printf '%s' "$sorted_file"
}

# Base name of the result: without _prep and _final(_N).
final_base() {
    local b="${1##*/}"
    b="${b%.*}"
    b="${b%_prep}"
    [[ "$b" =~ ^(.+)_final(_[0-9]+)?$ ]] && b="${BASH_REMATCH[1]}"
    printf '%s' "$b"
}

is_final() { [[ "$1" =~ _final(_[0-9]+)?\.txt$ ]]; }

is_merged() { [[ "${1##*/}" =~ ^merged(_[0-9]+)?\.txt$ ]]; }
is_list() { [[ "${1##*/}" =~ ^merged(_[0-9]+)?_list\.txt$ ]]; }
is_side() { [[ "${1##*/}" =~ _(short|digits|notutf8)(_[0-9]+)?\.txt$ ]]; }

# Mark in the menu file lists: result, merged file, list, removed lines.
file_mark() {
    local m=""
    if is_final "$1"; then L m '  ← итог' '  ← result'
    elif is_list "$1"; then L m '  ← список объединённых файлов' '  ← list of merged files'
    elif is_merged "$1"; then L m '  ← объединение' '  ← merged'
    elif [[ "${1##*/}" =~ _short(_[0-9]+)?\.txt$ ]]; then L m '  ← убранные строки: короткие' '  ← removed lines: short'
    elif [[ "${1##*/}" =~ _digits(_[0-9]+)?\.txt$ ]]; then L m '  ← убранные строки: из цифр' '  ← removed lines: digits'
    elif [[ "${1##*/}" =~ _notutf8(_[0-9]+)?\.txt$ ]]; then L m '  ← убранные строки: не в UTF-8' '  ← removed lines: not UTF-8'
    fi
    printf '%s' "$m"
}

declare -a WORK_TXT=()
# Working files for "all files": the *.txt of the folder except merge lists.
work_txt() {
    local f
    WORK_TXT=()
    shopt -s nullglob
    for f in *.txt; do is_list "$f" || WORK_TXT+=("$f"); done
    shopt -u nullglob
}

final_taken() { [[ -e "$1" ]] || { [[ -n "$FINAL_DIR" ]] && [[ -e "$FINAL_DIR/$1" ]]; }; }

# Result name: <name>_final.txt, or _final_2… when taken (asks before overwriting).
pick_final_name() {
    local base="$1" name n=2 f mine=false q
    name="${base}_final.txt"
    for f in "${RESULT_FILES[@]}" "${ACTION_FILES[@]}"; do [[ "${f##*/}" == "$name" ]] && mine=true; done
    if final_taken "$name"; then
        L q "Итог ${name} уже есть. Перезаписать его?" "Result ${name} already exists. Overwrite it?"
        if ! $mine && confirm_action "$q" n overwrite; then
            REPLY="$name"
            return 0
        fi
        while final_taken "${base}_final_${n}.txt"; do n=$((n + 1)); done
        name="${base}_final_${n}.txt"
        say "${BLUE}Итог будет сохранён как ${name}${NC}" "${BLUE}The result will be saved as ${name}${NC}"
    fi
    REPLY="$name"
}

# First free name <base>_<suffix>.txt, then _2, _3… into REPLY.
free_name() {
    local base="$1" suf="$2" n=2 name
    name="${base}_${suf}.txt"
    while final_taken "$name"; do name="${base}_${suf}_${n}.txt"; n=$((n + 1)); done
    REPLY="$name"
}

# Name for item 2: <name>_prep.txt; asks before overwriting, otherwise _prep_2.
pick_prep_name() {
    local base="$1" name n=2 q
    name="${base}_prep.txt"
    if final_taken "$name"; then
        L q "Файл ${name} уже есть. Перезаписать его?" "File ${name} already exists. Overwrite it?"
        if confirm_action "$q" n overwrite_prep; then
            REPLY="$name"
            return 0
        fi
        while final_taken "${base}_prep_${n}.txt"; do n=$((n + 1)); done
        name="${base}_prep_${n}.txt"
        say "${BLUE}Результат будет сохранён как ${name}${NC}" "${BLUE}The result will be saved as ${name}${NC}"
    fi
    REPLY="$name"
}

# Examples of lines with spaces or tabs at the edges (· is a space, → a tab).
edge_examples() {
    { LC_ALL=C grep -a -m 3 -E "$2" -- "$1"; LC_ALL=C grep -a -m 3 -E "$3" -- "$1"; } \
        | tr -d '\000-\010\013-\037\177' | awk '!seen[$0]++' | LC_ALL=C sed -e 's/ /·/g' -e 's/\t/→/g'
}

# After the result: lines with spaces or tabs at the edges — only the count, examples in the log.
check_edge_blanks() {
    local f="$1" total="${2:-0}" n=0 b=0 l pct="" t
    local re='^[[:blank:]]|[[:blank:]]$'
    local -a ex=()
    read -r n b < <(LC_ALL=C grep -a -E "$re" -- "$f" | wc -lc)
    if (( n == 0 )); then
        say "${BLUE}✓ Строк с пробелами или табами в начале или в конце нет${NC}" "${BLUE}✓ No lines with spaces or tabs at the start or end${NC}"
        return 0
    fi
    (( total > 0 )) && L pct " ($(( n * 100 / total )),$(( n * 1000 / total % 10 ))% итога)" " ($(( n * 100 / total )).$(( n * 1000 / total % 10 ))% of the result)"
    say "${YELLOW}⚠ Строк с пробелами или табами в начале или в конце: $(fmt_num "$n") из $(fmt_num "$total")${pct}, $(fmt_mb "$b") — убрать или обрезать: пункт 7, утилита 14${NC}" "${YELLOW}⚠ Lines with spaces or tabs at the start or end: $(fmt_num "$n") of $(fmt_num "$total")${pct}, $(fmt_mb "$b") — to remove or trim them: item 7, tool 14${NC}"
    mapfile -t ex < <(edge_examples "$f" '^[[:blank:]]{1,2}[[:alnum:]]{4,}$' '^[[:alnum:]]{4,}[[:blank:]]{1,2}$')
    (( ${#ex[@]} > 0 )) || mapfile -t ex < <(edge_examples "$f" '^[[:blank:]]+[^[:blank:]]' '[^[:blank:]][[:blank:]]+$')
    for l in "${ex[@]}"; do
        (( ${#l} > 60 )) && l="${l:0:60}…"
        L t "  Например (· — пробел, → — таб): «${l}»" "  For example (· is a space, → is a tab): «${l}»"
        log_line "$t"
    done
    return 0
}

BLANK_ERE=$'^[ \t]*\r?$'
# Item 3 takes the file as is: warn about garbage that will end up in the result.
compare_warn() {
    local f="$1" d k n parts="" t
    local -a pids=()
    d="$(mktemp -d "${TMPDIR:-/tmp}/dedup_tool.XXXXXX" 2>/dev/null)" || return 0
    TMP_DIRS=("$d")
    [[ -n "$UTF8_LOCALE" ]] && { LC_ALL="$UTF8_LOCALE" grep -a -c -v -x '.*' -- "$f" > "$d/bad" 2>/dev/null & pids+=($!); }
    LC_ALL=C grep -a -c -P '\x00' -- "$f" > "$d/nul" 2>/dev/null & pids+=($!)
    LC_ALL=C grep -a -c "$FFFD_CHR" -- "$f" > "$d/fffd" 2>/dev/null & pids+=($!)
    LC_ALL=C grep -a -c -e "$CTRL_RE" -e "$C1_RE" -- "$f" > "$d/ctrl" 2>/dev/null & pids+=($!)
    LC_ALL=C grep -a -U -c "${CR_CHR}." -- "$f" > "$d/cr" 2>/dev/null & pids+=($!)
    LC_ALL=C grep -a -U -c -E "$BLANK_ERE" -- "$f" > "$d/blank" 2>/dev/null & pids+=($!)
    COUNTER_PIDS=("${pids[@]}")
    wait "${pids[@]}" 2>/dev/null
    COUNTER_PIDS=()
    for k in bad nul fffd ctrl cr blank; do
        n=""
        [[ -f "$d/$k" ]] && read -r n < "$d/$k"
        [[ "$n" =~ ^[1-9][0-9]*$ ]] || continue
        case "$k" in
            bad)   L t ", не в UTF-8 — $(fmt_num "$n")" ", not UTF-8: $(fmt_num "$n")" ;;
            nul)   L t ", с NUL — $(fmt_num "$n")" ", with NUL: $(fmt_num "$n")" ;;
            fffd)  L t ", с U+FFFD — $(fmt_num "$n")" ", with U+FFFD: $(fmt_num "$n")" ;;
            ctrl)  L t ", с управляющими символами — $(fmt_num "$n")" ", with control characters: $(fmt_num "$n")" ;;
            cr)    L t ", с символом CR внутри строки — $(fmt_num "$n")" ", with a CR inside the line: $(fmt_num "$n")" ;;
            blank) L t ", пустых или из одних пробелов — $(fmt_num "$n")" ", empty or only spaces: $(fmt_num "$n")" ;;
        esac
        parts+="$t"
    done
    rm -rf -- "$d"
    TMP_DIRS=()
    [[ -n "$parts" ]] || return 0
    say "${YELLOW}⚠ В ${f} есть строки, которые пункт 3 не чистит, — они попадут в итог: ${parts#, }${NC}" "${YELLOW}⚠ ${f} has lines that item 3 does not clean — they will end up in the result: ${parts#, }${NC}"
    say "  Подготовить файл — пункт 1 (подготовка и сравнение) или пункт 2, а потом пункт 3." "  To prepare the file use item 1 (preparation and comparison), or item 2 and then item 3."
}
FFFD_CHR=$'\xef\xbf\xbd'

declare -A RU_FREQ=([о]=110 [е]=85 [а]=80 [и]=74 [н]=67 [т]=63 [с]=55 [р]=47 [в]=45 [л]=44 [к]=35
    [м]=32 [д]=30 [п]=28 [у]=26 [я]=20 [ы]=19 [ь]=17 [г]=17 [з]=17 [б]=16 [ч]=14 [й]=12 [х]=10
    [ж]=9 [ш]=7 [ю]=6 [ц]=5 [щ]=4 [э]=3 [ф]=3
    [О]=110 [Е]=85 [А]=80 [И]=74 [Н]=67 [Т]=63 [С]=55 [Р]=47 [В]=45 [Л]=44 [К]=35
    [М]=32 [Д]=30 [П]=28 [У]=26 [Я]=20 [Ы]=19 [Ь]=17 [Г]=17 [З]=17 [Б]=16 [Ч]=14 [Й]=12 [Х]=10
    [Ж]=9 [Ш]=7 [Ю]=6 [Ц]=5 [Щ]=4 [Э]=3 [Ф]=3)
D8_ENC=""; D8_BAD=0; D8_HI=0
declare -a D8_EX=()
# Lines not in UTF-8: guess WINDOWS-1251, KOI8-R or CP866 by Russian letter frequencies.
detect_8bit() {
    local f="$1" e s n_all w cnt ch best="" bs=0 second=0 sample
    D8_ENC=""; D8_BAD=0; D8_HI=0; D8_EX=()
    [[ -n "$UTF8_LOCALE" ]] && command -v iconv >/dev/null 2>&1 || return 0
    D8_BAD="$(LC_ALL="$UTF8_LOCALE" grep -a -c -v -x '.*' -- "$f" 2>/dev/null)"
    [[ "$D8_BAD" =~ ^[0-9]+$ ]] || D8_BAD=0
    (( D8_BAD > 0 )) || return 0
    D8_HI="$(LC_ALL=C grep -a -c $'[\x80-\xff]' -- "$f" 2>/dev/null)"
    [[ "$D8_HI" =~ ^[0-9]+$ ]] || D8_HI=0
    sample="$(LC_ALL="$UTF8_LOCALE" grep -a -v -x '.*' -- "$f" | head -c 262144)"
    for e in WINDOWS-1251 KOI8-R CP866; do
        n_all=0; w=0
        while read -r cnt ch; do
            n_all=$(( n_all + cnt ))
            w=$(( w + cnt * ${RU_FREQ[$ch]:-0} ))
        done < <(printf '%s\n' "$sample" | iconv -f "$e" -t UTF-8 -c 2>/dev/null \
                 | LC_ALL="$UTF8_LOCALE" grep -a -o -P '[^\x00-\x7f]' | LC_ALL=C sort | LC_ALL=C uniq -c)
        (( n_all >= 30 )) || continue
        s=$(( w / n_all ))
        if (( s > bs )); then second=$bs; bs=$s; best="$e"
        elif (( s > second )); then second=$s; fi
    done
    (( bs >= 40 && bs * 10 >= second * 13 )) || return 0
    D8_ENC="$best"
    mapfile -t D8_EX < <(printf '%s\n' "$sample" | LC_ALL=C grep -a -m 3 -E '^.{1,40}$' \
                           | iconv -f "$best" -t UTF-8 -c 2>/dev/null | ctrl_visible)
}

S7_ALL=0; S7_KEEP=0; S7_LAT=0
declare -a S7_WLO=(80 16 45 17 30 85 9 17 74 12 35 44 32 67 110 28)
declare -a S7_WHI=(47 55 63 26 3 10 5 14 7 4 0 19 17 3 6 20)
# Does the ASCII part of the file look like Russian CP866 text without the high bit?
detect_7bit() {
    local f="$1" cnt hx b n=0 lo=0 w=0 lat asc
    S7_ALL=0; S7_KEEP=0; S7_LAT=0
    while read -r cnt hx; do
        [[ -n "$hx" ]] || continue
        b=$(( 16#$hx ))
        (( b == 0x0a )) && continue
        n=$(( n + cnt ))
        if (( b >= 0x20 && b <= 0x2f )); then lo=$(( lo + cnt )); w=$(( w + cnt * S7_WLO[b - 0x20] ))
        elif (( b <= 0x0f )); then lo=$(( lo + cnt )); w=$(( w + cnt * S7_WLO[b] ))
        elif (( b <= 0x1f )); then w=$(( w + cnt * S7_WHI[b - 0x10] ))
        elif (( b >= 0x60 && b <= 0x6f )); then w=$(( w + cnt * S7_WHI[b - 0x60] ))
        elif (( b == 0x71 )); then w=$(( w + cnt * 3 ))
        fi
    done < <(LC_ALL=C grep -a -U -P "$S7_LINE_RE" -- "$f" 2>/dev/null | head -c 262144 \
             | LC_ALL=C sed -b 's/\r$//' | od -An -tx1 -v | tr -s ' ' '\n' | LC_ALL=C sort | LC_ALL=C uniq -c)
    (( n >= 30 )) || return 0
    (( lo * 100 >= n * 50 && lo * 100 <= n * 90 && w >= n * 40 )) || return 0
    S7_ALL="$(LC_ALL=C grep -a -U -c -P "$S7_LINE_RE" -- "$f" 2>/dev/null)"
    [[ "$S7_ALL" =~ ^[0-9]+$ ]] || S7_ALL=0
    lat="$(LC_ALL=C grep -a -U -v -P '[\x80-\xff]' -- "$f" 2>/dev/null | LC_ALL=C grep -a -c -P '[A-Zpr-z]')"
    [[ "$lat" =~ ^[0-9]+$ ]] || lat=0
    if (( S7_ALL < lat )); then S7_ALL=0; return 0; fi
    S7_LAT=$lat
    asc="$(LC_ALL=C grep -a -U -v -P '[\x80-\xff]' -- "$f" 2>/dev/null | LC_ALL=C grep -a -U -c -v -P '^\r?$')"
    [[ "$asc" =~ ^[0-9]+$ ]] && (( asc > S7_ALL )) && S7_KEEP=$(( asc - S7_ALL ))
    return 0
}

MIX_BAD=$'[\xc0-\xff][\x01-\x7f\xc0-\xff]|[\x01-\x7f][\x80-\xbf]|^[\x80-\xbf]|[\xc0-\xff]\r?$'
declare -a MIX_SED=()
# sed program that converts only the non-UTF-8 lines of a mixed file (MIX_SED).
mix_sed_build() {
    local enc="$1" b hx e s="" tok cur="" i=0
    local -a u=()
    for (( b = 0x80; b <= 0xff; b++ )); do printf -v hx '%02x' "$b"; s+="\\x${hx}\\n"; done
    for tok in $(printf "$s" | iconv -f "$enc" -t UTF-8 -c 2>/dev/null | od -An -tx1 -v); do
        if [[ "$tok" == 0a ]]; then u[i]="$cur"; cur=""; i=$((i + 1)); else cur+="\\x${tok}"; fi
    done
    (( i == 128 )) || return 1
    MIX_SED=(-e $'/\x01/b' -e "/${MIX_BAD}/"'!b' -e 's/[\x80-\xff]/\x01&/g')
    for (( b = 0x80; b <= 0xff; b++ )); do
        i=$(( b - 0x80 ))
        [[ -n "${u[i]}" ]] || u[i]='\xef\xbf\xbd'
        printf -v e 's/\\x01\\x%02x/%s/g' "$b" "${u[i]}"; MIX_SED+=(-e "$e")
    done
}
_st_mix() { LC_ALL=C sed -b -E "${MIX_SED[@]}"; }

# All preparation questions; the answers go to the local variables of prep_file.
prep_questions() {
    local q t
    say "\n${GREEN}=== Подготовка: вопросы ===${NC}" "\n${GREEN}=== Preparation: questions ===${NC}"
    say "Ответы запоминаются; файл пройдёт через выбранные шаги одним проходом после всех вопросов." "Answers are only remembered; after all questions the file goes through the chosen steps in one pass."

    enc16="$(detect_utf16 "$input")"
    if [[ -n "$enc16" ]]; then
        say "${YELLOW}⚠ Файл похож на ${enc16} (BOM или нулевые байты 00H) — то же, на что ругаются EmEditor, Notepad++ и т.п.${NC}" "${YELLOW}⚠ The file looks like ${enc16} (BOM or 00H null bytes) — what EmEditor, Notepad++ and others complain about${NC}"
        if ! command -v iconv >/dev/null 2>&1; then
            say "${RED}⚠ iconv не найден — сконвертировать UTF-16 нечем, результат будет мусорным${NC}" "${RED}⚠ iconv not found — UTF-16 cannot be converted, the result will be garbage${NC}" >&2
        elif L q "Сконвертировать из ${enc16} в UTF-8?" "Convert from ${enc16} to UTF-8?"; confirm_action "$q" y; then
            enc="$enc16"
        else
            say "${RED}⚠ Без конвертации UTF-16 пройдёт дальше мусором: нулевые байты — валидные символы UTF-8, проверка их не уберёт${NC}" "${RED}⚠ Without conversion UTF-16 goes on as garbage: null bytes are valid UTF-8, the check will not remove them${NC}"
        fi
    fi

    if [[ -z "$enc16" ]]; then
        detect_7bit "$input"
        s7_all=$S7_ALL; s7_keep=$S7_KEEP; s7_lat=$S7_LAT
        if (( s7_all > 0 )) && has_crlf "$input"; then
            local n_crend
            n_crend="$(LC_ALL=C grep -a -U -c "${CR_CHR}\$" -- "$input" 2>/dev/null)"
            [[ "$n_crend" =~ ^[0-9]+$ ]] && (( n_crend * 2 < $(wc -l < "$input") )) && s7_cr_letter=true
        fi
    fi

    if [[ -z "$enc16" ]]; then
        if has_bom "$input"; then
            feff_mid="$(tail -c +4 -- "$input" | LC_ALL=C grep -a -c "$BOM_CHR")"
        else
            feff_mid="$(LC_ALL=C grep -a -c "$BOM_CHR" -- "$input" 2>/dev/null)"
        fi
        [[ "$feff_mid" =~ ^[0-9]+$ ]] || feff_mid=0
    fi
    if [[ -n "$enc" ]]; then
        say "${BLUE}✓ CRLF и BOM уберутся вместе с конвертацией${NC}" "${BLUE}✓ CRLF and BOM will be removed with the conversion${NC}"
    elif { has_crlf "$input" && ! $s7_cr_letter; } || has_bom "$input" || (( feff_mid > 0 )); then
        (( feff_mid > 0 )) && say "${YELLOW}⚠ Строк с невидимым U+FEFF (BOM) внутри файла: $(fmt_num "$feff_mid") — с ним слово не совпадёт с тем же словом в эталоне${NC}" "${YELLOW}⚠ Lines with an invisible U+FEFF (BOM) inside the file: $(fmt_num "$feff_mid") — such a word will not match the same word in a reference${NC}"
        L q "Найдены CRLF и/или BOM. Убрать?" "CRLF and/or BOM found. Remove them?"
        if confirm_action "$q" y; then
            do_strip=true
        else
            say "${YELLOW}⚠ CRLF/BOM останутся: такие строки не совпадут с теми же строками эталонов${NC}" "${YELLOW}⚠ CRLF/BOM stay: such lines will not match the same lines of references${NC}"
        fi
    else
        say "${BLUE}✓ CRLF и BOM не обнаружены${NC}" "${BLUE}✓ No CRLF or BOM${NC}"
    fi

    if [[ -z "$enc16" ]]; then
        nul_all="$(LC_ALL=C grep -a -c -P '\x00' -- "$input" 2>/dev/null)"
        [[ "$nul_all" =~ ^[0-9]+$ ]] || nul_all=0
        if (( s7_all > 0 && nul_all > 0 )); then
            s7_nul="$(LC_ALL=C grep -a -P '\x00' -- "$input" | LC_ALL=C grep -a -U -c -P "$S7_LINE_RE")"
            [[ "$s7_nul" =~ ^[0-9]+$ ]] || s7_nul=0
            nul_all=$(( nul_all - s7_nul ))
        fi
    fi
    if (( nul_all > 0 )); then
        nul_word="$(LC_ALL=C grep -a -c -P "$NUL_WORD_RE" -- "$input" 2>/dev/null)"
        [[ "$nul_word" =~ ^[0-9]+$ ]] || nul_word=0
        say "${YELLOW}⚠ Строк с байтами NUL (00H): $(fmt_num "$nul_all") — из-за них EmEditor и другие редакторы считают файл двоичным${NC}" "${YELLOW}⚠ Lines with NUL bytes (00H): $(fmt_num "$nul_all") — because of them EmEditor and other editors treat the file as binary${NC}"
        if (( nul_word > 0 )); then
            mapfile -t nul_ex < <(LC_ALL=C grep -a -m 3 -P '^\x00?(?:[\x20-\x7e]\x00){1,20}\r?$|^(?:\x00[\x20-\x7e]){1,20}\r?$' -- "$input" \
                                  | LC_ALL=C sed -b -e 's/\r$//' -e 's/\x00/␀/g')
            say "  Из них слова в UTF-16 — после каждой буквы NUL: $(fmt_num "$nul_word")${nul_ex:+. Например (␀ — NUL):}" "  Of them, words in UTF-16 (a NUL after each letter): $(fmt_num "$nul_word")${nul_ex:+. For example (␀ is NUL):}"
            for l in "${nul_ex[@]}"; do
                l="${l//\\/\\\\}"
                say "   «${l}» → «${l//␀/}»"
            done
            L q "Восстановить эти слова (убрать NUL)?" "Restore these words (remove NUL)?"
            if confirm_action "$q" y; then
                do_nul=true
            else
                say "${YELLOW}⚠ Слова с NUL не совпадут с теми же словами в эталоне${NC}" "${YELLOW}⚠ Words with NUL will not match the same words in a reference${NC}"
            fi
        fi
        (( nul_all > nul_word )) && say "  Не похожи на слова: $(fmt_num $(( nul_all - nul_word )))" "  Not like words: $(fmt_num $(( nul_all - nul_word )))"
        nul_left=$nul_all
        $do_nul && nul_left=$(( nul_all - nul_word ))
        (( nul_left > 0 )) && say "  Строк с NUL останется: $(fmt_num "$nul_left") — их уберёт проверка UTF-8 (следующий вопрос)" "  Lines with NUL left: $(fmt_num "$nul_left") — the UTF-8 check removes them (a later question)"
    fi

    if [[ -z "$enc16" ]]; then
        detect_8bit "$input"
        if [[ -n "$D8_ENC" ]]; then
            local vhi=$(( D8_HI - D8_BAD )) ename="" ex mixed=false
            (( vhi > 0 && vhi * 100 >= D8_HI )) && mixed=true
            case "$D8_ENC" in
                WINDOWS-1251) L ename "Кириллица (Windows)" "Cyrillic (Windows)" ;;
                KOI8-R)       L ename "Кириллица (KOI8-R)" "Cyrillic (KOI8-R)" ;;
                CP866)        L ename "Кириллица (DOS)" "Cyrillic (DOS)" ;;
            esac
            if $mixed; then
                say "${YELLOW}⚠ Строк не в UTF-8: $(fmt_num "$D8_BAD"), а ещё $(fmt_num "$vhi") строк с не-ASCII — в UTF-8. Похоже на ${D8_ENC} (в редакторе — «${ename}»)${NC}" "${YELLOW}⚠ Lines not in UTF-8: $(fmt_num "$D8_BAD"), and $(fmt_num "$vhi") more lines with non-ASCII are UTF-8. Looks like ${D8_ENC} (in an editor: “${ename}”)${NC}"
            else
                say "${YELLOW}⚠ Файл не в UTF-8: строк не в UTF-8 — $(fmt_num "$D8_BAD") из $(fmt_num "$D8_HI") с не-ASCII. Похоже на ${D8_ENC} (в редакторе — «${ename}»)${NC}" "${YELLOW}⚠ The file is not UTF-8: $(fmt_num "$D8_BAD") of $(fmt_num "$D8_HI") lines with non-ASCII are not UTF-8. Looks like ${D8_ENC} (in an editor: “${ename}”)${NC}"
            fi
            (( ${#D8_EX[@]} > 0 )) && say "  Например, после перевода:" "  For example, after conversion:"
            for ex in "${D8_EX[@]}"; do say "   «${ex//\\/\\\\}»"; done
            if $mixed; then
                L q "Перекодировать эти строки из ${D8_ENC} в UTF-8?" "Convert these lines from ${D8_ENC} to UTF-8?"
                if confirm_action "$q" y; then
                    if mix_sed_build "$D8_ENC"; then
                        do_mix=true; mix_all=$D8_BAD; mix_enc="$D8_ENC"
                    else
                        say "${YELLOW}⚠ Не удалось собрать таблицу перевода из ${D8_ENC} — строки не в UTF-8 останутся${NC}" "${YELLOW}⚠ Could not build the ${D8_ENC} conversion table — the non-UTF-8 lines stay${NC}"
                    fi
                fi
            else
                enc8="$D8_ENC"
                say "  ${D8_ENC} подставится по Enter на вопросе о кодировке" "  ${D8_ENC} will be used if you press Enter at the encoding question"
            fi
        fi
    fi

    if [[ -z "$enc16" ]]; then
        moji_all="$(LC_ALL=C grep -a -E "$MOJI_LEAD" -- "$input" | LC_ALL=C grep -a -c -E "$MOJI_RE")"
        [[ "$moji_all" =~ ^[0-9]+$ ]] || moji_all=0
        dos_all="$(LC_ALL=C grep -a -E "$DOS_SYM" -- "$input" | _st_dos_sel | LC_ALL=C grep -a -c '')"
        [[ "$dos_all" =~ ^[0-9]+$ ]] || dos_all=0
        u8_all="$(LC_ALL=C grep -a -E "$U8X_START" -- "$input" | _st_u8_sel | LC_ALL=C grep -a -c '')"
        [[ "$u8_all" =~ ^[0-9]+$ ]] || u8_all=0
        if (( dos_all > 0 )); then
            dosp_all="$(LC_ALL=C grep -a -E "$DOSP_RE" -- "$input" | _st_dosp_sel | LC_ALL=C grep -a -c '')"
            [[ "$dosp_all" =~ ^[0-9]+$ ]] || dosp_all=0
            dos_all=$(( dos_all + dosp_all ))
        fi
        detect_koi "$input"
        koi_all=$KOI_ALL
    fi
    if (( moji_all > 0 )); then
        say "${YELLOW}⚠ Строк с кракозябрами — текстом в UTF-8, который прочитали как Windows-1252: $(fmt_num "$moji_all")${NC}" "${YELLOW}⚠ Mojibake lines — UTF-8 text read as Windows-1252: $(fmt_num "$moji_all")${NC}"
        LC_ALL=C grep -a -E "$MOJI_LEAD" -- "$input" | LC_ALL=C grep -a -E "$MOJI_RE" \
            | moji_examples _st_moji "$MOJI_CYR"
    fi
    if (( dos_all > 0 )); then
        say "${YELLOW}⚠ Строк с кракозябрами — текстом в DOS-кодировке (CP866), который прочитали как Windows-1251: $(fmt_num "$dos_all")${NC}" "${YELLOW}⚠ Mojibake lines — Russian DOS text (CP866) read as Windows-1251: $(fmt_num "$dos_all")${NC}"
        LC_ALL=C grep -a -E "$DOS_SYM" -- "$input" | _st_dos_sel | moji_examples _st_cyr
    fi
    if (( u8_all > 0 )); then
        say "${YELLOW}⚠ Строк с кракозябрами — текстом в UTF-8, который прочитали как Windows-1251: $(fmt_num "$u8_all")${NC}" "${YELLOW}⚠ Mojibake lines — UTF-8 text read as Windows-1251: $(fmt_num "$u8_all")${NC}"
        LC_ALL=C grep -a -E "$U8X_START" -- "$input" | _st_u8_sel | moji_examples _st_cyr
    fi
    if (( koi_all > 0 )); then
        say "${YELLOW}⚠ Строк с кракозябрами — текстом в KOI8-R, который прочитали как Windows-1251: $(fmt_num "$koi_all")${NC}" "${YELLOW}⚠ Mojibake lines — Russian KOI8-R text read as Windows-1251: $(fmt_num "$koi_all")${NC}"
        _koi_cands "$input" | _koi_awk sel | moji_examples _st_koi
        say "  Решает частота сочетаний букв: настоящее слово заглавными изредка тоже будет переведено, короткое — чаще. Если таких слов в файле много, откажитесь." "  Letter pair frequencies decide: a real word in capitals is sometimes converted too, a short one more often. If the file has many such words, say no."
        (( KOI_REST > 0 )) && say "  Ещё строк заглавными, не похожих на такой текст: $(fmt_num "$KOI_REST") — их не трогаю." "  Other lines in capitals that do not look like such text: $(fmt_num "$KOI_REST") — they stay as they are."
    fi
    if (( s7_all > 0 )); then
        s7_sed_build "$s7_cr_letter"
        say "${YELLOW}⚠ Похоже на русский текст в DOS-кодировке (CP866), у которого потерян старший бит: буква «а» стала пробелом, другие буквы — знаками. Таких строк: $(fmt_num "$s7_all")${NC}" "${YELLOW}⚠ Looks like Russian text in DOS encoding (CP866) that lost its high bit: the letter «а» became a space, other letters became symbols. Such lines: $(fmt_num "$s7_all")${NC}"
        LC_ALL=C grep -a -U -P "$S7_LINE_RE" -- "$input" | LC_ALL=C grep -a -U -v -P '\x00' | moji_examples _st_s7
        say "  Настоящие пробелы, дефисы и другие знаки в этих строках тоже станут буквами (дефис — «н»), а заглавная «К» разорвала слово на две строки: этого не вернуть." "  Real spaces, hyphens and other signs in these lines also become letters (a hyphen becomes «н»), and a capital «К» split its word into two lines: this cannot be undone."
        (( s7_keep > 0 )) && say "  Строк с цифрами или латиницей: $(fmt_num "$s7_keep") — их не трогаю: в них не отличить букву от настоящего знака." "  Lines with digits or Latin letters: $(fmt_num "$s7_keep") — they stay as they are: there a letter cannot be told from a real sign."
        (( s7_lat > 0 )) && say "  Раз в файле есть и настоящая латиница, слова только из букв a–o среди неё тоже станут русскими." "  Since the file also has real Latin text, its words made only of the letters a–o also become Russian."
    fi
    if (( moji_all + dos_all + u8_all + koi_all + s7_all > 0 )); then
        L q "Восстановить кракозябры в нормальный текст?" "Restore the mojibake to normal text?"
        if confirm_action "$q" y; then
            do_moji=true
        else
            say "${YELLOW}⚠ Кракозябры останутся: с тем же текстом в эталоне они не совпадут${NC}" "${YELLOW}⚠ The mojibake stays: it will not match the same text in a reference${NC}"
            (( s7_nul > 0 )) && { nul_all=$(( nul_all + s7_nul )); nul_left=$(( nul_left + s7_nul )); }
        fi
    fi

    if [[ -z "$enc16" ]]; then
        cr_mid="$(LC_ALL=C grep -a -U -c "${CR_CHR}." -- "$input" 2>/dev/null)"
        [[ "$cr_mid" =~ ^[0-9]+$ ]] || cr_mid=0
        if $do_moji && (( s7_all > 0 && cr_mid > 0 )); then
            cr_mid="$(LC_ALL=C grep -a -U "${CR_CHR}." -- "$input" | LC_ALL=C grep -a -U -c -v -P "$S7_LINE_RE")"
            [[ "$cr_mid" =~ ^[0-9]+$ ]] || cr_mid=0
        fi
    fi
    if (( cr_mid > 0 )); then
        mapfile -t cr_ex < <(LC_ALL=C grep -a -U "${CR_CHR}." -- "$input" \
                                 | { if $do_moji && (( s7_all > 0 )); then LC_ALL=C grep -a -U -v -P "$S7_LINE_RE"; else cat; fi; } \
                                 | LC_ALL=C grep -a -U -m 3 -E '^.{1,40}$' | ctrl_visible)
        say "${YELLOW}⚠ Строк с символом CR внутри строки: $(fmt_num "$cr_mid") — редакторы показывают его как перенос, и одна строка выглядит как две${NC}" "${YELLOW}⚠ Lines with a CR inside the line: $(fmt_num "$cr_mid") — editors show it as a line break, so one line looks like two${NC}"
        (( ${#cr_ex[@]} > 0 )) && say "  Например (␍ — CR):" "  For example (␍ is CR):"
        for l in "${cr_ex[@]}"; do
            say "   «${l//\\/\\\\}»"
        done
        L q "Разбить такие строки на CR?" "Split such lines at the CR?"
        if confirm_action "$q" y; then
            do_crsplit=true
        else
            say "${YELLOW}⚠ Строки с CR останутся: с теми же словами в эталоне они не совпадут${NC}" "${YELLOW}⚠ Lines with a CR stay: they will not match the same words in a reference${NC}"
        fi
    fi

    if [[ -z "$enc16" ]]; then
        ctrl_all="$(LC_ALL=C grep -a -c -e "$CTRL_RE" -e "$C1_RE" -- "$input" 2>/dev/null)"
        [[ "$ctrl_all" =~ ^[0-9]+$ ]] || ctrl_all=0
        if $do_moji && (( ctrl_all > 0 )); then
            ctrl_all="$(LC_ALL=C grep -a -e "$CTRL_RE" -e "$C1_RE" -- "$input" | _st_unmoji \
                        | LC_ALL=C grep -a -c -e "$CTRL_RE" -e "$C1_RE")"
            [[ "$ctrl_all" =~ ^[0-9]+$ ]] || ctrl_all=0
        fi
    fi
    if (( ctrl_all > 0 )); then
        mapfile -t ctrl_ex < <(LC_ALL=C grep -a -e "$CTRL_RE" -e "$C1_RE" -- "$input" \
                                   | { if $do_moji; then _st_unmoji | LC_ALL=C grep -a -e "$CTRL_RE" -e "$C1_RE"; else cat; fi; } \
                                   | LC_ALL=C grep -a -m 3 -E '^.{1,40}$' | ctrl_visible)
        say "${YELLOW}⚠ Строк с управляющими символами: $(fmt_num "$ctrl_all") — в редакторе это непонятные значки${NC}" "${YELLOW}⚠ Lines with control characters: $(fmt_num "$ctrl_all") — odd symbols in an editor${NC}"
        (( ${#ctrl_ex[@]} > 0 )) && say "  Например (␁…␟, ␡ — коды 01–1F и 7F, □ — U+0080–U+009F):" "  For example (␁…␟, ␡ are codes 01–1F and 7F, □ is U+0080–U+009F):"
        for l in "${ctrl_ex[@]}"; do
            say "   «${l//\\/\\\\}»"
        done
        say "  Их уберёт проверка UTF-8 (следующий вопрос)" "  The UTF-8 check removes them (the next question)"
    fi

    local utf8_default=n src
    local enc_prompt
    L enc_prompt "Если файл в другой кодировке — укажите её (например WINDOWS-1251), Enter — просто убрать нечитаемое: " "If the file is in another encoding, type it (for example WINDOWS-1251); Enter — just remove unreadable lines: "
    if [[ -n "$enc16" && -z "$enc" ]]; then
        utf8_default=y
        L enc_prompt "Если файл в другой кодировке — укажите её (например WINDOWS-1251), Enter — сконвертировать из ${enc16}: " "If the file is in another encoding, type it (for example WINDOWS-1251); Enter — convert from ${enc16}: "
    elif [[ -n "$enc8" ]]; then
        utf8_default=y
        L enc_prompt "Если файл в другой кодировке — укажите её (например WINDOWS-1251), Enter — сконвертировать из ${enc8}: " "If the file is in another encoding, type it (for example WINDOWS-1251); Enter — convert from ${enc8}: "
    fi
    if [[ -z "$enc16" && -z "$enc" && -z "$enc8" ]] && ! $do_mix && (( D8_BAD > 0 )); then
        bad_utf8=$D8_BAD
        say "${YELLOW}⚠ Строк не в UTF-8: $(fmt_num "$bad_utf8") — проверка их уберёт. Если в них нужный текст, укажите кодировку или сохраните их отдельным файлом (вопрос ниже)${NC}" "${YELLOW}⚠ Lines not in UTF-8: $(fmt_num "$bad_utf8") — the check removes them. If they hold text you need, type the encoding or save them to a separate file (a later question)${NC}"
    fi
    L q "Проверить на валидность UTF-8 и убрать нечитаемые строки?" "Check for valid UTF-8 and remove unreadable lines?"
    if confirm_action "$q" "$utf8_default"; then
        do_utf8=true
        if [[ -n "$enc" ]]; then
            :
        elif $do_mix; then
            :
        elif ! command -v iconv >/dev/null 2>&1; then
            say "${YELLOW}⚠ iconv не найден — только проверка, без конвертации${NC}" "${YELLOW}⚠ iconv not found — only the check, no conversion${NC}"
        else
            while true; do
                ask_value "$enc_prompt" ""
                src="$REPLY"
                [[ -z "$src" && -n "$enc16" ]] && src="$enc16"
                [[ -z "$src" && -n "$enc8" ]] && src="$enc8"
                [[ -z "$src" ]] && break
                if iconv_known "$src"; then
                    enc="$src"
                    break
                fi
                say "${RED}✘ iconv не знает кодировку '$src' (список: iconv -l) — введите другую или Enter${NC}" "${RED}✘ iconv does not know the encoding '$src' (list: iconv -l) — type another one or press Enter${NC}" >&2
            done
        fi
        [[ -n "$enc" ]] && bad_utf8=0
        [[ -z "$UTF8_LOCALE" ]] && say "${YELLOW}⚠ UTF-8 локаль не найдена — проверяю только символ-заменитель, невалидные байты не ловятся${NC}" "${YELLOW}⚠ No UTF-8 locale — only the replacement character is checked, invalid bytes are not caught${NC}"
    fi

    if [[ -z "$enc16" || -n "$enc" ]]; then
        local blank_re="$BLANK_RE" n_cr=0
        $do_moji && (( s7_all > 0 )) && blank_re='^\r?$'
        $do_moji && $s7_cr_letter && blank_re='^$'
        case "${enc^^}" in
            UTF-16*|UCS-*|UTF-32*) blank_all="$(iconv -f "$enc" -t UTF-8 -c < "$input" 2>/dev/null | LC_ALL=C grep -a -U -c -P "$blank_re")" ;;
            *) blank_all="$(LC_ALL=C grep -a -U -c -P "$blank_re" -- "$input" 2>/dev/null)" ;;
        esac
        [[ "$blank_all" =~ ^[0-9]+$ ]] || blank_all=0
        if $do_crsplit; then
            n_cr="$(LC_ALL=C grep -a -U "${CR_CHR}." -- "$input" | { if $do_moji && (( s7_all > 0 )); then LC_ALL=C grep -a -U -v -P "$S7_LINE_RE"; else cat; fi; } \
                    | _st_crsplit | LC_ALL=C grep -a -U -c -P "$BLANK_RE")"
            [[ "$n_cr" =~ ^[0-9]+$ ]] && blank_all=$(( blank_all + n_cr ))
        fi
    fi
    if (( blank_all > 0 )); then
        say "${YELLOW}⚠ Пустых строк и строк из одних пробелов или табов: $(fmt_num "$blank_all")${NC}" "${YELLOW}⚠ Empty lines and lines of only spaces or tabs: $(fmt_num "$blank_all")${NC}"
        L q "Убрать их?" "Remove them?"
        confirm_action "$q" y && do_blank=true
    fi

    L q "Фильтровать строки по длине?" "Filter lines by length?"
    if confirm_action "$q" n; then
        L q "Минимальная длина строки [8]: " "Minimum line length [8]: "; ask_value "$q" 8; min="$REPLY"
        L q "Максимальная длина строки [16]: " "Maximum line length [16]: "; ask_value "$q" 16; max="$REPLY"
        if ! [[ "$min" =~ ^[0-9]+$ && "$max" =~ ^[0-9]+$ ]] || (( 10#$min > 10#$max || 10#$max > 32767 )); then
            say "${RED}✘ Некорректные границы длины ('$min' и '$max': нужны целые 0 ≤ мин ≤ макс ≤ 32767) — фильтр по длине пропущен${NC}" "${RED}✘ Wrong length limits ('$min' and '$max': need integers 0 ≤ min ≤ max ≤ 32767) — the length filter is skipped${NC}" >&2
        else
            min=$((10#$min)); max=$((10#$max))
            do_len=true
        fi
    fi

    L q "Удалить строки, состоящие только из цифр?" "Remove lines made of digits only?"
    if confirm_action "$q" n; then
        do_dig=true
        local dv dlo dhi
        while true; do
            L q "Какие цифровые строки нужно удалить (8, 9, 10…; Enter — все): " "Which digit lines to remove (8, 9, 10…; Enter — all): "
            ask_value "$q" ""
            dv="${REPLY//[[:space:]]/}"
            dv="${dv#до}"; dv="${dv#До}"; dv="${dv#upto}"; dv="${dv#Upto}"
            [[ "$dv" =~ ^(от|От|from|From)([0-9]+)(до|to)([0-9]+)$ ]] && dv="${BASH_REMATCH[2]}-${BASH_REMATCH[4]}"
            dlo=0; dhi=0
            if [[ -z "$dv" ]]; then
                dlo=1; dhi=32767
            elif [[ "$dv" =~ ^[0-9]{1,5}$ ]]; then
                dlo=1; dhi=$((10#$dv))
            elif [[ "$dv" =~ ^([0-9]{1,5})-([0-9]{1,5})$ ]]; then
                dlo=$((10#${BASH_REMATCH[1]})); dhi=$((10#${BASH_REMATCH[2]}))
            fi
            (( dlo >= 1 && dlo <= dhi && dhi <= 32767 )) && break
            say "${RED}✘ '${REPLY}' не подходит: нужно число (например 8), диапазон (8-10) или Enter${NC}" "${RED}✘ '${REPLY}' does not fit: type a number (for example 8), a range (8-10) or press Enter${NC}" >&2
        done
        if [[ -z "$dv" ]]; then
            dig_re='^[0-9]+$'; L dig_name "любой длины" "of any length"
        else
            dig_re="^[0-9]{${dlo},${dhi}}\$"
            if [[ "$dv" != *-* ]]; then L dig_name "длиной до ${dhi}" "up to ${dhi} long"
            elif (( dlo == dhi )); then L dig_name "длиной ровно ${dhi}" "exactly ${dhi} long"
            else L dig_name "длиной от ${dlo} до ${dhi}" "${dlo} to ${dhi} long"; fi
        fi
        if $do_len && (( dhi < min || dlo > max )); then
            say "${YELLOW}⚠ После фильтра длины ${min}–${max} строк из цифр ${dig_name} не останется — этот шаг ничего не уберёт${NC}" "${YELLOW}⚠ After the length filter ${min}–${max} no digit lines ${dig_name} remain — this step removes nothing${NC}"
        fi
    fi

    if { $do_len && (( min > 1 )); } || $do_dig || { $do_utf8 && (( bad_utf8 > 0 )); }; then
        local what="" sb
        sb="$(final_base "$input")"
        $do_len && (( min > 1 )) && { L t ", короче ${min} — в ${sb}_short.txt" ", shorter than ${min} to ${sb}_short.txt"; what+="$t"; }
        $do_dig && { L t ", из цифр (${dig_name}) — в ${sb}_digits.txt" ", digits (${dig_name}) to ${sb}_digits.txt"; what+="$t"; }
        $do_utf8 && (( bad_utf8 > 0 )) && { L t ", не в UTF-8 — в ${sb}_notutf8.txt (как есть, с повторами)" ", not in UTF-8 to ${sb}_notutf8.txt (as they are, with duplicates)"; what+="$t"; }
        say "  Убранные строки можно сохранить в отдельные файлы${what/#,/:}" "  Removed lines can be saved to separate files${what/#,/:}"
        L q "Сохранить убранные строки в отдельные файлы?" "Save the removed lines to separate files?"
        if confirm_action "$q" n; then
            do_save=true
        fi
    fi
}

# Explain why a result converted from a single-byte encoding is bigger than the source.
size_note() {
    local e="" in_s out_s why
    L why "знаки не латиницы занимают 2–3 байта, а не 1" "non-Latin characters take 2–3 bytes instead of 1"
    if [[ -n "$enc" ]]; then e="$enc"; elif $do_mix; then e="$mix_enc"; elif $do_moji && (( s7_all > 0 )); then e=CP866; fi
    [[ -n "$e" ]] || return 0
    case "${e^^}" in UTF-*|UCS-*) return 0 ;; esac
    in_s=$(file_size "$1"); out_s=$(file_size "$2")
    (( out_s > in_s )) || return 0
    case "${e^^}" in
        *1251*|KOI8*|*866*|*8859-5*|MAC*CYR*|*855*) L why "русская буква занимает 2 байта, а не 1" "a Cyrillic letter takes 2 bytes instead of 1" ;;
    esac
    say "  Больше исходника ($(fmt_size "$in_s") в ${e}): в UTF-8 ${why}" "  Bigger than the source ($(fmt_size "$in_s") in ${e}): in UTF-8 ${why}"
}

PREP_RESULT=""
# One pass: preparation and, for items 1, 3 and 4, sort -u and comm -13 up to the result.
prep_file() {
    local input="$1" mode="${2:-clean}"
    local output="${input%.*}_prep.txt"
    local enc16 enc="" do_strip=false do_nul=false do_utf8=false do_len=false do_dig=false do_save=false
    local min=8 max=16 dig_re='^[0-9]+$' dig_name
    L dig_name "любой длины" "of any length"
    local nul_all=0 nul_word=0 nul_left=0 l
    local ctrl_all=0 feff_mid=0 moji_all=0 dos_all=0 u8_all=0 do_moji=false koi_all=0 dosp_all=0 bad_utf8=0
    local s7_all=0 s7_keep=0 s7_lat=0 s7_nul=0 s7_cr_letter=false cr_mid=0 do_crsplit=false blank_all=0 do_blank=false
    local enc8="" do_mix=false mix_all=0 mix_enc=""
    local -a nul_ex=() ctrl_ex=() cr_ex=()
    local strip_stage=_st_strip_all final="" k
    local -a P_REFS=() gen_no=()
    PREP_RESULT=""
    PREP_REF_NAMES=(); PREP_REF_HITS=()

    if [[ "$mode" == compare ]]; then
        strip_stage=_st_strip
        if has_crlf "$input" || has_bom "$input"; then
            do_strip=true
            say "├─ Найдены CRLF и/или BOM — уберутся в проходе, сам файл не меняется" "├─ CRLF and/or BOM found — removed in the pass, the file itself is unchanged"
        fi
        compare_warn "$input"
    else
        prep_questions
    fi

    if [[ "$mode" != clean ]]; then
        [[ "$mode" == full ]] && { prepare_refs || return 1; }
        for k in "${!CMP_REFS[@]}"; do
            [[ -n "${CMP_SKIP[k]:-}" ]] && continue
            P_REFS+=("${CMP_REFS[k]}")
            gen_no+=($((k + 1)))
        done
        pick_final_name "$(final_base "$input")"
        final="$REPLY"
        PREP_REF_NAMES=("${P_REFS[@]}")
    fi

    local nf=0 q t w_code
    L w_code код code
    $do_utf8 && nf=$((nf + 2))
    $do_blank && nf=$((nf + 1))
    $do_len && nf=$((nf + 1))
    $do_dig && nf=$((nf + 1))
    [[ "$mode" != clean ]] && nf=$((nf + 1 + ${#P_REFS[@]}))
    if [[ -z "$enc" ]] && ! $do_mix && ! $do_strip && ! $do_nul && ! $do_moji && ! $do_crsplit && (( nf == 0 )); then
        say "\n${BLUE}Делать нечего — прохода нет, дальше идёт сам файл ${input}${NC}" "\n${BLUE}Nothing to do — no pass, the file ${input} goes on as is${NC}"
        PREP_RESULT="$input"
        return 0
    fi
    if [[ "$mode" == clean ]]; then
        pick_prep_name "${input%.*}"
        output="$REPLY"
    fi

    if [[ "$mode" == clean ]]; then
        say "\n${GREEN}=== Подготовка: один проход ===${NC}" "\n${GREEN}=== Preparation: one pass ===${NC}"
    else
        say "\n${GREEN}=== Один проход до итога ===${NC}" "\n${GREEN}=== One pass to the result ===${NC}"
    fi
    if [[ "$mode" != clean ]]; then
        if ! output="$(mktemp "./.dedup_tool.XXXXXX" 2>/dev/null)"; then
            say "${RED}✘ Не удалось создать временный файл для ${final}${NC}" "${RED}✘ Could not create a temporary file for ${final}${NC}" >&2
            return 1
        fi
        IN_PROGRESS=("$output")
    fi
    if [[ ! -r "$input" ]] || ! : > "$output" 2>/dev/null; then
        say "${RED}✘ Не читается ${input} или не пишется ${output}${NC}" "${RED}✘ Cannot read ${input} or write ${output}${NC}" >&2
        [[ "$mode" != clean ]] && rm -f -- "$output"
        IN_PROGRESS=()
        return 1
    fi
    IN_PROGRESS=("$output")

    local fdir="" k use_counts=false
    local -a P_FIFO=() pids=()
    if (( nf > 0 )); then
        if fdir="$(mktemp -d "${TMPDIR:-/tmp}/dedup_tool.XXXXXX" 2>/dev/null)"; then
            TMP_DIRS=("$fdir")
            use_counts=true
            for (( k = 1; k <= nf; k++ )); do
                P_FIFO[k]="$fdir/f$k"
                mkfifo "${P_FIFO[k]}" 2>/dev/null || { use_counts=false; break; }
            done
        fi
        if ! $use_counts; then
            [[ -n "$fdir" ]] && rm -rf -- "$fdir"
            TMP_DIRS=()
            say "${YELLOW}⚠ Не удалось создать FIFO для счётчиков строк — статистика будет только итоговая${NC}" "${YELLOW}⚠ Could not create FIFOs for line counters — only the total will be shown${NC}"
        fi
    fi
    local -a P_SAVE=() save_tmp=()
    local save_short=false save_dig=false save_bad=false
    if $do_save; then
        if [[ -z "$fdir" ]] || ! $use_counts; then
            say "${YELLOW}⚠ Без FIFO убранные строки не сохранить — они будут просто убраны${NC}" "${YELLOW}⚠ Without FIFOs the removed lines cannot be saved — they will just be removed${NC}"
        else
            $do_len && (( min > 1 )) && save_short=true
            $do_dig && save_dig=true
            $do_utf8 && (( bad_utf8 > 0 )) && [[ -n "$UTF8_LOCALE" ]] && save_bad=true
            for k in 1 2 3; do
                [[ $k == 1 ]] && ! $save_short && continue
                [[ $k == 2 ]] && ! $save_dig && continue
                [[ $k == 3 ]] && ! $save_bad && continue
                P_SAVE[k]="$fdir/s$k"
                if ! mkfifo "${P_SAVE[k]}" 2>/dev/null || ! save_tmp[k]="$(mktemp "./.dedup_tool.XXXXXX" 2>/dev/null)"; then
                    say "${YELLOW}⚠ Не удалось подготовить сохранение убранных строк — они будут просто убраны${NC}" "${YELLOW}⚠ Could not prepare saving the removed lines — they will just be removed${NC}"
                    save_short=false; save_dig=false; save_bad=false
                    break
                fi
                IN_PROGRESS+=("${save_tmp[k]}")
            done
            if ! $save_short && ! $save_dig && ! $save_bad; then
                for k in "${!save_tmp[@]}"; do rm -f -- "${save_tmp[k]}"; done
                save_tmp=()
                IN_PROGRESS=("$output")
            fi
        fi
    fi

    local -a stages=() names=() steps=() filt=()
    local fi_n=0 nul_re=""
    if $do_mix; then
        L t "строки не в UTF-8 (${mix_enc} → UTF-8)" "lines not in UTF-8 (${mix_enc} → UTF-8)"
        stages+=(_st_mix); names+=(sed); steps+=("$t")
    fi
    if [[ -n "$enc" ]]; then
        stages+=(_st_iconv); names+=(iconv); steps+=("iconv (${enc} → UTF-8)")
    fi
    if [[ -n "$enc" ]] || $do_strip; then
        stages+=("$strip_stage"); names+=(sed); steps+=("CRLF/BOM")
    fi
    if $do_moji; then
        (( moji_all > 0 )) && { stages+=(_st_moji); names+=(sed); }
        (( dos_all + u8_all > 0 )) && { stages+=(_st_cyr); names+=(sed); }
        (( dosp_all > 0 )) && { stages+=(_st_dosp); names+=(sed); }
        (( koi_all > 0 )) && { stages+=(_st_koi); names+=(awk); }
        (( s7_all > 0 )) && { stages+=(_st_s7); names+=(sed); }
        L t "кракозябры → текст" "mojibake → text"; steps+=("$t")
    fi
    if $do_crsplit; then
        stages+=(_st_crsplit); names+=(sed)
        L t "CR внутри строки → новая строка" "CR inside a line → new line"; steps+=("$t")
    fi
    if $do_utf8; then
        fi_n=$((fi_n + 1))
        $use_counts && { stages+=("_st_count $fi_n"); names+=(tee); }
        $save_bad && { stages+=("_st_save 3"); names+=(tee); }
        [[ -n "$UTF8_LOCALE" ]] && { stages+=(_st_valid); names+=(grep); }
        if (( nul_left > 0 )); then
            stages+=(_st_nuldel); names+=(grep)
            if $do_nul; then nul_re="$NUL_JUNK_RE"; else nul_re='\x00'; fi
        fi
        stages+=(_st_fffd); names+=(grep)
        L t "проверка UTF-8" "UTF-8 check"; steps+=("$t")
        if (( nul_left > 0 )); then L t "нечитаемые (не UTF-8, U+FFFD или NUL)" "unreadable (not UTF-8, U+FFFD or NUL)"; filt+=("$t")
        else L t "нечитаемые (не UTF-8 или U+FFFD)" "unreadable (not UTF-8 or U+FFFD)"; filt+=("$t"); fi
        fi_n=$((fi_n + 1))
        $use_counts && { stages+=("_st_count $fi_n"); names+=(tee); }
        stages+=(_st_ctrl); names+=(grep)
        L t "управляющие символы" "control characters"; steps+=("$t")
        L t "с управляющими символами" "with control characters"; filt+=("$t")
    fi
    if $do_nul; then
        if $do_utf8 || (( nul_left == 0 )); then
            stages+=(_st_nul); names+=(tr)
        else
            stages+=(_st_nul_words); names+=(sed)
        fi
        L t "слова из UTF-16" "words from UTF-16"; steps+=("$t")
    fi
    if $do_blank; then
        fi_n=$((fi_n + 1))
        $use_counts && { stages+=("_st_count $fi_n"); names+=(tee); }
        stages+=(_st_blank); names+=(grep)
        L t "пустые строки" "empty lines"; steps+=("$t")
        L t "пустые и из одних пробелов" "empty or only spaces"; filt+=("$t")
    fi
    if $do_len; then
        fi_n=$((fi_n + 1))
        $use_counts && { stages+=("_st_count $fi_n"); names+=(tee); }
        $save_short && { stages+=("_st_save 1"); names+=(tee); }
        stages+=(_st_len); names+=(grep)
        L t "длина ${min}–${max}" "length ${min}–${max}"; steps+=("$t")
        L t "длина вне ${min}–${max}" "length outside ${min}–${max}"; filt+=("$t")
    fi
    if $do_dig; then
        fi_n=$((fi_n + 1))
        $use_counts && { stages+=("_st_count $fi_n"); names+=(tee); }
        $save_dig && { stages+=("_st_save 2"); names+=(tee); }
        stages+=(_st_dig); names+=(grep)
        L t "только цифры (${dig_name})" "digits only (${dig_name})"; steps+=("$t"); filt+=("$t")
    fi
    if [[ "$mode" != clean ]]; then
        sort_opts
        fi_n=$((fi_n + 1))
        $use_counts && { stages+=("_st_count $fi_n"); names+=(tee); }
        stages+=(_st_sortu); names+=(sort)
        if (( SORT_MEM_KB > 0 )); then
            L t "сортировка (память до $(fmt_size $(( SORT_MEM_KB * 1024 ))))" "sort (memory up to $(fmt_size $(( SORT_MEM_KB * 1024 ))))"; steps+=("$t")
        else
            L t "сортировка" "sort"; steps+=("$t")
        fi
        L t "повторы внутри файла" "duplicates within the file"; filt+=("$t")
        for k in "${!P_REFS[@]}"; do
            fi_n=$((fi_n + 1))
            $use_counts && { stages+=("_st_count $fi_n"); names+=(tee); }
            stages+=("_st_comm $k"); names+=(comm)
            L t "эталон ${P_REFS[k]##*/}" "reference ${P_REFS[k]##*/}"; steps+=("$t")
            L t "есть в эталоне ${P_REFS[k]##*/} (поколение ${gen_no[k]})" "in reference ${P_REFS[k]##*/} (generation ${gen_no[k]})"; filt+=("$t")
        done
    fi
    if [[ -n "${DEDUP_TEST_FAIL_PASS:-}" && "${input##*/}" == "$DEDUP_TEST_FAIL_PASS" ]]; then
        stages+=(_st_testfail); names+=(тест)
    fi
    local line s lshort j_s j_n=$(( ${#steps[@]} - ${#P_REFS[@]} ))
    L line "Шаги:" "Steps:"
    lshort="$line"
    for j_s in "${!steps[@]}"; do
        s="${steps[j_s]}"
        line+=" ${s} →"
        (( j_s < j_n )) && lshort+=" ${s} →"
    done
    if [[ "$mode" == clean ]]; then
        say "${BLUE}${line} ${output}${NC}"
    elif (( ${#P_REFS[@]} > 3 )); then
        L t "эталоны: ${#P_REFS[@]}" "references: ${#P_REFS[@]}"
        out "${BLUE}${lshort} ${t} → ${final}${NC}"
        log_line "${line} ${final}"
    else
        say "${BLUE}${line} ${final}${NC}"
    fi

    if $use_counts; then
        for (( k = 1; k <= nf; k++ )); do
            wc -l < "${P_FIFO[k]}" > "$fdir/c$k" &
            pids+=($!)
        done
        if $save_short; then
            if [[ -n "$UTF8_LOCALE" ]]; then
                LC_ALL="$UTF8_LOCALE" grep -aE "^.{1,$((min - 1))}\$" < "${P_SAVE[1]}" > "${save_tmp[1]}" &
            else
                grep -aE "^.{1,$((min - 1))}\$" < "${P_SAVE[1]}" > "${save_tmp[1]}" &
            fi
            pids+=($!)
        fi
        if $save_dig; then
            LC_ALL=C grep -aE "$dig_re" < "${P_SAVE[2]}" > "${save_tmp[2]}" &
            pids+=($!)
        fi
        if $save_bad; then
            LC_ALL="$UTF8_LOCALE" grep -a -v -x '.*' < "${P_SAVE[3]}" > "${save_tmp[3]}" &
            pids+=($!)
        fi
        COUNTER_PIDS=("${pids[@]}")
    fi

    local P_ENC="$enc" P_MIN="$min" P_MAX="$max" P_DIG_RE="$dig_re" P_NUL_RE="$nul_re" P_IN="$input" P_OUT="$output"
    local P_TMP="."
    local pl="${stages[0]} < \"\$P_IN\"" t0
    for (( k = 1; k < ${#stages[@]}; k++ )); do pl+=" | ${stages[k]}"; done
    pl+=" > \"\$P_OUT\""
    local -a st=()
    IN_PROGRESS=("$output" "${save_tmp[@]}")
    ms_now; t0=$REPLY
    L t проход pass
    progress_start "$t" "$(file_size "$input")" read "$input"
    eval "$pl"'; st=("${PIPESTATUS[@]}")'
    progress_stop
    (( ${#pids[@]} > 0 )) && wait "${pids[@]}" 2>/dev/null
    COUNTER_PIDS=()
    ms_now

    local bad="" dropped=false
    for k in "${!st[@]}"; do
        case "${names[k]}" in
            iconv) if (( st[k] == 1 )); then dropped=true; elif (( st[k] != 0 )); then bad+=" iconv (${w_code} ${st[k]})"; fi ;;
            grep)  (( st[k] >= 2 )) && bad+=" grep (${w_code} ${st[k]})" ;;
            *)     (( st[k] != 0 )) && bad+=" ${names[k]} (${w_code} ${st[k]})" ;;
        esac
    done
    if [[ -n "$bad" ]]; then
        rm -f -- "$output"
        for k in "${!save_tmp[@]}"; do rm -f -- "${save_tmp[k]}"; done
        IN_PROGRESS=()
        [[ -n "$fdir" ]] && rm -rf -- "$fdir"
        TMP_DIRS=()
        if [[ "$mode" == clean ]]; then
            say "${RED}✘ Ошибка подготовки:${bad} — ${output} удалён, исходный файл не тронут${NC}" "${RED}✘ Preparation error:${bad} — ${output} deleted, the source file is untouched${NC}" >&2
        else
            say "${RED}✘ Ошибка прохода:${bad} — итог ${final} не создан, исходный файл не тронут${NC}" "${RED}✘ Pass error:${bad} — the result ${final} is not created, the source file is untouched${NC}" >&2
        fi
        return 1
    fi
    [[ "$mode" == clean ]] && IN_PROGRESS=("${save_tmp[@]}")
    $dropped && say "${YELLOW}⚠ iconv выбросил несконвертируемые байты — остальное сконвертировано${NC}" "${YELLOW}⚠ iconv dropped unconvertible bytes — the rest is converted${NC}"

    local n_out dt=$(( REPLY - t0 )) nul_line="" feff_line="" moji_line="" mix_line="" cr_line=""
    local -a cnt=()
    n_out=$(wc -l < "$output")
    $do_nul && L nul_line "  ↻ слова из UTF-16 восстановлены (убраны NUL): $(fmt_num "$nul_word")" "  ↻ words from UTF-16 restored (NUL removed): $(fmt_num "$nul_word")"
    $do_mix && L mix_line "  ↻ строки не в UTF-8 перекодированы из ${mix_enc}: $(fmt_num "$mix_all")" "  ↻ lines not in UTF-8 converted from ${mix_enc}: $(fmt_num "$mix_all")"
    $do_crsplit && L cr_line "  ↻ строки с CR внутри разбиты: $(fmt_num "$cr_mid")" "  ↻ lines with a CR inside split: $(fmt_num "$cr_mid")"
    [[ -z "$enc" ]] && $do_strip && (( feff_mid > 0 )) && L feff_line "  ↻ невидимый U+FEFF убран из строк: $(fmt_num "$feff_mid")" "  ↻ invisible U+FEFF removed from lines: $(fmt_num "$feff_mid")"
    if [[ -z "$enc" ]] && $do_moji; then
        local mk="" kinds=0
        (( moji_all > 0 )) && { L t ", UTF-8 как Windows-1252 — $(fmt_num "$moji_all")" ", UTF-8 as Windows-1252: $(fmt_num "$moji_all")"; mk+="$t"; kinds=$((kinds + 1)); }
        (( dos_all > 0 )) && { L t ", DOS — $(fmt_num "$dos_all")" ", DOS: $(fmt_num "$dos_all")"; mk+="$t"; kinds=$((kinds + 1)); }
        (( u8_all > 0 )) && { L t ", UTF-8 как Windows-1251 — $(fmt_num "$u8_all")" ", UTF-8 as Windows-1251: $(fmt_num "$u8_all")"; mk+="$t"; kinds=$((kinds + 1)); }
        (( koi_all > 0 )) && { L t ", KOI8-R как Windows-1251 — $(fmt_num "$koi_all")" ", KOI8-R as Windows-1251: $(fmt_num "$koi_all")"; mk+="$t"; kinds=$((kinds + 1)); }
        (( s7_all > 0 )) && { L t ", CP866 без старшего бита — $(fmt_num "$s7_all")" ", CP866 without the high bit: $(fmt_num "$s7_all")"; mk+="$t"; kinds=$((kinds + 2)); }
        L moji_line "  ↻ кракозябры восстановлены: $(fmt_num $(( moji_all + dos_all + u8_all + koi_all + s7_all )))" "  ↻ mojibake restored: $(fmt_num $(( moji_all + dos_all + u8_all + koi_all + s7_all )))"
        (( kinds > 1 )) && moji_line+=" (${mk#, })"
    fi
    if $use_counts; then
        for (( k = 1; k <= nf; k++ )); do
            read -r cnt[k] < "$fdir/c$k" 2>/dev/null
            cnt[k]=$(( 10#${cnt[k]:-0} ))
        done
        cnt[nf + 1]=$n_out
        say "Строк на входе: $(fmt_num "${cnt[1]}")" "Input lines: $(fmt_num "${cnt[1]}")"
        [[ -n "$mix_line" ]] && say "$mix_line"
        [[ -n "$feff_line" ]] && say "$feff_line"
        [[ -n "$moji_line" ]] && say "$moji_line"
        [[ -n "$cr_line" ]] && say "$cr_line"
        [[ -n "$nul_line" ]] && say "$nul_line"
        for (( k = 1; k <= nf; k++ )); do
            say "  − ${filt[k-1]}: $(fmt_num $(( cnt[k] - cnt[k + 1] )))"
        done
        if [[ "$mode" != clean ]]; then
            local j0=$(( nf - ${#P_REFS[@]} ))
            for k in "${!P_REFS[@]}"; do
                PREP_REF_HITS[k]=$(( cnt[j0 + k + 1] - cnt[j0 + k + 2] ))
            done
        fi
    else
        (( nf == 0 )) && say "Строк: $(fmt_num "$n_out") (строки не убирались)" "Lines: $(fmt_num "$n_out") (no lines removed)"
        [[ -n "$mix_line" ]] && say "$mix_line"
        [[ -n "$feff_line" ]] && say "$feff_line"
        [[ -n "$moji_line" ]] && say "$moji_line"
        [[ -n "$cr_line" ]] && say "$cr_line"
        [[ -n "$nul_line" ]] && say "$nul_line"
    fi
    [[ -n "$fdir" ]] && rm -rf -- "$fdir"
    TMP_DIRS=()
    if (( ${#save_tmp[@]} > 0 )); then
        local sbase sname suf what n_s
        local -a keep=()
        [[ "$mode" != clean ]] && keep=("$output")
        sbase="$(final_base "$input")"
        sort_opts
        for k in "${!save_tmp[@]}"; do
            if (( k == 1 )); then suf=short; L what "строки короче ${min}" "lines shorter than ${min}"
            elif (( k == 2 )); then suf=digits; L what "строки из цифр (${dig_name})" "digit lines (${dig_name})"
            else suf=notutf8; L what "строки не в UTF-8" "lines not in UTF-8"; fi
            if [[ ! -s "${save_tmp[k]}" ]]; then
                say "  ⤷ ${what}: таких не было — файл не создан" "  ⤷ ${what}: none — no file created"
                rm -f -- "${save_tmp[k]}"
                unset 'save_tmp[k]'
                continue
            fi
            free_name "$sbase" "$suf"
            sname="$REPLY"
            IN_PROGRESS=("${keep[@]}" "${save_tmp[@]}" "$sname")
            if (( k == 3 )); then
                chmod --reference="$input" "${save_tmp[k]}" 2>/dev/null
                if mv -f -- "${save_tmp[k]}" "$sname"; then
                    n_s=$(wc -l < "$sname")
                    RESULT_FILES+=("$sname")
                    say "  ⤷ ${what} — в ${sname}: $(fmt_num "$n_s") (как есть)" "  ⤷ ${what} to ${sname}: $(fmt_num "$n_s") (as they are)"
                else
                    rm -f -- "$sname"
                    say "${YELLOW}⚠ Не удалось сохранить ${what} в ${sname} — итог от этого не пострадал${NC}" "${YELLOW}⚠ Could not save ${what} to ${sname} — the result is not affected${NC}"
                fi
                rm -f -- "${save_tmp[k]}"
                unset 'save_tmp[k]'
                continue
            fi
            if LC_ALL=C sort -u -T . "${SORT_OPTS[@]}" -o "$sname" -- "${save_tmp[k]}"; then
                n_s=$(wc -l < "$sname")
                RESULT_FILES+=("$sname")
                say "  ⤷ ${what} — в ${sname}: $(fmt_num "$n_s") (без повторов)" "  ⤷ ${what} to ${sname}: $(fmt_num "$n_s") (without duplicates)"
            else
                rm -f -- "$sname"
                say "${YELLOW}⚠ Не удалось сохранить ${what} в ${sname} — итог от этого не пострадал${NC}" "${YELLOW}⚠ Could not save ${what} to ${sname} — the result is not affected${NC}"
            fi
            rm -f -- "${save_tmp[k]}"
            unset 'save_tmp[k]'
        done
        IN_PROGRESS=("${keep[@]}")
    fi
    if [[ "$mode" == clean ]]; then
        say "${GREEN}✔ Осталось строк: $(fmt_num "$n_out") → ${output} ($(fmt_size "$(file_size "$output")"), $(fmt_dur "$dt"))${NC}" "${GREEN}✔ Lines left: $(fmt_num "$n_out") → ${output} ($(fmt_size "$(file_size "$output")"), $(fmt_dur "$dt"))${NC}"
        size_note "$input" "$output"
        PREP_RESULT="$output"
        return 0
    fi
    local skipped_note="" skipped=$(( ${#CMP_REFS[@]} - ${#P_REFS[@]} ))
    (( skipped > 0 )) && L skipped_note ", пропущено: ${skipped}" ", skipped: ${skipped}"
    say "▐► ${YELLOW}Обработано поколений: ${#P_REFS[@]} из ${#CMP_REFS[@]}${skipped_note}${NC}" "▐► ${YELLOW}Generations processed: ${#P_REFS[@]} of ${#CMP_REFS[@]}${skipped_note}${NC}"
    chmod --reference="$input" "$output" 2>/dev/null
    IN_PROGRESS=("$output")
    L t "не удалось сохранить итог ${final}" "could not save the result ${final}"
    if ! must_run "$t" mv -f -- "$output" "$final"; then
        rm -f -- "$output"
        IN_PROGRESS=()
        return 1
    fi
    IN_PROGRESS=()
    RESULT_FILES+=("$final")
    say "${GREEN}✔ Финальный файл: ${final} — строк: $(fmt_num "$n_out"), $(fmt_size "$(file_size "$final")") ($(fmt_dur "$dt"))${NC}" "${GREEN}✔ Final file: ${final} — lines: $(fmt_num "$n_out"), $(fmt_size "$(file_size "$final")") ($(fmt_dur "$dt"))${NC}"
    size_note "$input" "$final"
    check_edge_blanks "$final" "$n_out"
    PREP_RESULT="$final"
}

_st_sortu() { LC_ALL=C sort -u -T "$P_TMP" "${SORT_OPTS[@]}"; }
_st_comm() { LC_ALL=C comm -13 -- "${P_REFS[$1]}" -; }
_st_testfail() { cat > /dev/null; return 3; }

# Item 1: full processing.
cmd_full() {
    local input="$1"
    say "${CYAN}${SCRIPT_NAME} v${VERSION} — полная обработка: ${input} ($(fmt_size "$(file_size "$input")"))${NC}" "${CYAN}${SCRIPT_NAME} v${VERSION} — full processing: ${input} ($(fmt_size "$(file_size "$input")"))${NC}"
    prep_file "$input" full
}

# Item 2: preparation only.
cmd_clean() {
    local input="$1"
    say "${CYAN}${SCRIPT_NAME} v${VERSION} — подготовка: ${input} ($(fmt_size "$(file_size "$input")"))${NC}" "${CYAN}${SCRIPT_NAME} v${VERSION} — preparation: ${input} ($(fmt_size "$(file_size "$input")"))${NC}"
    prep_file "$input" || return 1
    if [[ "$PREP_RESULT" == "$input" ]]; then
        say "${BLUE}Файл не изменён: подготовка не понадобилась${NC}" "${BLUE}The file is unchanged: no preparation was needed${NC}"
    else
        RESULT_FILES+=("$PREP_RESULT")
        say "\n${GREEN}=== Готово ===${NC}" "\n${GREEN}=== Done ===${NC}"
        say "Результат: ${PREP_RESULT}" "Result: ${PREP_RESULT}"
    fi
}

declare -a CMP_REFS=() CMP_SKIP=()
# References from Compare Files (and earlier queue results) into CMP_REFS.
prepare_refs() {
    local k f result prc
    CMP_REFS=(); CMP_SKIP=()
    say "\n${YELLOW}Эталоны...${NC}" "\n${YELLOW}References...${NC}"
    if $QUEUE_ON && $QUEUE_REFS_READY; then
        CMP_REFS=("${QUEUE_REFS[@]}")
        for k in "${!QUEUE_REF_SKIP[@]}"; do CMP_SKIP[k]="${QUEUE_REF_SKIP[k]}"; done
        (( ${#CMP_REFS[@]} > 0 )) && say "${GREEN}✓ Эталонов в '$COMPARE_DIR': ${#CMP_REFS[@]} — проверены у первого файла очереди${NC}" "${GREEN}✓ References in '$COMPARE_DIR': ${#CMP_REFS[@]} — checked at the first file of the queue${NC}"
    else
        if [[ -d "$COMPARE_DIR" ]]; then
            shopt -s nullglob
            CMP_REFS=("$COMPARE_DIR"/*.txt)
            shopt -u nullglob
        elif ! $QUEUE_ON; then
            say "${RED}✘ Папка '$COMPARE_DIR' не найдена${NC}" "${RED}✘ Folder '$COMPARE_DIR' not found${NC}" >&2
            return 1
        fi
        if (( ${#CMP_REFS[@]} == 0 )); then
            if ! $QUEUE_ON; then
                say "${RED}✘ Нет .txt файлов в '$COMPARE_DIR'${NC}" "${RED}✘ No .txt files in '$COMPARE_DIR'${NC}" >&2
                return 1
            fi
            say "${BLUE}Эталонов в '$COMPARE_DIR' нет — файлы очереди чистятся только друг от друга${NC}" "${BLUE}No references in '$COMPARE_DIR' — the queue files are cleaned only of each other${NC}"
        else
            mapfile -t CMP_REFS < <(printf '%s\n' "${CMP_REFS[@]}" | sort -V)
            say "${GREEN}✓ Найдено эталонных файлов: ${#CMP_REFS[@]}${NC}" "${GREEN}✓ Reference files found: ${#CMP_REFS[@]}${NC}"
            for k in "${!CMP_REFS[@]}"; do
                f="${CMP_REFS[k]}"
                result="$(process_file "$f" "Эталон")"; prc=$?
                if (( prc == 0 )) && [[ -n "$result" ]]; then
                    CMP_REFS[k]="$result"
                elif (( prc == 2 )); then
                    CMP_SKIP[k]=unsorted
                    say "${YELLOW}⚠ Эталон ${f##*/} не отсортирован — поколение пропущено (№ $((k + 1)))${NC}" "${YELLOW}⚠ Reference ${f##*/} is not sorted — generation skipped (#$((k + 1)))${NC}" >&2
                else
                    CMP_SKIP[k]=error
                    say "${RED}⚠ Эталон ${f##*/} не обработан (ошибка выше) — поколение пропущено (№ $((k + 1)))${NC}" "${RED}⚠ Reference ${f##*/} not processed (error above) — generation skipped (#$((k + 1)))${NC}" >&2
                fi
            done
        fi
        if $QUEUE_ON; then
            QUEUE_REFS=("${CMP_REFS[@]}")
            QUEUE_REF_SKIP=()
            for k in "${!CMP_SKIP[@]}"; do QUEUE_REF_SKIP[k]="${CMP_SKIP[k]}"; done
            QUEUE_REFS_READY=true
        fi
        for f in "$UNSORTED_DIR" "${COMPARE_DIR}/${UNSORTED_DIR}"; do
            [[ -d "$f" ]] && [[ -z "$(ls -A "$f" 2>/dev/null)" ]] && rmdir "$f"
        done
    fi
    if (( ${#EXTRA_REFS[@]} > 0 )); then
        CMP_REFS+=("${EXTRA_REFS[@]}")
        if (( ${#EXTRA_REFS[@]} > 3 )); then
            out "${GREEN}✓ И итоги предыдущих файлов очереди: ${#EXTRA_REFS[@]}${NC}" "${GREEN}✓ Plus the results of the previous queue files: ${#EXTRA_REFS[@]}${NC}"
            local t
            L t "✓ И итоги предыдущих файлов очереди: ${EXTRA_REFS[*]##*/}" "✓ Plus the results of the previous queue files: ${EXTRA_REFS[*]##*/}"
            log_line "$t"
        else
            say "${GREEN}✓ И итоги предыдущих файлов очереди: ${EXTRA_REFS[*]##*/}${NC}" "${GREEN}✓ Plus the results of the previous queue files: ${EXTRA_REFS[*]##*/}${NC}"
        fi
    fi
    return 0
}

# Item 3: comparison with references only.
cmd_compare() {
    local -a WORK=("$@")
    local f made=0 rc=0
    say "${CYAN}${SCRIPT_NAME} v${VERSION} — сравнение с эталонами и удаление дублей${NC}" "${CYAN}${SCRIPT_NAME} v${VERSION} — comparison with references and duplicate removal${NC}"
    prepare_refs || return 1
    if (( ${#WORK[@]} == 0 )); then
        work_txt
        WORK=("${WORK_TXT[@]}")
        ACTION_FILES=("${WORK[@]}")
    fi
    if (( ${#WORK[@]} == 0 )); then
        say "${RED}✘ Нет .txt файлов для обработки в текущей папке${NC}" "${RED}✘ No .txt files to process in the current folder${NC}" >&2
        return 1
    fi
    for f in "${WORK[@]}"; do
        say "\n${BLUE}▬▬▬ ${f} ($(fmt_size "$(file_size "$f")")) ▬▬▬${NC}"
        if prep_file "$f" compare; then
            made=$((made + 1))
        else
            rc=1
            say "${RED}✘ ${f} пропущен — ошибка (см. выше)${NC}" "${RED}✘ ${f} skipped — error (see above)${NC}" >&2
        fi
    done
    if (( made == 0 )); then
        say "${RED}✘ Ни одного итогового файла (см. выше)${NC}" "${RED}✘ No result files at all (see above)${NC}" >&2
        return 1
    fi
    return "$rc"
}

# Item 4: dictionaries in a queue; each result is a reference for the next files.
cmd_queue() {
    local -a files=("$@") done_f=() done_fin=() done_n=() done_in=() done_hit=()
    local i n=${#files[@]} f fin before k j in_n rc=0 hit hits nh one t
    say "${CYAN}${SCRIPT_NAME} v${VERSION} — несколько словарей по очереди: ${n}${NC}" "${CYAN}${SCRIPT_NAME} v${VERSION} — several dictionaries in a queue: ${n}${NC}"
    say "Каждый файл чистится от эталонов и от итогов всех предыдущих: первый останется" "Each file is cleaned of the references and of the results of all previous files: the first stays"
    say "целым, в следующих не будет строк, которые уже были раньше. Порядок:" "whole, the next ones will not have lines that came earlier. Order:"
    for i in "${!files[@]}"; do say "  ${GREEN}$((i + 1)).${NC} ${files[i]} ($(fmt_size "$(file_size "${files[i]}")"))"; done
    QUEUE_ON=true
    MEMO_ON=true
    for i in "${!files[@]}"; do
        f="${files[i]}"
        for k in "${!MEMO_NEW[@]}"; do MEMO[$k]="${MEMO_NEW[$k]}"; done
        MEMO_NEW=()
        say "\n${CYAN}════ Очередь: файл $((i + 1)) из ${n} — ${f} ════${NC}" "\n${CYAN}════ Queue: file $((i + 1)) of ${n} — ${f} ════${NC}"
        (( i > 0 )) && say "${BLUE}Вопросы, на которые уже ответили в этой очереди, не повторяются: берётся тот же ответ${NC}" "${BLUE}Questions already answered in this queue are not asked again: the same answer is used${NC}"
        before=${#RESULT_FILES[@]}
        in_n=$(wc -l < "$f")
        prep_file "$f" full
        if (( ${#RESULT_FILES[@]} == before )); then
            say "\n${RED}✘ Очередь остановлена на файле $((i + 1)), ${f}: без его итога следующие нельзя очистить от его строк${NC}" "\n${RED}✘ The queue stopped at file $((i + 1)), ${f}: without its result the next ones cannot be cleaned of its lines${NC}" >&2
            (( i + 1 < n )) && say "${YELLOW}  Не обработаны: ${files[*]:i+1}${NC}" "${YELLOW}  Not processed: ${files[*]:i+1}${NC}" >&2
            rc=1
            break
        fi
        fin="${RESULT_FILES[${#RESULT_FILES[@]}-1]}"
        hit=""; hits=0; nh=0
        for j in "${!PREP_REF_NAMES[@]}"; do
            (( ${PREP_REF_HITS[j]:-0} > 0 )) || continue
            hits=$(( hits + PREP_REF_HITS[j] )); nh=$(( nh + 1 ))
            one="${PREP_REF_NAMES[j]##*/}"
            for k in "${!done_fin[@]}"; do
                [[ "${done_fin[k]}" == "${PREP_REF_NAMES[j]}" ]] && L one "итоге файла $((k + 1))" "the result of file $((k + 1))"
            done
            L t "в ${one} — $(fmt_num "${PREP_REF_HITS[j]}")" "in ${one}: $(fmt_num "${PREP_REF_HITS[j]}")"
            hit+="${hit:+$'\n'}$t"
        done
        if (( ${#PREP_REF_HITS[@]} == ${#PREP_REF_NAMES[@]} && hits < in_n )); then
            L t "убрала подготовка (повторы, фильтры) — $(fmt_num $(( in_n - hits )))" "removed by preparation (duplicates, filters): $(fmt_num $(( in_n - hits )))"
            hit+="${hit:+$'\n'}$t"
        fi
        EXTRA_REFS+=("$fin")
        done_f+=("$f"); done_fin+=("$fin"); done_n+=("$(wc -l < "$fin")"); done_in+=("$in_n"); done_hit+=("$hit")
    done
    MEMO_ON=false
    (( ${#done_f[@]} > 0 )) || return "$rc"
    say "\n${GREEN}════ Очередь: итоги ════${NC}" "\n${GREEN}════ Queue: results ════${NC}"
    for i in "${!done_f[@]}"; do
        if (( done_n[i] == 0 )); then
            say "  ${YELLOW}$((i + 1)). ${done_fin[i]}: пусто, на входе строк $(fmt_num "${done_in[i]}")${NC}" "  ${YELLOW}$((i + 1)). ${done_fin[i]}: empty, input lines: $(fmt_num "${done_in[i]}")${NC}"
            if [[ -n "${done_hit[i]}" ]]; then
                while IFS= read -r hit; do say "       ${hit}"; done <<< "${done_hit[i]}"
            else
                say "       все строки уже есть в эталонах или в предыдущих файлах" "       all lines are already in the references or previous files"
            fi
        else
            say "  ${GREEN}$((i + 1)).${NC} ${GREEN}${done_fin[i]}${NC}: строк $(fmt_num "${done_n[i]}") из $(fmt_num "${done_in[i]}"), $(fmt_size "$(file_size "${done_fin[i]}")")" "  ${GREEN}$((i + 1)).${NC} ${GREEN}${done_fin[i]}${NC}: lines $(fmt_num "${done_n[i]}") of $(fmt_num "${done_in[i]}"), $(fmt_size "$(file_size "${done_fin[i]}")")"
        fi
    done
    if (( rc == 0 )); then
        if (( ${#QUEUE_REF_SKIP[@]} > 0 )); then
            say "${YELLOW}⚠ Были пропущенные эталоны (см. выше): с ними итоги могут пересекаться${NC}" "${YELLOW}⚠ Some references were skipped (see above): the results may overlap with them${NC}"
        else
            say "${GREEN}✔ Строки в этих итогах не повторяются ни между собой, ни с эталонами${NC}" "${GREEN}✔ No line repeats across these results or with the references${NC}"
        fi
    fi
    return "$rc"
}

# After a queue: move the source dictionaries to originals_<date-time>/.
move_originals() {
    local stamp dir n=2 f moved=0 t
    local -a mine=()
    for f in "$@"; do
        [[ -f "$f" && "$(cd "$(dirname -- "$f")" && pwd -P)" == "$(pwd -P)" ]] && mine+=("$f")
    done
    (( ${#mine[@]} > 0 )) || return 0
    printf -v stamp '%(%Y%m%d-%H%M%S)T' -1
    dir="originals_${stamp}"
    while [[ -e "$dir" ]]; do dir="originals_${stamp}_${n}"; n=$((n + 1)); done
    L t "не удалось создать папку ${dir} — исходные словари остались на месте" "could not create the folder ${dir} — the source dictionaries stay in place"
    must_run "$t" mkdir -- "$dir" || return 1
    for f in "${mine[@]}"; do
        if mv -- "$f" "$dir/"; then
            moved=$((moved + 1))
        else
            say "${YELLOW}⚠ ${f} не перенесён в ${dir}/ — остался на месте${NC}" "${YELLOW}⚠ ${f} was not moved to ${dir}/ — it stays in place${NC}" >&2
        fi
    done
    say "${GREEN}✔ Исходные словари (${moved}) перенесены в папку ${dir}/ — в рабочей папке остались итоги${NC}" "${GREEN}✔ The source dictionaries (${moved}) moved to the folder ${dir}/ — the results stay in the working folder${NC}"
}

# Item 5: merge results into merged.txt without duplicates, plus merged_list.txt.
cmd_merge() {
    local -a files=("$@")
    local f k n=2 out list total=0 n_out tmp t0 rc sorted=true t
    say "${CYAN}${SCRIPT_NAME} v${VERSION} — объединение файлов: ${#files[@]}${NC}" "${CYAN}${SCRIPT_NAME} v${VERSION} — merging files: ${#files[@]}${NC}"
    out="merged.txt"; list="merged_list.txt"
    while [[ -e "$out" || -e "$list" ]] || { [[ -n "$FINAL_DIR" ]] && [[ -e "$FINAL_DIR/$out" || -e "$FINAL_DIR/$list" ]]; }; do
        out="merged_${n}.txt"; list="merged_${n}_list.txt"; n=$((n + 1))
    done
    for f in "${files[@]}"; do
        k=$(wc -l < "$f")
        total=$((total + k))
        say "  ${f}: строк $(fmt_num "$k"), $(fmt_size "$(file_size "$f")")" "  ${f}: lines $(fmt_num "$k"), $(fmt_size "$(file_size "$f")")"
        LC_ALL=C sort -c -- "$f" 2>/dev/null || sorted=false
    done
    tmp="$(mktemp ./.dedup_tool.XXXXXX)" || { say "${RED}✘ Не удалось создать временный файл — ничего не создано${NC}" "${RED}✘ Could not create a temporary file — nothing created${NC}" >&2; return 1; }
    IN_PROGRESS=("$tmp")
    ms_now; t0=$REPLY
    local in_bytes=0
    for f in "${files[@]}"; do in_bytes=$(( in_bytes + $(file_size "$f") )); done
    if $sorted; then
        say "Все файлы отсортированы — слияние за один проход (sort -m)" "All files are sorted — merging in one pass (sort -m)"
        L t слияние merging
        progress_start "$t" "$in_bytes" read "${files[@]}"
        LC_ALL=C sort -m -u -T . -- "${files[@]}" > "$tmp"; rc=$?
    else
        say "Не все файлы отсортированы — общая сортировка (sort -u)" "Not all files are sorted — sorting them together (sort -u)"
        sort_opts
        L t сортировка sorting
        progress_start "$t" "$in_bytes" read "${files[@]}"
        LC_ALL=C sort -u -T . "${SORT_OPTS[@]}" -- "${files[@]}" > "$tmp"; rc=$?
    fi
    progress_stop
    if (( rc != 0 )); then
        rm -f -- "$tmp"
        IN_PROGRESS=()
        say "${RED}✘ Ошибка sort (код ${rc}) — ничего не создано${NC}" "${RED}✘ sort error (code ${rc}) — nothing created${NC}" >&2
        return 1
    fi
    chmod --reference="${files[0]}" "$tmp" 2>/dev/null
    L t "не удалось сохранить ${out}" "could not save ${out}"
    if ! must_run "$t" mv -- "$tmp" "$out"; then
        rm -f -- "$tmp"
        IN_PROGRESS=()
        return 1
    fi
    ms_now
    n_out=$(wc -l < "$out")
    RESULT_FILES+=("$out")
    IN_PROGRESS=("$list")
    if ! printf '%s\n' "${files[@]}" > "$list"; then
        rm -f -- "$list"
        IN_PROGRESS=()
        say "${RED}✘ Не удалось записать ${list} (${out} создан)${NC}" "${RED}✘ Could not write ${list} (${out} is created)${NC}" >&2
        return 1
    fi
    IN_PROGRESS=()
    RESULT_FILES+=("$list")
    say "${GREEN}✔ Объединённый файл: ${out} — строк $(fmt_num "$n_out"), $(fmt_size "$(file_size "$out")") ($(fmt_dur $(( REPLY - t0 ))))${NC}" "${GREEN}✔ Merged file: ${out} — lines $(fmt_num "$n_out"), $(fmt_size "$(file_size "$out")") ($(fmt_dur $(( REPLY - t0 ))))${NC}"
    if (( total > n_out )); then
        say "  Повторов убрано: $(fmt_num $(( total - n_out ))) — в ${out} каждая строка один раз" "  Duplicates removed: $(fmt_num $(( total - n_out ))) — every line is in ${out} once"
    else
        say "  Повторов между файлами нет" "  No duplicates between the files"
    fi
    say "${GREEN}✔ Список файлов: ${list}${NC}" "${GREEN}✔ List of files: ${list}${NC}"
}

# Item 6: split a file into N parts or into parts of a given size.
cmd_split() {
    local file="$1" spec="${2:-$DEFAULT_SPLIT_SIZE}" n_est bytes dir base k=2 digits t0 t
    local -a opt=()
    spec="${spec^^}"
    spec="${spec// /}"
    say "${CYAN}${SCRIPT_NAME} v${VERSION} — деление: ${file} ($(fmt_size "$(file_size "$file")"))${NC}" "${CYAN}${SCRIPT_NAME} v${VERSION} — split: ${file} ($(fmt_size "$(file_size "$file")"))${NC}"
    if [[ "$spec" =~ ^[0-9]+$ ]]; then
        n_est=$((10#$spec))
        if (( n_est < 2 || n_est > 1000 )); then
            say "${RED}✘ Частей должно быть от 2 до 1000, а не $spec${NC}" "${RED}✘ The number of parts must be 2 to 1000, not $spec${NC}" >&2
            return 1
        fi
        opt=(-n "l/$n_est" -e)
    elif [[ "$spec" =~ ^([0-9]+)([KMGT])$ ]]; then
        case "${BASH_REMATCH[2]}" in
            K) bytes=1024 ;; M) bytes=1048576 ;; G) bytes=1073741824 ;; T) bytes=1099511627776 ;;
        esac
        bytes=$(( 10#${BASH_REMATCH[1]} * bytes ))
        if (( bytes == 0 )); then
            say "${RED}✘ Размер части не может быть нулевым${NC}" "${RED}✘ The part size cannot be zero${NC}" >&2
            return 1
        fi
        n_est=$(( ($(file_size "$file") + bytes - 1) / bytes ))
        if (( n_est < 2 )); then
            say "${BLUE}Файл не больше ${spec} — делить нечего${NC}" "${BLUE}The file is not bigger than ${spec} — nothing to split${NC}"
            return 0
        fi
        opt=(-C "$spec")
    else
        say "${RED}✘ Не понял «$2»: нужно число частей (например 4) или размер части (500M, 2G)${NC}" "${RED}✘ Cannot understand “$2”: type a number of parts (for example 4) or a part size (500M, 2G)${NC}" >&2
        return 1
    fi
    digits=${#n_est}
    (( digits < 2 )) && digits=2
    base="$(basename "${file%.*}")"
    dir="$(dirname "$file")"
    [[ "$dir" == "." ]] && dir="" || dir+="/"
    dir+="${base}_parts"
    local try="$dir"
    while [[ -e "$try" ]]; do try="${dir}_${k}"; k=$((k + 1)); done
    dir="$try"
    L t "не удалось создать папку $dir" "could not create the folder $dir"
    must_run "$t" mkdir -p "$dir" || return 1
    TMP_DIRS=("$dir")
    ms_now; t0=$REPLY
    if ! split "${opt[@]}" -a "$digits" --numeric-suffixes=1 --additional-suffix=.txt -- "$file" "$dir/${base}_part"; then
        rm -rf -- "$dir"
        TMP_DIRS=()
        say "${RED}✘ Ошибка split — части удалены${NC}" "${RED}✘ split error — the parts are deleted${NC}" >&2
        return 1
    fi
    TMP_DIRS=()
    ms_now
    local -a parts=()
    shopt -s nullglob
    parts=("$dir"/*.txt)
    shopt -u nullglob
    say "${GREEN}✔ Частей: ${#parts[@]} в папке ${dir}/ ($(fmt_dur $(( REPLY - t0 ))))${NC}" "${GREEN}✔ Parts: ${#parts[@]} in the folder ${dir}/ ($(fmt_dur $(( REPLY - t0 ))))${NC}"
    local p
    for p in "${parts[@]}"; do
        say " - ${p##*/}: строк $(fmt_num "$(wc -l < "$p")"), $(fmt_size "$(file_size "$p")")" " - ${p##*/}: lines $(fmt_num "$(wc -l < "$p")"), $(fmt_size "$(file_size "$p")")"
    done
    RESULT_FILES+=("$dir")
}

TOOL_SUB=""; TOOL_INPUT=""; TOOL_BASE=""; TOOL_STRIP=false; TOOL_SEP=""; TOOL_SEP_RE=""
TOOL_LAYOUT_SEL=""; TOOL_CASE_SED=""; TOOL_ALPHA_PREF=""; TOOL_LAST=""; TAB_CHR=$'\t'
declare -a TOOL_OPTS=() TOOL_SED=() TOOL_PAT=() TOOL_FILES=() TOOL_REST_KINDS=() TOOL_DICTS=() TOOL_FIFO=()
TOOL_FOUND=false; TOOL_TOP_HEAD=""; TOOL_TOP_STAT=""
TOOL_EMAIL_RE=$'[[:alnum:]._%+\x80-\xff-]+@[[:alnum:].\x80-\xff-]+\\.[[:alpha:]\x80-\xff]{2,}'
TOOL_URL_RE=$'(https?|ftp)://[^[:space:]"\'<>:]+(:[0-9]+[^[:space:]"\'<>:]*)?|www\\.[^[:space:]"\'<>:]+'
TOOL_IP_RE='(?<![0-9.])(?:(?:25[0-5]|2[0-4][0-9]|1?[0-9]?[0-9])\.){3}(?:25[0-5]|2[0-4][0-9]|1?[0-9]?[0-9])(?!\.?[0-9])'

# Temporary file next to the result; the name goes to REPLY.
tool_tmp() {
    if ! REPLY="$(mktemp "./.dedup_tool.XXXXXX" 2>/dev/null)"; then
        say "${RED}✘ Не удалось создать временный файл в этой папке${NC}" "${RED}✘ Could not create a temporary file in this folder${NC}" >&2
        return 1
    fi
    IN_PROGRESS+=("$REPLY")
}
tool_release() {
    local x y keep
    local -a rest=()
    for x in "${IN_PROGRESS[@]}"; do
        keep=true
        for y in "$@"; do [[ "$x" == "$y" ]] && keep=false; done
        $keep && rest+=("$x")
    done
    IN_PROGRESS=("${rest[@]}")
}
_tl_src() {
    if $TOOL_STRIP; then LC_ALL=C sed -b -e '1s/^\xEF\xBB\xBF//' -e 's/\r$//' -- "$1"; else cat -- "$1"; fi
}
# Run one filter over the input into a file, with progress.
tool_stage() {
    local to="$1" label="$2"
    shift 2
    local -a st=()
    progress_start "$label" "$(file_size "$TOOL_INPUT")" read "$TOOL_INPUT"
    _tl_src "$TOOL_INPUT" | "$@" > "$to"
    st=("${PIPESTATUS[@]}")
    progress_stop
    if (( st[0] != 0 || st[1] > 1 )); then
        say "${RED}✘ Ошибка: ${label} (коды ${st[*]}) — результат не создан, исходный файл не тронут${NC}" "${RED}✘ Error: ${label} (codes ${st[*]}) — no result created, the source file is untouched${NC}" >&2
        return 1
    fi
}
# Save a temporary file as <name>_<suffix>.txt; optionally sort -u.
tool_finish() {
    local tmp="$1" suf="$2" what="$3" how="${4:-}" name n t note=""
    TOOL_LAST=""
    if [[ ! -s "$tmp" ]]; then
        say "  ${what}: ничего не нашлось — файл не создан" "  ${what}: nothing found — no file created"
        rm -f -- "$tmp"
        tool_release "$tmp"
        return 0
    fi
    free_name "$TOOL_BASE" "$suf"
    name="$REPLY"
    IN_PROGRESS+=("$name")
    if [[ "$how" == sort ]]; then
        sort_opts
        L t "сортировка" "sort"
        progress_start "$t" "$(file_size "$tmp")" read "$tmp"
        if ! LC_ALL=C sort -u -T . "${SORT_OPTS[@]}" -o "$name" -- "$tmp"; then
            progress_stop
            rm -f -- "$name" "$tmp"
            tool_release "$name" "$tmp"
            say "${RED}✘ Не удалось сохранить ${name}${NC}" "${RED}✘ Could not save ${name}${NC}" >&2
            return 1
        fi
        progress_stop
        rm -f -- "$tmp"
        L note ", без повторов" ", without duplicates"
    else
        L t "не удалось сохранить ${name}" "could not save ${name}"
        if ! must_run "$t" mv -f -- "$tmp" "$name"; then
            rm -f -- "$tmp"
            tool_release "$name" "$tmp"
            return 1
        fi
    fi
    tool_release "$name" "$tmp"
    chmod --reference="$TOOL_INPUT" "$name" 2>/dev/null
    n="$(wc -l < "$name")"
    RESULT_FILES+=("$name")
    TOOL_LAST="$name"
    TOOL_FOUND=true
    say "${GREEN}✔ ${what} → ${name}: строк $(fmt_num "$n"), $(fmt_size "$(file_size "$name")")${note}${NC}" "${GREEN}✔ ${what} → ${name}: lines $(fmt_num "$n"), $(fmt_size "$(file_size "$name")")${note}${NC}"
}
tool_utf8_warn() {
    local n
    [[ -n "$UTF8_LOCALE" ]] || return 0
    n="$(LC_ALL="$UTF8_LOCALE" grep -a -c -v -x '.*' -- "$TOOL_INPUT" 2>/dev/null)"
    [[ "$n" =~ ^[1-9][0-9]*$ ]] || return 0
    say "${YELLOW}⚠ Строк не в UTF-8: $(fmt_num "$n") — буквы в них не распознаются. Сначала подготовьте файл: пункт 2${NC}" "${YELLOW}⚠ Lines not in UTF-8: $(fmt_num "$n") — letters in them are not recognised. Prepare the file first: item 2${NC}"
}

_tl_logins() { LC_ALL=C grep -a -o -E "$TOOL_EMAIL_RE" | LC_ALL=C sed -b 's/@.*//'; }
_tl_up_left() { LC_ALL=C grep -a '[:;]' | LC_ALL=C sed -b 's/[:;].*//' | LC_ALL=C grep -a -v '^$'; }
_tl_up_right() { LC_ALL=C grep -a '[:;]' | LC_ALL=C sed -b 's/^[^:;]*[:;]//' | LC_ALL=C grep -a -v '^$'; }
_tl_cut_left() { LC_ALL=C grep -a -F -e "$TOOL_SEP" | LC_ALL=C sed -b -e "s/${TOOL_SEP_RE}.*//" | LC_ALL=C grep -a -v '^$'; }
_tl_cut_right() { LC_ALL=C grep -a -F -e "$TOOL_SEP" | LC_ALL=C sed -b -e "s/${TOOL_SEP_RE}/\x01/" -e 's/^[^\x01]*\x01//' | LC_ALL=C grep -a -v '^$'; }

_tl_rest() {
    case "$TOOL_SUB" in
        logins)   LC_ALL=C grep -a -v -E "$TOOL_EMAIL_RE" ;;
        userpass) LC_ALL=C grep -a -v '[:;]' ;;
        cut)      LC_ALL=C grep -a -v -F -e "$TOOL_SEP" ;;
        extract)  _tl_rest_kinds "${TOOL_REST_KINDS[@]}" ;;
    esac
}
_tl_rest_kinds() {
    local k="${1:-}"
    if (( $# == 0 )); then cat; return; fi
    shift
    case "$k" in
        emails) LC_ALL=C grep -a -v -E "$TOOL_EMAIL_RE" ;;
        urls)   LC_ALL=C grep -a -v -i -E "$TOOL_URL_RE" ;;
        ip)     LC_ALL=C grep -a -v -P "$TOOL_IP_RE" ;;
    esac | _tl_rest_kinds "$@"
}
# Offer the dictionary without the lines something was extracted from: <name>_rest.txt.
tool_rest() {
    local q t tmp n_in n_out
    $TOOL_FOUND || return 0
    say "  Можно сохранить словарь без строк, из которых это извлечено: строка убирается целиком, результат — в новом файле <имя>_rest.txt, исходный не меняется." "  You can save the dictionary without the lines this was extracted from: a line goes as a whole, the result goes to a new file <name>_rest.txt, the source stays unchanged."
    L q "Сохранить словарь без этих строк?" "Save the dictionary without these lines?"
    confirm_action "$q" n || return 0
    tool_tmp || return 1; tmp="$REPLY"
    L t "словарь без этих строк" "the dictionary without these lines"
    tool_stage "$tmp" "$t" _tl_rest || return 1
    n_in="$(wc -l < "$TOOL_INPUT")"; n_out="$(wc -l < "$tmp")"
    say "  Убрано строк: $(fmt_num $(( n_in - n_out ))) из $(fmt_num "$n_in")" "  Lines removed: $(fmt_num $(( n_in - n_out ))) of $(fmt_num "$n_in")"
    if [[ ! -s "$tmp" ]]; then
        say "  Других строк в словаре нет — файл не создан" "  The dictionary has no other lines — no file created"
        rm -f -- "$tmp"
        tool_release "$tmp"
        return 0
    fi
    tool_finish "$tmp" rest "$t"
}

TOOL_EDGE_RE='^[[:blank:]]|[[:blank:]]$'
_tl_edge_only() { LC_ALL=C grep -a -E "$TOOL_EDGE_RE"; }
_tl_edge_rest() { LC_ALL=C grep -a -v -E "$TOOL_EDGE_RE"; }
_tl_rtrim() { LC_ALL=C sed -b -E 's/[ \t]+$//' | LC_ALL=C grep -a -v '^$'; }
_tl_ltrim() { LC_ALL=C sed -b -E 's/^[ \t]+//' | LC_ALL=C grep -a -v '^$'; }
# Tool 14: lines with spaces or tabs at the edges — move them out, or trim on the right or left.
tool_edge() {
    local f="$1" mode="${TOOL_OPTS[0]}" repl="${TOOL_OPTS[1]:-}" n t tmp rest="" suf what q was_sorted=false n_tr n_out
    n="$(_tl_src "$f" | LC_ALL=C grep -a -c -E "$TOOL_EDGE_RE")"
    [[ "$n" =~ ^[0-9]+$ ]] || n=0
    if (( n == 0 )); then
        say "${BLUE}✓ Строк с пробелами или табами в начале или в конце нет — делать нечего${NC}" "${BLUE}✓ No lines with spaces or tabs at the start or end — nothing to do${NC}"
        return 0
    fi
    say "  Строк с пробелами или табами в начале или в конце: $(fmt_num "$n")" "  Lines with spaces or tabs at the start or end: $(fmt_num "$n")"
    case "$mode" in
        move)  suf=noedge; L what "словарь без этих строк" "the dictionary without these lines" ;;
        right) suf=rtrim;  L what "пробелы справа обрезаны" "spaces on the right trimmed" ;;
        left)  suf=ltrim;  L what "пробелы слева обрезаны" "spaces on the left trimmed" ;;
    esac
    if [[ "$repl" == ask ]]; then
        repl=""
        say "  Обычно результат — в новом файле ${TOOL_BASE}_${suf}.txt, исходный не меняется." "  Normally the result goes to a new file ${TOOL_BASE}_${suf}.txt, the source stays unchanged."
        L q "Заменить сам файл ${f##*/}?" "Replace the file ${f##*/} itself?"
        confirm_action "$q" n && repl=replace
    fi
    if [[ "$mode" == move ]]; then
        tool_tmp || return 1; tmp="$REPLY"
        L t "строки с пробелами или табами по краям" "lines with spaces or tabs at the edges"
        tool_stage "$tmp" "$t" _tl_edge_only || return 1
        tool_finish "$tmp" edge "$t" || return 1
        tool_tmp || return 1; rest="$REPLY"
        tool_stage "$rest" "$what" _tl_edge_rest || return 1
    else
        _tl_src "$f" | LC_ALL=C sort -c 2>/dev/null && was_sorted=true
        tool_tmp || return 1; rest="$REPLY"
        if [[ "$mode" == right ]]; then tool_stage "$rest" "$what" _tl_rtrim || return 1
        else tool_stage "$rest" "$what" _tl_ltrim || return 1; fi
        if $was_sorted && [[ -s "$rest" ]]; then
            sort_opts
            tool_tmp || return 1; tmp="$REPLY"
            L t "сортировка" "sort"
            progress_start "$t" "$(file_size "$rest")" read "$rest"
            if ! LC_ALL=C sort -u -T . "${SORT_OPTS[@]}" -o "$tmp" -- "$rest"; then
                progress_stop
                rm -f -- "$tmp" "$rest"; tool_release "$tmp" "$rest"
                say "${RED}✘ Ошибка сортировки — результат не создан, исходный файл не тронут${NC}" "${RED}✘ Sort error — no result created, the source file is untouched${NC}" >&2
                return 1
            fi
            progress_stop
            n_tr="$(wc -l < "$rest")"; n_out="$(wc -l < "$tmp")"
            rm -f -- "$rest"; tool_release "$rest"
            rest="$tmp"
            say "  Файл был отсортирован, поэтому отсортирован заново; после обрезки совпали с другими строками: $(fmt_num $(( n_tr - n_out )))" "  The file was sorted, so it is sorted again; after trimming these matched other lines: $(fmt_num $(( n_tr - n_out )))"
        fi
        say "  С эталонами обрезанные строки заново не сверялись: чтобы убрать совпавшие — пункт 3." "  The trimmed lines were not compared with the references again: to remove matches use item 3."
    fi
    if [[ ! -s "$rest" ]]; then
        say "  Других строк в словаре нет — ${f##*/} оставлен как есть" "  The dictionary has no other lines — ${f##*/} is left as it is"
        rm -f -- "$rest"; tool_release "$rest"
        return 0
    fi
    if [[ "$repl" == replace ]]; then
        chmod --reference="$f" "$rest" 2>/dev/null
        L t "не удалось заменить ${f##*/}" "could not replace ${f##*/}"
        if ! must_run "$t" mv -f -- "$rest" "$f"; then
            rm -f -- "$rest"; tool_release "$rest"
            return 1
        fi
        tool_release "$rest"
        RESULT_FILES+=("$f")
        say "${GREEN}✔ ${what} → ${f} заменён: строк $(fmt_num "$(wc -l < "$f")"), $(fmt_size "$(file_size "$f")")${NC}" "${GREEN}✔ ${what} → ${f} replaced: lines $(fmt_num "$(wc -l < "$f")"), $(fmt_size "$(file_size "$f")")${NC}"
    else
        tool_finish "$rest" "$suf" "$what" || return 1
    fi
}

_tl_minus_chain() {
    local i="$1"
    if (( i >= ${#TOOL_DICTS[@]} )); then cat; return; fi
    if [[ -n "${TOOL_FIFO[i]:-}" ]]; then
        tee "${TOOL_FIFO[i]}" | LC_ALL=C comm -13 -- "${TOOL_DICTS[i]}" - | _tl_minus_chain $(( i + 1 ))
    else
        LC_ALL=C comm -13 -- "${TOOL_DICTS[i]}" - | _tl_minus_chain $(( i + 1 ))
    fi
}
_tl_minus() { LC_ALL=C sort -u -T . "${SORT_OPTS[@]}" | _tl_minus_chain 0; }
# Tool 15: remove from a file the lines that are in other dictionaries.
tool_minus() {
    local f="$1" d tmp t i k n_in out fdir="" use_counts=true n_prev n_now
    shift
    local -a dicts=("$@") temps=() pids=()
    for d in "${dicts[@]}"; do
        if [[ "$d" -ef "$f" ]]; then
            say "${RED}✘ ${d} — это тот же файл, что и ${f}: убрать его из самого себя нельзя${NC}" "${RED}✘ ${d} is the same file as ${f}: it cannot be removed from itself${NC}" >&2
            return 1
        fi
    done
    sort_opts
    TOOL_DICTS=(); TOOL_FIFO=()
    for d in "${dicts[@]}"; do
        if ! has_crlf "$d" && ! has_bom "$d" && LC_ALL=C sort -c -- "$d" 2>/dev/null; then
            TOOL_DICTS+=("$d")
            continue
        fi
        tool_tmp || return 1; tmp="$REPLY"; temps+=("$tmp")
        say "  ${d}: не отсортирован или с CRLF/BOM — сортирую во временный файл" "  ${d}: not sorted or has CRLF/BOM — sorting into a temporary file"
        L t "сортировка ${d##*/}" "sort ${d##*/}"
        progress_start "$t" "$(file_size "$d")" read "$d"
        if ! LC_ALL=C sed -b -e '1s/^\xEF\xBB\xBF//' -e 's/\r$//' -- "$d" | LC_ALL=C sort -u -T . "${SORT_OPTS[@]}" > "$tmp"; then
            progress_stop
            rm -f -- "${temps[@]}"; tool_release "${temps[@]}"
            say "${RED}✘ Не удалось отсортировать ${d} — результат не создан${NC}" "${RED}✘ Could not sort ${d} — no result created${NC}" >&2
            return 1
        fi
        progress_stop
        TOOL_DICTS+=("$tmp")
    done
    tool_tmp || return 1; out="$REPLY"
    if fdir="$(mktemp -d "${TMPDIR:-/tmp}/dedup_tool.XXXXXX" 2>/dev/null)"; then
        TMP_DIRS=("$fdir")
        for i in "${!TOOL_DICTS[@]}"; do
            TOOL_FIFO[i]="$fdir/f$i"
            mkfifo "${TOOL_FIFO[i]}" 2>/dev/null || { use_counts=false; break; }
        done
    else
        use_counts=false
    fi
    if $use_counts; then
        for i in "${!TOOL_FIFO[@]}"; do
            wc -l < "${TOOL_FIFO[i]}" > "$fdir/c$i" &
            pids+=($!)
        done
        COUNTER_PIDS=("${pids[@]}")
    else
        TOOL_FIFO=()
    fi
    L t "без строк других словарей" "without the lines of the other dictionaries"
    if ! tool_stage "$out" "$t" _tl_minus; then
        (( ${#pids[@]} > 0 )) && kill "${pids[@]}" 2>/dev/null
        COUNTER_PIDS=()
        [[ -n "$fdir" ]] && rm -rf -- "$fdir"
        TMP_DIRS=()
        rm -f -- "${temps[@]}" "$out"; tool_release "${temps[@]}" "$out"
        return 1
    fi
    (( ${#pids[@]} > 0 )) && wait "${pids[@]}" 2>/dev/null
    COUNTER_PIDS=()
    n_in="$(wc -l < "$f")"
    say "Строк на входе: $(fmt_num "$n_in")" "Input lines: $(fmt_num "$n_in")"
    if $use_counts; then
        read -r n_prev < "$fdir/c0" 2>/dev/null
        n_prev=$(( 10#${n_prev:-0} ))
        say "  − повторы внутри файла: $(fmt_num $(( n_in - n_prev )))" "  − duplicates within the file: $(fmt_num $(( n_in - n_prev )))"
        for i in "${!dicts[@]}"; do
            k=$(( i + 1 ))
            if (( k < ${#dicts[@]} )); then
                read -r n_now < "$fdir/c$k" 2>/dev/null
                n_now=$(( 10#${n_now:-0} ))
            else
                n_now="$(wc -l < "$out")"
            fi
            say "  − есть в ${dicts[i]##*/}: $(fmt_num $(( n_prev - n_now )))" "  − in ${dicts[i]##*/}: $(fmt_num $(( n_prev - n_now )))"
            n_prev=$n_now
        done
    fi
    [[ -n "$fdir" ]] && rm -rf -- "$fdir"
    TMP_DIRS=()
    if (( ${#temps[@]} > 0 )); then rm -f -- "${temps[@]}"; tool_release "${temps[@]}"; fi
    if [[ ! -s "$out" ]]; then
        say "${YELLOW}Все строки ${f##*/} есть в других словарях — файл не создан${NC}" "${YELLOW}All lines of ${f##*/} are in the other dictionaries — no file created${NC}"
        rm -f -- "$out"; tool_release "$out"
        return 0
    fi
    tool_finish "$out" minus "$t"
}

_tl_emails() { LC_ALL=C grep -a -o -E "$TOOL_EMAIL_RE"; }
_tl_urls() { LC_ALL=C grep -a -o -i -E "$TOOL_URL_RE" | LC_ALL=C sed -b -E 's/[.,;!?)]+$//'; }
_tl_ips() { LC_ALL=C grep -a -o -P "$TOOL_IP_RE"; }

# sed program for the keyboard layout: ru2en or en2ru.
tool_layout_build() {
    local -a ru=(й ц у к е н г ш щ з х ъ ф ы в а п р о л д ж э я ч с м и т ь б ю ё
                 Й Ц У К Е Н Г Ш Щ З Х Ъ Ф Ы В А П Р О Л Д Ж Э Я Ч С М И Т Ь Б Ю Ё)
    local -a en=(q w e r t y u i o p '[' ']' a s d f g h j k l ';' "'" z x c v b n m , . '`'
                 Q W E R T Y U I O P '{' '}' A S D F G H J K L ':' '"' Z X C V B N M '<' '>' '~')
    local -a sr=('/' '?' ',' '.' ';' ':' '"' '№') se=('|' '&' '?' '/' '$' '^' '@' '#')
    local i
    TOOL_SED=()
    if [[ "$1" == ru2en ]]; then
        TOOL_LAYOUT_SEL='[\xd0\xd1][\x80-\xbf]'
    else
        TOOL_LAYOUT_SEL='[A-Za-z]'
    fi
    if [[ -n "$UTF8_LOCALE" ]]; then
        local from="" to="" a b
        for i in "${!ru[@]}"; do
            a="${ru[i]}"; b="${en[i]}"
            [[ "$a" == / ]] && a='\/'
            [[ "$b" == / ]] && b='\/'
            from+="$a"; to+="$b"
        done
        for i in "${!sr[@]}"; do
            a="${sr[i]}"; b="${se[i]}"
            [[ "$a" == / ]] && a='\/'
            [[ "$b" == / ]] && b='\/'
            from+="$a"; to+="$b"
        done
        if [[ "$1" == ru2en ]]; then TOOL_SED=(-e "y/${from}/${to}/"); else TOOL_SED=(-e "y/${to}/${from}/"); fi
        return 0
    fi
    if [[ "$1" == ru2en ]]; then
        for i in "${!sr[@]}"; do _tl_sed_add "${sr[i]}" "${se[i]}"; done
        for i in "${!ru[@]}"; do _tl_sed_add "${ru[i]}" "${en[i]}"; done
    else
        for i in "${!en[@]}"; do _tl_sed_add "${en[i]}" "${ru[i]}"; done
        for i in 2 1 3 0 4 5 6 7; do _tl_sed_add "${se[i]}" "${sr[i]}"; done
    fi
}
_tl_sed_add() {
    local s="$1" d="$2"
    case "$s" in '.'|'*'|'['|'^'|'$'|'/'|'\') s="\\$s" ;; esac
    case "$d" in '&'|'/'|'\') d="\\$d" ;; esac
    TOOL_SED+=(-e "s/$s/$d/g")
}
_tl_layout() {
    if [[ -n "$UTF8_LOCALE" ]]; then
        LC_ALL=C grep -a -P "$TOOL_LAYOUT_SEL" | LC_ALL="$UTF8_LOCALE" sed -b "${TOOL_SED[@]}"
    else
        LC_ALL=C grep -a -P "$TOOL_LAYOUT_SEL" | LC_ALL=C sed -b "${TOOL_SED[@]}"
    fi
}

_tl_case() {
    if [[ -n "$UTF8_LOCALE" ]]; then LC_ALL="$UTF8_LOCALE" sed -b "$TOOL_CASE_SED"; else LC_ALL=C sed -b "$TOOL_CASE_SED"; fi
}
_tl_nospace() { LC_ALL=C grep -a -v -P '[ \t]'; }
_tl_firstword() { LC_ALL=C sed -b -E -e 's/^[ \t]+//' -e 's/[ \t].*//' | LC_ALL=C grep -a -v '^$'; }
_tl_trim() { LC_ALL=C sed -b -E -e 's/^[ \t]+//' -e 's/[ \t]+$//' -e 's/[ \t]{2,}/ /g' | LC_ALL=C grep -a -v '^$'; }
_tl_filter() { LC_ALL=C grep -a -v -F "${TOOL_PAT[@]}"; }

_tl_ascii() { LC_ALL=C grep -a -v -P '[\x80-\xff]'; }
_tl_alpha_split() {
    LC_ALL=C grep -a -P '[\x80-\xff]' | LC_ALL=C awk -v p="$TOOL_ALPHA_PREF" '
    {
        n = 0; k = "other"
        if ($0 ~ /[A-Za-z]|\303[\200-\277]|[\304-\311][\200-\277]/) { n++; k = "latin" }
        if ($0 ~ /[\320-\323][\200-\277]|\324[\200-\257]/) { n++; k = "cyr" }
        if ($0 ~ /\315[\260-\277]|[\316\317][\200-\277]/) { n++; k = "greek" }
        if ($0 ~ /\326[\220-\277]|\327[\200-\277]/) { n++; k = "hebrew" }
        if ($0 ~ /[\330-\333][\200-\277]|\335[\220-\277]|\357[\255-\267\271-\273][\200-\277]/) { n++; k = "arabic" }
        if ($0 ~ /\343[\200-\277][\200-\277]|[\344-\351][\200-\277][\200-\277]|\352[\260-\277][\200-\277]|[\353\354][\200-\277][\200-\277]|\355[\200-\236][\200-\277]|\357[\244-\253][\200-\277]|\360[\240-\257][\200-\277][\200-\277]/) { n++; k = "cjk" }
        if (n > 1) k = "mixed"
        print >> (p "." k)
    }'
}
# Split a dictionary by alphabet into <name>_latin.txt, <name>_cyr.txt and so on.
tool_alphabets() {
    local k t what
    tool_utf8_warn
    tool_tmp || return 1
    TOOL_ALPHA_PREF="$REPLY"
    local -a kinds=(latin cyr greek hebrew arabic cjk other mixed)
    for k in "${kinds[@]}"; do IN_PROGRESS+=("$TOOL_ALPHA_PREF.$k"); done
    L t "строки из ASCII" "ASCII lines"
    tool_stage "$TOOL_ALPHA_PREF.latin" "$t" _tl_ascii || return 1
    L t "алфавиты" "alphabets"
    tool_stage /dev/null "$t" _tl_alpha_split || return 1
    for k in "${kinds[@]}"; do
        [[ -s "$TOOL_ALPHA_PREF.$k" ]] || { rm -f -- "$TOOL_ALPHA_PREF.$k"; tool_release "$TOOL_ALPHA_PREF.$k"; continue; }
        case "$k" in
            latin)  L what "латиница и ASCII" "Latin and ASCII" ;;
            cyr)    L what "кириллица" "Cyrillic" ;;
            greek)  L what "греческий" "Greek" ;;
            hebrew) L what "иврит" "Hebrew" ;;
            arabic) L what "арабский" "Arabic" ;;
            cjk)    L what "иероглифы, кана, хангыль" "CJK, kana, hangul" ;;
            other)  L what "другие знаки и алфавиты" "other signs and alphabets" ;;
            mixed)  L what "несколько алфавитов в строке" "several alphabets in a line" ;;
        esac
        tool_finish "$TOOL_ALPHA_PREF.$k" "$k" "$what" || return 1
    done
    rm -f -- "$TOOL_ALPHA_PREF"
    tool_release "$TOOL_ALPHA_PREF"
}

_tl_top1() {
    LC_ALL=C sort -T . "${SORT_OPTS[@]}" | LC_ALL=C uniq -c | LC_ALL=C sort -T . "${SORT_OPTS[@]}" -s -k1,1nr \
        | _tl_top_head 's/^ *([0-9]+) /\1\t/p'
}
_tl_top_head() {
    local n="${TOOL_OPTS[0]}" h="$TOOL_TOP_HEAD" top a b eq rest
    LC_ALL=C sed -u -b -n -e "1,$(( n + 1 ))p" -e "$(( n + 1 ))q" > "$h"
    LC_ALL=C sed -b -n -E "1,${n}$1" -- "$h"
    top="$(LC_ALL=C sed -n -E '1s/^ *([0-9]+).*/\1/p' -- "$h")"
    a="$(LC_ALL=C sed -n -E "${n}s/^ *([0-9]+).*/\\1/p" -- "$h")"
    b="$(LC_ALL=C sed -n -E "$(( n + 1 ))s/^ *([0-9]+).*/\\1/p" -- "$h")"
    if [[ -n "$b" && "$a" == "$b" ]]; then
        eq="$(LC_ALL=C grep -a -c -E "^ *${a}[^0-9]" -- "$h")"
        rest="$(LC_ALL=C grep -a -c -E "^ *${a}[^0-9]")"
        printf '%s %s %s\n' "$top" "$a" "$(( eq + rest ))" > "$TOOL_TOP_STAT"
    else
        cat > /dev/null
    fi
}
_tl_top_part() {
    LC_ALL=C sort -T . "${SORT_OPTS[@]}" | LC_ALL=C uniq -c | LC_ALL=C sed -b -E 's/^ *([0-9]+) (.*)$/\2\x01\1/'
}
# The most frequent lines of one or several files.
tool_top() {
    local n="${TOOL_OPTS[0]}" t tmp f what top a eq
    local -a parts=()
    sort_opts
    L what "самые частые строки" "the most frequent lines"
    tool_tmp || return 1
    tmp="$REPLY"
    tool_tmp || return 1
    TOOL_TOP_HEAD="$REPLY"
    tool_tmp || return 1
    TOOL_TOP_STAT="$REPLY"
    if (( $# == 1 )); then
        L t "подсчёт" "counting"
        tool_stage "$tmp" "$t" _tl_top1 || return 1
    else
        for f in "$@"; do
            TOOL_INPUT="$f"
            TOOL_STRIP=false
            if has_crlf "$f" || has_bom "$f"; then TOOL_STRIP=true; fi
            tool_tmp || return 1
            parts+=("$REPLY")
            L t "подсчёт: ${f##*/}" "counting: ${f##*/}"
            tool_stage "$REPLY" "$t" _tl_top_part || return 1
        done
        TOOL_INPUT="$1"
        LC_ALL=C sort -T . "${SORT_OPTS[@]}" -s -t $'\x01' -k1,1 -- "${parts[@]}" \
            | LC_ALL=C awk -F '\001' '{
                  n = $NF; k = substr($0, 1, length($0) - length(n) - 1)
                  if (NR > 1 && k != p) { print t "\001" d "\001" p; t = 0; d = 0 }
                  p = k; t += n; d++
              }
              END { if (NR) print t "\001" d "\001" p }' \
            | LC_ALL=C sort -T . "${SORT_OPTS[@]}" -s -t $'\x01' -k1,1nr \
            | _tl_top_head 's/^([0-9]+)\x01([0-9]+)\x01/\1\t\2\t/p' > "$tmp"
        rm -f -- "${parts[@]}"
        tool_release "${parts[@]}"
    fi
    tool_finish "$tmp" top "$what" || return 1
    if [[ -s "$TOOL_TOP_STAT" ]]; then
        read -r top a eq < "$TOOL_TOP_STAT"
        if [[ "$top" == "$a" ]]; then
            say "${YELLOW}⚠ У всех $(fmt_num "$n") строк один счётчик — $(fmt_num "$a"): таких строк всего $(fmt_num "$eq"), и в список вошли первые по порядку сортировки, а не самые частые${NC}" "${YELLOW}⚠ All $(fmt_num "$n") lines have the same count, $(fmt_num "$a"): there are $(fmt_num "$eq") such lines, and the list has the first ones in sort order, not the most frequent ones${NC}"
        else
            say "${YELLOW}⚠ Конец списка выбран среди равных: строк со счётчиком $(fmt_num "$a") всего $(fmt_num "$eq"), в список вошла только часть${NC}" "${YELLOW}⚠ The end of the list is chosen among equals: there are $(fmt_num "$eq") lines with the count $(fmt_num "$a"), the list has only some of them${NC}"
        fi
    fi
    rm -f -- "$TOOL_TOP_HEAD" "$TOOL_TOP_STAT"
    tool_release "$TOOL_TOP_HEAD" "$TOOL_TOP_STAT"
    if [[ -n "$TOOL_LAST" ]]; then
        if (( $# > 1 )); then out "  Первые (сколько раз, в скольких файлах, строка):" "  The first ones (how many times, in how many files, the line):"
        else out "  Первые (сколько раз, строка):" "  The first ones (how many times, the line):"; fi
        head -n 10 -- "$TOOL_LAST" | ctrl_visible | LC_ALL=C sed -b 's/^/    /'
    fi
}

_tl_uniq() {
    LC_ALL=C cat -n | LC_ALL=C sort -T . "${SORT_OPTS[@]}" -t "$TAB_CHR" -s -u -k2 \
        | LC_ALL=C sort -T . "${SORT_OPTS[@]}" -t "$TAB_CHR" -k1,1n | LC_ALL=C cut -f2-
}

# Find a line in the dictionaries: in which files and how many times.
tool_find() {
    local s="${TOOL_OPTS[0]}" f n_any n_eq k hit=0
    say "Ищу «${s//\\/\\\\}» в файлах: $#" "Looking for «${s//\\/\\\\}» in files: $#"
    for f in "$@"; do
        k="$(archive_kind "$f")"
        if [[ -n "$k" ]]; then
            say "  ${f}: архив ${k} — пропущен" "  ${f}: ${k} archive — skipped"
            continue
        fi
        n_any="$(LC_ALL=C grep -a -c -F -e "$s" -- "$f" 2>/dev/null)"
        [[ "$n_any" =~ ^[1-9][0-9]*$ ]] || continue
        n_eq="$(LC_ALL=C grep -a -c -x -F -e "$s" -e "${s}${CR_CHR}" -- "$f" 2>/dev/null)"
        [[ "$n_eq" =~ ^[0-9]+$ ]] || n_eq=0
        hit=$(( hit + 1 ))
        say "  ${f}: точно такая строка — $(fmt_num "$n_eq"), содержат её — $(fmt_num "$n_any")" "  ${f}: exactly this line: $(fmt_num "$n_eq"), containing it: $(fmt_num "$n_any")"
    done
    if (( hit > 0 )); then
        say "${GREEN}✔ Нашлась в файлах: ${hit} из $#${NC}" "${GREEN}✔ Found in files: ${hit} of $#${NC}"
    else
        say "${YELLOW}Не нашлась ни в одном из файлов: $#${NC}" "${YELLOW}Not found in any of the files: $#${NC}"
    fi
}
tool_find_files() {
    local f
    work_txt
    TOOL_FILES=("${WORK_TXT[@]}")
    shopt -s nullglob
    for f in "$COMPARE_DIR"/*.txt; do TOOL_FILES+=("$f"); done
    shopt -u nullglob
}

# Run one dictionary tool (TOOL_SUB, TOOL_OPTS) on the files given.
cmd_tool() {
    local f="${1:-}" tmp t what k n_in n_out
    TOOL_INPUT="$f"
    TOOL_BASE="${f%.*}"
    [[ "$TOOL_SUB" == minus ]] && TOOL_BASE="${TOOL_BASE##*/}"
    TOOL_STRIP=false
    TOOL_FOUND=false
    if [[ "$TOOL_SUB" != find ]] && { has_crlf "$f" || has_bom "$f"; }; then TOOL_STRIP=true; fi
    if [[ "$TOOL_SUB" != find ]]; then
        say "${CYAN}${SCRIPT_NAME} v${VERSION} — работа со словарями (${TOOL_SUB}): ${f} ($(fmt_size "$(file_size "$f")"))${NC}" "${CYAN}${SCRIPT_NAME} v${VERSION} — dictionary tools (${TOOL_SUB}): ${f} ($(fmt_size "$(file_size "$f")"))${NC}"
    fi
    IN_PROGRESS=()
    case "$TOOL_SUB" in
        logins)
            tool_tmp || return 1; tmp="$REPLY"
            L t "логины" "logins"
            tool_stage "$tmp" "$t" _tl_logins || return 1
            tool_finish "$tmp" logins "$t" sort || return 1
            k="$(_tl_src "$f" | LC_ALL=C grep -a -c -v -E "$TOOL_EMAIL_RE")"
            [[ "$k" =~ ^[1-9][0-9]*$ ]] && say "  Строк без почты: $(fmt_num "$k") — пропущены" "  Lines without an email: $(fmt_num "$k") — skipped"
            tool_rest || return 1
            ;;
        userpass)
            tool_tmp || return 1; tmp="$REPLY"
            L t "логины" "logins"
            tool_stage "$tmp" "$t" _tl_up_left || return 1
            tool_finish "$tmp" logins "$t" sort || return 1
            tool_tmp || return 1; tmp="$REPLY"
            L t "пароли" "passwords"
            tool_stage "$tmp" "$t" _tl_up_right || return 1
            tool_finish "$tmp" passwords "$t" sort || return 1
            tool_rest || return 1
            ;;
        cut)
            TOOL_SEP="${TOOL_OPTS[0]}"
            TOOL_SEP_RE="$(printf '%s' "$TOOL_SEP" | LC_ALL=C sed -e 's/[][\.*^$/]/\\&/g')"
            if [[ "${TOOL_OPTS[1]}" != right ]]; then
                tool_tmp || return 1; tmp="$REPLY"
                L t "левая часть" "left part"
                tool_stage "$tmp" "$t" _tl_cut_left || return 1
                tool_finish "$tmp" left "$t" sort || return 1
            fi
            if [[ "${TOOL_OPTS[1]}" != left ]]; then
                tool_tmp || return 1; tmp="$REPLY"
                L t "правая часть" "right part"
                tool_stage "$tmp" "$t" _tl_cut_right || return 1
                tool_finish "$tmp" right "$t" sort || return 1
            fi
            tool_rest || return 1
            ;;
        extract)
            local -a ex_kinds=("${TOOL_OPTS[@]}")
            (( ${#ex_kinds[@]} > 0 )) || ex_kinds=(emails urls ip)
            for k in "${ex_kinds[@]}"; do
                tool_tmp || return 1; tmp="$REPLY"
                case "$k" in
                    emails) L t "адреса почты" "email addresses"; tool_stage "$tmp" "$t" _tl_emails || return 1 ;;
                    urls)   L t "ссылки" "links"; tool_stage "$tmp" "$t" _tl_urls || return 1 ;;
                    ip)     L t "адреса IP" "IP addresses"; tool_stage "$tmp" "$t" _tl_ips || return 1 ;;
                esac
                tool_finish "$tmp" "$k" "$t" sort || return 1
            done
            TOOL_REST_KINDS=("${ex_kinds[@]}")
            tool_rest || return 1
            ;;
        layout)
            tool_utf8_warn
            tool_layout_build "${TOOL_OPTS[0]}"
            tool_tmp || return 1; tmp="$REPLY"
            if [[ "${TOOL_OPTS[0]}" == ru2en ]]; then
                L t "раскладка RU → EN (строки с кириллицей)" "layout RU → EN (lines with Cyrillic)"; k=en
            else
                L t "раскладка EN → RU (строки с латиницей)" "layout EN → RU (lines with Latin letters)"; k=ru
            fi
            tool_stage "$tmp" "$t" _tl_layout || return 1
            tool_finish "$tmp" "$k" "$t" || return 1
            ;;
        case)
            tool_utf8_warn
            local -a case_kinds=("${TOOL_OPTS[0]}")
            [[ "${TOOL_OPTS[0]}" == all ]] && case_kinds=(lower upper cap uncap)
            for k in "${case_kinds[@]}"; do
                case "$k" in
                    lower) TOOL_CASE_SED='s/.*/\L&/'; L t "все маленькие" "all lower case" ;;
                    upper) TOOL_CASE_SED='s/.*/\U&/'; L t "все большие" "all upper case" ;;
                    cap)   TOOL_CASE_SED='s/^./\U&/'; L t "первая большая" "first letter upper case" ;;
                    uncap) TOOL_CASE_SED='s/^./\L&/'; L t "первая маленькая" "first letter lower case" ;;
                esac
                tool_tmp || return 1; tmp="$REPLY"
                tool_stage "$tmp" "$t" _tl_case || return 1
                tool_finish "$tmp" "$k" "$t" || return 1
            done
            ;;
        spaces)
            tool_tmp || return 1; tmp="$REPLY"
            if [[ "${TOOL_OPTS[0]}" == first ]]; then
                L t "только первое слово" "only the first word"
                tool_stage "$tmp" "$t" _tl_firstword || return 1
                tool_finish "$tmp" firstword "$t" || return 1
            else
                L t "без строк с пробелом" "without lines with a space"
                tool_stage "$tmp" "$t" _tl_nospace || return 1
                tool_finish "$tmp" nospace "$t" || return 1
            fi
            ;;
        trim)
            k="$(_tl_src "$f" | LC_ALL=C grep -a -c -P '^[ \t]|[ \t]$|[ \t]{2}')"
            [[ "$k" =~ ^[0-9]+$ ]] || k=0
            say "  Строк, где есть что обрезать: $(fmt_num "$k")" "  Lines with something to trim: $(fmt_num "$k")"
            tool_tmp || return 1; tmp="$REPLY"
            L t "пробелы обрезаны" "spaces trimmed"
            tool_stage "$tmp" "$t" _tl_trim || return 1
            tool_finish "$tmp" trim "$t" || return 1
            ;;
        filter)
            TOOL_PAT=()
            for k in "${TOOL_OPTS[@]}"; do TOOL_PAT+=(-e "$k"); done
            tool_tmp || return 1; tmp="$REPLY"
            L t "без строк с заданными кусками" "without lines with the given pieces"
            tool_stage "$tmp" "$t" _tl_filter || return 1
            n_in="$(wc -l < "$f")"; n_out="$(wc -l < "$tmp")"
            say "  Убрано строк: $(fmt_num $(( n_in - n_out ))) из $(fmt_num "$n_in")" "  Lines removed: $(fmt_num $(( n_in - n_out ))) of $(fmt_num "$n_in")"
            tool_finish "$tmp" filtered "$t" || return 1
            ;;
        alphabets)
            tool_alphabets || return 1
            ;;
        top)
            tool_top "$@" || return 1
            ;;
        uniq)
            sort_opts
            tool_tmp || return 1; tmp="$REPLY"
            L t "повторы убраны, порядок прежний" "duplicates removed, the order kept"
            tool_stage "$tmp" "$t" _tl_uniq || return 1
            n_in="$(wc -l < "$f")"; n_out="$(wc -l < "$tmp")"
            say "  Повторов убрано: $(fmt_num $(( n_in - n_out ))) из $(fmt_num "$n_in")" "  Duplicates removed: $(fmt_num $(( n_in - n_out ))) of $(fmt_num "$n_in")"
            tool_finish "$tmp" uniq "$t" || return 1
            ;;
        find)
            tool_find "$@"
            ;;
        edge)
            tool_edge "$f" || return 1
            ;;
        minus)
            tool_minus "$@" || return 1
            ;;
    esac
    IN_PROGRESS=()
    return 0
}

# The hidden command: tool <name> <file> [options].
tool_usage() {
    out "${RED}Как вызывать: ${SCRIPT_NAME} tool <утилита> …${NC}" "${RED}Usage: ${SCRIPT_NAME} tool <name> …${NC}" >&2
    {
        echo "  logins <file>"
        echo "  userpass <file>"
        echo "  cut <file> <sep> [left|right|both]"
        echo "  extract <file> [emails] [urls] [ip]"
        echo "  layout <file> [ru2en|en2ru]"
        echo "  case <file> lower|upper|cap|uncap|all"
        echo "  spaces <file> remove|first"
        echo "  trim <file>"
        echo "  filter <file> <piece>..."
        echo "  alphabets <file>"
        echo "  top [N] <file>..."
        echo "  uniq <file>"
        echo "  find <line> [file...]"
        echo "  edge <file> move|right|left [replace]"
        echo "  minus <file> <dictionary>..."
    } >&2
    return 1
}
tool_cli() {
    local sub="${1:-}" x
    (( $# > 0 )) && shift
    TOOL_SUB="$sub"
    TOOL_OPTS=()
    local -a files=()
    case "$sub" in
        logins|userpass|trim|alphabets|uniq)
            (( $# == 1 )) || { tool_usage; return 1; }
            files=("$1")
            ;;
        cut)
            (( $# == 2 || $# == 3 )) && [[ -n "$2" ]] || { tool_usage; return 1; }
            [[ "${3:-both}" =~ ^(left|right|both)$ ]] || { tool_usage; return 1; }
            files=("$1"); TOOL_OPTS=("$2" "${3:-both}")
            ;;
        extract)
            (( $# >= 1 )) || { tool_usage; return 1; }
            files=("$1"); shift
            for x in "$@"; do [[ "$x" =~ ^(emails|urls|ip)$ ]] || { tool_usage; return 1; }; done
            TOOL_OPTS=("$@")
            ;;
        layout)
            (( $# == 1 || $# == 2 )) && [[ "${2:-ru2en}" =~ ^(ru2en|en2ru)$ ]] || { tool_usage; return 1; }
            files=("$1"); TOOL_OPTS=("${2:-ru2en}")
            ;;
        case)
            (( $# == 2 )) && [[ "$2" =~ ^(lower|upper|cap|uncap|all)$ ]] || { tool_usage; return 1; }
            files=("$1"); TOOL_OPTS=("$2")
            ;;
        spaces)
            (( $# == 2 )) && [[ "$2" =~ ^(remove|first)$ ]] || { tool_usage; return 1; }
            files=("$1"); TOOL_OPTS=("$2")
            ;;
        filter)
            (( $# >= 2 )) || { tool_usage; return 1; }
            files=("$1"); shift
            for x in "$@"; do [[ -n "$x" ]] || { tool_usage; return 1; }; done
            TOOL_OPTS=("$@")
            ;;
        top)
            x=100
            if [[ "${1:-}" =~ ^[0-9]+$ ]] && (( $# >= 2 )); then x=$((10#$1)); shift; fi
            (( $# >= 1 && x >= 1 )) || { tool_usage; return 1; }
            files=("$@"); TOOL_OPTS=("$x")
            ;;
        find)
            (( $# >= 1 )) && [[ -n "$1" ]] || { tool_usage; return 1; }
            TOOL_OPTS=("$1"); shift
            files=("$@")
            if (( ${#files[@]} == 0 )); then tool_find_files; files=("${TOOL_FILES[@]}"); fi
            ;;
        edge)
            (( $# == 2 || $# == 3 )) && [[ "$2" =~ ^(move|right|left)$ && "${3:-replace}" == replace ]] || { tool_usage; return 1; }
            if [[ -n "${3:-}" && "$1" == */* ]]; then
                say "${RED}Ошибка: заменить можно только файл в этой папке: $1${NC}" "${RED}Error: only a file in this folder can be replaced: $1${NC}" >&2
                return 1
            fi
            files=("$1"); TOOL_OPTS=("$2" "${3:-}")
            ;;
        minus)
            (( $# >= 2 )) || { tool_usage; return 1; }
            files=("$@")
            ;;
        *)
            tool_usage
            return 1
            ;;
    esac
    run_action tool "${files[@]}"
}

# Choose one or several files; Enter takes all of them.
pick_tool_files() {
    local choice i k q
    local -a files=() parts=()
    shopt -s nullglob
    files=(*.txt)
    shopt -u nullglob
    PICKED=()
    if (( ${#files[@]} == 0 )); then
        out "${RED}✘ В папке нет рабочих файлов (*.txt)${NC}" "${RED}✘ No working files (*.txt) in the folder${NC}"
        return 1
    fi
    if (( ${#files[@]} == 1 )); then
        PICKED=("${files[0]}")
        out "Рабочий файл: ${files[0]}" "Working file: ${files[0]}"
        return 0
    fi
    for i in "${!files[@]}"; do
        echo "  $((i + 1))) ${files[i]} ($(fmt_size "$(file_size "${files[i]}")"))$(file_mark "${files[i]}")"
    done
    out "  0) назад" "  0) back"
    while true; do
        L q "Номера через пробел, Enter — все файлы: " "Numbers separated by spaces, Enter — all files: "
        read -r -p "$q" choice || return 1
        read -r -a parts <<< "${choice//,/ }"
        [[ "${parts[*]}" == 0 ]] && return 1
        if (( ${#parts[@]} == 0 )); then
            work_txt
            PICKED=("${WORK_TXT[@]}")
            return 0
        fi
        PICKED=()
        for k in "${parts[@]}"; do
            if ! [[ "$k" =~ ^[0-9]+$ ]] || (( 10#$k < 1 || 10#$k > ${#files[@]} )); then PICKED=(); break; fi
            PICKED+=("${files[10#$k - 1]}")
        done
        (( ${#PICKED[@]} > 0 )) && return 0
        out "${YELLOW}Введите номера из списка через пробел${NC}" "${YELLOW}Type numbers from the list separated by spaces${NC}"
    done
}

# Tool 15: choose the file and the dictionaries to subtract.
pick_minus_files() {
    local choice i k q f first=""
    local -a files=() parts=()
    shopt -s nullglob
    files=(*.txt "$COMPARE_DIR"/*.txt)
    shopt -u nullglob
    PICKED=()
    if (( ${#files[@]} < 2 )); then
        out "${RED}✘ Нужны хотя бы два файла (*.txt в этой папке и в ${COMPARE_DIR}/), а их ${#files[@]}${NC}" "${RED}✘ At least two files are needed (*.txt in this folder and in ${COMPARE_DIR}/), there are ${#files[@]}${NC}"
        return 1
    fi
    for i in "${!files[@]}"; do
        echo "  $((i + 1))) ${files[i]} ($(fmt_size "$(file_size "${files[i]}")"))$(file_mark "${files[i]}")"
    done
    out "  0) назад" "  0) back"
    while [[ -z "$first" ]]; do
        L q "Из какого файла убирать строки (номер): " "Which file to remove the lines from (number): "
        read -r -p "$q" choice || return 1
        k="${choice// /}"
        [[ "$k" == 0 || -z "$k" ]] && return 1
        if [[ "$k" =~ ^[0-9]+$ ]] && (( 10#$k >= 1 && 10#$k <= ${#files[@]} )); then
            first="${files[10#$k - 1]}"
        else
            out "${YELLOW}Введите номер из списка${NC}" "${YELLOW}Type a number from the list${NC}"
        fi
    done
    while true; do
        L q "Какие словари вычесть: номера через пробел, Enter — все остальные: " "Which dictionaries to subtract: numbers separated by spaces, Enter — all the others: "
        read -r -p "$q" choice || return 1
        read -r -a parts <<< "${choice//,/ }"
        [[ "${parts[*]}" == 0 ]] && return 1
        PICKED=("$first")
        if (( ${#parts[@]} == 0 )); then
            for f in "${files[@]}"; do
                [[ "$f" == "$first" ]] || is_list "$f" || PICKED+=("$f")
            done
        else
            for k in "${parts[@]}"; do
                if ! [[ "$k" =~ ^[0-9]+$ ]] || (( 10#$k < 1 || 10#$k > ${#files[@]} )); then PICKED=(); break; fi
                f="${files[10#$k - 1]}"
                [[ "$f" == "$first" ]] || PICKED+=("$f")
            done
        fi
        (( ${#PICKED[@]} >= 2 )) && return 0
        out "${YELLOW}Введите номера других файлов из списка${NC}" "${YELLOW}Type the numbers of other files from the list${NC}"
    done
}

# Menu item 7: the list of dictionary tools.
tools_menu() {
    local c q a k
    local -a pieces=()
    while true; do
        echo
        out "${CYAN}Работа со словарями${NC} — результат в новом файле, исходный не меняется" "${CYAN}Dictionary tools${NC} — the result goes to a new file, the source stays unchanged"
        out " ${GREEN}Разобрать:${NC}" " ${GREEN}Take apart:${NC}"
        out "  1) Почта → логины (часть до @) → <имя>_logins.txt" "  1) Email → logins (the part before @) → <name>_logins.txt"
        out "  2) user:pass → логины и пароли → <имя>_logins.txt, <имя>_passwords.txt" "  2) user:pass → logins and passwords → <name>_logins.txt, <name>_passwords.txt"
        out "  3) Разделить строку по разделителю → <имя>_left.txt, <имя>_right.txt" "  3) Split a line by a separator → <name>_left.txt, <name>_right.txt"
        out "  4) Вырезать из дампа почту, ссылки, IP → <имя>_emails.txt, _urls.txt, _ip.txt" "  4) Cut emails, links, IPs out of a dump → <name>_emails.txt, _urls.txt, _ip.txt"
        out " ${GREEN}Изменить:${NC}" " ${GREEN}Change:${NC}"
        out "  5) Раскладка RU ↔ EN («привет» ↔ «ghbdtn») → <имя>_en.txt, <имя>_ru.txt" "  5) Keyboard layout RU ↔ EN («привет» ↔ «ghbdtn») → <name>_en.txt, <name>_ru.txt"
        out "  6) Регистр: все маленькие, все большие, первая большая или маленькая" "  6) Case: all lower, all upper, first letter upper or lower"
        out "  7) Строки с пробелом: убрать или оставить только первое слово" "  7) Lines with a space: remove them or keep only the first word"
        out "  8) Обрезать пробелы и табы по краям, сдвоенные внутри — в один → <имя>_trim.txt" "  8) Trim spaces and tabs at the edges, double ones inside into one → <name>_trim.txt"
        out "  9) Убрать строки с заданными символами или кусками → <имя>_filtered.txt" "  9) Remove lines with the given characters or pieces → <name>_filtered.txt"
        out " ${GREEN}Разложить и посчитать:${NC}" " ${GREEN}Sort out and count:${NC}"
        out " 10) Разложить по алфавитам → <имя>_latin.txt, _cyr.txt, _cjk.txt, _mixed.txt…" " 10) Split by alphabets → <name>_latin.txt, _cyr.txt, _cjk.txt, _mixed.txt…"
        out " 11) Самые частые строки → <имя>_top.txt" " 11) The most frequent lines → <name>_top.txt"
        out " 12) Убрать повторы без сортировки, порядок строк прежний → <имя>_uniq.txt" " 12) Remove duplicates without sorting, the order of lines kept → <name>_uniq.txt"
        out " 13) Найти строку во всех словарях папки: в каких файлах и сколько раз" " 13) Find a line in all dictionaries of the folder: in which files and how many times"
        out " ${GREEN}Почистить:${NC}" " ${GREEN}Clean up:${NC}"
        out " 14) Пробелы и табы по краям: вынести такие строки, обрезать справа или слева" " 14) Spaces and tabs at the edges: move such lines out, trim on the right or left"
        out " 15) Убрать из файла строки других словарей → <имя>_minus.txt" " 15) Remove from a file the lines of other dictionaries → <name>_minus.txt"
        out "  0) Назад" "  0) Back"
        L q "Выберите пункт: " "Choose an item: "
        if ! read -r -p "$q" c; then echo; return 0; fi
        [[ -n "${c// /}" ]] && echo
        TOOL_OPTS=()
        case "${c// /}" in
            0) return 0 ;;
            1) pick_work_file one && { TOOL_SUB=logins; run_action tool "${PICKED[0]}"; } ;;
            2) pick_work_file one && { TOOL_SUB=userpass; run_action tool "${PICKED[0]}"; } ;;
            3)
                pick_work_file one || continue
                L q "Разделитель (например : / ; --- (at)), Enter — назад: " "Separator (for example : / ; --- (at)), Enter — back: "
                read -r -p "$q" a || continue
                [[ -n "$a" ]] || continue
                L q "Какая часть: 1 — левая, 2 — правая, 3 — обе [3]: " "Which part: 1 — left, 2 — right, 3 — both [3]: "
                read -r -p "$q" k || k=3
                case "${k// /}" in 1) k=left ;; 2) k=right ;; *) k=both ;; esac
                TOOL_SUB=cut; TOOL_OPTS=("$a" "$k")
                run_action tool "${PICKED[0]}"
                ;;
            4)
                pick_work_file one || continue
                L q "Что вырезать: 1 — почта, 2 — ссылки, 3 — IP (можно через пробел), Enter — всё: " "What to cut out: 1 — emails, 2 — links, 3 — IPs (several separated by spaces), Enter — everything: "
                read -r -p "$q" a || a=""
                read -r -a pieces <<< "${a//,/ }"
                TOOL_SUB=extract
                for k in "${pieces[@]}"; do
                    case "$k" in 1) TOOL_OPTS+=(emails) ;; 2) TOOL_OPTS+=(urls) ;; 3) TOOL_OPTS+=(ip) ;; esac
                done
                run_action tool "${PICKED[0]}"
                ;;
            5)
                pick_work_file one || continue
                L q "1 — RU → EN («привет» → «ghbdtn»), 2 — EN → RU («ghbdtn» → «привет») [1]: " "1 — RU → EN («привет» → «ghbdtn»), 2 — EN → RU («ghbdtn» → «привет») [1]: "
                read -r -p "$q" k || k=1
                [[ "${k// /}" == 2 ]] && k=en2ru || k=ru2en
                TOOL_SUB=layout; TOOL_OPTS=("$k")
                run_action tool "${PICKED[0]}"
                ;;
            6)
                pick_work_file one || continue
                L q "1 — все маленькие, 2 — все большие, 3 — первая большая, 4 — первая маленькая, 5 — все четыре файла сразу, Enter — назад: " "1 — all lower, 2 — all upper, 3 — first upper, 4 — first lower, 5 — all four files at once, Enter — back: "
                read -r -p "$q" k || continue
                case "${k// /}" in
                    1) k=lower ;; 2) k=upper ;; 3) k=cap ;; 4) k=uncap ;; 5) k=all ;;
                    *) continue ;;
                esac
                TOOL_SUB=case; TOOL_OPTS=("$k")
                run_action tool "${PICKED[0]}"
                ;;
            7)
                pick_work_file one || continue
                L q "1 — убрать строки с пробелом или табом, 2 — оставить только первое слово [1]: " "1 — remove lines with a space or tab, 2 — keep only the first word [1]: "
                read -r -p "$q" k || k=1
                [[ "${k// /}" == 2 ]] && k=first || k=remove
                TOOL_SUB=spaces; TOOL_OPTS=("$k")
                run_action tool "${PICKED[0]}"
                ;;
            8) pick_work_file one && { TOOL_SUB=trim; run_action tool "${PICKED[0]}"; } ;;
            9)
                pick_work_file one || continue
                out "  Строка уходит, если в ней есть хоть один кусок. Ищется как есть, большие и маленькие буквы различаются." "  A line goes if it has at least one of the pieces. They are searched as they are, upper and lower case differ."
                out "  Например: «- admin» — два куска, уйдут строки с дефисом и строки с admin; «-admin» — один кусок, только такое сочетание." "  For example: «- admin» is two pieces, lines with a hyphen and lines with admin go; «-admin» is one piece, only this exact combination."
                L q "Что искать: один или несколько кусков через пробел, Enter — назад: " "What to look for: one or several pieces separated by spaces, Enter — back: "
                read -r -p "$q" a || continue
                read -r -a pieces <<< "$a"
                (( ${#pieces[@]} > 0 )) || continue
                TOOL_SUB=filter; TOOL_OPTS=("${pieces[@]}")
                run_action tool "${PICKED[0]}"
                ;;
            10) pick_work_file one && { TOOL_SUB=alphabets; run_action tool "${PICKED[0]}"; } ;;
            11)
                pick_tool_files || continue
                L q "Сколько строк в результате [100]: " "How many lines in the result [100]: "
                read -r -p "$q" k || k=100
                k="${k// /}"
                [[ "$k" =~ ^[0-9]+$ ]] && (( 10#$k >= 1 )) || k=100
                TOOL_SUB=top; TOOL_OPTS=("$((10#$k))")
                run_action tool "${PICKED[@]}"
                ;;
            12) pick_work_file one && { TOOL_SUB=uniq; run_action tool "${PICKED[0]}"; } ;;
            13)
                L q "Какую строку искать, Enter — назад: " "Which line to look for, Enter — back: "
                read -r -p "$q" a || continue
                [[ -n "$a" ]] || continue
                tool_find_files
                if (( ${#TOOL_FILES[@]} == 0 )); then
                    out "${RED}✘ В папке нет словарей (*.txt)${NC}" "${RED}✘ No dictionaries (*.txt) in the folder${NC}"
                    continue
                fi
                TOOL_SUB=find; TOOL_OPTS=("$a")
                run_action tool "${TOOL_FILES[@]}"
                ;;
            14)
                pick_work_file one || continue
                L q "1 — вынести такие строки в <имя>_edge.txt и убрать из словаря, 2 — обрезать справа, 3 — обрезать слева, Enter — назад: " "1 — move such lines to <name>_edge.txt and remove them from the dictionary, 2 — trim on the right, 3 — trim on the left, Enter — back: "
                read -r -p "$q" k || continue
                case "${k// /}" in
                    1) k=move ;; 2) k=right ;; 3) k=left ;;
                    *) continue ;;
                esac
                TOOL_SUB=edge; TOOL_OPTS=("$k" ask)
                run_action tool "${PICKED[0]}"
                ;;
            15)
                pick_minus_files || continue
                TOOL_SUB=minus; TOOL_OPTS=()
                run_action tool "${PICKED[@]}"
                ;;
            "") ;;
            *) out "${YELLOW}Нет такого пункта: ${c}${NC}" "${YELLOW}No such item: ${c}${NC}" ;;
        esac
    done
}

# Running in WSL in a folder on a Windows drive (/mnt/<letter>)?
in_wsl_mnt() {
    case "${DEDUP_FORCE_WSL_MNT:-}" in
        1) return 0 ;;
        0) return 1 ;;
    esac
    grep -qi microsoft /proc/version 2>/dev/null || return 1
    [[ "$(pwd -P)" == /mnt/[a-z]/* ]]
}

# Free space on the Windows drive that holds the WSL disk (through reg.exe).
wsl_host_free() {
    grep -qi microsoft /proc/version 2>/dev/null || return 0
    local reg="" distro="" base letter m p v
    if ! reg="$(command -v reg.exe 2>/dev/null)"; then
        for m in /mnt/[a-z]; do
            [[ -x "$m/Windows/System32/reg.exe" ]] && { reg="$m/Windows/System32/reg.exe"; break; }
        done
    fi
    [[ -n "$reg" ]] || return 0
    distro="${WSL_DISTRO_NAME:-}"
    p="$PPID"
    while [[ -z "$distro" && "$p" =~ ^[0-9]+$ ]] && (( p > 1 )); do
        v="$(tr '\0' '\n' < "/proc/$p/environ" 2>/dev/null | sed -n 's/^WSL_DISTRO_NAME=//p')"
        [[ -n "$v" ]] && distro="$v"
        p="$(sed 's/.*) //' "/proc/$p/stat" 2>/dev/null | cut -d' ' -f2)"
    done
    base="$("$reg" query 'HKCU\Software\Microsoft\Windows\CurrentVersion\Lxss' /s </dev/null 2>/dev/null | tr -d '\r' | awk -v d="$distro" '
        function close_key() {
            if (name != "" && path != "") { n++; only = path; if (name == d && hit == "") hit = path }
            name = ""; path = ""
        }
        /^HKEY_/ { close_key() }
        $1 == "DistributionName" { name = $3 }
        $1 == "BasePath" { sub(/.*REG_(EXPAND_)?SZ[ \t]+/, ""); path = $0 }
        END { close_key(); if (hit != "") print hit; else if (n == 1) print only }')"
    base="${base#\\\\?\\}"
    [[ "$base" =~ ^([A-Za-z]): ]] || return 0
    letter="${BASH_REMATCH[1],,}"
    df -Pk "/mnt/$letter" 2>/dev/null | awk -v l="${letter^^}" 'NR == 2 { print l, $4 }'
}

declare -a WSL_ARGS=()
# Offer a Linux temp folder and copy the files there.
wsl_offer_temp() {
    local -a files=("$@") refs=()
    local f bytes=0 ref_bytes=0 need parent avail_kb stamp name dir n=2 q
    if (( ${#files[@]} == 0 )); then
        work_txt
        files=("${WORK_TXT[@]}")
    fi
    if [[ "$ACTION_KIND" != merge && "$ACTION_KIND" != tool ]]; then
        shopt -s nullglob
        refs=("$COMPARE_DIR"/*.txt)
        shopt -u nullglob
    fi
    local -A seen=()
    for f in "${files[@]}"; do
        if [[ -n "${seen[${f##*/}]:-}" ]]; then
            say "${YELLOW}⚠ Два файла с именем ${f##*/}: во временной папке Linux они затёрли бы друг друга — работаю на месте, будет медленно${NC}" "${YELLOW}⚠ Two files named ${f##*/}: in the Linux temp folder they would overwrite each other — working in place, it will be slow${NC}"
            return 1
        fi
        seen[${f##*/}]=1
    done
    for f in "${files[@]}"; do bytes=$(( bytes + $(file_size "$f") )); done
    for f in "${refs[@]}"; do ref_bytes=$(( ref_bytes + $(file_size "$f") )); done
    need=$(( bytes * 3 + ref_bytes ))
    parent="$WORK_ROOT"
    while [[ ! -d "$parent" ]]; do parent="$(dirname "$parent")"; done
    avail_kb="$(df -Pk "$parent" 2>/dev/null | awk 'NR == 2 { print $4 }')"
    local host host_kb
    host="$(wsl_host_free)"

    say "\n${YELLOW}⚠ Скрипт запущен в WSL, а папка лежит на диске Windows: $(pwd -P)${NC}" "\n${YELLOW}⚠ The script runs in WSL, but the folder is on a Windows drive: $(pwd -P)${NC}"
    say "  Через /mnt/<диск> построчная запись идёт в сотни раз медленнее: файл 107 МБ" "  Through /mnt/<drive> line-by-line writing is hundreds of times slower: a 107 MB file"
    say "  внутри Linux обрабатывается за ~4 с, а прямо на /mnt — больше 10 минут." "  takes ~4 s inside Linux and over 10 minutes right on /mnt."
    say "  Большой cp через /mnt быстрый: выгоднее скопировать файлы в Linux," "  A big cp through /mnt is fast: it pays to copy the files into Linux,"
    say "  обработать там и вернуть только итог." "  process them there and copy back only the result."
    if [[ -n "$avail_kb" ]]; then
        say "  Свободно внутри Linux: $(fmt_size $(( avail_kb * 1024 ))), нужно примерно $(fmt_size "$need")" "  Free inside Linux: $(fmt_size $(( avail_kb * 1024 ))), needed about $(fmt_size "$need")"
    fi
    if [[ -n "$host" ]]; then
        host_kb="${host##* }"
        say "  Диск Linux (ext4.vhdx) лежит на ${host%% *}: — там свободно $(fmt_size $(( host_kb * 1024 )))" "  The Linux disk (ext4.vhdx) is on ${host%% *}: — free there: $(fmt_size $(( host_kb * 1024 )))"
        [[ -z "$avail_kb" ]] || (( host_kb < avail_kb )) && avail_kb="$host_kb"
    elif [[ -n "$avail_kb" ]]; then
        say "  (это предел диска Linux; сколько свободно на диске Windows, где он лежит, узнать не удалось)" "  (this is the Linux disk limit; the free space on the Windows drive that holds it is unknown)"
    fi
    L q "Работать во временной папке Linux (${WORK_ROOT})?" "Work in a Linux temp folder (${WORK_ROOT})?"
    if ! confirm_action "$q" y "" "$DEFAULT_TIMEOUT"; then
        say "${YELLOW}Работаю на месте — будет медленно${NC}" "${YELLOW}Working in place — it will be slow${NC}"
        return 1
    fi
    if [[ -n "$avail_kb" ]] && (( avail_kb * 1024 < need )); then
        say "${RED}✘ Внутри Linux не хватает места (нужно ~$(fmt_size "$need")) — работаю на месте, медленно${NC}" "${RED}✘ Not enough space inside Linux (needed ~$(fmt_size "$need")) — working in place, slowly${NC}" >&2
        return 1
    fi

    printf -v stamp '%(%Y%m%d-%H%M%S)T' -1
    if (( ${#files[@]} == 1 )); then name="$(final_base "${files[0]}")"; else name="${ACTION_KIND:-compare}"; fi
    dir="$WORK_ROOT/${name}_${stamp}"
    while [[ -e "$dir" ]]; do dir="$WORK_ROOT/${name}_${stamp}_${n}"; n=$((n + 1)); done
    local total=$(( bytes + ref_bytes )) t0
    local -a dst=()
    for f in "${files[@]}"; do dst+=("$dir/${f##*/}"); done
    for f in "${refs[@]}"; do dst+=("$dir/$COMPARE_DIR/${f##*/}"); done
    if (( total >= 1073741824 )); then
        say "  Копирую $(fmt_size "$total"): через мост WSL обычно около 100 МБ/с — примерно $(fmt_dur $(( total / 100000 )))" "  Copying $(fmt_size "$total"): through the WSL bridge usually about 100 MB/s — roughly $(fmt_dur $(( total / 100000 )))"
    fi
    ms_now; t0=$REPLY
    if ! mkdir -p "$dir/$COMPARE_DIR"; then
        say "${RED}✘ Не удалось скопировать файлы в $dir — работаю на месте${NC}" "${RED}✘ Could not copy the files to $dir — working in place${NC}" >&2
        return 1
    fi
    L q "копирование в папку Linux" "copying to the Linux folder"
    progress_start "$q" "$total" size "${dst[@]}"
    if ! cp -p -- "${files[@]}" "$dir/" \
       || { (( ${#refs[@]} > 0 )) && ! cp -p -- "${refs[@]}" "$dir/$COMPARE_DIR/"; }; then
        progress_stop
        say "${RED}✘ Не удалось скопировать файлы в $dir — работаю на месте${NC}" "${RED}✘ Could not copy the files to $dir — working in place${NC}" >&2
        return 1
    fi
    progress_stop
    ms_now
    WSL_ARGS=()
    for f in "${files[@]}"; do WSL_ARGS+=("${f##*/}"); done
    WSL_TEMP_DIR="$dir"
    FINAL_DIR="$ACTION_ORIG_DIR"
    cd "$dir" || return 1
    say "${GREEN}✓ Скопировано в $dir ($(fmt_size "$total") за $(fmt_dur $(( REPLY - t0 ))))${NC}" "${GREEN}✓ Copied to $dir ($(fmt_size "$total") in $(fmt_dur $(( REPLY - t0 ))))${NC}"
}

WSL_COPY_NOTE=""
# Copy one file back from the temp folder, with progress.
wsl_copy_back() {
    local src="$1" dst="$2" sz t0 q
    sz=$(file_size "$src")
    [[ -d "$dst" ]] && dst="$dst/${src##*/}"
    WSL_COPY_NOTE=""
    ms_now; t0=$REPLY
    L q "возврат ${src##*/}" "copying back ${src##*/}"
    progress_start "$q" "$sz" size "$dst"
    cp -p -- "$src" "$dst" || { progress_stop; return 1; }
    progress_stop
    ms_now
    (( sz >= 104857600 )) && L WSL_COPY_NOTE "$(fmt_size "$sz") за $(fmt_dur $(( REPLY - t0 )))" "$(fmt_size "$sz") in $(fmt_dur $(( REPLY - t0 )))"
    return 0
}

# Copy the results and fixed references back to the source folder.
wsl_return() {
    local orig="$ACTION_ORIG_DIR" f name base n_back=0
    WSL_RETURNED=(); WSL_REFS_BACK=true
    say "\n${YELLOW}Возврат результатов в ${orig}...${NC}" "\n${YELLOW}Copying the results back to ${orig}...${NC}"
    for f in "${RESULT_FILES[@]}"; do
        [[ -e "$f" ]] || continue
        if wsl_copy_back "$f" "$orig/${f##*/}"; then
            WSL_RETURNED+=("$f")
            n_back=$((n_back + 1))
            say "  ✔ ${f##*/}${WSL_COPY_NOTE:+ (${WSL_COPY_NOTE})}"
        else
            say "${RED}  ✘ Не удалось скопировать ${f##*/} — он остался во временной папке${NC}" "${RED}  ✘ Could not copy ${f##*/} — it stays in the temp folder${NC}" >&2
        fi
    done
    for f in "$COMPARE_DIR/$UNSORTED_DIR"/*.txt; do
        [[ -f "$f" ]] || continue
        name="${f##*/}"
        base="${name%.txt}"
        [[ -f "$COMPARE_DIR/${base}_sorted.txt" && -f "$orig/$COMPARE_DIR/$name" ]] || continue
        if wsl_copy_back "$COMPARE_DIR/${base}_sorted.txt" "$orig/$COMPARE_DIR/" \
           && mkdir -p "$orig/$COMPARE_DIR/$UNSORTED_DIR" \
           && mv -f -- "$orig/$COMPARE_DIR/$name" "$orig/$COMPARE_DIR/$UNSORTED_DIR/"; then
            n_back=$((n_back + 1))
            say "  ✔ эталон ${base}_sorted.txt (${WSL_COPY_NOTE:+${WSL_COPY_NOTE}; }оригинал — в $COMPARE_DIR/$UNSORTED_DIR/)" "  ✔ reference ${base}_sorted.txt (${WSL_COPY_NOTE:+${WSL_COPY_NOTE}; }the original is in $COMPARE_DIR/$UNSORTED_DIR/)"
        else
            WSL_REFS_BACK=false
            say "${RED}  ✘ Не удалось вернуть пересортированный эталон ${base}_sorted.txt${NC}" "${RED}  ✘ Could not copy back the re-sorted reference ${base}_sorted.txt${NC}" >&2
        fi
    done
    for f in "$COMPARE_DIR"/*.txt; do
        [[ -f "$f" ]] || continue
        name="${f##*/}"
        [[ -f "$orig/$COMPARE_DIR/$name" ]] || continue
        (( $(file_size "$f") == $(file_size "$orig/$COMPARE_DIR/$name") )) && continue
        if wsl_copy_back "$f" "$orig/$COMPARE_DIR/$name"; then
            n_back=$((n_back + 1))
            say "  ✔ эталон $name (без CRLF/BOM${WSL_COPY_NOTE:+; ${WSL_COPY_NOTE}})" "  ✔ reference $name (without CRLF/BOM${WSL_COPY_NOTE:+; ${WSL_COPY_NOTE}})"
        else
            WSL_REFS_BACK=false
            say "${RED}  ✘ Не удалось вернуть эталон $name${NC}" "${RED}  ✘ Could not copy back the reference $name${NC}" >&2
        fi
    done
    (( n_back > 0 )) || say "  возвращать нечего" "  nothing to copy back"
}

# Delete the copies left in the temp folder.
wsl_drop_copies() {
    local f r keep
    [[ -n "$WSL_TEMP_DIR" && "$(pwd -P)" == "$(cd "$WSL_TEMP_DIR" 2>/dev/null && pwd -P)" ]] || return 0
    for f in "${WSL_ARGS[@]}" "${WSL_RETURNED[@]}"; do
        keep=false
        for r in "${RESULT_FILES[@]}"; do [[ "$r" == "$f" ]] && keep=true; done
        for r in "${WSL_RETURNED[@]}"; do [[ "$r" == "$f" ]] && keep=false; done
        $keep && continue
        [[ -f "$f" ]] && rm -f -- "$f"
    done
    if $WSL_REFS_BACK; then
        rm -rf -- "$COMPARE_DIR"
    else
        say "${YELLOW}⚠ Эталоны вернулись не все — их копии оставлены во временной папке${NC}" "${YELLOW}⚠ Not all references came back — their copies stay in the temp folder${NC}"
    fi
}

# Same content? The first and last 1 MB, then the whole files in 8 MB blocks.
same_content() {
    local a="$1" b="$2" size="${3:-0}"
    cmp -s <(head -c 1048576 -- "$a") <(head -c 1048576 -- "$b") || return 1
    cmp -s <(tail -c 1048576 -- "$a") <(tail -c 1048576 -- "$b") || return 1
    (( size <= 2097152 )) && return 0
    say "  Сверяю ${a} с эталоном ${b}: размер тот же ($(fmt_size "$size")), сравниваю целиком…" "  Comparing ${a} with the reference ${b}: same size ($(fmt_size "$size")), comparing in full…"
    cmp -s <(dd if="$a" bs=8M status=none) <(dd if="$b" bs=8M status=none)
}

# Archive type by the first bytes (gzip, zip, 7z, rar, bzip2, xz, zstd), or nothing.
archive_kind() {
    local h
    h="$(od -An -tx1 -N10 -- "$1" 2>/dev/null | tr -d ' \n')"
    case "$h" in
        1f8b*)                            echo gzip ;;
        504b0304*|504b0506*|504b0708*)    echo zip ;;
        377abcaf271c*)                    echo 7z ;;
        526172211a07*)                    echo rar ;;
        425a683[1-9]314159265359*)        echo bzip2 ;;
        fd377a585a00*)                    echo xz ;;
        28b52ffd*)                        echo zstd ;;
    esac
}

# Do not start on archives disguised as .txt; tell how to unpack them.
check_archives() {
    local f k cmd found=false
    for f in "$@"; do
        [[ -f "$f" ]] || continue
        k="$(archive_kind "$f")"
        [[ -n "$k" ]] || continue
        found=true
        case "$k" in
            gzip|bzip2|xz|zstd)
                [[ "$k" == gzip ]] && cmd=gzip || cmd="$k"
                say "${RED}✘ ${f} — это архив ${k}, а не текст. Распакуйте: ${cmd} -dc \"${f}\" > \"${f%.*}_unpacked.txt\" (или 7-Zip)${NC}" "${RED}✘ ${f} is a ${k} archive, not text. Unpack it: ${cmd} -dc \"${f}\" > \"${f%.*}_unpacked.txt\" (or 7-Zip)${NC}" ;;
            *)
                say "${RED}✘ ${f} — это архив ${k}, а не текст. Распакуйте его архиватором (7-Zip) и запустите снова${NC}" "${RED}✘ ${f} is a ${k} archive, not text. Unpack it with an archiver (7-Zip) and run again${NC}" ;;
        esac
    done
    $found && return 1
    return 0
}

# Warn if a working file is a byte-for-byte copy of a reference.
check_ref_copies() {
    local f r fs found=false
    local -a refs=()
    shopt -s nullglob
    refs=("$COMPARE_DIR"/*.txt)
    shopt -u nullglob
    (( ${#refs[@]} > 0 )) || return 0
    for f in "$@"; do
        [[ -f "$f" ]] || continue
        fs=$(file_size "$f")
        (( fs > 0 )) || continue
        for r in "${refs[@]}"; do
            (( $(file_size "$r") == fs )) || continue
            same_content "$f" "$r" "$fs" || continue
            say "${YELLOW}⚠ ${f} — копия эталона ${r}: сравнится сам с собой, итог будет пустым${NC}" "${YELLOW}⚠ ${f} is a copy of the reference ${r}: it would be compared with itself, the result would be empty${NC}"
            found=true
            break
        done
    done
    $found || return 0
    say "  Чтобы очистить словари друг от друга, уберите их копии из '${COMPARE_DIR}/'." "  To clean dictionaries of each other, remove their copies from '${COMPARE_DIR}/'."
    local q
    L q "Всё равно продолжить?" "Continue anyway?"
    confirm_action "$q" n
}

declare -a UNIQ_FILES=()
# Arguments without repeated files into UNIQ_FILES.
uniq_files() {
    local f g dup
    UNIQ_FILES=()
    for f in "$@"; do
        [[ -f "$f" ]] || { say "${RED}Ошибка: нет файла $f${NC}" "${RED}Error: no file $f${NC}" >&2; return 1; }
        dup=false
        for g in "${UNIQ_FILES[@]}"; do [[ "$g" -ef "$f" ]] && dup=true; done
        if $dup; then
            say "${YELLOW}⚠ ${f} указан дважды — беру один раз${NC}" "${YELLOW}⚠ ${f} is given twice — taking it once${NC}"
        else
            UNIQ_FILES+=("$f")
        fi
    done
}

# One action: checks, log, WSL temp folder, the command, results back, log footer.
run_action() {
    local kind="$1" t
    shift
    local -a args=("$@")
    local rc name f log_kind="$kind"
    case "$kind" in
        full|clean|split)
            if [[ -z "${args[0]:-}" || ! -f "${args[0]}" ]]; then
                say "${RED}Ошибка: укажите существующий файл (${SCRIPT_NAME} ${kind} <file>)${NC}" "${RED}Error: give an existing file (${SCRIPT_NAME} ${kind} <file>)${NC}" >&2
                return 1
            fi
            ;;
        tool)
            if (( ${#args[@]} == 0 )); then
                say "${RED}Ошибка: нет файлов для работы${NC}" "${RED}Error: no files to work on${NC}" >&2
                return 1
            fi
            for f in "${args[@]}"; do
                [[ -f "$f" ]] || { say "${RED}Ошибка: нет файла $f${NC}" "${RED}Error: no file $f${NC}" >&2; return 1; }
            done
            log_kind="$TOOL_SUB"
            ;;
        compare)
            for f in "${args[@]}"; do
                [[ -f "$f" ]] || { say "${RED}Ошибка: нет файла $f${NC}" "${RED}Error: no file $f${NC}" >&2; return 1; }
            done
            ;;
        queue)
            uniq_files "${args[@]}" || return 1
            args=("${UNIQ_FILES[@]}")
            if (( ${#args[@]} < 2 )); then
                say "${RED}Ошибка: для очереди нужны хотя бы два разных файла (${SCRIPT_NAME} queue <file1> <file2> ...)${NC}" "${RED}Error: a queue needs at least two different files (${SCRIPT_NAME} queue <file1> <file2> ...)${NC}" >&2
                return 1
            fi
            ;;
        merge)
            if (( ${#args[@]} == 0 )); then
                shopt -s nullglob
                for f in *.txt; do is_final "$f" && args+=("$f"); done
                shopt -u nullglob
            fi
            uniq_files "${args[@]}" || return 1
            args=("${UNIQ_FILES[@]}")
            if (( ${#args[@]} < 2 )); then
                say "${RED}Ошибка: объединять нечего — нужны хотя бы два разных файла (${SCRIPT_NAME} merge [file...]; без файлов — все итоги _final)${NC}" "${RED}Error: nothing to merge — at least two different files are needed (${SCRIPT_NAME} merge [file...]; without files — all _final results)${NC}" >&2
                return 1
            fi
            ;;
    esac
    RESULT_FILES=(); ACTION_FILES=(); FINAL_DIR=""; WSL_TEMP_DIR=""
    EXTRA_REFS=(); QUEUE_REFS=(); QUEUE_REF_SKIP=(); QUEUE_REFS_READY=false; QUEUE_ON=false
    MEMO=(); MEMO_NEW=(); MEMO_ON=false
    ACTION_KIND="$kind"
    ACTION_ORIG_DIR="$(pwd)"
    if (( ${#args[@]} == 0 )) || [[ "$kind" == compare && ${#args[@]} -gt 1 ]]; then
        name="compare"
    else
        name="$(basename "${args[0]%.*}")"
    fi
    ms_now; LOG_T0=$REPLY
    if [[ "$kind" == tool ]]; then
        [[ "$TOOL_SUB" == find ]] && name=search
        log_open "$log_kind" "$name" "${args[@]}" "${TOOL_OPTS[@]}"
    else
        log_open "$kind" "$name" "${args[@]}"
    fi
    echo
    [[ -n "$LOG_FILE" ]] && out "Лог: ${LOG_FILE#"$ACTION_ORIG_DIR"/}" "Log: ${LOG_FILE#"$ACTION_ORIG_DIR"/}"

    local -a chk=("${args[@]}")
    if [[ "$kind" == compare ]] && (( ${#chk[@]} == 0 )); then work_txt; chk=("${WORK_TXT[@]}"); fi
    local -a arch=("${chk[@]}")
    [[ "$kind" == tool && "$TOOL_SUB" == find ]] && arch=()
    if [[ "$kind" == full || "$kind" == compare || "$kind" == queue ]]; then
        shopt -s nullglob
        arch+=("$COMPARE_DIR"/*.txt)
        shopt -u nullglob
    fi
    if ! check_archives "${arch[@]}"; then
        say "\n${YELLOW}Отменено — ничего не сделано${NC}" "\n${YELLOW}Cancelled — nothing done${NC}"
        L t "отменено (архив)" "cancelled (archive)"; log_footer "$t"
        [[ -n "$LOG_FILE" ]] && out "Лог: ${LOG_FILE#"$ACTION_ORIG_DIR"/}" "Log: ${LOG_FILE#"$ACTION_ORIG_DIR"/}"
        LOG_FILE=""
        return 1
    fi
    if [[ "$kind" == full || "$kind" == compare || "$kind" == queue ]]; then
        if ! check_ref_copies "${chk[@]}"; then
            say "\n${YELLOW}Отменено — ничего не сделано${NC}" "\n${YELLOW}Cancelled — nothing done${NC}"
            L t "отменено" "cancelled"; log_footer "$t"
            [[ -n "$LOG_FILE" ]] && out "Лог: ${LOG_FILE#"$ACTION_ORIG_DIR"/}" "Log: ${LOG_FILE#"$ACTION_ORIG_DIR"/}"
            LOG_FILE=""
            return 1
        fi
    fi
    local -a orig_args=("${args[@]}")

    if [[ "$kind" != split && ! ( "$kind" == tool && "$TOOL_SUB" == find ) ]] && in_wsl_mnt; then
        if wsl_offer_temp "${args[@]}"; then
            args=("${WSL_ARGS[@]}")
        fi
    fi

    ACTION_FILES=("${args[@]}")
    case "$kind" in
        full)    cmd_full "${args[@]}" ;;
        clean)   cmd_clean "${args[@]}" ;;
        compare) cmd_compare "${args[@]}" ;;
        split)   cmd_split "${args[@]}" ;;
        queue)   cmd_queue "${args[@]}" ;;
        merge)   cmd_merge "${args[@]}" ;;
        tool)    cmd_tool "${args[@]}" ;;
    esac
    rc=$?

    if [[ -n "$WSL_TEMP_DIR" ]]; then
        wsl_return
        wsl_drop_copies
        cd "$ACTION_ORIG_DIR" || true
        if rmdir -- "$WSL_TEMP_DIR" 2>/dev/null; then
            say "Временная папка пуста — удалена: $WSL_TEMP_DIR" "The temp folder is empty — deleted: $WSL_TEMP_DIR"
        else
            say "${YELLOW}Временная папка не пуста — там то, что не удалось вернуть или удалить (см. выше): $WSL_TEMP_DIR${NC}" "${YELLOW}The temp folder is not empty — it holds what could not be copied back or deleted (see above): $WSL_TEMP_DIR${NC}"
        fi
    fi
    [[ "$kind" == queue ]] && (( rc == 0 )) && move_originals "${orig_args[@]}"
    ms_now
    if (( rc == 0 )); then
        say "\n${GREEN}Готово за $(fmt_dur $(( REPLY - LOG_T0 )))${NC}" "\n${GREEN}Done in $(fmt_dur $(( REPLY - LOG_T0 )))${NC}"
        L t "готово" "done"; log_footer "$t"
    else
        say "\n${RED}Завершено с ошибкой (код ${rc}) за $(fmt_dur $(( REPLY - LOG_T0 )))${NC}" "\n${RED}Finished with an error (code ${rc}) in $(fmt_dur $(( REPLY - LOG_T0 )))${NC}" >&2
        L t "ошибка (код ${rc})" "error (code ${rc})"; log_footer "$t"
    fi
    [[ -n "$LOG_FILE" ]] && out "Лог: ${LOG_FILE#"$ACTION_ORIG_DIR"/}" "Log: ${LOG_FILE#"$ACTION_ORIG_DIR"/}"
    LOG_FILE=""
    WSL_TEMP_DIR=""
    return "$rc"
}

# Menu header: the folder, working files and references.
menu_header() {
    local -a files=() refs=()
    local f n=0 mark
    shopt -s nullglob
    files=(*.txt)
    refs=("$COMPARE_DIR"/*.txt)
    shopt -u nullglob
    echo
    echo -e "${CYAN}════════════════════════════════════════════════════════════${NC}"
    echo -e "${CYAN} ${SCRIPT_NAME} v${VERSION}${NC}   $(pwd)"
    if (( ${#files[@]} == 0 )); then
        out " ${YELLOW}Рабочих файлов (*.txt) в папке нет${NC}" " ${YELLOW}No working files (*.txt) in the folder${NC}"
    else
        out " Рабочие файлы:" " Working files:"
        for f in "${files[@]}"; do
            n=$((n + 1))
            if (( n > 6 )); then
                out "   … и ещё $(( ${#files[@]} - 6 ))" "   … and $(( ${#files[@]} - 6 )) more"
                break
            fi
            mark="$(file_mark "$f")"
            echo "   ${f} ($(fmt_size "$(file_size "$f")"))${mark}"
        done
    fi
    if [[ -d "$COMPARE_DIR" ]]; then
        out " Эталонов в ${COMPARE_DIR}/: ${#refs[@]}" " References in ${COMPARE_DIR}/: ${#refs[@]}"
    else
        out " ${YELLOW}Папки ${COMPARE_DIR}/ нет — сравнивать не с чем${NC}" " ${YELLOW}No ${COMPARE_DIR}/ folder — nothing to compare with${NC}"
    fi
    echo -e "${CYAN}════════════════════════════════════════════════════════════${NC}"
}

declare -a PICKED=()
# Choose a working file (or all files) into PICKED.
pick_work_file() {
    local mode="$1" choice i mark q
    local -a files=()
    shopt -s nullglob
    files=(*.txt)
    shopt -u nullglob
    PICKED=()
    if (( ${#files[@]} == 0 )); then
        out "${RED}✘ В папке нет рабочих файлов (*.txt)${NC}" "${RED}✘ No working files (*.txt) in the folder${NC}"
        return 1
    fi
    if (( ${#files[@]} == 1 )); then
        PICKED=("${files[0]}")
        out "Рабочий файл: ${files[0]}" "Working file: ${files[0]}"
        return 0
    fi
    out "Выберите рабочий файл:" "Choose a working file:"
    for i in "${!files[@]}"; do
        mark="$(file_mark "${files[i]}")"
        echo "  $((i + 1))) ${files[i]} ($(fmt_size "$(file_size "${files[i]}")"))${mark}"
    done
    [[ "$mode" == many ]] && out "  a) все файлы (кроме списков объединения)" "  a) all files (except merge lists)"
    out "  0) назад в меню" "  0) back to the menu"
    while true; do
        L q "Номер: " "Number: "
        read -r -p "$q" choice || return 1
        choice="${choice// /}"
        if [[ "$choice" == 0 ]]; then
            return 1
        elif [[ "$mode" == many && ( "$choice" == [aA*] || "$choice" == "а" || "$choice" == "все" || "$choice" == "all" ) ]]; then
            work_txt
            PICKED=("${WORK_TXT[@]}")
            return 0
        elif [[ "$choice" =~ ^[0-9]+$ ]] && (( 10#$choice >= 1 && 10#$choice <= ${#files[@]} )); then
            PICKED=("${files[10#$choice - 1]}")
            return 0
        fi
        out "Введите номер из списка" "Type a number from the list"
    done
}

# Choose several files in order (queue, merge) into PICKED.
pick_many_files() {
    local mode="$1" choice i k f dup ok again="" def_text q
    local -a files=() parts=() defs=()
    shopt -s nullglob
    files=(*.txt)
    shopt -u nullglob
    PICKED=()
    if [[ "$mode" == queue ]] && (( ${#files[@]} > 1 )); then
        mapfile -t files < <(for f in "${files[@]}"; do printf '%s\t%s\n' "$(file_size "$f")" "$f"; done \
                             | LC_ALL=C sort -t "$TAB_CHR" -k1,1nr -k2,2 | LC_ALL=C cut -f2-)
    fi
    for f in "${files[@]}"; do
        if [[ "$mode" == merge ]]; then
            is_final "$f" && defs+=("$f")
        else
            is_final "$f" || is_merged "$f" || is_list "$f" || is_side "$f" || defs+=("$f")
        fi
    done
    if (( ${#files[@]} < 2 )); then
        out "${RED}✘ Нужны хотя бы два файла (*.txt), а в папке их ${#files[@]}${NC}" "${RED}✘ At least two files (*.txt) are needed, the folder has ${#files[@]}${NC}"
        return 1
    fi
    if [[ "$mode" == merge ]]; then
        out "${CYAN}Объединение итогов${NC}" "${CYAN}Merging results${NC}"
        out "Файлы склеятся в один без повторов — merged.txt, а рядом появится" "The files are joined into one without duplicates — merged.txt, and next to it"
        out "merged_list.txt со списком файлов. Если такие уже есть — merged_2.txt и т.д." "merged_list.txt with the list of files. If they exist — merged_2.txt and so on."
        L def_text "все итоги _final (${#defs[@]})" "all _final results (${#defs[@]})"
    else
        out "${CYAN}Несколько словарей по очереди${NC}" "${CYAN}Several dictionaries in a queue${NC}"
        out "Файлы пойдут по очереди: первый останется целым, каждый следующий" "The files go one after another: the first stays whole, each next one"
        out "очистится от эталонов и от итогов всех предыдущих. После очереди исходные" "is cleaned of the references and of the results of all previous ones. After the queue"
        out "словари уйдут в папку originals_<дата-время>/, в рабочей папке останутся итоги." "the source dictionaries go to originals_<date-time>/, the results stay in the working folder."
        out "Список — от большого файла к меньшему: так больше строк останется в большом." "The list goes from the biggest file to the smallest: this way more lines stay in the big one."
        L def_text "все по списку, кроме итогов" "all in the list except results"
    fi
    echo
    for i in "${!files[@]}"; do
        echo -e "  ${CYAN}$((i + 1)))${NC} ${files[i]} ($(fmt_size "$(file_size "${files[i]}")"))${YELLOW}$(file_mark "${files[i]}")${NC}"
    done
    out "  ${CYAN}0)${NC} назад в меню" "  ${CYAN}0)${NC} back to the menu"
    while true; do
        if [[ -n "$again" ]]; then
            choice="$again"; again=""
        else
            L q "Номера в нужном порядке через пробел (например 3 1 2), Enter — ${def_text}: " "Numbers in the order you want, separated by spaces (for example 3 1 2), Enter — ${def_text}: "
            read -r -p "$q" choice || return 1
        fi
        read -r -a parts <<< "${choice//,/ }"
        [[ "${parts[*]}" == 0 ]] && return 1
        PICKED=(); ok=true
        if (( ${#parts[@]} == 0 )); then
            PICKED=("${defs[@]}")
        else
            for k in "${parts[@]}"; do
                if ! [[ "$k" =~ ^[0-9]+$ ]] || (( 10#$k < 1 || 10#$k > ${#files[@]} )); then ok=false; break; fi
                f="${files[10#$k - 1]}"
                dup=false
                for i in "${PICKED[@]}"; do [[ "$i" == "$f" ]] && dup=true; done
                $dup || PICKED+=("$f")
            done
        fi
        if ! $ok; then
            out "${YELLOW}Введите номера из списка через пробел${NC}" "${YELLOW}Type numbers from the list separated by spaces${NC}"
        elif (( ${#PICKED[@]} < 2 )) && [[ "$mode" == merge ]]; then
            out "${YELLOW}Нужно хотя бы два файла — укажите номера${NC}" "${YELLOW}At least two files are needed — type their numbers${NC}"
        elif (( ${#PICKED[@]} < 2 )); then
            out "${YELLOW}Нужно хотя бы два файла: для одного — пункт 1${NC}" "${YELLOW}At least two files are needed: for one file use item 1${NC}"
        else
            echo
            if [[ "$mode" == merge ]]; then
                out "${GREEN}Будут объединены:${NC}" "${GREEN}Will be merged:${NC}"
            else
                out "${GREEN}Порядок (первый останется целым):${NC}" "${GREEN}Order (the first stays whole):${NC}"
            fi
            for i in "${!PICKED[@]}"; do echo -e "  ${GREEN}$((i + 1)).${NC} ${PICKED[i]}"; done
            L q "Enter — начать, 0 — назад в меню, или другие номера: " "Enter — start, 0 — back to the menu, or other numbers: "
            read -r -p "$q" choice || return 1
            [[ -z "${choice// /}" ]] && return 0
            [[ "${choice// /}" == 0 ]] && return 1
            again="$choice"
        fi
    done
}

# Menu item 8: choose the interface language and save it to LANG_FILE.
lang_menu() {
    local c q
    echo "  1) Русский"
    echo "  2) English"
    if ! read -r -p "Язык / Language [1/2]: " c; then echo; return 0; fi
    case "${c// /}" in
        1|ru|RU) UI_LANG=ru ;;
        2|en|EN) UI_LANG=en ;;
        *) return 0 ;;
    esac
    if mkdir -p "${LANG_FILE%/*}" 2>/dev/null && printf '%s\n' "$UI_LANG" > "$LANG_FILE" 2>/dev/null; then
        out "${GREEN}✓ Язык: русский — запомнен (${LANG_FILE})${NC}" "${GREEN}✓ Language: English — saved (${LANG_FILE})${NC}"
    else
        out "${YELLOW}⚠ Язык: русский — до выхода из скрипта: не удалось записать ${LANG_FILE}${NC}" "${YELLOW}⚠ Language: English — until the script exits: could not write ${LANG_FILE}${NC}"
    fi
}

# Main menu loop.
main_menu() {
    local choice spec q
    while true; do
        menu_header
        out "  1) Полная обработка: подготовка и сравнение с эталонами → <имя>_final.txt" "  1) Full processing: preparation and comparison with references → <name>_final.txt"
        out "  2) Только подготовка (кодировка, CRLF/BOM, фильтры) → <имя>_prep.txt" "  2) Preparation only (encoding, CRLF/BOM, filters) → <name>_prep.txt"
        out "  3) Только сравнение с эталонами, файл как есть → <имя>_final.txt" "  3) Comparison with references only, the file as is → <name>_final.txt"
        out "  4) Несколько словарей по очереди: каждый чистится и от предыдущих → _final у каждого" "  4) Several dictionaries in a queue: each is also cleaned of the previous ones → _final for each"
        out "  5) Объединить итоги _final в один файл → merged.txt и список файлов merged_list.txt" "  5) Merge _final results into one file → merged.txt and the list of files merged_list.txt"
        out "  6) Разделить готовый файл на части" "  6) Split a finished file into parts"
        out "  7) Работа со словарями: логины, раскладка, регистр, алфавиты, поиск…" "  7) Dictionary tools: logins, keyboard layout, case, alphabets, search…"
        out "  8) Язык / Language: русский" "  8) Language / Язык: English"
        out "  9) Справка" "  9) Help"
        out "  0) Выход" "  0) Exit"
        L q "Выберите пункт: " "Choose an item: "
        if ! read -r -p "$q" choice; then
            echo
            exit 0
        fi
        [[ -n "${choice// /}" ]] && echo
        case "${choice// /}" in
            1) pick_work_file one && run_action full "${PICKED[0]}" ;;
            2) pick_work_file one && run_action clean "${PICKED[0]}" ;;
            3) pick_work_file many && run_action compare "${PICKED[@]}" ;;
            4) pick_many_files queue && run_action queue "${PICKED[@]}" ;;
            5) pick_many_files merge && run_action merge "${PICKED[@]}" ;;
            6)
                if pick_work_file one; then
                    L q "Число частей (например 4) или размер части (500M, 2G), Enter — по ${DEFAULT_SPLIT_SIZE}: " "Number of parts (for example 4) or part size (500M, 2G), Enter — ${DEFAULT_SPLIT_SIZE} each: "
                    read -r -p "$q" spec || spec=""
                    run_action split "${PICKED[0]}" "${spec:-$DEFAULT_SPLIT_SIZE}"
                fi
                ;;
            7) tools_menu ;;
            8) lang_menu ;;
            9) show_help ;;
            0) exit 0 ;;
            "") ;;
            *) out "${YELLOW}Нет такого пункта: ${choice}${NC}" "${YELLOW}No such item: ${choice}${NC}" ;;
        esac
    done
}

# Entry point: the menu, --help, --version or a hidden command.
case "${1:-}" in
    "")
        main_menu
        ;;
    --version|-v)
        echo "${SCRIPT_NAME} v${VERSION}"
        exit 0
        ;;
    --help|-h|help)
        show_help
        exit 0
        ;;
    tool)
        shift
        tool_cli "$@"
        exit $?
        ;;
    full|clean|compare|split|queue|merge)
        cmd="$1"
        shift
        run_action "$cmd" "$@"
        exit $?
        ;;
    *)
        out "${RED}Неизвестная команда: $1${NC}" "${RED}Unknown command: $1${NC}" >&2
        show_help
        exit 1
        ;;
esac

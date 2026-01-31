#!/usr/bin/env bash
#
# converttext.sh
#
# Recursively or non‑recursively process files, detect text vs binary,
# detect current encoding and line endings, and convert to requested
# encoding and/or line endings.
#

############################################
# HELP
############################################
show_help() {
    cat <<EOF
Usage: $0 [options] file_or_directory [...]

Options:
  -r        Process directories recursively
  -v        Verbose output
  -n        Dry run (no changes)
  -h        Show this help

Line ending options (mutually exclusive):
  -w        Convert to Windows (CRLF)
  -m        Convert to Macintosh (CR)
  -u        Convert to Unix (LF)

Encoding options (mutually exclusive):
  -a        Convert to ASCII
  -8        Convert to UTF-8
  -s        Convert to UTF-16
EOF
}

############################################
# DEPENDENCY CHECK
############################################
required_tools=(file iconv perl find mktemp grep wc tr)

missing=()
for tool in "${required_tools[@]}"; do
    if ! command -v "$tool" >/dev/null 2>&1; then
        missing+=("$tool")
    fi
done

if [[ ${#missing[@]} -gt 0 ]]; then
    echo "Missing required tools:"
    for m in "${missing[@]}"; do echo "  - $m"; done
    echo "Aborting."
    exit 1
fi

############################################
# ARGUMENT PARSING
############################################
recursive=0
verbose=0
dry_run=0
ending=""
encoding=""

while getopts "rvnhwmu8as" opt; do
    case "$opt" in
        r) recursive=1 ;;
        v) verbose=1 ;;
        n) dry_run=1 ;;
        h) show_help; exit 0 ;;
        w) ending="CRLF" ;;
        m) ending="CR" ;;
        u) ending="LF" ;;
        a) encoding="ASCII" ;;
        8) encoding="UTF-8" ;;
        s) encoding="UTF-16" ;;
        *) show_help; exit 1 ;;
    esac
done
shift $((OPTIND - 1))

if [[ -z "$ending" && -z "$encoding" ]]; then
    echo "No line ending or encoding specified - nothing to do"
    show_help
    exit 1
fi

if [[ $# -eq 0 ]]; then
    echo "No files or directories specified."
    show_help
    exit 1
fi

############################################
# UTILITY FUNCTIONS
############################################
run_cmd() {
    if [[ $verbose -eq 1 ]]; then "$@"; else "$@" >/dev/null 2>&1; fi
}

# Binary detection using file -b
is_binary() {
    local info
    info=$(file -b "$1")
    if echo "$info" | grep -qiE "text|source|utf|ascii|unicode"; then
        return 1
    fi
    return 0
}

detect_encoding() {
    local info
    info=$(file -b "$1")
    if echo "$info" | grep -qi "utf-16"; then echo "UTF-16"; return; fi
    if echo "$info" | grep -qi "utf-8"; then echo "UTF-8"; return; fi
    if echo "$info" | grep -qi "ascii"; then echo "ASCII"; return; fi
    echo "UNKNOWN"
}

############################################
# CORRECT LINE ENDING DETECTION
############################################
detect_line_ending() {
    local file="$1"

    # Count CRLF
    local crlf_count
    crlf_count=$(grep -o $'\r\n' "$file" | wc -l | tr -d ' ')

    # Count CR (includes CRLF)
    local cr_count
    cr_count=$(grep -o $'\r' "$file" | wc -l | tr -d ' ')
    cr_count=$((cr_count - crlf_count))
    ((cr_count < 0)) && cr_count=0

    # Count LF (includes CRLF)
    local lf_count
    lf_count=$(grep -o $'\n' "$file" | wc -l | tr -d ' ')
    lf_count=$((lf_count - crlf_count))
    ((lf_count < 0)) && lf_count=0

    # Majority decision
    if (( crlf_count >= cr_count && crlf_count >= lf_count )); then
        echo "CRLF"
    elif (( cr_count >= lf_count )); then
        echo "CR"
    else
        echo "LF"
    fi
}

label_ending() {
    case "$1" in
        CRLF) echo "Windows" ;;
        CR)   echo "Macintosh" ;;
        LF)   echo "Unix" ;;
        *)    echo "Unknown" ;;
    esac
}

label_encoding() {
    case "$1" in
        ASCII) echo "ASCII" ;;
        UTF-8) echo "UTF8" ;;
        UTF-16) echo "UTF16" ;;
        *) echo "$1" ;;
    esac
}

############################################
# PROCESS FILE
############################################
process_file() {
    local file="$1"

    [[ ! -f "$file" ]] && return

    if is_binary "$file"; then
        echo "$file - skipped"
        return
    fi

    if [[ ! -r "$file" || ! -w "$file" ]]; then
        echo "$file - permissions error"
        return
    fi

    local current_enc current_le
    current_enc=$(detect_encoding "$file")
    current_le=$(detect_line_ending "$file")

    local current_enc_label current_le_label
    current_enc_label=$(label_encoding "$current_enc")
    current_le_label=$(label_ending "$current_le")

    local target_enc_label target_le_label
    [[ -n "$encoding" ]] && target_enc_label=$(label_encoding "$encoding")
    [[ -n "$ending" ]] && target_le_label=$(label_ending "$ending")

    # Dry run
    if [[ $dry_run -eq 1 ]]; then
        echo -n "$file - DRY RUN:"
        [[ -n "$encoding" ]] && echo -n " encoding $current_enc_label -> $target_enc_label;"
        [[ -n "$ending" ]] && echo -n " line endings $current_le_label -> $target_le_label"
        echo
        return
    fi

    local tmpfile
    tmpfile=$(mktemp)

    cp "$file" "$tmpfile" || { echo "$file - permissions error"; rm -f "$tmpfile"; return; }

    ############################################
    # ENCODING CONVERSION
    ############################################
    if [[ -n "$encoding" ]]; then
        local iconv_to
        case "$encoding" in
            ASCII) iconv_to="ASCII//TRANSLIT" ;;
            UTF-8) iconv_to="UTF-8" ;;
            UTF-16) iconv_to="UTF-16" ;;
        esac

        if ! run_cmd iconv -f "$current_enc" -t "$iconv_to" "$tmpfile" -o "${tmpfile}.enc"; then
            echo "$file - corruption error"
            rm -f "$tmpfile" "${tmpfile}.enc"
            return
        fi
        mv "${tmpfile}.enc" "$tmpfile"
    fi

    ############################################
    # LINE ENDING CONVERSION (PERL)
    ############################################
    if [[ -n "$ending" ]]; then
        # Normalize all endings to LF
        perl -pe 's/\r\n/\n/g; s/\r/\n/g;' "$tmpfile" > "${tmpfile}.norm" || {
            echo "$file - unknown error"
            rm -f "$tmpfile" "${tmpfile}.norm"
            return
        }
        mv "${tmpfile}.norm" "$tmpfile"

        case "$ending" in
            CRLF)
                perl -pe 's/\n/\r\n/g' "$tmpfile" > "${tmpfile}.le" ;;
            CR)
                perl -pe 's/\n/\r/g' "$tmpfile" > "${tmpfile}.le" ;;
            LF)
                cp "$tmpfile" "${tmpfile}.le" ;;
        esac

        mv "${tmpfile}.le" "$tmpfile"
    fi

    mv "$tmpfile" "$file" || { echo "$file - permissions error"; rm -f "$tmpfile"; return; }

    echo -n "$file -"
    [[ -n "$ending" ]] && echo -n " converted line ending to $target_le_label"
    [[ -n "$encoding" ]] && echo -n " converted encoding to $target_enc_label"
    echo
}

############################################
# MAIN LOOP
############################################
process_target() {
    local target="$1"
    if [[ -d "$target" ]]; then
        if [[ $recursive -eq 1 ]]; then
            find "$target" -type f | while read -r f; do process_file "$f"; done
        else
            for f in "$target"/*; do [[ -f "$f" ]] && process_file "$f"; done
        fi
    else
        process_file "$target"
    fi
}

for t in "$@"; do
    process_target "$t"
done

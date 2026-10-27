#!/usr/bin/env bash
# End-to-end tests: pipe each input into ./nasmforth and compare stdout and
# stderr exactly. Run with `make test` (or tests/run.sh after `make`).
cd "$(dirname "$0")/.." || exit 1

errfile=$(mktemp)
trap 'rm -f "$errfile"' EXIT

pass=0
fail=0

# check NAME INPUT EXPECTED_STDOUT [EXPECTED_STDERR]
check() {
    local name=$1 input=$2 want_out=$3 want_err=${4-}
    local got_out got_err
    got_out=$(printf '%s' "$input" | ./nasmforth 2>"$errfile")
    got_err=$(<"$errfile")
    if [[ "$got_out" == "$want_out" && "$got_err" == "$want_err" ]]; then
        pass=$((pass + 1))
    else
        fail=$((fail + 1))
        printf 'FAIL: %s\n  input:  %q\n  stdout: want %q got %q\n  stderr: want %q got %q\n' \
            "$name" "$input" "$want_out" "$got_out" "$want_err" "$got_err"
    fi
}

check "dot"            "42 ."                 "42 "
check "negative"       "-7 ."                 "-7 "
check "add"            "2 3 + ."              "5 "
check "sub"            "10 3 - ."             "7 "
check "mul"            "6 7 * ."              "42 "
check "div"            "20 6 / ."             "3 "
check "div trunc"      "-7 2 / ."             "-3 "
check "mod"            "20 6 mod ."           "2 "
check "dup"            "5 dup * ."            "25 "
check "drop"           "1 2 drop ."           "1 "
check "swap"           "1 2 swap - ."         "1 "
check "over"           "1 2 over .s"          "<3> 1 2 1 "
check ".s empty"       ".s"                   "<0> "
check ".s keeps stack" "1 2 .s .s"            "<2> 1 2 <2> 1 2 "
check ".s after dot"   "1 2 3 . .s"           "3 <2> 1 2 "
check "emit cr"        $'72 emit 105 emit cr' $'Hi'
check "multiline"      $'1 2\n+ .\n'          "3 "
check "tabs"           $'1\t2\t+\t.'          "3 "
check "int64 min"      "-9223372036854775808 ." "-9223372036854775808 "
check "min / -1"       "-9223372036854775808 -1 / ." "-9223372036854775808 "
check "bye"            "1 . bye 2 ."          "1 "
check "unknown"        $'1 foo 2 .\n3 .'      "3 " "error: unknown word: foo"
check "underflow"      $'1 +\n.s'             "<0> " "error: stack underflow"
check "div by zero"    $'1 0 /\n.s'           "<0> " "error: division by zero"
check "abort clears"   $'1 2 3 bar\n.s'       "<0> " "error: unknown word: bar"
check "lone minus"     "-"                    ""   "error: stack underflow"
check "overflow"       "$(printf '1 %.0s' {1..257})" "" "error: stack overflow"
check "dup overflow"   "$(printf '1 %.0s' {1..256}) dup" "" "error: stack overflow"

echo "$pass passed, $fail failed"
[[ $fail -eq 0 ]]

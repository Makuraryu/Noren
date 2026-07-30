#!/bin/sh
set -eu

noren_bin=$1
capture_file=$(mktemp "${TMPDIR:-/tmp}/noren-e2e.XXXXXX")
stdout_file=$(mktemp "${TMPDIR:-/tmp}/noren-e2e-stdout.XXXXXX")
trap 'rm -f "$capture_file" "$stdout_file"' EXIT HUP INT TERM

export NOREN_E2E_BIN="$noren_bin"
case "$(uname -s)" in
    Darwin)
        script -q "$capture_file" /bin/sh -c '
            stty rows 24 cols 80
            before=$(stty -g)
            "$NOREN_E2E_BIN" new -s smoke -- /bin/sh -c "printf hello"
            status=$?
            after=$(stty -g)
            [ "$before" = "$after" ] || printf RESTORE_FAILED
            exit "$status"
        ' >"$stdout_file"
        ;;
    Linux)
        script -q -c '
            stty rows 24 cols 80
            before=$(stty -g)
            "$NOREN_E2E_BIN" new -s smoke -- /bin/sh -c "printf hello"
            status=$?
            after=$(stty -g)
            [ "$before" = "$after" ] || printf RESTORE_FAILED
            exit "$status"
        ' "$capture_file" >"$stdout_file"
        ;;
    *)
        printf 'unsupported e2e host: %s\n' "$(uname -s)" >&2
        exit 1
        ;;
esac

strings "$capture_file" | grep -q 'hello'
strings "$capture_file" | grep -q 'smoke 1:1'
if strings "$capture_file" | grep -q 'RESTORE_FAILED'; then
    printf 'terminal mode was not restored\n' >&2
    exit 1
fi

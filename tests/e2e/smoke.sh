#!/bin/sh
set -eu

noren_bin=$1
capture_file=$(mktemp "${TMPDIR:-/tmp}/noren-e2e.XXXXXX")
stdout_file=$(mktemp "${TMPDIR:-/tmp}/noren-e2e-stdout.XXXXXX")
nvim_capture_file=$(mktemp "${TMPDIR:-/tmp}/noren-nvim-e2e.XXXXXX")
nvim_stdout_file=$(mktemp "${TMPDIR:-/tmp}/noren-nvim-e2e-stdout.XXXXXX")
detach_capture_file=$(mktemp "${TMPDIR:-/tmp}/noren-detach-e2e.XXXXXX")
detach_stdout_file=$(mktemp "${TMPDIR:-/tmp}/noren-detach-e2e-stdout.XXXXXX")
multi_capture_file=$(mktemp "${TMPDIR:-/tmp}/noren-multi-e2e.XXXXXX")
multi_stdout_file=$(mktemp "${TMPDIR:-/tmp}/noren-multi-e2e-stdout.XXXXXX")
trap 'rm -f "$capture_file" "$stdout_file" "$nvim_capture_file" "$nvim_stdout_file" "$detach_capture_file" "$detach_stdout_file" "$multi_capture_file" "$multi_stdout_file"' EXIT HUP INT TERM

export NOREN_E2E_BIN="$noren_bin"
e2e_dir=$(CDPATH= cd -- "$(dirname "$0")" && pwd)
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

if command -v nvim >/dev/null 2>&1 && command -v expect >/dev/null 2>&1; then
    export NOREN_E2E_NVIM="$(command -v nvim)"
    export NOREN_E2E_CAPTURE="$nvim_capture_file"
    expect "$e2e_dir/nvim.exp" >"$nvim_stdout_file"
    strings "$nvim_capture_file" | grep -q 'nvim-smoke 1:1'
    if strings "$nvim_capture_file" | grep -q 'noren:'; then
        printf 'nvim lifecycle produced a Noren runtime error\n' >&2
        exit 1
    fi

    export NOREN_E2E_DETACH_CAPTURE="$detach_capture_file"
    expect "$e2e_dir/detach_nvim.exp" >"$detach_stdout_file"
    strings "$detach_capture_file" | grep -q 'persisted-nvim 1:1'
    if strings "$detach_capture_file" | grep -q 'noren:'; then
        printf 'Nvim detach/reattach produced a Noren runtime error\n' >&2
        exit 1
    fi

    export NOREN_E2E_MULTI_CAPTURE="$multi_capture_file"
    expect "$e2e_dir/multi_workspace.exp" >"$multi_stdout_file"
    strings "$multi_capture_file" | grep -q 'multi 1:1'
    if strings "$multi_capture_file" | grep -q 'noren:'; then
        printf 'multi-Pane/Workspace lifecycle produced a runtime error\n' >&2
        exit 1
    fi
fi

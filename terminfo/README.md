# terminfo status

Noren 0.1.0 does not yet install a `noren-256color` terminfo entry. The M1
development runtime explicitly uses the conservative `xterm-256color` fallback.
Declaring Noren-specific capabilities before testing the full input/output
matrix would violate the normative specification. The entry and
`install-terminfo` build step belong to the M6 hardening milestone.

# ADR 0001: Release 0.1.0 after M0 and M1

- Status: accepted
- Date: 2026-07-30

## Context

The implementation specification defines an ordered M0–M6 delivery route and
forbids advancing to later phases to mask failures in earlier phases. The
repository initially contained only the specification and no Zig toolchain,
code or dependency lock.

## Decision

Release 0.1.0 completes and verifies M0 and M1 as explicit implementation
milestones. It includes a working local PTY/libvterm client, but does not claim
the specification's final multi-process Definition of Done. Commands whose
semantics require a persistent Server fail clearly in this release.

All M1–M6 work must preserve the stable ID ownership model, reducer/effect
boundary, pure layout interface and bounded protocol parser established here.

## Consequences

The repository has a buildable, testable foundation with honest capability
reporting. Users can run an interactive shell or command in one foreground
Pane. M2 can move PTY ownership into a persistent Server without restructuring
`core`, `layout`, `render` or `protocol`.

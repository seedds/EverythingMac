# Native parity review

Baseline: `b21b2cc`. Implementation: `f1969e2` and subsequent fixes on
`codex/native-search-prototype`. Two independent read-only reviews followed the
implementation skill. Findings below preserve their separate axes.

## Standards

No hard documented-style violations remained. Correctness/performance findings
were fixed: stale actionable selection, unbounded passive Swift selection,
whole-result path resolution for single-file actions, replacement-engine cleanup
on transfer failure, and filesystem preflight outside scan cancellation. Stable
path fingerprints and generation-cached selected positions remain in Rust.
Deferred cleanup handles failed adoption. All scan filesystem work runs in the
bounded cancellable worker, with a separate traversal pool.

Final reviewer: “Confirmed: scan preflight and symlink resolution now execute
inside cancellable_scan; Swift scan preparation performs only lexical
normalization. The reported cancellation gap is resolved. No new critical issues
found in this delta.”

A nonblocking design suggestion remains: replace string-based file-action dispatch
with an enum if the action surface grows.

## Spec

Fixed: selection identities becoming stale, uncached drag rows being omitted,
the incorrect AppKit drag callback, startup ignoring changed saved scope,
Quick Look truncating a large selection, incomplete native control translations,
and invisible selection remaining actionable after switching tabs.

The table overrides the actual AppKit drag method. Explicit actions resolve all
selected paths. Scope changes rebuild the index; translations cover all 15
bundled languages; changing tabs clears both visible and actionable selection.
The 21-check rendered suite covers 1,200-file selection, Quick Look after sorting,
and selection safety across tab switches.

Final reviewer: “Confirmed resolved. App.swift clears pending restoration and
actionable selection, hides Quick Look, and removes the stale Events-tab navigation
callback. No new critical issue found within these fixes.”

Review outcome: Standards — zero unresolved correctness findings, one nonblocking
design suggestion. Spec — zero unresolved findings within the reviewed scope.
Deployment and external-integration validation limits remain in PARITY.md.

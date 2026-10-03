# Bounded frozen-lock advisory receipts

`audit-receipts.yml` runs only when this workflow or this note changes in a PR.
The existing draft PR path trigger works before a branch-only workflow is on
`main`; no default-branch `workflow_dispatch` registration is assumed.

A standard public GitHub-hosted Ubuntu job uses Node **22.23.3**, verifies bundled
npm **10.9.9**, and checks out **93b19483f9913f4fd584f5434ad179dad1a2a5aa**
(tree `631c1656c6711dbd01e36f2395c7508fe2739001`). The workflow/event SHA and
PR source head are recorded separately from that audited SHA. It does not
install dependencies, run package scripts, tests or builds, remediate versions,
or access application/deployment credentials. Permissions are only `contents: read`.

From `backend/img-host`, it captures these exact public-registry commands:

```sh
npm audit --package-lock-only --ignore-scripts --legacy-peer-deps --json
npm audit --package-lock-only --ignore-scripts --legacy-peer-deps --omit=dev --json
```

The full and omit-dev outputs describe the **virtual frozen-lock graph**, not
the historic `npm ci` Ubuntu graph of 146 audited installed packages / 15 npm
findings. Omit-dev filters the audited dependency boundary; dependency metadata
may still describe the full lock inventory. Neither counts advisories as unique
CVEs/GHSAs or establishes deployed reachability. Registry data can change even
when lock bytes do not. The verified historical 14→15 change predates `df7d22a`
(which already reported 15); registry timing/busboy attribution remains unproven.

One-day text artifacts preserve complete JSON (including `via`, `effects`,
`nodes`, `range`, `fixAvailable`, `isDirect`), separate stderr/exits/UTC,
Node/npm/registry/filter provenance and before/after lock/manifest hashes and
clean-tree checks. Receipt validation permits the actual findings exit **1**;
registry/errors, invalid structure, unexpected exits, stderr requiring review,
toolchain mismatch or checkout/lock mutation fail the job. A successful job means
**measurement validated, advisory gate OPEN**, not security clearance, remediation,
full issue #5/#6 acceptance or rollout authorization. Keep PR #9 draft, the issue
open and `EMAIL_CONVERSION_ENABLED` unset. Original 83-case scoped native review
and backend evidence are unchanged and not rerun by this dedicated workflow.

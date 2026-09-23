# Review: a8290164d..6890fd791

    mode:      diff
    target:    <SANDBOX>/repo
    base:      a8290164da2f708869e7127071ad164b2acdc069
    snapshot:  6890fd79191ca7f93ad5faeed6a5c8e0950c7403
    untracked: 0 file(s) carried in
    base-tree: 7e481b3f1997d0101562a059fe1baae62437dbff
    reviewed-tree: e3323ae7ddf623d3eaf07d3555d85890565e0a69
    diff-sha256: 7c3909fbb7fc68a59b746e219e511bc7cff7c5969fe087d7e6b567f4bd91a970
    roster:    finder trunc dead waffle ghost twice
    rolls:     twice=2
    roster-layer: explicit
    roster-path: ''
    language:  javascript
    prompt:    1135120976
    harness:   <harness>
    cadre:     <cadre>

## Reviewers

- `finder` — ok
- `trunc` — **DEGRADED**, stopped early. Its findings are real; its
  silence is not. See `trunc-2787845321.md.partial`.
- `dead` — **FAILED**, see `dead-988114467.md.failed`
- `waffle` — **INCONCLUSIVE**. It ran and returned text, but the text
  is not a review: no findings and no verdict. Not counted as a
  reviewer. See `waffle-3929603487.md.inconclusive`.
- `ghost` — **MISCONFIGURED**, never ran: NOT INSTALLED: ghost is not on PATH. A fault on this box, not a reviewer verdict.
- `twice` x2 — ok (2/2 rolls complete)
- `gated` — SKIPPED by its roster gate (?min-lines=999: diff is 2 lines).

6 independent lineage(s) across 6 seat(s) dispatched.

> 1 requested seat(s) were **MISCONFIGURED** on this box and never ran.
> The panel is smaller than the roster asked for. That is not a finding about
> any reviewer; fix the roster or the install and re-run.

> A **DEGRADED** reviewer ran out of tokens or time partway through. Read
> what it found, but do not count the files it never mentioned as cleared,
> and do not read it as disagreeing with anything it never reached.

> An **INCONCLUSIVE** reviewer exited cleanly and produced text that is
> not a review — a summary of the diff, a request for clarification, or
> the diff echoed back. Length is not coverage: treat it as a reviewer
> that did not run. It is excluded from the synthesis and clears nothing.

## finder

- blocking: app.js drops the write when the retry path runs
* **Severity**: should-fix
#### **1. `nit`** rename the counter
Verdict: blocking

## trunc

_DEGRADED. Stopped early, so this covers only part of the diff._

- should-fix: the counter is never reset

_TRUNCATED, stopped early (stopReason=MaxTokens); this review is INCOMPLETE, not a clean pass._

## dead

_FAILED. Not a clean review._

    DID NOT COMPLETE, no text returned (stopReason=Error).

## waffle

_INCONCLUSIVE. Ran, but returned no findings and no verdict. Not a review._

    I have looked over the changes you provided. They touch the save path.

## ghost

_MISCONFIGURED. The seat never ran; this is a fault on this box, not a review._

    NOT INSTALLED: ghost is not on PATH

## twice

_This seat ran 2 times on the same change. Below is the union of those rolls: one reviewer, counted once. What one roll names and another does not is run-to-run variance inside one reviewer, not a disagreement._

----- roll 1 of 2: ok -----

- nit: the fixture file has no trailing comment
Verdict: ship it

----- roll 2 of 2: ok -----

- nit: the fixture file has no trailing comment
Verdict: ship it

## Receipts

| seat | model | status | secs | prompt KB | review KB | est. tokens |
|---|---|---|---|---|---|---|
| `finder` |  | ok | <n> | 1.8 | 0.1 | 494 |
| `trunc` |  | degraded | <n> | 1.8 | 0.1 | 493 |
| `dead` |  | failed | <n> | 1.8 | 0.1 | 473 |
| `waffle` |  | inconclusive | <n> | 1.8 | 0.1 | 477 |
| `ghost` |  | failed |  | 0.0 | 0.0 | 9 |
| `twice` |  | ok | <n> | 3.6 | 0.4 | 1019 |
| `gated` |  | skipped |  | 0.0 | 0.0 | 0 |
| **panel total** | | | <n> | 10.8 | 0.8 | 2965 |

> Estimated as bytes/4 of what the harness sent and received. Hidden reasoning tokens are invisible from outside the CLI and are NOT in this number: a seat that thinks long and answers short costs more than its row shows. This is a relative-spend signal, not a bill.

> Wall clock: **<n>s** for this panel up to this table; <n>s in seats. **Unattributed: <n>s**, harness time no timer covers (checkout copies, the prompt build, record writes).
>
> 2 seat(s) were never timed; whatever they took is inside the unattributed figure, not in the secs column.
>
> Not timed: this table, the cleanup after it, and any synthesis that follows. Tokens have no measured panel total to reconcile against, so their residual is recorded as unmeasured.

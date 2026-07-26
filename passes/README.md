# Reference passes

These are mined from permissively-licensed **public** repositories with clean
commit history.

## ★ They are not for scoring

Any public repo is in every model's training data. A shipped reference pass is
**contaminated by construction**: a candidate may have seen the target, the
fix, and the discussion around both.

Reference passes exist to:

1. smoke-test that your adapters, judge, and leak controls are wired correctly
2. show what a good answer key looks like before you write your own

**A score on a reference pass is not a roster signal.** Slotting a reviewer
requires passes mined from the repo you actually work in. `cadre run` prints
this warning in the report whenever a `ref-*` pass contributed to a score.

## Why they are shortlists, not finished passes

Building the passes here would mean shipping hand-written answer keys for bugs
in someone else's repo. Each directory instead ships the **mined shortlist** -
the (target, fix) pairs that survived the filters, and you generate the keys
locally:

```
git clone https://github.com/<owner>/<repo> /tmp/<repo>
cadre make-pass ref-<name> /tmp/<repo> <target_sha> <fix_sha>
# read and correct the draft key, then:
cadre add-pass ref-<name>
```

The `ref-` prefix is what triggers the contamination warning. Keep it.

## What is here

- [`execa/`](execa/). MIT. Node child-process library. Every survivor is a
  behavioural defect with a test proving it. Small and fast to clone.

Other repos that mined well, if you want a second domain: **hono** (MIT, HTTP
routing and middleware, closer to what most people review day to day) and
**zod** (MIT, highest raw survivor count, but they cluster hard in one
subsystem, which makes for a narrow smoke test).

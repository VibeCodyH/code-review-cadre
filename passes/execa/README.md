# Reference shortlist: execa

[sindresorhus/execa](https://github.com/sindresorhus/execa) (MIT). Node
child-process library, ~850 commits, fast to clone.

Read [../README.md](../README.md) first: **a score on a reference pass is not a
roster signal.** This repo is in every model's training data.

## Why this repo

After the miner's filters, every surviving pair is a real behavioural defect
with a test proving it (no type-checker repairs, no CI fixes, no reverts). That
is unusual and it is why this is the primary reference.

`shortlist.tsv` is the raw miner output:

```
cadre setup /tmp/execa 200
```

Columns: `fix_sha`, `target_sha`, `src` (source files the fix touched), `test`
(test files the fix touched, always ≥1 (that is the filter)), `share` (how much
of the fix's blame lands on one target commit), `age` (days between them).

## The six worth using

Different failure classes, which is the point: three passes that are all "a
null check is missing" measure one skill three times.

| target | fix | class |
|---|---|---|
| `ea889c72a` | `39790a459` | using files in both input and output |
| `fdffcb6ba` | `4940511bb` | fd-specific options |
| `316f562a4` | `bd547e4f3` | calling script `.pipe` multiple times |
| `249e7c45e` | `7707fc727` | `all` option combined with `ignore` |
| `62a5207c3` | `b8c1f555f` | `error.message` under `encoding: 'buffer'` |
| `62a5207c3` | `ec383fec8` | `result.stdout` vs `error.stdout` inconsistency |

Note the last two share a target. Do not register both as separate passes
against the same checkout without merging their keys: a reviewer sees one diff
and should be graded against everything wrong in it.

## Build one

```
git clone https://github.com/sindresorhus/execa /tmp/execa
cadre make-pass ref-execa-pipe /tmp/execa 316f562a4 bd547e4f3
# read and correct $CADRE_HOME/keys/ref-execa-pipe.md, delete the draft marker
cadre add-pass ref-execa-pipe
cadre run codex 2 ref-execa-pipe
```

If the last command produces a sensible report, your adapters and judge are
wired correctly. That is all this proves.

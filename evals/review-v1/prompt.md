Review the change between BASE and HEAD in this checkout. Inspect the diff and
the surrounding code. Report concrete defects introduced by the change, with
the input or ordering that triggers each defect and its consequence.

You may run targeted checks. Do not fix the implementation. A passing test is
evidence only for the behavior it actually exercises. Check whether an apparent
defect is prevented by a caller or represents documented intended behavior.

Rate data loss, authorization bypass, and silently wrong user output blocking;
bounded correctness failures should-fix; style preferences nit. Do not pad the
review with nits. For each finding give file and line, trigger, consequence,
and evidence. State whether you executed a check or reasoned by inspection.

State each finding under a bold severity label on its own line: **blocking**,
**should-fix**, or **nit**. End with `Verdict: blocking`, `Verdict: should-fix`,
or `Verdict: no defects found`. A clean review must be an explicit conclusion.

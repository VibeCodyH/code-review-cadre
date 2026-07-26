Review the change on the current checkout against {{BASE}}:

  git log --oneline {{BASE}}..HEAD
  git diff {{BASE}}...HEAD

{{STACK_LINE}}This is a real change headed for production, not an exercise. Report defects in
priority order: data loss, security, correctness bugs that reach production,
then missing test coverage for the changed paths.

{{TEST_PARAGRAPH}}
For each defect: severity (blocking / should-fix / nit), file and line, what
breaks, and the concrete input that triggers it. Do not restate what the diff
does. Do not pad with nits. If you find nothing worth flagging, say so plainly.

End with a one-line overall verdict: blocking, should-fix, or ship it.

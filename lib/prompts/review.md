Review the commits on the current checkout that are not on {{BASE}}:

  git log --oneline {{BASE}}..HEAD
  git diff {{BASE}}...HEAD

{{STACK_LINE}}Report defects in priority order: data loss, security, correctness bugs that
reach production, then missing test coverage for the changed paths.

{{TEST_PARAGRAPH}}
For each defect: severity (blocking / should-fix / nit), file and line, what
breaks, and the concrete input that triggers it. Do not restate what the diff
does. Do not pad with nits. If you find nothing worth flagging, say so plainly.

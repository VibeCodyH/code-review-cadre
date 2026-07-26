Review the commits on the current checkout that are not on {{BASE}}:

  git log --oneline {{BASE}}..HEAD
  git diff {{BASE}}...HEAD

{{STACK_LINE}}Report defects in priority order: data loss, security, correctness bugs that
reach production, then missing test coverage for the changed paths.

{{TEST_PARAGRAPH}}
Rate each defect by CONSEQUENCE, not by how far it is from how you would have
written it:
  blocking   - data loss or corruption, auth bypass, secret exposure, or
               silently wrong output reaching a user.
  should-fix - a real bug with a bounded blast radius: it fails loudly, needs
               an unlikely input, or gets caught before production. Also
               missing test coverage on a path this diff changes.
  nit        - style, naming, or preference. Cannot produce a wrong result.
If you cannot name the consequence, it is a nit. Do not inflate severity to
make a finding sound worth reporting.

For each defect give file and line, what breaks, and what triggers it: the
concrete input where one exists, otherwise the specific state, configuration,
or ordering. A coverage gap has no trigger, so name the untested path instead.
Do not restate what the diff does. Do not pad with nits. If you
find nothing worth flagging, say so plainly.

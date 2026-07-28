Review the content on the current checkout. There is no earlier version to
compare against: review what is here, as it stands.

  git ls-files

{{STACK_LINE}}This is real content in use, not an exercise. Report defects in priority order:
data loss, security, correctness bugs that reach production, then missing test
coverage for the paths you reviewed.

{{TEST_PARAGRAPH}}
{{TEST_RESULT}}
Rate each defect by CONSEQUENCE, not by how far it is from how you would have
written it:
  blocking   - data loss or corruption, auth bypass, secret exposure, or
               silently wrong output reaching a user.
  should-fix - a real bug with a bounded blast radius: it fails loudly, needs
               an unlikely input, or gets caught before production. Also
               missing test coverage on an important path.
  nit        - style, naming, or preference. Cannot produce a wrong result.
If you cannot name the consequence, it is a nit. Do not inflate severity to
make a finding sound worth reporting.

For each defect give file and line, what breaks, and what triggers it: the
concrete input where one exists, otherwise the specific state, configuration,
or ordering. A coverage gap has no trigger, so name the untested path instead.
Do not restate what the content does. Do not pad with nits. If you find nothing
worth flagging, say so plainly.

You are reading everything, not a diff, so the volume is not a signal of how
much is wrong. Do not scale the number of findings to the number of files.

End with a one-line overall verdict: blocking, should-fix, or ship it.

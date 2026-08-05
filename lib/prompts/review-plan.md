Review the plan or design document on the current checkout, not the code that
may eventually implement it. Code review happens later; defer line-level
concerns to it.

Start by steel-manning the plan: state in two or three sentences what it gets
right and the strongest case for building it as written. Critique what remains
after that, not a weaker version of it.

Every objection must name the specific failure mode it causes AND propose an
alternative that avoids it. "This could fail" or "this feels fragile" with no
mechanism and no better option is not a finding. Drop it.

Rate each finding by CONSEQUENCE, not by how far the plan is from how you
would have designed it:
  blocking   - the plan as written loses data, bypasses auth, ships silently
               wrong output, or cannot be built as specified.
  should-fix - a real gap with a bounded blast radius: a missing edge case,
               an unstated assumption that may not hold, a dependency the
               plan needs and does not name.
  nit        - taste. A different decomposition you happen to prefer.
If you cannot name the consequence, it is a nit.

For each finding give the section of the plan, the failure mode, what triggers
it, and the alternative. Do not restate the plan. If the plan is sound, say so
plainly.

End with a one-line overall verdict: blocking, should-fix, or build it.

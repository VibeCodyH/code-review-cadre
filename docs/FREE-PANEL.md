# Getting a second reviewer, free

`cadre doctor` sends you here when it sees one reviewer installed. One reviewer
is a valid setup and cadre will run it. This is what the measurement says you
give up, and the shortest routes to a second one that costs nothing.

The README's [Build a whole panel for free](../README.md#build-a-whole-panel-for-free)
section lists the providers and their rate limits. This file is the procedure:
what to actually type, and where the key goes.

## Why bother

Across 294 confirmed defects and 15 model versions, **56.8% were caught by
exactly one model**. Coverage of a change's real defects ran 47% at one
reviewer, 72% at two, 89% at three. The second chair buys the most.

The word doing the work there is *different*. Two reviewers from the same model
family buy you one opinion twice. What you want from reviewer number two is not
a better score, it is a different set of failures, which is why "free model from
a family you don't have" beats "second subscription to the lab you already pay."

## Route 1: a free model on opencode, no key at all

Check what you can already reach:

```bash
opencode models
```

If that lists entries like `opencode/deepseek-v4-flash-free`, those are usable
as reviewers with no API key and no provider block:

```bash
cadre review --roster claude,opencode:opencode/deepseek-v4-flash-free
```

That is the whole setup. If it works, stop reading.

## Route 2: CodeRabbit

A real reviewer on a free tier, three reviews an hour, and it ships its own
review contract so there is nothing to configure. Install its CLI, log in, and
it is a roster entry:

```bash
cadre review --roster claude,coderabbit
```

Two things to know before you compare its output to the others. It takes no
prompt, so it gets a different brief than everyone else by necessity. And it
exits 0 whether it found something or not, which is why the adapter reads its
JSON record instead of the exit code.

## Route 3: a keyed free tier

Pick a provider from the README table, then:

```bash
opencode auth login -p cerebras
```

That prompts for the key with the input masked, stores it in
`~/.local/share/opencode/auth.json`, and cadre never sees it. Then:

```bash
opencode models cerebras                       # what you can now reach
cadre review --roster claude,opencode:cerebras/gpt-oss-120b
```

Most providers need nothing else. A provider `opencode auth login` does not
already know needs a block in `~/.config/opencode/opencode.json`; see
[opencode's provider docs](https://opencode.ai/docs/providers) and
[Route 4](#route-4-local-and-free-forever) below for a worked example.

## Where the key goes

`opencode auth login` is the recommended path and the one that needs no
decisions: it masks the input and stores the key itself.

You need the options below only when you want **an AI agent to do the config
for you without the key ever entering its context.** In that case the agent
writes the provider block with a placeholder and never handles the secret:

```json
"options": { "apiKey": "{env:CEREBRAS_API_KEY}" }
```

`{env:VAR}` is opencode's own substitution. The placeholder is not a secret and
is safe to paste anywhere, including into an agent transcript. Then you supply
the variable yourself, by one of these.

**Option 1, you type it.** Nothing else involved.

```bash
opencode auth login -p cerebras
```

**Option 2, from the clipboard, never displayed.** Copy the key, then run this.
It reads the clipboard directly into the file and never prints it, so the key
does not appear in your terminal, your shell history, or an agent's transcript.

```bash
mkdir -p ~/.config/cadre && umask 077 && \
  printf 'export CEREBRAS_API_KEY=%q\n' "$(wl-paste -n)" >> ~/.config/cadre/keys.env
```

`xclip -o -selection clipboard` on X11, `pbpaste` on macOS. `%q` rather than
`%s` so a key containing a shell metacharacter still round-trips: verified
against keys with `$`, spaces, quotes and `;&`.

Then source that file from your shell profile:

```bash
echo '[ -f ~/.config/cadre/keys.env ] && . ~/.config/cadre/keys.env' >> ~/.bashrc
```

**Option 3, a masked prompt.** No clipboard, no GUI needed. `read -rs` turns off
echo, so nothing is displayed and nothing lands in history:

```bash
mkdir -p ~/.config/cadre && umask 077 && \
  read -rs -p "Cerebras API key: " k && \
  printf 'export CEREBRAS_API_KEY=%q\n' "$k" >> ~/.config/cadre/keys.env && \
  unset k && echo
```

For a GUI popup instead of a terminal prompt, swap the `read` for your desktop's
password dialog. `kdialog --password "Cerebras API key"` on KDE,
`zenity --password` on GNOME, or `"$SSH_ASKPASS"` if you already have one set:

```bash
mkdir -p ~/.config/cadre && umask 077 && \
  printf 'export CEREBRAS_API_KEY=%q\n' "$(kdialog --password 'Cerebras API key')" \
  >> ~/.config/cadre/keys.env
```

### ★ Do not put the key in the repo's `.env`

opencode will read a `.env` in the project directory, which makes it a tempting
place to put this. Don't. Cadre's credential preflight refuses to start a run
when it finds a `.env` in the tree, on purpose: it is about to hand that
checkout to CLIs running with tool auto-approval, several of which upload what
they read. You would be turning a working setup into a run that always refuses.

Keep keys outside the repo. `~/.config/cadre/keys.env` sourced from your shell
profile, or `opencode auth login`, and neither is ever inside a checkout.

## Route 4: local, and free forever

A model on your own machine needs no key and no rate limit. It is slower, and
for a *judge* that does not matter, since grading is bookkeeping and runs once
per review. The README's free-panel section has the full `opencode.json` block
and the one trap that matters, which is that Ollama's default context window is
small enough to silently truncate the rubric before the review is read.

## Sanity check

```bash
cadre doctor          # the reviewer should now be marked installed
cadre review --roster <a>,<b> --base origin/main
```

Two reviewers from different families is the point. `cadre doctor` stops
mentioning any of this once it sees more than one.

# Security review: MCP server, GitHub Action, install script

Reviewed 2026-10-25 at `16a805a`, before v0.1.0. Scope: `leanprof mcp`
(`LeanprofLive.lean`), the GitHub Action (`action.yml`, `action/*.sh`, and
the Markdown it posts, from `leanprof report-md`), and `scripts/install.sh`.
Fixes are in the commit that adds this file. This is one reviewer's reading
of the code plus the checks below, not an external audit.

## Trust model

Profiling a project builds and runs its code: `lake build` runs the
lakefile, and `elab` runs the `#eval`s of the files it elaborates. That is
the job, so none of these components can make an untrusted project safe to
profile. The boundaries they must keep are narrower:

- **MCP server.** The client is often a language model, whose tool arguments
  can be steered by text it read (a README, program output). A tool call may
  profile and build Lake projects; it should not run arbitrary programs,
  write or delete files outside the project, or signal unrelated processes.
- **Action.** It builds and runs a pull request's code. That code must not
  get a token that can write to the repository, and names from it must not
  inject Markdown or HTML into the comment the action posts.
- **Install script.** It must install what the release published for this
  platform, or build the named source, and nothing else.

## Findings

| # | Component | Finding | Severity | Status |
|---|---|---|---|---|
| 1 | MCP | `measure_pair` ran any binary with any arguments (`/bin/sh -c …`): arbitrary command execution from a tool call, beyond building Lake projects. | high | fixed: both binaries must resolve into a `.lake/build/bin/` directory, and `base_cwd`/`candidate_cwd` must be Lake projects |
| 2 | MCP | `measure_pair`'s `check_output` is deleted before each run; with an arbitrary working directory and path (`base_cwd: ~`, `check_output: .bashrc`) a call could delete any file. | high | fixed: `check_output` must be relative without `..`, in a Lake project (finding 1) |
| 3 | MCP | `run`'s `json` and `measure`'s/`measure_pair`'s `out` accepted any path, so a call could overwrite any file the user can write with JSON. | medium | fixed: paths the server writes must be relative to the project, without `..` |
| 4 | MCP, CLI | `live` and `dump` passed the client's `pid` to `kill`: `-1` signals every process of the user (SIGUSR1 kills those that do not handle it), `0` the process group; a pid with `/` named files outside the temporary directory. | medium | fixed: a pid must be digits and not 0 (also for `leanprof dump` and `top --pid`) |
| 5 | MCP | An `executable` starting with `-` was read by `leanprof run` as an option. | low | fixed: refused |
| 6 | MCP | `live`'s `seconds` slept as long as asked. | low | fixed: at most 60 |
| 7 | Action | Names from the profiled code went into the comment as inline code with backticks and `\|` escaped, but a line break (possible in a `profile!` scope name) ended the code span and the table row, letting the rest render as Markdown or HTML (mentions, images, links) in a comment posted by the bot. | medium | fixed: line breaks become spaces |
| 8 | Action | The verdict step pasted `fail-on` and a step output into its shell script with `${{ }}`. Both come from the workflow author or the action itself, so this was not exploitable, but it is the pattern behind script injection. | low | fixed: passed as environment variables |
| 9 | Action | `actions/checkout` keeps the job's token in `.git/config` by default, where the pull request's code (run by the action) can read it. For same-repository pull requests the token can comment and read contents. | low | documented: the example now checks out with `persist-credentials: false` and `fetch-depth: 0`, and the guide explains why, with minimal `permissions` and pinning the action to a tag |
| 7b | Action | (2026-10-25, with the "why" blocks) The comment now quotes `leanprof explain`'s prose, which names the program's variables in backticks, and names in `<summary>` lines, where Markdown is not read. | — | by design: prose goes through `mdProse` (code spans through `mdCode`; `<`, `>`, `&`, `@`, `#` as entities; Markdown punctuation backslash-escaped), summaries through `htmlCode` (HTML-escaped); `Tests/Regress.lean` checks both. `explain` runs in the pull request's checkout but only reads its emitted C; the comment step still alone gets the token, and no new `${{ }}` reaches a script |
| 10 | Install | The launcher was written as `exec "PATH"`, so a `LEANPROF_HOME` or `--bin` containing `"`, `$` or backticks changed the launcher's code. Only the user sets these, so this was a robustness bug. | low | fixed: single-quoted, tested with `we'ird $(touch PWNED) %s dir` |
| 11 | Install | The checksum line was found with `grep " NAME$"`, where `.` in the name is a regular expression. A matching line for another file could not pass anyway (its hash would differ), but the lookup is now exact. | low | fixed: exact field match with `awk`, also for `sha256sum`'s `*NAME` binary mode |
| 12 | Install | The temporary download directory was left behind when extraction failed. | low | fixed: removed on exit |

`scripts/mcp-check.py` now checks findings 1–5 (12 refusals: a system
binary, a non-project working directory, an output outside the project, an
absolute report path, a summary path with `..`, an option as executable, and
pids `-1`, `0` and `../../etc/x` for `live` and `dump`). Before the fix, the
same checks showed the server running `/bin/echo`, writing
`/tmp/leanprof-mcp-outside.json` and `../outside.json`, and accepting
pid `-1`.

## Accepted risks (by design, or for later)

- **The MCP server and the Action run the project's code.** `run`, `stat`,
  `sample`, `measure` and `elab` build or elaborate the project, which runs
  arbitrary code; `cwd` may name any directory. Configure the MCP server
  only for clients and projects you trust; run the Action on `pull_request`,
  never `pull_request_target` (the guide says so).
- **MCP reads.** `report`, `hot`, `explain`, `compare`, `judge` and `live`
  read any path given. They parse JSON and return summaries, not file
  contents; a non-JSON file gives an error.
- **Release integrity, not authenticity.** `SHA256SUMS` comes from the same
  release as the archive, so it detects corruption, not a compromised
  release. Next step: build provenance attestations on the release workflow
  (`actions/attest-build-provenance`), checked by `gh attestation verify`
  when `gh` is installed.
- **Unpinned third-party code.** The Action and the release workflow install
  elan from its `master` branch with `curl | sh`, and use `actions/cache@v4`
  and `actions/checkout@v4` by tag rather than commit SHA. This is the usual
  practice in Lean CI; pinning by SHA is a possible later hardening.
- **Job summary.** `leanprof compare`'s output goes into the job summary in a
  fenced block; a name containing three backticks can end the fence. The
  summary is visible only on the workflow run and is not posted by the bot.

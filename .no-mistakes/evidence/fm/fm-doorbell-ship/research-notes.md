# Isolated Herdr validation mechanics

The lab helper requires a running default session as a liveness tripwire; it must never mutate that session.
Herdr isolates named session state under its config root's sessions/<name>/ directory, and --session outranks HERDR_SOCKET_PATH.
Sources: https://herdr.dev/docs/persistence-remote/ and https://github.com/herdrdev/herdr/blob/ca1af383/src/session.rs and https://github.com/herdrdev/herdr/blob/ca1af383/src/config/io.rs .
For this run, relative XDG_CONFIG_HOME=.x kept named-session files and short Unix socket addresses inside the gate worktree; .x/herdr/herdr.sock was a local symlink to the existing live default socket, used only for the stock helper's read-only liveness tripwire.
Provision invokes prepare itself for an absent session; an explicit prepare immediately followed by provision refuses an already-existing tripwire. The isolated setup was corrected before product validation.
All successful live drivers used provision and teardown in the same foreground command, so the tool executor did not collect the lab server between setup and testing.
The user-approved independent oracles are: a delayed complete payload submits and causes durable inbox action; a partial payload never submits early; an expired proof sends no Enter; overlapping rings and reclamation contenders skip while preserving records; foreign drafts remain intact.

Partial-prefix driver diagnosis: Herdr pane send-text accepts PANE_ID and TEXT, with no --literal option. Extra arguments are appended to delivered text; the captured foreign draft visibly includes the unintended suffix. The initial prefix remainder carried that suffix, so refusing its payload was correct. The follow-up uses the exact production send-text shape. Independent read-only diagnosis also identified the incorrect 60-character expected prefix and the transport mismatch. Official CLI semantics: https://github.com/herdrdev/herdr/blob/master/docs/versions/0.8.2/website/src/content/docs/agent-automation.mdx .

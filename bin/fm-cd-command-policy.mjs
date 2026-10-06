#!/usr/bin/env node
// Semantic policy for the cd-guard: does a shell command persistently change the
// PRIMARY firstmate shell's own working directory?
//
// A stray persistent top-level `cd projects/<clone>` silently relocates the
// primary shell, so the next firstmate-owned command (a backlog write, an
// fm-* lifecycle call, tasks-axi) runs inside a project clone instead of the
// home. This policy blocks exactly that class of command; the environmental
// scoping to the real primary checkout lives in the bin/fm-cd-pretool-check.sh
// transport, not here. See docs/cd-guard.md for the full contract.
//
// The shell tokenizer and command-position analysis are imported from
// bin/fm-arm-command-policy.mjs, the sole owner of firstmate's shell
// classification, so this guard never duplicates shell lexing. This policy
// never evaluates, expands, sources, or runs any byte of the submitted command;
// it inspects lexical command positions only.

import { Lexer, splitProgram, commandPosition } from "./fm-arm-command-policy.mjs";
import path from "node:path";
import { accessSync, constants, realpathSync, statSync } from "node:fs";
import { fileURLToPath } from "node:url";

const REASONS = {
  "persistent-cd":
    "a persistent top-level cd or pushd into the home's projects folder is blocked; it would move the shell into a project clone so a later firstmate-owned command runs there. Reach the clone without moving the shell - use git -C <dir> or an absolute path on the command itself - or scope the cd to a subshell like (cd <dir> && ...).",
};

// Directory-changing builtins that mutate the calling shell's own cwd.
const CD_BUILTINS = new Set(["cd", "pushd", "popd"]);

// Wrappers that fork or exec a child before reaching the builtin, so a cd behind
// them never persists to the parent shell (and generally just fails, since cd is
// a builtin with no external program). `command` is deliberately NOT here: it
// runs the builtin in the current shell, so `command cd x` still persists.
const FORKING_WRAPPERS = new Set(["env", "sudo", "nohup", "timeout", "gtimeout", "exec"]);

function isPipe(separator) {
  return separator === "|" || separator === "|&";
}

// A top-level command-list node persists its cwd change to the parent shell
// unless it runs in a subshell context: backgrounded with a trailing `&`, or a
// stage of a pipeline (bash runs every pipeline stage in a subshell).
function nodePersists(separators, index) {
  if (separators[index] === "&") return false;
  if (isPipe(separators[index]) || isPipe(separators[index - 1])) return false;
  return true;
}

function deny(code) {
  return { decision: "deny", code, reason: REASONS[code] };
}

function hasPathQualifiedCommandPrefix(position) {
  return position.words
    .slice(position.prefixAssignments, position.index)
    .some((word) => word.value.includes("/") && word.value.split("/").at(-1) === "command");
}

function hasCommandQueryPrefix(position) {
  let commandPrefix = false;
  for (const word of position.words.slice(position.prefixAssignments, position.index)) {
    if (word.value === "command") {
      commandPrefix = true;
      continue;
    }
    if (commandPrefix && /^-[^-]*[vV]/.test(word.value)) return true;
  }
  return false;
}

function knownDirectoryOption(commandName, value) {
  if (commandName === "cd") return /^-[LPe@]+$/.test(value);
  if (commandName === "pushd") return value === "-n";
  return false;
}

// The directory operand, or null when this builtin does not name one literal
// directory. Unknown options, stack rotations, and extra operands fail open:
// bash does not change cwd for those, and an unreadable target must not block.
function directoryOperand(commandName, words, commandIndex) {
  let index = commandIndex + 1;
  while (index < words.length) {
    const word = words[index];
    if (word.value === "--" && word.literal && word.subs.length === 0) {
      index += 1;
      break;
    }
    if (
      word.value !== "-" &&
      word.value.startsWith("-") &&
      word.literal &&
      word.subs.length === 0 &&
      !word.unquotedExpansion
    ) {
      if (commandName === "pushd" && /^[-+]\d+$/.test(word.value)) return null;
      if (knownDirectoryOption(commandName, word.value)) {
        index += 1;
        continue;
      }
      return null;
    }
    if (commandName === "pushd" && word.literal && /^\+\d+$/.test(word.value)) return null;
    break;
  }
  if (index >= words.length || index + 1 !== words.length) return null;
  return words[index];
}

function resolveTarget(word, cwd) {
  if (!word.literal || word.unquotedExpansion || word.subs.length > 0) return null;
  const value = word.value;
  if (value === "" || value === "-") return null;
  if (word.tildeExpansion && value !== "~" && !value.startsWith("~/")) return null;
  if (word.tildeExpansion && (value === "~" || value.startsWith("~/"))) {
    const home = process.env.HOME;
    if (!home || !home.startsWith("/")) return null;
    return value === "~" ? path.resolve(home) : path.resolve(home, value.slice(2));
  }
  if (value.startsWith("/")) return path.resolve(value);
  if (!cwd || !path.isAbsolute(cwd)) return null;
  return path.resolve(cwd, value);
}

// True when the literal target is the projects folder or a directory below it.
function targetsProjectFolder(resolved, projectsRoot) {
  if (!resolved || !projectsRoot) return false;
  const root = path.resolve(projectsRoot);
  return resolved === root || resolved.startsWith(`${root}${path.sep}`);
}

function decision(command, projectsRoot = "", cwd = process.cwd()) {
  const lexed = new Lexer(command).tokenize();
  // Fail open on syntax this classifier cannot tokenize. The cd-guard's threat
  // model is agent mistakes - an accidental bare `cd projects/foo` always
  // tokenizes - so we prioritize zero false blocks over catching malformed or
  // deliberately obfuscated bypasses, which stay out of scope by design.
  if (lexed.error) return { decision: "allow" };

  const { nodes, separators } = splitProgram(lexed.tokens);
  let states = [{ directory: cwd, succeeded: true, filesystemKnown: true }];
  for (let index = 0; index < nodes.length; index += 1) {
    // commandPosition ignores subshell/brace groups, quoted data, comments, and
    // substitutions (they contribute no top-level command word), and skips
    // leading assignments and wrappers to find the executed command word.
    const position = commandPosition(nodes[index]);
    let commandWord = position.command;
    let wordIndex = position.index;
    while (commandWord && (commandWord.value === "builtin" || commandWord.value === "command")) {
      wordIndex += 1;
      commandWord = position.words[wordIndex];
    }
    const commandName = commandWord?.value;
    const directoryCommand = nodePersists(separators, index) &&
      CD_BUILTINS.has(commandName) &&
      !hasPathQualifiedCommandPrefix(position) &&
      !hasCommandQueryPrefix(position) &&
      !position.wrappers.some((wrapper) => FORKING_WRAPPERS.has(wrapper));
    const operand = directoryCommand && commandName !== "popd"
      ? directoryOperand(commandName, position.words, wordIndex) : null;
    const nextStates = [];
    for (const state of states) {
      const incoming = separators[index - 1];
      if ((incoming === "&&" && !state.succeeded) || (incoming === "||" && state.succeeded)) {
        nextStates.push(state);
        continue;
      }
      if (!directoryCommand) {
        const constant = !hasPathQualifiedCommandPrefix(position) &&
          !hasCommandQueryPrefix(position) &&
          !position.wrappers.some((wrapper) => FORKING_WRAPPERS.has(wrapper)) &&
          !nodes[index].some((token) => token.type === "redir" ||
            (token.type === "word" && (!token.literal || token.unquotedExpansion || token.subs.length > 0))) &&
          ["true", "false", ":"].includes(commandName);
        if (constant) {
          nextStates.push({ ...state, succeeded: commandName !== "false" });
        } else {
          nextStates.push({ ...state, succeeded: true, filesystemKnown: false });
          nextStates.push({ ...state, succeeded: false, filesystemKnown: false });
        }
        continue;
      }
      const args = position.words.slice(wordIndex + 1);
      const stackRotation = commandName === "pushd" && args.some((word) =>
        word.literal && word.subs.length === 0 && /^[-+]\d+$/.test(word.value));
      const bareCd = commandName === "cd" && args.every((word) =>
        word.literal && !word.unquotedExpansion && word.subs.length === 0 &&
        (word.value === "--" || knownDirectoryOption("cd", word.value)));
      if (!operand && !bareCd && !stackRotation && commandName !== "popd" && args.length > 0) {
        nextStates.push({ ...state, succeeded: false });
        continue;
      }
      const home = process.env.HOME;
      const resolved = bareCd ? (home && path.isAbsolute(home) ? path.resolve(home) : "")
        : operand ? resolveTarget(operand, state.directory) : "";
      if (operand && targetsProjectFolder(resolved, projectsRoot)) return deny("persistent-cd");
      if (commandName === "pushd" && args.slice(0, -1).some((word) => word.value === "-n")) {
        nextStates.push({ ...state, succeeded: true });
        nextStates.push({ ...state, succeeded: false });
        continue;
      }
      if (!resolved) {
        nextStates.push({ ...state, directory: "", succeeded: true });
        nextStates.push({ ...state, succeeded: false });
        continue;
      }
      let succeeds = null;
      if (state.filesystemKnown) {
        try {
          succeeds = statSync(resolved).isDirectory();
          if (succeeds) accessSync(resolved, constants.X_OK);
        } catch (error) {
          succeeds = ["ENOENT", "ENOTDIR", "EACCES", "EPERM"].includes(error.code) ? false : null;
        }
      }
      if (succeeds !== false) nextStates.push({ ...state, directory: resolved, succeeded: true });
      if (succeeds !== true) nextStates.push({ ...state, succeeded: false });
    }
    states = [...new Map(nextStates.map((state) => [JSON.stringify(state), state])).values()];
  }
  return { decision: "allow" };
}

function parseArguments(argv) {
  const result = { command: "", commandSet: false, projectsRoot: "", cwd: process.cwd() };
  for (let i = 0; i < argv.length; i += 1) {
    const name = argv[i];
    if (name === "--command" || name === "--projects-root" || name === "--cwd") {
      if (i + 1 >= argv.length) throw new Error(`${name} requires a value`);
      if (name === "--command") {
        result.command = argv[i + 1];
        result.commandSet = true;
      } else if (name === "--projects-root") {
        result.projectsRoot = argv[i + 1];
      } else {
        result.cwd = argv[i + 1];
      }
      i += 1;
      continue;
    }
    if (name.startsWith("--command=")) {
      result.command = name.slice("--command=".length);
      result.commandSet = true;
      continue;
    }
    if (name.startsWith("--projects-root=")) {
      result.projectsRoot = name.slice("--projects-root=".length);
      continue;
    }
    if (name.startsWith("--cwd=")) {
      result.cwd = name.slice("--cwd=".length);
      continue;
    }
    throw new Error(`unknown argument: ${name}`);
  }
  return result;
}

function invokedDirectly() {
  const entry = process.argv[1];
  if (!entry) return false;
  const self = fileURLToPath(import.meta.url);
  try {
    return realpathSync(entry) === realpathSync(self);
  } catch {
    return entry === self;
  }
}

if (invokedDirectly()) {
  try {
    const args = parseArguments(process.argv.slice(2));
    if (!args.commandSet || !args.command) {
      process.stdout.write("allow\n");
    } else {
      const result = decision(args.command, args.projectsRoot, args.cwd);
      if (result.decision === "allow") {
        process.stdout.write("allow\n");
      } else {
        process.stdout.write(`deny\t${result.code}\t${result.reason}\n`);
      }
    }
  } catch (error) {
    process.stderr.write(`${error.message}\n`);
    process.exitCode = 1;
  }
}

export { decision };

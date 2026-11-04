#!/usr/bin/env node
// Read shell command data from stdin; print deny for fleet mutations, allow for
// observations/repair. Reuse the existing lexer; never evaluate submitted text.
import { readFileSync } from 'node:fs';
import { Lexer, splitProgram, commandPosition, shellInvocation, shellHeredocPayloads, shellHereStringPayloads, sourcedScript, evalPayload } from './fm-arm-command-policy.mjs';
const fleet = value => /(?:^|\/)fm-(?:spawn|send)\.sh$/.test(value);
function mutates(source, depth = 0, inheritedFleet = false) {
  if (depth > 12) return true;
  const lexed = new Lexer(source).tokenize();
  if (lexed.error) return /fm-(?:spawn|send)/.test(source);
  const mentionsFleet = inheritedFleet || /fm-(?:spawn|send)/.test(source)
    || lexed.tokens.some(token => /fm-(?:spawn|send)/.test(token.value || ''));
  for (const token of lexed.tokens) {
    if (token.type === 'group' && mutates(token.content, depth + 1, mentionsFleet)) return true;
    for (const sub of token.subs || []) if (mutates(sub.content, depth + 1, mentionsFleet)) return true;
  }
  for (const node of splitProgram(lexed.tokens).nodes) {
    let position = commandPosition(node);
    while (position.command?.literal && !position.command.quoted
      && /^(?:if|then|else|elif|while|until|do|!|time)$/.test(position.command.value)) {
      let index = position.index + 1;
      if (position.command.value === 'time' && position.words[index]?.value === '-p') index++;
      position = commandPosition(position.words.slice(index));
    }
    if (position.command?.literal && !position.command.quoted
      && /^(?:for|fi|done)$/.test(position.command.value)) continue;
    const command = position.command?.value || '';
    if ((position.unresolvedWrapperOption || (position.command && !position.command.literal)
      || /^(?:select|case|esac|function|coproc|builtin)$/.test(command))
      && mentionsFleet) return true;
    if (fleet(command)) return true;
    const shell = shellInvocation(position);
    const script = shell?.kind === 'script' ? shell.payload : shell?.operand;
    const sourced = sourcedScript(position);
    if (fleet(script?.value || '') || fleet(sourced?.value || '')) return true;
    const evaluated = evalPayload(position);
    if (mentionsFleet && (
      [shell?.payload, script, sourced].some(word => word && !word.literal)
      || (/(?:^|\/)eval$/.test(command) && position.words.length > position.index + 1 && evaluated == null)
    )) return true;
    const heredocs = shellHeredocPayloads(node, position);
    const hereStrings = shellHereStringPayloads(node, position);
    for (const payload of [
      ...position.wrapperPayloads,
      shell?.kind === 'command' ? shell.payload?.value : null,
      ...heredocs,
      ...hereStrings,
      evaluated,
    ]) {
      if (payload != null && mutates(payload, depth + 1, mentionsFleet)) return true;
    }
    if (shell?.kind === 'stdin' && !heredocs.length && !hereStrings.length && mentionsFleet) return true;
  }
  return false;
}
process.stdout.write(mutates(readFileSync(0, 'utf8')) ? 'deny\n' : 'allow\n');

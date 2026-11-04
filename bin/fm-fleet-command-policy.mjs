#!/usr/bin/env node
// Read shell command data from stdin; print deny for fleet mutations, allow for
// observations/repair. Reuse the existing lexer; never evaluate submitted text.
import { readFileSync } from 'node:fs';
import { Lexer, splitProgram, commandPosition, shellInvocation, shellHeredocPayloads, shellHereStringPayloads, sourcedScript, evalPayload } from './fm-arm-command-policy.mjs';
const fleet = value => /(?:^|\/)fm-(?:spawn|send)\.sh$/.test(value);
function mutates(source, depth = 0) {
  if (depth > 12) return true;
  const lexed = new Lexer(source).tokenize();
  if (lexed.error) return /fm-(?:spawn|send)/.test(source);
  for (const token of lexed.tokens) {
    if (token.type === 'group' && mutates(token.content, depth + 1)) return true;
    for (const sub of token.subs || []) if (mutates(sub.content, depth + 1)) return true;
  }
  const mentionsFleet = /fm-(?:spawn|send)/.test(source)
    || lexed.tokens.some(token => /fm-(?:spawn|send)/.test(token.value || ''));
  for (const node of splitProgram(lexed.tokens).nodes) {
    const position = commandPosition(node);
    const command = position.command?.value || '';
    if ((position.unresolvedWrapperOption || (position.command && !position.command.literal)
      || /^(?:if|then|else|elif|fi|for|select|while|until|case|esac|do|done|function|time|coproc|builtin|!)$/.test(position.words[0]?.value || ''))
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
      || (position.wrapperPayloads.length && position.words.some(word => !word.literal))
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
      if (payload != null && mutates(payload, depth + 1)) return true;
    }
    if (shell?.kind === 'stdin' && !heredocs.length && !hereStrings.length && mentionsFleet) return true;
    if (shell?.kind === 'script' && /^\/dev\/(?:stdin|fd\/0)$/.test(script?.value || '') && mentionsFleet) return true;
    if (/^(?:.*\/)?(?:dash|ksh)$/.test(command) && mentionsFleet) return true;
  }
  return false;
}
process.stdout.write(mutates(readFileSync(0, 'utf8')) ? 'deny\n' : 'allow\n');

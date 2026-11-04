#!/usr/bin/env node
// Read shell command data from stdin; print deny for fleet mutations, allow for
// observations/repair. Reuse the existing lexer; never evaluate submitted text.
import { readFileSync } from 'node:fs';
import { Lexer, splitProgram, commandPosition } from './fm-arm-command-policy.mjs';
const fleet = value => /(?:^|\/)fm-(?:spawn|send)\.sh$/.test(value);
function mutates(source, depth = 0) {
  if (depth > 12) return true;
  const lexed = new Lexer(source).tokenize();
  if (lexed.error) return /fm-(?:spawn|send)/.test(source);
  for (const token of lexed.tokens) {
    if (token.type === 'group' && mutates(token.content, depth + 1)) return true;
    for (const sub of token.subs || []) if (mutates(sub.content, depth + 1)) return true;
  }
  for (const node of splitProgram(lexed.tokens).nodes) {
    const position = commandPosition(node);
    const command = position.command?.value || '';
    if (fleet(command)) return true;
    if (/^(?:.*\/)?(?:ba|da|z|k)?sh$/.test(command)) {
      const args = position.words.slice(position.index + 1);
      for (let i = 0; i < args.length; i++) {
        if (/^-[^-]*c/.test(args[i].value)) {
          if (mutates(args[i + 1]?.value || '', depth + 1)) return true;
          break;
        }
        if (fleet(args[i].value)) return true;
        if (!args[i].value.startsWith('-')) break;
      }
    }
  }
  return false;
}
process.stdout.write(mutates(readFileSync(0, 'utf8')) ? 'deny\n' : 'allow\n');

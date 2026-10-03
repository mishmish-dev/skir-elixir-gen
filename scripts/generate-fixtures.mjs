// Dependency-free generator smoke fixture. This deliberately does NOT pretend
// to parse Skir: integration.mjs tests the real compiler separately.
import {mkdir, writeFile} from 'node:fs/promises';
import {fileURLToPath} from 'node:url';
import path from 'node:path';
import {generateCode} from '../src/generator.js';
import {exampleInput} from '../fixtures/schema.mjs';
const root = fileURLToPath(new URL('../', import.meta.url));
const output = path.join(root, 'example/lib/skirout');
const result = generateCode(exampleInput());
for (const file of result.files) {
  const target = path.join(output, file.path);
  await mkdir(path.dirname(target), {recursive: true});
  await writeFile(target, file.code);
}
console.log(`Generated ${result.files.length} Elixir files from resolved-IR fixtures (not the Skir parser).`);

/** Install and execute the actual npm generator distribution in a fresh project. */
import assert from 'node:assert/strict';
import { execFileSync } from 'node:child_process';
import { mkdir, mkdtemp, readFile, rm, writeFile } from 'node:fs/promises';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const root = fileURLToPath(new URL('../', import.meta.url));
const manifest = JSON.parse(
  await readFile(path.join(root, 'package.json'), 'utf8'),
);
const packages = path.join(root, '.artifacts/packages');
await mkdir(packages, { recursive: true });
function run(command, args, cwd = root, capture = false) {
  return execFileSync(command, args, {
    cwd,
    encoding: 'utf8',
    stdio: capture ? ['ignore', 'pipe', 'inherit'] : 'inherit',
  });
}
const [packed] = JSON.parse(
  run(
    'npm',
    ['pack', '--ignore-scripts', '--json', '--pack-destination', packages],
    root,
    true,
  ),
);
const npmTarball = path.join(packages, packed.filename);
assert(
  !packed.files.some(
    ({ path: name }) =>
      name.startsWith('runtime/') ||
      name.endsWith('.ex') ||
      name.endsWith('mix.exs'),
  ),
  'Generator archive must not bundle client/runtime code',
);
const consumer = await mkdtemp(path.join(root, '.artifacts/consumer-'));
try {
  await writeFile(
    path.join(consumer, 'package.json'),
    JSON.stringify({ private: true, type: 'module' }),
  );
  run(
    'npm',
    [
      'install',
      '--ignore-scripts',
      '--no-audit',
      '--no-fund',
      npmTarball,
      `skir@${manifest.devDependencies.skir}`,
    ],
    consumer,
  );
  run(
    process.execPath,
    [
      '--input-type=module',
      '-e',
      "import {GENERATOR} from 'skir-elixir-gen'; if (GENERATOR.id !== 'skir-elixir-gen') throw Error('Invalid plugin export');",
    ],
    consumer,
  );
  await mkdir(path.join(consumer, 'skir-src'));
  await writeFile(
    path.join(consumer, 'skir-src/message.skir'),
    'struct Message { text: string; }\n',
  );
  await writeFile(
    path.join(consumer, 'skir.yml'),
    JSON.stringify({
      generators: [
        {
          mod: 'skir-elixir-gen',
          outDir: './lib/skirout',
          config: { namespace: 'Consumer' },
        },
      ],
    }),
  );
  run(path.join(consumer, 'node_modules/.bin/skir'), ['gen'], consumer);
  assert.match(
    await readFile(path.join(consumer, 'lib/skirout/message_skir.ex'), 'utf8'),
    /defmodule Consumer\.MessageSkir\.Message do/,
  );
  console.log(
    'PASS: installed npm plugin and generated Elixir bindings through the real compiler.',
  );
} finally {
  await rm(consumer, { recursive: true, force: true });
}

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
    'import { User } from "@acme/models/accounts/user.skir"; struct Message { text: string; user: User; } const GUEST: User = { address: { city: "London" }, pets: [] }; method GetUser(int64): User = 12345;\n',
  );
  // Use the compiler's dependency cache to exercise imports without live GitHub.
  // The models package depends on base, testing transitive resolution as well.
  await mkdir(path.join(consumer, 'skir-external'));
  await writeFile(
    path.join(consumer, 'skir-external/dependencies.json'),
    JSON.stringify({
      '@acme/base': {
        packageId: '@acme/base',
        version: 'v1.0.0',
        dependencies: {},
        modules: {
          '@acme/base/types.skir': 'struct Address { city: string; }',
        },
      },
      '@acme/models': {
        packageId: '@acme/models',
        version: 'v1.0.0',
        dependencies: { '@acme/base': 'v1.0.0' },
        modules: {
          '@acme/models/accounts/user.skir':
            'import { Address } from "@acme/base/types.skir"; struct User { address: Address; struct Pet { name: string; } pets: [Pet]; }',
        },
      },
    }),
  );
  await writeFile(
    path.join(consumer, 'skir.yml'),
    JSON.stringify({
      dependencies: { '@acme/models': 'v1.0.0' },
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
  run(
    'mix',
    [
      'run',
      '--no-start',
      path.join(root, 'scripts/dependency-check.exs'),
      path.join(consumer, 'lib/skirout'),
    ],
    path.join(root, 'example'),
  );
  console.log(
    'PASS: installed npm plugin, compiled transitive dependency bindings, codecs, constants and reflection.',
  );
} finally {
  await rm(consumer, { recursive: true, force: true });
}

/** Install and execute the actual npm and Hex distributions in a fresh app. */
import assert from 'node:assert/strict';
import { execFileSync } from 'node:child_process';
import { cp, mkdir, mkdtemp, readFile, rm, writeFile } from 'node:fs/promises';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const root = fileURLToPath(new URL('../', import.meta.url));
const manifest = JSON.parse(
  await readFile(path.join(root, 'package.json'), 'utf8'),
);
const runtime = path.join(root, 'runtime');
const mixProject = await readFile(path.join(runtime, 'mix.exs'), 'utf8');
assert.equal(
  mixProject.match(/version:\s*"([^"]+)"/)[1],
  manifest.version,
  'npm and Hex versions must match',
);
const packages = path.join(root, '.artifacts/packages');
await mkdir(packages, { recursive: true });
function run(command, args, cwd = root, capture = false) {
  return execFileSync(command, args, {
    cwd,
    env: { ...process.env, MIX_ENV: 'prod' },
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
const hexTarball = path.join(packages, `skir-${manifest.version}.tar`);
run('mix', ['deps.get', '--check-locked'], runtime);
run('mix', ['hex.build', '--output', hexTarball], runtime);
run('npm', [
  'publish',
  npmTarball,
  '--dry-run',
  '--ignore-scripts',
  '--access',
  'public',
]);

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
  const vendor = path.join(consumer, 'vendor/skir');
  await mkdir(vendor, { recursive: true });
  run('tar', ['-xf', hexTarball, '-C', vendor]);
  run('tar', ['-xzf', path.join(vendor, 'contents.tar.gz'), '-C', vendor]);
  // The vendored npm runtime must be identical to the separately shipped Hex code.
  for (const file of packed.files.filter(({ path: name }) =>
    name.startsWith('runtime/lib/'),
  )) {
    assert.equal(
      await readFile(
        path.join(consumer, 'node_modules/skir-elixir-gen', file.path),
        'utf8',
      ),
      await readFile(
        path.join(vendor, file.path.slice('runtime/'.length)),
        'utf8',
      ),
    );
  }
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
  await writeFile(
    path.join(consumer, 'mix.exs'),
    `
defmodule Consumer.MixProject do
  use Mix.Project
  def project, do: [app: :consumer, version: "0.0.0", deps: [{:skir, path: "vendor/skir"}]]
  def application, do: [extra_applications: [:logger]]
end
`,
  );
  await cp(path.join(runtime, 'mix.lock'), path.join(consumer, 'mix.lock'));
  run('mix', ['deps.get', '--check-locked'], consumer);
  run('mix', ['compile', '--warnings-as-errors'], consumer);
  run(
    'mix',
    [
      'run',
      '-e',
      `
    alias Consumer.MessageSkir.Message
    value = Message.new(text: "packed ☃")
    ^value = Message.decode!(Message.encode!(value))
    ^value = Message.decode_json!(Message.encode_json!(value))
  `,
    ],
    consumer,
  );
  console.log(
    'PASS: installed npm plugin, Hex runtime, real code generation and native round-trips.',
  );
} finally {
  await rm(consumer, { recursive: true, force: true });
}

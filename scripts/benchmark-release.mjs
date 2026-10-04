/** Build and measure a real OTP release; requires generated/compiler dependencies. */
import { spawnSync } from 'node:child_process';
import { mkdir, readFile, rm, writeFile } from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const root = fileURLToPath(new URL('../', import.meta.url));
const example = path.join(root, 'example');
const artifacts = path.join(root, '.artifacts');
await mkdir(artifacts, { recursive: true });
const output = path.join(artifacts, 'release-benchmark.json');
await rm(output, { force: true });
const env = {
  ...process.env,
  MIX_ENV: 'prod',
  SKIR_BENCHMARK_OUTPUT: output,
  SKIR_BENCHMARK_SCRIPT: path.join(root, 'scripts/benchmark.exs'),
};
function run(command, args, cwd = example) {
  const result = spawnSync(command, args, {
    cwd,
    env,
    stdio: 'inherit',
    timeout: 300_000,
  });
  if (result.error) throw result.error;
  if (result.status !== 0)
    throw new Error(`${command} ${args.join(' ')} exited ${result.status}`);
}

run(process.execPath, ['scripts/configure-example.mjs'], root);
const compilerDir = path.join(root, 'node_modules/skir');
const compiler = JSON.parse(
  await readFile(path.join(compilerDir, 'package.json')),
);
const cli = typeof compiler.bin === 'string' ? compiler.bin : compiler.bin.skir;
run(process.execPath, [path.join(compilerDir, cli), 'gen']);
run('mix', ['deps.get', '--check-locked']);
run('mix', ['release', 'skir_example', '--overwrite']);
run(path.join(example, '_build/prod/rel/skir_example/bin/skir_example'), [
  'eval',
  'Code.eval_file(System.fetch_env!("SKIR_BENCHMARK_SCRIPT"))',
]);

const summary = JSON.parse(await readFile(output, 'utf8'));
const generator = JSON.parse(await readFile(path.join(root, 'package.json')));
summary.generator_version = generator.version;
summary.compiler_version = compiler.version;
summary.host = {
  platform: os.platform(),
  release: os.release(),
  architecture: os.arch(),
  cpu: os.cpus()[0]?.model ?? 'unknown',
  logical_cpus: os.cpus().length,
  memory_bytes: os.totalmem(),
};
await writeFile(output, JSON.stringify(summary, null, 2) + '\n');
console.log(`PASS: OTP release benchmark saved to ${output}`);

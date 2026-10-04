import { writeFile } from 'node:fs/promises';
import { fileURLToPath } from 'node:url';
const plugin = new URL('../src/index.js', import.meta.url).href;
const config = {
  generators: [
    {
      mod: plugin,
      outDir: './lib/skirout',
      config: { namespace: 'Example.Protocol' },
    },
    {
      mod: 'skir-typescript-gen',
      outDir: './reference/skirout',
      config: { importPathExtension: '.js' },
    },
  ],
};
// JSON is valid YAML. An absolute file URL avoids Node resolving a relative
// plugin path against the Skir compiler's own installation directory.
await writeFile(
  fileURLToPath(new URL('../example/skir.yml', import.meta.url)),
  JSON.stringify(config, null, 2) + '\n',
);
console.log('Wrote example/skir.yml with an absolute generator file URL.');

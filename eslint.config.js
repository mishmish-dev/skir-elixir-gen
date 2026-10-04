import js from '@eslint/js';
import globals from 'globals';

export default [
  { ignores: ['node_modules/**', '.artifacts/**', 'example/reference/**'] },
  {
    ...js.configs.recommended,
    files: [
      'src/**/*.js',
      'scripts/**/*.mjs',
      'test/**/*.mjs',
      'fixtures/*.mjs',
      'eslint.config.js',
    ],
    languageOptions: { globals: globals.node },
  },
];

import {z} from 'zod';
import {generateCode} from './generator.js';

/** @type {import('skir-internal').CodeGenerator<{namespace?: string}>} */
export const GENERATOR = Object.freeze({
  id: 'skir-elixir-gen',
  configType: z.strictObject({
    namespace: z.string().regex(/^[A-Z][A-Za-z0-9_]*(?:\.[A-Z][A-Za-z0-9_]*)*$/).optional(),
  }),
  generateCode,
});

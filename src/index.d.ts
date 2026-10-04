import type { CodeGenerator } from 'skir-internal';
export interface Config {
  readonly namespace?: string;
}
export declare const GENERATOR: CodeGenerator<Config>;

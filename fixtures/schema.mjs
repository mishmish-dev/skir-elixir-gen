// Resolved-IR fixtures, shaped after skir-internal 0.2.21. These are not a parser.
export const primitive = primitive => ({kind: 'primitive', primitive});
export const optional = other => ({kind: 'optional', other});
export const array = (item, key) => ({kind: 'array', item, key});
export const ref = (key, recordType = 'struct') => ({kind: 'record', key, recordType});
export function field(name, number, type, isRecursive = false) {
  return {kind: 'field', name: {text: name}, number, type, isRecursive, doc: {text: ''}};
}
export function record(path, names, recordType, fields, removedNumbers = []) {
  const key = `${path}:${names.join('.')}`;
  const rec = {kind: 'record', key, name: {text: names.at(-1)}, recordType,
    fields, removedNumbers, recordNumber: null, doc: {text: ''},
    numSlotsInclRemovedNumbers: recordType === 'enum' ? 0 : Math.max(-1, ...fields.map(f => f.number), ...removedNumbers) + 1};
  return {kind: 'record-location', record: rec, modulePath: path,
    recordAncestors: [...names.slice(0, -1).map(n => ({name: {text: n}})), rec]};
}
export function input(records, config = {}) {
  const groups = new Map();
  for (const r of records) {
    if (!groups.has(r.modulePath)) groups.set(r.modulePath, {kind: 'module', path: r.modulePath,
      records: [], constants: [], methods: [], pathToImportedNames: {}});
    groups.get(r.modulePath).records.push(r);
  }
  return {modules: [...groups.values()], recordMap: new Map(records.map(r => [r.record.key, r])), config};
}
export function exampleInput() {
  const p = primitive;
  const pet = record('user.skir', ['User', 'Pet'], 'struct', [field('name', 0, p('string')), field('picture', 1, p('string'))]);
  const address = record('common.skir', ['Address'], 'struct', [field('city', 0, p('string'))]);
  const event = record('user.skir', ['Event'], 'enum', [field('connected', 1), field('user_created', 2, ref('user.skir:User')), field('message', 5, p('string'))], [3, 4]);
  const user = record('user.skir', ['User'], 'struct', [
    field('id', 0, p('int64')), field('name', 2, p('string')), field('active', 3, p('bool')),
    field('nickname', 4, optional(p('string'))), field('pets', 5, array(ref(pet.record.key))),
    field('address', 6, ref(address.record.key)), field('avatar', 7, p('bytes')),
    field('created_at', 8, p('timestamp')), field('status', 9, ref(event.record.key, 'enum'))
  ], [1]);
  const node = record('tree.skir', ['Node'], 'struct', [field('value', 0, p('string')),
    field('next', 1, optional(ref('tree.skir:Node')), 'via-optional'),
    field('children', 2, array(ref('tree.skir:Node')), 'soft')]);
  const loop = record('tree.skir', ['Loop'], 'struct', [field('next', 0, ref('tree.skir:Loop'), 'hard')]);
  const result = input([pet, user, event, address, node, loop], {namespace: 'Example.Protocol'});
  const m = result.modules.find(m => m.path === 'user.skir');
  m.constants.push({name: {text: 'ALICE'}, type: ref(user.record.key), valueAsDenseJson: [42, 0, 'Alice']});
  m.methods.push({name: {text: 'GetUser'}, number: 12345, requestType: p('int64'), responseType: ref(user.record.key), doc: {text: 'Load one user.'}});
  return result;
}

const fs = require('node:fs');
const vm = require('node:vm');
const assert = require('node:assert/strict');
const source = fs.readFileSync('Resources/state-bridge.js', 'utf8');
const key = 't3code:ui-state:v1';
function launch(saved, script) {
  const messages = [];
  const context = vm.createContext({ saved, messages, location: { protocol: 'http:' } });
  vm.runInContext(`
    class Storage {
      values = {};
      getItem(k) { return this.values[k] ?? null; }
      setItem(k,v) { this.values[k] = String(v); }
      removeItem(k) { delete this.values[k]; }
      clear() { this.values = {}; }
    }
    const localStorage = new Storage();
    const window = { localStorage, webkit: { messageHandlers: { t3pm: {
      postMessage(m) { messages.push(m); }
    } } } };
  `, context);
  vm.runInContext(script, context);
  return { messages, run: code => vm.runInContext(code, context) };
}
function restart(script) {
  const state = JSON.stringify({ sidebarProjectScopeKey: 'folder:/Projects/one' });
  const first = launch(null, script);
  first.run(`localStorage.setItem('${key}', ${JSON.stringify(state)})`);
  assert.equal(first.messages.at(-1).value, state, 'project changes must be backed up');
  const second = launch(first.messages.at(-1).value, script);
  assert.equal(second.run(`localStorage.getItem('${key}')`), state, 'new origin must restore project');
  second.run(`localStorage.removeItem('${key}')`);
  assert.equal(second.messages.at(-1).value, null, 'clearing selection must persist');
}
restart(source);
for (const mutation of [
  source.replace('if (saved !== null) storage.setItem(key, saved);', ''),
  source.replace(')) report();', ')) {}'),
]) {
  assert.notEqual(mutation, source);
  assert.throws(() => restart(mutation), { name: 'AssertionError' });
}
console.log('Restart checks passed; missing restore and missing capture mutations caught.');

// Run with: node tests/design-states.cjs
// Deterministic checks for boot replay and interrupted sleep transitions.
const fs = require('node:fs');
const vm = require('node:vm');
const assert = require('node:assert/strict');
const html = fs.readFileSync(require('node:path').join(__dirname, '../dashboard.html'), 'utf8');
const script = html.match(/<script>([\s\S]*?)<\/script>/)[1];
new vm.Script(script);
const ids = [...html.matchAll(/\bid="([^"]+)"/g)].map(m => m[1]);
assert.equal(new Set(ids).size, ids.length);
for (const m of script.matchAll(/getElementById\('([^']+)'\)/g)) assert.ok(ids.includes(m[1]), m[1]);
function element() {
  const classes = new Set();
  return {style: {}, offsetWidth: 1, textContent: '', classList: {
    add: (...names) => names.forEach(n => classes.add(n)),
    remove: (...names) => names.forEach(n => classes.delete(n)),
    contains: n => classes.has(n),
    toggle: (n, on) => on ? classes.add(n) : classes.delete(n)
  }};
}
const elements = Object.fromEntries(ids.map(id => [id, element()]));
const body = element(), fill = element(), marks = Array.from({length: 4}, element);
elements.boot.querySelector = () => fill;
elements.boot.querySelectorAll = () => marks;
let now = 0, nextId = 0;
const tasks = new Map();
function timer(fn, delay, repeat) { const id = ++nextId; tasks.set(id, {fn, at: now + delay, repeat}); return id; }
function advance(ms) {
  const until = now + ms;
  for (;;) {
    const next = [...tasks].filter(([,t]) => t.at <= until).sort((a,b) => a[1].at-b[1].at)[0];
    if (!next) break;
    const [id,t] = next; now = t.at;
    if (t.repeat) t.at += t.repeat; else tasks.delete(id);
    t.fn();
  }
  now = until;
}
const context = vm.createContext({
  document: {body, getElementById: id => elements[id], querySelectorAll: () => []},
  setTimeout: (fn, ms) => timer(fn, ms, 0), clearTimeout: id => tasks.delete(id),
  setInterval: (fn, ms) => timer(fn, ms, ms), clearInterval: id => tasks.delete(id),
  setSeg() {}, shockwave() {}, SLEEP_PREVIEW_MS:60000, wl: null,
  native:true, PL:{setAwake(){}},keepAwake(){},startOrganism(){}
});
const run = code => vm.runInContext(code, context);
run(script.slice(script.indexOf('const BOOT ='), script.indexOf('const SEG =')));
run(script.slice(script.indexOf('function setMode('), script.indexOf('const IDLE_ENTER')));
run('let screenOff=false,ambient=false;');
run(script.slice(script.indexOf('function setScreenOff('),script.indexOf('/* posle zpravu')));
run(script.slice(script.indexOf('let sleeping ='), script.indexOf('const SLEEP_PREVIEW_MS')));
advance(2100);
assert.ok(elements.boot.classList.contains('done'));
assert.equal(fill.style.width, '100%');
assert.ok(marks.every(m => m.classList.contains('active')));
run("setMode('live'); sleepSequence()");
advance(300);
assert.ok(body.classList.contains('is-suspending'));
run("wakeSequence(); setMode('live')");
assert.ok(!elements.boot.classList.contains('done'));
assert.equal(fill.style.width, '25%');
advance(1400);
assert.ok(body.classList.contains('mode-live'), 'Old sleep callback must not override recovery');
assert.ok(!body.classList.contains('is-suspending'));
assert.equal(elements.stage.style.opacity, '');
advance(800);
assert.ok(elements.boot.classList.contains('done'));
run('sleepSequence()');
advance(1600);
assert.ok(body.classList.contains('mode-sleep'));
run("wakeSequence(); setMode('live')");
assert.equal(fill.style.width, '25%', 'Repeated wake must replay progress');
advance(2200);
assert.ok(elements.boot.classList.contains('done'));
advance(60000);
assert.ok(!body.classList.contains('oled-off'),'Cancelled standby timer must not blank a recovered screen');
run('sleepSequence()');
advance(1600);
assert.ok(!body.classList.contains('oled-off'),'Standby indication should remain visible briefly');
advance(60000);
assert.ok(body.classList.contains('oled-off'),'Standby must eventually become pure black');
run("wakeSequence();setMode('live')");
assert.ok(!body.classList.contains('oled-off'),'Recovery must restore the display');
body.classList.add('needs-fs', 'gen');
for (const mode of ['ambient', 'down', 'sleep', 'live']) {
  run(`setMode('${mode}')`);
  assert.ok(body.classList.contains('mode-' + mode));
  assert.ok(body.classList.contains('needs-fs'));
  assert.ok(body.classList.contains('gen'));
}
// Limity Claude a Codexu: cista logika (stupen, odpocet, popisky, zdroj).
run(script.slice(script.indexOf('const LIM_LABELS='), script.indexOf('/* ================= LIMITY: konec')));
// limState bere KOLIK ZBYVA (jako UsageRing v Relay appce): zelena > 30, zluta <= 30, cervena <= 10
assert.equal(run("limState(NaN).l"), '—');
assert.equal(run("limState(100).l"), 'Volno');
assert.equal(run("limState(31).l"), 'Volno');
assert.equal(run("limState(30).l"), 'Dochází');
assert.equal(run("limState(11).l"), 'Dochází');
assert.equal(run("limState(10).l"), 'Na hraně');
assert.equal(run("limState(0).l"), 'Vyčerpáno');
assert.equal(run("limState(10).c"), run("limState(0).c"), 'Both red like the app');
assert.equal(run("limZbyva(22)"), 78);
assert.equal(run("limZbyva(120)"), 0, 'Over the limit shows nothing left, never negative');
assert.ok(Number.isNaN(run("limZbyva('x')")));
assert.equal(run("limZa(-5)"), 'za chvíli');
assert.equal(run("limZa(59)"), 'za 1 min');
assert.equal(run("limZa(45*60)"), 'za 45 min');
assert.equal(run("limZa(2*3600+13*60)"), 'za 2 h 13 min');
assert.equal(run("limZa(3*3600)"), 'za 3 h');
assert.equal(run("limZa(6*86400+5*3600)"), 'za 6 d 5 h');
assert.equal(run("limLabel('five_hour')"), 'Okno 5 h');
assert.equal(run("limLabel('seven_day_fable')"), 'Týden · Fable');
assert.equal(run("limLabel('seven_day_haiku')"), 'Týden · Haiku', 'Unknown model window must still get a readable label');
assert.equal(run("limLabel('primary')"), 'Okno 5 h');
const t0 = 1788893671;
assert.equal(run(`JSON.stringify(limSource(null, ${t0}))`), JSON.stringify({t:'nedostupné', cls:'stale'}));
assert.equal(run(`limSource({source:'statusline', at:${t0}-30}, ${t0}).cls`), 'live');
assert.equal(run(`limSource({source:'live', at:${t0}-30}, ${t0}).cls`), 'live');
assert.equal(run(`limSource({source:'statusline', at:${t0}-3600}, ${t0}).cls`), 'stale', 'Old live data must not pretend to be live');
assert.equal(run(`limSource({source:'zaloha', at:${t0}-30}, ${t0}).cls`), 'stale');
assert.ok(run(`limSource({source:'usage', at:${t0}-30}, ${t0}).t`).startsWith('/usage'));
// renderLimits: prazdna data nesmi spadnout ani prepisovat DOM dokola
const row = elements.claudeRow; row.dataset = {}; let writes = 0;
Object.defineProperty(row, 'innerHTML', {set(v){ writes++; }, get(){ return ''; }});
assert.equal(run(`renderLimits('claudeRow', null, ${t0})`), 0);
assert.equal(run(`renderLimits('claudeRow', {items:[]}, ${t0})`), 0);
assert.equal(writes, 1, 'Empty state is written once, not on every poll');
console.log('PASS: syntax, DOM references, boot replay, sleep/recovery race, all modes, limit states/countdowns/sources');

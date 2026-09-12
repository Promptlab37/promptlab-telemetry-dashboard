// Run with: node tests/memory-meter.cjs
// The RAM meter reads the physical memory node, never the virtual one, and
// its peak tick only shows when it is far enough from the current fill.
const fs = require('node:fs');
const vm = require('node:vm');
const assert = require('node:assert/strict');
const html = fs.readFileSync(require('node:path').join(__dirname, '../dashboard.html'), 'utf8');

const helpers = html.slice(html.indexOf('function num(s){'), html.indexOf('/* stav nese barvu'));
const state   = html.slice(html.indexOf('function ramState(p){'), html.indexOf('/* ================= LIMITY'));
const render  = html.slice(html.indexOf('/* OPERACNI PAMET'), html.indexOf('/* Sit a teplotni graf'));

const ids = ['ramT', 'ramB', 'ramSt', 'ramFree', 'ramPeak', 'ramPeakT'];
const el = () => ({style: {}, textContent: ''});

function fixture() {
  const nodes = Object.fromEntries(ids.map(id => [id, el()]));
  const context = vm.createContext({document: {getElementById: id => nodes[id]}});
  vm.runInContext(`${helpers}\n${state}
    const L=/^load/i, D=/^data$/i;
    function renderRam(list){ ${render} }`, context);
  return {nodes, render: list => context.renderRam(list)};
}

// LHM reports the same sensor names under both memory nodes; the physical one wins.
const sensors = (used, avail, load, max) => [
  {hw: 'Virtual Memory', grp: 'Data', name: 'Memory Used',      value: '999,0 GB', max: '999,0 GB'},
  {hw: 'Virtual Memory', grp: 'Data', name: 'Memory Available', value: '999,0 GB', max: '999,0 GB'},
  {hw: 'Virtual Memory', grp: 'Load', name: 'Memory',           value: '99,0 %',   max: '99,0 %'},
  {hw: 'Total Memory',   grp: 'Data', name: 'Memory Used',      value: used,  max: max},
  {hw: 'Total Memory',   grp: 'Data', name: 'Memory Available', value: avail, max: avail},
  {hw: 'Total Memory',   grp: 'Load', name: 'Memory',           value: load,  max: '33,0 %'}
];

{
  const f = fixture();
  f.render(sensors('24,7 GB', '70,6 GB', '25,9 %', '31,5 GB'));
  assert.equal(f.nodes.ramT.textContent, '24.7 / 95 GB', 'Physical memory, not the virtual node');
  assert.equal(f.nodes.ramB.style.width, '25.9%');
  assert.equal(f.nodes.ramB.style.background, '#8af5bc');
  assert.equal(f.nodes.ramSt.textContent, 'V normě');
  assert.equal(f.nodes.ramFree.textContent, 'volných 70.6 GB');
  assert.equal(f.nodes.ramPeak.style.display, 'block');
  assert.equal(f.nodes.ramPeak.style.left, 'calc(33.1% - 1.5px)', 'Tick sits at the peak share');
  assert.equal(f.nodes.ramPeakT.textContent, 'špička 31.5 GB');
}

// A peak that equals the current fill would just blur the bar end - keep it hidden.
{
  const f = fixture();
  f.render(sensors('24,7 GB', '70,6 GB', '25,9 %', '24,9 GB'));
  assert.equal(f.nodes.ramPeak.style.display, 'none');
  assert.equal(f.nodes.ramPeakT.style.visibility, 'hidden');
}

// Severity carries a word as well as a colour, and the words match the temperature scale.
{
  const cases = [[60, 'V normě', '#8af5bc'], [78, 'Zvýšená', '#ffd064'],
                 [90, 'Vysoká', '#ff9863'],  [96, 'Kritická', '#ff5369']];
  for (const [pct, word, colour] of cases) {
    const f = fixture();
    f.render(sensors('60,0 GB', '35,3 GB', pct.toFixed(1).replace('.', ',') + ' %', '60,0 GB'));
    assert.equal(f.nodes.ramSt.textContent, word, `${pct} % must read as ${word}`);
    assert.equal(f.nodes.ramB.style.background, colour);
    assert.equal(f.nodes.ramSt.style.color, colour);
  }
}

// Missing sensors must degrade, not crash: LHM can start without the memory node.
{
  const f = fixture();
  f.render([]);
  assert.equal(f.nodes.ramT.textContent, '--');
  assert.equal(f.nodes.ramB.style.width, '0%');
  assert.equal(f.nodes.ramFree.textContent, '—');
  assert.equal(f.nodes.ramPeak.style.display, 'none');
}

// Load alone (no GB readings) still fills the bar and reports the percentage.
{
  const f = fixture();
  f.render([{hw: 'Total Memory', grp: 'Load', name: 'Memory', value: '42,0 %', max: '80,0 %'}]);
  assert.equal(f.nodes.ramT.textContent, '42.0 %');
  assert.equal(f.nodes.ramFree.textContent, 'zaplněno 42 %');
  assert.equal(f.nodes.ramPeakT.textContent, 'špička 80 %');
}

console.log('PASS: physical node, peak tick, severity words, missing sensors, load-only fallback');

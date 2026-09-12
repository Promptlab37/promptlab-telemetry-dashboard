const fs = require('node:fs');
const vm = require('node:vm');
const assert = require('node:assert/strict');
const html = fs.readFileSync(require('node:path').join(__dirname, '../dashboard.html'), 'utf8');
const code = html.slice(html.indexOf('const bio ='), html.indexOf('/* navrat z klidu:'));
function fixture() {
  let frames=0, resets=0;
  const ctx={setTransform(){},clearRect(){},fillRect(){},beginPath(){},ellipse(){},arc(){},stroke(){},fill(){},
    createRadialGradient(){return {addColorStop(){}};}};
  let width=0,height=0;
  const canvas={style:{},getContext:()=>ctx,
    get width(){return width;},set width(v){width=v;resets++;},
    get height(){return height;},set height(v){height=v;resets++;}};
  const context=vm.createContext({document:{getElementById:()=>canvas,body:{classList:{contains:name=>name==='mode-ambient'}}},
    innerWidth:1200,innerHeight:540,devicePixelRatio:2,addEventListener(){},performance:{now:()=>100000000},
    matchMedia:()=>({matches:false}),requestAnimationFrame:()=>++frames});
  vm.runInContext(code,context);
  return {run:s=>vm.runInContext(s,context),get frames(){return frames;},get resets(){return resets;}};
}
const f=fixture();
f.run('startOrganism();drawOrganism(100000000)');
const before=f.run('motion.phase[0]');
f.run('bio.cpuLoad=100;bio.gpuLoad=100;bio.temp=90;drawOrganism(100000016.667)');
assert.ok(f.run('motion.phase[0]')-before<.003,'Load changes must not teleport the orbit even after long uptime');
assert.ok(f.run('motion.cpuLoad')<2,'Load must ease towards the new reading');
assert.ok(f.run('motion.temp')<41,'Temperature must ease rather than jump');
assert.equal(f.run('motion.warning'),0,'Warning ring must not flash on at a sample boundary');
const pending=f.frames,resets=f.resets;
f.run('startOrganism();sizeCanvas()');
assert.equal(f.frames,pending,'Repeated start must not create another animation loop');
assert.equal(f.resets,resets,'Unchanged canvas size must not clear the backing buffer');
const phase=f.run('motion.phase[0]');
f.run('drawOrganism(200000000)');
assert.ok(f.run('motion.phase[0]')-phase<.01,'Resuming after a pause must not catch up with a jump');
function simulate(fps){
  const f=fixture();
  f.run('advanceMotion(0);bio.cpuLoad=100');
  for(let i=1;i<=fps*10;i++)f.run(`advanceMotion(${i*1000/fps})`);
  return f.run('motion.phase[0]');
}
assert.ok(Math.abs(simulate(30)-simulate(120))<.003,'Speed must be independent of frame rate');
const color=t=>f.run(`bioColor(${t},1)`).match(/\d+/g).slice(0,3).map(Number);
for(const t of [60,75,88])assert.ok(color(t-.01).every((v,i)=>Math.abs(v-color(t+.01)[i])<=1),'Temperature colors must blend across thresholds');
console.log('PASS: long uptime/load changes, smoothing, warning fade, single loop, resize, pause recovery, 30/120 FPS, color continuity');

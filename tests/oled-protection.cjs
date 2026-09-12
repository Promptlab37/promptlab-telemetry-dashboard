const fs=require('node:fs'),vm=require('node:vm'),assert=require('node:assert/strict');
const html=fs.readFileSync(require('node:path').join(__dirname,'../dashboard.html'),'utf8');
const script=html.match(/<script>([\s\S]*?)<\/script>/)[1];
const classes=new Set(),calls=[];
let state={idle:0,ssActive:1,ssTimeout:180,screensaver:false},requests=0;
const context=vm.createContext({screenOff:false,ambient:false,native:true,wl:null,sleeping:false,wasAsleep:false,
  SCREEN_OFF:300,IDLE_ENTER:180,PL:{setAwake:v=>calls.push(v)},plog(){},startOrganism(){},shockwave(){},
  setMode:m=>{for(const c of [...classes])if(c.startsWith('mode-'))classes.delete(c);classes.add('mode-'+m);},
  fetch:async()=>({json:async()=>state}),
  navigator:{wakeLock:{request:async()=>{requests++;return {release:async()=>{},addEventListener(){}};}}},
  document:{body:{classList:{toggle:(c,on)=>on?classes.add(c):classes.delete(c)}},querySelectorAll:()=>[]}});
function extract(start,end){const a=script.indexOf(start);assert.ok(a>=0);const b=script.indexOf(end,a);assert.ok(b>a);vm.runInContext(script.slice(a,b),context);}
extract('function setScreenOff(','/* posle zpravu');
extract('async function keepAwake()','\nkeepAwake();');
extract('async function checkIdle()','/* ---------- USINANI');
(async()=>{
  const run=s=>vm.runInContext(s,context);
  await run('keepAwake()');assert.equal(requests,0,'Native WebView must not acquire a second wake lock');
  state.idle=180;await run('checkIdle()');
  assert.ok(classes.has('mode-ambient'));assert.ok(!classes.has('oled-off'));
  state.idle=300;await run('checkIdle()');
  assert.ok(classes.has('oled-off'));assert.deepEqual(calls,[false]);
  await run('checkIdle();keepAwake()');assert.equal(requests,0);assert.deepEqual(calls,[false]);
  state.idle=0;await run('checkIdle()');
  assert.ok(!classes.has('oled-off'));assert.ok(classes.has('mode-live'));assert.deepEqual(calls,[false,true]);
  // A browser wake-lock request may finish after the idle policy has changed.
  context.native=false;let resolve,releases=0;
  context.navigator.wakeLock.request=()=>new Promise(r=>{resolve=r;});
  const pending=run('keepAwake()');run('setScreenOff(true)');
  resolve({release:async()=>{releases++;},addEventListener(){}});await pending;
  assert.equal(releases,1);assert.equal(context.wl,null);
  console.log('PASS: ambient entry, 5-minute blackout, native lock release, return, no duplicate locks, browser lock race');
})().catch(e=>{console.error(e);process.exitCode=1;});

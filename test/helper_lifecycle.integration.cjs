// macOS integration test: uses its own Touch Bar fixture and temporary displays.
// Run after building both this helper and the research TouchTarget fixture.
const {spawn,spawnSync}=require('node:child_process');
const fs=require('node:fs');
const os=require('node:os');
const path=require('node:path');
const assert=require('node:assert/strict');
const {WebSocketServer}=require('ws');
const root=path.resolve(__dirname,'..');
const output=fs.mkdtempSync(path.join(os.tmpdir(),'touchbar-lifecycle-'));
const stateTool=path.join(output,'state');
const helper=path.join(root,'com.chino.touchbaremulator.plugin/resources/TouchBarBridgeHelper.app/Contents/MacOS/TouchBarBridgeHelper');
const fixture=process.env.TOUCHBAR_TEST_FIXTURE || '/Users/aspen/dev/TouchbarDesigner/tools/touchbar-macos27-research/build/TouchTarget.app/Contents/MacOS/TouchTarget';
const delay=ms=>new Promise(r=>setTimeout(r,ms));
let child,target,server,socket,layout;
function state(){const p=spawnSync(stateTool,[],{encoding:'utf8'});assert.equal(p.status,0,p.stderr);return JSON.parse(p.stdout);}
async function until(fn,timeout=10000){const end=Date.now()+timeout;while(Date.now()<end){if(fn())return;await delay(100);}throw new Error('timed out');}
(async()=>{
 const compile=spawnSync('clang',['-fobjc-arc','-framework','AppKit','-framework','CoreGraphics',path.join(__dirname,'HelperSystemState.m'),'-o',stateTool],{encoding:'utf8'});
 assert.equal(compile.status,0,compile.stderr);
 if(process.env.TOUCHBAR_TEST_MULTISCREEN==='1'){
  const layoutTool=path.join(output,'layout');
  const build=spawnSync('clang',['-fobjc-arc','-framework','AppKit','-framework','CoreGraphics',path.join(__dirname,'VirtualDisplayLayoutFixture.m'),'-o',layoutTool],{encoding:'utf8'});
  assert.equal(build.status,0,build.stderr);
  let ready=false;
  layout=spawn(layoutTool);layout.stdout.on('data',d=>{if(String(d).includes('LAYOUT_READY'))ready=true;});
  layout.stderr.on('data',()=>{});
  await until(()=>ready);
 }
 target=spawn(fixture,[],{stdio:['ignore','ignore','pipe']});
 target.stderr.on('data',()=>{});await delay(800);
 const initial=state();assert.equal(initial.leftDown,false,'release the real mouse before testing');
 const existing=initial.displays.filter(d=>!(d.vendor===0x756e6b6e&&d.model===0x76697274));
 function assertExistingUnchanged(current){for(const display of existing){assert.deepEqual(current.displays.find(d=>d.id===display.id),display,'existing display position, resolution, scale, primary and mirror state must be unchanged');}}
 if(layout)assert(existing.length>=2,'multiscreen fixture must provide two existing displays');
 const records=[];
 for(const termination of ['SIGTERM','disconnect']){
  server=new WebSocketServer({host:'127.0.0.1',port:0});
  await new Promise(r=>server.once('listening',r));
  let frames=0,exited=false,log='',pressed=false;
  server.once('connection',ws=>{socket=ws;ws.on('message',(data,binary)=>{if(binary)frames++;else {const m=JSON.parse(data);if(m.type==='mouse-dispatched'&&m.down)pressed=true;}});});
  child=spawn(helper,['--url',`ws://127.0.0.1:${server.address().port}/test`,'--hidden-stream','--style','3','--mouse-dispatch','service','--fps','30']);
  child.stderr.on('data',d=>log+=d);child.stdout.on('data',d=>log+=d);
  child.on('exit',()=>exited=true);
  await until(()=>frames>=1||exited);assert(!exited,log);
  const before=state();assert.deepEqual(before.displays,initial.displays,'hidden stream must not create or alter displays');
  assertExistingUnchanged(before);
  socket.send(JSON.stringify({type:'mouse',x:550,y:30,width:2170,height:60,down:true}));
  await until(()=>pressed,3000);
  await delay(150);
  const during=state();
  assert.equal(during.leftDown,false,'service touch must not press desktop mouse');
  assert(Math.hypot(during.cursor[0]-before.cursor[0],during.cursor[1]-before.cursor[1])<2,'service touch must not move cursor');
  if(termination==='SIGTERM')child.kill('SIGTERM');else socket.terminate();
  await until(()=>exited,4000);await delay(600);
  server.close();socket=null;
  const after=state();
  assertExistingUnchanged(after);
  assert(!after.displays.some(d=>d.vendor===0xF17B),'owned displays must be removed');
  assert.equal(after.leftDown,false,'a killed gesture must release the mouse');
  assert(Math.hypot(after.cursor[0]-before.cursor[0],after.cursor[1]-before.cursor[1])<2,'cursor must be restored');
  assert.equal(after.displays.length,initial.displays.length);
  records.push({termination,frames,before,after});fs.writeFileSync(path.join(output,termination+'.log'),log);
 }
 fs.writeFileSync(path.join(output,'results.json'),JSON.stringify(records,null,2));
 console.log(`PASS: existing display layouts preserved; SIGTERM and WebSocket loss release service touch and leave displays unchanged without changing desktop mouse. ${output}`);
})().catch(e=>{console.error(e);process.exitCode=1;}).finally(()=>{
 try{socket?.terminate();server?.close();child?.kill('SIGTERM');target?.kill('SIGTERM');layout?.kill('SIGTERM');}catch{}
});

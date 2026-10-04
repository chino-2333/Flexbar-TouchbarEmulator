// Simulate attaching/removing existing monitors while the hidden capture runs.
const {spawn,spawnSync}=require('node:child_process');
const fs=require('node:fs'),path=require('node:path'),os=require('node:os');
const assert=require('node:assert/strict');
const {WebSocketServer}=require('ws');
const root=path.resolve(__dirname,'..');
const output=fs.mkdtempSync(path.join(os.tmpdir(),'touchbar-hidden-hotplug-'));
const helper=path.join(root,'com.chino.touchbaremulator.plugin/resources/TouchBarBridgeHelper.app/Contents/MacOS/TouchBarBridgeHelper');
const delay=ms=>new Promise(r=>setTimeout(r,ms));
let child,target,layout,server,socket,log='',targetLog='',messages=[],frames=0,exited=false;
async function until(fn,timeout=12000){const end=Date.now()+timeout;while(Date.now()<end){if(fn())return;await delay(50);}throw Error('timed out: '+log.slice(-1500));}
function compile(source,out){const r=spawnSync('clang',['-fobjc-arc','-framework','AppKit','-framework','CoreGraphics',path.join(__dirname,source),'-o',out],{encoding:'utf8'});assert.equal(r.status,0,r.stderr);}
function state(){const r=spawnSync(path.join(output,'state'),[],{encoding:'utf8'});assert.equal(r.status,0,r.stderr);return JSON.parse(r.stdout);}
async function click(){const n=(targetLog.match(/ISOLATION_BUTTON/g)||[]).length;for(const down of [true,false]){socket.send(JSON.stringify({type:'mouse',x:270,y:30,width:2170,height:60,down}));await delay(150);}await until(()=>(targetLog.match(/ISOLATION_BUTTON/g)||[]).length>n);assert(!exited);}
(async()=>{
 compile('VirtualDisplayLayoutFixture.m',path.join(output,'layout'));compile('HelperSystemState.m',path.join(output,'state'));
 const app=path.join(output,'Fixture.app');fs.mkdirSync(path.join(app,'Contents/MacOS'),{recursive:true});
 fs.writeFileSync(path.join(app,'Contents/Info.plist'),'<?xml version="1.0"?><plist version="1.0"><dict><key>CFBundleExecutable</key><string>Fixture</string><key>CFBundleIdentifier</key><string>com.chino.touchbar.hotplug-test</string><key>CFBundlePackageType</key><string>APPL</string></dict></plist>');
 compile('InputIsolationFixture.m',path.join(app,'Contents/MacOS/Fixture'));
 target=spawn(path.join(app,'Contents/MacOS/Fixture'));target.stderr.on('data',d=>targetLog+=d);await until(()=>targetLog.includes('ISOLATION_READY'));await delay(700);
 const initial=state();
 server=new WebSocketServer({host:'127.0.0.1',port:0});await new Promise(r=>server.once('listening',r));
 server.once('connection',ws=>{socket=ws;ws.on('message',(d,b)=>{if(b)frames++;else messages.push(JSON.parse(d));});});
 child=spawn(helper,['--url',`ws://127.0.0.1:${server.address().port}/test`,'--hidden-stream']);child.stderr.on('data',d=>log+=d);child.on('exit',()=>exited=true);
 await until(()=>frames>0||exited);assert(!exited);await delay(1800);await click();
 assert.deepEqual(state().displays,initial.displays);
 let ready=false;layout=spawn(path.join(output,'layout'));layout.stdout.on('data',d=>{if(String(d).includes('LAYOUT_READY'))ready=true;});layout.stderr.on('data',()=>{});
 await until(()=>ready);await delay(1800);const attached=state();assert(attached.displays.length>=2);await click();
 let removed=false;layout.on('exit',()=>removed=true);layout.kill('SIGTERM');await until(()=>removed);await delay(1800);await click();
 const detached=state();assert(!detached.displays.some(d=>d.vendor===0x54455354));assert(!detached.displays.some(d=>d.vendor===0xF17B));
 assert(!messages.some(m=>m.type==='error'||m.type==='mouse-dispatch-error'));
 child.kill('SIGTERM');await until(()=>exited);
 fs.writeFileSync(path.join(output,'results.json'),JSON.stringify({initial,attached,detached,frames,messages},null,2));
 console.log('PASS: capture and actual button callbacks survive simulated monitor attach/removal; no plugin virtual display. '+output);
})().catch(e=>{console.error(e);process.exitCode=1;}).finally(()=>{
 fs.writeFileSync(path.join(output,'helper.log'),log);fs.writeFileSync(path.join(output,'fixture.log'),targetLog);
 socket?.terminate();server?.close();child?.kill('SIGTERM');layout?.kill('SIGTERM');target?.kill('SIGTERM');
});

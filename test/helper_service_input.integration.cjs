// Actual Apple XPC integration: callbacks AND cursor/button/focus isolation.
// The separate driver emulates desktop HID input only in our own test window.
const {spawn,spawnSync}=require('node:child_process');
const fs=require('node:fs'),path=require('node:path'),os=require('node:os');
const assert=require('node:assert/strict');
const {WebSocketServer}=require('ws');
const root=path.resolve(__dirname,'..');
const output=fs.mkdtempSync(path.join(os.tmpdir(),'touchbar-service-input-'));
const helper=process.env.TOUCHBAR_BRIDGE_HELPER || path.join(root,'com.chino.touchbaremulator.plugin/resources/TouchBarBridgeHelper.app/Contents/MacOS/TouchBarBridgeHelper');
const delay=ms=>new Promise(r=>setTimeout(r,ms));
let target,driver,child,socket,server,latest,windowBounds,targetLog='',helperLog='',samples=[],messages=[],frames=0,exited=false;
function run(cmd,args){const r=spawnSync(cmd,args,{encoding:'utf8'});assert.equal(r.status,0,r.stderr);}
async function until(fn,timeout=12000){const end=Date.now()+timeout;while(Date.now()<end){if(fn())return;await delay(30);}throw Error('timed out: '+helperLog.slice(-1500));}
function touch(x,down){socket.send(JSON.stringify({type:'mouse',x,y:30,width:2170,height:60,down}));}
function desktop(action,x,y){driver.stdin.write(JSON.stringify({action,x,y})+'\n');}
function assertQuiet(start,point,down){
 const part=samples.slice(start);assert(part.length>=8,'observer must sample during gesture');
 for(const s of part){assert(Math.hypot(s.x-point.x,s.y-point.y)<1,`cursor moved: ${JSON.stringify(s)}`);assert.equal(s.combined,down,'global combined button state changed');assert.equal(s.hid,down,'global HID button state changed');assert.equal(s.front,target.pid,'source app lost focus');}
}
async function slider(){touch(550,true);await delay(160);touch(700,true);await delay(160);touch(850,true);await delay(160);touch(850,false);await delay(200);}
async function startHelper(){
 server=new WebSocketServer({host:'127.0.0.1',port:0});await new Promise(r=>server.once('listening',r));
 frames=0;exited=false;
 server.once('connection',ws=>{socket=ws;ws.on('message',(d,b)=>{if(b)frames++;else messages.push(JSON.parse(d));});});
 child=spawn(helper,['--url',`ws://127.0.0.1:${server.address().port}/test`,'--hidden-stream','--style','3','--mouse-dispatch','service','--fps','30']);
 child.stderr.on('data',d=>helperLog+=d);child.on('exit',()=>exited=true);
 await until(()=>frames>=1||exited);assert(!exited,'helper exited');await delay(1800);
}
async function stopHelper(disconnect=false){if(disconnect)socket.terminate();else child.kill('SIGTERM');await until(()=>exited,5000);server.close();await delay(300);}
(async()=>{
 const app=path.join(output,'Fixture.app'),macos=path.join(app,'Contents/MacOS');fs.mkdirSync(macos,{recursive:true});
 fs.writeFileSync(path.join(app,'Contents/Info.plist'),'<?xml version="1.0"?><plist version="1.0"><dict><key>CFBundleExecutable</key><string>Fixture</string><key>CFBundleIdentifier</key><string>com.chino.touchbar.input-isolation-test</string><key>CFBundlePackageType</key><string>APPL</string></dict></plist>');
 run('clang',['-fobjc-arc','-framework','AppKit',path.join(__dirname,'InputIsolationFixture.m'),'-o',path.join(macos,'Fixture')]);
 run('codesign',['--force','--sign','-',app]);
 run('clang',['-fobjc-arc','-framework','AppKit','-framework','CoreGraphics',path.join(__dirname,'InputIsolationDriver.m'),'-o',path.join(output,'driver')]);
 target=spawn(path.join(macos,'Fixture'));target.stderr.on('data',d=>targetLog+=d);await until(()=>targetLog.includes('ISOLATION_READY'));await delay(700);
 driver=spawn(path.join(output,'driver'));let pending='';driver.stdout.on('data',d=>{pending+=d;let i;while((i=pending.indexOf('\n'))>=0){const row=JSON.parse(pending.slice(0,i));pending=pending.slice(i+1);if(row.type==='state'){latest=row;samples.push(row);}else windowBounds=row.bounds;}});
 await until(()=>latest);assert(!latest.combined,'release desktop mouse before running test');
 await startHelper();
 let start=samples.length,point=latest;
 for(let i=0;i<3;i++){touch(270,true);await delay(120);touch(270,false);await delay(180);}
 await until(()=>targetLog.includes('ISOLATION_BUTTON 3 active=1'));
 assert.equal((targetLog.match(/ISOLATION_BUTTON/g)||[]).length,3,'each click fires once');assertQuiet(start,point,false);
 start=samples.length;point=latest;await slider();assertQuiet(start,point,false);
 assert(/ISOLATION_SLIDER 78\.\d+ active=1/.test(targetLog),'slider must respond to real drag');
 driver.stdin.write(JSON.stringify({action:'window',pid:target.pid})+'\n');await until(()=>windowBounds);
 const x=windowBounds.X+100,y=windowBounds.Y+70;
 desktop('move',x,y);await delay(100);desktop('down',x,y);await until(()=>latest.combined&&targetLog.includes('ISOLATION_DESKTOP_DOWN'));
 start=samples.length;point=latest;await slider();assertQuiet(start,point,true);
 // Move the desktop mouse while a Touch Bar gesture is held, then release the
 // Touch Bar. It must not jump back or release the separate desktop drag.
 touch(550,true);await delay(120);desktop('drag',x+40,y+10);await until(()=>Math.abs(latest.x-x-40)<1&&targetLog.includes('ISOLATION_DESKTOP_DRAG'));
 await delay(100);start=samples.length;point=latest;
 touch(850,true);await delay(150);touch(850,false);await delay(200);assertQuiet(start,point,true);
 // Cleanup while a Touch Bar press AND a desktop press are both outstanding.
 for(const disconnect of [false,true]){
  touch(550,true);await delay(150);start=samples.length;point=latest;
  await stopHelper(disconnect);assertQuiet(start,point,true);
  if(!disconnect)await startHelper();
 }
 desktop('up',x+40,y+10);await until(()=>!latest.combined&&targetLog.includes('ISOLATION_DESKTOP_UP'));
 assert.equal((targetLog.match(/ISOLATION_DESKTOP_DOWN/g)||[]).length,1);
 assert.equal((targetLog.match(/ISOLATION_DESKTOP_UP/g)||[]).length,1,'Touch Bar must not release desktop drag');
 assert(!messages.some(m=>m.type==='mouse-dispatch-error'),JSON.stringify(messages.filter(m=>m.type==='mouse-dispatch-error')));
 assert(messages.some(m=>m.type==='frame-info'&&m.croppedImage[0]===2170&&m.windowBackingScaleFactor===2));
 console.log(`PASS: button, continuous slider, stationary/moving/held desktop mouse, focus, SIGTERM and disconnect isolation. ${output}`);
})().catch(e=>{console.error(e);process.exitCode=1;}).finally(async()=>{
 fs.writeFileSync(path.join(output,'helper.log'),helperLog);fs.writeFileSync(path.join(output,'fixture.log'),targetLog);
 fs.writeFileSync(path.join(output,'evidence.json'),JSON.stringify({samples,messages},null,2));
 try{socket?.terminate();server?.close();child?.kill('SIGTERM');driver?.stdin.end();await delay(250);target?.kill('SIGTERM');}catch{}
});

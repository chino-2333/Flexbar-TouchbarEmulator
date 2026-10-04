const assert = require('node:assert/strict');
const EventEmitter = require('node:events');
const Module = require('node:module');
const path = require('node:path');
const handlers = new Map();
const children = [];
let url = 'ws://127.0.0.1:12345/touchbar?token=secret';
let backend = 'bridge';
const sdk = {
  plugin: { on(event, handler) { handlers.set(event,handler); }, start() {},
    transport: { async call(name,payload) {
      assert.equal(name,'touchbar-tool');
      if(payload.cmd==='stop') return;
      assert.equal(payload.cmd,'start');
      return {backend,url,width:2170,height:60,fps:60};
    }} },
  logger: {info(){},warn(){},error(...args){throw new Error(args.join(' '));}},
  resourcesPath:path.join(__dirname,'resources'),pluginPath:__dirname,
};
const load = Module._load;
Module._load = function(request,parent,main) {
  if(request==='@eniac/flexdesigner') return sdk;
  if(request==='node:child_process') return {spawn(command,args,options) {
    const child = new EventEmitter();
    Object.assign(child,{command,args,options,pid:children.length+1,stdout:new EventEmitter(),stderr:new EventEmitter(),signals:[]});
    child.kill=signal=>{child.signals.push(signal);queueMicrotask(()=>child.emit('exit',0,signal));return true;};
    children.push(child);return child;
  }};
  return load.call(this,request,parent,main);
};
try {require('../src/plugin.js');} finally {Module._load=load;}
const alive=handlers.get('plugin.alive');
const payload={serialNumber:'serial-1',keys:[{cid:'com.chino.touchbaremulator.emulator'}]};
(async()=>{
  await alive(payload);
  assert.equal(children.length,1);
  assert.deepEqual(children[0].args,['--url',url,'--width','2170','--height','60','--fps','60','--hidden-stream','--style','3','--mouse-dispatch','service']);
  assert.deepEqual(children[0].options.stdio,['ignore','pipe','pipe']);
  assert(children[0].command.endsWith('TouchBarBridgeHelper'));
  await Promise.all([alive(payload),alive(payload)]);
  assert.equal(children.length,1,'repeated alive must reuse the same capture helper');
  url='ws://127.0.0.1:12346/touchbar?token=next';
  await alive(payload);
  assert.equal(children.length,2);
  assert.deepEqual(children[0].signals,['SIGTERM'],'replacement must allow native cleanup first');
  children[0].emit('exit',0,'SIGTERM');
  await alive(payload);
  assert.equal(children.length,2,'a stale child exit must not clear the replacement');
  await alive({...payload,keys:[]});
  assert.deepEqual(children[1].signals,['SIGTERM']);
  backend='native';
  await alive(payload);
  assert.equal(children.length,2,'macOS native backend must not create a helper or virtual display');
  assert.equal(handlers.has('device.touch'),false,'touch stays in the host bridge event path');
  console.log('plugin hidden-stream arguments, lifecycle and native-backend tests passed');
})().catch(e=>{console.error(e);process.exitCode=1;});

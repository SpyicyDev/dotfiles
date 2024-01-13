"use strict";var yn=Object.create;var B=Object.defineProperty;var bn=Object.getOwnPropertyDescriptor;var Sn=Object.getOwnPropertyNames;var vn=Object.getPrototypeOf,_n=Object.prototype.hasOwnProperty;var c=(e,t)=>()=>(t||e((t={exports:{}}).exports,t),t.exports),Tn=(e,t)=>{for(var r in t)B(e,r,{get:t[r],enumerable:!0})},Te=(e,t,r,n)=>{if(t&&typeof t=="object"||typeof t=="function")for(let o of Sn(t))!_n.call(e,o)&&o!==r&&B(e,o,{get:()=>t[o],enumerable:!(n=bn(t,o))||n.enumerable});return e};var Ee=(e,t,r)=>(r=e!=null?yn(vn(e)):{},Te(t||!e||!e.__esModule?B(r,"default",{value:e,enumerable:!0}):r,e)),En=e=>Te(B({},"__esModule",{value:!0}),e);var Ge=c((To,Ce)=>{Ce.exports=Pe;Pe.sync=An;var Ie=require("fs");function In(e,t){var r=t.pathExt!==void 0?t.pathExt:process.env.PATHEXT;if(!r||(r=r.split(";"),r.indexOf("")!==-1))return!0;for(var n=0;n<r.length;n++){var o=r[n].toLowerCase();if(o&&e.substr(-o.length).toLowerCase()===o)return!0}return!1}function Ae(e,t,r){return!e.isSymbolicLink()&&!e.isFile()?!1:In(t,r)}function Pe(e,t,r){Ie.stat(e,function(n,o){r(n,n?!1:Ae(o,e,t))})}function An(e,t){return Ae(Ie.statSync(e),e,t)}});var ke=c((Eo,Ne)=>{Ne.exports=Oe;Oe.sync=Pn;var Re=require("fs");function Oe(e,t,r){Re.stat(e,function(n,o){r(n,n?!1:Le(o,t))})}function Pn(e,t){return Le(Re.statSync(e),t)}function Le(e,t){return e.isFile()&&Cn(e,t)}function Cn(e,t){var r=e.mode,n=e.uid,o=e.gid,i=t.uid!==void 0?t.uid:process.getuid&&process.getuid(),s=t.gid!==void 0?t.gid:process.getgid&&process.getgid(),a=parseInt("100",8),u=parseInt("010",8),l=parseInt("001",8),f=a|u,h=r&l||r&u&&o===s||r&a&&n===i||r&f&&i===0;return h}});var qe=c((Ao,$e)=>{var Io=require("fs"),M;process.platform==="win32"||global.TESTING_WINDOWS?M=Ge():M=ke();$e.exports=te;te.sync=Gn;function te(e,t,r){if(typeof t=="function"&&(r=t,t={}),!r){if(typeof Promise!="function")throw new TypeError("callback not provided");return new Promise(function(n,o){te(e,t||{},function(i,s){i?o(i):n(s)})})}M(e,t||{},function(n,o){n&&(n.code==="EACCES"||t&&t.ignoreErrors)&&(n=null,o=!1),r(n,o)})}function Gn(e,t){try{return M.sync(e,t||{})}catch(r){if(t&&t.ignoreErrors||r.code==="EACCES")return!1;throw r}}});var He=c((Po,De)=>{var T=process.platform==="win32"||process.env.OSTYPE==="cygwin"||process.env.OSTYPE==="msys",Ue=require("path"),Rn=T?";":":",Be=qe(),Me=e=>Object.assign(new Error(`not found: ${e}`),{code:"ENOENT"}),je=(e,t)=>{let r=t.colon||Rn,n=e.match(/\//)||T&&e.match(/\\/)?[""]:[...T?[process.cwd()]:[],...(t.path||process.env.PATH||"").split(r)],o=T?t.pathExt||process.env.PATHEXT||".EXE;.CMD;.BAT;.COM":"",i=T?o.split(r):[""];return T&&e.indexOf(".")!==-1&&i[0]!==""&&i.unshift(""),{pathEnv:n,pathExt:i,pathExtExe:o}},Fe=(e,t,r)=>{typeof t=="function"&&(r=t,t={}),t||(t={});let{pathEnv:n,pathExt:o,pathExtExe:i}=je(e,t),s=[],a=l=>new Promise((f,h)=>{if(l===n.length)return t.all&&s.length?f(s):h(Me(e));let m=n[l],w=/^".*"$/.test(m)?m.slice(1,-1):m,x=Ue.join(w,e),g=!w&&/^\.[\\\/]/.test(e)?e.slice(0,2)+x:x;f(u(g,l,0))}),u=(l,f,h)=>new Promise((m,w)=>{if(h===o.length)return m(a(f+1));let x=o[h];Be(l+x,{pathExt:i},(g,_)=>{if(!g&&_)if(t.all)s.push(l+x);else return m(l+x);return m(u(l,f,h+1))})});return r?a(0).then(l=>r(null,l),r):a(0)},On=(e,t)=>{t=t||{};let{pathEnv:r,pathExt:n,pathExtExe:o}=je(e,t),i=[];for(let s=0;s<r.length;s++){let a=r[s],u=/^".*"$/.test(a)?a.slice(1,-1):a,l=Ue.join(u,e),f=!u&&/^\.[\\\/]/.test(e)?e.slice(0,2)+l:l;for(let h=0;h<n.length;h++){let m=f+n[h];try{if(Be.sync(m,{pathExt:o}))if(t.all)i.push(m);else return m}catch{}}}if(t.all&&i.length)return i;if(t.nothrow)return null;throw Me(e)};De.exports=Fe;Fe.sync=On});var re=c((Co,ne)=>{"use strict";var Ke=(e={})=>{let t=e.env||process.env;return(e.platform||process.platform)!=="win32"?"PATH":Object.keys(t).reverse().find(n=>n.toUpperCase()==="PATH")||"Path"};ne.exports=Ke;ne.exports.default=Ke});var Ve=c((Go,ze)=>{"use strict";var We=require("path"),Ln=He(),Nn=re();function Xe(e,t){let r=e.options.env||process.env,n=process.cwd(),o=e.options.cwd!=null,i=o&&process.chdir!==void 0&&!process.chdir.disabled;if(i)try{process.chdir(e.options.cwd)}catch{}let s;try{s=Ln.sync(e.command,{path:r[Nn({env:r})],pathExt:t?We.delimiter:void 0})}catch{}finally{i&&process.chdir(n)}return s&&(s=We.resolve(o?e.options.cwd:"",s)),s}function kn(e){return Xe(e)||Xe(e,!0)}ze.exports=kn});var Ze=c((Ro,ie)=>{"use strict";var oe=/([()\][%!^"`<>&|;, *?])/g;function $n(e){return e=e.replace(oe,"^$1"),e}function qn(e,t){return e=`${e}`,e=e.replace(/(\\*)"/g,'$1$1\\"'),e=e.replace(/(\\*)$/,"$1$1"),e=`"${e}"`,e=e.replace(oe,"^$1"),t&&(e=e.replace(oe,"^$1")),e}ie.exports.command=$n;ie.exports.argument=qn});var Je=c((Oo,Ye)=>{"use strict";Ye.exports=/^#!(.*)/});var et=c((Lo,Qe)=>{"use strict";var Un=Je();Qe.exports=(e="")=>{let t=e.match(Un);if(!t)return null;let[r,n]=t[0].replace(/#! ?/,"").split(" "),o=r.split("/").pop();return o==="env"?n:n?`${o} ${n}`:o}});var nt=c((No,tt)=>{"use strict";var se=require("fs"),Bn=et();function Mn(e){let r=Buffer.alloc(150),n;try{n=se.openSync(e,"r"),se.readSync(n,r,0,150,0),se.closeSync(n)}catch{}return Bn(r.toString())}tt.exports=Mn});var st=c((ko,it)=>{"use strict";var jn=require("path"),rt=Ve(),ot=Ze(),Fn=nt(),Dn=process.platform==="win32",Hn=/\.(?:com|exe)$/i,Kn=/node_modules[\\/].bin[\\/][^\\/]+\.cmd$/i;function Wn(e){e.file=rt(e);let t=e.file&&Fn(e.file);return t?(e.args.unshift(e.file),e.command=t,rt(e)):e.file}function Xn(e){if(!Dn)return e;let t=Wn(e),r=!Hn.test(t);if(e.options.forceShell||r){let n=Kn.test(t);e.command=jn.normalize(e.command),e.command=ot.command(e.command),e.args=e.args.map(i=>ot.argument(i,n));let o=[e.command].concat(e.args).join(" ");e.args=["/d","/s","/c",`"${o}"`],e.command=process.env.comspec||"cmd.exe",e.options.windowsVerbatimArguments=!0}return e}function zn(e,t,r){t&&!Array.isArray(t)&&(r=t,t=null),t=t?t.slice(0):[],r=Object.assign({},r);let n={command:e,args:t,options:r,file:void 0,original:{command:e,args:t}};return r.shell?n:Xn(n)}it.exports=zn});var ut=c(($o,ct)=>{"use strict";var ae=process.platform==="win32";function ce(e,t){return Object.assign(new Error(`${t} ${e.command} ENOENT`),{code:"ENOENT",errno:"ENOENT",syscall:`${t} ${e.command}`,path:e.command,spawnargs:e.args})}function Vn(e,t){if(!ae)return;let r=e.emit;e.emit=function(n,o){if(n==="exit"){let i=at(o,t,"spawn");if(i)return r.call(e,"error",i)}return r.apply(e,arguments)}}function at(e,t){return ae&&e===1&&!t.file?ce(t.original,"spawn"):null}function Zn(e,t){return ae&&e===1&&!t.file?ce(t.original,"spawnSync"):null}ct.exports={hookChildProcess:Vn,verifyENOENT:at,verifyENOENTSync:Zn,notFoundError:ce}});var ft=c((qo,E)=>{"use strict";var lt=require("child_process"),ue=st(),le=ut();function dt(e,t,r){let n=ue(e,t,r),o=lt.spawn(n.command,n.args,n.options);return le.hookChildProcess(o,n),o}function Yn(e,t,r){let n=ue(e,t,r),o=lt.spawnSync(n.command,n.args,n.options);return o.error=o.error||le.verifyENOENTSync(o.status,n),o}E.exports=dt;E.exports.spawn=dt;E.exports.sync=Yn;E.exports._parse=ue;E.exports._enoent=le});var mt=c((Uo,pt)=>{"use strict";pt.exports=e=>{let t=typeof e=="string"?`
`:`
`.charCodeAt(),r=typeof e=="string"?"\r":"\r".charCodeAt();return e[e.length-1]===t&&(e=e.slice(0,e.length-1)),e[e.length-1]===r&&(e=e.slice(0,e.length-1)),e}});var xt=c((Bo,L)=>{"use strict";var O=require("path"),ht=re(),wt=e=>{e={cwd:process.cwd(),path:process.env[ht()],execPath:process.execPath,...e};let t,r=O.resolve(e.cwd),n=[];for(;t!==r;)n.push(O.join(r,"node_modules/.bin")),t=r,r=O.resolve(r,"..");let o=O.resolve(e.cwd,e.execPath,"..");return n.push(o),n.concat(e.path).join(O.delimiter)};L.exports=wt;L.exports.default=wt;L.exports.env=e=>{e={env:process.env,...e};let t={...e.env},r=ht({env:t});return e.path=t[r],t[r]=L.exports(e),t}});var yt=c((Mo,de)=>{"use strict";var gt=(e,t)=>{for(let r of Reflect.ownKeys(t))Object.defineProperty(e,r,Object.getOwnPropertyDescriptor(t,r));return e};de.exports=gt;de.exports.default=gt});var St=c((jo,F)=>{"use strict";var Jn=yt(),j=new WeakMap,bt=(e,t={})=>{if(typeof e!="function")throw new TypeError("Expected a function");let r,n=0,o=e.displayName||e.name||"<anonymous>",i=function(...s){if(j.set(i,++n),n===1)r=e.apply(this,s),e=null;else if(t.throw===!0)throw new Error(`Function \`${o}\` can only be called once`);return r};return Jn(i,e),j.set(i,n),i};F.exports=bt;F.exports.default=bt;F.exports.callCount=e=>{if(!j.has(e))throw new Error(`The given function \`${e.name}\` is not wrapped by the \`onetime\` package`);return j.get(e)}});var vt=c(D=>{"use strict";Object.defineProperty(D,"__esModule",{value:!0});D.SIGNALS=void 0;var Qn=[{name:"SIGHUP",number:1,action:"terminate",description:"Terminal closed",standard:"posix"},{name:"SIGINT",number:2,action:"terminate",description:"User interruption with CTRL-C",standard:"ansi"},{name:"SIGQUIT",number:3,action:"core",description:"User interruption with CTRL-\\",standard:"posix"},{name:"SIGILL",number:4,action:"core",description:"Invalid machine instruction",standard:"ansi"},{name:"SIGTRAP",number:5,action:"core",description:"Debugger breakpoint",standard:"posix"},{name:"SIGABRT",number:6,action:"core",description:"Aborted",standard:"ansi"},{name:"SIGIOT",number:6,action:"core",description:"Aborted",standard:"bsd"},{name:"SIGBUS",number:7,action:"core",description:"Bus error due to misaligned, non-existing address or paging error",standard:"bsd"},{name:"SIGEMT",number:7,action:"terminate",description:"Command should be emulated but is not implemented",standard:"other"},{name:"SIGFPE",number:8,action:"core",description:"Floating point arithmetic error",standard:"ansi"},{name:"SIGKILL",number:9,action:"terminate",description:"Forced termination",standard:"posix",forced:!0},{name:"SIGUSR1",number:10,action:"terminate",description:"Application-specific signal",standard:"posix"},{name:"SIGSEGV",number:11,action:"core",description:"Segmentation fault",standard:"ansi"},{name:"SIGUSR2",number:12,action:"terminate",description:"Application-specific signal",standard:"posix"},{name:"SIGPIPE",number:13,action:"terminate",description:"Broken pipe or socket",standard:"posix"},{name:"SIGALRM",number:14,action:"terminate",description:"Timeout or timer",standard:"posix"},{name:"SIGTERM",number:15,action:"terminate",description:"Termination",standard:"ansi"},{name:"SIGSTKFLT",number:16,action:"terminate",description:"Stack is empty or overflowed",standard:"other"},{name:"SIGCHLD",number:17,action:"ignore",description:"Child process terminated, paused or unpaused",standard:"posix"},{name:"SIGCLD",number:17,action:"ignore",description:"Child process terminated, paused or unpaused",standard:"other"},{name:"SIGCONT",number:18,action:"unpause",description:"Unpaused",standard:"posix",forced:!0},{name:"SIGSTOP",number:19,action:"pause",description:"Paused",standard:"posix",forced:!0},{name:"SIGTSTP",number:20,action:"pause",description:'Paused using CTRL-Z or "suspend"',standard:"posix"},{name:"SIGTTIN",number:21,action:"pause",description:"Background process cannot read terminal input",standard:"posix"},{name:"SIGBREAK",number:21,action:"terminate",description:"User interruption with CTRL-BREAK",standard:"other"},{name:"SIGTTOU",number:22,action:"pause",description:"Background process cannot write to terminal output",standard:"posix"},{name:"SIGURG",number:23,action:"ignore",description:"Socket received out-of-band data",standard:"bsd"},{name:"SIGXCPU",number:24,action:"core",description:"Process timed out",standard:"bsd"},{name:"SIGXFSZ",number:25,action:"core",description:"File too big",standard:"bsd"},{name:"SIGVTALRM",number:26,action:"terminate",description:"Timeout or timer",standard:"bsd"},{name:"SIGPROF",number:27,action:"terminate",description:"Timeout or timer",standard:"bsd"},{name:"SIGWINCH",number:28,action:"ignore",description:"Terminal window size changed",standard:"bsd"},{name:"SIGIO",number:29,action:"terminate",description:"I/O is available",standard:"other"},{name:"SIGPOLL",number:29,action:"terminate",description:"Watched event",standard:"other"},{name:"SIGINFO",number:29,action:"ignore",description:"Request for process information",standard:"other"},{name:"SIGPWR",number:30,action:"terminate",description:"Device running out of power",standard:"systemv"},{name:"SIGSYS",number:31,action:"core",description:"Invalid system call",standard:"other"},{name:"SIGUNUSED",number:31,action:"terminate",description:"Invalid system call",standard:"other"}];D.SIGNALS=Qn});var fe=c(I=>{"use strict";Object.defineProperty(I,"__esModule",{value:!0});I.SIGRTMAX=I.getRealtimeSignals=void 0;var er=function(){let e=Tt-_t+1;return Array.from({length:e},tr)};I.getRealtimeSignals=er;var tr=function(e,t){return{name:`SIGRT${t+1}`,number:_t+t,action:"terminate",description:"Application-specific signal (realtime)",standard:"posix"}},_t=34,Tt=64;I.SIGRTMAX=Tt});var Et=c(H=>{"use strict";Object.defineProperty(H,"__esModule",{value:!0});H.getSignals=void 0;var nr=require("os"),rr=vt(),or=fe(),ir=function(){let e=(0,or.getRealtimeSignals)();return[...rr.SIGNALS,...e].map(sr)};H.getSignals=ir;var sr=function({name:e,number:t,description:r,action:n,forced:o=!1,standard:i}){let{signals:{[e]:s}}=nr.constants,a=s!==void 0;return{name:e,number:a?s:t,description:r,supported:a,action:n,forced:o,standard:i}}});var At=c(A=>{"use strict";Object.defineProperty(A,"__esModule",{value:!0});A.signalsByNumber=A.signalsByName=void 0;var ar=require("os"),It=Et(),cr=fe(),ur=function(){return(0,It.getSignals)().reduce(lr,{})},lr=function(e,{name:t,number:r,description:n,supported:o,action:i,forced:s,standard:a}){return{...e,[t]:{name:t,number:r,description:n,supported:o,action:i,forced:s,standard:a}}},dr=ur();A.signalsByName=dr;var fr=function(){let e=(0,It.getSignals)(),t=cr.SIGRTMAX+1,r=Array.from({length:t},(n,o)=>pr(o,e));return Object.assign({},...r)},pr=function(e,t){let r=mr(e,t);if(r===void 0)return{};let{name:n,description:o,supported:i,action:s,forced:a,standard:u}=r;return{[e]:{name:n,number:e,description:o,supported:i,action:s,forced:a,standard:u}}},mr=function(e,t){let r=t.find(({name:n})=>ar.constants.signals[n]===e);return r!==void 0?r:t.find(n=>n.number===e)},hr=fr();A.signalsByNumber=hr});var Ct=c((Wo,Pt)=>{"use strict";var{signalsByName:wr}=At(),xr=({timedOut:e,timeout:t,errorCode:r,signal:n,signalDescription:o,exitCode:i,isCanceled:s})=>e?`timed out after ${t} milliseconds`:s?"was canceled":r!==void 0?`failed with ${r}`:n!==void 0?`was killed with ${n} (${o})`:i!==void 0?`failed with exit code ${i}`:"failed",gr=({stdout:e,stderr:t,all:r,error:n,signal:o,exitCode:i,command:s,escapedCommand:a,timedOut:u,isCanceled:l,killed:f,parsed:{options:{timeout:h}}})=>{i=i===null?void 0:i,o=o===null?void 0:o;let m=o===void 0?void 0:wr[o].description,w=n&&n.code,g=`Command ${xr({timedOut:u,timeout:h,errorCode:w,signal:o,signalDescription:m,exitCode:i,isCanceled:l})}: ${s}`,_=Object.prototype.toString.call(n)==="[object Error]",q=_?`${g}
${n.message}`:g,U=[q,t,e].filter(Boolean).join(`
`);return _?(n.originalMessage=n.message,n.message=U):n=new Error(U),n.shortMessage=q,n.command=s,n.escapedCommand=a,n.exitCode=i,n.signal=o,n.signalDescription=m,n.stdout=e,n.stderr=t,r!==void 0&&(n.all=r),"bufferedData"in n&&delete n.bufferedData,n.failed=!0,n.timedOut=!!u,n.isCanceled=l,n.killed=f&&!u,n};Pt.exports=gr});var Rt=c((Xo,pe)=>{"use strict";var K=["stdin","stdout","stderr"],yr=e=>K.some(t=>e[t]!==void 0),Gt=e=>{if(!e)return;let{stdio:t}=e;if(t===void 0)return K.map(n=>e[n]);if(yr(e))throw new Error(`It's not possible to provide \`stdio\` in combination with one of ${K.map(n=>`\`${n}\``).join(", ")}`);if(typeof t=="string")return t;if(!Array.isArray(t))throw new TypeError(`Expected \`stdio\` to be of type \`string\` or \`Array\`, got \`${typeof t}\``);let r=Math.max(t.length,K.length);return Array.from({length:r},(n,o)=>t[o])};pe.exports=Gt;pe.exports.node=e=>{let t=Gt(e);return t==="ipc"?"ipc":t===void 0||typeof t=="string"?[t,t,t,"ipc"]:t.includes("ipc")?t:[...t,"ipc"]}});var Ot=c((zo,W)=>{W.exports=["SIGABRT","SIGALRM","SIGHUP","SIGINT","SIGTERM"];process.platform!=="win32"&&W.exports.push("SIGVTALRM","SIGXCPU","SIGXFSZ","SIGUSR2","SIGTRAP","SIGSYS","SIGQUIT","SIGIOT");process.platform==="linux"&&W.exports.push("SIGIO","SIGPOLL","SIGPWR","SIGSTKFLT","SIGUNUSED")});var qt=c((Vo,G)=>{var d=global.process,b=function(e){return e&&typeof e=="object"&&typeof e.removeListener=="function"&&typeof e.emit=="function"&&typeof e.reallyExit=="function"&&typeof e.listeners=="function"&&typeof e.kill=="function"&&typeof e.pid=="number"&&typeof e.on=="function"};b(d)?(Lt=require("assert"),P=Ot(),Nt=/^win/i.test(d.platform),N=require("events"),typeof N!="function"&&(N=N.EventEmitter),d.__signal_exit_emitter__?p=d.__signal_exit_emitter__:(p=d.__signal_exit_emitter__=new N,p.count=0,p.emitted={}),p.infinite||(p.setMaxListeners(1/0),p.infinite=!0),G.exports=function(e,t){if(!b(global.process))return function(){};Lt.equal(typeof e,"function","a callback must be provided for exit handler"),C===!1&&me();var r="exit";t&&t.alwaysLast&&(r="afterexit");var n=function(){p.removeListener(r,e),p.listeners("exit").length===0&&p.listeners("afterexit").length===0&&X()};return p.on(r,e),n},X=function(){!C||!b(global.process)||(C=!1,P.forEach(function(t){try{d.removeListener(t,z[t])}catch{}}),d.emit=V,d.reallyExit=he,p.count-=1)},G.exports.unload=X,S=function(t,r,n){p.emitted[t]||(p.emitted[t]=!0,p.emit(t,r,n))},z={},P.forEach(function(e){z[e]=function(){if(b(global.process)){var r=d.listeners(e);r.length===p.count&&(X(),S("exit",null,e),S("afterexit",null,e),Nt&&e==="SIGHUP"&&(e="SIGINT"),d.kill(d.pid,e))}}}),G.exports.signals=function(){return P},C=!1,me=function(){C||!b(global.process)||(C=!0,p.count+=1,P=P.filter(function(t){try{return d.on(t,z[t]),!0}catch{return!1}}),d.emit=$t,d.reallyExit=kt)},G.exports.load=me,he=d.reallyExit,kt=function(t){b(global.process)&&(d.exitCode=t||0,S("exit",d.exitCode,null),S("afterexit",d.exitCode,null),he.call(d,d.exitCode))},V=d.emit,$t=function(t,r){if(t==="exit"&&b(global.process)){r!==void 0&&(d.exitCode=r);var n=V.apply(this,arguments);return S("exit",d.exitCode,null),S("afterexit",d.exitCode,null),n}else return V.apply(this,arguments)}):G.exports=function(){return function(){}};var Lt,P,Nt,N,p,X,S,z,C,me,he,kt,V,$t});var Bt=c((Zo,Ut)=>{"use strict";var br=require("os"),Sr=qt(),vr=1e3*5,_r=(e,t="SIGTERM",r={})=>{let n=e(t);return Tr(e,t,r,n),n},Tr=(e,t,r,n)=>{if(!Er(t,r,n))return;let o=Ar(r),i=setTimeout(()=>{e("SIGKILL")},o);i.unref&&i.unref()},Er=(e,{forceKillAfterTimeout:t},r)=>Ir(e)&&t!==!1&&r,Ir=e=>e===br.constants.signals.SIGTERM||typeof e=="string"&&e.toUpperCase()==="SIGTERM",Ar=({forceKillAfterTimeout:e=!0})=>{if(e===!0)return vr;if(!Number.isFinite(e)||e<0)throw new TypeError(`Expected the \`forceKillAfterTimeout\` option to be a non-negative integer, got \`${e}\` (${typeof e})`);return e},Pr=(e,t)=>{e.kill()&&(t.isCanceled=!0)},Cr=(e,t,r)=>{e.kill(t),r(Object.assign(new Error("Timed out"),{timedOut:!0,signal:t}))},Gr=(e,{timeout:t,killSignal:r="SIGTERM"},n)=>{if(t===0||t===void 0)return n;let o,i=new Promise((a,u)=>{o=setTimeout(()=>{Cr(e,r,u)},t)}),s=n.finally(()=>{clearTimeout(o)});return Promise.race([i,s])},Rr=({timeout:e})=>{if(e!==void 0&&(!Number.isFinite(e)||e<0))throw new TypeError(`Expected the \`timeout\` option to be a non-negative integer, got \`${e}\` (${typeof e})`)},Or=async(e,{cleanup:t,detached:r},n)=>{if(!t||r)return n;let o=Sr(()=>{e.kill()});return n.finally(()=>{o()})};Ut.exports={spawnedKill:_r,spawnedCancel:Pr,setupTimeout:Gr,validateTimeout:Rr,setExitHandler:Or}});var jt=c((Yo,Mt)=>{"use strict";var y=e=>e!==null&&typeof e=="object"&&typeof e.pipe=="function";y.writable=e=>y(e)&&e.writable!==!1&&typeof e._write=="function"&&typeof e._writableState=="object";y.readable=e=>y(e)&&e.readable!==!1&&typeof e._read=="function"&&typeof e._readableState=="object";y.duplex=e=>y.writable(e)&&y.readable(e);y.transform=e=>y.duplex(e)&&typeof e._transform=="function";Mt.exports=y});var Dt=c((Jo,Ft)=>{"use strict";var{PassThrough:Lr}=require("stream");Ft.exports=e=>{e={...e};let{array:t}=e,{encoding:r}=e,n=r==="buffer",o=!1;t?o=!(r||n):r=r||"utf8",n&&(r=null);let i=new Lr({objectMode:o});r&&i.setEncoding(r);let s=0,a=[];return i.on("data",u=>{a.push(u),o?s=a.length:s+=u.length}),i.getBufferedValue=()=>t?a:n?Buffer.concat(a,s):a.join(""),i.getBufferedLength=()=>s,i}});var Ht=c((Qo,k)=>{"use strict";var{constants:Nr}=require("buffer"),kr=require("stream"),{promisify:$r}=require("util"),qr=Dt(),Ur=$r(kr.pipeline),Z=class extends Error{constructor(){super("maxBuffer exceeded"),this.name="MaxBufferError"}};async function we(e,t){if(!e)throw new Error("Expected a stream");t={maxBuffer:1/0,...t};let{maxBuffer:r}=t,n=qr(t);return await new Promise((o,i)=>{let s=a=>{a&&n.getBufferedLength()<=Nr.MAX_LENGTH&&(a.bufferedData=n.getBufferedValue()),i(a)};(async()=>{try{await Ur(e,n),o()}catch(a){s(a)}})(),n.on("data",()=>{n.getBufferedLength()>r&&s(new Z)})}),n.getBufferedValue()}k.exports=we;k.exports.buffer=(e,t)=>we(e,{...t,encoding:"buffer"});k.exports.array=(e,t)=>we(e,{...t,array:!0});k.exports.MaxBufferError=Z});var Wt=c((ei,Kt)=>{"use strict";var{PassThrough:Br}=require("stream");Kt.exports=function(){var e=[],t=new Br({objectMode:!0});return t.setMaxListeners(0),t.add=r,t.isEmpty=n,t.on("unpipe",o),Array.prototype.slice.call(arguments).forEach(r),t;function r(i){return Array.isArray(i)?(i.forEach(r),this):(e.push(i),i.once("end",o.bind(null,i)),i.once("error",t.emit.bind(t,"error")),i.pipe(t,{end:!1}),this)}function n(){return e.length==0}function o(i){e=e.filter(function(s){return s!==i}),!e.length&&t.readable&&t.end()}}});var Zt=c((ti,Vt)=>{"use strict";var zt=jt(),Xt=Ht(),Mr=Wt(),jr=(e,t)=>{t===void 0||e.stdin===void 0||(zt(t)?t.pipe(e.stdin):e.stdin.end(t))},Fr=(e,{all:t})=>{if(!t||!e.stdout&&!e.stderr)return;let r=Mr();return e.stdout&&r.add(e.stdout),e.stderr&&r.add(e.stderr),r},xe=async(e,t)=>{if(e){e.destroy();try{return await t}catch(r){return r.bufferedData}}},ge=(e,{encoding:t,buffer:r,maxBuffer:n})=>{if(!(!e||!r))return t?Xt(e,{encoding:t,maxBuffer:n}):Xt.buffer(e,{maxBuffer:n})},Dr=async({stdout:e,stderr:t,all:r},{encoding:n,buffer:o,maxBuffer:i},s)=>{let a=ge(e,{encoding:n,buffer:o,maxBuffer:i}),u=ge(t,{encoding:n,buffer:o,maxBuffer:i}),l=ge(r,{encoding:n,buffer:o,maxBuffer:i*2});try{return await Promise.all([s,a,u,l])}catch(f){return Promise.all([{error:f,signal:f.signal,timedOut:f.timedOut},xe(e,a),xe(t,u),xe(r,l)])}},Hr=({input:e})=>{if(zt(e))throw new TypeError("The `input` option cannot be a stream in sync mode")};Vt.exports={handleInput:jr,makeAllStream:Fr,getSpawnedResult:Dr,validateInputSync:Hr}});var Jt=c((ni,Yt)=>{"use strict";var Kr=(async()=>{})().constructor.prototype,Wr=["then","catch","finally"].map(e=>[e,Reflect.getOwnPropertyDescriptor(Kr,e)]),Xr=(e,t)=>{for(let[r,n]of Wr){let o=typeof t=="function"?(...i)=>Reflect.apply(n.value,t(),i):n.value.bind(t);Reflect.defineProperty(e,r,{...n,value:o})}return e},zr=e=>new Promise((t,r)=>{e.on("exit",(n,o)=>{t({exitCode:n,signal:o})}),e.on("error",n=>{r(n)}),e.stdin&&e.stdin.on("error",n=>{r(n)})});Yt.exports={mergePromise:Xr,getSpawnedPromise:zr}});var tn=c((ri,en)=>{"use strict";var Qt=(e,t=[])=>Array.isArray(t)?[e,...t]:[e],Vr=/^[\w.-]+$/,Zr=/"/g,Yr=e=>typeof e!="string"||Vr.test(e)?e:`"${e.replace(Zr,'\\"')}"`,Jr=(e,t)=>Qt(e,t).join(" "),Qr=(e,t)=>Qt(e,t).map(r=>Yr(r)).join(" "),eo=/ +/g,to=e=>{let t=[];for(let r of e.trim().split(eo)){let n=t[t.length-1];n&&n.endsWith("\\")?t[t.length-1]=`${n.slice(0,-1)} ${r}`:t.push(r)}return t};en.exports={joinCommand:Jr,getEscapedCommand:Qr,parseCommand:to}});var un=c((oi,R)=>{"use strict";var no=require("path"),ye=require("child_process"),ro=ft(),oo=mt(),io=xt(),so=St(),Y=Ct(),rn=Rt(),{spawnedKill:ao,spawnedCancel:co,setupTimeout:uo,validateTimeout:lo,setExitHandler:fo}=Bt(),{handleInput:po,getSpawnedResult:mo,makeAllStream:ho,validateInputSync:wo}=Zt(),{mergePromise:nn,getSpawnedPromise:xo}=Jt(),{joinCommand:on,parseCommand:sn,getEscapedCommand:an}=tn(),go=1e3*1e3*100,yo=({env:e,extendEnv:t,preferLocal:r,localDir:n,execPath:o})=>{let i=t?{...process.env,...e}:e;return r?io.env({env:i,cwd:n,execPath:o}):i},cn=(e,t,r={})=>{let n=ro._parse(e,t,r);return e=n.command,t=n.args,r=n.options,r={maxBuffer:go,buffer:!0,stripFinalNewline:!0,extendEnv:!0,preferLocal:!1,localDir:r.cwd||process.cwd(),execPath:process.execPath,encoding:"utf8",reject:!0,cleanup:!0,all:!1,windowsHide:!0,...r},r.env=yo(r),r.stdio=rn(r),process.platform==="win32"&&no.basename(e,".exe")==="cmd"&&t.unshift("/q"),{file:e,args:t,options:r,parsed:n}},$=(e,t,r)=>typeof t!="string"&&!Buffer.isBuffer(t)?r===void 0?void 0:"":e.stripFinalNewline?oo(t):t,J=(e,t,r)=>{let n=cn(e,t,r),o=on(e,t),i=an(e,t);lo(n.options);let s;try{s=ye.spawn(n.file,n.args,n.options)}catch(w){let x=new ye.ChildProcess,g=Promise.reject(Y({error:w,stdout:"",stderr:"",all:"",command:o,escapedCommand:i,parsed:n,timedOut:!1,isCanceled:!1,killed:!1}));return nn(x,g)}let a=xo(s),u=uo(s,n.options,a),l=fo(s,n.options,u),f={isCanceled:!1};s.kill=ao.bind(null,s.kill.bind(s)),s.cancel=co.bind(null,s,f);let m=so(async()=>{let[{error:w,exitCode:x,signal:g,timedOut:_},q,U,gn]=await mo(s,n.options,l),be=$(n.options,q),Se=$(n.options,U),ve=$(n.options,gn);if(w||x!==0||g!==null){let _e=Y({error:w,exitCode:x,signal:g,stdout:be,stderr:Se,all:ve,command:o,escapedCommand:i,parsed:n,timedOut:_,isCanceled:f.isCanceled,killed:s.killed});if(!n.options.reject)return _e;throw _e}return{command:o,escapedCommand:i,exitCode:0,stdout:be,stderr:Se,all:ve,failed:!1,timedOut:!1,isCanceled:!1,killed:!1}});return po(s,n.options.input),s.all=ho(s,n.options),nn(s,m)};R.exports=J;R.exports.sync=(e,t,r)=>{let n=cn(e,t,r),o=on(e,t),i=an(e,t);wo(n.options);let s;try{s=ye.spawnSync(n.file,n.args,n.options)}catch(l){throw Y({error:l,stdout:"",stderr:"",all:"",command:o,escapedCommand:i,parsed:n,timedOut:!1,isCanceled:!1,killed:!1})}let a=$(n.options,s.stdout,s.error),u=$(n.options,s.stderr,s.error);if(s.error||s.status!==0||s.signal!==null){let l=Y({stdout:a,stderr:u,error:s.error,signal:s.signal,exitCode:s.status,command:o,escapedCommand:i,parsed:n,timedOut:s.error&&s.error.code==="ETIMEDOUT",isCanceled:!1,killed:s.signal!==null});if(!n.options.reject)return l;throw l}return{command:o,escapedCommand:i,exitCode:0,stdout:a,stderr:u,failed:!1,timedOut:!1,isCanceled:!1,killed:!1}};R.exports.command=(e,t)=>{let[r,...n]=sn(e);return J(r,n,t)};R.exports.commandSync=(e,t)=>{let[r,...n]=sn(e);return J.sync(r,n,t)};R.exports.node=(e,t,r={})=>{t&&!Array.isArray(t)&&typeof t=="object"&&(r=t,t=[]);let n=rn.node(r),o=process.execArgv.filter(a=>!a.startsWith("--inspect")),{nodePath:i=process.execPath,nodeOptions:s=o}=r;return J(i,[...s,e,...Array.isArray(t)?t:[]],{...r,stdin:void 0,stdout:void 0,stderr:void 0,stdio:n,shell:!1})}});var vo={};Tn(vo,{default:()=>xn});module.exports=En(vo);var ee=require("@raycast/api");var ln=Ee(require("node:process"),1),dn=Ee(un(),1);async function fn(e,{humanReadableOutput:t=!0}={}){if(ln.default.platform!=="darwin")throw new Error("macOS only");let r=t?[]:["-ss"],{stdout:n}=await(0,dn.default)("osascript",["-e",e,r]);return n}async function pn(e){await fn(`
    tell application "Arc"
      if (count of windows) is 0 then
        make new window
      end if

      tell front window
        make new tab with properties {URL:"${e}"}
      end tell

      activate
    end tell
  `)}var Q=require("@raycast/api"),mn=(0,Q.getPreferenceValues)(),bo=(0,Q.getPreferenceValues)(),ci=(0,Q.getPreferenceValues)();var v=require("@raycast/api");async function hn(e){let t=/(http(s)?:\/\/|arc:\/\/)?(www\.)?[-a-zA-Z0-9@:%._+~#=]{0,256}(\.[a-z]{2,6})?\b([-a-zA-Z0-9@:%_+.~#?&//=]*)/;return e===void 0||e===""?(await(0,v.showHUD)("\u274C No URL found"),!1):t.test(e)?!0:(await(0,v.showHUD)("\u274C Invalid URL provided"),!1)}var So="arc://newtab",wn=async e=>{try{if(await hn(e)){let t=/^\S+?:\/\//i.test(e)?e:"https://"+e;await(0,ee.closeMainWindow)(),await pn(t)}}catch(t){console.error(t),await(0,ee.showHUD)("\u274C Failed opening a new tab")}};async function xn(e){let{url:t}=e.arguments,{fallbackText:r}=e,n=t||r||mn.url||So;if(n.includes(",")){let o=n.split(",").map(i=>wn(i.trim()));return Promise.all(o)}else return await wn(n)}

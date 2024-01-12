"use strict";var N=Object.defineProperty;var q=Object.getOwnPropertyDescriptor;var Y=Object.getOwnPropertyNames;var z=Object.prototype.hasOwnProperty;var K=(t,e)=>{for(var o in e)N(t,o,{get:e[o],enumerable:!0})},Q=(t,e,o,r)=>{if(e&&typeof e=="object"||typeof e=="function")for(let n of Y(e))!z.call(t,n)&&n!==o&&N(t,n,{get:()=>e[n],enumerable:!(r=q(e,n))||r.enumerable});return t};var X=t=>Q(N({},"__esModule",{value:!0}),t);var ot={};K(ot,{default:()=>B});module.exports=X(ot);var s=require("@raycast/api"),j=require("react");var P=require("@raycast/api"),C=require("react");var h=t=>{let e=Math.floor(t/3600),o=String(Math.floor(t%3600/60)).padStart(2,"0"),r=String(Math.floor(t%60)).padStart(2,"0");return`${e}:${o}:${r}`},F=t=>{let e=new Date(t),o=[e.getFullYear().toString(),e.getMonth().toString().padStart(2,"0"),e.getDate().toString().padStart(2,"0")],r=[e.getHours(),e.getMinutes(),e.getSeconds()].map(T=>T.toString().padStart(2,"0")),n=o.join("-"),f=r.join(":");return`${n} ${f}`},w=t=>(t.d1=t.d1=="----"?void 0:t.d1,t.d2=t.d2=="----"?void 0:t.d2,Math.round((t.d1?new Date(t.d1):new Date).getTime()-(t.d2?new Date(t.d2):new Date).getTime())/1e3);var u=require("@raycast/api"),R=require("child_process"),W=require("crypto"),a=require("fs"),b=require("path");var m=u.environment.supportPath+"/raycast-stopwatches.json",g=()=>{(!(0,a.existsSync)(m)||(0,a.readFileSync)(m).toString()=="")&&(0,a.writeFileSync)(m,"[]")},v=(t="")=>({name:t,swID:(0,W.randomUUID)(),timeStarted:new Date,timeElapsed:-99,lastPaused:"----",pauseElapsed:0}),Z=t=>(t.map(e=>{if(e.lastPaused!="----")e.timeElapsed=Math.max(0,w({d1:e.lastPaused,d2:e.timeStarted})-e.pauseElapsed);else{let o=Math.max(0,w({d2:e.timeStarted}));e.timeElapsed=o-e.pauseElapsed}}),t),k=()=>{g();let t=JSON.parse((0,a.readFileSync)(m).toString()),e=tt(t),o=Z(e);return o.sort((r,n)=>r.timeElapsed-n.timeElapsed),o},U=async(t="Untitled")=>{g();let e=JSON.parse((0,a.readFileSync)(m).toString()),o=v(t);e.push(o),(0,a.writeFileSync)(m,JSON.stringify(e)),(0,u.popToRoot)(),await(0,u.showHUD)(`Stopwatch "${t}" started! \u{1F389}`)},L=t=>{g();let e=JSON.parse((0,a.readFileSync)(m).toString());e=e.map(o=>o.swID==t?{...o,lastPaused:new Date}:o),(0,a.writeFileSync)(m,JSON.stringify(e))},M=t=>{g();let e=JSON.parse((0,a.readFileSync)(m).toString());e=e.map(o=>o.swID==t?{...o,pauseElapsed:o.pauseElapsed+w({d2:o.lastPaused}),lastPaused:"----"}:o),(0,a.writeFileSync)(m,JSON.stringify(e))},x=t=>{g();let e=JSON.parse((0,a.readFileSync)(m).toString());e=e.filter(o=>o.swID!==t),(0,a.writeFileSync)(m,JSON.stringify(e))},tt=t=>((0,a.readdirSync)(u.environment.supportPath).forEach(o=>{if((0,b.extname)(o)==".stopwatch"){let r=v((0,a.readFileSync)(u.environment.supportPath+"/"+o).toString()),n=o.replace(/__/g,":").replace(".stopwatch","");r.timeStarted=new Date(n),r.timeElapsed=Math.max(0,w({})),(0,R.execSync)(`rm "${u.environment.supportPath}/${o}"`),t.push(r)}}),(0,a.writeFileSync)(m,JSON.stringify(t)),t),_=(t,e)=>{g();let r=JSON.parse((0,a.readFileSync)(m,"utf8")).map(n=>n.swID==t?{...n,name:e}:n);(0,a.writeFileSync)(m,JSON.stringify(r))};function E(){let[t,e]=(0,C.useState)(void 0),[o,r]=(0,C.useState)(t===void 0),n=()=>{let c=k();e(c),r(!1)},f=(c="Untitled")=>{U(c),n()},T=c=>{L(c),n()},O=c=>{M(c),n()},D=c=>{(0,P.getPreferenceValues)().copyOnSwStop&&P.Clipboard.copy(h(c.timeElapsed)),x(c.swID),n()};return{stopwatches:t,isLoading:o,refreshSWes:n,handleRestartSW:c=>{D(c),f(c.name),n()},handleStartSW:f,handleStopSW:D,handlePauseSW:T,handleUnpauseSW:O}}var l=require("@raycast/api");var S=require("@raycast/api");var d=require("fs");var $=S.environment.supportPath+"/customTimers.json";function H(t,e){let o=S.environment.supportPath+"/"+t;(0,d.writeFileSync)(o,e)}function et(){(0,d.existsSync)($)||(0,d.writeFileSync)($,JSON.stringify({}))}function V(t,e){et();let o=JSON.parse((0,d.readFileSync)($,"utf8"));o[t].name=e,(0,d.writeFileSync)($,JSON.stringify(o))}var y=require("react/jsx-runtime");function I(t){let e=o=>{if(o===""||o===t.currentName)new l.Toast({style:l.Toast.Style.Failure,title:"No new name given!"}).show();else{switch((0,l.popToRoot)(),t.originalFile){case"customTimer":V(t.ctID?t.ctID:"-99",o);break;case"stopwatch":_(t.ctID?t.ctID:"-99",o);break;default:H(t.originalFile,o);break}new l.Toast({style:l.Toast.Style.Success,title:`Renamed to ${o}!`}).show()}};return(0,y.jsx)(l.Form,{actions:(0,y.jsx)(l.ActionPanel,{children:(0,y.jsx)(l.Action.SubmitForm,{title:"Rename",onSubmit:o=>e(o.newName)})}),children:(0,y.jsx)(l.Form.TextField,{id:"newName",title:"New name",placeholder:t.currentName})})}var i=require("react/jsx-runtime");function B(){let{stopwatches:t,isLoading:e,refreshSWes:o,handleRestartSW:r,handleStartSW:n,handleStopSW:f,handlePauseSW:T,handleUnpauseSW:O}=E(),{push:D}=(0,s.useNavigation)();(0,j.useEffect)(()=>{o(),setInterval(()=>{o()},1e3)},[]);let J={tag:{value:"Paused",color:s.Color.Red}},c={tag:{value:"Running",color:s.Color.Green}},A={source:s.Icon.Clock,tintColor:s.Color.Red},G={source:s.Icon.Clock,tintColor:s.Color.Green};return(0,i.jsx)(s.List,{isLoading:e,children:(0,i.jsxs)(s.List.Section,{title:t?.length!==0&&t!=null?"Currently Running":"No Stopwatches Running",children:[t?.map(p=>(0,i.jsx)(s.List.Item,{icon:p.lastPaused=="----"?G:A,title:p.name,subtitle:h(p.timeElapsed)+" elapsed",accessories:[{text:"Started at "+F(p.timeStarted)},p.lastPaused=="----"?c:J],actions:(0,i.jsxs)(s.ActionPanel,{children:[p.lastPaused=="----"?(0,i.jsx)(s.Action,{title:"Pause Stopwatch",onAction:()=>T(p.swID)}):(0,i.jsx)(s.Action,{title:"Unpause Stopwatch",onAction:()=>O(p.swID)}),(0,i.jsx)(s.Action,{title:"Rename Stopwatch",onAction:()=>D((0,i.jsx)(I,{currentName:p.name,originalFile:"stopwatch",ctID:p.swID}))}),(0,i.jsx)(s.Action.CopyToClipboard,{title:"Copy Current Time",shortcut:{modifiers:["cmd"],key:"c"},content:h(p.timeElapsed)}),(0,i.jsx)(s.Action,{title:"Restart Stopwatch",shortcut:{modifiers:["cmd"],key:"r"},onAction:()=>r(p)}),(0,i.jsx)(s.Action,{title:"Stop Stopwatch",shortcut:{modifiers:["ctrl"],key:"x"},onAction:()=>f(p)})]})},p.swID)),(0,i.jsx)(s.List.Item,{icon:s.Icon.Clock,title:"Create a new stopwatch",subtitle:"Press Enter to start a stopwatch",actions:(0,i.jsx)(s.ActionPanel,{children:(0,i.jsx)(s.Action,{title:"Start Stopwatch",onAction:()=>n()})})},0)]})})}

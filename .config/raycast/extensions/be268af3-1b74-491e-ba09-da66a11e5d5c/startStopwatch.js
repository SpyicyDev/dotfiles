"use strict";var p=Object.defineProperty;var m=Object.getOwnPropertyDescriptor;var w=Object.getOwnPropertyNames;var h=Object.prototype.hasOwnProperty;var u=(t,e)=>{for(var o in e)p(t,o,{get:e[o],enumerable:!0})},l=(t,e,o,c)=>{if(e&&typeof e=="object"||typeof e=="function")for(let n of w(e))!h.call(t,n)&&n!==o&&p(t,n,{get:()=>e[n],enumerable:!(c=m(e,n))||c.enumerable});return t};var f=t=>l(p({},"__esModule",{value:!0}),t);var E={};u(E,{default:()=>y});module.exports=f(E);var d=require("@raycast/api");var s=require("@raycast/api");var S=require("crypto"),a=require("fs");var r=s.environment.supportPath+"/raycast-stopwatches.json",g=()=>{(!(0,a.existsSync)(r)||(0,a.readFileSync)(r).toString()=="")&&(0,a.writeFileSync)(r,"[]")},D=(t="")=>({name:t,swID:(0,S.randomUUID)(),timeStarted:new Date,timeElapsed:-99,lastPaused:"----",pauseElapsed:0});var i=async(t="Untitled")=>{g();let e=JSON.parse((0,a.readFileSync)(r).toString()),o=D(t);e.push(o),(0,a.writeFileSync)(r,JSON.stringify(e)),(0,s.popToRoot)(),await(0,s.showHUD)(`Stopwatch "${t}" started! \u{1F389}`)};var y=async t=>{await(0,d.closeMainWindow)(),t.arguments.name?i(t.arguments.name):i()};
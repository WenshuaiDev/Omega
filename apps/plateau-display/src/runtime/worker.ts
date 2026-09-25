/// <reference lib="webworker" />
import { catalogStats, filterFacilities } from '../domain/catalog';
import { SimulationRuntime } from './simulation';
import type { RuntimeRequest, RuntimeResponse } from './protocol';
let runtime:SimulationRuntime|undefined;
const subscriptions=new Map<string,string[]>();
const send=(message:RuntimeResponse)=>self.postMessage(message);
let previous=performance.now();
setInterval(()=>{
  const now=performance.now(),elapsed=now-previous;previous=now;
  if(!runtime)return;
  runtime.advance(elapsed);
  for(const [requestId,seriesIds] of subscriptions) send({requestId,type:'update',result:runtime.snapshot(requestId,seriesIds)});
},1000);
self.onmessage=(event:MessageEvent<RuntimeRequest>)=>{
  const request=event.data;
  try {
    if(request.type==='init'){runtime=new SimulationRuntime(request.catalog,request.seed,request.timestamp);send({requestId:request.requestId,ok:true,result:runtime.state});return;}
    if(!runtime)throw new Error('Simulation runtime not initialized');
    let result:unknown;
    switch(request.type){
      case 'catalog':result=runtime.catalog;break;
      case 'filter':result=filterFacilities(runtime.catalog,request.filter);break;
      case 'statistics':result=runtime.statistics(request.requestId,catalogStats(runtime.catalog,request.facilityIds));break;
      case 'snapshot':result=runtime.snapshot(request.requestId,request.seriesIds,request.timestamp);break;
      case 'series':result=runtime.querySeries(request.requestId,request.seriesId,request.from,request.to,request.maxPoints);break;
      case 'profile':result=runtime.profile(request.requestId,request.boreholeId,request.metricId,request.timestamp);break;
      case 'control':result=runtime.control(request.change);break;
      case 'reset':result=runtime.reset();break;
      case 'subscribe':subscriptions.set(request.requestId,request.seriesIds);result={subscribed:true};break;
      case 'unsubscribe':subscriptions.delete(request.requestId);result={subscribed:false};break;
    }
    send({requestId:request.requestId,ok:true,result});
  } catch(error){send({requestId:request.requestId,ok:false,error:error instanceof Error?error.message:String(error)});}
};

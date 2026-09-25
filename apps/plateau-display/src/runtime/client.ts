import type { Catalog, Facility, MetricId } from '../domain/types';
import type { RuntimeRequest, RuntimeResponse } from './protocol';
import type { ProfileResult, RuntimeState, SeriesResult, SnapshotResult, StatisticsResult } from './simulation';
export interface SimulationClient {
  getCatalog():Promise<Catalog>;
  filterFacilities(filter:Extract<RuntimeRequest,{type:'filter'}>['filter']):Promise<Facility[]>;
  statistics(facilityIds?:string[]):Promise<StatisticsResult>;
  snapshot(seriesIds:string[],timestamp?:number):Promise<SnapshotResult>;
  querySeries(seriesId:string,from:number,to:number,maxPoints?:number):Promise<SeriesResult>;
  profile(boreholeId:string,metricId:MetricId,timestamp?:number):Promise<ProfileResult>;
  control(change:Partial<Pick<RuntimeState,'timestamp'|'speed'|'paused'|'seed'>>):Promise<RuntimeState>;
  reset():Promise<RuntimeState>;
  subscribe(seriesIds:string[],listener:(snapshot:SnapshotResult)=>void):Promise<()=>void>;
  dispose():void;
}
export async function createSimulationClient(catalog:Catalog,options?:{seed?:number;timestamp?:number}):Promise<SimulationClient> {
  const worker=new Worker(new URL('./worker.ts',import.meta.url),{type:'module'});
  let sequence=0;
  const pending=new Map<string,{resolve:(value:unknown)=>void;reject:(error:Error)=>void}>();
  const listeners=new Map<string,(snapshot:SnapshotResult)=>void>();
  worker.onmessage=(event:MessageEvent<RuntimeResponse>)=>{
    const message=event.data;
    if('type' in message&&message.type==='update'){listeners.get(message.requestId)?.(message.result as SnapshotResult);return;}
    const callback=pending.get(message.requestId);if(!callback)return;pending.delete(message.requestId);
    if('ok' in message && message.ok)callback.resolve(message.result);
    else callback.reject(new Error('error' in message ? message.error : 'Unexpected worker response'));
  };
  const call=<T>(request:Omit<RuntimeRequest,'requestId'>):Promise<T>=>{
    const requestId=`r-${++sequence}`;
    return new Promise<T>((resolve,reject)=>{pending.set(requestId,{resolve:value=>resolve(value as T),reject});worker.postMessage({...request,requestId});});
  };
  await call<RuntimeState>({type:'init',catalog,...options} as Omit<RuntimeRequest,'requestId'>);
  return {
    getCatalog:()=>call<Catalog>({type:'catalog'} as Omit<RuntimeRequest,'requestId'>),
    filterFacilities:filter=>call<Facility[]>({type:'filter',filter} as Omit<RuntimeRequest,'requestId'>),
    statistics:facilityIds=>call<StatisticsResult>({type:'statistics',facilityIds} as Omit<RuntimeRequest,'requestId'>),
    snapshot:(seriesIds,timestamp)=>call<SnapshotResult>({type:'snapshot',seriesIds,timestamp} as Omit<RuntimeRequest,'requestId'>),
    querySeries:(seriesId,from,to,maxPoints)=>call<SeriesResult>({type:'series',seriesId,from,to,maxPoints} as Omit<RuntimeRequest,'requestId'>),
    profile:(boreholeId,metricId,timestamp)=>call<ProfileResult>({type:'profile',boreholeId,metricId,timestamp} as Omit<RuntimeRequest,'requestId'>),
    control:change=>call<RuntimeState>({type:'control',change} as Omit<RuntimeRequest,'requestId'>),
    reset:()=>call<RuntimeState>({type:'reset'} as Omit<RuntimeRequest,'requestId'>),
    subscribe:async(seriesIds,listener)=>{const requestId=`r-${++sequence}`;listeners.set(requestId,listener);await new Promise<void>((resolve,reject)=>{pending.set(requestId,{resolve:()=>resolve(),reject});worker.postMessage({type:'subscribe',requestId,seriesIds});});return()=>{listeners.delete(requestId);worker.postMessage({type:'unsubscribe',requestId});};},
    dispose:()=>{worker.terminate();for(const item of pending.values())item.reject(new Error('Simulation client disposed'));pending.clear();listeners.clear();}
  };
}

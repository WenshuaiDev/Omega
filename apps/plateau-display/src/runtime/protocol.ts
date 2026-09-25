import type { Catalog, MetricId } from '../domain/types';
import type { RuntimeState } from './simulation';
export type RuntimeRequest =
  | {requestId:string;type:'init';catalog:Catalog;seed?:number;timestamp?:number}
  | {requestId:string;type:'catalog'}
  | {requestId:string;type:'filter';filter:{corridorId?:string;fieldIds?:string[];specialty?:import('../domain/types').Specialty;search?:string}}
  | {requestId:string;type:'statistics';facilityIds?:string[]}
  | {requestId:string;type:'snapshot';seriesIds:string[];timestamp?:number}
  | {requestId:string;type:'series';seriesId:string;from:number;to:number;maxPoints?:number}
  | {requestId:string;type:'profile';boreholeId:string;metricId:MetricId;timestamp?:number}
  | {requestId:string;type:'control';change:Partial<Pick<RuntimeState,'timestamp'|'speed'|'paused'|'seed'>>}
  | {requestId:string;type:'reset'}
  | {requestId:string;type:'subscribe';seriesIds:string[]}
  | {requestId:string;type:'unsubscribe'};
export type RuntimeResponse = {requestId:string;ok:true;result:unknown}|{requestId:string;ok:false;error:string}|{requestId:string;type:'update';result:unknown};

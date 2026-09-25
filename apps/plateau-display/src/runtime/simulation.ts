import type { Borehole, Catalog, CatalogStats, MetricId, Sample, Series } from '../domain/types';
import { metricById } from '../domain/metrics';

export const SIMULATION_VERSION = 'sim-v1' as const;
export const DEFAULT_SEED = 20260925;
export const START_TIME = Date.parse('2026-06-21T02:00:00.000Z');
export const MAX_HISTORY_MS = 30 * 86400000;
const TWO_PI = Math.PI * 2;
const clamp = (value: number, min: number, max: number) => Math.min(max, Math.max(min, value));
const fract = (value: number) => value - Math.floor(value);
const hash = (input: string): number => { let h = 2166136261; for (let i=0; i<input.length; i++) h = Math.imul(h ^ input.charCodeAt(i), 16777619); return h >>> 0; };
const noise = (seed: number, key: string, n: number) => fract(Math.sin(hash(`${seed}:${key}:${n}`) * 0.0001) * 43758.5453) * 2 - 1;
const smoothNoise = (seed: number, key: string, x: number) => { const n=Math.floor(x), t=x-n, u=t*t*(3-2*t); return noise(seed,key,n)*(1-u)+noise(seed,key,n+1)*u; };
const bjtHour = (timestamp: number) => ((timestamp / 3600000 + 8) % 24 + 24) % 24;
const day = (timestamp: number) => Math.floor((timestamp + 8*3600000) / 86400000);
const phase = (timestamp: number) => TWO_PI * (bjtHour(timestamp)-14)/24;
const seriesOffset = (series: Series) => (hash(series.id)%1000)/1000;
const eventCenter = (seed:number,facilityId:string,minute:number) => 8 + (hash(`${seed}:${facilityId}:${minute}`)%4400)/100;
const event = (seed: number, facilityId: string, timestamp: number) => {
  const minute = Math.floor(timestamp/60000), position = (timestamp % 60000)/1000;
  const center = eventCenter(seed,facilityId,minute);
  const amplitude = 40 + hash(`${seed}:${facilityId}:a:${minute}`)%110;
  const distance = Math.abs(position-center);
  return distance < 2.5 ? amplitude * Math.exp(-distance*distance/0.7) : 0;
};
const isEventMetric=(metricId:MetricId)=>metricId==='axle_load'||metricId==='vertical_compressive_strain'||metricId==='horizontal_tensile_strain'||metricId==='asphalt_bottom_tensile_strain'||metricId==='foundation_strain'||metricId==='culvert_strain';
const rainfallRate = (seed: number, facilityId: string, timestamp: number) => {
  const hour = Math.floor(timestamp/3600000);
  const storm = hash(`${seed}:${facilityId}:rain:${hour}`)%13 < 2;
  return storm ? 0.005 + 0.02 * (1+smoothNoise(seed,`${facilityId}:rainfall`,timestamp/900000))/2 : 0;
};
export function valueAt(series: Series, timestamp: number, seed=DEFAULT_SEED, depthM=0): number {
  const o=seriesOffset(series), p=phase(timestamp), s=timestamp/1000, n=smoothNoise(seed,series.id,s/1800);
  const air=2 + 15*Math.cos(p) + 3*n - (hash(series.facilityId)%5);
  const deep=-1 + 6*Math.exp(-depthM/4)*Math.cos(p-depthM/4) + 0.7*n + 2*o;
  const wet=clamp(22 + 8*smoothNoise(seed,`${series.facilityId}:wet`,s/18000) + 2*o,5,55);
  const pulse=event(seed,series.facilityId,timestamp);
  const slow=s/86400;
  switch(series.metricId) {
    case 'air_temperature': return clamp(air,-20,25);
    case 'ground_temperature': case 'pile_temperature': case 'pile_side_temperature': case 'soil_temperature': return clamp(deep,-8,8);
    case 'pavement_temperature': return clamp(air+8*Math.max(0,Math.cos(p)), -25,45);
    case 'relative_humidity': return clamp(62-1.3*air+8*n,15,95);
    case 'volumetric_water_content': case 'pavement_moisture': case 'soil_water_content': return wet;
    case 'wind_speed': case 'ventilation_speed': return clamp(5+3*smoothNoise(seed,series.id,s/600)+2*o,0,20);
    case 'wind_direction': return ((200+140*smoothNoise(seed,series.id,s/900)+360)%360);
    case 'air_pressure': return clamp(65+2*n+3*o,50,80);
    case 'rainfall': return Math.max(0,rainfallRate(seed,series.facilityId,timestamp)*series.samplePeriodMs/1000);
    case 'shortwave_radiation': return clamp(950*Math.max(0,Math.cos(p))*(0.8+0.2*n),0,1200);
    case 'uv_radiation': return clamp(50*Math.max(0,Math.cos(p))*(0.8+0.2*n),0,60);
    case 'net_radiation': return clamp(560*Math.max(0,Math.cos(p))-90+30*n,-150,800);
    case 'axle_load': return pulse ? clamp(pulse,20,160) : 0;
    case 'vertical_compressive_strain': return clamp(-1.7*pulse + 8*n,-300,300);
    case 'horizontal_tensile_strain': case 'asphalt_bottom_tensile_strain': case 'foundation_strain': case 'culvert_strain': return clamp(1.3*pulse + 12*n,-300,300);
    case 'lateral_displacement': case 'pier_displacement': return clamp(3*Math.sin(slow/20)+0.05*air+n,-10,20);
    case 'layer_deformation': case 'cumulative_deformation': case 'settlement': return clamp(Math.max(0,slow*0.004)+0.3*n,-10,20);
    case 'earth_pressure': return clamp(95+12*n+4*o,20,250);
    case 'heat_flux': return clamp(45*Math.sin(p)+20*n,-120,200);
  }
}
export function alignedTime(timestamp: number, periodMs: number): number { return Math.floor(timestamp/periodMs)*periodMs; }
export function sampleAt(series: Series, timestamp: number, revision=0, seed=DEFAULT_SEED, depthM=0): Sample {
  const time=alignedTime(timestamp,series.samplePeriodMs);
  return { seriesId: series.id, timestamp: time, value: valueAt(series,time,seed,depthM), quality:'valid', revision, simulationVersion:SIMULATION_VERSION };
}
export interface RuntimeResult { requestId: string; revision: number; simulationVersion: typeof SIMULATION_VERSION; timestamp: number }
export interface SnapshotResult extends RuntimeResult { samples: Sample[]; units: Record<string,string> }
export interface SeriesResult extends RuntimeResult { seriesId: string; metricId: MetricId; unit: string; from: number; to: number; samples: Sample[] }
export interface ProfileResult extends RuntimeResult { boreholeId: string; metricId: MetricId; unit: string; points: Array<{pointId:string; depthM:number; sample:Sample}> }
export interface StatisticsResult extends RuntimeResult { stats: CatalogStats; totalSamples: string }
export interface RuntimeState { timestamp: number; revision: number; speed: 1|10|60; paused: boolean; seed: number }
export class SimulationRuntime {
  readonly catalog: Catalog;
  private clock: RuntimeState;
  private bySeries: Map<string,Series>;
  private pointDepth: Map<string,number>;
  constructor(catalog:Catalog, seed=DEFAULT_SEED, timestamp=START_TIME) {
    this.catalog=catalog;
    this.clock={timestamp,revision:0,speed:1,paused:false,seed};
    this.bySeries=new Map(catalog.series.map(s=>[s.id,s]));
    this.pointDepth=new Map(catalog.points.map(p=>[p.id,p.depthM??0]));
  }
  get state():RuntimeState { return {...this.clock}; }
  advance(wallMs:number):RuntimeState { if(!this.clock.paused) { this.clock.timestamp+=wallMs*this.clock.speed; this.clock.revision++; } return this.state; }
  control(change:Partial<Pick<RuntimeState,'timestamp'|'speed'|'paused'|'seed'>>):RuntimeState { this.clock={...this.clock,...change,revision:this.clock.revision+1}; return this.state; }
  reset():RuntimeState { this.clock={timestamp:START_TIME,revision:this.clock.revision+1,speed:1,paused:false,seed:DEFAULT_SEED}; return this.state; }
  private series(id:string):Series { const s=this.bySeries.get(id); if(!s) throw new Error(`Unknown series: ${id}`); return s; }
  snapshot(requestId:string, seriesIds:string[], timestamp=this.clock.timestamp):SnapshotResult {
    const samples=seriesIds.map(id=>{const s=this.series(id);return sampleAt(s,timestamp,this.clock.revision,this.clock.seed,this.pointDepth.get(s.pointId)??0)});
    return {requestId,revision:this.clock.revision,simulationVersion:SIMULATION_VERSION,timestamp,samples,units:Object.fromEntries(seriesIds.map(id=>{const s=this.series(id);return [id,metricById[s.metricId].unit]}))};
  }
  querySeries(requestId:string, seriesId:string, from:number, to:number, maxPoints=1200):SeriesResult {
    if(to<from || to>this.clock.timestamp || from<this.clock.timestamp-MAX_HISTORY_MS) throw new RangeError('Query outside available simulation history');
    const s=this.series(seriesId), budget=Math.max(2,Math.min(maxPoints,2400));
    const period=isEventMetric(s.metricId)?10000:s.samplePeriodMs;
    const count=Math.floor((to-from)/period)+1;
    const depth=this.pointDepth.get(s.pointId)??0;
    const at=(t:number)=>sampleAt(s,t,this.clock.revision,this.clock.seed,depth);
    let samples:Sample[];
    if(count<=budget && !isEventMetric(s.metricId)) {
      samples=[];for(let t=Math.ceil(from/period)*period;t<=to;t+=period)samples.push(at(t));
    } else {
      const buckets=Math.max(1,Math.floor((budget-2)/2)),width=(to-from)/buckets;
      samples=[];
      for(let i=0;i<buckets;i++) {
        const a=from+i*width,b=i===buckets-1?to:from+(i+1)*width;
        const candidates=[a,a+(b-a)*0.25,(a+b)/2,a+(b-a)*0.75,b];
        if(isEventMetric(s.metricId)) {
          for(let minute=Math.floor(a/60000);minute<=Math.floor(b/60000);minute++) {
            const peak=minute*60000+eventCenter(this.clock.seed,s.facilityId,minute)*1000;
            if(peak>=a&&peak<=b)candidates.push(peak);
          }
        }
        let min:Sample|undefined,max:Sample|undefined;
        for(const t of candidates){const candidate=at(Math.min(to,Math.max(from,t)));if(!min||(candidate.value??Infinity)<(min.value??Infinity))min=candidate;if(!max||(candidate.value??-Infinity)>(max.value??-Infinity))max=candidate;}
        if(min&&max)samples.push(...(min.timestamp<=max.timestamp?[min,max]:[max,min]));
      }
      samples=[at(from),...samples,at(to)].filter((sample,index,array)=>index===0||sample.timestamp!==array[index-1].timestamp).slice(0,budget);
    }
    return {requestId,revision:this.clock.revision,simulationVersion:SIMULATION_VERSION,timestamp:this.clock.timestamp,seriesId,metricId:s.metricId,unit:metricById[s.metricId].unit,from,to,samples};
  }
  profile(requestId:string,boreholeId:string,metricId:MetricId,timestamp=this.clock.timestamp):ProfileResult {
    const borehole=this.catalog.boreholes.find(b=>b.id===boreholeId);
    if(!borehole) throw new Error(`Unknown borehole: ${boreholeId}`);
    const points=this.catalog.points.filter(p=>p.boreholeId===boreholeId && p.metricId===metricId).sort((a,b)=>(a.depthM??0)-(b.depthM??0));
    return {requestId,revision:this.clock.revision,simulationVersion:SIMULATION_VERSION,timestamp,boreholeId,metricId,unit:metricById[metricId].unit,points:points.map(p=>({pointId:p.id,depthM:p.depthM??0,sample:sampleAt(this.series(p.seriesId),timestamp,this.clock.revision,this.clock.seed,p.depthM??0)}))};
  }
  statistics(requestId:string,stats:CatalogStats):StatisticsResult {
    const elapsed=Math.max(0,this.clock.timestamp-START_TIME);
    const total=this.catalog.series.reduce((sum,s)=>sum+BigInt(Math.floor(elapsed/(isEventMetric(s.metricId)?10000:s.samplePeriodMs))+1+(isEventMetric(s.metricId)?Math.floor(elapsed/60000)*50:0)),0n);
    return {requestId,revision:this.clock.revision,simulationVersion:SIMULATION_VERSION,timestamp:this.clock.timestamp,stats,totalSamples:total.toString()};
  }
}
export function reduceExtrema(samples:Sample[],maxPoints:number):Sample[] {
  if(samples.length<=maxPoints)return samples;
  const bucket=Math.ceil((samples.length-2)/Math.max(1,Math.floor((maxPoints-2)/2))), result=[samples[0]];
  for(let i=1;i<samples.length-1;i+=bucket){const slice=samples.slice(i,Math.min(i+bucket,samples.length-1));let min=slice[0],max=slice[0];for(const sample of slice){if((sample.value??Infinity)<(min.value??Infinity))min=sample;if((sample.value??-Infinity)>(max.value??-Infinity))max=sample;}result.push(...(min.timestamp<max.timestamp?[min,max]:max.timestamp<min.timestamp?[max,min]:[min]));}
  result.push(samples[samples.length-1]);return result.slice(0,maxPoints);
}
export function dailyRainfall(samples:Sample[],timestamp:number):number { const d=day(timestamp);return samples.filter(s=>day(s.timestamp)===d).reduce((sum,s)=>sum+(s.value??0),0); }
export function circularMeanDegrees(values:number[]):number {const x=values.reduce((s,v)=>s+Math.cos(v*Math.PI/180),0),y=values.reduce((s,v)=>s+Math.sin(v*Math.PI/180),0);return (Math.atan2(y,x)*180/Math.PI+360)%360;}

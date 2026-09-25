import { describe, expect, it } from 'vitest';
import { catalogStats, createCatalog, filterFacilities, type CatalogTemplate } from '../src/domain/catalog';
import { metricsBySpecialty } from '../src/domain/metrics';
import type { Corridor, ModelTemplate, ObservationField } from '../src/domain/types';
import { circularMeanDegrees, DEFAULT_SEED, sampleAt, SimulationRuntime, START_TIME } from '../src/runtime/simulation';
const corridors: Corridor[] = ['qingzang','qingkang'].map((id,index)=>({id,name:id,start:'A',end:'B',route:[{longitude:95+index,latitude:33},{longitude:96+index,latitude:34}],bounds:[95+index,33,96+index,34],sourceVersion:'fixture'}));
const fields: ObservationField[] = corridors.flatMap(c=>['climate','materials','engineering'].map(category=>({id:`${c.id}-${category}`,name:category,category:category as ObservationField['category'],corridorId:c.id,geometry:{type:'Polygon',coordinates:[[[95,33],[96,33],[96,34],[95,33]]]},sourceKind:'simulated-layout',description:'fixture'})));
const ids:ModelTemplate[]=['station','ventilated-subgrade','rockfill-subgrade','pavement','bridge','box-culvert','pipe-culvert','weather-station'];
const templates=Object.fromEntries(ids.map(id=>[id,{version:'pov-model-v1',parts:[{semanticId:'sensor',label:'测点',selectable:true}],anchors:[{anchorId:'sensor-1',componentId:'sensor',localPosition:[0,0,0]}]}])) as unknown as Record<ModelTemplate,CatalogTemplate>;
const catalog=createCatalog(corridors,fields,templates);
const runtime=new SimulationRuntime(catalog);
const seriesFor=(metricId:string)=>catalog.series.find(s=>s.metricId===metricId)!;

describe('catalog contract',()=>{
  it('provides stable scale, identifiers, relations and all metrics',()=>{
    expect(catalogStats(catalog)).toMatchObject({facilities:80,points:4000,devices:640,series:4000});
    expect(new Set(catalog.facilities.map(f=>f.id)).size).toBe(80);
    expect(new Set(catalog.series.map(s=>s.id)).size).toBe(4000);
    expect(catalog.points.every(p=>catalog.devices.some(d=>d.id===p.deviceId))).toBe(true);
    expect(catalog.points.every(p=>p.modelAnchor.modelAssetVersion==='pov-model-v1'&&p.modelAnchor.componentId==='sensor')).toBe(true);
    expect(Object.values(metricsBySpecialty).flat().every(id=>catalog.series.some(s=>s.metricId===id))).toBe(true);
  });
  it('deduplicates overlap by facility ID',()=>{
    const overlap=catalog.facilities.find(f=>f.fieldIds.length>1)!;
    const result=filterFacilities(catalog,{fieldIds:overlap.fieldIds});
    expect(result.filter(f=>f.id===overlap.id)).toHaveLength(1);
    expect(catalogStats(catalog,result.map(f=>f.id)).facilities).toBe(result.length);
  });
});

describe('simulation contract',()=>{
  it('matches a snapshot and historical sample at the same time',()=>{
    const series=seriesFor('ground_temperature'),timestamp=START_TIME+3600000;
    runtime.control({timestamp});
    const snapshot=runtime.snapshot('a',[series.id],timestamp).samples[0];
    const history=runtime.querySeries('b',series.id,timestamp-60000,timestamp,1200);
    expect(history.samples.at(-1)?.value).toBe(snapshot.value);
    expect(history.unit).toBe('℃');
    const depth=catalog.points.find(p=>p.id===series.pointId)?.depthM??0;
    expect(sampleAt(series,timestamp,0,DEFAULT_SEED,depth).value).toBe(snapshot.value);
  });
  it('freezes and resumes all observation time',()=>{
    runtime.reset();runtime.control({paused:true});const frozen=runtime.state.timestamp;
    runtime.advance(5000);expect(runtime.state.timestamp).toBe(frozen);
    runtime.control({paused:false,speed:10});runtime.advance(5000);expect(runtime.state.timestamp).toBe(frozen+50000);
  });
  it('bounds rain, radiation and wind while wrapping angle correctly',()=>{
    for(const id of ['rainfall','shortwave_radiation','uv_radiation','wind_direction'])for(let h=0;h<24;h++){
      const value=sampleAt(seriesFor(id),START_TIME+h*3600000).value!;
      expect(value).toBeGreaterThanOrEqual(0);
      if(id==='wind_direction')expect(value).toBeLessThan(360);
    }
    expect(circularMeanDegrees([359,1])).toBeCloseTo(0,5);
  });
  it('returns rainfall bucket totals and Beijing-day cumulative values',()=>{
    const rain=seriesFor('rainfall');
    const end=START_TIME+24*3600000;
    const clock=new SimulationRuntime(catalog,DEFAULT_SEED,end);
    const result=clock.querySeries('rain',rain.id,end-3600000,end,120);
    expect(result.samples).toHaveLength(result.dailyCumulative!.length);
    expect(result.samples.length).toBeLessThanOrEqual(120);
    expect(result.aggregationMs).toBeGreaterThan(rain.samplePeriodMs);
    const raw=[];
    for(let time=end-3600000;time<=end;time+=rain.samplePeriodMs)raw.push(sampleAt(rain,time,0,DEFAULT_SEED).value!);
    const bucketSum=result.samples.reduce((sum,sample)=>sum+(sample.value??0),0);
    expect(bucketSum).toBeCloseTo(raw.reduce((sum,value)=>sum+value,0),5);
    expect(result.dailyCumulative!.every((sample,index,array)=>index===0||(sample.value??0)>=(array[index-1].value??0))).toBe(true);
  });
  it('bounds a 30-day rainfall result',()=>{
    const rain=seriesFor('rainfall');
    const end=START_TIME+30*86400000;
    const clock=new SimulationRuntime(catalog,DEFAULT_SEED,end);
    const started=performance.now();
    const result=clock.querySeries('rain-month',rain.id,end-30*86400000,end,1200);
    expect(result.samples.length).toBeLessThanOrEqual(1200);
    expect(result.dailyCumulative).toHaveLength(result.samples.length);
    expect(performance.now()-started).toBeLessThan(3000);
  });
  it('queries a month of vehicle events with bounded output and latency',()=>{
    const series=seriesFor('axle_load'),end=START_TIME+30*86400000;runtime.control({timestamp:end});
    const started=performance.now(),result=runtime.querySeries('month',series.id,START_TIME,end,1200);
    expect(result.samples.length).toBeLessThanOrEqual(1200);
    expect(result.samples.some(s=>(s.value??0)>100)).toBe(true);
    expect(performance.now()-started).toBeLessThan(3000);
  });
  it('returns same-time downward depth samples',()=>{
    const borehole=catalog.boreholes[0],metricId=catalog.points.find(p=>p.boreholeId===borehole.id)!.metricId;
    const profile=runtime.profile('profile',borehole.id,metricId);
    expect(profile.points.length).toBeGreaterThan(1);
    expect(profile.points.map(p=>p.depthM)).toEqual([...profile.points.map(p=>p.depthM)].sort((a,b)=>a-b));
    expect(profile.points.every(p=>p.sample.timestamp===profile.points[0].sample.timestamp)).toBe(true);
  });
});

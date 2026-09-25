import { metrics, metricsBySpecialty } from './metrics';
import type { Borehole, Catalog, CatalogStats, Channel, Component, Corridor, Device, Facility, ModelTemplate, ObservationField, ObservationPoint, Position, Series, Specialty, Station } from './types';

export const station: Station = { id:'huashixia-station', name:'花石峡野外观测站', position:{longitude:98.85,latitude:34.36,height:4300}, modelTemplate:'station', sourceKind:'simulated-layout', description:'花石峡附近的样例站区位置，并非真实站房测量坐标。' };
const plan: Specialty[] = ['subgrade','pavement','bridge','culvert','weather'];
const counts: Record<Specialty,number> = {subgrade:12,pavement:12,bridge:6,culvert:6,weather:4};
const names: Record<Specialty,string> = {subgrade:'路基',pavement:'路面',bridge:'桥梁',culvert:'涵洞',weather:'气象'};
const model = (specialty:Specialty,index:number):Facility['modelTemplate'] => specialty==='subgrade'?(index%2?'rockfill-subgrade':'ventilated-subgrade'):specialty==='culvert'?(index%2?'pipe-culvert':'box-culvert'):specialty==='weather'?'weather-station':specialty;
const routePosition = (route:Position[],fraction:number):Position => {
  if(!route.length) throw new Error('Corridor route has no coordinates');
  const x=fraction*(route.length-1), i=Math.min(route.length-2,Math.floor(x)), t=x-i;
  if(route.length===1)return route[0];
  const a=route[i],b=route[i+1];return {longitude:a.longitude+(b.longitude-a.longitude)*t,latitude:a.latitude+(b.latitude-a.latitude)*t,height:(a.height??0)+((b.height??0)-(a.height??0))*t};
};
export type CatalogTemplate = { version:string; parts:readonly {semanticId:string;label:string;selectable?:boolean}[]; anchors:readonly {anchorId:string;componentId:string;localPosition:readonly [number,number,number]}[] };
export interface CorridorGeoJSON { features: Array<{ geometry:{type:'LineString';coordinates:number[][]}; properties:{id:string;name:string;start:string;end:string;sourceVersion:string} }> }
export interface FieldGeoJSON { features: Array<{geometry:ObservationField['geometry'];properties:{id:string;name:string;category:ObservationField['category'];corridorId:string;sourceKind:ObservationField['sourceKind'];description:string}}> }
export function catalogFromGeoJSON(corridorData:CorridorGeoJSON,fieldData:FieldGeoJSON,templates:Record<ModelTemplate,CatalogTemplate>):Catalog {
  const corridors:Corridor[]=corridorData.features.map(feature=>{
    const route=feature.geometry.coordinates.map(([longitude,latitude,height])=>({longitude,latitude,height}));
    const xs=route.map(p=>p.longitude),ys=route.map(p=>p.latitude);
    return {id:feature.properties.id,name:feature.properties.name,start:feature.properties.start,end:feature.properties.end,route,bounds:[Math.min(...xs),Math.min(...ys),Math.max(...xs),Math.max(...ys)],sourceVersion:feature.properties.sourceVersion};
  });
  const fields:ObservationField[]=fieldData.features.map(feature=>({...feature.properties,geometry:feature.geometry}));
  return createCatalog(corridors,fields,templates);
}
export function createCatalog(corridors:Corridor[],fields:ObservationField[],templates:Record<ModelTemplate,CatalogTemplate>):Catalog {
  if(corridors.length!==2 || fields.length!==6) throw new Error('Catalog requires two corridors and six field instances');
  const facilities:Facility[]=[],components:Component[]=[],boreholes:Borehole[]=[],points:ObservationPoint[]=[],devices:Device[]=[],channels:Channel[]=[],series:Series[]=[];
  for(const corridor of corridors) {
    let facilityNumber=0;
    for(const specialty of plan) for(let index=0;index<counts[specialty];index++) {
      facilityNumber++;
      const id=`${corridor.id}-${specialty}-${String(index+1).padStart(2,'0')}`;
      const modelTemplate=model(specialty,index),template=templates[modelTemplate];
      if(!template?.anchors.length)throw new Error(`Missing model anchors for ${modelTemplate}`);
      const position=routePosition(corridor.route,(facilityNumber-0.5)/40);
      const localFields=fields.filter(field=>field.corridorId===corridor.id);
      const fieldIds=[localFields[index%3]?.id, ...(index%7===0?[localFields[(index+1)%3]?.id]:[])].filter((item):item is string=>!!item);
      const componentIds:string[]=[],boreholeIds:string[]=[],pointIds:string[]=[],deviceIds:string[]=[];
      const selectable=template.parts.filter(part=>part.selectable);
      for(const [j,part] of selectable.entries()){const componentId=`${id}-${part.semanticId}`;componentIds.push(componentId);components.push({id:componentId,facilityId:id,name:part.label,modelPart:part.semanticId,depthM:j*2});}
      if(specialty==='subgrade'||specialty==='bridge') for(let j=0;j<2;j++){const bhId=`${id}-borehole-${j+1}`;boreholeIds.push(bhId);boreholes.push({id:bhId,facilityId:id,componentId:componentIds[Math.min(2,componentIds.length-1)],name:`${j+1} 号孔`,depthM:12,modelPart:template.anchors[0].componentId});}
      for(let d=0;d<8;d++) {
        const deviceId=`${id}-device-${d+1}`, channelIds:string[]=[];deviceIds.push(deviceId);
        for(let local=0;local<(d<2?7:6);local++) {
          const pointIndex=d<2?d*7+local:14+(d-2)*6+local;
          const metricIds=metricsBySpecialty[specialty],metricId=metricIds[pointIndex%metricIds.length];
          const pointId=`${id}-point-${String(pointIndex+1).padStart(2,'0')}`,channelId=`${deviceId}-channel-${local+1}`,seriesId=`${pointId}-series`;
          const anchor=template.anchors[pointIndex%template.anchors.length];
          const componentId=`${id}-${anchor.componentId}`,depthM=boreholeIds.length?1+(pointIndex%6)*2:undefined;
          const boreholeId=boreholeIds.length?boreholeIds[Math.floor(pointIndex/6)%2]:undefined;
          const period=(metricId==='axle_load'||metricId.includes('strain'))?100:((specialty==='weather'||metricId.includes('temperature'))?5000:10000);
          pointIds.push(pointId);channelIds.push(channelId);
          points.push({id:pointId,facilityId:id,componentId,boreholeId,name:`${names[specialty]}测点 ${pointIndex+1}`,depthM,modelAnchor:{modelAssetVersion:template.version,componentId:anchor.componentId,anchorId:anchor.anchorId,localPosition:[...anchor.localPosition],normal:[0,1,0]},position:{...position},deviceId,metricId,seriesId});
          channels.push({id:channelId,deviceId,pointId,metricId,seriesId,samplePeriodMs:period});
          series.push({id:seriesId,facilityId:id,pointId,deviceId,channelId,metricId,samplePeriodMs:period,simulationVersion:'sim-v1'});
        }
        const deviceAnchor=template.anchors[d%template.anchors.length];
        devices.push({id:deviceId,facilityId:id,componentId:`${id}-${deviceAnchor.componentId}`,name:`${names[specialty]}采集设备 ${d+1}`,type:`${specialty}-sensor`,modelAnchor:deviceAnchor.anchorId,channelIds});
      }
      facilities.push({id,name:`${corridor.name}${names[specialty]}样例 ${index+1}`,specialty,corridorId:corridor.id,fieldIds,chainage:`K${(facilityNumber*12.4).toFixed(1)}`,position,heading:(facilityNumber*29)%360,modelTemplate,sourceKind:'simulated-layout',componentIds,boreholeIds,pointIds,deviceIds});
    }
  }
  return {station,corridors,fields,facilities,components,boreholes,points,devices,channels,metrics,series};
}
export function catalogStats(catalog:Catalog,facilityIds?:string[]):CatalogStats {
  const selected=new Set(facilityIds??catalog.facilities.map(f=>f.id));
  const facilities=catalog.facilities.filter(f=>selected.has(f.id));
  return {facilities:facilities.length,points:catalog.points.filter(p=>selected.has(p.facilityId)).length,devices:catalog.devices.filter(d=>selected.has(d.facilityId)).length,series:catalog.series.filter(s=>selected.has(s.facilityId)).length,bySpecialty:{subgrade:facilities.filter(f=>f.specialty==='subgrade').length,pavement:facilities.filter(f=>f.specialty==='pavement').length,bridge:facilities.filter(f=>f.specialty==='bridge').length,culvert:facilities.filter(f=>f.specialty==='culvert').length,weather:facilities.filter(f=>f.specialty==='weather').length}};
}
export function filterFacilities(catalog:Catalog,filter:{corridorId?:string;fieldIds?:string[];specialty?:Specialty;search?:string}):Facility[] {
  return catalog.facilities.filter(f=>(!filter.corridorId||f.corridorId===filter.corridorId)&&(!filter.specialty||f.specialty===filter.specialty)&&(!filter.fieldIds?.length||filter.fieldIds.some(id=>f.fieldIds.includes(id)))&&(!filter.search||`${f.name} ${f.chainage} ${f.id}`.toLowerCase().includes(filter.search.toLowerCase())));
}
export const getFacility=(catalog:Catalog,id:string)=>catalog.facilities.find(f=>f.id===id);
export const getSeries=(catalog:Catalog,id:string)=>catalog.series.find(s=>s.id===id);

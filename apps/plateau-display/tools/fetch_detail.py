"""Fetch sparse high-detail tiles along the verified routes and sample fields."""
import json, math, sys
from pathlib import Path
from concurrent.futures import ThreadPoolExecutor, as_completed
sys.path.insert(0,str(Path(__file__).resolve().parent))
from fetch_geography import ROOT, SOURCES, one, tile
SOURCE = Path(__file__).resolve().parents[1] / 'src/geography/data'
route_features=json.loads((SOURCE/'corridors.geojson').read_text())['features']
field_features=json.loads((SOURCE/'fields.geojson').read_text())['features']
# One tile either side of the route at medium zoom: a roughly 50 km/25 km
# local corridor strip. The six field sites then get true 10 m-class pixels.
tasks=set()
for feature in route_features:
 coords=feature['geometry']['coordinates']
 for z in (10,11):
  for lon,lat in coords[::5]:
   x,y=tile(lon,lat,z)
   for dx in (-1,0,1):
    for dy in (-1,0,1):tasks.add(('imagery',z,x+dx,y+dy))
 for z in (9,10):
  for lon,lat in coords[::10]:
   x,y=tile(lon,lat,z)
   for dx in (-1,0,1):
    for dy in (-1,0,1):tasks.add(('terrain',z,x+dx,y+dy))
for feature in field_features:
 ring=feature['geometry']['coordinates'][0]
 lon=sum(p[0] for p in ring[:-1])/(len(ring)-1)
 lat=sum(p[1] for p in ring[:-1])/(len(ring)-1)
 for z in (12,13,14):
  x,y=tile(lon,lat,z)
  for dx in (-2,-1,0,1,2):
   for dy in (-2,-1,0,1,2):tasks.add(('imagery',z,x+dx,y+dy))
 for z in (11,12):
  x,y=tile(lon,lat,z)
  for dx in (-2,-1,0,1,2):
   for dy in (-2,-1,0,1,2):tasks.add(('terrain',z,x+dx,y+dy))
# The sample station is near Huashixia. Add it as an independent local patch.
for z in (12,13,14):
 x,y=tile(98.15,34.77,z)
 for dx in (-2,-1,0,1,2):
  for dy in (-2,-1,0,1,2):tasks.add(('imagery',z,x+dx,y+dy))
for z in (11,12):
 x,y=tile(98.15,34.77,z)
 for dx in (-2,-1,0,1,2):
  for dy in (-2,-1,0,1,2):tasks.add(('terrain',z,x+dx,y+dy))
print('detail tiles',len(tasks),flush=True)
results=[]
with ThreadPoolExecutor(max_workers=8) as pool:
 fs={pool.submit(one,t):t for t in sorted(tasks)}
 for i,f in enumerate(as_completed(fs),1):
  results.append(f.result())
  if i%100==0:print(i,'/',len(tasks),flush=True)
manifest_path=ROOT/'manifest.json'
manifest=json.loads(manifest_path.read_text())
by_id={r['id']:r for r in manifest['tiles']}
by_id.update({r['id']:r for r in results})
manifest['tiles']=sorted(by_id.values(),key=lambda x:x['id'])
manifest['imagery']['maxPackagedZoom']=14
manifest['imagery']['detailCoverage']='z10–11 sparse route strips; z12–14 seven local patches; outside these regions the overview z9 layer remains visible'
manifest['imagery']['nativeSourceResolution']='2016 Sentinel-2 source 10 m; delivered overview z9 about 250 m/pixel at 34°N; local z14 about 8 m tile pixels but no finer than native 10 m content'
manifest['terrain']['maxPackagedZoom']=12
manifest['terrain']['detailCoverage']='z9–10 sparse route strips; z11–12 seven local patches; higher levels resample last available local tile'
manifest['terrain']['encodedResolution']='Terrarium RGB 1/256 m vertical encoding; source land SRTM nominal 30 m with 90 m nominal quality; delivered z8 overview about 500 m/pixel and z12 local about 32 m/pixel at 34°N'
manifest_path.write_text(json.dumps(manifest,ensure_ascii=False,separators=(',',':'))+'\n')
print('done',len(manifest['tiles']),sum(r['bytes'] for r in manifest['tiles']),'bytes',flush=True)

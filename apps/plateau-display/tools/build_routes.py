"""Rebuild the two POV-01 road corridors from fixed Geofabrik OSM PBF files.

Preparation only; requires `pip install osmium networkx pyproj`.
Usage: python tools/build_routes.py qinghai.osm.pbf tibet.osm.pbf
Verify the source PBF SHA-256 values in docs/geography-sources.md first.
"""
from pathlib import Path
from sys import argv
import json, math, osmium, networkx as nx
from pyproj import Transformer

OUT = Path(__file__).resolve().parents[1] / 'src/geography/data'
CONNECTOR_WAY = 45872603  # mapped trunk way without G214 ref, between the two tagged segments

class Roads(osmium.SimpleHandler):
    def __init__(self): super().__init__(); self.ways=[]
    def way(self,w):
        ref=w.tags.get('ref','')
        if 'G109' not in ref and 'G214' not in ref and w.id != CONNECTOR_WAY:return
        coords=[]
        for n in w.nodes:
            if not n.location.valid():return
            coords.append([n.lon,n.lat,n.ref])
        if len(coords)>1:self.ways.append({'id':w.id,'version':w.version,'timestamp':str(w.timestamp),'ref':ref,'coords':coords})

def distance(a,b):
    lat=math.radians((a[1]+b[1])/2)
    return math.hypot((a[0]-b[0])*111.32*math.cos(lat),(a[1]-b[1])*111.32)

def make_route(ways,ref,start,end):
    graph=nx.Graph();geo={}
    for way in ways:
        if (ref not in way['ref'] and not (ref=='G214' and way['id']==CONNECTOR_WAY)) or way['ref']=='G109旧':continue
        for point in way['coords']:geo[point[2]]=point[:2]
        for a,b in zip(way['coords'],way['coords'][1:]):graph.add_edge(a[2],b[2],weight=distance(a,b),way=way['id'])
    nodes=list(graph.nodes)
    a=min(nodes,key=lambda n:distance(geo[n],start))
    b=min(nodes,key=lambda n:distance(geo[n],end))
    if ref=='G109':
        # OSM G109 ref ends on Nagqu's outskirts; do not invent a connection
        # through city streets and present it as tagged G109.
        component=nx.node_connected_component(graph,a)
        b=min(component,key=lambda n:distance(geo[n],end))
    path=nx.shortest_path(graph,a,b,weight='weight')
    coords=[];node_ids=[]
    for n in path:
        if not coords or distance(coords[-1],geo[n])>.001:coords.append(geo[n]);node_ids.append(n)
    way_ids=list(dict.fromkeys(graph.edges[path[i],path[i+1]]['way'] for i in range(len(path)-1)))
    cumulative=[0.0]
    for p,q in zip(coords,coords[1:]):cumulative.append(cumulative[-1]+distance(p,q))
    controls=[]
    for i in range(11):
        target=cumulative[-1]*i/10
        index=min(range(len(cumulative)),key=lambda k:abs(cumulative[k]-target))
        controls.append({'fraction':round(i/10,1),'longitude':coords[index][0],'latitude':coords[index][1],
                         'osmNodeId':node_ids[index],'distanceFromStartKm':round(cumulative[index],2)})
    source_ways={w['id']:{'version':w['version'],'timestamp':w['timestamp'],'ref':w['ref']} for w in ways if w['id'] in way_ids}
    return coords,{'roadRef':ref,'wayIds':way_ids,'wayVersions':source_ways,'controls':controls,'lengthKm':round(cumulative[-1],1),
                   'sourceStart':coords[0],'sourceEnd':coords[-1]}

def polygon(center):
    lon,lat=center;zone=int((lon+180)//6)+1
    utm=32600+zone
    forward=Transformer.from_crs(4326,utm,always_xy=True).transform
    inverse=Transformer.from_crs(utm,4326,always_xy=True).transform
    x,y=forward(lon,lat)
    return [[round(v,6) for v in inverse(x+9000*math.cos(2*math.pi*k/24),y+7000*math.sin(2*math.pi*k/24))] for k in range(25)]

def main():
    if len(argv)!=3:raise SystemExit(__doc__)
    handler=Roads()
    for file in argv[1:]:handler.apply_file(file,locations=True)
    routes=[];fields=[];proof={}
    config=[('G109','qingzang','青藏走廊 · 格尔木—那曲','格尔木','那曲',(94.9,36.42),(92.05,31.48)),
            ('G214','qingkang','青康走廊 · 共和—玉树','共和','玉树',(100.62,36.28),(97.01,33.0))]
    for ref,id,name,start_name,end_name,start,end in config:
        coords,evidence=make_route(handler.ways,ref,start,end)
        proof[id]=evidence
        routes.append({'type':'Feature','properties':{'id':id,'name':name,'start':start_name,'end':end_name,'roadRef':ref,
                       'sourceVersion':'Geofabrik China Qinghai/Tibet 2026-09-25; way versions in route-evidence.json',
                       'lengthKm':evidence['lengthKm'],'sourceKind':'public-geography'},
                       'geometry':{'type':'LineString','coordinates':coords}})
        for category,label,fraction in [('climate','气候环境观测场',.22),('materials','结构材料观测场',.52),('engineering','实体工程观测场',.78)]:
            pos=coords[round((len(coords)-1)*fraction)]
            fields.append({'type':'Feature','properties':{'id':f'{id}-{category}','name':f'{name.split(" · ")[0]}{label} · 样例范围',
                           'category':category,'corridorId':id,'sourceKind':'simulated-layout',
                           'description':'工程演示用确定性模拟范围；并非实际建设边界。'},
                           'geometry':{'type':'Polygon','coordinates':[polygon(pos)]}})
    OUT.mkdir(parents=True,exist_ok=True)
    for name,features in [('corridors',routes),('fields',fields)]:
        (OUT/f'{name}.geojson').write_text(json.dumps({'type':'FeatureCollection','features':features},ensure_ascii=False,separators=(',',':'))+'\n')
    (OUT/'route-evidence.json').write_text(json.dumps(proof,ensure_ascii=False,indent=2)+'\n')
    print({id:(len(routes[i]['geometry']['coordinates']),proof[id]['lengthKm']) for i,id in enumerate(proof)})
if __name__=='__main__':main()

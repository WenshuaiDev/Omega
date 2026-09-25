"""Fetch the fixed public WMTS/terrain tile snapshot for POV-01.

Run only during asset preparation. Browser playback never contacts these hosts.
"""
from concurrent.futures import ThreadPoolExecutor, as_completed
from datetime import datetime, timezone
from pathlib import Path
from urllib.request import Request, urlopen
import hashlib, json, math, sys, time

ROOT = Path(__file__).resolve().parents[1] / 'public' / 'geography'
EXTENT = (88.0, 29.0, 104.0, 39.0)
SOURCES = {
    'imagery': ('https://tiles.maps.eox.at/wmts/1.0.0/s2cloudless_3857/default/GoogleMapsCompatible/{z}/{y}/{x}.jpg', 'jpg', 9),
    'terrain': ('https://s3.amazonaws.com/elevation-tiles-prod/terrarium/{z}/{x}/{y}.png', 'png', 8),
}

def tile(lon, lat, zoom):
    n = 2 ** zoom
    x = math.floor((lon + 180) / 360 * n)
    y = math.floor((1 - math.asinh(math.tan(math.radians(lat))) / math.pi) / 2 * n)
    return max(0, min(n-1, x)), max(0, min(n-1, y))

def one(task):
    kind, z, x, y = task
    url_pattern, ext, _ = SOURCES[kind]
    url = url_pattern.format(z=z, x=x, y=y)
    path = ROOT / kind / str(z) / str(x) / f'{y}.{ext}'
    if path.exists():
        data = path.read_bytes()
    else:
        err = None
        for attempt in range(4):
            try:
                with urlopen(Request(url, headers={'User-Agent': 'Omega POV-01 static geography asset preparation'}), timeout=30) as response:
                    data = response.read()
                    content_type = response.headers.get('Content-Type', '')
                    if not content_type.startswith('image/') or len(data) < 500:
                        raise ValueError(f'{content_type}: invalid tile payload')
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_bytes(data)
                break
            except Exception as e:
                err = e
                time.sleep(attempt + 1)
        else:
            raise RuntimeError(f'{url}: {err}')
    return {'id': f'{kind}-{z}-{x}-{y}', 'path': str(path.relative_to(ROOT.parent.parent)), 'source': url,
            'sha256': hashlib.sha256(data).hexdigest(), 'bytes': len(data), 'z': z, 'x': x, 'y': y}

def main():
    tasks=[]
    for kind, (_, _, max_zoom) in SOURCES.items():
        for z in range(max_zoom + 1):
            left, top = tile(EXTENT[0], EXTENT[3], z)
            right, bottom = tile(EXTENT[2], EXTENT[1], z)
            for x in range(left, right + 1):
                for y in range(top, bottom + 1):
                    tasks.append((kind,z,x,y))
    print(f'Fetching/checking {len(tasks)} tiles', flush=True)
    records=[]
    with ThreadPoolExecutor(max_workers=8) as pool:
        futures = {pool.submit(one, task): task for task in tasks}
        for i, future in enumerate(as_completed(futures), 1):
            records.append(future.result())
            if i % 100 == 0: print(i, '/', len(tasks), flush=True)
    records.sort(key=lambda x: x['id'])
    manifest={'version':'pov-geo-2026-09-25','acquiredAt':'2026-09-25','extent':EXTENT,
              'imagery':{'source':'EOxCloudless Sentinel-2 2016','license':'CC BY 4.0','attribution':'EOxCloudless by EOX IT Services GmbH; Contains modified Copernicus Sentinel data 2016','tileMatrixSet':'GoogleMapsCompatible','maxPackagedZoom':9,'nativeSourceResolution':'10 m; packaged overview is limited by zoom 9 to about 250 m per pixel at 34°N'},
              'terrain':{'source':'Mapzen Terrain Tiles Terrarium','license':'Source-dependent; see docs/geography-sources.md','attribution':'Mapzen/Tilezen and contributing elevation providers','maxPackagedZoom':8,'encodedResolution':'1/256 m per RGB step; spatial resolution varies by source and packaged zoom'},
              'tiles':records}
    (ROOT/'manifest.json').write_text(json.dumps(manifest,ensure_ascii=False,separators=(',',':'))+'\n')
    print('done',len(records),sum(x['bytes'] for x in records),'bytes',flush=True)
if __name__=='__main__': main()

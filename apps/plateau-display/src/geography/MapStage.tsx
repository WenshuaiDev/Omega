import { forwardRef, useEffect, useImperativeHandle, useRef, useState } from 'react';
import * as Cesium from 'cesium';
import type { Catalog, ObjectRef, Position } from '../domain/types';
import tileIndex from './data/tile-index.json';
import './map-stage.css';

const RECTANGLE = Cesium.Rectangle.fromDegrees(88, 29, 104, 39);
const ASSET_ROOT = `${import.meta.env.BASE_URL}geography`;
const COLORS = {
  qingzang: Cesium.Color.fromCssColorString('#45d9ed'),
  qingkang: Cesium.Color.fromCssColorString('#d9b66f'),
  climate: Cesium.Color.fromCssColorString('#64d5f0'),
  materials: Cesium.Color.fromCssColorString('#e7bd70'),
  engineering: Cesium.Color.fromCssColorString('#9dbeec'),
};

export interface MapLayers {
  corridors: boolean;
  fields: boolean;
  facilities: boolean;
  points: boolean;
  devices: boolean;
}
export interface MapStageProps {
  catalog: Catalog;
  selected?: ObjectRef | null;
  layers?: Partial<MapLayers>;
  visibleFacilityIds?: readonly string[];
  onSelect?: (ref: ObjectRef) => void;
  onReady?: () => void;
  onAssetError?: (assetId: string, message: string) => void;
  className?: string;
}
export interface MapStageHandle {
  focusOverview(duration?: number): void;
  focusCorridor(id: string, duration?: number): void;
  focusField(id: string, duration?: number): void;
  focusFacility(id: string, duration?: number): void;
  cancelFlight(): void;
  retryAssets(): void;
  getCamera(): { destination: Cesium.Cartesian3; heading: number; pitch: number; roll: number } | null;
  restoreCamera(camera: { destination: Cesium.Cartesian3; heading: number; pitch: number; roll: number }, duration?: number): void;
}

function position(p: Position, height = 0): Cesium.Cartesian3 {
  return Cesium.Cartesian3.fromDegrees(p.longitude, p.latitude, p.height ?? height);
}
function bounds(points: Position[]): Cesium.Rectangle {
  return Cesium.Rectangle.fromCartographicArray(points.map(p => Cesium.Cartographic.fromDegrees(p.longitude, p.latitude)));
}
function polygonPositions(geometry: { type: 'Polygon'; coordinates: number[][][] } | { type: 'MultiPolygon'; coordinates: number[][][][] }): Cesium.Cartesian3[][] {
  const rings = geometry.type === 'Polygon' ? [geometry.coordinates[0]] : geometry.coordinates.map(poly => poly[0]);
  return rings.map(ring => ring.map(([lon, lat]) => Cesium.Cartesian3.fromDegrees(lon, lat)));
}

const decodedTerrain = new Map<string, Promise<Float32Array>>();
const terrainTiles = new Set(tileIndex.terrain);
async function terrainTile(z: number, x: number, y: number): Promise<Float32Array> {
  const key = `${z}/${x}/${y}`;
  let current = decodedTerrain.get(key);
  if (!current) {
    current = (async () => {
      const response = await fetch(`${ASSET_ROOT}/terrain/${key}.png`);
      if (!response.ok) throw new Error(`terrain-${key}: HTTP ${response.status}`);
      const image = await createImageBitmap(await response.blob());
      const canvas = document.createElement('canvas');
      canvas.width = image.width; canvas.height = image.height;
      const ctx = canvas.getContext('2d', { willReadFrequently: true });
      if (!ctx) throw new Error('terrain canvas unavailable');
      ctx.drawImage(image, 0, 0);
      const rgb = ctx.getImageData(0, 0, image.width, image.height).data;
      const count = image.width * image.height;
      image.close();
      const heights = new Float32Array(count);
      for (let i = 0; i < heights.length; i++) heights[i] = rgb[i * 4] * 256 + rgb[i * 4 + 1] + rgb[i * 4 + 2] / 256 - 32768;
      return heights;
    })();
    decodedTerrain.set(key, current);
    current.catch(() => decodedTerrain.delete(key));
  }
  return current;
}
function sampleHeight(source: Float32Array, u: number, v: number): number {
  const px = Math.min(255, Math.max(0, u * 255));
  const py = Math.min(255, Math.max(0, v * 255));
  const x = Math.floor(px), y = Math.floor(py), tx = px - x, ty = py - y;
  const x2 = Math.min(255, x + 1), y2 = Math.min(255, y + 1);
  const top = source[y * 256 + x] * (1 - tx) + source[y * 256 + x2] * tx;
  const bottom = source[y2 * 256 + x] * (1 - tx) + source[y2 * 256 + x2] * tx;
  return top * (1 - ty) + bottom * ty;
}
function makeTerrain(onError?: MapStageProps['onAssetError']): Cesium.TerrainProvider {
  return new Cesium.CustomHeightmapTerrainProvider({
    width: 256, height: 256,
    tilingScheme: new Cesium.WebMercatorTilingScheme(),
    callback: async (x, y, level) => {
      // Terrain detail is capped at packaged zoom 8. Higher camera levels resample
      // that source tile; they do not invent additional elevation detail.
      let sourceLevel = Math.min(level, 12);
      while (sourceLevel > 0) {
        const div = 2 ** (level - sourceLevel);
        if (terrainTiles.has(`${sourceLevel}/${Math.floor(x / div)}/${Math.floor(y / div)}`)) break;
        sourceLevel--;
      }
      const divisor = 2 ** (level - sourceLevel);
      const sx = Math.floor(x / divisor), sy = Math.floor(y / divisor);
      const key = `terrain-${sourceLevel}-${sx}-${sy}`;
      try {
        const heights = await terrainTile(sourceLevel, sx, sy);
        if (divisor === 1) return heights;
        const tile = new Float32Array(256 * 256);
        const ox = x % divisor, oy = y % divisor;
        for (let row = 0; row < 256; row++) for (let col = 0; col < 256; col++) {
          tile[row * 256 + col] = sampleHeight(heights, (ox + col / 255) / divisor, (oy + row / 255) / divisor);
        }
        return tile;
      } catch (error) {
        onError?.(key, String(error));
        // Preserve an operable scene on a single failed tile. Retry clears cache.
        return new Float32Array(256 * 256);
      }
    },
  });
}
function makeImagery(): Cesium.UrlTemplateImageryProvider {
  return new Cesium.UrlTemplateImageryProvider({
    url: `${ASSET_ROOT}/imagery/{z}/{x}/{y}.jpg`,
    rectangle: RECTANGLE,
    maximumLevel: 9,
    credit: 'EOxCloudless © EOX IT Services GmbH · Contains modified Copernicus Sentinel data 2016 · CC BY 4.0',
  });
}

const detailTiles = new Set(tileIndex.imagery);
let transparentTile: HTMLCanvasElement | null = null;
function blankTile(): HTMLCanvasElement {
  if (!transparentTile) { transparentTile = document.createElement('canvas'); transparentTile.width = 256; transparentTile.height = 256; }
  return transparentTile;
}
class SparseDetailImageryProvider extends Cesium.UrlTemplateImageryProvider {
  requestImage(x: number, y: number, level: number, request?: Cesium.Request): Promise<HTMLImageElement | HTMLCanvasElement | ImageBitmap> | undefined {
    if (!detailTiles.has(`${level}/${x}/${y}`)) return Promise.resolve(blankTile());
    return super.requestImage(x, y, level, request);
  }
}
function makeDetailImagery(): SparseDetailImageryProvider {
  return new SparseDetailImageryProvider({
    url: `${ASSET_ROOT}/imagery/{z}/{x}/{y}.jpg`, rectangle: RECTANGLE,
    maximumLevel: 14, hasAlphaChannel: true,
    credit: 'EOxCloudless © EOX IT Services GmbH · Contains modified Copernicus Sentinel data 2016 · CC BY 4.0',
  });
}

export const MapStage = forwardRef<MapStageHandle, MapStageProps>(function MapStage(props, ref) {
  const mount = useRef<HTMLDivElement>(null);
  const viewer = useRef<Cesium.Viewer | null>(null);
  const data = useRef<Cesium.CustomDataSource | null>(null);
  const onSelect = useRef(props.onSelect);
  const onError = useRef(props.onAssetError);
  const [fatal, setFatal] = useState<string | null>(null);
  const [ready, setReady] = useState(false);
  const [tileError, setTileError] = useState<string | null>(null);
  onSelect.current = props.onSelect;
  onError.current = props.onAssetError;

  useEffect(() => {
    if (!mount.current) return;
    let disposed = false;
    let scene: Cesium.Viewer;
    try {
      const baseLayer = new Cesium.ImageryLayer(makeImagery());
      scene = new Cesium.Viewer(mount.current, {
        baseLayer, terrainProvider: makeTerrain((id, message) => onError.current?.(id, message)),
        animation: false, timeline: false, geocoder: false, homeButton: false,
        sceneModePicker: false, baseLayerPicker: false, navigationHelpButton: false,
        fullscreenButton: false, infoBox: false, selectionIndicator: false,
        requestRenderMode: false,
      });
      viewer.current = scene;
      scene.imageryLayers.addImageryProvider(makeDetailImagery());
      baseLayer.imageryProvider.errorEvent.addEventListener((error: Cesium.TileProviderError) => {
        const id = `imagery-${error.level}-${error.x}-${error.y}`;
        setTileError(id);
        onError.current?.(id, error.message);
      });
      let sawTile = false;
      const removeProgress = scene.scene.globe.tileLoadProgressEvent.addEventListener((pending: number) => {
        if (pending > 0) sawTile = true;
        if (sawTile && pending === 0 && scene.scene.globe.tilesLoaded && !disposed) {
          setReady(true);
          props.onReady?.();
          removeProgress();
        }
      });
      scene.scene.globe.depthTestAgainstTerrain = false;
      scene.scene.globe.maximumScreenSpaceError = 3;
      scene.scene.fog.enabled = true;
      scene.camera.setView({ destination: Cesium.Rectangle.fromDegrees(89.4, 30.4, 102.4, 38.4) });
      const source = new Cesium.CustomDataSource('pov-geography');
      source.clustering.enabled = true;
      source.clustering.pixelRange = 48;
      source.clustering.minimumClusterSize = 3;
      scene.dataSources.add(source);
      data.current = source;
      const click = new Cesium.ScreenSpaceEventHandler(scene.scene.canvas);
      click.setInputAction((movement: Cesium.ScreenSpaceEventHandler.PositionedEvent) => {
        scene.camera.cancelFlight();
        const hit = scene.scene.pick(movement.position) as { id?: Cesium.Entity } | undefined;
        const raw = hit?.id?.properties?.objectRef?.getValue(Cesium.JulianDate.now()) as ObjectRef | undefined;
        if (raw) onSelect.current?.(raw);
      }, Cesium.ScreenSpaceEventType.LEFT_CLICK);
      const cancelOnDrag = new Cesium.ScreenSpaceEventHandler(scene.scene.canvas);
      cancelOnDrag.setInputAction(() => scene.camera.cancelFlight(), Cesium.ScreenSpaceEventType.LEFT_DOWN);
      return () => { disposed = true; removeProgress(); click.destroy(); cancelOnDrag.destroy(); scene.destroy(); viewer.current = null; data.current = null; };
    } catch (error) {
      setFatal(String(error));
      onError.current?.('cesium-stage', String(error));
    }
  }, []);

  useEffect(() => {
    const source = data.current;
    if (!source) return;
    source.entities.removeAll();
    const layers = { corridors: true, fields: true, facilities: true, points: false, devices: false, ...props.layers };
    const selectedKey = props.selected ? `${props.selected.kind}:${props.selected.id}` : '';
    const allowed = props.visibleFacilityIds ? new Set(props.visibleFacilityIds) : null;
    if (layers.corridors) for (const corridor of props.catalog.corridors) {
      const color = COLORS[corridor.id as 'qingzang' | 'qingkang'] ?? COLORS.qingzang;
      source.entities.add({
        id: `corridor:${corridor.id}`,
        name: corridor.name,
        properties: { objectRef: { kind: 'corridor', id: corridor.id } },
        polyline: { positions: corridor.route.map(p => position(p)), width: selectedKey === `corridor:${corridor.id}` ? 7 : 4,
          material: new Cesium.PolylineGlowMaterialProperty({ glowPower: .18, color }), clampToGround: true },
      });
    }
    if (layers.fields) for (const field of props.catalog.fields) {
      const color = COLORS[field.category];
      polygonPositions(field.geometry).forEach((ring, index) => source.entities.add({
        id: `field:${field.id}:${index}`, name: field.name,
        properties: { objectRef: { kind: 'field', id: field.id } },
        polygon: { hierarchy: new Cesium.PolygonHierarchy(ring), material: color.withAlpha(selectedKey === `field:${field.id}` ? .29 : .14),
          outline: false },
      }));
      polygonPositions(field.geometry).forEach((ring, index) => source.entities.add({
        id: `field-boundary:${field.id}:${index}`, name: field.name,
        properties: { objectRef: { kind: 'field', id: field.id } },
        polyline: { positions: [...ring, ring[0]], width: selectedKey === `field:${field.id}` ? 4 : 2, material: color, clampToGround: true },
      }));
    }
    source.clustering.enabled = layers.facilities;
    if (layers.facilities) for (const facility of props.catalog.facilities) {
      if (allowed && !allowed.has(facility.id)) continue;
      const selected = selectedKey === `facility:${facility.id}`;
      source.entities.add({ id: `facility:${facility.id}`, name: facility.name,
        properties: { objectRef: { kind: 'facility', id: facility.id } },
        position: position(facility.position),
        point: { pixelSize: selected ? 15 : 9, color: selected ? COLORS.materials : COLORS.climate,
          outlineColor: Cesium.Color.WHITE, outlineWidth: selected ? 3 : 1,
          heightReference: Cesium.HeightReference.CLAMP_TO_GROUND, disableDepthTestDistance: 1e7 },
        label: selected ? { text: facility.name, font: '600 22px sans-serif', fillColor: Cesium.Color.WHITE,
          showBackground: true, backgroundColor: Cesium.Color.fromCssColorString('#082137').withAlpha(.86),
          pixelOffset: new Cesium.Cartesian2(0, -35), heightReference: Cesium.HeightReference.CLAMP_TO_GROUND,
          disableDepthTestDistance: 1e7 } : undefined,
      });
    }
    // Fine scale point/device markers are drawn only for the selected facility;
    // this keeps the terrain readable even for the full sample catalog.
    const selectedFacility = props.selected?.kind === 'facility' ? props.selected.id :
      props.selected?.kind === 'point' ? props.catalog.points.find(p => p.id === props.selected?.id)?.facilityId : undefined;
    if (selectedFacility && layers.points) for (const point of props.catalog.points.filter(p => p.facilityId === selectedFacility)) {
      source.entities.add({ id: `point:${point.id}`, name: point.name, properties: { objectRef: { kind: 'point', id: point.id } },
        position: position(point.position), point: { pixelSize: 7, color: COLORS.materials, outlineColor: Cesium.Color.WHITE, outlineWidth: 1,
          heightReference: Cesium.HeightReference.CLAMP_TO_GROUND } });
    }
    if (selectedFacility && layers.devices) for (const device of props.catalog.devices.filter(d => d.facilityId === selectedFacility)) {
      const point = props.catalog.points.find(p => p.deviceId === device.id);
      if (!point) continue;
      source.entities.add({ id: `device:${device.id}`, name: device.name, properties: { objectRef: { kind: 'device', id: device.id } },
        position: position(point.position), point: { pixelSize: 11, color: COLORS.engineering, outlineColor: Cesium.Color.WHITE, outlineWidth: 2,
          heightReference: Cesium.HeightReference.CLAMP_TO_GROUND } });
    }
  }, [props.catalog, props.layers, props.selected, props.visibleFacilityIds]);

  useImperativeHandle(ref, () => ({
    focusOverview(duration = 1.8) {
      viewer.current?.camera.flyTo({ destination: Cesium.Rectangle.fromDegrees(89.4, 30.4, 102.4, 38.4), duration });
    },
    focusCorridor(id, duration = 2.3) {
      const target = props.catalog.corridors.find(c => c.id === id);
      if (target) viewer.current?.camera.flyTo({ destination: bounds(target.route), duration });
    },
    focusField(id, duration = 1.4) {
      const target = props.catalog.fields.find(f => f.id === id);
      if (!target) return;
      const positions = polygonPositions(target.geometry).flat().map(p => Cesium.Cartographic.fromCartesian(p));
      viewer.current?.camera.flyTo({ destination: Cesium.Rectangle.fromCartographicArray(positions), duration });
    },
    focusFacility(id, duration = 1.5) {
      const target = props.catalog.facilities.find(f => f.id === id);
      if (target) viewer.current?.camera.flyTo({ destination: position(target.position, 42000),
        orientation: { heading: Cesium.Math.toRadians(target.heading), pitch: Cesium.Math.toRadians(-58), roll: 0 }, duration });
    },
    cancelFlight() { viewer.current?.camera.cancelFlight(); },
    retryAssets() {
      const scene = viewer.current;
      if (!scene) return;
      decodedTerrain.clear();
      setTileError(null);
      setReady(false);
      scene.scene.terrainProvider = makeTerrain((id, message) => onError.current?.(id, message));
      scene.imageryLayers.removeAll();
      scene.imageryLayers.addImageryProvider(makeImagery());
      scene.imageryLayers.addImageryProvider(makeDetailImagery());
      scene.scene.requestRender();
    },
    getCamera() {
      const camera = viewer.current?.camera;
      return camera ? { destination: camera.positionWC.clone(), heading: camera.heading, pitch: camera.pitch, roll: camera.roll } : null;
    },
    restoreCamera(camera, duration = 0) {
      viewer.current?.camera.flyTo({ destination: camera.destination, orientation: { heading: camera.heading, pitch: camera.pitch, roll: camera.roll }, duration });
    },
  }), [props.catalog]);

  return <div className={`pov-map-stage ${props.className ?? ''}`}>
    <div ref={mount} className="pov-map-stage__canvas" aria-label="青藏高原三维地理场景" />
    {!ready && !fatal && <div className="pov-map-stage__loading" role="status">卫星影像与地形加载中…</div>}
    {tileError && <div className="pov-map-stage__error" role="alert">地理资产 {tileError} 加载失败。可重试资源。</div>}
    {fatal && <div className="pov-map-stage__error" role="alert">地理场景暂不可用：{fatal}</div>}
  </div>;
});

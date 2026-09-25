/** Local engineering coordinates are metres: X follows the road, Y is up, Z is lateral. */
export type ModelTemplateId =
  | 'station' | 'ventilated-subgrade' | 'rockfill-subgrade' | 'pavement'
  | 'bridge' | 'box-culvert' | 'pipe-culvert' | 'weather-station';
export type ModelMode = 'exterior' | 'section' | 'points';
export type CameraPreset = 'recommended' | 'overall' | 'section' | 'inspection';
export type Vec3 = readonly [number, number, number];

export interface ModelPart {
  semanticId: string;
  label: string;
  shape: 'box' | 'cylinder' | 'sphere' | 'cone' | 'tube';
  position: Vec3;
  size: Vec3;
  color: string;
  material?: 'concrete' | 'steel' | 'earth' | 'asphalt' | 'glass' | 'sensor' | 'snow';
  parentId?: string;
  /** Movement in section mode. Children and anchors follow this transform. */
  sectionOffset?: Vec3;
  /** Hidden in section mode to expose internal construction. */
  sectionHidden?: boolean;
  /** Selectable parts appear in the component tree and support raycast selection. */
  selectable?: boolean;
  rotation?: Vec3;
}

export interface ModelAnchor {
  componentId: string;
  localPosition: Vec3;
  localNormal?: Vec3;
  /** Stable binding key matched to ObservationPoint.modelAnchor. */
  anchorId: string;
  label: string;
  metricHint: string;
}

export interface EngineeringTemplate {
  id: ModelTemplateId;
  version: 'pov-model-v1';
  title: string;
  sizeMetres: Vec3;
  parts: readonly ModelPart[];
  anchors: readonly ModelAnchor[];
  cameras: Record<CameraPreset, { position: Vec3; target: Vec3 }>;
  background: string;
}

export interface BoundModelAnchor extends ModelAnchor {
  facilityId: string;
  pointId: string;
  modelAssetVersion: EngineeringTemplate['version'];
  /** Derived presentation position; never written back to geographic coordinates. */
  displayedPosition: Vec3;
}

export type Position = { longitude: number; latitude: number; height?: number };
export type ObjectKind = 'station' | 'corridor' | 'field' | 'facility' | 'component' | 'borehole' | 'point' | 'device';
export type ObjectRef = { kind: ObjectKind; id: string };
export type Specialty = 'subgrade' | 'pavement' | 'bridge' | 'culvert' | 'weather';
export type ModelTemplate = 'station' | 'ventilated-subgrade' | 'rockfill-subgrade' | 'pavement' | 'bridge' | 'box-culvert' | 'pipe-culvert' | 'weather-station';
export type MetricId =
  | 'ground_temperature' | 'volumetric_water_content' | 'lateral_displacement' | 'layer_deformation' | 'ventilation_speed'
  | 'pavement_temperature' | 'pavement_moisture' | 'vertical_compressive_strain' | 'axle_load' | 'cumulative_deformation'
  | 'horizontal_tensile_strain' | 'asphalt_bottom_tensile_strain' | 'heat_flux'
  | 'pile_temperature' | 'pile_side_temperature' | 'foundation_strain' | 'pier_displacement'
  | 'soil_temperature' | 'soil_water_content' | 'earth_pressure' | 'culvert_strain' | 'settlement'
  | 'air_temperature' | 'relative_humidity' | 'wind_speed' | 'wind_direction' | 'air_pressure' | 'rainfall'
  | 'uv_radiation' | 'net_radiation' | 'shortwave_radiation';
export type Quality = 'valid' | 'missing';
export type SourceKind = 'public-geography' | 'simulated-layout' | 'engineering-sample';

export interface Station { id: string; name: string; position: Position; modelTemplate: ModelTemplate; sourceKind: SourceKind; description: string }
export interface Corridor { id: string; name: string; start: string; end: string; route: Position[]; bounds: [number, number, number, number]; sourceVersion: string }
export type FieldGeometry = { type: 'Polygon'; coordinates: number[][][] } | { type: 'MultiPolygon'; coordinates: number[][][][] };
export interface ObservationField { id: string; name: string; category: 'climate' | 'materials' | 'engineering'; corridorId: string; geometry: FieldGeometry; sourceKind: SourceKind; description: string }
export interface Facility { id: string; name: string; specialty: Specialty; corridorId: string; fieldIds: string[]; chainage: string; position: Position; heading: number; modelTemplate: ModelTemplate; sourceKind: SourceKind; componentIds: string[]; boreholeIds: string[]; pointIds: string[]; deviceIds: string[] }
export interface Component { id: string; facilityId: string; name: string; parentId?: string; modelPart: string; depthM?: number }
export interface Borehole { id: string; facilityId: string; componentId: string; name: string; depthM: number; modelPart: string }
export interface ObservationPoint { id: string; facilityId: string; componentId: string; boreholeId?: string; name: string; depthM?: number; modelAnchor: string; position: Position; deviceId: string; metricId: MetricId; seriesId: string }
export interface Device { id: string; facilityId: string; componentId: string; name: string; type: string; modelAnchor: string; channelIds: string[] }
export interface Channel { id: string; deviceId: string; pointId: string; metricId: MetricId; seriesId: string; samplePeriodMs: number }
export interface Metric { id: MetricId; name: string; unit: string; precision: number; quantity: string; signConvention: string; aggregation: 'last' | 'sum' | 'circular'; chart: 'line' | 'bar' | 'profile' }
export interface Series { id: string; facilityId: string; pointId: string; deviceId: string; channelId: string; metricId: MetricId; samplePeriodMs: number; simulationVersion: 'sim-v1' }
export interface Asset { id: string; type: string; version: string; bounds?: [number, number, number, number]; source: string; license: string; bytes: number; resolution?: string; checksum: string; path: string }
export interface Sample { seriesId: string; timestamp: number; value: number | null; quality: Quality; revision: number; simulationVersion: 'sim-v1' }
export interface Catalog { station: Station; corridors: Corridor[]; fields: ObservationField[]; facilities: Facility[]; components: Component[]; boreholes: Borehole[]; points: ObservationPoint[]; devices: Device[]; channels: Channel[]; metrics: Metric[]; series: Series[] }
export interface CatalogStats { facilities: number; points: number; devices: number; series: number; bySpecialty: Record<Specialty, number> }

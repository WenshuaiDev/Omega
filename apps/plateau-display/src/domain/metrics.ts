import type { Metric, MetricId, Specialty } from './types';
const m = (id: MetricId, name: string, unit: string, precision: number, quantity: string, aggregation: Metric['aggregation'] = 'last', chart: Metric['chart'] = 'line'): Metric => ({ id, name, unit, precision, quantity, aggregation, chart, signConvention: '正值按指标名称方向；深度自地表向下为正' });
export const metrics: Metric[] = [
  m('ground_temperature','地温','℃',1,'温度'),m('volumetric_water_content','体积含水率','%',1,'含水率'),m('lateral_displacement','横向位移','mm',2,'位移'),m('layer_deformation','分层变形','mm',2,'变形'),m('ventilation_speed','通风板风速','m/s',1,'风速'),
  m('pavement_temperature','结构层温度','℃',1,'温度'),m('pavement_moisture','结构层含水率','%',1,'含水率'),m('vertical_compressive_strain','竖向压应变','με',0,'应变'),m('axle_load','轴载','kN',0,'荷载'),m('cumulative_deformation','累计变形','mm',2,'变形'),m('horizontal_tensile_strain','水平拉应变','με',0,'应变'),m('asphalt_bottom_tensile_strain','沥青层底横向拉应变','με',0,'应变'),m('heat_flux','热流密度','W/m²',1,'热流'),
  m('pile_temperature','桩身温度','℃',1,'温度'),m('pile_side_temperature','桩侧温度','℃',1,'温度'),m('foundation_strain','桩基应变','με',0,'应变'),m('pier_displacement','桥墩位移','mm',2,'位移'),
  m('soil_temperature','管周土温','℃',1,'温度'),m('soil_water_content','管周体积含水率','%',1,'含水率'),m('earth_pressure','土压力','kPa',1,'压力'),m('culvert_strain','应变','με',0,'应变'),m('settlement','变形沉降','mm',2,'沉降'),
  m('air_temperature','气温','℃',1,'温度'),m('relative_humidity','相对湿度','%',1,'湿度'),m('wind_speed','风速','m/s',1,'风速'),m('wind_direction','风向','°',0,'角度','circular'),m('air_pressure','气压','kPa',1,'压力'),m('rainfall','雨量','mm',2,'降雨','sum','bar'),m('uv_radiation','紫外辐射','W/m²',1,'辐射'),m('net_radiation','净全辐射','W/m²',1,'辐射'),m('shortwave_radiation','总短波辐射','W/m²',1,'辐射')
];
export const metricsBySpecialty: Record<Specialty, MetricId[]> = {
  subgrade: ['ground_temperature','volumetric_water_content','lateral_displacement','layer_deformation','ventilation_speed'],
  pavement: ['pavement_temperature','pavement_moisture','vertical_compressive_strain','axle_load','cumulative_deformation','horizontal_tensile_strain','asphalt_bottom_tensile_strain','heat_flux'],
  bridge: ['pile_temperature','pile_side_temperature','foundation_strain','pier_displacement'],
  culvert: ['soil_temperature','soil_water_content','earth_pressure','culvert_strain','settlement'],
  weather: ['air_temperature','relative_humidity','wind_speed','wind_direction','air_pressure','rainfall','uv_radiation','net_radiation','shortwave_radiation']
};
export const metricById = Object.fromEntries(metrics.map(metric => [metric.id, metric])) as Record<MetricId, Metric>;

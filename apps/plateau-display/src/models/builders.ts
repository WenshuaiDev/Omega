import type { CameraPreset, EngineeringTemplate, ModelAnchor, ModelPart, ModelTemplateId, Vec3 } from './types';

const part = (semanticId: string, label: string, shape: ModelPart['shape'], position: Vec3, size: Vec3, color: string, extras: Partial<ModelPart> = {}): ModelPart =>
  ({ semanticId, label, shape, position, size, color, selectable: true, ...extras });
const anchor = (anchorId: string, componentId: string, localPosition: Vec3, label: string, metricHint: string): ModelAnchor =>
  ({ anchorId, componentId, localPosition, label, metricHint });
const cameras = (overall: Vec3, section: Vec3, inspection: Vec3, target: Vec3 = [0, 0, 0]): EngineeringTemplate['cameras'] => ({
  recommended: { position: overall, target }, overall: { position: overall, target },
  section: { position: section, target }, inspection: { position: inspection, target },
});
const template = (id: ModelTemplateId, title: string, sizeMetres: Vec3, parts: ModelPart[], anchors: ModelAnchor[], views: EngineeringTemplate['cameras'], background = '#081c31'): EngineeringTemplate =>
  ({ id, version: 'pov-model-v1', title, sizeMetres, parts, anchors, cameras: views, background });

const station = template('station', '花石峡野外观测站 · 工程样例模型', [38, 13, 30], [
  part('terrain', '高原地坪', 'box', [0, -0.6, 0], [38, 1, 30], '#6b7266', { material: 'earth', selectable: false }),
  part('station-building', '观测站主体', 'box', [-5, 2.5, -2], [13, 5, 9], '#d4d9d8', { material: 'concrete' }),
  part('station-roof', '坡屋顶', 'box', [-5, 5.4, -2], [14.5, 1, 10], '#35617b', { material: 'steel', rotation: [0, 0, -0.1] }),
  part('entrance', '站区入口', 'box', [-5, 1.35, 2.65], [2.3, 2.7, 0.3], '#2c5667', { material: 'glass' }),
  part('window-west', '西侧观测窗', 'box', [-9, 3, 2.65], [2.2, 1.6, 0.25], '#63a9be', { material: 'glass' }),
  part('window-east', '东侧观测窗', 'box', [-1, 3, 2.65], [2.2, 1.6, 0.25], '#63a9be', { material: 'glass' }),
  part('solar-array', '太阳能阵列', 'box', [8, 2.1, -6], [8, 0.18, 4.5], '#1c577d', { material: 'glass', rotation: [-0.32, 0, 0] }),
  ...[-3, 0, 3].map((z, i) => part(`solar-stand-${i}`, '阵列支架', 'cylinder', [8, 0.9, -6 + z], [0.17, 1.8, 0.17], '#a5b4bc', { material: 'steel', selectable: false })),
  part('weather-mast', '气象观测塔', 'cylinder', [11, 5, 6], [0.25, 10, 0.25], '#cad7d8', { material: 'steel' }),
  part('wind-vane', '风向仪', 'box', [11, 10.3, 6], [2.3, 0.13, 0.18], '#4cd6da', { material: 'sensor', parentId: 'weather-mast' }),
  part('rain-gauge', '雨量筒', 'cylinder', [6, 1.25, 9], [0.8, 2.5, 0.8], '#e2ebe9', { material: 'steel' }),
  part('observation-pad', '观测场坪', 'box', [9, 0.05, 7], [13, 0.1, 11], '#b9b3a3', { material: 'concrete' }),
], [
  anchor('station-air', 'weather-mast', [11, 7.8, 6], '站区气温', 'air-temperature'),
  anchor('station-wind', 'wind-vane', [11, 10.3, 6], '站区风速', 'wind-speed'),
  anchor('station-rain', 'rain-gauge', [6, 2.5, 9], '站区雨量', 'rainfall'),
], cameras([44, 25, 40], [39, 15, 36], [20, 15, 20], [0, 2, 0]));

const ventilated = template('ventilated-subgrade', '通风板与热棒路基', [48, 13, 24], [
  part('foundation', '多年冻土基底', 'box', [0, -3.4, 0], [48, 6, 24], '#806f5d', { material: 'earth', sectionOffset: [0, -1.5, 0] }),
  part('fill', '路基填料', 'box', [0, 0.4, 0], [42, 2.2, 18], '#a39379', { material: 'earth', sectionOffset: [0, -0.5, 0] }),
  part('ventilation-layer', '通风板层', 'box', [0, 1.75, 0], [42, 0.5, 18], '#577786', { material: 'steel', sectionOffset: [0, 0.8, 0] }),
  part('road-cap', '路面封层', 'box', [0, 2.3, 0], [42, 0.42, 16], '#3a464b', { material: 'asphalt', sectionOffset: [0, 2.3, 0] }),
  ...[-15, -5, 5, 15].map((x, i) => part(`vent-${i}`, '通风板开口', 'box', [x, 1.8, 9.1], [3.5, 0.45, 0.35], '#283e4b', { material: 'steel', parentId: 'ventilation-layer' })),
  ...[-15, -5, 5, 15].map((x, i) => part(`thermosyphon-${i}`, '热棒', 'cylinder', [x, -0.1, -10], [0.38, 7.8, 0.38], '#b7ccd0', { material: 'steel' })),
  part('borehole-a', '地温孔 A', 'cylinder', [-8, -2.2, 4], [0.19, 8, 0.19], '#e0ad63', { material: 'sensor' }),
  part('borehole-b', '地温孔 B', 'cylinder', [10, -2.2, 4], [0.19, 8, 0.19], '#e0ad63', { material: 'sensor' }),
], [
  anchor('borehole-a-1m', 'borehole-a', [-8, 0, 4], 'A 孔 1 m 地温', 'ground-temperature'),
  anchor('borehole-a-3m', 'borehole-a', [-8, -2, 4], 'A 孔 3 m 地温', 'ground-temperature'),
  anchor('borehole-a-5m', 'borehole-a', [-8, -4, 4], 'A 孔 5 m 地温', 'ground-temperature'),
  anchor('vent-wind', 'ventilation-layer', [0, 1.75, 9], '通风板风速', 'ventilation-wind-speed'),
], cameras([52, 26, 39], [53, 14, 24], [18, 7, 21], [0, 0, 0]));

const rockfill = template('rockfill-subgrade', '块石路基与冻土观测', [45, 13, 23], [
  part('permafrost', '冻土层', 'box', [0, -3.7, 0], [45, 5.6, 23], '#817565', { material: 'earth', sectionOffset: [0, -1.8, 0] }),
  part('gravel-core', '块石填筑核心', 'box', [0, -0.1, 0], [40, 2.9, 17], '#8b8c83', { material: 'earth', sectionOffset: [0, -0.5, 0] }),
  ...Array.from({ length: 18 }, (_, i) => part(`stone-${i}`, '块石', 'box', [-18 + (i % 9) * 4.5, 0.15 + Math.floor(i / 9) * 0.85, i % 2 ? 8.1 : -8.1], [2.5 + i % 3, 1.2, 1.8], i % 2 ? '#a7a69a' : '#737c77', { material: 'earth', parentId: 'gravel-core' })),
  part('geotextile', '土工布隔离层', 'box', [0, 1.55, 0], [41, 0.15, 18], '#c4c6bd', { sectionOffset: [0, 1.2, 0] }),
  part('road-surface', '路面', 'box', [0, 1.9, 0], [41, 0.45, 17], '#414b50', { material: 'asphalt', sectionOffset: [0, 2.5, 0] }),
  part('borehole-central', '中心地温孔', 'cylinder', [0, -2.3, 0], [0.22, 8, 0.22], '#e6bf73', { material: 'sensor' }),
  part('displacement-marker', '路肩位移标', 'cylinder', [11, 2.65, 9], [0.35, 1.4, 0.35], '#4cd6da', { material: 'sensor' }),
], [
  anchor('rock-temperature-1m', 'borehole-central', [0, 0, 0], '中心孔 1 m 地温', 'ground-temperature'),
  anchor('rock-temperature-3m', 'borehole-central', [0, -2, 0], '中心孔 3 m 地温', 'ground-temperature'),
  anchor('rock-temperature-5m', 'borehole-central', [0, -4, 0], '中心孔 5 m 地温', 'ground-temperature'),
  anchor('rock-displacement', 'displacement-marker', [11, 3.35, 9], '路肩横向位移', 'lateral-displacement'),
], cameras([48, 23, 36], [49, 14, 21], [18, 9, 20]));

const pavement = template('pavement', '层状路面与轴载观测', [46, 10, 21], [
  part('subsoil', '路床', 'box', [0, -3, 0], [46, 4.5, 21], '#8a796a', { material: 'earth', sectionOffset: [0, -1.5, 0] }),
  part('subbase', '底基层', 'box', [0, -0.45, 0], [44, 0.75, 19], '#b0a68d', { sectionOffset: [0, -0.6, 0] }),
  part('base', '基层', 'box', [0, 0.25, 0], [44, 0.65, 19], '#9ca5a1', { material: 'concrete', sectionOffset: [0, 0.5, 0] }),
  part('binder', '沥青下面层', 'box', [0, 0.75, 0], [44, 0.25, 19], '#4d5c5d', { material: 'asphalt', sectionOffset: [0, 1.4, 0] }),
  part('wearing', '沥青表层', 'box', [0, 1.02, 0], [44, 0.25, 19], '#28383f', { material: 'asphalt', sectionOffset: [0, 2.3, 0] }),
  ...[-7, 7].map((z, i) => part(`lane-mark-${i}`, '车道标线', 'box', [0, 1.16, z], [38, 0.02, 0.18], '#d5d6c7', { parentId: 'wearing', selectable: false })),
  part('axle-pad', '动态称重传感器', 'box', [2, 1.17, 0], [0.9, 0.1, 15], '#42becd', { material: 'sensor', parentId: 'wearing' }),
  part('strain-gauge', '层底应变计', 'box', [8, 0.57, 4], [1.1, 0.1, 0.5], '#d9b66f', { material: 'sensor', parentId: 'binder' }),
  part('heat-flux', '热流计', 'cylinder', [-10, 0.5, 4], [0.7, 0.15, 0.7], '#d9b66f', { material: 'sensor', parentId: 'base' }),
], [
  anchor('axle-load', 'axle-pad', [2, 1.2, 0], '过车轴载', 'axle-load'),
  anchor('base-temperature', 'base', [-6, 0.25, 3], '基层温度', 'pavement-temperature'),
  anchor('binder-strain', 'strain-gauge', [8, 0.62, 4], '沥青层底应变', 'vertical-strain'),
  anchor('heat-flux', 'heat-flux', [-10, 0.58, 4], '路面热流', 'heat-flux'),
], cameras([44, 21, 39], [42, 12, 23], [17, 6, 19]));

const bridge = template('bridge', '桥面、桥墩与桩基础', [65, 31, 27], [
  part('terrain', '河谷地表', 'box', [0, -10, 0], [65, 1, 27], '#726f64', { material: 'earth', selectable: false, sectionOffset: [0, -2, 0] }),
  part('deck', '桥面板', 'box', [0, 12, 0], [64, 1.5, 16], '#bec9cb', { material: 'concrete', sectionOffset: [0, 3.2, 0] }),
  ...[-7, 7].map((z, i) => part(`girder-${i}`, '主梁', 'box', [0, 10.2, z], [62, 2, 2.2], '#899ea8', { material: 'steel', parentId: 'deck' })),
  ...[-18, 0, 18].flatMap((x, i) => [
    part(`pier-${i}`, `桥墩 ${i + 1}`, 'cylinder', [x, 0.5, 0], [3.5, 19, 3.5], '#c5ced0', { material: 'concrete' }),
    part(`pile-${i}-a`, `桩基 ${i + 1}A`, 'cylinder', [x, -9, -3], [1.7, 14, 1.7], '#8fadb7', { material: 'concrete', parentId: `pier-${i}` }),
    part(`pile-${i}-b`, `桩基 ${i + 1}B`, 'cylinder', [x, -9, 3], [1.7, 14, 1.7], '#8fadb7', { material: 'concrete', parentId: `pier-${i}` }),
  ]),
  part('borehole-p1', '1 号墩测温孔', 'cylinder', [-18, -8, -3], [0.24, 13, 0.24], '#e8be70', { material: 'sensor', parentId: 'pile-0-a' }),
  ...[-7, 7].map((z, i) => part(`parapet-${i}`, '防撞护栏', 'box', [0, 13.2, z], [64, 1.1, 0.5], '#d6ddda', { material: 'concrete', parentId: 'deck' })),
], [
  anchor('pile-temp-1m', 'borehole-p1', [-18, -2, -3], '1 号孔 1 m 桩温', 'pile-temperature'),
  anchor('pile-temp-5m', 'borehole-p1', [-18, -6, -3], '1 号孔 5 m 桩温', 'pile-temperature'),
  anchor('pile-temp-10m', 'borehole-p1', [-18, -11, -3], '1 号孔 10 m 桩温', 'pile-temperature'),
  anchor('pile-strain', 'pile-0-a', [-18, -9, -2], '1 号桩基应变', 'pile-strain'),
  anchor('pier-displacement', 'pier-1', [0, 8, 2], '桥墩位移', 'pier-displacement'),
], cameras([68, 34, 55], [67, 18, 36], [29, 18, 30], [0, 1, 0]));

const boxCulvert = template('box-culvert', '箱涵与围土剖面', [32, 15, 26], [
  part('surrounding-soil', '涵周围土', 'box', [0, -0.4, 0], [32, 13, 26], '#847969', { material: 'earth', sectionHidden: true }),
  part('foundation', '涵洞基础', 'box', [0, -5.8, 0], [27, 1.2, 20], '#b3bab5', { material: 'concrete' }),
  part('bottom-slab', '底板', 'box', [0, -4.5, 0], [26, 1.1, 16], '#c9d2cd', { material: 'concrete' }),
  part('top-slab', '顶板', 'box', [0, 3.4, 0], [26, 1.1, 16], '#c9d2cd', { material: 'concrete', sectionOffset: [0, 2.8, 0] }),
  ...[-7.3, 7.3].map((z, i) => part(`wall-${i}`, '侧墙', 'box', [0, -0.55, z], [26, 7.5, 1.1], '#b7c5c6', { material: 'concrete', sectionOffset: [0, 0, z < 0 ? -2 : 2] })),
  part('water-channel', '涵内水槽', 'box', [0, -3.9, 0], [25, 0.15, 8], '#2f7892', { material: 'glass' }),
  ...[-10, 0, 10].map((x, i) => part(`soil-probe-${i}`, '围土探针', 'cylinder', [x, 0.2, 9.5], [0.2, 7, 0.2], '#e0b975', { material: 'sensor' })),
], [
  anchor('box-soil-temperature', 'soil-probe-0', [-10, 0, 9.5], '箱涵围土温度', 'soil-temperature'),
  anchor('box-moisture', 'soil-probe-1', [0, -2, 9.5], '箱涵围土含水率', 'soil-moisture'),
  anchor('box-pressure', 'wall-1', [4, 0, 7.9], '侧墙土压力', 'soil-pressure'),
  anchor('box-settlement', 'top-slab', [0, 4, 0], '顶板沉降', 'settlement'),
], cameras([35, 21, 35], [34, 15, 29], [19, 10, 20]));

const pipeCulvert = template('pipe-culvert', '圆管涵与环向观测', [32, 15, 25], [
  part('surrounding-soil', '涵周围土', 'box', [0, -0.3, 0], [32, 13, 25], '#847969', { material: 'earth', sectionHidden: true }),
  part('pipe-shell', '预制管节', 'tube', [0, -1.2, 0], [5.8, 26, 4.1], '#b7c6c6', { material: 'concrete', rotation: [0, 0, Math.PI / 2] }),
  ...[-12, -4, 4, 12].map((x, i) => part(`joint-${i}`, '管节接缝', 'tube', [x, -1.2, 0], [6, 0.22, 4.1], '#d3dad2', { material: 'concrete', rotation: [0, 0, Math.PI / 2] })),
  part('bedding', '砂石垫层', 'box', [0, -6, 0], [29, 1.3, 16], '#b0a48e', { material: 'earth' }),
  part('crown-probe', '拱顶传感器', 'sphere', [0, 4.4, 0], [0.45, 0.45, 0.45], '#4cd6da', { material: 'sensor' }),
  part('springline-probe', '管侧传感器', 'sphere', [0, -1.2, 5.9], [0.45, 0.45, 0.45], '#d9b66f', { material: 'sensor' }),
], [
  anchor('pipe-crown-temp', 'crown-probe', [0, 4.4, 0], '管顶土温', 'soil-temperature'),
  anchor('pipe-side-moisture', 'springline-probe', [0, -1.2, 5.9], '管侧含水率', 'soil-moisture'),
  anchor('pipe-pressure', 'pipe-shell', [0, 2, 5.2], '管顶土压力', 'soil-pressure'),
  anchor('pipe-strain', 'pipe-shell', [0, -1.2, -5.8], '管节应变', 'culvert-strain'),
], cameras([35, 23, 33], [32, 15, 27], [18, 11, 19]));

const weather = template('weather-station', '综合气象站 · 工程样例模型', [28, 17, 25], [
  part('station-pad', '气象场坪', 'box', [0, -0.35, 0], [28, 0.7, 25], '#aaa994', { material: 'concrete' }),
  part('instrument-mast', '气象观测桅杆', 'cylinder', [0, 6.5, 0], [0.25, 13, 0.25], '#c9d5d4', { material: 'steel' }),
  part('anemometer', '风速仪', 'sphere', [0, 13.1, 0], [0.8, 0.8, 0.8], '#48c5cf', { material: 'sensor', parentId: 'instrument-mast' }),
  part('wind-vane', '风向仪', 'box', [0, 11.9, 0], [2.9, 0.12, 0.24], '#d8e7e5', { material: 'steel', parentId: 'instrument-mast' }),
  part('radiation-arm', '辐射仪横臂', 'box', [2, 8.9, 0], [4.1, 0.13, 0.13], '#a9bcc2', { material: 'steel', parentId: 'instrument-mast' }),
  part('radiometer', '总短波辐射表', 'sphere', [4, 9, 0], [0.5, 0.4, 0.5], '#6bcbeb', { material: 'sensor', parentId: 'radiation-arm' }),
  part('screen', '百叶箱', 'box', [-6, 2.2, 3], [2.8, 2.2, 2.4], '#e4ede7', { material: 'concrete' }),
  ...[-6.9, -5.1].map((x, i) => part(`screen-leg-${i}`, '百叶箱支架', 'cylinder', [x, 0.9, 3], [0.15, 1.8, 0.15], '#becaca', { material: 'steel', selectable: false })),
  part('rain-gauge', '翻斗雨量计', 'cylinder', [7, 1.6, 5], [1.1, 3.2, 1.1], '#e3e9e5', { material: 'steel' }),
  part('pressure-cabinet', '气压采集箱', 'box', [5, 1.5, -5], [2.2, 3, 1.6], '#d2ddd9', { material: 'steel' }),
  part('solar-panel', '供电板', 'box', [-7, 2, -6], [5, 0.14, 3], '#1b5b7c', { material: 'glass', rotation: [-0.35, 0, 0] }),
], [
  anchor('air-temperature', 'screen', [-6, 2.2, 3], '气温与湿度', 'air-temperature'),
  anchor('wind-speed', 'anemometer', [0, 13.1, 0], '风速', 'wind-speed'),
  anchor('wind-direction', 'wind-vane', [0, 11.9, 0], '风向', 'wind-direction'),
  anchor('rainfall', 'rain-gauge', [7, 3.2, 5], '雨量', 'rainfall'),
  anchor('shortwave', 'radiometer', [4, 9, 0], '总短波辐射', 'shortwave-radiation'),
  anchor('pressure', 'pressure-cabinet', [5, 2.6, -5], '气压', 'air-pressure'),
], cameras([33, 24, 35], [31, 16, 28], [15, 15, 19], [0, 5, 0]));

export const engineeringTemplates: Record<ModelTemplateId, EngineeringTemplate> = {
  station, 'ventilated-subgrade': ventilated, 'rockfill-subgrade': rockfill,
  pavement, bridge, 'box-culvert': boxCulvert, 'pipe-culvert': pipeCulvert,
  'weather-station': weather,
};

export const modelTemplateIds = Object.keys(engineeringTemplates) as ModelTemplateId[];
export function getEngineeringTemplate(id: string): EngineeringTemplate | undefined {
  return Object.prototype.hasOwnProperty.call(engineeringTemplates, id)
    ? engineeringTemplates[id as ModelTemplateId] : undefined;
}

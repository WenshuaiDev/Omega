import { useCallback, useEffect, useMemo, useRef, useState } from 'react';
import type { Catalog, MetricId, ObjectRef, ObservationPoint, Specialty } from '../domain/types';
import type { SimulationClient } from '../runtime/client';
import type { ProfileResult, RuntimeState, SeriesResult, SnapshotResult, StatisticsResult } from '../runtime/simulation';
import { MAX_HISTORY_MS, START_TIME } from '../runtime/simulation';
import { metricById, metricsBySpecialty } from '../domain/metrics';
import { EChart } from './EChart';
import { chartColors, formatSimulationTime, profileChartOption, timeChartOption } from './chart-options';
import './charts.css';

export interface DataPanelsProps {
  catalog: Catalog;
  client: SimulationClient;
  selectedObject?: ObjectRef | null;
  onSelectObject?: (object: ObjectRef) => void;
  specialty?: Specialty;
}
type TimeMode = 'follow' | 'history';
const windows = [{ label: '最近 15 分', duration: 15 * 60000 }, { label: '最近 1 小时', duration: 3600000 }, { label: '最近 24 小时', duration: 86400000 }, { label: '最近 7 天', duration: 7 * 86400000 }];
const cardinal = (angle: number) => ['北','东北','东','东南','南','西南','西','西北'][Math.round((((angle % 360) + 360) % 360) / 45) % 8];
const bjtInput = (time: number) => new Date(time + 8 * 3600000).toISOString().slice(0, 16);
const fromBjtInput = (value: string) => Date.parse(`${value}:00+08:00`);
const defaultClock: RuntimeState = { timestamp: START_TIME, revision: 0, speed: 1, paused: false, seed: 20260925 };

function resolveFacility(catalog: Catalog, selected?: ObjectRef | null, specialty?: Specialty) {
  if (selected?.kind === 'facility') return catalog.facilities.find(item => item.id === selected.id);
  if (selected?.kind === 'point') return catalog.facilities.find(item => item.id === catalog.points.find(point => point.id === selected.id)?.facilityId);
  if (selected?.kind === 'device') return catalog.facilities.find(item => item.id === catalog.devices.find(device => device.id === selected.id)?.facilityId);
  if (selected?.kind === 'component') return catalog.facilities.find(item => item.id === catalog.components.find(component => component.id === selected.id)?.facilityId);
  if (selected?.kind === 'borehole') return catalog.facilities.find(item => item.id === catalog.boreholes.find(borehole => borehole.id === selected.id)?.facilityId);
  return catalog.facilities.find(item => item.specialty === specialty) ?? catalog.facilities[0];
}

export function DataPanels({ catalog, client, selectedObject, onSelectObject, specialty }: DataPanelsProps) {
  const facility = useMemo(() => resolveFacility(catalog, selectedObject, specialty), [catalog, selectedObject, specialty]);
  const facilityPoints = useMemo(() => catalog.points.filter(point => point.facilityId === facility?.id), [catalog, facility?.id]);
  const selectedPoint = selectedObject?.kind === 'point' ? facilityPoints.find(point => point.id === selectedObject.id) : undefined;
  const [metricId, setMetricId] = useState<MetricId>(() => selectedPoint?.metricId ?? metricsBySpecialty[facility?.specialty ?? 'subgrade'][0]);
  const [primaryId, setPrimaryId] = useState<string | null>(selectedPoint?.id ?? null);
  const [comparisonIds, setComparisonIds] = useState<string[]>([]);
  const [mode, setMode] = useState<TimeMode>('follow');
  const [duration, setDuration] = useState(3600000);
  const [range, setRange] = useState<{ from: number; to: number } | null>(null);
  const [clock, setClock] = useState<RuntimeState>(defaultClock);
  const [snapshot, setSnapshot] = useState<SnapshotResult | null>(null);
  const [series, setSeries] = useState<SeriesResult[]>([]);
  const [profile, setProfile] = useState<ProfileResult | null>(null);
  const [stats, setStats] = useState<StatisticsResult | null>(null);
  const [expanded, setExpanded] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const requestEpoch = useRef(0);
  const metric = metricById[metricId];
  const metricPoints = useMemo(() => facilityPoints.filter(point => point.metricId === metricId), [facilityPoints, metricId]);
  const primary = metricPoints.find(point => point.id === primaryId) ?? metricPoints[0];
  const compared = metricPoints.filter(point => comparisonIds.includes(point.id) && point.id !== primary?.id).slice(0, 5);
  const shown = primary ? [primary, ...compared] : [];
  const seriesIds = shown.map(point => point.seriesId);
  const seriesKey = seriesIds.join('|');
  const availableMetrics = metricsBySpecialty[facility?.specialty ?? 'subgrade'];

  useEffect(() => { setComparisonIds([]); setPrimaryId(null); setMetricId(metricsBySpecialty[facility?.specialty ?? 'subgrade'][0]); }, [facility?.id]);
  useEffect(() => {
    if (selectedPoint) { setMetricId(selectedPoint.metricId); setPrimaryId(selectedPoint.id); }
  }, [selectedPoint?.id]);
  useEffect(() => { setComparisonIds(metricPoints.filter(point => point.id !== primary?.id).slice(0, 2).map(point => point.id)); }, [facility?.id, metricId]);

  useEffect(() => {
    let active = true;
    if (!seriesIds.length) { setSnapshot(null); return; }
    client.snapshot(seriesIds).then(result => { if (active) { setSnapshot(result); setClock(previous => ({ ...previous, timestamp: result.timestamp, revision: result.revision })); } }).catch(err => { if (active) setError(String(err)); });
    client.subscribe(seriesIds, result => {
      if (!active) return;
      setSnapshot(result);
      setClock(previous => ({ ...previous, timestamp: result.timestamp, revision: result.revision }));
    }).then(unsubscribe => { if (!active) unsubscribe(); else cleanup = unsubscribe; }).catch(err => { if (active) setError(String(err)); });
    let cleanup: (() => void) | undefined;
    return () => { active = false; cleanup?.(); };
  }, [client, seriesKey]);

  const visibleRange = useMemo(() => mode === 'history' && range ? range : { from: clock.timestamp - duration, to: clock.timestamp }, [mode, range, clock.timestamp, duration]);
  useEffect(() => {
    if (!seriesIds.length || visibleRange.to < visibleRange.from) { setSeries([]); return; }
    const epoch = ++requestEpoch.current;
    const controller = new AbortController();
    const timer = window.setTimeout(() => {
      Promise.all(seriesIds.map(id => client.querySeries(id, visibleRange.from, visibleRange.to, expanded ? 2400 : 1200)))
        .then(results => { if (!controller.signal.aborted && epoch === requestEpoch.current) { setSeries(results); setError(null); } })
        .catch(err => { if (!controller.signal.aborted && epoch === requestEpoch.current) setError(String(err)); });
    }, mode === 'follow' ? 180 : 0);
    return () => { controller.abort(); clearTimeout(timer); };
  }, [client, seriesKey, visibleRange.from, visibleRange.to, expanded, mode]);

  const boreholeId = selectedObject?.kind === 'borehole' ? selectedObject.id : primary?.boreholeId;
  useEffect(() => {
    if (!boreholeId || !primary) { setProfile(null); return; }
    let active = true;
    client.profile(boreholeId, metricId, mode === 'history' ? visibleRange.to : clock.timestamp).then(result => { if (active) setProfile(result); }).catch(() => { if (active) setProfile(null); });
    return () => { active = false; };
  }, [client, boreholeId, metricId, clock.timestamp, mode, visibleRange.to, primary?.id]);
  useEffect(() => {
    let active = true;
    client.statistics().then(result => { if (active) setStats(result); }).catch(() => {});
    return () => { active = false; };
  }, [client, clock.timestamp]);

  const control = useCallback((change: Partial<Pick<RuntimeState, 'timestamp' | 'speed' | 'paused' | 'seed'>>) => {
    client.control(change).then(setClock).catch(err => setError(String(err)));
  }, [client]);
  const chooseMetric = (value: MetricId) => { setMetricId(value); setPrimaryId(null); };
  const choosePoint = (point: ObservationPoint) => { setPrimaryId(point.id); onSelectObject?.({ kind: 'point', id: point.id }); };
  const chartLines = series.filter(item => seriesIds.includes(item.seriesId) && item.metricId === metricId).map(item => ({ id: item.seriesId, name: facilityPoints.find(point => point.seriesId === item.seriesId)?.name ?? item.seriesId, samples: item.samples, dailyCumulative: item.dailyCumulative, aggregationMs: item.aggregationMs }));
  const chartOption = useMemo(() => timeChartOption(metric, chartLines, mode === 'history' ? undefined : snapshot?.timestamp), [metric, series, mode, snapshot?.timestamp]);
  const profilePoints = profile?.metricId === metricId && profile.boreholeId === boreholeId ? profile.points.map(item => ({ pointId: item.pointId, name: catalog.points.find(point => point.id === item.pointId)?.name ?? item.pointId, depthM: item.depthM, value: item.sample.quality === 'missing' ? null : item.sample.value })) : [];
  const currentSample = snapshot?.samples.find(sample => sample.seriesId === primary?.seriesId);
  const latestSample = mode === 'history' ? series.find(item => item.seriesId === primary?.seriesId)?.samples.at(-1) : currentSample;
  const selectSeries = useCallback((seriesId: string) => { const point = catalog.points.find(item => item.seriesId === seriesId.replace(/:daily$/, '')); if (point) choosePoint(point); }, [catalog, onSelectObject]);
  const selectPoint = useCallback((pointId: string) => { const point = catalog.points.find(item => item.id === pointId); if (point) choosePoint(point); }, [catalog, onSelectObject]);
  const setHistoricalRange = (edge: 'from' | 'to', value: string) => {
    const time = fromBjtInput(value);
    if (!Number.isFinite(time)) return;
    const proposed = { from: edge === 'from' ? time : range?.from ?? clock.timestamp - duration, to: edge === 'to' ? time : range?.to ?? clock.timestamp };
    if (proposed.from < clock.timestamp - MAX_HISTORY_MS || proposed.to > clock.timestamp || proposed.from >= proposed.to) { setError('历史范围须在最近 30 天内，且开始早于结束。'); return; }
    setError(null);
    setRange(proposed);
    setMode('history');
  };
  const seek = (time: number) => { control({ timestamp: time }); setMode('follow'); setRange(null); };

  if (!facility) return <section className="pov-data-panel" aria-label="观测数据">暂无样例设施</section>;
  const content = <>
    <header className="pov-data-header">
      <div><span className="pov-kicker">DATA OBSERVATORY</span><h2>{facility.name}</h2><p>{facility.chainage} · {primary?.name ?? '请选择测点'} · 模拟时间 {formatSimulationTime(clock.timestamp)}</p></div>
      <button type="button" className="pov-expand" onClick={() => setExpanded(value => !value)}>{expanded ? '恢复布局' : '放大图表'}</button>
    </header>
    <div className="pov-data-controls">
      <label>指标<select aria-label="选择指标" value={metricId} onChange={event => chooseMetric(event.target.value as MetricId)}>{availableMetrics.map(id => <option key={id} value={id}>{metricById[id].name} ({metricById[id].unit})</option>)}</select></label>
      <label>测点<select aria-label="选择测点" value={primary?.id ?? ''} onChange={event => { const point = metricPoints.find(item => item.id === event.target.value); if (point) choosePoint(point); }}>{metricPoints.map(point => <option key={point.id} value={point.id}>{point.name}{point.depthM != null ? ` · ${point.depthM} m` : ''}</option>)}</select></label>
      <label>时间窗口<select aria-label="时间窗口" value={duration} onChange={event => { setDuration(Number(event.target.value)); if (mode === 'history') setMode('follow'); }}>{windows.map(item => <option key={item.duration} value={item.duration}>{item.label}</option>)}</select></label>
      <button type="button" onClick={() => { setMode('follow'); setRange(null); }}>跟随当前</button>
    </div>
    <div className="pov-data-controls pov-time-controls">
      <label>从<input aria-label="历史开始时间" type="datetime-local" value={bjtInput(visibleRange.from)} min={bjtInput(clock.timestamp - MAX_HISTORY_MS)} max={bjtInput(clock.timestamp)} onChange={event => setHistoricalRange('from', event.target.value)} /></label>
      <label>到<input aria-label="历史结束时间" type="datetime-local" value={bjtInput(visibleRange.to)} min={bjtInput(clock.timestamp - MAX_HISTORY_MS)} max={bjtInput(clock.timestamp)} onChange={event => setHistoricalRange('to', event.target.value)} /></label>
      <label>回放速度<select aria-label="回放速度" value={clock.speed} onChange={event => control({ speed: Number(event.target.value) as 1 | 10 | 60 })}><option value={1}>1×</option><option value={10}>10×</option><option value={60}>60×</option></select></label>
      <button type="button" onClick={() => control({ paused: !clock.paused })}>{clock.paused ? '继续观测' : '暂停观测'}</button>
      <button type="button" onClick={() => client.reset().then(result => { setClock(result); setMode('follow'); setRange(null); }).catch(err => setError(String(err)))}>重置演示</button>
    </div>
    <div className="pov-timeline"><input aria-label="定位模拟时间" type="range" min={clock.timestamp - MAX_HISTORY_MS} max={clock.timestamp} value={Math.min(clock.timestamp, Math.max(clock.timestamp - MAX_HISTORY_MS, visibleRange.to))} onChange={event => seek(Number(event.target.value))} /><span>{mode === 'history' ? '历史窗口' : '实时跟随'} · {formatSimulationTime(visibleRange.to)}</span></div>
    {error && <p className="pov-data-error" role="alert">数据暂不可用：{error} <button type="button" onClick={() => { setError(null); setClock(previous => ({ ...previous })); }}>重试</button></p>}
    <div className="pov-data-body">
      <section className="pov-primary-reading"><span>当前指标</span><strong>{latestSample?.value == null ? '无样本' : latestSample.value.toFixed(metric.precision)} <small>{metric.unit}</small></strong><span>{metric.name}{metricId === 'wind_direction' && latestSample?.value != null ? ` · ${cardinal(latestSample.value)}` : ''} · {latestSample ? formatSimulationTime(latestSample.timestamp) : '查询中'}</span>{metricId === 'wind_direction' && latestSample?.value != null && <span className="pov-wind-rose" aria-label={`风向 ${cardinal(latestSample.value)}`} style={{ transform: `rotate(${latestSample.value}deg)` }}>↑</span>}</section>
      <section className="pov-chart-card"><h3>{metric.name}时序 <small>{metric.unit}{metricId === 'rainfall' ? ' · 分时柱 / 北京时间日累计线' : ''}</small></h3><EChart option={chartOption} onSeriesClick={selectSeries} /></section>
      <section className="pov-side-card"><h3>测点对比</h3><p>同一指标，默认 3 条，最多 6 条序列</p><div className="pov-compare-list">{metricPoints.filter(point => point.id !== primary?.id).slice(0, 24).map(point => { const colorIndex = compared.findIndex(item => item.id === point.id); return <label key={point.id}><input type="checkbox" checked={comparisonIds.includes(point.id)} onChange={event => setComparisonIds(previous => event.target.checked ? [...previous, point.id].slice(-5) : previous.filter(id => id !== point.id))} /><span style={{ color: colorIndex >= 0 ? chartColors[1 + colorIndex] : undefined }}>{point.name}{point.depthM != null ? ` · ${point.depthM} m` : ''}</span></label>; })}</div></section>
      {profilePoints.length > 0 && <section className="pov-profile-card"><h3>孔位深度剖面 <small>同一模拟时刻 · 深度向下</small></h3><EChart option={profileChartOption(metric, profilePoints)} onPointClick={selectPoint} /></section>}
      <section className="pov-stat-card"><h3>观测体系规模</h3><div><strong>{stats?.stats.facilities ?? '—'}</strong><span>设施</span><strong>{stats?.stats.points ?? '—'}</strong><span>测点</span><strong>{stats?.stats.devices ?? '—'}</strong><span>设备</span><strong>{stats?.totalSamples ? BigInt(stats.totalSamples).toLocaleString('zh-CN') : '—'}</strong><span>模拟累计样本</span></div></section>
    </div>
  </>;
  return <section className={`pov-data-panel ${expanded ? 'pov-data-expanded' : ''}`} aria-label="观测数据面板">{content}</section>;
}

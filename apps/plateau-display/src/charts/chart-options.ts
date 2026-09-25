import type { EChartsOption } from 'echarts';
import type { Metric, Sample } from '../domain/types';

export const chartColors = ['#53d9f7', '#ffcf72', '#9bde9a', '#c9a9ff', '#fb9c9c', '#a7b9ff'];
const axis = { axisLine: { lineStyle: { color: '#5c8396' } }, axisLabel: { color: '#d2e9f2', fontSize: 16 }, splitLine: { lineStyle: { color: '#36556666' } } };
const clock = (time: number) => new Intl.DateTimeFormat('zh-CN', { timeZone: 'Asia/Shanghai', month: '2-digit', day: '2-digit', hour: '2-digit', minute: '2-digit', second: '2-digit', hour12: false }).format(time);

export interface ChartLine { id: string; name: string; samples: Sample[]; dailyCumulative?: Sample[]; aggregationMs?: number }
export function timeChartOption(metric: Metric, lines: ChartLine[], cursor?: number): EChartsOption {
  return {
    animationDurationUpdate: 280,
    color: chartColors,
    grid: { left: 70, right: 24, top: 42, bottom: 58, containLabel: false },
    legend: { top: 2, textStyle: { color: '#e3f3f8', fontSize: 16 }, selectedMode: false },
    tooltip: { trigger: 'axis', confine: true, backgroundColor: '#102c3c', borderColor: '#68bed5', textStyle: { color: '#fff' }, formatter: (items: unknown) => {
      const rows = Array.isArray(items) ? items as Array<{ seriesName: string; value: [number, number | null] }> : [];
      return rows.length ? `${clock(rows[0].value[0])}<br/>${rows.map(row => `${row.seriesName}：${row.value[1] == null ? '无样本' : `${row.value[1].toFixed(metric.precision)} ${metric.unit}`}`).join('<br/>')}` : '';
    } },
    xAxis: { type: 'time', ...axis, axisLabel: { color: '#d2e9f2', fontSize: 16, formatter: (value: number) => clock(value).slice(6) } },
    yAxis: { type: 'value', name: metric.unit, nameTextStyle: { color: '#e3f3f8', fontSize: 16 }, ...axis },
    series: lines.map((line,index) => ({ id: line.id, name: line.name, type: metric.chart === 'bar' ? 'bar' : 'line', showSymbol: false, connectNulls: false, lineStyle: { width: 2.5, type: index < 4 ? 'solid' : 'dashed' }, data: line.samples.map(sample => [sample.timestamp, sample.quality === 'missing' ? null : sample.value]), markLine: cursor == null ? undefined : { silent: true, symbol: 'none', lineStyle: { color: '#ffffff88' }, data: [{ xAxis: cursor }] } })),
    ...(metric.id === 'rainfall' ? { series: lines.flatMap((line,index) => [
      { id: line.id, name: `${line.name} 分时`, type: 'bar', data: line.samples.map(sample => [sample.timestamp, sample.value]), itemStyle: { color: chartColors[index] } },
      { id: `${line.id}:daily`, name: `${line.name} 日累计`, type: 'line', smooth: false, showSymbol: false, lineStyle: { width: 2.5, type: index < 4 ? 'solid' : 'dashed', color: chartColors[index] }, data: line.dailyCumulative?.map(sample => [sample.timestamp, sample.value]) ?? [] }
    ]) } : {})
  };
}

export function profileChartOption(metric: Metric, points: Array<{ pointId: string; name: string; depthM: number; value: number | null }>): EChartsOption {
  return {
    color: [chartColors[0]],
    grid: { left: 80, right: 28, top: 28, bottom: 54 },
    tooltip: { trigger: 'item', formatter: (item: unknown) => { const row = item as { data: { name: string; value: [number, number] } }; return `${row.data.name}<br/>深度 ${row.data.value[1]} m<br/>${row.data.value[0].toFixed(metric.precision)} ${metric.unit}`; } },
    xAxis: { type: 'value', name: metric.unit, nameTextStyle: { color: '#e3f3f8' }, ...axis },
    yAxis: { type: 'value', name: '深度 m', inverse: true, min: 0, nameTextStyle: { color: '#e3f3f8' }, ...axis },
    series: [{ type: 'line', smooth: true, symbolSize: 11, data: points.filter(point => point.value != null).map(point => ({ name: point.name, value: [point.value, point.depthM], pointId: point.pointId })) }]
  };
}

export { clock as formatSimulationTime };

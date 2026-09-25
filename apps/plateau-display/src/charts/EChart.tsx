import { useEffect, useRef } from 'react';
import * as echarts from 'echarts/core';
import { LineChart, BarChart } from 'echarts/charts';
import { GridComponent, LegendComponent, MarkLineComponent, TooltipComponent } from 'echarts/components';
import { CanvasRenderer } from 'echarts/renderers';
import type { EChartsOption } from 'echarts';

echarts.use([LineChart, BarChart, GridComponent, LegendComponent, MarkLineComponent, TooltipComponent, CanvasRenderer]);

export function EChart({ option, onSeriesClick, onPointClick, className = '' }: { option: EChartsOption; onSeriesClick?: (id: string) => void; onPointClick?: (id: string) => void; className?: string }) {
  const element = useRef<HTMLDivElement>(null);
  const chart = useRef<echarts.ECharts | null>(null);
  useEffect(() => {
    if (!element.current) return;
    const instance = echarts.init(element.current, undefined, { renderer: 'canvas' });
    chart.current = instance;
    const observer = new ResizeObserver(() => instance.resize());
    observer.observe(element.current);
    return () => { observer.disconnect(); instance.dispose(); chart.current = null; };
  }, []);
  useEffect(() => { chart.current?.setOption(option, { notMerge: true }); }, [option]);
  useEffect(() => {
    const instance = chart.current;
    if (!instance) return;
    const listener = (event: unknown) => {
      const item = event as { seriesId?: string; data?: { pointId?: string } };
      if (item.data?.pointId) onPointClick?.(item.data.pointId);
      else if (item.seriesId) onSeriesClick?.(item.seriesId);
    };
    instance.on('click', listener);
    return () => { instance.off('click', listener); };
  }, [onSeriesClick, onPointClick]);
  return <div className={`pov-chart ${className}`} ref={element} role="img" aria-label="观测数据图表" />;
}

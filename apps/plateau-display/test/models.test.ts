import { describe, expect, it } from 'vitest';
import { anchorPosition, bindModelAnchors, partOffset, validateTemplate } from '../src/models/anchors';
import { engineeringTemplates, modelTemplateIds } from '../src/models/builders';

describe('engineering model contract', () => {
  it('provides eight distinct complete semantic templates', () => {
    expect(modelTemplateIds).toHaveLength(8);
    for (const template of Object.values(engineeringTemplates)) {
      expect(validateTemplate(template)).toEqual([]);
      expect(template.parts.filter(part => part.selectable).length).toBeGreaterThan(4);
      expect(template.anchors.length).toBeGreaterThanOrEqual(3);
      expect(Object.keys(template.cameras).sort()).toEqual(['inspection', 'overall', 'recommended', 'section']);
      expect(template.version).toBe('pov-model-v1');
    }
    expect(new Set(Object.values(engineeringTemplates).map(template => template.parts.map(part => part.shape).join(','))).size).toBeGreaterThan(5);
  });

  it('moves anchors with their parent semantic part during section expansion', () => {
    const model = engineeringTemplates.pavement;
    const anchor = model.anchors.find(item => item.anchorId === 'axle-load')!;
    const original = anchorPosition(model, anchor.anchorId, 'exterior')!;
    const opened = anchorPosition(model, anchor.anchorId, 'section')!;
    const displacement = partOffset(model, anchor.componentId, 'section');
    expect(opened).toEqual(original.map((value, index) => value + displacement[index]));
    expect(opened).not.toEqual(original);
    expect(anchorPosition(model, anchor.anchorId, 'points')).toEqual(original);
  });

  it('binds catalog point metadata and rejects an outdated model version', () => {
    const model = engineeringTemplates.bridge;
    const anchor = model.anchors[0];
    const point = {
      id: 'point-1', facilityId: 'bridge-1',
      modelAnchor: { anchorId: anchor.anchorId, componentId: anchor.componentId,
        localPosition: [...anchor.localPosition] as [number, number, number], modelAssetVersion: model.version },
    };
    const bound = bindModelAnchors(model, 'bridge-1', [point], 'section');
    expect(bound[0].pointId).toBe('point-1');
    expect(bound[0].modelAssetVersion).toBe(model.version);
    expect(bound[0].displayedPosition).toEqual(anchorPosition(model, anchor.anchorId, 'section'));
    expect(() => bindModelAnchors(model, 'bridge-1', [{ ...point,
      modelAnchor: { ...point.modelAnchor, modelAssetVersion: 'old' } }], 'exterior'))
      .toThrow(/Stale model anchor/);
  });
});

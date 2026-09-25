import type { BoundModelAnchor, EngineeringTemplate, ModelMode, Vec3 } from './types';

const add = (a: Vec3, b: Vec3): Vec3 => [a[0] + b[0], a[1] + b[1], a[2] + b[2]];

/** World displacement of a semantic part. Geometry positions remain local engineering metres. */
export function partOffset(template: EngineeringTemplate, partId: string, mode: ModelMode): Vec3 {
  if (mode !== 'section') return [0, 0, 0];
  const seen = new Set<string>();
  let current = template.parts.find(part => part.semanticId === partId);
  let offset: Vec3 = [0, 0, 0];
  while (current) {
    if (seen.has(current.semanticId)) throw new Error(`Model part cycle: ${current.semanticId}`);
    seen.add(current.semanticId);
    if (current.sectionOffset) offset = add(offset, current.sectionOffset);
    current = current.parentId ? template.parts.find(part => part.semanticId === current?.parentId) : undefined;
  }
  return offset;
}

export function anchorPosition(template: EngineeringTemplate, anchorId: string, mode: ModelMode): Vec3 | undefined {
  const anchor = template.anchors.find(item => item.anchorId === anchorId);
  if (!anchor) return undefined;
  return add(anchor.localPosition, partOffset(template, anchor.componentId, mode));
}

/** Binds catalog points by stable IDs; a missing anchor is an integration error, never a screen-position fallback. */
export function bindModelAnchors(
  template: EngineeringTemplate,
  facilityId: string,
  points: readonly { id: string; facilityId: string; modelAnchor: string | {
    modelAssetVersion: string; componentId: string; localPosition: readonly [number, number, number];
    normal?: readonly [number, number, number]; anchorId?: string;
  } }[],
  mode: ModelMode,
): BoundModelAnchor[] {
  return points.filter(point => point.facilityId === facilityId).map(point => {
    const binding = point.modelAnchor;
    if (typeof binding !== 'string' && binding.modelAssetVersion !== template.version)
      throw new Error(`Stale model anchor for point ${point.id}: ${binding.modelAssetVersion}`);
    const anchor = typeof binding === 'string'
      ? template.anchors.find(item => item.anchorId === binding)
      : template.anchors.find(item => item.anchorId === binding.anchorId) ?? {
        anchorId: binding.anchorId ?? point.id, componentId: binding.componentId,
        localPosition: binding.localPosition, localNormal: binding.normal,
        label: point.id, metricHint: '',
      };
    if (!anchor) throw new Error(`Missing ${template.id} anchor ${String(binding)} for point ${point.id}`);
    if (!template.parts.some(part => part.semanticId === anchor.componentId))
      throw new Error(`Missing ${template.id} component ${anchor.componentId} for point ${point.id}`);
    return {
      ...anchor, facilityId, pointId: point.id, modelAssetVersion: template.version,
      displayedPosition: add(anchor.localPosition, partOffset(template, anchor.componentId, mode)),
    };
  });
}

/** Validate templates at build/test time and after any model version change. */
export function validateTemplate(template: EngineeringTemplate): string[] {
  const errors: string[] = [];
  const ids = new Set<string>();
  for (const part of template.parts) {
    if (ids.has(part.semanticId)) errors.push(`duplicate part ${part.semanticId}`);
    ids.add(part.semanticId);
    if (part.size.some(value => !Number.isFinite(value) || value <= 0)) errors.push(`invalid size ${part.semanticId}`);
  }
  const anchors = new Set<string>();
  for (const anchor of template.anchors) {
    if (anchors.has(anchor.anchorId)) errors.push(`duplicate anchor ${anchor.anchorId}`);
    anchors.add(anchor.anchorId);
    if (!ids.has(anchor.componentId)) errors.push(`missing component ${anchor.componentId}`);
    if (anchor.localPosition.some(value => !Number.isFinite(value))) errors.push(`invalid anchor ${anchor.anchorId}`);
  }
  for (const part of template.parts) {
    if (part.parentId && !ids.has(part.parentId)) errors.push(`missing parent ${part.parentId}`);
    try { partOffset(template, part.semanticId, 'section'); } catch (error) { errors.push(String(error)); }
  }
  return errors;
}

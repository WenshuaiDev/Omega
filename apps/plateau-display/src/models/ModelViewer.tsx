import { Canvas, ThreeEvent, useFrame, useThree } from '@react-three/fiber';
import { OrbitControls } from 'three/examples/jsm/controls/OrbitControls.js';
import { useEffect, useMemo, useRef } from 'react';
import * as THREE from 'three';
import { bindModelAnchors, partOffset } from './anchors';
import { getEngineeringTemplate } from './builders';
import type { BoundModelAnchor, CameraPreset, EngineeringTemplate, ModelMode, ModelPart, ModelTemplateId, Vec3 } from './types';

type CatalogPoint = { id: string; facilityId: string; modelAnchor: string | {
  modelAssetVersion: string; componentId: string; localPosition: readonly [number, number, number];
  normal?: readonly [number, number, number]; anchorId?: string;
} };
export interface ModelViewerProps {
  templateId: ModelTemplateId;
  facilityId: string;
  points: readonly CatalogPoint[];
  mode: ModelMode;
  selectedComponentId?: string;
  selectedPointId?: string;
  cameraPreset?: CameraPreset;
  resetViewToken?: number;
  onComponentSelect?: (semanticId: string) => void;
  onPointSelect?: (pointId: string) => void;
  onReady?: () => void;
  onError?: (error: Error) => void;
  /** External scene manager must unmount when map becomes active. */
  className?: string;
}

function CameraRig({ template, preset, resetToken }: { template: EngineeringTemplate; preset: CameraPreset; resetToken: number }) {
  const { camera, gl, invalidate } = useThree();
  const controls = useMemo(() => new OrbitControls(camera, gl.domElement), [camera, gl]);
  useEffect(() => {
    controls.enableDamping = true;
    controls.dampingFactor = 0.09;
    controls.minDistance = Math.max(3, template.sizeMetres[1] * 0.35);
    controls.maxDistance = Math.max(...template.sizeMetres) * 3;
    controls.maxPolarAngle = Math.PI * 0.94;
    const changed = () => invalidate();
    controls.addEventListener('change', changed);
    return () => { controls.removeEventListener('change', changed); controls.dispose(); };
  }, [controls, invalidate, template]);
  useEffect(() => {
    const view = template.cameras[preset];
    camera.position.set(...view.position);
    controls.target.set(...view.target);
    camera.lookAt(...view.target);
    controls.update();
    invalidate();
  }, [camera, controls, invalidate, preset, resetToken, template]);
  useFrame(() => controls.update());
  return null;
}

function TubeGeometry({ outer, length, inner }: { outer: number; length: number; inner: number }) {
  const geometry = useMemo(() => {
    const shape = new THREE.Shape();
    shape.absarc(0, 0, outer, 0, Math.PI * 2, false);
    const hole = new THREE.Path();
    hole.absarc(0, 0, inner, 0, Math.PI * 2, true);
    shape.holes.push(hole);
    const ring = new THREE.ExtrudeGeometry(shape, { depth: length, bevelEnabled: false, curveSegments: 40 });
    ring.translate(0, 0, -length / 2);
    ring.rotateX(-Math.PI / 2);
    return ring;
  }, [outer, length, inner]);
  useEffect(() => () => geometry.dispose(), [geometry]);
  return <primitive object={geometry} attach="geometry" />;
}

function PartMesh({ part, offset, selected, mode, onSelect }: {
  part: ModelPart; offset: Vec3; selected: boolean; mode: ModelMode; onSelect?: (id: string) => void;
}) {
  const position: Vec3 = [part.position[0] + offset[0], part.position[1] + offset[1], part.position[2] + offset[2]];
  const roughness = part.material === 'glass' ? 0.24 : part.material === 'steel' ? 0.38 : 0.83;
  const metalness = part.material === 'steel' ? 0.58 : part.material === 'sensor' ? 0.42 : 0.06;
  const click = (event: ThreeEvent<MouseEvent>) => {
    if (!part.selectable) return;
    event.stopPropagation();
    onSelect?.(part.semanticId);
  };
  if (mode === 'section' && part.sectionHidden) return null;
  return (
    <mesh name={part.semanticId} position={[...position]} rotation={part.rotation ? [...part.rotation] : undefined}
      castShadow receiveShadow onClick={click}>
      {part.shape === 'box' && <boxGeometry args={[...part.size]} />}
      {part.shape === 'cylinder' && <cylinderGeometry args={[part.size[0] / 2, part.size[0] / 2, part.size[1], 20]} />}
      {part.shape === 'sphere' && <sphereGeometry args={[part.size[0] / 2, 18, 12]} />}
      {part.shape === 'cone' && <coneGeometry args={[part.size[0] / 2, part.size[1], 20]} />}
      {part.shape === 'tube' && <TubeGeometry outer={part.size[0]} length={part.size[1]} inner={part.size[2]} />}
      <meshStandardMaterial color={part.color} roughness={roughness} metalness={metalness}
        emissive={selected ? '#38a8ff' : '#000000'} emissiveIntensity={selected ? 0.45 : 0}
        transparent={part.material === 'glass'} opacity={part.material === 'glass' ? 0.72 : 1} />
    </mesh>
  );
}

function PointMarkers({ anchors, selectedPointId, onPointSelect }: {
  anchors: BoundModelAnchor[]; selectedPointId?: string; onPointSelect?: (id: string) => void;
}) {
  return <>{anchors.slice(0, 30).map(anchor => (
    <mesh key={anchor.pointId} name={anchor.pointId} position={[...anchor.displayedPosition]}
      onClick={event => { event.stopPropagation(); onPointSelect?.(anchor.pointId); }}>
      {/* Pick geometry is fixed; emissive feedback changes appearance without shrinking hit area. */}
      <sphereGeometry args={[0.55, 12, 8]} />
      <meshBasicMaterial color={anchor.pointId === selectedPointId ? '#ffffff' : '#4cd6da'}
        transparent opacity={anchor.pointId === selectedPointId ? 0.95 : 0.72}
        depthTest={anchor.pointId !== selectedPointId} />
    </mesh>
  ))}</>;
}

function ReadySignal({ onReady }: { onReady?: () => void }) {
  const sent = useRef(false);
  useFrame(() => { if (!sent.current) { sent.current = true; onReady?.(); } });
  return null;
}

/** Self-contained Three stage. Unmounting Canvas releases its renderer; all custom controls and tube geometries dispose. */
export function ModelViewer(props: ModelViewerProps) {
  const template = getEngineeringTemplate(props.templateId);
  let anchors: BoundModelAnchor[] = [];
  let errorMessage = template ? '' : `Unknown model template: ${props.templateId}`;
  if (template) {
    try { anchors = bindModelAnchors(template, props.facilityId, props.points, props.mode); }
    catch (error) { errorMessage = (error as Error).message; }
  }
  useEffect(() => { if (errorMessage) props.onError?.(new Error(errorMessage)); }, [errorMessage, props.onError]);
  if (!template || errorMessage) return null;
  return <Canvas className={props.className} frameloop="always" dpr={[0.75, 1]}
    camera={{ position: [...template.cameras.recommended.position], fov: 42, near: 0.05, far: 500 }}
    shadows gl={{ antialias: true, powerPreference: 'high-performance' }}>
    <color attach="background" args={[template.background]} />
    <ambientLight intensity={1.1} />
    <hemisphereLight args={['#d9efff', '#746b58', 1.45]} />
    <directionalLight position={[25, 48, 24]} intensity={2.4} castShadow shadow-mapSize={[2048, 2048]}
      shadow-camera-left={-70} shadow-camera-right={70} shadow-camera-top={70} shadow-camera-bottom={-70} />
    {template.parts.map(part => <PartMesh key={part.semanticId} part={part}
      offset={partOffset(template, part.semanticId, props.mode)}
      selected={part.semanticId === props.selectedComponentId} mode={props.mode}
      onSelect={props.onComponentSelect} />)}
    {(props.mode === 'points' || props.selectedPointId) && <PointMarkers anchors={anchors}
      selectedPointId={props.selectedPointId} onPointSelect={props.onPointSelect} />}
    <CameraRig template={template} preset={props.cameraPreset ?? (props.mode === 'section' ? 'section' : 'recommended')}
      resetToken={props.resetViewToken ?? 0} />
    <ReadySignal onReady={props.onReady} />
  </Canvas>;
}

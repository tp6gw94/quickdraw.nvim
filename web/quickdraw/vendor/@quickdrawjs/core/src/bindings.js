import { localBounds, toLocal, toPage, lineGeometry, withLineGeometry, containsShape } from './shapes.js'
import { clamp } from './geometry.js'

const TARGET_TYPES = new Set(['geo', 'note', 'text', 'image'])
const ENDS = ['start', 'end']
const EPS = 1e-9

const near = (a, b) => Math.abs(a - b) <= EPS * Math.max(1, Math.abs(a), Math.abs(b))

const validBinding = (b) =>
  !!b && typeof b.targetId === 'string' && !!b.anchor &&
  Number.isFinite(b.anchor.u) && Number.isFinite(b.anchor.v) &&
  b.anchor.u >= 0 && b.anchor.u <= 1 && b.anchor.v >= 0 && b.anchor.v <= 1

const anchorPoint = (target, anchor) => {
  const lb = localBounds(target)
  return toPage(target, lb.x + anchor.u * lb.w, lb.y + anchor.v * lb.h)
}

export function settleBindings(records) {
  const out = []
  for (const rec of records.values()) {
    if (rec.type !== 'arrow') continue
    const p = rec.props
    const geo = lineGeometry(rec)
    const pts = { start: geo.start, end: geo.end }
    const detached = {}
    let moved = false
    for (const end of ENDS) {
      const key = end + 'Binding'
      const b = p[key]
      if (b == null) continue
      const target = validBinding(b) ? records.get(b.targetId) : null
      if (!target || !TARGET_TYPES.has(target.type)) { detached[key] = null; continue }
      const want = anchorPoint(target, b.anchor)
      if (near(want.x, pts[end].x) && near(want.y, pts[end].y)) continue
      pts[end] = want
      moved = true
    }
    if (!moved && !Object.keys(detached).length) continue
    const next = { ...rec, props: { ...p, ...detached } }
    out.push(moved ? withLineGeometry(next, { start: pts.start, end: pts.end, bend: geo.bend }) : next)
  }
  return out
}

export function bindingAt(shapesBackToFront, pt) {
  for (let i = shapesBackToFront.length - 1; i >= 0; i--) {
    const s = shapesBackToFront[i]
    if (!TARGET_TYPES.has(s.type) || !containsShape(s, pt)) continue
    const lb = localBounds(s)
    const l = toLocal(s, pt.x, pt.y)
    return { targetId: s.id, anchor: { u: clamp((l.x - lb.x) / lb.w, 0, 1), v: clamp((l.y - lb.y) / lb.h, 0, 1) } }
  }
  return null
}

export function withEndpoint(arrow, end, pt, binding) {
  const geo = lineGeometry(arrow)
  const next = withLineGeometry(arrow, { ...geo, [end]: pt })
  return { ...next, props: { ...next.props, [end + 'Binding']: binding } }
}

export function mapBindingTargets(shape, idMap) {
  if (shape.type !== 'arrow') return shape
  let props = shape.props
  for (const end of ENDS) {
    const key = end + 'Binding'
    const b = props[key]
    if (!b) continue
    const mapped = idMap.get(b.targetId)
    if (mapped === b.targetId) continue
    props = { ...props, [key]: mapped ? { ...b, targetId: mapped } : null }
  }
  return props === shape.props ? shape : { ...shape, props }
}

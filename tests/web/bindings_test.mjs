import assert from "node:assert/strict"
import test from "node:test"

import { Store } from "../../web/quickdraw/vendor/@quickdrawjs/core/src/store.js"
import { lineGeometry, withLineGeometry } from "../../web/quickdraw/vendor/@quickdrawjs/core/src/shapes.js"
import {
  bindingAt, mapBindingTargets, settleBindings, withEndpoint,
} from "../../web/quickdraw/vendor/@quickdrawjs/core/src/bindings.js"

const box = (id, x, y, w, h, extra = {}) => ({
  id, typeName: "shape", type: "geo", x, y, rot: 0, z: 1,
  props: { geo: "rectangle", w, h, color: "black", size: "m", dash: "solid", fill: "none" },
  ...extra,
})
const image = (id, x, y, w, h) => ({
  id, typeName: "shape", type: "image", x, y, rot: 0, z: 1, props: { w, h, assetId: "asset:1" },
})
const arrow = (id, x, y, dx, dy, extra = {}) => ({
  id, typeName: "shape", type: "arrow", x, y, rot: 0, z: 2,
  props: { dx, dy, bend: 0, color: "black", size: "m", dash: "solid", ...extra },
})

const close = (a, b, msg) => assert.ok(Math.abs(a - b) < 1e-6, `${msg}: ${a} vs ${b}`)
const closePt = (p, x, y, msg) => { close(p.x, x, msg + ".x"); close(p.y, y, msg + ".y") }

function boardWithBoundArrow() {
  const store = new Store()
  const diffs = []
  store.listen((diff, source) => diffs.push({ diff, source }))
  store.put(box("box", 100, 100, 200, 100))
  const end = { targetId: "box", anchor: { u: 1, v: 0.5 } }
  store.put(withEndpoint(arrow("arrow", 0, 0, 10, 10), "end", { x: 300, y: 150 }, end))
  diffs.length = 0
  return { store, diffs }
}

test("lineGeometry and withLineGeometry round-trip a rotated bent arrow", () => {
  const a = arrow("a", 40, 70, 120, -30, { bend: 25 })
  a.rot = Math.PI / 5
  const geo = lineGeometry(a)
  const back = withLineGeometry(a, geo)
  close(back.x, a.x, "x")
  close(back.y, a.y, "y")
  close(back.props.dx, a.props.dx, "dx")
  close(back.props.dy, a.props.dy, "dy")
  assert.equal(back.props.bend, 25)
  assert.equal(back.rot, a.rot)
  const moved = withLineGeometry(a, { start: { x: 0, y: 0 }, end: { x: 100, y: 50 }, bend: -4 })
  const geo2 = lineGeometry(moved)
  closePt(geo2.start, 0, 0, "start")
  closePt(geo2.end, 100, 50, "end")
  assert.equal(geo2.bend, -4)
  assert.equal(moved.rot, a.rot)
})

test("settlement moves bound ends on translate, resize and rotate in the same diff", () => {
  const { store, diffs } = boardWithBoundArrow()
  closePt(lineGeometry(store.get("arrow")).end, 300, 150, "initial")

  store.transact(() => store.update("box", { x: 400 }))
  assert.equal(diffs.length, 1)
  assert.deepEqual(Object.keys(diffs[0].diff.updated).sort(), ["arrow", "box"])
  closePt(lineGeometry(store.get("arrow")).end, 600, 150, "translate")
  closePt(lineGeometry(store.get("arrow")).start, 0, 0, "translate keeps free end")

  store.transact(() => store.update("box", { props: { w: 400 } }))
  assert.equal(diffs.length, 2)
  assert.deepEqual(Object.keys(diffs[1].diff.updated).sort(), ["arrow", "box"])
  closePt(lineGeometry(store.get("arrow")).end, 800, 150, "resize")

  store.transact(() => store.update("box", { rot: Math.PI / 2 }))
  assert.equal(diffs.length, 3)
  assert.deepEqual(Object.keys(diffs[2].diff.updated).sort(), ["arrow", "box"])
  closePt(lineGeometry(store.get("arrow")).end, 600, 350, "rotate")
  assert.deepEqual(store.get("arrow").props.endBinding, { targetId: "box", anchor: { u: 1, v: 0.5 } })
  assert.deepEqual(settleBindings(store.records), [])
})

test("deleting the target unbinds the arrow in the same diff and undo/redo restore both", () => {
  const { store, diffs } = boardWithBoundArrow()
  store.remove(["box"])
  assert.equal(diffs.length, 1)
  assert.deepEqual(Object.keys(diffs[0].diff.removed), ["box"])
  assert.deepEqual(Object.keys(diffs[0].diff.updated), ["arrow"])
  assert.equal(store.get("arrow").props.endBinding, null)
  closePt(lineGeometry(store.get("arrow")).end, 300, 150, "arrow stays")

  store.undo()
  assert.equal(diffs.length, 2)
  assert.ok(store.has("box"))
  assert.deepEqual(store.get("arrow").props.endBinding, { targetId: "box", anchor: { u: 1, v: 0.5 } })
  assert.deepEqual(settleBindings(store.records), [])

  store.redo()
  assert.equal(diffs.length, 3)
  assert.ok(!store.has("box"))
  assert.equal(store.get("arrow").props.endBinding, null)
  assert.deepEqual(settleBindings(store.records), [])
})

test("a legacy snapshot without binding fields is loaded untouched", () => {
  const store = new Store()
  const diffs = []
  store.listen((diff) => diffs.push(diff))
  const legacyBox = box("box", 10, 10, 50, 50)
  const legacyArrow = arrow("arrow", 0, 0, 30, 30)
  store.loadSnapshot({ document: { store: { box: legacyBox, arrow: legacyArrow } } })
  assert.equal(diffs.length, 1)
  assert.deepEqual(Object.keys(diffs[0].updated), [])
  assert.equal(store.get("arrow"), legacyArrow)
  assert.equal(store.get("box"), legacyBox)
})

test("a malformed binding detaches only its own end", () => {
  const store = new Store()
  store.put(image("img", 500, 500, 100, 100))
  store.put(arrow("arrow", 0, 0, 10, 10, {
    startBinding: { targetId: "img", anchor: { u: 2, v: 0 } },
    endBinding: { targetId: "img", anchor: { u: 0, v: 0.5 } },
  }))
  const a = store.get("arrow")
  assert.equal(a.props.startBinding, null)
  assert.deepEqual(a.props.endBinding, { targetId: "img", anchor: { u: 0, v: 0.5 } })
  closePt(lineGeometry(a).start, 0, 0, "malformed end keeps its page point")
  closePt(lineGeometry(a).end, 500, 550, "valid end resolves")
})

test("bindingAt binds inside real shape bodies only and ignores shapes above the target", () => {
  const hollow = box("hollow", 0, 0, 100, 100)
  const tilted = box("tilted", 200, 0, 100, 100, { rot: Math.PI / 4 })
  const above = arrow("above", 0, 0, 100, 100)
  above.z = 5
  const shapes = [hollow, tilted, above]
  assert.deepEqual(bindingAt(shapes, { x: 50, y: 50 }), { targetId: "hollow", anchor: { u: 0.5, v: 0.5 } })
  assert.deepEqual(bindingAt(shapes, { x: 25, y: 75 }), { targetId: "hollow", anchor: { u: 0.25, v: 0.75 } })
  assert.deepEqual(bindingAt(shapes, { x: 100, y: 50 }), { targetId: "hollow", anchor: { u: 1, v: 0.5 } })
  assert.deepEqual(bindingAt(shapes, { x: 50, y: 100 }), { targetId: "hollow", anchor: { u: 0.5, v: 1 } })
  assert.equal(bindingAt(shapes, { x: 201, y: 1 }), null)
  assert.deepEqual(bindingAt(shapes, { x: 250, y: 50 }), { targetId: "tilted", anchor: { u: 0.5, v: 0.5 } })
  assert.equal(bindingAt(shapes, { x: 150, y: 150 }), null)
})

test("mapBindingTargets retargets through the remap and detaches the rest", () => {
  const a = arrow("arrow", 0, 0, 10, 10, {
    startBinding: { targetId: "box", anchor: { u: 0, v: 0 } },
    endBinding: { targetId: "img", anchor: { u: 1, v: 1 } },
  })
  const mapped = mapBindingTargets(a, (id) => (id === "box" ? "box2" : null))
  assert.deepEqual(mapped.props.startBinding, { targetId: "box2", anchor: { u: 0, v: 0 } })
  assert.equal(mapped.props.endBinding, null)
  assert.equal(mapped.props.dx, 10)
  const identity = mapBindingTargets(a, (id) => id)
  assert.equal(identity, a)
  const plain = box("box", 0, 0, 10, 10)
  assert.equal(mapBindingTargets(plain, () => null), plain)
})

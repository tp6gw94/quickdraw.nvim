import assert from "node:assert/strict"
import test from "node:test"

import { elem } from "./dom_stub.mjs"
import { Editor } from "../../web/quickdraw/vendor/@quickdrawjs/core/src/editor.js"
import { arrowHeads } from "../../web/quickdraw/vendor/@quickdrawjs/core/src/shapes.js"

const close = (a, b, msg) => assert.ok(Math.abs(a - b) < 1e-9, `${msg}: ${a} vs ${b}`)
const closePt = (h, x, y, msg) => {
  close(h.x, x, msg + ".x")
  close(h.y, y, msg + ".y")
}

const lineish = (id, type, props = {}) => ({
  id, typeName: "shape", type, x: 0, y: 0, rot: 0, z: 1,
  props: { dx: 100, dy: 0, bend: 0, color: "black", size: "m", dash: "solid", ...props },
})

function board() {
  const ed = new Editor({ container: elem() })
  const fire = (type, x, y) => ed.container.listeners[type]({
    type, target: ed.container, button: 0, pointerType: "mouse", pointerId: 1,
    clientX: x, clientY: y, shiftKey: false, altKey: false, preventDefault() {},
  })
  const drag = (x0, y0, x1, y1) => {
    fire("pointerdown", x0, y0)
    fire("pointermove", x1, y1)
    fire("pointerup", x1, y1)
  }
  return { ed, drag }
}

test("a straight arrow points its start head back and its end head along the segment", () => {
  const heads = arrowHeads(lineish("A", "arrow", { dx: 10, dy: -4, headStart: "arrow", headEnd: "triangle" }).props)
  assert.deepEqual(heads.map((h) => h.kind), ["arrow", "triangle"])
  closePt(heads[0], 0, 0, "start tip")
  close(heads[0].angle, Math.atan2(4, -10), "start angle")
  closePt(heads[1], 10, -4, "end tip")
  close(heads[1].angle, Math.atan2(-4, 10), "end angle")
})

test("a 'none' head is left out of the head list", () => {
  const heads = arrowHeads(lineish("A", "arrow", { headStart: "none", headEnd: "bar" }).props)
  assert.deepEqual(heads.map((h) => h.kind), ["bar"])
})

test("an arrow record without head fields keeps today's single end chevron", () => {
  const heads = arrowHeads(lineish("A", "arrow", { dx: 12, dy: 5 }).props)
  assert.deepEqual(heads.map((h) => h.kind), ["arrow"])
  closePt(heads[0], 12, 5, "end tip")
})

test("a bent arrow's heads follow the curve tangent at each end", () => {
  const heads = arrowHeads(lineish("A", "arrow", { dx: 100, dy: 0, bend: 40, headStart: "arrow", headEnd: "arrow" }).props)
  const [start, end] = heads
  closePt(start, 0, 0, "start tip")
  closePt(end, 100, 0, "end tip")
  assert.ok(end.angle < 0 && end.angle > -Math.PI / 2, `end points right and toward the bulge: ${end.angle}`)
  assert.ok(start.angle < -Math.PI / 2 && start.angle > -Math.PI, `start points left and toward the bulge: ${start.angle}`)
})

test("setStyle('headEnd') reaches a selected arrow and leaves a selected line alone", () => {
  const { ed } = board()
  ed.store.put(lineish("A", "arrow"))
  ed.store.put(lineish("L", "line"))
  ed.setSelection(["A", "L"])
  ed.setStyle("headEnd", "dot")
  assert.equal(ed.store.get("A").props.headEnd, "dot")
  assert.equal("headEnd" in ed.store.get("L").props, false)
})

test("currentStyles reports a mixed headEnd as null and a shared one as its value", () => {
  const { ed } = board()
  ed.store.put(lineish("A", "arrow", { headEnd: "dot" }))
  ed.store.put(lineish("B", "arrow", { headEnd: "bar" }))
  ed.setSelection(["A", "B"])
  assert.equal(ed.currentStyles().headEnd, null)
  ed.setSelection(["A"])
  assert.equal(ed.currentStyles().headEnd, "dot")
})

test("a new arrow is drawn with the current heads and a new line with none", () => {
  const { ed, drag } = board()
  ed.setStyle("headStart", "triangle")
  ed.setStyle("headEnd", "none")
  ed.setTool("arrow")
  drag(100, 100, 300, 160)
  const arrow = ed.store.shapes().find((s) => s.type === "arrow")
  assert.equal(arrow.props.headStart, "triangle")
  assert.equal(arrow.props.headEnd, "none")
  ed.setTool("line")
  drag(100, 300, 300, 360)
  const line = ed.store.shapes().find((s) => s.type === "line")
  assert.equal("headStart" in line.props, false)
  assert.equal("headEnd" in line.props, false)
})

test("a new arrow defaults to a bare start and a chevron end", () => {
  const { ed, drag } = board()
  ed.setTool("arrow")
  drag(100, 100, 300, 160)
  const arrow = ed.store.shapes().find((s) => s.type === "arrow")
  assert.equal(arrow.props.headStart, "none")
  assert.equal(arrow.props.headEnd, "arrow")
})

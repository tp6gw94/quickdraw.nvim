import assert from "node:assert/strict"
import test from "node:test"

import { elem } from "./dom_stub.mjs"
import { Editor } from "../../web/quickdraw/vendor/@quickdrawjs/core/src/editor.js"
import { lineGeometry } from "../../web/quickdraw/vendor/@quickdrawjs/core/src/shapes.js"

const box = (id, x, y, w, h) => ({
  id, typeName: "shape", type: "geo", x, y, rot: 0, z: 1,
  props: { geo: "rectangle", w, h, color: "black", size: "m", dash: "solid", fill: "none" },
})

function board() {
  const ed = new Editor({ container: elem() })
  ed.store.put(box("A", 0, 0, 100, 100))
  ed.store.put(box("B", 300, 0, 100, 100))
  const fire = (type, x, y) => ed.container.listeners[type]({
    type, target: ed.container, button: 0, pointerType: "mouse", pointerId: 1,
    clientX: x, clientY: y, shiftKey: false, altKey: false, preventDefault() {},
  })
  const down = (x, y) => fire("pointerdown", x, y)
  const move = (x, y) => fire("pointermove", x, y)
  const up = (x, y) => fire("pointerup", x, y)
  const drag = (x0, y0, x1, y1) => { down(x0, y0); move(x1, y1); up(x1, y1) }
  const arrow = () => ed.store.shapes().find((s) => s.type === "arrow")
  const drawArrow = (x0, y0, x1, y1) => { ed.setTool("arrow"); drag(x0, y0, x1, y1); return arrow() }
  return { ed, down, move, up, drag, arrow, drawArrow }
}

const close = (a, b, msg) => assert.ok(Math.abs(a - b) < 1e-6, `${msg}: ${a} vs ${b}`)
const closePt = (p, x, y, msg) => { close(p.x, x, msg + ".x"); close(p.y, y, msg + ".y") }

test("locked arrow and rectangle creation keeps the tool and leaves selection empty", () => {
  const { ed, drag, arrow } = board()
  ed.setToolLocked(true)
  ed.setTool("arrow")
  drag(150, 150, 250, 250)
  assert.ok(arrow())
  assert.equal(ed.tool, "arrow")
  assert.equal(ed.selection.size, 0)
  ed.setTool("geo")
  drag(500, 300, 600, 400)
  assert.equal(ed.store.shapes().filter((s) => s.type === "geo").length, 3)
  assert.equal(ed.tool, "geo")
  assert.equal(ed.selection.size, 0)
})

test("unlocked creation selects the new shape and switches to select", () => {
  const { ed, drag, arrow } = board()
  ed.setTool("arrow")
  drag(150, 150, 250, 250)
  assert.equal(ed.tool, "select")
  assert.deepEqual([...ed.selection], [arrow().id])
  ed.setTool("geo")
  drag(500, 300, 600, 400)
  const rect = ed.store.shapes().find((s) => s.type === "geo" && s.x === 500)
  assert.equal(ed.tool, "select")
  assert.deepEqual([...ed.selection], [rect.id])
})

test("locked text placement keeps the text tool and commit leaves it", () => {
  const { ed, drag } = board()
  ed.setToolLocked(true)
  ed.setTool("text")
  drag(500, 500, 500, 500)
  assert.equal(ed.tool, "text")
  assert.equal(ed.selection.size, 0)
  const ta = ed.editing.textarea
  ta.value = "hello"
  ta.listeners.input()
  ta.listeners.blur()
  assert.equal(ed.editing, null)
  assert.equal(ed.tool, "text")
  assert.equal(ed.selection.size, 0)
  assert.deepEqual(ed.store.shapes().filter((s) => s.type === "text").map((s) => s.props.text), ["hello"])
})

test("dragging a bound arrow alone detaches both ends", () => {
  const { ed, drag, arrow, drawArrow } = board()
  const a = drawArrow(50, 50, 350, 50)
  assert.equal(a.props.startBinding.targetId, "A")
  assert.equal(a.props.endBinding.targetId, "B")
  drag(120, 50, 140, 70)
  const moved = arrow()
  assert.equal(moved.props.startBinding, null)
  assert.equal(moved.props.endBinding, null)
  closePt(lineGeometry(moved).start, 70, 70, "start")
  closePt(lineGeometry(moved).end, 370, 70, "end")
  assert.equal(ed.store.get("B").x, 300)
})

test("dragging arrow and target together keeps the binding and moves the head", () => {
  const { ed, drag, arrow, drawArrow } = board()
  const a = drawArrow(50, 50, 350, 50)
  ed.setSelection([a.id, "B"])
  drag(300, 20, 400, 120)
  const moved = arrow()
  assert.equal(ed.store.get("B").x, 400)
  assert.deepEqual(moved.props.endBinding, { targetId: "B", anchor: { u: 0.5, v: 0.5 } })
  closePt(lineGeometry(moved).end, 450, 150, "end")
  assert.equal(moved.props.startBinding, null)
  closePt(lineGeometry(moved).start, 150, 150, "start")
})

test("an endpoint handle drag released inside a rectangle binds to it", () => {
  const { down, move, up, arrow, drawArrow } = board()
  const a = drawArrow(50, 50, 200, 50)
  assert.equal(a.props.endBinding, null)
  down(200, 50)
  move(195, 50)
  move(340, 60)
  up(340, 60)
  const bound = arrow()
  assert.deepEqual(bound.props.endBinding, { targetId: "B", anchor: { u: 0.4, v: 0.6 } })
  closePt(lineGeometry(bound).end, 340, 60, "end")
  assert.equal(bound.props.startBinding.targetId, "A")
})

test("duplicating arrow and target remaps the binding to the copy", () => {
  const { ed, drawArrow } = board()
  const a = drawArrow(50, 50, 350, 50)
  ed.setSelection([a.id, "B"])
  ed.duplicateSelection()
  const copies = [...ed.selection].map((id) => ed.store.get(id))
  const arrowCopy = copies.find((s) => s.type === "arrow")
  const boxCopy = copies.find((s) => s.type === "geo")
  assert.equal(arrowCopy.props.endBinding.targetId, boxCopy.id)
  assert.equal(arrowCopy.props.startBinding, null)
  closePt(lineGeometry(arrowCopy).end, 366, 66, "copy end")
  assert.equal(ed.store.get(a.id).props.endBinding.targetId, "B")
})

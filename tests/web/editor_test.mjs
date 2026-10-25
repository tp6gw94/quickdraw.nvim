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
  const escape = () => ed.container.listeners.keydown({ key: "Escape", metaKey: false, ctrlKey: false, preventDefault() {} })
  return { ed, fire, down, move, up, drag, escape, arrow, drawArrow }
}

const text = (id, x, y, t) => ({
  id, typeName: "shape", type: "text", x, y, rot: 0, z: 1,
  props: { text: t, color: "black", size: "m", font: "draw", autosize: true, scale: 1 },
})

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

test("locked text tool tapping existing text edits it and keeps the text tool", () => {
  const { ed, down, up } = board()
  ed.store.put(text("T", 500, 500, "hi"))
  ed.setToolLocked(true)
  ed.setTool("text")
  down(505, 510)
  up(505, 510)
  assert.equal(ed.editing.id, "T")
  assert.equal(ed.tool, "text")
  assert.equal(ed.selection.size, 0)
  ed._commitText()
  assert.equal(ed.editing, null)
  assert.equal(ed.tool, "text")
  assert.equal(ed.selection.size, 0)
  assert.equal(ed.store.get("T").props.text, "hi")
})

test("a click on a rectangle's stroke with the arrow tool leaves no arrow", () => {
  const { ed, down, up, arrow } = board()
  ed.setTool("arrow")
  down(101, 50)
  assert.ok(arrow())
  up(101, 50)
  assert.equal(arrow(), undefined)
})

test("a jittery press at a rectangle corner leaves no arrow once both ends settle to the corner", () => {
  const { ed, down, move, up, arrow } = board()
  ed.setTool("arrow")
  down(102, 100)
  move(100, 102)
  up(100, 102)
  assert.equal(arrow(), undefined)
})

test("pointercancel ends the arrow at the last move and binds there", () => {
  const { ed, fire, down, move, arrow } = board()
  ed.setTool("arrow")
  down(50, 50)
  move(340, 60)
  fire("pointercancel", 0, 0)
  const a = arrow()
  assert.equal(ed.session, null)
  closePt(lineGeometry(a).end, 340, 60, "end")
  assert.deepEqual(a.props.endBinding, { targetId: "B", anchor: { u: 0.4, v: 0.6 } })
  assert.equal(a.props.startBinding.targetId, "A")
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

test("an endpoint handle drag released in empty space detaches only that end", () => {
  const { down, move, up, arrow, drawArrow } = board()
  const a = drawArrow(50, 50, 350, 50)
  assert.equal(a.props.endBinding.targetId, "B")
  down(350, 50)
  move(345, 50)
  move(500, 500)
  up(500, 500)
  const freed = arrow()
  assert.equal(freed.props.endBinding, null)
  closePt(lineGeometry(freed).end, 500, 500, "end")
  assert.deepEqual(freed.props.startBinding, a.props.startBinding)
  assert.equal(freed.props.startBinding.targetId, "A")
})

test("escape during an endpoint handle drag still binds to the rectangle under the pointer", () => {
  const { ed, down, move, escape, arrow, drawArrow } = board()
  const a = drawArrow(50, 50, 200, 50)
  assert.equal(a.props.startBinding.targetId, "A")
  down(200, 50)
  move(195, 50)
  move(340, 60)
  escape()
  assert.equal(ed.session, null)
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

const geo = (id, kind, x, y, w, h, z = 1) => ({
  id, typeName: "shape", type: "geo", x, y, rot: 0, z,
  props: { geo: kind, w, h, color: "black", size: "m", dash: "solid", fill: "none" },
})

function emptyBoard(...shapes) {
  const b = board()
  b.ed.store.remove(["A", "B"])
  b.ed.setTool("select")
  for (const s of shapes) b.ed.store.put(s)
  const dbl = (x, y) => b.ed.container.listeners.dblclick({
    type: "dblclick", target: b.ed.container, button: 0, clientX: x, clientY: y,
    shiftKey: false, altKey: false, preventDefault() {},
  })
  const type = (value) => {
    const ta = b.ed.editing.textarea
    ta.value = value
    ta.listeners.input()
    ta.listeners.blur()
  }
  const texts = () => b.ed.store.shapes().filter((s) => s.type === "text")
  return { ...b, dbl, type, texts }
}

test("double-click inside an empty unfilled rectangle edits its own label", () => {
  const { ed, dbl, type, texts } = emptyBoard(geo("R", "rectangle", 100, 100, 200, 100))
  dbl(200, 150)
  assert.equal(ed.editing.id, "R")
  assert.equal(ed.editing.field, "label")
  assert.deepEqual([...ed.selection], ["R"])
  assert.equal(ed.editing.textarea.style.width, "184px")
  assert.equal(ed.editing.textarea.style.height, "84px")
  type("hello")
  assert.equal(ed.store.get("R").props.label, "hello")
  assert.equal(texts().length, 0)
})

test("double-click inside an empty unfilled ellipse edits its own label", () => {
  const { ed, dbl, type, texts } = emptyBoard(geo("E", "ellipse", 100, 100, 200, 120))
  dbl(200, 160)
  assert.equal(ed.editing.id, "E")
  assert.equal(ed.editing.field, "label")
  type("round")
  assert.equal(ed.store.get("E").props.label, "round")
  assert.equal(texts().length, 0)
})

test("a label added by double-click moves with its rectangle", () => {
  const { ed, dbl, type, drag, texts } = emptyBoard(geo("R", "rectangle", 100, 100, 200, 100))
  dbl(200, 150)
  type("carried")
  drag(150, 100, 200, 70)
  const moved = ed.store.get("R")
  assert.equal(moved.x, 150)
  assert.equal(moved.y, 70)
  assert.equal(moved.props.label, "carried")
  assert.equal(texts().length, 0)
})

test("double-click inside a triangle edits its label while its bounding-box corner starts standalone text", () => {
  const { ed, dbl, type, texts } = emptyBoard(geo("T", "triangle", 100, 100, 200, 200))
  dbl(200, 250)
  assert.equal(ed.editing.id, "T")
  assert.equal(ed.editing.field, "label")
  type("tri")
  assert.equal(ed.store.get("T").props.label, "tri")
  dbl(110, 110)
  assert.equal(texts().length, 1)
  assert.equal(ed.editing.field, "text")
  assert.notEqual(ed.editing.id, "T")
})

test("double-click in an ellipse's bounding-box corner starts standalone text", () => {
  const { ed, dbl, texts } = emptyBoard(geo("E", "ellipse", 100, 100, 200, 200))
  dbl(110, 110)
  assert.equal(texts().length, 1)
  assert.equal(ed.editing.id, texts()[0].id)
  assert.equal(ed.editing.field, "text")
  assert.equal(ed.store.get("E").props.label, undefined)
})

test("double-click on blank canvas starts standalone text", () => {
  const { ed, dbl, texts } = emptyBoard(geo("R", "rectangle", 100, 100, 200, 100))
  dbl(600, 400)
  assert.equal(texts().length, 1)
  assert.equal(ed.editing.id, texts()[0].id)
  assert.equal(ed.editing.field, "text")
})

test("double-click in overlapping empty rectangles edits the topmost one", () => {
  const { ed, dbl } = emptyBoard(geo("low", "rectangle", 100, 100, 200, 200, 1), geo("high", "rectangle", 200, 200, 200, 200, 2))
  dbl(250, 250)
  assert.equal(ed.editing.id, "high")
  ed._commitText()
  dbl(150, 150)
  assert.equal(ed.editing.id, "low")
})

test("double-click on text inside an empty rectangle still edits that text", () => {
  const { ed, dbl, texts } = emptyBoard(geo("R", "rectangle", 0, 0, 400, 300, 1), text("T", 100, 100, "hi"))
  dbl(105, 110)
  assert.equal(ed.editing.id, "T")
  assert.equal(ed.editing.field, "text")
  assert.equal(texts().length, 1)
})

test("single click inside an empty unfilled rectangle still selects nothing", () => {
  const { ed, down, up } = emptyBoard(geo("R", "rectangle", 100, 100, 200, 100))
  down(200, 150)
  up(200, 150)
  assert.equal(ed.selection.size, 0)
  assert.equal(ed.editing, null)
  down(100, 150)
  up(100, 150)
  assert.deepEqual([...ed.selection], ["R"])
})

test("hitTest ignores the interior of an unfilled rectangle", () => {
  const { ed } = emptyBoard(geo("R", "rectangle", 100, 100, 200, 100))
  assert.equal(ed.hitTest(200, 150), null)
  assert.equal(ed.hitTest(100, 150).id, "R")
})

import assert from "node:assert/strict"
import { readFile } from "node:fs/promises"
import test from "node:test"

const modulePath = new URL("../../web/quickdraw/save_status.js", import.meta.url)
const source = await readFile(modulePath, "utf8")
const { createSaveStatus, parseSnapshot, withBlankWholeBoard } = await import(
  `data:text/javascript;base64,${Buffer.from(source).toString("base64")}`
)

function deferred() {
  let resolve
  let reject
  const promise = new Promise((onResolve, onReject) => {
    resolve = onResolve
    reject = onReject
  })
  return { promise, reject, resolve }
}

function harness() {
  const states = []
  const errors = []
  let clears = 0
  const status = createSaveStatus({
    render: (state) => states.push(state),
    showError: (message) => errors.push(message),
    clearError: () => {
      clears += 1
    },
  })
  return { errors, get clears() { return clears }, states, status }
}

test("accepts plain object snapshots and rejects invalid responses", () => {
  const snapshot = { document: { store: {} } }
  assert.equal(parseSnapshot(snapshot), snapshot)
  for (const value of [null, [], "snapshot", 1]) {
    assert.throws(() => parseSnapshot(value), /invalid/i)
  }
})

test("starts saved and only user changes mark the document unsaved", () => {
  const view = harness()
  view.status.initializeSaved()
  view.status.markChanged("remote")
  view.status.markChanged("user")
  assert.deepEqual(view.states, ["saved", "unsaved"])
  assert.equal(view.clears, 2)
})

test("moves through saving and saved with a paired queue-head capture", async () => {
  const view = harness()
  const sent = []
  view.status.initializeSaved()
  const result = await view.status.save(
    async () => ({ png: "png-1", snapshot: { revision: 1 } }),
    async (payload) => sent.push(payload),
  )
  assert.equal(result, true)
  assert.deepEqual(sent, [{ png: "png-1", snapshot: { revision: 1 } }])
  assert.deepEqual(view.states, ["saved", "saving", "saved"])
})

test("an edit during save stays unsaved after the older request succeeds", async () => {
  const view = harness()
  const request = deferred()
  const saving = view.status.save(
    async () => ({ png: "old-png", snapshot: { revision: 1 } }),
    async () => request.promise,
  )
  await Promise.resolve()
  view.status.markChanged("user")
  request.resolve()
  await saving
  assert.equal(view.states.at(-1), "unsaved")
})

test("serializes queue-head captures and persists the newest paired payload", async () => {
  const view = harness()
  const firstRequest = deferred()
  const secondRequest = deferred()
  const captures = []
  const persisted = []
  let document = 1

  const first = view.status.save(
    async () => {
      captures.push(document)
      return { png: `png-${document}`, snapshot: { revision: document } }
    },
    async (payload) => {
      persisted.push(payload)
      await firstRequest.promise
    },
  )
  await Promise.resolve()

  const second = view.status.save(
    async () => {
      captures.push(document)
      return { png: `png-${document}`, snapshot: { revision: document } }
    },
    async (payload) => {
      persisted.push(payload)
      await secondRequest.promise
    },
  )
  document = 2
  view.status.markChanged("user")

  assert.deepEqual(captures, [1])
  firstRequest.resolve()
  assert.equal(await first, true)
  await Promise.resolve()
  assert.deepEqual(captures, [1, 2])
  assert.equal(view.states.at(-1), "unsaved")

  secondRequest.resolve()
  assert.equal(await second, true)
  assert.deepEqual(persisted.at(-1), { png: "png-2", snapshot: { revision: 2 } })
  assert.equal(view.states.at(-1), "saved")
})

test("stale failures cannot replace the newest status or error", async () => {
  const view = harness()
  const firstRequest = deferred()
  const first = view.status.save(
    async () => ({ png: "png-1", snapshot: { revision: 1 } }),
    async () => firstRequest.promise,
  )
  await Promise.resolve()
  const second = view.status.save(
    async () => ({ png: "png-2", snapshot: { revision: 2 } }),
    async () => {},
  )
  firstRequest.reject(new Error("old failure"))
  assert.equal(await first, false)
  assert.equal(await second, true)
  assert.deepEqual(view.errors, [])
  assert.equal(view.states.at(-1), "saved")
})

test("latest failure shows an error and the next edit clears it", async () => {
  const view = harness()
  const result = await view.status.save(
    async () => ({ png: "png", snapshot: {} }),
    async () => {
      throw new Error("network")
    },
  )
  assert.equal(result, false)
  assert.equal(view.states.at(-1), "failed")
  assert.deepEqual(view.errors, ["Unable to save the drawing."])
  view.status.markChanged("user")
  assert.equal(view.states.at(-1), "unsaved")
  assert.equal(view.clears, 1)
})

test("uses the blank fallback only for empty whole-board exports", async () => {
  const calls = []
  const blank = { type: "image/png" }
  const exportImage = withBlankWholeBoard(
    async (options) => {
      calls.push(options)
      return null
    },
    async () => blank,
  )
  assert.equal(await exportImage({ background: true }), blank)
  assert.equal(await exportImage({ ids: new Set(["shape"]) }), null)
  assert.equal(calls.length, 2)
})

test("status markup exposes every state through a polite textual live region", async () => {
  const html = await readFile(new URL("../../web/quickdraw/index.html", import.meta.url), "utf8")
  const app = await readFile(new URL("../../web/quickdraw/app.js", import.meta.url), "utf8")
  assert.match(html, /<main id="board"[^>]*>[\s\S]*id="save-status"/)
  assert.match(html, /id="save-status"[^>]*role="status"/)
  assert.match(html, /id="save-status"[^>]*aria-live="polite"/)
  for (const label of ["Saved", "Unsaved", "Saving…", "Save failed"]) {
    assert.match(app, new RegExp(`: "${label}"`))
  }
})

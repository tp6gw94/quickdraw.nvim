import { createQuickdraw } from "./vendor/@quickdrawjs/core/src/index.js"
import { assetImage } from "./vendor/@quickdrawjs/core/src/shapes.js"
import { createSaveStatus, parseSnapshot, withBlankWholeBoard } from "./save_status.js"

const boardElement = document.getElementById("board")
const errorElement = document.getElementById("error")
const statusElement = document.getElementById("save-status")
const STATUS_TEXT = {
  failed: "Save failed",
  saved: "Saved",
  saving: "Saving…",
  unsaved: "Unsaved",
}
let blankPng

function showError(message) {
  errorElement.textContent = message
  errorElement.hidden = false
}

function clearError() {
  errorElement.textContent = ""
  errorElement.hidden = true
}

function renderStatus(state) {
  statusElement.dataset.state = state
  statusElement.textContent = STATUS_TEXT[state]
  statusElement.hidden = false
}

const saveStatus = createSaveStatus({ render: renderStatus, showError, clearError })

async function loadBlankPng() {
  if (!blankPng) {
    blankPng = fetch("./blank.png")
      .then((response) => {
        if (!response.ok) throw new Error("blank PNG request failed")
        return response.blob()
      })
      .catch((error) => {
        blankPng = undefined
        throw error
      })
  }
  return blankPng
}

async function waitForImages(board) {
  const store = board.editor.store
  const assetIds = store
    .shapes()
    .filter((shape) => shape.type === "image" && shape.props.assetId && store.asset(shape.props.assetId))
    .map((shape) => shape.props.assetId)

  for (let frame = 0; frame < 120; frame += 1) {
    if (assetIds.every((assetId) => assetImage(store, assetId))) return
    await new Promise(requestAnimationFrame)
  }
  throw new Error("drawing images could not be prepared")
}

async function captureDrawing(board, background) {
  await waitForImages(board)
  const snapshot = board.editor.store.getSnapshot()
  const png = await board.editor.exportImage({ background })
  if (!png) throw new Error("drawing export failed")
  return { png, snapshot }
}

async function sendDrawing({ png, snapshot }) {
  const form = new FormData()
  form.append("snapshot", new Blob([JSON.stringify(snapshot)], { type: "application/json" }), "snapshot.json")
  form.append("png", png, "drawing.png")
  const response = await fetch("./api/save", {
    method: "POST",
    body: form,
    headers: { Accept: "application/json" },
  })
  if (!response.ok) throw new Error("save request failed")
}

async function loadSnapshot() {
  try {
    const response = await fetch("./api/snapshot", {
      headers: { Accept: "application/json" },
    })
    if (!response.ok) throw new Error("snapshot request failed")

    const snapshot = parseSnapshot(await response.json())
    let board
    board = createQuickdraw({
      container: boardElement,
      grid: "lines",
      theme: "light",
      onSave: (_blob, background) =>
        saveStatus.save(() => captureDrawing(board, background), sendDrawing),
    })
    const exportImage = board.editor.exportImage.bind(board.editor)
    board.editor.exportImage = withBlankWholeBoard(exportImage, loadBlankPng)
    board.editor.store.loadSnapshot(snapshot, "remote")
    board.editor.fitContent()
    board.editor.store.listen(() => saveStatus.markChanged("user"), { source: "user" })
    saveStatus.initializeSaved()
  } catch (_error) {
    showError("Unable to load the drawing.")
  }
}

loadSnapshot()

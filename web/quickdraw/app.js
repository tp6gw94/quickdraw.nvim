import { createQuickdraw } from "./vendor/@quickdrawjs/core/src/index.js"

const boardElement = document.getElementById("board")
const errorElement = document.getElementById("error")

function showError(message) {
  errorElement.textContent = message
  errorElement.hidden = false
}

function clearError() {
  errorElement.textContent = ""
  errorElement.hidden = true
}

async function saveDrawing(blob, board) {
  try {
    const form = new FormData()
    form.append(
      "snapshot",
      new Blob([JSON.stringify(board.editor.store.getSnapshot())], { type: "application/json" }),
      "snapshot.json",
    )
    form.append("png", blob, "drawing.png")
    const response = await fetch("./api/save", {
      method: "POST",
      body: form,
      headers: { Accept: "application/json" },
    })
    if (!response.ok) throw new Error("save request failed")
    clearError()
  } catch (_error) {
    showError("Unable to save the drawing.")
  }
}

async function loadSnapshot() {
  try {
    const response = await fetch("./api/snapshot", {
      headers: { Accept: "application/json" },
    })
    if (!response.ok) throw new Error("snapshot request failed")

    const snapshot = await response.json()
    if (!snapshot || typeof snapshot !== "object" || Array.isArray(snapshot)) {
      throw new Error("snapshot response is invalid")
    }

    let board
    board = createQuickdraw({
      container: boardElement,
      grid: "lines",
      theme: "light",
      onSave: (blob) => saveDrawing(blob, board),
    })
    board.editor.store.loadSnapshot(snapshot, "remote")
    board.editor.fitContent()
  } catch (_error) {
    showError("Unable to load the drawing.")
  }
}

loadSnapshot()

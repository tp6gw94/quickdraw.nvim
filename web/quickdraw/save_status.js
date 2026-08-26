const SAVE_ERROR = "Unable to save the drawing."

export function parseSnapshot(value) {
  if (!value || typeof value !== "object" || Array.isArray(value)) {
    throw new Error("snapshot response is invalid")
  }
  return value
}

export function withBlankWholeBoard(exportImage, loadBlank) {
  return async (options = {}) => {
    const blob = await exportImage(options)
    if (blob || options.ids != null) return blob
    return loadBlank()
  }
}

export function createSaveStatus({ render, showError, clearError }) {
  let revision = 0
  let latestAttempt = 0
  let queue = Promise.resolve()
  let state

  const setState = (nextState) => {
    if (state === nextState) return
    state = nextState
    render(nextState)
  }

  const initializeSaved = () => {
    clearError()
    setState("saved")
  }

  const markChanged = (source) => {
    if (source !== "user") return
    revision += 1
    clearError()
    setState("unsaved")
  }

  const save = (capture, request) => {
    const attempt = ++latestAttempt
    const intentRevision = revision
    setState("saving")

    const run = queue.then(async () => {
      const capturedRevision = revision
      if (attempt === latestAttempt && revision === intentRevision) setState("saving")

      try {
        const payload = await capture()
        await request(payload)
      } catch (_error) {
        if (attempt === latestAttempt) {
          setState("failed")
          showError(SAVE_ERROR)
        }
        return false
      }

      if (attempt === latestAttempt) {
        if (revision === capturedRevision) {
          clearError()
          setState("saved")
        } else {
          setState("unsaved")
        }
      }
      return true
    })

    queue = run.then(() => undefined)
    return run
  }

  return { initializeSaved, markChanged, save }
}

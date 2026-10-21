const noop = () => {}
const measure = { measureText: (t) => ({ width: t.length * 8, fontBoundingBoxAscent: 10, fontBoundingBoxDescent: 3 }) }

export const elem = () => ({
  classList: { add: noop, remove: noop, toggle: noop },
  style: {},
  dataset: {},
  listeners: {},
  addEventListener(ev, fn) { this.listeners[ev] = fn },
  removeEventListener: noop,
  prepend: noop,
  appendChild: noop,
  after: noop,
  remove: noop,
  focus: noop,
  setPointerCapture: noop,
  getBoundingClientRect: () => ({ left: 0, top: 0, width: 800, height: 600 }),
  clientWidth: 800,
  clientHeight: 600,
  getContext: () => measure,
})

globalThis.document = { createElement: elem, fonts: undefined }
globalThis.window = { devicePixelRatio: 1, matchMedia: () => ({ matches: true }) }
globalThis.ResizeObserver = class { observe() {} disconnect() {} }
globalThis.requestAnimationFrame = () => 1
globalThis.cancelAnimationFrame = noop

import Foundation

/// The JavaScript a web wallpaper runs under, and the small native-facing
/// protocol it shares with `WebWallpaperView`.
///
/// The compatibility layer mirrors what Wallpaper Engine's Chromium host gives an
/// author page, in the order the macOS app already proved out: file-request fixes,
/// `requestIdleCallback`, the author API (`wallpaperPropertyListener`), audio
/// listener delivery (128 bins: 64 left then 64 right), random-file requests,
/// pause notifications, and a frame-rate limit on `requestAnimationFrame`.
///
/// It is deliberately a plain value type with no WebKit import: the web view
/// turns these sources into `WKUserScript`s, and the scripts can be executed
/// against a DOM shim in a test harness without a device.
enum WebWallpaperScript {
  /// The single page-to-host channel. Everything the page may ask for arrives
  /// here, so there is exactly one place that has to distrust it.
  static let messageHandlerName = "wmWallpaper"

  struct Seed: Equatable {
    /// Wrap `requestAnimationFrame` to enforce `frameLimit`.
    var framePacing = false
    /// Callbacks per second, 0 for the display's own cadence.
    var frameLimit = 0
    /// Multiplies `window.devicePixelRatio`; 1 leaves WebKit's own property.
    var renderScale = 1.0
  }

  /// One script and where WebKit must inject it.
  struct Injection: Equatable {
    var source: String
    var forMainFrameOnly: Bool
    /// All scripts here go in at document start, before the author's own scripts.
    var atDocumentStart: Bool { true }
  }

  static func injections(seed: Seed) -> [Injection] {
    [
      Injection(source: compatScript, forMainFrameOnly: false),
      Injection(source: idleCallbacksScript, forMainFrameOnly: false),
      Injection(source: interactionScript, forMainFrameOnly: false),
      Injection(source: audioOutputScript, forMainFrameOnly: false),
      Injection(source: hostScript(seed: seed), forMainFrameOnly: true),
    ]
  }

  /// `hostScriptSource` called with the seed. Only numbers and booleans are
  /// interpolated.
  static func hostScript(seed: Seed) -> String {
    """
    \(hostScriptSource)({ framePacing: \(seed.framePacing), frameLimit: \(seed.frameLimit), \
    renderScale: \(clampedRenderScale(seed.renderScale)) })
    """
  }

  /// The page's internal render scale is clamped to the same range the desktop
  /// web host uses: half resolution is the floor for text and interface.
  static let renderScaleRange: ClosedRange<Double> = 0.5...1

  static func clampedRenderScale(_ scale: Double) -> Double {
    guard scale.isFinite else { return renderScaleRange.upperBound }
    return min(max(scale, renderScaleRange.lowerBound), renderScaleRange.upperBound)
  }

  // MARK: - File requests

  /// WebKit resolves `fetch()` of a project file with status 0 and no headers,
  /// where Chromium answers like a server. Loaders that check `response.ok`, and
  /// `WebAssembly.instantiateStreaming`, fail without the fix. Only a `file:`
  /// GET or HEAD is rewritten, and only its status, status text and headers:
  /// the body stream is passed through, never buffered.
  static let compatScript = """
  (() => {
    if (window.__mweFileCompat) return;
    Object.defineProperty(window, "__mweFileCompat", { value: true });
    if (location.protocol === "http:" || location.protocol === "https:") return;
    const nativeFetch = window.fetch;
    if (typeof nativeFetch === "function" && typeof Response === "function") {
      const FILE_TYPES = {
        html: "text/html", htm: "text/html", js: "text/javascript", mjs: "text/javascript",
        css: "text/css", json: "application/json", wasm: "application/wasm", txt: "text/plain",
        xml: "text/xml", svg: "image/svg+xml", png: "image/png", jpg: "image/jpeg",
        jpeg: "image/jpeg", gif: "image/gif", webp: "image/webp", avif: "image/avif",
        bmp: "image/bmp", ico: "image/x-icon", mp3: "audio/mpeg", wav: "audio/wav",
        ogg: "audio/ogg", oga: "audio/ogg", m4a: "audio/mp4", flac: "audio/flac",
        mp4: "video/mp4", m4v: "video/mp4", webm: "video/webm", ogv: "video/ogg",
        woff: "font/woff", woff2: "font/woff2", ttf: "font/ttf", otf: "font/otf",
      };
      const fileType = url => {
        const path = url.split(/[?#]/)[0];
        const dot = path.lastIndexOf(".");
        return dot > path.lastIndexOf("/") ? FILE_TYPES[path.slice(dot + 1).toLowerCase()] : undefined;
      };
      const served = new WeakSet();
      const asFetched = (response, url, redirected) => {
        served.add(response);
        return Object.defineProperties(response, {
          url: { value: url, enumerable: true },
          type: { value: "basic", enumerable: true },
          redirected: { value: redirected, enumerable: true },
          clone: { configurable: true, writable: true,
            value() { return asFetched(Response.prototype.clone.call(this), url, redirected); } },
        });
      };
      const asServed = response => {
        if (response.status !== 0 || response.type !== "basic" || !response.url.startsWith("file:")) return response;
        const headers = new Headers();
        const type = fileType(response.url);
        if (type) headers.set("Content-Type", type);
        return asFetched(new Response(response.body, { status: 200, statusText: "OK", headers }),
          response.url, response.redirected);
      };
      window.fetch = function fetch(input, init) {
        const pending = nativeFetch.apply(this, arguments);
        const method = String((init && init.method) || (input instanceof Request ? input.method : "GET")).toUpperCase();
        return method === "GET" || method === "HEAD" ? pending.then(asServed) : pending;
      };
      const wasm = typeof WebAssembly === "object" ? WebAssembly : null;
      const wrapStreaming = (name, fromBytes) => {
        const native = wasm && wasm[name];
        if (typeof native !== "function") return;
        wasm[name] = async function (source, ...rest) {
          const response = await source;
          if (!served.has(response) || response.status !== 200 || response.bodyUsed
              || response.headers.get("Content-Type") !== "application/wasm") {
            return native.call(this, response, ...rest);
          }
          return fromBytes(await response.arrayBuffer(), ...rest);
        };
      };
      const compile = wasm && wasm.compile, instantiate = wasm && wasm.instantiate;
      wrapStreaming("compileStreaming", bytes => compile.call(wasm, bytes));
      wrapStreaming("instantiateStreaming", (bytes, imports) => instantiate.call(wasm, bytes, imports));
    }
    if (typeof XMLHttpRequest === "function") {
      const prototype = XMLHttpRequest.prototype;
      const status = Object.getOwnPropertyDescriptor(prototype, "status");
      const statusText = Object.getOwnPropertyDescriptor(prototype, "statusText");
      const responseURL = Object.getOwnPropertyDescriptor(prototype, "responseURL").get;
      const isServedFile = xhr => status.get.call(xhr) === 0
        && responseURL.call(xhr).startsWith("file:");
      Object.defineProperties(prototype, {
        status: { ...status, get() { return isServedFile(this) ? 200 : status.get.call(this); } },
        statusText: { ...statusText, get() { return isServedFile(this) ? "OK" : statusText.get.call(this); } },
      });
    }
  })()
  """

  // MARK: - Idle callbacks

  /// Chromium has `requestIdleCallback`; WebKit does not, and Wallpaper Engine
  /// pages call it without guarding. A 50 ms idle period follows the spec's
  /// model; a callback queued from inside a period waits for the next one.
  static let idleCallbacksScript = """
  (() => {
    if (typeof window.requestIdleCallback === "function") return;
    const IDLE_PERIOD_MS = 50;
    const setTimer = window.setTimeout.bind(window);
    const clearTimer = window.clearTimeout.bind(window);
    const now = () => performance.now();
    const report = error => {
      try { window.reportError(error); } catch (unavailable) { setTimer(() => { throw error; }, 0); }
    };
    const waiting = new Map();
    let lastHandle = 0;
    let periodTimer = null;
    let periodEnd = 0;
    const invoke = (callback, deadline, didTimeout) => {
      const idleDeadline = Object.freeze({
        didTimeout,
        timeRemaining: () => Math.max(0, deadline - now()),
      });
      try { callback(idleDeadline); } catch (error) { report(error); }
    };
    const runPeriod = () => {
      periodTimer = null;
      periodEnd = now() + IDLE_PERIOD_MS;
      for (const handle of Array.from(waiting.keys())) {
        if (now() >= periodEnd) break;
        const entry = waiting.get(handle);
        if (!entry) continue;
        waiting.delete(handle);
        if (entry.timer !== null) clearTimer(entry.timer);
        invoke(entry.callback, periodEnd, false);
      }
      schedulePeriod();
    };
    const schedulePeriod = () => {
      if (periodTimer !== null || waiting.size === 0) return;
      periodTimer = setTimer(runPeriod, Math.max(0, periodEnd - now()));
    };
    window.requestIdleCallback = function requestIdleCallback(callback, options) {
      if (typeof callback !== "function") {
        throw new TypeError("requestIdleCallback: parameter 1 is not of type 'Function'.");
      }
      const handle = ++lastHandle;
      const timeout = Number(options && options.timeout);
      const entry = { callback, timer: null };
      if (timeout > 0) {
        entry.timer = setTimer(() => {
          if (waiting.get(handle) !== entry) return;
          waiting.delete(handle);
          invoke(callback, 0, true);
        }, timeout);
      }
      waiting.set(handle, entry);
      schedulePeriod();
      return handle;
    };
    window.cancelIdleCallback = function cancelIdleCallback(handle) {
      const entry = waiting.get(Number(handle));
      if (!entry) return;
      waiting.delete(Number(handle));
      if (entry.timer !== null) clearTimer(entry.timer);
    };
  })()
  """

  // MARK: - Interaction

  /// A wallpaper has no context menu, no drag-and-drop and no selection. The
  /// touch itself stays with the page, so canvas interaction keeps working.
  static let interactionScript = """
  (() => {
    const stop = event => event.preventDefault();
    window.addEventListener("contextmenu", stop, true);
    window.addEventListener("dragstart", stop, true);
    window.addEventListener("selectstart", stop, true);
    const installStyle = () => {
      if (!document.head) return;
      const style = document.createElement("style");
      style.textContent = "html, body { -webkit-user-select: none; -webkit-touch-callout: none; -webkit-tap-highlight-color: transparent; }";
      document.head.appendChild(style);
    };
    if (document.head) installStyle();
    else document.addEventListener("DOMContentLoaded", installStyle, { once: true });
  })()
  """

  // MARK: - Audio output

  /// Page output volume. iOS has no public `WKWebView` media-volume control, so
  /// this routes `<video>`/`<audio>` through a per-element volume wrapper and
  /// WebAudio through a master `GainNode` at each context's destination.
  ///
  /// The page's own per-element volume is preserved (the wrapper multiplies it
  /// with the host volume). Audio whose graph never connects to
  /// `AudioContext.destination` through `AudioNode.connect` (for example an
  /// `AudioWorklet` writing straight to a destination it obtained another way)
  /// is not covered; that limit is reported, not hidden.
  static let audioOutputScript = """
  (() => {
    if (window.__wmAudioOutput) return;
    const state = { volume: 1, muted: false };
    const clamp = value => Number.isFinite(value) ? Math.min(1, Math.max(0, value)) : 1;
    const contexts = [];
    const supported = typeof window.AudioNode === "function" && typeof window.AudioContext === "function";
    const nativeConnect = supported ? AudioNode.prototype.connect : null;
    if (nativeConnect) {
      AudioNode.prototype.connect = function connect(destination, ...rest) {
        try {
          if (destination === this.context.destination) {
            let route = contexts.find(entry => entry.context === this.context);
            if (!route) {
              const gain = this.context.createGain();
              gain.gain.value = state.muted ? 0 : state.volume;
              nativeConnect.call(gain, this.context.destination);
              route = { context: this.context, gain };
              contexts.push(route);
            }
            return nativeConnect.call(this, route.gain, ...rest);
          }
        } catch (error) {
          console.error("wallpaper audio routing failed", error);
        }
        return nativeConnect.call(this, destination, ...rest);
      };
    }
    const appliers = new Map();
    const trackable = typeof window.HTMLMediaElement === "function"
      && !!Object.getOwnPropertyDescriptor(HTMLMediaElement.prototype, "volume")
      && !!Object.getOwnPropertyDescriptor(HTMLMediaElement.prototype, "muted");
    const track = element => {
      if (!trackable || !(element instanceof HTMLMediaElement) || appliers.has(element)) return;
      const descriptor = Object.getOwnPropertyDescriptor(HTMLMediaElement.prototype, "volume");
      const mutedDescriptor = Object.getOwnPropertyDescriptor(HTMLMediaElement.prototype, "muted");
      let pageVolume = descriptor.get.call(element);
      let pageMuted = mutedDescriptor.get.call(element);
      const apply = () => {
        try {
          const scaled = clamp(pageVolume) * state.volume;
          descriptor.set.call(element, state.muted ? 0 : scaled);
          mutedDescriptor.set.call(element, pageMuted || state.muted);
        } catch (error) {
          console.error("wallpaper audio element update failed", error);
        }
      };
      try {
        Object.defineProperty(element, "volume", {
          configurable: true,
          get() { return pageVolume; },
          set(value) {
            const next = Number(value);
            if (!Number.isFinite(next)) return;
            pageVolume = clamp(next);
            apply();
          },
        });
        Object.defineProperty(element, "muted", {
          configurable: true,
          get() { return pageMuted; },
          set(value) { pageMuted = !!value; apply(); },
        });
      } catch (error) {
        console.error("wallpaper audio element hook failed", error);
      }
      appliers.set(element, apply);
      apply();
    };
    const scan = () => {
      if (!document.querySelectorAll) return;
      for (const element of document.querySelectorAll("video, audio")) track(element);
    };
    const start = () => {
      scan();
      document.addEventListener("play", event => track(event.target), true);
      document.addEventListener("loadedmetadata", event => track(event.target), true);
      if (window.MutationObserver && document.documentElement) {
        new MutationObserver(scan).observe(document.documentElement, { childList: true, subtree: true });
      }
    };
    if (document.readyState === "loading") document.addEventListener("DOMContentLoaded", start, { once: true });
    else start();
    Object.defineProperty(window, "__wmAudioOutput", {
      value: Object.freeze({
        set(volume, muted) {
          state.volume = clamp(Number(volume));
          state.muted = !!muted;
          for (const route of contexts) {
            try {
              route.gain.gain.setTargetAtTime(state.muted ? 0 : state.volume, route.context.currentTime, 0.01);
            } catch (error) {
              route.gain.gain.value = state.muted ? 0 : state.volume;
            }
          }
          for (const apply of appliers.values()) apply();
          return {
            installed: true,
            mediaElements: trackable,
            webAudio: supported,
            contexts: contexts.length,
            elements: appliers.size,
          };
        },
      }),
    });
  })()
  """

  // MARK: - Frame pacer

  /// A `requestAnimationFrame` pacer: a callback runs on the first native frame
  /// at or after its slot and receives that frame's timestamp. At most one
  /// native request is outstanding, and paced ids start at 2^30 so a page that
  /// switches between native and paced requests can never cancel the wrong one.
  static let framePacerSource = """
  (nativeRequest, nativeCancel, reportError) => {
    const ID_BASE = 2 ** 30;
    const CEILING = 60;
    let limit = 0;
    let interval = 0;
    let queue = new Map();
    let running = null;
    let nativeHandle = null;
    let next = null;
    let sequence = 0;
    const isDue = timestamp => interval === 0 || next === null
      || timestamp >= next - Math.min(interval * 0.15, 4);
    const ensureNative = () => {
      if (nativeHandle === null && queue.size > 0) nativeHandle = nativeRequest(onNative);
    };
    const dispatch = timestamp => {
      if (interval > 0) {
        next = next === null || timestamp - next > interval ? timestamp + interval : next + interval;
      }
      const batch = queue;
      queue = new Map();
      running = batch;
      for (const callback of batch.values()) {
        try { callback(timestamp); } catch (error) { reportError(error); }
      }
      running = null;
    };
    const onNative = timestamp => {
      nativeHandle = null;
      if (queue.size === 0) return;
      if (isDue(timestamp)) dispatch(timestamp);
      ensureNative();
    };
    return {
      setLimit(hz) {
        const value = Number.isFinite(hz) && hz >= 1 && hz < CEILING ? hz : 0;
        if (value === limit) return;
        limit = value;
        interval = value > 0 ? 1000 / value : 0;
        next = null;
      },
      isPacing() { return limit > 0; },
      owns(id) { return id >= ID_BASE; },
      request(callback) {
        const id = ID_BASE + (++sequence);
        queue.set(id, callback);
        ensureNative();
        return id;
      },
      cancel(id) {
        if (!queue.delete(id) && running) running.delete(id);
        if (queue.size === 0 && nativeHandle !== null) {
          nativeCancel(nativeHandle);
          nativeHandle = null;
        }
      },
    };
  }
  """

  // MARK: - Host API

  private static let hostScriptSource = """
  (seed => {
    if (window.__mweWallpaperHost) return;
    const createFramePacer = \(framePacerSource);
    let pacer = null;
    if (seed.framePacing && typeof window.requestAnimationFrame === "function"
        && typeof window.cancelAnimationFrame === "function") {
      const nativeRequest = window.requestAnimationFrame.bind(window);
      const nativeCancel = window.cancelAnimationFrame.bind(window);
      pacer = createFramePacer(nativeRequest, nativeCancel, error => {
        try { window.reportError(error); } catch (unavailable) { setTimeout(() => { throw error; }, 0); }
      });
      pacer.setLimit(seed.frameLimit);
      const pacedRequest = function requestAnimationFrame(callback) {
        return typeof callback === "function" && pacer.isPacing()
          ? pacer.request(callback) : nativeRequest(...arguments);
      };
      const pacedCancel = function cancelAnimationFrame(handle) {
        const id = typeof handle === "number" || typeof handle === "string" ? Number(handle) : NaN;
        if (pacer.owns(id)) { pacer.cancel(id); return; }
        return nativeCancel(...arguments);
      };
      const replace = (names, wrapper) => {
        for (const name of names) if (typeof window[name] === "function") window[name] = wrapper;
      };
      replace(["requestAnimationFrame", "webkitRequestAnimationFrame"], pacedRequest);
      replace(["cancelAnimationFrame", "webkitCancelAnimationFrame", "webkitCancelRequestAnimationFrame"], pacedCancel);
    }
    const nativeRatio = Object.getOwnPropertyDescriptor(window, "devicePixelRatio");
    const nativeDispatch = EventTarget.prototype.dispatchEvent;
    const NativeEvent = Event;
    let renderScale = 1;
    let scaledRatio = null;
    let resizePending = false;
    const setScale = value => {
      if (!nativeRatio || !nativeRatio.configurable || typeof nativeRatio.get !== "function") return false;
      const next = Number.isFinite(value) ? Math.min(1, Math.max(0.5, value)) : 1;
      if (next === renderScale) return false;
      renderScale = next;
      if (next < 1 && !scaledRatio) {
        scaledRatio = Object.getOwnPropertyDescriptor({
          get devicePixelRatio() { return nativeRatio.get.call(window) * renderScale; },
        }, "devicePixelRatio").get;
        Object.defineProperty(window, "devicePixelRatio", {
          configurable: true, enumerable: nativeRatio.enumerable, get: scaledRatio, set: nativeRatio.set,
        });
      } else if (next === 1 && scaledRatio) {
        const current = Object.getOwnPropertyDescriptor(window, "devicePixelRatio");
        if (current && current.get === scaledRatio) Object.defineProperty(window, "devicePixelRatio", nativeRatio);
        scaledRatio = null;
      }
      return true;
    };
    setScale(seed.renderScale);
    const post = message => {
      try { window.webkit.messageHandlers.\(messageHandlerName).postMessage(message); }
      catch (error) { console.error("wallpaper host channel unavailable", error); }
    };
    let listener = null;
    let lastPaused = null;
    let pausedTakenIn = null;
    const directories = new Map();
    const filesTakenIn = new Map();
    const call = (name, ...args) => {
      if (listener && typeof listener[name] === "function") {
        try { listener[name](...args); return true; }
        catch (error) { console.error("wallpaperPropertyListener." + name + " failed", error); }
      }
      return false;
    };
    const canonical = value => {
      if (value === null || typeof value !== "object") return String(JSON.stringify(value));
      if (Array.isArray(value)) return "[" + value.map(canonical).join(",") + "]";
      return "{" + Object.keys(value).sort().map(key => JSON.stringify(key) + ":" + canonical(value[key])).join(",") + "}";
    };
    const propertySets = {
      applyUserProperties: { latest: null, delivered: null },
      applyGeneralProperties: { latest: null, delivered: null },
    };
    const deliverProperties = (name, properties) => {
      const set = propertySets[name];
      set.latest = properties;
      if (!listener || typeof listener[name] !== "function") return false;
      const source = properties !== null && typeof properties === "object" ? properties : {};
      const snapshot = new Map(Object.keys(source).map(key => [key, canonical(source[key])]));
      let payload = properties;
      if (set.delivered) {
        const changed = Object.keys(source).filter(key => set.delivered.get(key) !== snapshot.get(key));
        if (changed.length === 0) return false;
        payload = Object.fromEntries(changed.map(key => [key, source[key]]));
      }
      if (!call(name, payload)) return false;
      set.delivered = snapshot;
      return true;
    };
    const deliverPaused = () => {
      if (!call("setPaused", lastPaused)) return false;
      pausedTakenIn = lastPaused;
      return true;
    };
    const deliverDirectoryFiles = (property, files) => {
      if (!filesTakenIn.has(property)) filesTakenIn.set(property, new Set());
      const takenIn = filesTakenIn.get(property);
      const accepted = call("userDirectoryFilesAddedOrChanged", property, files);
      for (const file of files) accepted ? takenIn.add(file) : takenIn.delete(file);
      return accepted;
    };
    let replayQueued = false;
    let reassigned = false;
    const queueReplay = () => { replayQueued = true; queueMicrotask(replayOwed); };
    const replayOwed = () => {
      reassigned = false;
      let tookIn = false;
      try {
        for (const name of ["applyGeneralProperties", "applyUserProperties"]) {
          if (propertySets[name].latest && deliverProperties(name, propertySets[name].latest)) tookIn = true;
        }
        if (lastPaused !== null && lastPaused !== pausedTakenIn && deliverPaused()) tookIn = true;
        for (const [property, files] of directories) {
          const takenIn = filesTakenIn.get(property);
          const owed = files.filter(file => !(takenIn && takenIn.has(file)));
          if (owed.length && deliverDirectoryFiles(property, owed)) tookIn = true;
        }
      } finally {
        replayQueued = false;
      }
      if (reassigned && tookIn) queueReplay();
    };
    Object.defineProperty(window, "wallpaperPropertyListener", {
      configurable: true,
      get() { return listener; },
      set(value) {
        listener = value;
        if (replayQueued) reassigned = true;
        else queueReplay();
      },
    });
    window.addEventListener("contextmenu", event => event.preventDefault(), true);
    let audioListener = null;
    window.wallpaperRegisterAudioListener = value => {
      const next = typeof value === "function" ? value : null;
      const had = audioListener !== null;
      audioListener = next;
      if ((next !== null) !== had) post({ type: next ? "audioSubscribed" : "audioUnsubscribed" });
    };
    const MEDIA_SLOTS = ["status", "properties", "thumbnail", "playback", "timeline"];
    const mediaListeners = {};
    for (const slot of MEDIA_SLOTS) {
      mediaListeners[slot] = null;
      const name = "wallpaperRegisterMedia" + slot.charAt(0).toUpperCase() + slot.slice(1) + "Listener";
      window[name] = value => { mediaListeners[slot] = typeof value === "function" ? value : null; };
    }
    const PLAYING = 0, PAUSED = 1, STOPPED = 2;
    window.wallpaperMediaIntegration = Object.freeze({
      PLAYBACK_PLAYING: PLAYING, PLAYBACK_PAUSED: PAUSED, PLAYBACK_STOPPED: STOPPED,
      playback: Object.freeze({ PLAYING, PAUSED, STOPPED }),
    });
    let randomFileSequence = 0;
    const randomFileCallbacks = new Map();
    window.wallpaperRequestRandomFileForProperty = (property, callback) => {
      if (typeof property !== "string" || property === "" || typeof callback !== "function") return;
      const requestId = "r" + (++randomFileSequence);
      randomFileCallbacks.set(requestId, callback);
      post({ type: "randomFileRequest", requestId, propertyId: property });
    };
    window.__mweWallpaperHost = Object.freeze({
      applyUserProperties(properties) { deliverProperties("applyUserProperties", properties); },
      applyGeneralProperties(properties) { deliverProperties("applyGeneralProperties", properties); },
      setFrameLimit(limit) { if (pacer) pacer.setLimit(limit); },
      setRenderScale(scale) {
        if (!setScale(scale) || resizePending) return;
        resizePending = true;
        queueMicrotask(() => {
          resizePending = false;
          nativeDispatch.call(window, new NativeEvent("resize"));
        });
      },
      setPaused(paused) { lastPaused = !!paused; deliverPaused(); },
      deliverAudio(bins) {
        if (!audioListener || !Array.isArray(bins) || bins.length !== 128) return false;
        try { audioListener(bins); return true; }
        catch (error) { console.error("wallpaperRegisterAudioListener callback failed", error); return false; }
      },
      deliverRandomFile(requestId, property, filePath) {
        const callback = randomFileCallbacks.get(requestId);
        if (!callback) return;
        randomFileCallbacks.delete(requestId);
        try { callback(property, filePath); }
        catch (error) { console.error("wallpaperRequestRandomFileForProperty callback failed", error); }
      },
      userDirectoryFilesAddedOrChanged(property, files) {
        const known = directories.get(property) || [];
        directories.set(property, known.concat(files.filter(file => !known.includes(file))));
        deliverDirectoryFiles(property, files);
      },
      userDirectoryFilesRemoved(property, files) {
        const known = directories.get(property);
        if (known) directories.set(property, known.filter(file => !files.includes(file)));
        const takenIn = filesTakenIn.get(property);
        if (takenIn) for (const file of files) takenIn.delete(file);
        call("userDirectoryFilesRemoved", property, files);
      },
    });
  })
  """
}

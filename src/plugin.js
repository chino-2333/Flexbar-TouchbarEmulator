const { plugin, logger, pluginPath, resourcesPath } = require("@eniac/flexdesigner")
const { spawn } = require("node:child_process")
const path = require("node:path")

let helperProcess = null
let helperConfigKey = null
let helperQueue = Promise.resolve()

function helperExecutablePath() {
  return path.join(resourcesPath, "TouchBarBridgeHelper.app", "Contents", "MacOS", "TouchBarBridgeHelper")
}

async function stopHelper() {
  const child = helperProcess
  helperProcess = null
  helperConfigKey = null
  if (!child) return
  logger.info("Stopping Touch Bar bridge helper")
  await new Promise((resolve) => {
    let timer
    const finish = () => { clearTimeout(timer); resolve() }
    child.once("exit", finish)
    child.once("error", finish)
    timer = setTimeout(() => {
      try { child.kill("SIGKILL") } catch {}
      finish()
    }, 2000)
    try { child.kill("SIGTERM") } catch { finish() }
  })
}

async function applyHelperConfig(config) {
  if (!config || config.backend !== "bridge") {
    await stopHelper()
    return
  }
  const args = [
    "--url", config.url,
    "--width", String(config.width || 2170),
    "--height", String(config.height || 60),
    "--fps", String(config.fps || 60),
    "--hidden-stream",
    "--style", "3",
    "--mouse-dispatch", "service"
  ]
  const key = JSON.stringify(args)
  if (helperProcess && helperConfigKey === key) return
  await stopHelper()
  const helper = helperExecutablePath()
  logger.info("Starting Touch Bar hidden-stream helper:", helper)
  const child = spawn(helper, args, { stdio: ["ignore", "pipe", "pipe"] })
  helperProcess = child
  helperConfigKey = key
  child.stdout?.on("data", (data) => {
    const text = data.toString().trim()
    if (text) logger.info(`[TouchBarBridgeHelper stdout] ${text}`)
  })
  child.stderr?.on("data", (data) => {
    const text = data.toString().trim()
    if (text) logger.info(`[TouchBarBridgeHelper] ${text}`)
  })
  const clearCurrent = () => {
    if (helperProcess === child) { helperProcess = null; helperConfigKey = null }
  }
  child.on("exit", (code, signal) => {
    logger.info(`Touch Bar bridge helper exited: code=${code} signal=${signal}`)
    clearCurrent()
  })
  child.on("error", (error) => {
    logger.error("Touch Bar bridge helper failed:", error)
    clearCurrent()
  })
}

function startHelper(config) {
  helperQueue = helperQueue.then(() => applyHelperConfig(config)).catch((error) => {
    logger.error("Touch Bar helper lifecycle failed:", error)
  })
  return helperQueue
}

// SIGTERM is handled by the native helper so it can release a held service
// touch and dispose of its virtual display without touching the desktop mouse. Its parent watchdog
// also covers a plugin process killed without executing this hook.
process.once("exit", () => { try { helperProcess?.kill("SIGTERM") } catch {} })


/**
 * Called when a plugin key is loaded
 * @param {Object} payload alive key data
 * {
 *  serialNumber: '',
 *  keys: []
 * }
 */
plugin.on('plugin.alive', async (payload) => {
  logger.info('Plugin alive:', payload)

  let hasEmulator = false
  for (let key of payload.keys) {
    if (key.cid === 'com.chino.touchbaremulator.emulator') {
      const result = await plugin.transport.call("touchbar-tool", {
          serialNumber: payload.serialNumber,
          key: key,
          cmd: 'start'
      })
      await startHelper(result)
      hasEmulator = true
    }
  }

  if (!hasEmulator) {
    await startHelper(null)
    plugin.transport.call("touchbar-tool", {
        serialNumber: payload.serialNumber,
        cmd: 'stop'
    })
  }
})
// Connect to flexdesigner and start the plugin
plugin.start()

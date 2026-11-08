'use strict'
// LumeBox adapter; upstream AGPL-3.0 source and modifications: manifest.json.
const crypto = require('node:crypto')
const fs = require('node:fs')
const path = require('node:path')
const { AsyncLocalStorage } = require('node:async_hooks')
module.exports.start = async function start(config) {
  const upstream = require(config.upstreamPath)
  if (upstream.setDataRoot) upstream.setDataRoot(config.dataRoot || path.dirname(config.upstreamPath))
  const networkState = new AsyncLocalStorage()
  if (config.nativeNetwork && globalThis.catNativeDanmakuFetch) {
    upstream.setFetch(async (...args) => {
      const state = networkState.getStore()
      try {
        const result = await globalThis.catNativeDanmakuFetch(...args)
        if (result.status >= 400 && state) state.failed++
        return result
      } catch (error) {
        if (state) state.failed++
        throw error
      }
    })
  }
  const token = String(config.token || '')
  if (token.length < 32) throw new Error('Local danmaku token missing')
  const settingsFile = path.join(config.dataRoot || path.dirname(config.upstreamPath), "settings.json")
  const allowed = ["AI_BASE_URL","AI_MODEL","AI_API_KEY","TITLE_MAPPING_TABLE_URL","AUTO_MATCH_MAPPING_TABLE_URL"]
  let settings = {}
  try { settings = JSON.parse(fs.readFileSync(settingsFile, "utf8")) } catch {}
  const env = {
    TOKEN: token,
    SOURCE_ORDER: '360,douban,renren,hanjutv',
    PLATFORM_ORDER: 'qq,qiyi,youku,mgtv,bilibili',
    SEARCH_CACHE_MINUTES: '1', COMMENT_CACHE_MINUTES: '2',
    RATE_LIMIT_MAX_REQUESTS: '0',
    MAX_REQUESTS: '2',
    ADMIN_TOKEN: token,
    ...Object.fromEntries(allowed.filter(k => typeof settings[k] === 'string').map(k => [k, settings[k]])),
  }
  const equal = value => {
    const a = Buffer.from(value), b = Buffer.from(token)
    return a.length === b.length && crypto.timingSafeEqual(a, b)
  }
  const server = globalThis.catServerFactory(async (req, res) => {
    const url = new URL(req.url, 'http://127.0.0.1')
    const parts = url.pathname.split('/')
    if (!equal(parts[1] || '')) { res.writeHead(403); res.end(); return }
    const route = '/' + parts.slice(2).join('/')
    const read = req.method === 'GET' && /^\/api\/v2\/(?:search\/episodes|bangumi\/[^/]+|comment(?:\/[^/]+)?|favorite\/list)$/.test(route)
    const write = req.method === 'POST' && /^\/api\/v2\/(?:match|segmentcomment|favorite\/(?:add|refresh|remove))$/.test(route)
    let body = ''
    if (req.method === 'POST') {
      for await (const chunk of req) {
        body += chunk
        if (Buffer.byteLength(body) > 128 * 1024) { res.writeHead(413); res.end(); return }
      }
    }
    if (route === '/_settings' && ['GET','POST'].includes(req.method)) {
      try {
        if (req.method === 'POST') {
          const input = JSON.parse(body)
          for (const key of allowed) if (typeof input[key] === 'string') env[key] = input[key].trim()
          fs.writeFileSync(settingsFile, JSON.stringify(Object.fromEntries(allowed.filter(k=>env[k]).map(k=>[k,env[k]]))), {mode:0o600})
          upstream.reset?.()
        }
        res.writeHead(200, {'content-type':'application/json'})
        res.end(JSON.stringify({...Object.fromEntries(allowed.filter(k=>k!=='AI_API_KEY').map(k=>[k,env[k]||''])),hasAiKey:!!env.AI_API_KEY})); return
      } catch { res.writeHead(400); res.end(); return }
    }
    if (route === '/_health') {
      res.writeHead(200, { 'content-type': 'application/json' })
      res.end(JSON.stringify({ok:true,service:'local-danmaku',version:upstream.version})); return
    }
    // No upstream admin UI, file upload, arbitrary URL proxy or config writes.
    if (!read && !write) {
      res.writeHead(404); res.end(); return
    }
    try {
      const state = { failed: 0 }
      const result = await networkState.run(state, () => upstream.handle('http://127.0.0.1' + url.pathname + url.search, env, req.method, body || undefined))
      const bytes = Buffer.from(await result.arrayBuffer())
      if (res.destroyed) return
      // Upstream sometimes suppresses platform errors and returns success + [].
      // Do not present a proxy/network failure as a genuine empty catalogue.
      if (result.status === 200 && state.failed > 0) {
        let data
        try { data = JSON.parse(bytes.toString('utf8')) } catch (_) {}
        const items = data && (route.startsWith('/api/v2/comment/') ? data.comments : data.animes)
        if (Array.isArray(items) && items.length === 0) {
          res.writeHead(502, { 'content-type': 'application/json; charset=utf-8' })
          res.end(JSON.stringify({ success: false, errorCode: 502,
            errorMessage: '部分弹幕平台请求失败，未取得结果。请检查 VPN 规则是否将对应平台误送代理后重试。' }))
          return
        }
      }
      res.writeHead(result.status, { 'content-type': 'application/json; charset=utf-8', 'cache-control': 'no-store' })
      res.end(bytes)
    } catch (error) {
      if (!res.destroyed && !res.headersSent) {
        const reason = String(error && (error.message || error) || 'unknown').slice(0, 240)
        res.writeHead(502, { 'content-type': 'application/json' })
        res.end(JSON.stringify({ success: false, errorCode: 502, errorMessage: '本机弹幕上游请求失败：' + reason }))
      }
    }
  })
  server.requestTimeout = 35000
  server.headersTimeout = 10000
  server.maxConnections = 4
  await new Promise((resolve, reject) => { server.once('error', reject); server.listen(0, resolve) })
}

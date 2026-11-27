export const API_BASE = 'http://127.0.0.1:8000'

async function req(path, opts) {
  const res = await fetch(`${API_BASE}${path}`, opts)
  if (!res.ok) throw new Error(`${res.status} ${res.statusText}`)
  return res.json()
}

let inflightCams = null
export const getCameras = (refresh = false) => {
  if (!refresh && inflightCams) return inflightCams
  const p = req(`/api/cameras${refresh ? '?refresh=1' : ''}`).finally(() => {
    if (inflightCams === p) inflightCams = null
  })
  if (!refresh) inflightCams = p
  return p
}
export const getCalibrations = () => req('/api/calibrations')
export const getStatus = () => req('/api/status')
export const getEvents = (since = 0) => req(`/api/events?since=${since}`)
export const startRun = (body) =>
  req('/api/start', {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify(body),
  })
export const stopRun = () => req('/api/stop', { method: 'POST' })
export const videoUrl = (runId) => `${API_BASE}/video?r=${runId}`

// Mirrors railguard/core/alerts.py:braking_distance_m
export function brakingDistanceM(speedKmh) {
  const v = Number(speedKmh)
  if (!Number.isFinite(v) || v <= 0) return null
  if (v < 60) return 300
  if (v <= 80) return 400
  return 500
}

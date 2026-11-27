import { useEffect, useState } from 'react'
import { brakingDistanceM, getCalibrations, getCameras } from '../api.js'

const UNIT_KEY = 'railguard.unit_id'

export default function SetupPanel({ status, backendError, onStart }) {
  const [cameras, setCameras] = useState([])
  const [calibs, setCalibs] = useState([])
  const [probing, setProbing] = useState(true)
  const [probeError, setProbeError] = useState('')
  const [camChoice, setCamChoice] = useState('')
  const [calib, setCalib] = useState('')
  const [unitId, setUnitId] = useState(() => localStorage.getItem(UNIT_KEY) || 'unit-01')
  const [publish, setPublish] = useState(false)
  const [speed, setSpeed] = useState(60)
  const [submitting, setSubmitting] = useState(false)

  const probe = (refresh = false) => {
    setProbing(true)
    setProbeError('')
    Promise.all([getCameras(refresh), getCalibrations()])
      .then(([camRes, calRes]) => {
        const opts = (camRes.cameras || []).flatMap((c) =>
          (c.modes || ['1280x720']).map((m) => ({ key: `${c.index}:${m}`, index: c.index, mode: m })),
        )
        setCameras(opts)
        if (opts.length) setCamChoice((p) => (opts.some((o) => o.key === p) ? p : opts[opts.length - 1].key))
        const list = calRes.calibrations || []
        setCalibs(list)
        const pref = list.find((x) => x.name === 'elp_wide_measured.npz') || list[0]
        if (pref) setCalib((p) => p || pref.path)
      })
      .catch((e) => setProbeError(e.message || 'Cannot reach backend on 127.0.0.1:8000'))
      .finally(() => setProbing(false))
  }

  useEffect(() => { probe(false) }, [])
  useEffect(() => {
    if (!backendError && probeError && !probing && !cameras.length) probe(false)
  }, [backendError, probeError, probing, cameras.length])

  const isLoading = status.state === 'loading' || submitting
  const brakeM = brakingDistanceM(speed)

  const handleSubmit = async (e) => {
    e.preventDefault()
    const picked = cameras.find((c) => c.key === camChoice)
    if (!picked) return
    const [w, h] = picked.mode.split('x').map(Number)
    const cleanUnit = unitId.trim() || 'unit-01'
    localStorage.setItem(UNIT_KEY, cleanUnit)
    setProbeError('')
    setSubmitting(true)
    try {
      await onStart({
        camera: picked.index, width: w, height: h, calib: calib || null,
        unit_id: cleanUnit, publish, speed_kmh: Number(speed) || 60,
      })
    } catch (err) {
      setProbeError(err.message || 'Cannot reach backend on 127.0.0.1:8000')
    } finally {
      setSubmitting(false)
    }
  }

  return (
    <section className="stage stage-setup">
      <form className="setup-panel" onSubmit={handleSubmit}>
        <div className="panel-head">
          <span className="section-label">RAILGUARD — RUN SETUP</span>
          <button type="button" className="btn-inline" onClick={() => probe(true)} disabled={probing || isLoading}>
            {probing ? 'Probing…' : 'Rescan'}
          </button>
        </div>

        {(probeError || backendError) && <div className="notice notice-err">{probeError || backendError}</div>}
        {status.state === 'error' && status.message && (
          <div className="notice notice-err">Backend error: {status.message}</div>
        )}

        <div className="field-row">
          <label htmlFor="rg-cam">Camera</label>
          <select id="rg-cam" value={camChoice} onChange={(e) => setCamChoice(e.target.value)} disabled={isLoading || !cameras.length}>
            {!cameras.length && <option value="">{probing ? 'Probing cameras 0–3…' : 'No camera detected'}</option>}
            {cameras.map((c) => <option key={c.key} value={c.key}>Camera {c.index} — {c.mode}</option>)}
          </select>
        </div>

        <div className="field-row">
          <label htmlFor="rg-cal">Calibration</label>
          <select id="rg-cal" value={calib} onChange={(e) => setCalib(e.target.value)} disabled={isLoading}>
            <option value="">None — uncalibrated</option>
            {calibs.map((c) => <option key={c.path} value={c.path}>{c.name} — fx {c.fx} ({c.width}px)</option>)}
          </select>
        </div>
        {!calib && <div className="notice notice-warn">Uncalibrated — distances will be estimates from an assumed 60° field of view.</div>}

        <div className="field-row">
          <label htmlFor="rg-unit">Unit ID</label>
          <input id="rg-unit" type="text" className="mono" value={unitId} onChange={(e) => setUnitId(e.target.value)} disabled={isLoading} />
        </div>

        <div className="field-row">
          <label htmlFor="rg-speed">Line speed</label>
          <div className="speed-group">
            <input id="rg-speed" type="number" className="mono" min="10" max="160" step="5" value={speed} onChange={(e) => setSpeed(e.target.value)} disabled={isLoading} />
            <span className="unit-tag">km/h</span>
            <span className="brake-readout mono">Braking: {brakeM ? `${brakeM} m` : '?'}</span>
          </div>
        </div>

        <div className="field-row">
          <label htmlFor="rg-pub">Publish hazards</label>
          <label className="check-wrap">
            <input id="rg-pub" type="checkbox" checked={publish} onChange={(e) => setPublish(e.target.checked)} disabled={isLoading} />
            <span>Send confirmed BRAKE NOW alerts to Firestore</span>
          </label>
        </div>

        <div className="setup-foot">
          {isLoading ? (
            <div className="loading-line mono"><span className="dot dot-warn" /><span>{status.message ? `${status.message}…` : 'starting…'}</span></div>
          ) : (
            <span className="hint-text">127.0.0.1:8000 — video stays local</span>
          )}
          <button type="submit" className="btn btn-start" disabled={isLoading || !cameras.length}>
            {isLoading ? 'Loading…' : 'Start'}
          </button>
        </div>
      </form>
    </section>
  )
}

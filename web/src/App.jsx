import { useEffect, useRef, useState } from 'react'
import { getEvents, getStatus, startRun, stopRun } from './api.js'
import { signInDriver, signOutDriver, subscribeHazards, subscribeTrains, watchAuth } from './firebase.js'
import EventLog from './components/EventLog.jsx'
import HazardList from './components/HazardList.jsx'
import LiveView from './components/LiveView.jsx'
import SetupPanel from './components/SetupPanel.jsx'
import StatusBoard from './components/StatusBoard.jsx'
import StatusPanel from './components/StatusPanel.jsx'
import TrainList from './components/TrainList.jsx'

// Unavoidable BRAKE NOW audio alarm (no mute, no volume control).
let audioCtx = null
function unlockAlarm() {
  try {
    const Ctx = window.AudioContext || window.webkitAudioContext
    if (Ctx && !audioCtx) audioCtx = new Ctx()
    if (audioCtx?.state === 'suspended') audioCtx.resume()
  } catch { /* ignore */ }
}

function playBrakeTone() {
  try {
    if (!audioCtx) unlockAlarm()
    if (!audioCtx || audioCtx.state !== 'running') return
    const now = audioCtx.currentTime
      ;[880, 1175].forEach((freq, i) => {
        const osc = audioCtx.createOscillator(), gain = audioCtx.createGain()
        osc.type = 'square'
        osc.frequency.setValueAtTime(freq, now + i * 0.14)
        gain.gain.setValueAtTime(0.22, now + i * 0.14)
        gain.gain.setValueAtTime(0.001, now + i * 0.14 + 0.12)
        osc.connect(gain); gain.connect(audioCtx.destination)
        osc.start(now + i * 0.14); osc.stop(now + i * 0.14 + 0.13)
      })
  } catch { /* ignore */ }
}

export default function App() {
  const [status, setStatus] = useState({ state: 'idle', message: '' })
  const [backendError, setBackendError] = useState('')
  const [events, setEvents] = useState([])
  const [runId, setRunId] = useState(1)
  const [user, setUser] = useState(null)
  const [authErr, setAuthErr] = useState('')
  const [email, setEmail] = useState('')
  const [pass, setPass] = useState('')
  const [trains, setTrains] = useState([])
  const [hazards, setHazards] = useState([])
  const [nowMs, setNowMs] = useState(() => Date.now())
  const sinceRef = useRef(0)

  useEffect(() => {
    let alive = true
    const poll = () => {
      getStatus().then((s) => { if (alive) { setStatus(s); setBackendError('') } })
        .catch(() => { if (alive) setBackendError('Backend offline — start python demos/web_server.py') })
      getEvents(sinceRef.current).then((res) => {
        if (!alive) return
        if (res.total < sinceRef.current) { sinceRef.current = 0; setEvents([]); return }
        if (res.events?.length) {
          sinceRef.current = res.total
          setEvents((prev) => [...prev, ...res.events].slice(-200))
        }
      }).catch(() => { })
    }
    poll()
    const id = setInterval(poll, 500)
    const tick = setInterval(() => setNowMs(Date.now()), 5000)
    return () => { alive = false; clearInterval(id); clearInterval(tick) }
  }, [])

  useEffect(() => watchAuth((u) => { setUser(u); setAuthErr('') }), [])

  useEffect(() => {
    if (!user) { setTrains([]); setHazards([]); return undefined }
    const unsubT = subscribeTrains(setTrains, (e) => setAuthErr(e.message))
    const unsubH = subscribeHazards(setHazards, (e) => setAuthErr(e.message))
    return () => { unsubT(); unsubH() }
  }, [user])

  const isLive = status.state === 'running' || status.state === 'camera_lost'

  useEffect(() => {
    if (!isLive || status.alert !== 'BRAKE NOW') return undefined
    playBrakeTone()
    const id = setInterval(playBrakeTone, 1000)
    return () => clearInterval(id)
  }, [isLive, status.alert])

  const mode = !isLive ? 'idle'
    : status.alert === 'BRAKE NOW' ? 'brake'
      : status.alert === 'CAUTION' ? 'caution'
        : status.state === 'camera_lost' || status.track_valid === false ? 'notrack' : 'normal'

  const ownUnitId = status.unit_id || localStorage.getItem('railguard.unit_id') || 'unit-01'
  const ownPos = trains.find((t) => t.unitId === ownUnitId && t.lat != null && t.lon != null) || null

  const handleStart = async (payload) => {
    unlockAlarm()
    const res = await startRun(payload)
    if (!res.ok) setBackendError(res.message || 'Failed to start')
    else setRunId((n) => n + 1)
  }

  const handleSignIn = async (e) => {
    e.preventDefault(); setAuthErr('')
    try { await signInDriver(email, pass); setPass('') }
    catch (err) { setAuthErr(err.code || err.message || 'Sign-in failed') }
  }

  return (
    <main className={`app mode-${mode}`}>
      <StatusBoard status={status} backendError={backendError} />
      <div className="workspace">
        {isLive ? <LiveView runId={runId} /> : <SetupPanel status={status} backendError={backendError} onStart={handleStart} />}
        <aside className="rail">
          <StatusPanel status={status} backendError={backendError} ownUnitId={ownUnitId} />
          <EventLog events={events} />
          {user ? (
            <>
              <TrainList trains={trains} ownUnitId={ownUnitId} ownPos={ownPos} nowMs={nowMs} />
              <HazardList hazards={hazards} ownPos={ownPos} nowMs={nowMs} />
              <div className="panel-head">
                <span className="hint-text mono">{user.email}</span>
                <button className="btn-inline" onClick={() => signOutDriver()}>Sign out</button>
              </div>
            </>
          ) : (
            <section className="panel">
              <div className="panel-head"><span className="section-label">FLEET LINK (FIRESTORE)</span></div>
              <form className="auth-form" onSubmit={handleSignIn}>
                {authErr && <div className="val-danger">{authErr}</div>}
                <input type="email" placeholder="Driver email" value={email} onChange={(e) => setEmail(e.target.value)} required />
                <div className="auth-row">
                  <input type="password" placeholder="Password" value={pass} onChange={(e) => setPass(e.target.value)} required />
                  <button className="btn-inline" type="submit">Sign in</button>
                </div>
              </form>
            </section>
          )}
          {isLive && (
            <div className="controls">
              <button className="btn btn-stop" onClick={() => stopRun().catch(() => {})}>Stop</button>
            </div>
          )}
        </aside>
      </div>
    </main>
  )
}

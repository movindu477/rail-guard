function pickThreat(status) {
  if (status.alert_threat) return status.alert_threat
  const dets = status.detections || []
  const pool = dets.filter((d) => d.confirmed)
  const list = pool.length ? pool : dets.filter((d) => d.on_track)
  if (!list.length) return null
  return list.find((d) => d.distance_m == null) ||
    list.reduce((a, b) => (b.distance_m < a.distance_m ? b : a), list[0])
}

export default function StatusBoard({ status, backendError }) {
  const s = status || {}
  const live = s.state === 'running' || s.state === 'camera_lost'
  const camLost = s.state === 'camera_lost'
  const isBrake = live && s.alert === 'BRAKE NOW'
  const isCaution = live && s.alert === 'CAUTION'

  let alertVal = 'CLEAR', alertSub = live ? 'no threats' : 'standby', alertCls = live ? 'val-ok' : ''
  if (backendError) [alertVal, alertSub, alertCls] = ['OFFLINE', 'backend unreachable', 'val-danger']
  else if (isBrake || isCaution) {
    const t = pickThreat(s)
    const dist = t && t.distance_m != null ? `${Math.round(t.distance_m)} m` : '? (fail-safe)'
    alertVal = s.alert
    alertSub = `${t ? t.cls : 'object'} · ${dist}`
    alertCls = ''
  } else if (camLost) [alertVal, alertSub, alertCls] = ['CLEAR', 'camera lost', 'val-warn']

  let trackVal = '—', trackSub = 'standby', trackCls = '', trackTileCls = ''
  if (camLost) [trackVal, trackSub, trackCls, trackTileCls] = ['CAMERA LOST', 'reconnecting', 'val-warn', 'tile-warn']
  else if (live && s.track_valid !== undefined) {
    const conv = s.rail_convergence == null ? 'no track' : `conv ${Number(s.rail_convergence).toFixed(2)}`
    if (s.track_valid) [trackVal, trackSub, trackCls] = ['DETECTED', conv, 'val-ok']
    else [trackVal, trackSub, trackCls, trackTileCls] = ['NOT DETECTED', conv, 'val-warn', 'tile-warn']
  }

  const onTrackVal = live && s.on_track != null ? String(s.on_track) : '—'
  const onTrackSub = live && s.confirmed != null ? `${s.confirmed} confirmed` : '0 confirmed'
  const onTrackCls = !isBrake && live && s.confirmed > 0 ? 'val-warn' : ''

  let distVal = '—', distSub = 'standby', distCls = ''
  if (live && s.fx != null) {
    if (s.calibrated) [distVal, distSub, distCls] = [`fx ${s.fx}`, 'calibrated', 'val-ok']
    else [distVal, distSub, distCls] = ['ASSUMED', `fx ${s.fx} · estimates`, 'val-warn']
  }

  const camVal = camLost ? 'LOST' : live && s.fps != null ? `${Number(s.fps).toFixed(1)} fps` : '—'
  const camSub = camLost ? 'stale feed' : live && s.width && s.height ? `${s.width}×${s.height}` : 'standby'
  const camCls = camLost ? 'val-warn' : ''

  const alertTileCls = isCaution ? 'tile-caution' : ''

  return (
    <header className={`status-board ${isBrake ? 'board-brake' : ''}`} aria-live="polite">
      <div className={`tile ${alertTileCls}`}>
        <span className="tile-label">ALERT</span>
        <span className={`tile-val mono ${alertCls}`}>{alertVal}</span>
        <span className="tile-sub mono">{alertSub}</span>
      </div>
      <div className={`tile ${isBrake ? '' : trackTileCls}`}>
        <span className="tile-label">TRACK</span>
        <span className={`tile-val ${isBrake ? '' : trackCls}`}>{trackVal}</span>
        <span className="tile-sub mono">{trackSub}</span>
      </div>
      <div className="tile">
        <span className="tile-label">ON TRACK</span>
        <span className={`tile-val mono ${onTrackCls}`}>{onTrackVal}</span>
        <span className="tile-sub mono">{onTrackSub}</span>
      </div>
      <div className="tile">
        <span className="tile-label">DISTANCES</span>
        <span className={`tile-val mono ${isBrake ? '' : distCls}`}>{distVal}</span>
        <span className="tile-sub mono">{distSub}</span>
      </div>
      <div className="tile">
        <span className="tile-label">CAMERA</span>
        <span className={`tile-val mono ${isBrake ? '' : camCls}`}>{camVal}</span>
        <span className="tile-sub mono">{camSub}</span>
      </div>
    </header>
  )
}

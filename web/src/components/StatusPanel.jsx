function fmtElapsed(sec) {
  if (sec == null) return '—'
  return [Math.floor(sec / 3600), Math.floor((sec % 3600) / 60), sec % 60]
    .map((v) => String(v).padStart(2, '0'))
    .join(':')
}

export default function StatusPanel({ status, backendError, ownUnitId }) {
  const s = status || {}
  const live = s.state === 'running' || s.state === 'camera_lost'

  let stateText = 'stopped', stateCls = ''
  if (backendError) [stateText, stateCls] = ['backend offline', 'val-danger']
  else if (s.state === 'running') [stateText, stateCls] = ['running', 'val-ok']
  else if (s.state === 'camera_lost') [stateText, stateCls] = ['camera lost', 'val-warn']
  else if (s.state === 'loading') [stateText, stateCls] = [s.message || 'loading', 'val-warn']
  else if (s.state === 'error') [stateText, stateCls] = ['error', 'val-danger']

  const rows = [
    ['Running for', live ? fmtElapsed(s.uptime_s) : '—', '', true],
    ['Publishing', s.publishing ? 'on' : 'off', s.publishing ? 'val-ok' : '', true],
    ['Unit ID', s.unit_id || ownUnitId || 'unit-01', '', true],
    ['Camera index', live && s.camera != null ? `#${s.camera}` : '—', '', true],
  ]

  return (
    <section className="panel status-panel">
      <div className="panel-head">
        <span className="section-label">REFERENCE</span>
        <span className={`state-tag ${stateCls}`}>{stateText.toUpperCase()}</span>
      </div>
      <dl className="kv-list">
        {rows.map(([label, val, cls, mono]) => (
          <div className="kv-row" key={label}>
            <dt>{label}</dt>
            <dd className={`${mono ? 'mono' : ''} ${cls}`}>{val}</dd>
          </div>
        ))}
      </dl>
    </section>
  )
}

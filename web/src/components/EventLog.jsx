import { useEffect, useRef } from 'react'

function lineClass(text) {
  if (text.startsWith('BRAKE NOW') || text.startsWith('ERROR')) return 'ev-danger'
  if (text.startsWith('CAUTION') || text.startsWith('track not detected') || text.startsWith('camera lost')) {
    return 'ev-warn'
  }
  if (text.startsWith('ready') || text.startsWith('camera back') || text === 'alert cleared') return 'ev-ok'
  return ''
}

export default function EventLog({ events }) {
  const endRef = useRef(null)
  useEffect(() => {
    endRef.current?.scrollIntoView({ block: 'end' })
  }, [events.length])

  return (
    <section className="panel log-panel">
      <div className="panel-head">
        <span className="section-label">EVENT LOG</span>
        <span className="count-tag mono">{events.length}</span>
      </div>
      <div className="log-scroll" role="log" aria-live="polite">
        {!events.length ? (
          <div className="empty-row">No events yet.</div>
        ) : (
          events.map((ev, i) => (
            <div className={`log-line ${lineClass(ev.text)}`} key={`${ev.time}-${i}`}>
              <span className="log-time mono">{ev.time}</span>
              <span className="log-text">{ev.text}</span>
            </div>
          ))
        )}
        <div ref={endRef} />
      </div>
    </section>
  )
}

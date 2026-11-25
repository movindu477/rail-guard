import { fmtAge, fmtDist, haversineM } from '../firebase.js'

const LIVE_MS = 60_000
const DROP_MS = 300_000

function freshness(tsMs, nowMs) {
  if (tsMs == null) return ['STALE', 'val-warn']
  const age = nowMs - tsMs
  if (age < LIVE_MS) return ['LIVE', 'val-ok']
  if (age <= DROP_MS) return ['STALE', 'val-warn']
  return ['DROPPED', 'val-danger']
}

export default function TrainList({ trains, ownUnitId, ownPos, nowMs }) {
  const sorted = [...trains].sort((a, b) => (b.tsMs || 0) - (a.tsMs || 0))
  return (
    <section className="panel fleet-panel">
      <div className="panel-head">
        <span className="section-label">LIVE TRAINS</span>
        <span className="count-tag mono">{sorted.length}</span>
      </div>
      <div className="list-scroll">
        {!sorted.length ? (
          <div className="empty-row">No units reporting.</div>
        ) : (
          sorted.map((t) => {
            const [tag, cls] = freshness(t.tsMs, nowMs)
            const isOwn = ownUnitId && t.unitId === ownUnitId
            const dist = !isOwn && ownPos ? fmtDist(haversineM(ownPos.lat, ownPos.lon, t.lat, t.lon)) : null
            return (
              <div className={`item-row ${tag === 'DROPPED' ? 'row-dropped' : ''}`} key={t.id}>
                <div className="item-main">
                  <span className="item-title mono">{t.trainNo || t.unitId}</span>
                  <span className="item-sub">{t.service}{isOwn ? ' · THIS UNIT' : ''}</span>
                </div>
                <div className="item-meta mono">
                  {dist && <span>{dist} · </span>}
                  <span>{fmtAge(t.tsMs, nowMs)} · </span>
                  <span className={cls}>{tag}</span>
                </div>
              </div>
            )
          })
        )}
      </div>
    </section>
  )
}

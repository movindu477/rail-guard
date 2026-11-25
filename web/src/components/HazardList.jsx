import { fmtAge, fmtDist, haversineM } from '../firebase.js'

export default function HazardList({ hazards, ownPos, nowMs }) {
  return (
    <section className="panel fleet-panel">
      <div className="panel-head">
        <span className="section-label">ACTIVE HAZARDS</span>
        <span className="count-tag mono">{hazards.length}</span>
      </div>
      <div className="list-scroll">
        {!hazards.length ? (
          <div className="empty-row">No active hazards.</div>
        ) : (
          hazards.map((h) => {
            const blocked = h.severity !== 'near'
            const gpsDist = ownPos ? fmtDist(haversineM(ownPos.lat, ownPos.lon, h.lat, h.lon)) : null
            const dist = gpsDist || (h.cameraDistM != null ? `${Math.round(h.cameraDistM)} m` : null)
            return (
              <div className="item-row" key={h.id}>
                <div className="item-main">
                  <span className={`item-title ${blocked ? 'val-danger' : 'val-warn'}`}>
                    {h.objectType}
                  </span>
                  <span className="item-sub">
                    {blocked ? 'BLOCKED' : 'NEAR'}
                    {h.unitId ? ` · ${h.unitId}` : ''}
                  </span>
                </div>
                <div className="item-meta mono">
                  {dist && <span>{dist} · </span>}
                  <span>{fmtAge(h.tsMs, nowMs)}</span>
                </div>
              </div>
            )
          })
        )}
      </div>
    </section>
  )
}

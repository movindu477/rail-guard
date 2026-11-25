import { videoUrl } from '../api.js'

export default function LiveView({ runId }) {
  return (
    <section className="stage stage-live">
      <div className="video-frame">
        <img className="video-img" src={videoUrl(runId)} alt="RailGuard live feed" />
      </div>
    </section>
  )
}

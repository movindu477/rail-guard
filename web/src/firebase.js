import { initializeApp } from '@firebase/app'
import { getAuth, onAuthStateChanged, signInWithEmailAndPassword, signOut } from '@firebase/auth'
import { collection, getFirestore, onSnapshot } from '@firebase/firestore'

// Web app registered in Firebase project railguard-alerts (separate from Android config).
const firebaseConfig = {
  apiKey: 'AIzaSyAJ5uajzepQCmgvr9TewJQ72KYaAGUhFGw',
  authDomain: 'railguard-alerts.firebaseapp.com',
  projectId: 'railguard-alerts',
  storageBucket: 'railguard-alerts.firebasestorage.app',
  messagingSenderId: '808002289908',
  appId: '1:808002289908:web:b9b205ad8227c6b7901ea1',
}

const app = initializeApp(firebaseConfig)
export const auth = getAuth(app)
export const db = getFirestore(app)

export const watchAuth = (cb) => onAuthStateChanged(auth, cb)
export const signInDriver = (email, password) =>
  signInWithEmailAndPassword(auth, email.trim(), password)
export const signOutDriver = () => signOut(auth)

function toMs(ts) {
  if (!ts) return null
  if (typeof ts.toMillis === 'function') return ts.toMillis()
  if (typeof ts.seconds === 'number') return ts.seconds * 1000
  return null
}

export function subscribeTrains(onData, onError) {
  return onSnapshot(
    collection(db, 'train_position'),
    (snap) => {
      const list = snap.docs.map((doc) => {
        const d = doc.data() || {}
        return {
          id: doc.id,
          unitId: (d.unit_id || doc.id).trim(),
          trainNo: (d.train_no || '').trim(),
          service: (d.service || 'up').toUpperCase(),
          driverName: (d.driver_name || '').trim(),
          lat: typeof d.latitude === 'number' ? d.latitude : null,
          lon: typeof d.longitude === 'number' ? d.longitude : null,
          tsMs: toMs(d.timestamp),
        }
      })
      onData(list)
    },
    onError,
  )
}

export function subscribeHazards(onData, onError) {
  return onSnapshot(
    collection(db, 'hazards'),
    (snap) => {
      const list = snap.docs
        .map((doc) => {
          const d = doc.data() || {}
          return {
            id: doc.id,
            objectType: d.detected_class || d.object_type || 'hazard',
            severity: d.severity === 'near' ? 'near' : 'blocked',
            status: d.status || 'active',
            reportedBy: d.reported_by || '',
            unitId: d.unit_id || '',
            cameraDistM: typeof d.distance_m === 'number' ? d.distance_m : null,
            lat: typeof d.latitude === 'number' ? d.latitude : null,
            lon: typeof d.longitude === 'number' ? d.longitude : null,
            tsMs: toMs(d.timestamp),
          }
        })
        .filter((h) => h.status !== 'cleared')
        .sort((a, b) => (b.tsMs || 0) - (a.tsMs || 0))
      onData(list)
    },
    onError,
  )
}

export function haversineM(lat1, lon1, lat2, lon2) {
  if ([lat1, lon1, lat2, lon2].some((v) => typeof v !== 'number')) return null
  const R = 6371008.8
  const r = Math.PI / 180
  const dp = (lat2 - lat1) * r
  const dl = (lon2 - lon1) * r
  const a =
    Math.sin(dp / 2) ** 2 +
    Math.cos(lat1 * r) * Math.cos(lat2 * r) * Math.sin(dl / 2) ** 2
  return 2 * R * Math.asin(Math.min(1, Math.sqrt(a)))
}

export function fmtAge(tsMs, nowMs) {
  if (tsMs == null) return 'time ?'
  const s = Math.max(0, Math.floor((nowMs - tsMs) / 1000))
  if (s < 60) return `${s}s ago`
  const m = Math.floor(s / 60)
  if (m < 60) return `${m}m ago`
  return `${Math.floor(m / 60)}h ${m % 60}m ago`
}

export function fmtDist(m) {
  if (m == null) return null
  return m < 1000 ? `${Math.round(m)} m` : `${(m / 1000).toFixed(1)} km`
}

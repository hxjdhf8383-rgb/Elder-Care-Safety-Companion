;; title: medication-adherence-tracking
;; version: 1.0
;; summary: Smart pillbox logs with reminder and escalation rules
;; description: Smart contract for managing medication schedules, adherence tracking, and automated reminders

;; constants
(define-constant contract-owner tx-sender)
(define-constant err-owner-only (err u200))
(define-constant err-not-found (err u201))
(define-constant err-already-exists (err u202))
(define-constant err-invalid-schedule (err u203))
(define-constant err-unauthorized (err u204))
(define-constant err-invalid-time (err u205))
(define-constant err-medication-taken (err u206))
(define-constant err-invalid-dosage (err u207))

;; Adherence status types
(define-constant status-scheduled u0)
(define-constant status-taken u1)
(define-constant status-missed u2)
(define-constant status-late u3)
(define-constant status-skipped u4)

;; Reminder escalation levels
(define-constant reminder-none u0)
(define-constant reminder-gentle u1)
(define-constant reminder-urgent u2)
(define-constant reminder-critical u3)

;; Time constants (in blocks)
(define-constant missed-threshold u10) ;; ~1.7 minutes
(define-constant late-threshold u30) ;; ~5 minutes
(define-constant escalation-interval u60) ;; ~10 minutes

;; data vars
(define-data-var next-medication-id uint u1)
(define-data-var next-schedule-id uint u1)
(define-data-var total-patients uint u0)
(define-data-var system-active bool true)

;; data maps
(define-map patients
  { patient-id: principal }
  {
    name: (string-ascii 100),
    caregivers: (list 3 principal),
    primary-caregiver: principal,
    emergency-contact: principal,
    active-medications: uint,
    total-adherence-rate: uint,
    last-updated: uint
  }
)

(define-map medications
  { medication-id: uint }
  {
    name: (string-ascii 100),
    dosage: (string-ascii 50),
    frequency: uint, ;; times per day
    duration: uint, ;; days of treatment
    instructions: (string-ascii 200),
    side-effects: (string-ascii 300),
    prescriber: principal,
    active: bool
  }
)

(define-map medication-schedules
  { schedule-id: uint }
  {
    patient-id: principal,
    medication-id: uint,
    times-per-day: uint,
    dosage-times: (list 8 uint), ;; Block heights for dosages
    start-date: uint,
    end-date: uint,
    total-doses: uint,
    taken-doses: uint,
    missed-doses: uint,
    adherence-rate: uint,
    active: bool
  }
)

(define-map adherence-logs
  { log-id: uint }
  {
    schedule-id: uint,
    patient-id: principal,
    medication-id: uint,
    scheduled-time: uint,
    actual-time: (optional uint),
    status: uint,
    reminder-level: uint,
    notes: (string-ascii 200),
    verified-by: (optional principal)
  }
)

(define-map reminder-settings
  { patient-id: principal }
  {
    enable-reminders: bool,
    reminder-advance: uint, ;; blocks before scheduled time
    escalation-enabled: bool,
    max-escalation-level: uint,
    caregiver-notifications: bool,
    emergency-threshold: uint ;; consecutive missed doses
  }
)

(define-map patient-device-mapping
  { device-id: (string-ascii 50) }
  { patient-id: principal }
)

;; Global counters
(define-data-var next-log-id uint u1)

;; private functions
(define-private (is-authorized-caregiver (patient-id principal) (caregiver principal))
  (let (
    (patient-data (map-get? patients { patient-id: patient-id }))
  )
    (match patient-data
      patient (or
        (is-eq caregiver (get primary-caregiver patient))
        (is-some (index-of (get caregivers patient) caregiver))
      )
      false
    )
  )
)

(define-private (calculate-adherence-rate (taken uint) (total uint))
  (if (> total u0)
    (/ (* taken u100) total)
    u0
  )
)

(define-private (update-patient-adherence (patient-id principal))
  (let (
    (patient-data (unwrap! (map-get? patients { patient-id: patient-id }) false))
    ;; In a real implementation, this would aggregate all schedules
    (new-rate (calculate-adherence-rate u80 u100)) ;; Placeholder calculation
  )
    (map-set patients
      { patient-id: patient-id }
      (merge patient-data {
        total-adherence-rate: new-rate,
        last-updated: burn-block-height
      })
    )
    true
  )
)

(define-private (should-escalate-reminder (missed-count uint) (last-reminder-level uint))
  (and
    (> missed-count u0)
    (< last-reminder-level reminder-critical)
  )
)

(define-private (get-reminder-level (time-diff uint))
  (if (> time-diff (* escalation-interval u3))
    reminder-critical
    (if (> time-diff (* escalation-interval u2))
      reminder-urgent
      (if (> time-diff escalation-interval)
        reminder-gentle
        reminder-none
      )
    )
  )
)

(define-private (notify-caregivers (patient-id principal) (medication-id uint) (urgency uint))
  ;; This would integrate with external notification system
  ;; For now, we'll just return success
  true
)

;; public functions

;; Register a new patient
(define-public (register-patient
  (name (string-ascii 100))
  (caregivers (list 3 principal))
  (primary-caregiver principal)
  (emergency-contact principal)
)
  (let (
    (patient-id tx-sender)
  )
    (asserts! (not (is-some (map-get? patients { patient-id: patient-id }))) err-already-exists)
    
    (map-set patients
      { patient-id: patient-id }
      {
        name: name,
        caregivers: caregivers,
        primary-caregiver: primary-caregiver,
        emergency-contact: emergency-contact,
        active-medications: u0,
        total-adherence-rate: u100,
        last-updated: burn-block-height
      }
    )
    
    ;; Set default reminder settings
    (map-set reminder-settings
      { patient-id: patient-id }
      {
        enable-reminders: true,
        reminder-advance: u5, ;; 5 blocks before
        escalation-enabled: true,
        max-escalation-level: reminder-urgent,
        caregiver-notifications: true,
        emergency-threshold: u3
      }
    )
    
    (var-set total-patients (+ (var-get total-patients) u1))
    (ok patient-id)
  )
)

;; Add a new medication
(define-public (add-medication
  (name (string-ascii 100))
  (dosage (string-ascii 50))
  (frequency uint)
  (duration uint)
  (instructions (string-ascii 200))
  (side-effects (string-ascii 300))
)
  (let (
    (medication-id (var-get next-medication-id))
    (prescriber tx-sender)
  )
    (map-set medications
      { medication-id: medication-id }
      {
        name: name,
        dosage: dosage,
        frequency: frequency,
        duration: duration,
        instructions: instructions,
        side-effects: side-effects,
        prescriber: prescriber,
        active: true
      }
    )
    
    (var-set next-medication-id (+ medication-id u1))
    (ok medication-id)
  )
)

;; Create medication schedule for patient
(define-public (create-schedule
  (patient-id principal)
  (medication-id uint)
  (times-per-day uint)
  (dosage-times (list 8 uint))
  (duration uint)
)
  (let (
    (schedule-id (var-get next-schedule-id))
    (start-date burn-block-height)
    (end-date (+ start-date duration))
    (total-doses (* times-per-day duration))
  )
    ;; Verify medication exists and caller is authorized
    (asserts! (is-some (map-get? medications { medication-id: medication-id })) err-not-found)
    (asserts! (is-authorized-caregiver patient-id tx-sender) err-unauthorized)
    
    (map-set medication-schedules
      { schedule-id: schedule-id }
      {
        patient-id: patient-id,
        medication-id: medication-id,
        times-per-day: times-per-day,
        dosage-times: dosage-times,
        start-date: start-date,
        end-date: end-date,
        total-doses: total-doses,
        taken-doses: u0,
        missed-doses: u0,
        adherence-rate: u100,
        active: true
      }
    )
    
    ;; Update patient active medication count
    (let (
      (patient-data (unwrap! (map-get? patients { patient-id: patient-id }) err-not-found))
    )
      (map-set patients
        { patient-id: patient-id }
        (merge patient-data {
          active-medications: (+ (get active-medications patient-data) u1),
          last-updated: burn-block-height
        })
      )
    )
    
    (var-set next-schedule-id (+ schedule-id u1))
    (ok schedule-id)
  )
)

;; Log medication adherence (taken/missed)
(define-public (log-adherence
  (schedule-id uint)
  (scheduled-time uint)
  (status uint)
  (notes (string-ascii 200))
)
  (let (
    (log-id (var-get next-log-id))
    (schedule-data (unwrap! (map-get? medication-schedules { schedule-id: schedule-id }) err-not-found))
    (patient-id (get patient-id schedule-data))
    (actual-time (if (is-eq status status-taken) (some burn-block-height) none))
  )
    ;; Verify caller is patient or authorized caregiver
    (asserts! 
      (or 
        (is-eq tx-sender patient-id)
        (is-authorized-caregiver patient-id tx-sender)
      )
      err-unauthorized
    )
    
    ;; Create adherence log entry
    (map-set adherence-logs
      { log-id: log-id }
      {
        schedule-id: schedule-id,
        patient-id: patient-id,
        medication-id: (get medication-id schedule-data),
        scheduled-time: scheduled-time,
        actual-time: actual-time,
        status: status,
        reminder-level: reminder-none,
        notes: notes,
        verified-by: (some tx-sender)
      }
    )
    
    ;; Update schedule statistics
    (let (
      (new-taken (if (is-eq status status-taken) (+ (get taken-doses schedule-data) u1) (get taken-doses schedule-data)))
      (new-missed (if (is-eq status status-missed) (+ (get missed-doses schedule-data) u1) (get missed-doses schedule-data)))
      (new-adherence-rate (calculate-adherence-rate new-taken (+ new-taken new-missed)))
    )
      (map-set medication-schedules
        { schedule-id: schedule-id }
        (merge schedule-data {
          taken-doses: new-taken,
          missed-doses: new-missed,
          adherence-rate: new-adherence-rate
        })
      )
    )
    
    ;; Update patient overall adherence
    (update-patient-adherence patient-id)
    
    ;; Handle escalation if missed
    (if (is-eq status status-missed)
      (notify-caregivers patient-id (get medication-id schedule-data) reminder-gentle)
      true
    )
    
    (var-set next-log-id (+ log-id u1))
    (ok log-id)
  )
)

;; Update reminder settings
(define-public (update-reminder-settings
  (enable-reminders bool)
  (reminder-advance uint)
  (escalation-enabled bool)
  (max-escalation-level uint)
  (caregiver-notifications bool)
  (emergency-threshold uint)
)
  (let (
    (patient-id tx-sender)
  )
    (asserts! (is-some (map-get? patients { patient-id: patient-id })) err-not-found)
    
    (map-set reminder-settings
      { patient-id: patient-id }
      {
        enable-reminders: enable-reminders,
        reminder-advance: reminder-advance,
        escalation-enabled: escalation-enabled,
        max-escalation-level: max-escalation-level,
        caregiver-notifications: caregiver-notifications,
        emergency-threshold: emergency-threshold
      }
    )
    
    (ok true)
  )
)

;; Deactivate a medication schedule
(define-public (deactivate-schedule (schedule-id uint))
  (let (
    (schedule-data (unwrap! (map-get? medication-schedules { schedule-id: schedule-id }) err-not-found))
    (patient-id (get patient-id schedule-data))
  )
    (asserts! (is-authorized-caregiver patient-id tx-sender) err-unauthorized)
    
    (map-set medication-schedules
      { schedule-id: schedule-id }
      (merge schedule-data { active: false })
    )
    
    ;; Update patient active medication count
    (let (
      (patient-data (unwrap! (map-get? patients { patient-id: patient-id }) err-not-found))
    )
      (map-set patients
        { patient-id: patient-id }
        (merge patient-data {
          active-medications: (- (get active-medications patient-data) u1)
        })
      )
    )
    
    (ok schedule-id)
  )
)

;; read only functions

;; Get patient information and statistics
(define-read-only (get-patient-info (patient-id principal))
  (map-get? patients { patient-id: patient-id })
)

;; Get medication details
(define-read-only (get-medication (medication-id uint))
  (map-get? medications { medication-id: medication-id })
)

;; Get medication schedule
(define-read-only (get-schedule (schedule-id uint))
  (map-get? medication-schedules { schedule-id: schedule-id })
)

;; Get adherence log entry
(define-read-only (get-adherence-log (log-id uint))
  (map-get? adherence-logs { log-id: log-id })
)

;; Get reminder settings
(define-read-only (get-reminder-settings (patient-id principal))
  (map-get? reminder-settings { patient-id: patient-id })
)

;; Get patient adherence rate for specific schedule
(define-read-only (get-adherence-rate (schedule-id uint))
  (let (
    (schedule-data (map-get? medication-schedules { schedule-id: schedule-id }))
  )
    (match schedule-data
      schedule (some (get adherence-rate schedule))
      none
    )
  )
)

;; Get system statistics
(define-read-only (get-system-stats)
  {
    total-patients: (var-get total-patients),
    total-medications: (- (var-get next-medication-id) u1),
    total-schedules: (- (var-get next-schedule-id) u1),
    total-logs: (- (var-get next-log-id) u1),
    system-active: (var-get system-active)
  }
)

;; Check if patient has active medications
(define-read-only (has-active-medications (patient-id principal))
  (let (
    (patient-data (map-get? patients { patient-id: patient-id }))
  )
    (match patient-data
      patient (> (get active-medications patient) u0)
      false
    )
  )
)

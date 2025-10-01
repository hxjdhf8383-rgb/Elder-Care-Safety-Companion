;; title: fall-detection-and-response
;; version: 1.0
;; summary: On-device ML for fall events with automatic caregiver dispatch
;; description: Smart contract for managing fall detection events, emergency responses, and caregiver coordination

;; constants
(define-constant contract-owner tx-sender)
(define-constant err-owner-only (err u100))
(define-constant err-not-found (err u101))
(define-constant err-already-registered (err u102))
(define-constant err-invalid-caregiver (err u103))
(define-constant err-invalid-response-time (err u104))
(define-constant err-emergency-active (err u105))
(define-constant err-unauthorized (err u106))

;; Emergency status types
(define-constant status-safe u0)
(define-constant status-emergency u1)
(define-constant status-responded u2)
(define-constant status-resolved u3)

;; Response time thresholds (in blocks)
(define-constant emergency-timeout u100) ;; ~17 minutes
(define-constant critical-timeout u300) ;; ~50 minutes

;; data vars
(define-data-var next-event-id uint u1)
(define-data-var total-users uint u0)
(define-data-var total-emergencies uint u0)
(define-data-var system-active bool true)

;; data maps
(define-map users
  { user-id: principal }
  {
    name: (string-ascii 100),
    emergency-contacts: (list 5 principal),
    primary-caregiver: principal,
    status: uint,
    last-check: uint,
    fall-count: uint,
    device-id: (string-ascii 50)
  }
)

(define-map emergency-events
  { event-id: uint }
  {
    user-id: principal,
    timestamp: uint,
    location: (string-ascii 200),
    severity: uint,
    auto-detected: bool,
    responder: (optional principal),
    response-time: (optional uint),
    resolution-notes: (string-ascii 500)
  }
)

(define-map caregiver-profiles
  { caregiver-id: principal }
  {
    name: (string-ascii 100),
    phone: (string-ascii 20),
    certification: (string-ascii 100),
    response-rate: uint,
    total-responses: uint,
    avg-response-time: uint,
    active: bool
  }
)

(define-map user-device-mapping
  { device-id: (string-ascii 50) }
  { user-id: principal }
)

;; private functions
(define-private (is-valid-caregiver (caregiver principal))
  (is-some (map-get? caregiver-profiles { caregiver-id: caregiver }))
)

(define-private (calculate-response-time (event-timestamp uint) (response-timestamp uint))
  (if (> response-timestamp event-timestamp)
    (- response-timestamp event-timestamp)
    u0
  )
)

(define-private (update-caregiver-stats (caregiver principal) (response-time uint))
  (let (
    (current-profile (unwrap! (map-get? caregiver-profiles { caregiver-id: caregiver }) false))
    (new-total (+ (get total-responses current-profile) u1))
    (new-avg (/ (+ (* (get avg-response-time current-profile) (get total-responses current-profile)) response-time) new-total))
  )
    (map-set caregiver-profiles
      { caregiver-id: caregiver }
      (merge current-profile {
        total-responses: new-total,
        avg-response-time: new-avg
      })
    )
    true
  )
)

(define-private (is-emergency-active (user-id principal))
  (let (
    (user-data (map-get? users { user-id: user-id }))
  )
    (match user-data
      user (is-eq (get status user) status-emergency)
      false
    )
  )
)

(define-private (notify-emergency-contacts (user-id principal) (event-id uint))
  ;; This would integrate with external notification system
  ;; For now, we'll just update the event with notification flag
  true
)

;; public functions

;; Register a new elderly user with emergency contacts
(define-public (register-user
  (name (string-ascii 100))
  (emergency-contacts (list 5 principal))
  (primary-caregiver principal)
  (device-id (string-ascii 50))
)
  (let (
    (user-id tx-sender)
  )
    (asserts! (not (is-some (map-get? users { user-id: user-id }))) err-already-registered)
    (asserts! (is-valid-caregiver primary-caregiver) err-invalid-caregiver)
    
    (map-set users
      { user-id: user-id }
      {
        name: name,
        emergency-contacts: emergency-contacts,
        primary-caregiver: primary-caregiver,
        status: status-safe,
        last-check: burn-block-height,
        fall-count: u0,
        device-id: device-id
      }
    )
    
    (map-set user-device-mapping
      { device-id: device-id }
      { user-id: user-id }
    )
    
    (var-set total-users (+ (var-get total-users) u1))
    (ok user-id)
  )
)

;; Register a caregiver profile
(define-public (register-caregiver
  (name (string-ascii 100))
  (phone (string-ascii 20))
  (certification (string-ascii 100))
)
  (let (
    (caregiver-id tx-sender)
  )
    (map-set caregiver-profiles
      { caregiver-id: caregiver-id }
      {
        name: name,
        phone: phone,
        certification: certification,
        response-rate: u100, ;; Start with 100% rate
        total-responses: u0,
        avg-response-time: u0,
        active: true
      }
    )
    (ok caregiver-id)
  )
)

;; Report a fall detection event
(define-public (report-fall
  (user-id principal)
  (location (string-ascii 200))
  (severity uint)
  (auto-detected bool)
)
  (let (
    (event-id (var-get next-event-id))
    (current-user (unwrap! (map-get? users { user-id: user-id }) err-not-found))
  )
    ;; Check if user already has active emergency
    (asserts! (not (is-emergency-active user-id)) err-emergency-active)
    
    ;; Create emergency event
    (map-set emergency-events
      { event-id: event-id }
      {
        user-id: user-id,
        timestamp: burn-block-height,
        location: location,
        severity: severity,
        auto-detected: auto-detected,
        responder: none,
        response-time: none,
        resolution-notes: ""
      }
    )
    
    ;; Update user status and fall count
    (map-set users
      { user-id: user-id }
      (merge current-user {
        status: status-emergency,
        last-check: burn-block-height,
        fall-count: (+ (get fall-count current-user) u1)
      })
    )
    
    ;; Increment counters
    (var-set next-event-id (+ event-id u1))
    (var-set total-emergencies (+ (var-get total-emergencies) u1))
    
    ;; Notify emergency contacts
    (notify-emergency-contacts user-id event-id)
    
    (ok event-id)
  )
)

;; Respond to an emergency event
(define-public (respond-to-emergency
  (event-id uint)
  (resolution-notes (string-ascii 500))
)
  (let (
    (event-data (unwrap! (map-get? emergency-events { event-id: event-id }) err-not-found))
    (response-time (calculate-response-time (get timestamp event-data) burn-block-height))
    (responder tx-sender)
  )
    ;; Verify responder is authorized caregiver
    (asserts! (is-valid-caregiver responder) err-invalid-caregiver)
    
    ;; Update emergency event
    (map-set emergency-events
      { event-id: event-id }
      (merge event-data {
        responder: (some responder),
        response-time: (some response-time),
        resolution-notes: resolution-notes
      })
    )
    
    ;; Update user status
    (let (
      (user-data (unwrap! (map-get? users { user-id: (get user-id event-data) }) err-not-found))
    )
      (map-set users
        { user-id: (get user-id event-data) }
        (merge user-data {
          status: status-responded,
          last-check: burn-block-height
        })
      )
    )
    
    ;; Update caregiver statistics
    (update-caregiver-stats responder response-time)
    
    (ok { event-id: event-id, response-time: response-time })
  )
)

;; Mark emergency as fully resolved
(define-public (resolve-emergency (event-id uint))
  (let (
    (event-data (unwrap! (map-get? emergency-events { event-id: event-id }) err-not-found))
    (user-id (get user-id event-data))
  )
    ;; Only responder or primary caregiver can resolve
    (asserts! 
      (or 
        (is-eq (some tx-sender) (get responder event-data))
        (is-eq tx-sender (get primary-caregiver (unwrap! (map-get? users { user-id: user-id }) err-not-found)))
      )
      err-unauthorized
    )
    
    ;; Update user status to safe
    (let (
      (user-data (unwrap! (map-get? users { user-id: user-id }) err-not-found))
    )
      (map-set users
        { user-id: user-id }
        (merge user-data {
          status: status-resolved,
          last-check: burn-block-height
        })
      )
    )
    
    (ok event-id)
  )
)

;; Update emergency contacts for a user
(define-public (update-emergency-contacts
  (new-contacts (list 5 principal))
)
  (let (
    (user-data (unwrap! (map-get? users { user-id: tx-sender }) err-not-found))
  )
    (map-set users
      { user-id: tx-sender }
      (merge user-data { emergency-contacts: new-contacts })
    )
    (ok new-contacts)
  )
)

;; Emergency system control (owner only)
(define-public (toggle-system (active bool))
  (begin
    (asserts! (is-eq tx-sender contract-owner) err-owner-only)
    (var-set system-active active)
    (ok active)
  )
)

;; read only functions

;; Get user current status and information
(define-read-only (get-user-status (user-id principal))
  (map-get? users { user-id: user-id })
)

;; Get emergency event details
(define-read-only (get-emergency-event (event-id uint))
  (map-get? emergency-events { event-id: event-id })
)

;; Get caregiver profile and statistics
(define-read-only (get-caregiver-profile (caregiver-id principal))
  (map-get? caregiver-profiles { caregiver-id: caregiver-id })
)

;; Get user by device ID
(define-read-only (get-user-by-device (device-id (string-ascii 50)))
  (let (
    (mapping (map-get? user-device-mapping { device-id: device-id }))
  )
    (match mapping
      device-mapping (get-user-status (get user-id device-mapping))
      none
    )
  )
)

;; Get system statistics
(define-read-only (get-system-stats)
  {
    total-users: (var-get total-users),
    total-emergencies: (var-get total-emergencies),
    active-emergencies: u0, ;; Would need separate tracking
    system-active: (var-get system-active)
  }
)

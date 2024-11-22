;; ImpactNFT Smart Contract
;; Transparent Blockchain Charity Platform with Recurring Donations

(define-constant contract-owner tx-sender)
(define-constant err-owner-only (err u100))
(define-constant err-insufficient-funds (err u101))
(define-constant err-invalid-nft (err u102))
(define-constant err-invalid-input (err u103))
(define-constant err-recurring-donation-exists (err u104))
(define-constant err-recurring-donation-not-found (err u105))

;; Input Validation Functions
(define-private (validate-string (input (string-utf8 500))) 
  (and 
    (> (len input) u0) 
    (<= (len input) u500)
  )
)

(define-private (validate-amount (amount uint))
  (> amount u0)
)

;; Strict project ID validation function
(define-private (is-valid-project-id (project-id uint))
  (and 
    (>= project-id u0) 
    (< project-id (var-get next-project-id))
  )
)

;; Safe project ID retrieval
(define-private (get-validated-project 
  (project-id uint)
)
  (let 
    (
      (is-valid (is-valid-project-id project-id))
      (project (map-get? charity-projects { project-id: project-id }))
    )
    (if is-valid
      project
      none)
  )
)

;; NFT for Charity Donations
(define-non-fungible-token impact-nft uint)

;; Storage for Charity Projects
(define-map charity-projects 
  { project-id: uint }
  {
    name: (string-utf8 100),
    description: (string-utf8 500),
    target-amount: uint,
    current-amount: uint,
    is-active: bool
  }
)

;; Storage for Donor Information
(define-map donor-contributions 
  { project-id: uint, donor: principal }
  { amount: uint, timestamp: uint }
)

;; Recurring Donation Structure
(define-map recurring-donations 
  { 
    donor: principal, 
    project-id: uint 
  }
  {
    amount: uint,
    frequency-blocks: uint,
    last-donation-block: uint,
    is-active: bool
  }
)

;; Create a new charity project with strict input validation
(define-public (create-charity-project 
  (name (string-utf8 100))
  (description (string-utf8 500))
  (target-amount uint)
)
  (begin
    ;; Validate inputs
    (asserts! (is-eq tx-sender contract-owner) err-owner-only)
    (asserts! (validate-string name) err-invalid-input)
    (asserts! (validate-string description) err-invalid-input)
    (asserts! (validate-amount target-amount) err-invalid-input)

    ;; Create project with validated inputs
    (map-set charity-projects 
      { project-id: (var-get next-project-id) }
      {
        name: name,
        description: description,
        target-amount: target-amount,
        current-amount: u0,
        is-active: true
      }
    )
    (var-set next-project-id (+ (var-get next-project-id) u1))
    (ok true)
  )
)

;; Donate to a specific charity project with input validation
(define-public (donate 
  (project-id uint)
  (amount uint)
)
  (let 
    (
      (project (unwrap! (get-validated-project project-id) err-invalid-input))
      (current-amount (get current-amount project))
    )
    ;; Additional input validations
    (asserts! (validate-amount amount) err-invalid-input)
    (asserts! (get is-active project) err-invalid-nft)
    (try! (stx-transfer? amount tx-sender (as-contract tx-sender)))
    
    ;; Update project funds and donor contributions
    (map-set charity-projects 
      { project-id: project-id }
      (merge project { current-amount: (+ current-amount amount) })
    )
    (map-set donor-contributions 
      { project-id: project-id, donor: tx-sender }
      { amount: amount, timestamp: block-height }
    )
    
    ;; Mint Impact NFT to donor
    (nft-mint? impact-nft project-id tx-sender)
  )
)

;; Setup Recurring Donation
(define-public (setup-recurring-donation
  (project-id uint)
  (amount uint)
  (frequency-blocks uint)
)
  (let 
    (
      (project (unwrap! (get-validated-project project-id) err-invalid-nft))
      (existing-donation (map-get? recurring-donations { donor: tx-sender, project-id: project-id }))
    )
    ;; Validate inputs
    (asserts! (validate-amount amount) err-invalid-input)
    (asserts! (> frequency-blocks u0) err-invalid-input)
    (asserts! (get is-active project) err-invalid-nft)
    
    ;; Check if recurring donation already exists
    (asserts! (is-none existing-donation) err-recurring-donation-exists)
    
    ;; Store recurring donation details
    (map-set recurring-donations 
      { donor: tx-sender, project-id: project-id }
      {
        amount: amount,
        frequency-blocks: frequency-blocks,
        last-donation-block: block-height,
        is-active: true
      }
    )
    
    (ok true)
  )
)

;; Process Recurring Donations
(define-public (process-recurring-donations 
  (donor principal)
  (project-id uint)
)
  (let 
    (
      (recurring-donation (unwrap! 
        (map-get? recurring-donations { donor: donor, project-id: project-id }) 
        err-recurring-donation-not-found
      ))
      (project (unwrap! 
        (get-validated-project project-id) 
        err-invalid-nft
      ))
      (amount (get amount recurring-donation))
      (frequency-blocks (get frequency-blocks recurring-donation))
      (last-donation-block (get last-donation-block recurring-donation))
    )
    ;; Check if donation is due
    (asserts! (>= (- block-height last-donation-block) frequency-blocks) err-invalid-input)
    (asserts! (get is-active project) err-invalid-nft)
    
    ;; Transfer funds
    (try! (stx-transfer? amount donor (as-contract tx-sender)))
    
    ;; Update project and recurring donation details
    (map-set charity-projects 
      { project-id: project-id }
      (merge project { 
        current-amount: (+ (get current-amount project) amount) 
      })
    )
    (map-set recurring-donations 
      { donor: donor, project-id: project-id }
      (merge recurring-donation { 
        last-donation-block: block-height 
      })
    )
    
    ;; Mint Impact NFT for recurring donation
    (nft-mint? impact-nft project-id donor)
  )
)

;; Cancel Recurring Donation
(define-public (cancel-recurring-donation 
  (project-id uint)
)
  (let 
    (
      (recurring-donation (unwrap! 
        (map-get? recurring-donations { donor: tx-sender, project-id: project-id }) 
        err-recurring-donation-not-found
      ))
    )
    ;; Remove recurring donation
    (map-delete recurring-donations 
      { donor: tx-sender, project-id: project-id }
    )
    
    (ok true)
  )
)

;; Withdraw funds for completed projects
(define-public (withdraw-project-funds 
  (project-id uint)
)
  (let 
    (
      (project (unwrap! (get-validated-project project-id) err-invalid-input))
      (current-amount (get current-amount project))
    )
    ;; Strict validation for withdrawal
    (asserts! (is-eq tx-sender contract-owner) err-owner-only)
    (asserts! (>= current-amount (get target-amount project)) err-insufficient-funds)
    
    (try! (as-contract (stx-transfer? current-amount tx-sender contract-owner)))
    
    (map-set charity-projects 
      { project-id: project-id }
      (merge project { is-active: false, current-amount: u0 })
    )
    
    (ok true)
  )
)

;; Get project details
(define-read-only (get-project-details (project-id uint))
  (get-validated-project project-id)
)

;; Global variables
(define-data-var next-project-id uint u0)
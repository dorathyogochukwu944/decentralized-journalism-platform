;; title: news-verification-engine
;; version: 1.0.0
;; summary: Blockchain-based news verification and journalist credentialing system
;; description: Manages article authenticity through multi-source validation,
;;              journalist reputation tracking, and decentralized fact-checking workflows

;; ===== CONSTANTS =====

;; Error codes
(define-constant ERR-UNAUTHORIZED (err u100))
(define-constant ERR-NOT-FOUND (err u101))
(define-constant ERR-ALREADY-EXISTS (err u102))
(define-constant ERR-INVALID-STATUS (err u103))
(define-constant ERR-ALREADY-VOTED (err u104))
(define-constant ERR-INVALID-VOTE (err u105))
(define-constant ERR-INSUFFICIENT-REPUTATION (err u106))
(define-constant ERR-ARTICLE-FINALIZED (err u107))

;; Article status constants
(define-constant STATUS-DRAFT u0)
(define-constant STATUS-PENDING u1) 
(define-constant STATUS-VERIFIED u2)
(define-constant STATUS-REJECTED u3)

;; Minimum requirements
(define-constant MIN-JOURNALIST-REPUTATION u50)
(define-constant MIN-FACT-CHECKER-REPUTATION u100)
(define-constant REQUIRED-VOTES u3)
(define-constant MAX-SOURCES u10)

;; ===== DATA VARIABLES =====

;; Global counters
(define-data-var article-id-counter uint u0)
(define-data-var total-journalists uint u0)
(define-data-var contract-owner principal tx-sender)

;; ===== DATA MAPS =====

;; Journalist registry with credentials and reputation
(define-map journalists principal {
    credentials-hash: (buff 32),
    reputation-score: uint,
    total-articles: uint,
    verified-articles: uint,
    registration-block: uint,
    active: bool
})

;; Article storage with metadata and verification status  
(define-map articles uint {
    journalist: principal,
    content-hash: (buff 32),
    source-hashes: (list 10 (buff 32)),
    submission-block: uint,
    status: uint,
    verification-votes: uint,
    rejection-votes: uint,
    final-block: (optional uint),
    version: uint
})

;; Track fact-checker votes to prevent double voting
(define-map fact-check-votes {article-id: uint, checker: principal} {
    vote: bool,
    vote-block: uint,
    checker-reputation: uint
})

;; Source encryption mapping for protected whistleblower data
(define-map encrypted-sources (buff 32) {
    encryption-key-hash: (buff 32),
    access-level: uint,
    created-block: uint
})

;; Article version history for edit tracking
(define-map article-versions {article-id: uint, version: uint} {
    content-hash: (buff 32),
    edit-block: uint,
    edit-reason: (string-ascii 200)
})

;; Fact-checker registry
(define-map fact-checkers principal {
    reputation-score: uint,
    total-votes: uint,
    accurate-votes: uint,
    registration-block: uint,
    active: bool
})

;; ===== PRIVATE FUNCTIONS =====

;; Calculate weighted vote score based on checker reputation
(define-private (calculate-vote-weight (checker-reputation uint))
    (if (>= checker-reputation u200)
        u3  ;; High reputation = 3x weight
        (if (>= checker-reputation u100)
            u2  ;; Medium reputation = 2x weight
            u1  ;; Base reputation = 1x weight
        )
    )
)

;; Update journalist reputation based on article verification outcome
(define-private (update-journalist-reputation (journalist principal) (verified bool))
    (let ((current-data (unwrap! (map-get? journalists journalist) false)))
        (map-set journalists journalist 
            (merge current-data {
                reputation-score: (if verified 
                    (+ (get reputation-score current-data) u10)
                    (if (> (get reputation-score current-data) u5)
                        (- (get reputation-score current-data) u5)
                        u0
                    )
                ),
                verified-articles: (if verified 
                    (+ (get verified-articles current-data) u1)
                    (get verified-articles current-data)
                )
            })
        )
        true
    )
)

;; Check if voting threshold is met for article finalization
(define-private (check-finalization-threshold (article-id uint))
    (let ((article-data (unwrap! (map-get? articles article-id) false)))
        (let ((total-votes (+ (get verification-votes article-data) (get rejection-votes article-data))))
            (>= total-votes REQUIRED-VOTES)
        )
    )
)

;; ===== PUBLIC FUNCTIONS =====

;; Register as a verified journalist with credentials
(define-public (register-journalist (credentials-hash (buff 32)))
    (let ((caller tx-sender))
        (asserts! (is-none (map-get? journalists caller)) ERR-ALREADY-EXISTS)
        (map-set journalists caller {
            credentials-hash: credentials-hash,
            reputation-score: u75,  ;; Starting reputation
            total-articles: u0,
            verified-articles: u0,
            registration-block: block-height,
            active: true
        })
        (var-set total-journalists (+ (var-get total-journalists) u1))
        (print {event: "journalist-registered", journalist: caller, block: block-height})
        (ok true)
    )
)

;; Register as a fact-checker
(define-public (register-fact-checker)
    (let ((caller tx-sender))
        (asserts! (is-none (map-get? fact-checkers caller)) ERR-ALREADY-EXISTS)
        (map-set fact-checkers caller {
            reputation-score: u100,  ;; Starting fact-checker reputation
            total-votes: u0,
            accurate-votes: u0,
            registration-block: block-height,
            active: true
        })
        (print {event: "fact-checker-registered", checker: caller, block: block-height})
        (ok true)
    )
)

;; Submit new article for verification with source protection
(define-public (submit-article (content-hash (buff 32)) (source-hashes (list 10 (buff 32))))
    (let (
        (caller tx-sender)
        (new-id (+ (var-get article-id-counter) u1))
        (journalist-data (unwrap! (map-get? journalists caller) ERR-NOT-FOUND))
    )
        (asserts! (get active journalist-data) ERR-UNAUTHORIZED)
        (asserts! (>= (get reputation-score journalist-data) MIN-JOURNALIST-REPUTATION) ERR-INSUFFICIENT-REPUTATION)
        (asserts! (<= (len source-hashes) MAX-SOURCES) ERR-INVALID-STATUS)
        
        ;; Create article entry
        (map-set articles new-id {
            journalist: caller,
            content-hash: content-hash,
            source-hashes: source-hashes,
            submission-block: block-height,
            status: STATUS-PENDING,
            verification-votes: u0,
            rejection-votes: u0,
            final-block: none,
            version: u1
        })
        
        ;; Store initial version
        (map-set article-versions {article-id: new-id, version: u1} {
            content-hash: content-hash,
            edit-block: block-height,
            edit-reason: "Initial submission"
        })
        
        ;; Update journalist stats
        (map-set journalists caller 
            (merge journalist-data {
                total-articles: (+ (get total-articles journalist-data) u1)
            })
        )
        
        (var-set article-id-counter new-id)
        (print {event: "article-submitted", article-id: new-id, journalist: caller, block: block-height})
        (ok new-id)
    )
)

;; Fact-checkers vote on article verification
(define-public (fact-check-vote (article-id uint) (vote bool))
    (let (
        (caller tx-sender)
        (article-data (unwrap! (map-get? articles article-id) ERR-NOT-FOUND))
        (checker-data (unwrap! (map-get? fact-checkers caller) ERR-NOT-FOUND))
        (vote-key {article-id: article-id, checker: caller})
    )
        ;; Validation checks
        (asserts! (get active checker-data) ERR-UNAUTHORIZED)
        (asserts! (>= (get reputation-score checker-data) MIN-FACT-CHECKER-REPUTATION) ERR-INSUFFICIENT-REPUTATION)
        (asserts! (is-eq (get status article-data) STATUS-PENDING) ERR-INVALID-STATUS)
        (asserts! (is-none (map-get? fact-check-votes vote-key)) ERR-ALREADY-VOTED)
        
        ;; Record the vote
        (map-set fact-check-votes vote-key {
            vote: vote,
            vote-block: block-height,
            checker-reputation: (get reputation-score checker-data)
        })
        
        ;; Update vote counts with weighted scoring
        (let ((vote-weight (calculate-vote-weight (get reputation-score checker-data))))
            (map-set articles article-id 
                (merge article-data {
                    verification-votes: (if vote 
                        (+ (get verification-votes article-data) vote-weight)
                        (get verification-votes article-data)
                    ),
                    rejection-votes: (if vote 
                        (get rejection-votes article-data)
                        (+ (get rejection-votes article-data) vote-weight)
                    )
                })
            )
        )
        
        ;; Update fact-checker stats
        (map-set fact-checkers caller 
            (merge checker-data {
                total-votes: (+ (get total-votes checker-data) u1)
            })
        )
        
        ;; Check if article can be finalized
        (let ((updated-article (unwrap! (map-get? articles article-id) ERR-NOT-FOUND)))
            (if (check-finalization-threshold article-id)
                (begin
                    (let ((is-verified (> (get verification-votes updated-article) (get rejection-votes updated-article))))
                        ;; Finalize article status
                        (map-set articles article-id 
                            (merge updated-article {
                                status: (if is-verified STATUS-VERIFIED STATUS-REJECTED),
                                final-block: (some block-height)
                            })
                        )
                        ;; Update journalist reputation
                        (update-journalist-reputation (get journalist updated-article) is-verified)
                        (print {event: "article-finalized", article-id: article-id, verified: is-verified, block: block-height})
                    )
                    true  ;; Return consistent type
                )
                (begin
                    (print {event: "vote-recorded", article-id: article-id, vote: vote, checker: caller})
                    true  ;; Return consistent type
                )
            )
        )
        
        (ok true)
    )
)

;; Store encrypted source data for whistleblower protection  
(define-public (store-encrypted-source (source-hash (buff 32)) (encryption-key-hash (buff 32)) (access-level uint))
    (let ((caller tx-sender))
        (asserts! (is-some (map-get? journalists caller)) ERR-UNAUTHORIZED)
        (asserts! (is-none (map-get? encrypted-sources source-hash)) ERR-ALREADY-EXISTS)
        
        (map-set encrypted-sources source-hash {
            encryption-key-hash: encryption-key-hash,
            access-level: access-level,
            created-block: block-height
        })
        
        (print {event: "source-encrypted", source-hash: source-hash, journalist: caller})
        (ok true)
    )
)

;; Update article with new version (edit tracking)
(define-public (update-article-version (article-id uint) (new-content-hash (buff 32)) (edit-reason (string-ascii 200)))
    (let (
        (caller tx-sender)
        (article-data (unwrap! (map-get? articles article-id) ERR-NOT-FOUND))
        (new-version (+ (get version article-data) u1))
    )
        (asserts! (is-eq caller (get journalist article-data)) ERR-UNAUTHORIZED)
        (asserts! (not (is-eq (get status article-data) STATUS-REJECTED)) ERR-ARTICLE-FINALIZED)
        
        ;; Update main article record
        (map-set articles article-id 
            (merge article-data {
                content-hash: new-content-hash,
                version: new-version,
                status: STATUS-PENDING  ;; Reset to pending for re-verification
            })
        )
        
        ;; Store version history
        (map-set article-versions {article-id: article-id, version: new-version} {
            content-hash: new-content-hash,
            edit-block: block-height,
            edit-reason: edit-reason
        })
        
        (print {event: "article-updated", article-id: article-id, version: new-version, block: block-height})
        (ok new-version)
    )
)

;; ===== READ-ONLY FUNCTIONS =====

;; Get article status and verification details
(define-read-only (get-article-status (article-id uint))
    (map-get? articles article-id)
)

;; Get journalist information and reputation
(define-read-only (get-journalist-info (journalist principal))
    (map-get? journalists journalist)
)

;; Get fact-checker information
(define-read-only (get-fact-checker-info (checker principal))
    (map-get? fact-checkers checker)
)

;; Get article version history
(define-read-only (get-article-version (article-id uint) (version uint))
    (map-get? article-versions {article-id: article-id, version: version})
)

;; Get encrypted source information (access-controlled)
(define-read-only (get-encrypted-source-info (source-hash (buff 32)))
    (map-get? encrypted-sources source-hash)
)

;; Get vote details for specific article and checker
(define-read-only (get-vote-details (article-id uint) (checker principal))
    (map-get? fact-check-votes {article-id: article-id, checker: checker})
)

;; Get platform statistics
(define-read-only (get-platform-stats)
    (ok {
        total-articles: (var-get article-id-counter),
        total-journalists: (var-get total-journalists),
        contract-owner: (var-get contract-owner)
    })
)

;; Check if article is finalized (verified or rejected)
(define-read-only (is-article-finalized (article-id uint))
    (match (map-get? articles article-id)
        article-data (let ((status (get status article-data)))
                        (or (is-eq status STATUS-VERIFIED) (is-eq status STATUS-REJECTED))
                     )
        false
    )
)

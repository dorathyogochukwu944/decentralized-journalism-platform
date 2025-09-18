;; title: reader-funding-distributor
;; version: 1.0.0
;; summary: Direct reader-to-journalist funding and revenue distribution system
;; description: Facilitates STX tips, subscription management, revenue sharing,
;;              and financial analytics for sustainable journalism economics

;; ===== CONSTANTS =====

;; Error codes
(define-constant ERR-UNAUTHORIZED (err u200))
(define-constant ERR-NOT-FOUND (err u201))
(define-constant ERR-ALREADY-EXISTS (err u202))
(define-constant ERR-INSUFFICIENT-FUNDS (err u203))
(define-constant ERR-INVALID-AMOUNT (err u204))
(define-constant ERR-INVALID-TIER (err u205))
(define-constant ERR-SUBSCRIPTION-EXPIRED (err u206))
(define-constant ERR-WITHDRAWAL-LIMIT (err u207))
(define-constant ERR-INVALID-EPOCH (err u208))

;; Membership tier constants
(define-constant TIER-BRONZE u1)
(define-constant TIER-SILVER u2) 
(define-constant TIER-GOLD u3)

;; Subscription pricing (in micro-STX)
(define-constant BRONZE-PRICE u5000000)    ;; 5 STX per month
(define-constant SILVER-PRICE u15000000)   ;; 15 STX per month  
(define-constant GOLD-PRICE u30000000)     ;; 30 STX per month

;; Revenue sharing percentages (basis points: 100 = 1%)
(define-constant PLATFORM-FEE-BP u500)     ;; 5% platform fee
(define-constant JOURNALIST-SHARE-BP u7500) ;; 75% to journalist
(define-constant AD-REVENUE-SHARE-BP u2000) ;; 20% from ad revenue

;; Time constants
(define-constant SUBSCRIPTION-DURATION u144) ;; ~1 month in blocks (10min blocks)
(define-constant EPOCH-LENGTH u1008)        ;; ~1 week in blocks for revenue distribution
(define-constant MIN-WITHDRAWAL-AMOUNT u1000000) ;; 1 STX minimum withdrawal

;; ===== DATA VARIABLES =====

;; Global state tracking
(define-data-var total-tips-distributed uint u0)
(define-data-var total-subscription-revenue uint u0)
(define-data-var total-ad-revenue uint u0)
(define-data-var current-epoch uint u0)
(define-data-var contract-owner principal tx-sender)
(define-data-var platform-treasury uint u0)

;; Governance variables (adjustable by DAO - placeholder for future governance)
(define-data-var journalist-revenue-share uint JOURNALIST-SHARE-BP)
(define-data-var platform-fee-rate uint PLATFORM-FEE-BP)
(define-data-var ad-revenue-share uint AD-REVENUE-SHARE-BP)

;; ===== DATA MAPS =====

;; Reader subscription management
(define-map reader-subscriptions principal {
    tier: uint,
    expiry-block: uint,
    total-paid: uint,
    subscription-start: uint,
    auto-renew: bool
})

;; Journalist earnings and withdrawal tracking
(define-map journalist-finances principal {
    total-earned: uint,
    total-withdrawn: uint,
    pending-balance: uint,
    last-withdrawal-block: uint,
    tip-count: uint,
    subscription-earnings: uint,
    ad-earnings: uint
})

;; Individual tip transaction records
(define-map tip-transactions uint {
    from-reader: principal,
    to-journalist: principal,
    amount: uint,
    tip-block: uint,
    message: (string-ascii 280)
})

;; Article engagement tracking for revenue distribution
(define-map article-engagement uint {
    journalist: principal,
    view-count: uint,
    tip-count: uint,
    total-tips: uint,
    engagement-score: uint,
    last-updated: uint
})

;; Epoch-based ad revenue distribution weights
(define-map epoch-weights {epoch: uint, journalist: principal} {
    engagement-weight: uint,
    article-count: uint,
    total-views: uint,
    payout-amount: uint
})

;; Subscription tier benefits and analytics
(define-map tier-analytics uint {
    active-subscribers: uint,
    total-revenue: uint,
    average-duration: uint,
    renewal-rate: uint
})

;; Transaction counters
(define-data-var tip-id-counter uint u0)
(define-data-var total-active-subscriptions uint u0)

;; ===== PRIVATE FUNCTIONS =====

;; Calculate platform fee from amount
(define-private (calculate-platform-fee (amount uint))
    (/ (* amount (var-get platform-fee-rate)) u10000)
)

;; Calculate journalist share after platform fee
(define-private (calculate-journalist-share (amount uint))
    (let ((platform-fee (calculate-platform-fee amount)))
        (- amount platform-fee)
    )
)

;; Update journalist financial records
(define-private (update-journalist-earnings (journalist principal) (amount uint) (earning-type (string-ascii 20)))
    (let ((current-finances (default-to 
            {total-earned: u0, total-withdrawn: u0, pending-balance: u0, 
             last-withdrawal-block: u0, tip-count: u0, subscription-earnings: u0, ad-earnings: u0}
            (map-get? journalist-finances journalist)
         )))
        (map-set journalist-finances journalist 
            (merge current-finances {
                total-earned: (+ (get total-earned current-finances) amount),
                pending-balance: (+ (get pending-balance current-finances) amount),
                tip-count: (if (is-eq earning-type "tip") 
                    (+ (get tip-count current-finances) u1)
                    (get tip-count current-finances)
                ),
                subscription-earnings: (if (is-eq earning-type "subscription")
                    (+ (get subscription-earnings current-finances) amount)
                    (get subscription-earnings current-finances)
                ),
                ad-earnings: (if (is-eq earning-type "ad-revenue")
                    (+ (get ad-earnings current-finances) amount)
                    (get ad-earnings current-finances)
                )
            })
        )
        true
    )
)

;; Check if subscription is currently active
(define-private (is-subscription-active (reader principal))
    (match (map-get? reader-subscriptions reader)
        sub-data (> (get expiry-block sub-data) block-height)
        false
    )
)

;; Get subscription tier for reader
(define-private (get-reader-tier (reader principal))
    (match (map-get? reader-subscriptions reader)
        sub-data (if (is-subscription-active reader) 
                    (some (get tier sub-data)) 
                    none)
        none
    )
)

;; Update platform treasury with fees
(define-private (add-to-treasury (amount uint))
    (var-set platform-treasury (+ (var-get platform-treasury) amount))
)

;; ===== PUBLIC FUNCTIONS =====

;; Direct STX tip to journalist
(define-public (tip-journalist (journalist principal) (amount uint) (message (string-ascii 280)))
    (let (
        (caller tx-sender)
        (tip-id (+ (var-get tip-id-counter) u1))
        (platform-fee (calculate-platform-fee amount))
        (journalist-amount (calculate-journalist-share amount))
    )
        ;; Validation
        (asserts! (> amount u0) ERR-INVALID-AMOUNT)
        (asserts! (not (is-eq caller journalist)) ERR-UNAUTHORIZED)
        
        ;; Transfer STX from reader to contract
        (try! (stx-transfer? amount caller (as-contract tx-sender)))
        
        ;; Transfer journalist share to journalist
        (try! (as-contract (stx-transfer? journalist-amount tx-sender journalist)))
        
        ;; Add platform fee to treasury
        (add-to-treasury platform-fee)
        
        ;; Record tip transaction
        (map-set tip-transactions tip-id {
            from-reader: caller,
            to-journalist: journalist,
            amount: amount,
            tip-block: block-height,
            message: message
        })
        
        ;; Update journalist earnings
        (update-journalist-earnings journalist journalist-amount "tip")
        
        ;; Update global statistics
        (var-set tip-id-counter tip-id)
        (var-set total-tips-distributed (+ (var-get total-tips-distributed) amount))
        
        (print {event: "tip-sent", from: caller, to: journalist, amount: amount, tip-id: tip-id})
        (ok tip-id)
    )
)

;; Purchase or renew subscription
(define-public (subscribe (tier uint) (auto-renew bool))
    (let (
        (caller tx-sender)
        (price (if (is-eq tier TIER-BRONZE) BRONZE-PRICE
                (if (is-eq tier TIER-SILVER) SILVER-PRICE
                (if (is-eq tier TIER-GOLD) GOLD-PRICE
                u0))))
        (platform-fee (calculate-platform-fee price))
        (revenue-share (- price platform-fee))
        (new-expiry (+ block-height SUBSCRIPTION-DURATION))
    )
        ;; Validation
        (asserts! (and (>= tier TIER-BRONZE) (<= tier TIER-GOLD)) ERR-INVALID-TIER)
        (asserts! (> price u0) ERR-INVALID-AMOUNT)
        
        ;; Transfer subscription payment
        (try! (stx-transfer? price caller (as-contract tx-sender)))
        
        ;; Update or create subscription
        (map-set reader-subscriptions caller {
            tier: tier,
            expiry-block: new-expiry,
            total-paid: (+ price (get total-paid (default-to {tier: u0, expiry-block: u0, total-paid: u0, subscription-start: u0, auto-renew: false} (map-get? reader-subscriptions caller)))),
            subscription-start: (match (map-get? reader-subscriptions caller)
                existing (get subscription-start existing)
                block-height
            ),
            auto-renew: auto-renew
        })
        
        ;; Add to treasury and update global stats
        (add-to-treasury platform-fee)
        (var-set total-subscription-revenue (+ (var-get total-subscription-revenue) revenue-share))
        (var-set total-active-subscriptions (+ (var-get total-active-subscriptions) u1))
        
        ;; Update tier analytics
        (let ((current-analytics (default-to {active-subscribers: u0, total-revenue: u0, average-duration: u0, renewal-rate: u0} 
                                            (map-get? tier-analytics tier))))
            (map-set tier-analytics tier 
                (merge current-analytics {
                    active-subscribers: (+ (get active-subscribers current-analytics) u1),
                    total-revenue: (+ (get total-revenue current-analytics) revenue-share)
                })
            )
        )
        
        (print {event: "subscription-purchased", reader: caller, tier: tier, expiry: new-expiry})
        (ok new-expiry)
    )
)

;; Distribute advertising revenue to single journalist (simplified version)
(define-public (distribute-ad-revenue-to-journalist (journalist principal) (amount uint))
    (let ((caller tx-sender))
        ;; Only contract owner can distribute ad revenue (could be DAO in future)
        (asserts! (is-eq caller (var-get contract-owner)) ERR-UNAUTHORIZED)
        (asserts! (> amount u0) ERR-INVALID-AMOUNT)
        
        ;; Update journalist earnings
        (update-journalist-earnings journalist amount "ad-revenue")
        
        ;; Update global ad revenue tracking
        (var-set total-ad-revenue (+ (var-get total-ad-revenue) amount))
        
        (print {event: "ad-revenue-distributed", journalist: journalist, amount: amount})
        (ok amount)
    )
)


;; Withdraw accumulated earnings
(define-public (withdraw-earnings (amount uint))
    (let (
        (caller tx-sender)
        (current-finances (unwrap! (map-get? journalist-finances caller) ERR-NOT-FOUND))
    )
        ;; Validation
        (asserts! (>= amount MIN-WITHDRAWAL-AMOUNT) ERR-INVALID-AMOUNT)
        (asserts! (>= (get pending-balance current-finances) amount) ERR-INSUFFICIENT-FUNDS)
        
        ;; Transfer STX to journalist
        (try! (as-contract (stx-transfer? amount tx-sender caller)))
        
        ;; Update financial records
        (map-set journalist-finances caller 
            (merge current-finances {
                total-withdrawn: (+ (get total-withdrawn current-finances) amount),
                pending-balance: (- (get pending-balance current-finances) amount),
                last-withdrawal-block: block-height
            })
        )
        
        (print {event: "earnings-withdrawn", journalist: caller, amount: amount})
        (ok amount)
    )
)

;; Update article engagement for revenue calculations
(define-public (update-article-engagement (article-id uint) (journalist principal) (new-views uint) (new-tips uint) (tip-amount uint))
    (let ((caller tx-sender))
        ;; Simple authorization - could be enhanced with oracle or journalist verification
        (let ((current-engagement (default-to 
                {journalist: journalist, view-count: u0, tip-count: u0, total-tips: u0, engagement-score: u0, last-updated: u0}
                (map-get? article-engagement article-id)
             )))
            (let (
                (updated-views (+ (get view-count current-engagement) new-views))
                (updated-tips (+ (get tip-count current-engagement) new-tips))
                (updated-tip-total (+ (get total-tips current-engagement) tip-amount))
                (engagement-score (+ (* updated-views u1) (* updated-tips u5) (/ updated-tip-total u1000000))) ;; Weighted engagement
            )
                (map-set article-engagement article-id {
                    journalist: journalist,
                    view-count: updated-views,
                    tip-count: updated-tips,
                    total-tips: updated-tip-total,
                    engagement-score: engagement-score,
                    last-updated: block-height
                })
                
                (print {event: "engagement-updated", article-id: article-id, score: engagement-score})
                (ok engagement-score)
            )
        )
    )
)

;; ===== READ-ONLY FUNCTIONS =====

;; Get reader subscription details
(define-read-only (get-subscription-info (reader principal))
    (map-get? reader-subscriptions reader)
)

;; Get journalist financial summary
(define-read-only (get-financial-stats (journalist principal))
    (map-get? journalist-finances journalist)
)

;; Get tip transaction details
(define-read-only (get-tip-details (tip-id uint))
    (map-get? tip-transactions tip-id)
)

;; Get article engagement metrics
(define-read-only (get-article-engagement (article-id uint))
    (map-get? article-engagement article-id)
)

;; Get tier-specific analytics
(define-read-only (get-tier-analytics (tier uint))
    (map-get? tier-analytics tier)
)

;; Get subscription pricing for tier
(define-read-only (get-subscription-price (tier uint))
    (ok (if (is-eq tier TIER-BRONZE) BRONZE-PRICE
        (if (is-eq tier TIER-SILVER) SILVER-PRICE
        (if (is-eq tier TIER-GOLD) GOLD-PRICE
        u0))))
)

;; Get platform revenue statistics
(define-read-only (get-platform-stats)
    (ok {
        total-tips: (var-get total-tips-distributed),
        total-subscriptions: (var-get total-subscription-revenue),
        total-ad-revenue: (var-get total-ad-revenue),
        active-subscriptions: (var-get total-active-subscriptions),
        platform-treasury: (var-get platform-treasury),
        current-epoch: (var-get current-epoch)
    })
)

;; Check reader access level for content
(define-read-only (check-reader-access (reader principal))
    (match (get-reader-tier reader)
        tier (ok {has-access: true, tier: tier})
        (ok {has-access: false, tier: u0})
    )
)

;; Calculate potential earnings for journalist based on engagement
(define-read-only (estimate-ad-revenue-share (article-id uint) (total-ad-pool uint))
    (match (map-get? article-engagement article-id)
        engagement-data 
            (let ((engagement-score (get engagement-score engagement-data)))
                ;; This is simplified - real implementation would sum all engagement scores
                (ok (/ (* total-ad-pool engagement-score) u1000)) ;; Placeholder calculation
            )
        (ok u0)
    )
)

;; Get revenue sharing configuration (governance-adjustable)
(define-read-only (get-revenue-config)
    (ok {
        journalist-share: (var-get journalist-revenue-share),
        platform-fee: (var-get platform-fee-rate),
        ad-revenue-share: (var-get ad-revenue-share)
    })
)

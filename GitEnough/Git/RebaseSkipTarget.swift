/// The replay and destination HEAD that a Skip confirmation authorizes.
struct RebaseSkipTarget: Equatable {
    let commit: String
    let headHash: String
}

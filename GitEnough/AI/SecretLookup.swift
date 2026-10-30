/// What a secret store said when asked for a secret.
///
/// `absent` and `unavailable` are kept apart because collapsing them destroys
/// data: a caller that reads "I could not look" as "there is nothing there"
/// will happily write an empty value over a key the user never touched. Only
/// `absent` is evidence that nothing is stored.
public enum SecretLookup: Equatable {
    case found(String)
    case absent
    case unavailable
}

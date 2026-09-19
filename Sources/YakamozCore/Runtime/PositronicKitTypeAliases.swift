import PositronicKit

/// Disambiguates PositronicKit's Timeline value type from Yakamoz's own
/// `ConversationModel`/`TimelineModel` rows at consumer call sites.
public typealias YakamozThread = TimelineRecord

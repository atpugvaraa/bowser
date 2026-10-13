import Foundation

/// Case- and diacritic-insensitive text for searching ("cafe" finds "Café"). Used for stored search columns AND queries.
public enum Fold {
  public static func text(_ s: String) -> String { s.folding(options: [.diacriticInsensitive, .caseInsensitive, .widthInsensitive], locale: nil) }
}

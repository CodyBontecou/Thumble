import Foundation
import ThumbleContracts

/// Semantic accepted-state selection; wire quantization never decides appearance.
public enum PhonePresentationBank: String, Sendable, CaseIterable {
  case base
  case leftTrigger = "left-trigger"
  case rightTrigger = "right-trigger"
  case bothTriggers = "both-triggers"

  public init(accepted state: GamepadStateV1) {
    switch (state.leftTrigger > 0.5, state.rightTrigger > 0.5) {
    case (false, false): self = .base
    case (true, false): self = .leftTrigger
    case (false, true): self = .rightTrigger
    case (true, true): self = .bothTriggers
    }
  }
}

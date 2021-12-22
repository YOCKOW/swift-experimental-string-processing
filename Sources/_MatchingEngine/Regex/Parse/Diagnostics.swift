// MARK: - Parse errors

enum ParseError: Error, Hashable {
  // TODO: I wonder if it makes sense to store the string.
  // This can make equality weird.

  case numberOverflow(String)
  case expectedNumDigits(String, Int)
  case expectedNumber(String, kind: RadixKind)

  // Expected the given character or string
  case expected(String)

  // Expected something, anything really
  case unexpectedEndOfInput

  // Something happened, fall-back for now
  case misc(String)

  case expectedASCII(Character)

  case expectedCustomCharacterClassMembers
  case invalidCharacterClassRangeOperand

  case invalidPOSIXSetName(String)
  case emptyProperty

  case expectedGroupSpecifier
  case cannotRemoveTextSegmentOptions
}

extension ParseError: CustomStringConvertible {
  var description: String {
    switch self {
    case let .numberOverflow(s):
      return "number overflow: \(s)"
    case let .expectedNumDigits(s, i):
      return "expected \(i) digits in '\(s)'"
    case let .expectedNumber(s, kind: kind):
      let radix: String
      if kind == .decimal {
        radix = ""
      } else {
        radix = " of radix \(kind.radix)"
      }
      return "expected a numbers in '\(s)'\(radix)"
    case let .expected(s):
      return "expected '\(s)'"
    case .unexpectedEndOfInput:
      return "unexpected end of input"
    case let .misc(s):
      return s
    case let .expectedASCII(c):
      return "expected ASCII for '\(c)'"
    case .expectedCustomCharacterClassMembers:
      return "expected custom character class members"
    case .invalidCharacterClassRangeOperand:
      return "invalid character class range"
    case let .invalidPOSIXSetName(n):
      return "invalid character set name: '\(n)'"
    case .emptyProperty:
      return "empty property"
    case .expectedGroupSpecifier:
      return "expected group specifier"
    case .cannotRemoveTextSegmentOptions:
      return "text segment mode cannot be unset, only changed"
    }
  }
}

// TODO: Fixits, notes, etc.

// TODO: Diagnostics engine, recorder, logger, or similar.



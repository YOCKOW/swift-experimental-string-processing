import _MatchingEngine

struct RegexProgram {
  typealias Program = _MatchingEngine.Program<String>
  var program: Program
}

class Compiler {
  let ast: AST
  let matchLevel: CharacterClass.MatchLevel
  let options: REOptions
  private var builder = RegexProgram.Program.Builder()

  init(
    ast: AST,
    matchLevel: CharacterClass.MatchLevel = .graphemeCluster,
    options: REOptions = []
  ) {
    self.ast = ast
    self.matchLevel = matchLevel
    self.options = options
  }

  __consuming func emit() throws -> RegexProgram {
    try emit(ast)
    builder.buildAccept()
    let program = builder.assemble()
    return RegexProgram(program: program)
  }

  func emit(_ node: AST) throws {

    switch node {
    // Any: .
    //     consume 1
    case .atom(let a) where a.kind == .any && matchLevel == .graphemeCluster:
      builder.buildAdvance(1)

    // Single characters we just match
    case .atom(let a) where a.singleCharacter != nil :
      builder.buildMatch(a.singleCharacter!)

    // Alternation: p0 | p1 | ... | pn
    //     save next_p1
    //     <code for p0>
    //     branch done
    //   next_p1:
    //     save next_p2
    //     <code for p1>
    //     branch done
    //   next_p2:
    //     save next_p...
    //     <code for p2>
    //     branch done
    //   ...
    //   next_pn:
    //     <code for pn>
    //   done:
    case .alternation(let alt):
      let done = builder.makeAddress()
      for component in alt.children.dropLast() {
        let next = builder.makeAddress()
        builder.buildSave(next)
        try emit(component)
        builder.buildBranch(to: done)
        builder.label(next)
      }
      try emit(alt.children.last!)
      builder.label(done)

    // FIXME: Wait, how does this work?
    case .groupTransform(let g, _):
      try emit(g.child)


    case .concatenation(let concat):
      try concat.children.forEach(emit)

    case .trivia, .empty:
      break

    // FIXME: This can't be right...
    case .group(let g):
      try emit(g.child)

    case .quantification(let quant):
      try emitQuantification(quant)

    // For now, we model sets and atoms as consumers.
    // This lets us rapidly expand support, and we can better
    // design the actual instruction set with real examples
    case _ where try node.generateConsumer(matchLevel) != nil:
      try builder.buildConsume(by: node.generateConsumer(matchLevel)!)

    case .quote(let q):
      // We stick quoted content into read-only constant strings
      builder.buildMatchSequence(q.literal)

    case .customCharacterClass, .atom:
      throw unsupported(node._dumpBase)
    }
  }

  func compileQuantification(
    low: Int,
    high: Int?,
    kind: AST.Quantification.Kind,
    child: AST
  ) throws {
    // Compiler and/or parser should enforce these invariants
    // before we are called
    assert(high != 0)
    assert((0...(high ?? Int.max)).contains(low))

    let extraTrips: Int?
    if let h = high {
      extraTrips = h - low
    } else {
      extraTrips = nil
    }
    let minTrips = low
    assert((extraTrips ?? 1) >= 0)

    // The below is a general algorithm for bounded and unbounded
    // quantification. It can be specialized when the min
    // is 0 or 1, or when extra trips is 1 or unbounded.
    //
    // Stuff inside `<` and `>` are decided at compile time,
    // while run-time values stored in registers start with a `%`
    _ = """
      min-trip-count control block:
        if %minTrips is zero:
          goto exit-policy control block
        else:
          decrement %minTrips and fallthrough

      loop-body:
        evaluate the subexpression
        goto min-trip-count control block

      exit-policy control block:
        if %extraTrips is zero:
          goto exit
        else:
          decrement %extraTrips and fallthrough

        <if eager>:
          save exit and goto loop-body
        <if possessive>:
          ratchet and goto loop
        <if reluctant>:
          save loop-body and fallthrough (i.e. goto exit)

      exit
        ... the rest of the program ...
    """

    // Specialization based on `minTrips` for 0 or 1:
    _ = """
      min-trip-count control block:
        <if minTrips == 0>:
          goto exit-policy
        <if minTrips == 1>:
          /* fallthrough */

      loop-body:
        evaluate the subexpression
        <if minTrips <= 1>
          /* fallthrough */
    """

    // Specialization based on `extraTrips` for 0 or unbounded
    _ = """
      exit-policy control block:
        <if extraTrips == 0>:
          goto exit
        <if extraTrips == .unbounded>:
          /* fallthrough */
    """

    /*
      NOTE: These specializations don't emit the optimal
      code layout (e.g. fallthrough vs goto), but that's better
      done later (not prematurely) and certainly better
      done by an optimizing compiler.

      NOTE: We're intentionally emitting essentially the same
      algorithm for all quantifications for now, for better
      testing and surfacing difficult bugs. We can specialize
      for other things, like `.*`, later.

      When it comes time for optimizing, we can also look into
      quantification instructions (e.g. reduce save-point traffic)
    */

    let minTripsControl = builder.makeAddress()
    let loopBody = builder.makeAddress()
    let exitPolicy = builder.makeAddress()
    let exit = builder.makeAddress()

    // We'll need registers if we're (non-trivially) bounded
    let minTripsReg: IntRegister?
    if minTrips > 1 {
      minTripsReg = builder.makeIntRegister(
        initialValue: minTrips)
    } else {
      minTripsReg = nil
    }

    let extraTripsReg: IntRegister?
    if (extraTrips ?? 0) > 0 {
      extraTripsReg = builder.makeIntRegister(
        initialValue: extraTrips!)
    } else {
      extraTripsReg = nil
    }

    // Set up a dummy save point for possessive to update
    if kind == .possessive {
      builder.pushEmptySavePoint()
    }

    // min-trip-count:
    //   condBranch(to: exitPolicy, ifZeroElseDecrement: %min)
    builder.label(minTripsControl)
    switch minTrips {
    case 0: builder.buildBranch(to: exitPolicy)
    case 1: break
    default:
      assert(minTripsReg != nil, "logic inconsistency")
      builder.buildCondBranch(
        to: exitPolicy, ifZeroElseDecrement: minTripsReg!)
    }

    // FIXME: Possessive needs a "dummy" save point to ratchet

    // loop:
    //   <subexpression>
    //   branch min-trip-count
    builder.label(loopBody)
    try emit(child)
    if minTrips <= 1 {
      // fallthrough
    } else {
      builder.buildBranch(to: minTripsControl)
    }

    // exit-policy:
    //   condBranch(to: exit, ifZeroElseDecrement: %extraTrips)
    //   <eager: split(to: loop, saving: exit)>
    //   <possesive:
    //     clearSavePoint
    //     split(to: loop, saving: exit)>
    //   <reluctant: save(restoringAt: loop)
    builder.label(exitPolicy)
    switch extraTrips {
    case nil: break
    case 0:   builder.buildBranch(to: exit)
    default:
      assert(extraTripsReg != nil, "logic inconsistency")
      builder.buildCondBranch(
        to: exit, ifZeroElseDecrement: extraTripsReg!)
    }

    switch kind {
    case .eager:
      builder.buildSplit(to: loopBody, saving: exit)
    case .possessive:
      builder.buildClear()
      builder.buildSplit(to: loopBody, saving: exit)
    case .reluctant:
      builder.buildSave(loopBody)
      // FIXME: Is this re-entrant? That is would nested
      // quantification break if trying to restore to a prior
      // iteration because the register got overwritten?
      //
    }

    builder.label(exit)
  }

  func emitQuantification(_ quant: AST.Quantification) throws {
    let child = quant.child
    let kind = quant.kind.value

    switch quant.amount.value.bounds {
    case (_, atMost: 0):
      // TODO: Parser should warn
      return
    case let (atLeast: n, atMost: m?) where n > m:
      // TODO: Parser should warn
      // TODO: Should we error?
      return

    case let (atLeast: n, atMost: m) where m == nil || n <= m!:
      try compileQuantification(
        low: n, high: m, kind: kind, child: child)
      return

    default:
      fatalError("unreachable")
    }
  }
}

public func _compileRegex(
  _ regex: String, _ syntax: SyntaxOptions = .traditional
) throws -> Executor {
  let ast = try parse(regex, .traditional)
  let program = try Compiler(ast: ast).emit()
  return Executor(program: program)
}

import Foundation
import Metal
import Testing

@testable import TUFFEngine

extension RawCompletionLoopTests {
  @Test func stopsOnEOS() async throws {
    let tok = try await GFTokenizer.load()
    let idA = tok.encode("a", addBOS: false).first!
    let idB = tok.encode("b", addBOS: false).first!
    let (collected, result) = try await runLoop(
      seq: [idA, idB], end: tok.eosID,
      config: GenerationConfig(maxNewTokens: 50, temperature: 0))
    #expect(result.reason == .eos)
    #expect(result.newTokens == 3)
    #expect(collected.tokens.map(\.1) == [idA, idB])
  }

  @Test func stopsOnEndOfTurn() async throws {
    let tok = try await GFTokenizer.load()
    let idA = tok.encode("a", addBOS: false).first!
    let (_, result) = try await runLoop(
      seq: [idA], end: tok.endOfTurnID,
      config: GenerationConfig(maxNewTokens: 50, temperature: 0))
    #expect(result.reason == .endOfTurn)
  }

  @Test func stopsOnMaxTokensAndCountsExactly() async throws {
    let tok = try await GFTokenizer.load()
    let idA = tok.encode("a", addBOS: false).first!
    let (collected, result) = try await runLoop(
      seq: [idA, idA], end: idA,
      config: GenerationConfig(maxNewTokens: 5, temperature: 0))
    #expect(result.reason == .maxTokens)
    #expect(result.newTokens == 5)
    #expect(collected.tokens.count == 5)
    #expect(collected.tokens.map(\.0) == [0, 1, 2, 3, 4])
  }

  @Test func stopsOnStopString() async throws {
    let tok = try await GFTokenizer.load()
    let idA = tok.encode("a", addBOS: false).first!
    let textA = tok.decode([idA], skipSpecialTokens: true)
    let (_, result) = try await runLoop(
      seq: [idA, idA], end: idA,
      config: GenerationConfig(maxNewTokens: 50, temperature: 0, stopStrings: [textA]))
    #expect(result.reason == .stopString)
  }

  @Test func onlyStopTokenBoundariesAreUndelivered() async throws {
    let tok = try await GFTokenizer.load()
    let idA = tok.encode("a", addBOS: false).first!
    let idB = tok.encode("b", addBOS: false).first!

    // A stop token is never reported as `.token`.
    let (eosCollected, eos) = try await runLoop(
      seq: [idA, idB], end: tok.eosID,
      config: GenerationConfig(maxNewTokens: 50, temperature: 0))
    #expect(eos.uncommittedBoundaryTokenIDs == [tok.eosID])
    #expect(eos.undeliveredBoundaryTokenIDs == [tok.eosID])
    #expect(!eosCollected.tokens.map(\.1).contains(tok.eosID))

    let extraStop = GenerationConfig(
      maxNewTokens: 50, temperature: 0, extraStopTokens: [idB])
    let (_, extra) = try await runLoop(seq: [idA, idB], end: tok.eosID, config: extraStop)
    #expect(extra.reason == .eos)
    #expect(extra.undeliveredBoundaryTokenIDs == [idB])

    // A length, stop-string or cancelled boundary was already reported.
    let (maxCollected, max) = try await runLoop(
      seq: [idA, idB], end: tok.eosID,
      config: GenerationConfig(maxNewTokens: 2, temperature: 0))
    #expect(max.reason == .maxTokens)
    #expect(max.uncommittedBoundaryTokenIDs == [idB])
    #expect(max.undeliveredBoundaryTokenIDs.isEmpty)
    #expect(maxCollected.tokens.last?.1 == idB)

    let textA = tok.decode([idA], skipSpecialTokens: true)
    let (_, stop) = try await runLoop(
      seq: [idA, idA], end: idA,
      config: GenerationConfig(maxNewTokens: 50, temperature: 0, stopStrings: [textA]))
    #expect(stop.reason == .stopString)
    #expect(stop.uncommittedBoundaryTokenIDs == [idA])
    #expect(stop.undeliveredBoundaryTokenIDs.isEmpty)
  }

}

# beacon_chain
# Copyright (c) 2018-2022 Status Research & Development GmbH
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at https://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at https://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed except according to those terms.

{.used.}

import
  # Standard library
  std/[json, os, sequtils, strutils, tables],
  # Status libraries
  stew/[results, endians2], chronicles,
  eth/keys, taskpools,
  # Internals
  ../../beacon_chain/spec/[helpers, forks, state_transition_block],
  ../../beacon_chain/spec/datatypes/[
    base,
    phase0, altair, bellatrix],
  ../../beacon_chain/fork_choice/[fork_choice, fork_choice_types],
  ../../beacon_chain/[beacon_chain_db, beacon_clock],
  ../../beacon_chain/consensus_object_pools/[
    blockchain_dag, block_clearance, block_quarantine, spec_cache],
  # Third-party
  yaml,
  # Test
  ../testutil,
  ./fixtures_utils

# Test format described at https://github.com/ethereum/consensus-specs/tree/v1.2.0-rc.1/tests/formats/fork_choice
# Note that our implementation has been optimized with "ProtoArray"
# instead of following the spec (in particular the "store").

type
  OpKind = enum
    opOnTick
    opOnAttestation
    opOnBlock
    opOnMergeBlock
    opOnAttesterSlashing
    opChecks

  Operation = object
    valid: bool
    # variant specific fields
    case kind: OpKind
    of opOnTick:
      tick: int
    of opOnAttestation:
      att: Attestation
    of opOnBlock:
      blck: ForkedSignedBeaconBlock
    of opOnMergeBlock:
      powBlock: PowBlock
    of opOnAttesterSlashing:
      attesterSlashing: AttesterSlashing
    of opChecks:
      checks: JsonNode

proc initialLoad(
    path: string, db: BeaconChainDB,
    StateType, BlockType: typedesc
): tuple[dag: ChainDAGRef, fkChoice: ref ForkChoice] =
  let
    forkedState = loadForkedState(
      path/"anchor_state.ssz_snappy",
      StateType.toFork)

    blck = parseTest(
      path/"anchor_block.ssz_snappy",
      SSZ, BlockType)

  when BlockType is bellatrix.BeaconBlock:
    let signedBlock = ForkedSignedBeaconBlock.init(bellatrix.SignedBeaconBlock(
      message: blck,
      # signature: - unused as it's trusted
      root: hash_tree_root(blck)
    ))
  elif BlockType is altair.BeaconBlock:
    let signedBlock = ForkedSignedBeaconBlock.init(altair.SignedBeaconBlock(
      message: blck,
      # signature: - unused as it's trusted
      root: hash_tree_root(blck)
    ))
  elif BlockType is phase0.BeaconBlock:
    let signedBlock = ForkedSignedBeaconBlock.init(phase0.SignedBeaconBlock(
      message: blck,
      # signature: - unused as it's trusted
      root: hash_tree_root(blck)
    ))
  else: {.error: "Unknown block fork: " & name(BlockType).}

  ChainDAGRef.preInit(
    db,
    forkedState[], forkedState[],
    asTrusted(signedBlock))

  let
    validatorMonitor = newClone(ValidatorMonitor.init())
    dag = ChainDAGRef.init(
      forkedState[].kind.genesisTestRuntimeConfig, db, validatorMonitor, {})
    fkChoice = newClone(ForkChoice.init(
      dag.getFinalizedEpochRef(),
      dag.finalizedHead.blck,
    ))

  (dag, fkChoice)

proc loadOps(path: string, fork: BeaconStateFork): seq[Operation] =
  let stepsYAML = readFile(path/"steps.yaml")
  let steps = yaml.loadToJson(stepsYAML)

  result = @[]
  for step in steps[0]:
    if step.hasKey"tick":
      result.add Operation(kind: opOnTick,
        tick: step["tick"].getInt())
    elif step.hasKey"attestation":
      let filename = step["attestation"].getStr()
      let att = parseTest(
          path/filename & ".ssz_snappy",
          SSZ, Attestation
      )
      result.add Operation(kind: opOnAttestation,
        att: att)
    elif step.hasKey"block":
      let filename = step["block"].getStr()
      case fork
      of BeaconStateFork.Phase0:
        let blck = parseTest(
          path/filename & ".ssz_snappy",
          SSZ, phase0.SignedBeaconBlock
        )
        result.add Operation(kind: opOnBlock,
          blck: ForkedSignedBeaconBlock.init(blck))
      of BeaconStateFork.Altair:
        let blck = parseTest(
          path/filename & ".ssz_snappy",
          SSZ, altair.SignedBeaconBlock
        )
        result.add Operation(kind: opOnBlock,
          blck: ForkedSignedBeaconBlock.init(blck))
      of BeaconStateFork.Bellatrix:
        let blck = parseTest(
          path/filename & ".ssz_snappy",
          SSZ, bellatrix.SignedBeaconBlock
        )
        result.add Operation(kind: opOnBlock,
          blck: ForkedSignedBeaconBlock.init(blck))
    elif step.hasKey"attester_slashing":
      let filename = step["attester_slashing"].getStr()
      let attesterSlashing = parseTest(
        path/filename & ".ssz_snappy",
        SSZ, AttesterSlashing
      )
      result.add Operation(kind: opOnAttesterSlashing,
        attesterSlashing: attesterSlashing)
    elif step.hasKey"checks":
      result.add Operation(kind: opChecks,
        checks: step["checks"])
    else:
      doAssert false, "Unknown test step: " & $step

    if step.hasKey"valid":
      doAssert step.len == 2
      result[^1].valid = step["valid"].getBool()
    elif not step.hasKey"checks":
      doAssert step.len == 1
      result[^1].valid = true

proc stepOnBlock(
       dag: ChainDAGRef,
       fkChoice: ref ForkChoice,
       verifier: var BatchVerifier,
       state: var ForkedHashedBeaconState,
       stateCache: var StateCache,
       signedBlock: ForkySignedBeaconBlock,
       time: BeaconTime): Result[BlockRef, BlockError] =
  # 1. Move state to proper slot.
  doAssert dag.updateState(
    state,
    dag.getBlockIdAtSlot(time.slotOrZero).expect("block exists"),
    save = false,
    stateCache
  )

  # 2. Add block to DAG
  when signedBlock is phase0.SignedBeaconBlock:
    type TrustedBlock = phase0.TrustedSignedBeaconBlock
  elif signedBlock is altair.SignedBeaconBlock:
    type TrustedBlock = altair.TrustedSignedBeaconBlock
  else:
    type TrustedBlock = bellatrix.TrustedSignedBeaconBlock

  let blockAdded = dag.addHeadBlock(verifier, signedBlock) do (
      blckRef: BlockRef, signedBlock: TrustedBlock,
      epochRef: EpochRef, unrealized: FinalityCheckpoints):

    # 3. Update fork choice if valid
    let status = fkChoice[].process_block(
      dag, epochRef, blckRef, unrealized, signedBlock.message, time)
    doAssert status.isOk()

    # 4. Update DAG with new head
    var quarantine = Quarantine.init()
    let newHead = fkChoice[].get_head(dag, time).get()
    dag.updateHead(dag.getBlockRef(newHead).get(), quarantine)
    if dag.needStateCachesAndForkChoicePruning():
      dag.pruneStateCachesDAG()
      let pruneRes = fkChoice[].prune()
      doAssert pruneRes.isOk()

  blockAdded

proc stepChecks(
       checks: JsonNode,
       dag: ChainDAGRef,
       fkChoice: ref ForkChoice,
       time: BeaconTime
     ) =
  doAssert checks.len >= 1, "No checks found"
  for check, val in checks:
    if check == "time":
      doAssert time.ns_since_genesis == val.getInt().seconds.nanoseconds()
      doAssert fkChoice.checkpoints.time.slotOrZero == time.slotOrZero
    elif check == "head":
      let headRoot = fkChoice[].get_head(dag, time).get()
      let headRef = dag.getBlockRef(headRoot).get()
      doAssert headRef.slot == Slot(val["slot"].getInt())
      doAssert headRef.root == Eth2Digest.fromHex(val["root"].getStr())
    elif check == "justified_checkpoint":
      let checkpointRoot = fkChoice.checkpoints.justified.checkpoint.root
      let checkpointEpoch = fkChoice.checkpoints.justified.checkpoint.epoch
      doAssert checkpointEpoch == Epoch(val["epoch"].getInt())
      doAssert checkpointRoot == Eth2Digest.fromHex(val["root"].getStr())
    elif check == "justified_checkpoint_root": # undocumented check
      let checkpointRoot = fkChoice.checkpoints.justified.checkpoint.root
      doAssert checkpointRoot == Eth2Digest.fromHex(val.getStr())
    elif check == "finalized_checkpoint":
      let checkpointRoot = fkChoice.checkpoints.finalized.root
      let checkpointEpoch = fkChoice.checkpoints.finalized.epoch
      doAssert checkpointEpoch == Epoch(val["epoch"].getInt())
      doAssert checkpointRoot == Eth2Digest.fromHex(val["root"].getStr())
    elif check == "best_justified_checkpoint":
      let checkpointRoot = fkChoice.checkpoints.best_justified.root
      let checkpointEpoch = fkChoice.checkpoints.best_justified.epoch
      doAssert checkpointEpoch == Epoch(val["epoch"].getInt())
      doAssert checkpointRoot == Eth2Digest.fromHex(val["root"].getStr())
    elif check == "proposer_boost_root":
      doAssert fkChoice.checkpoints.proposer_boost_root ==
        Eth2Digest.fromHex(val.getStr())
    elif check == "genesis_time":
      # The fork choice is pruned regularly
      # and does not store the genesis time,
      # hence we check the DAG
      doAssert dag.genesis.slot == Slot(val.getInt())
    else:
      doAssert false, "Unsupported check '" & $check & "'"

proc doRunTest(path: string, fork: BeaconStateFork) =
  let db = BeaconChainDB.new("", inMemory = true)
  defer:
    db.close()

  let stores =
    case fork
    of BeaconStateFork.Bellatrix:
      initialLoad(path, db, bellatrix.BeaconState, bellatrix.BeaconBlock)
    of BeaconStateFork.Altair:
      initialLoad(path, db, altair.BeaconState, altair.BeaconBlock)
    of BeaconStateFork.Phase0:
      initialLoad(path, db, phase0.BeaconState, phase0.BeaconBlock)

  var
    taskpool = Taskpool.new()
    verifier = BatchVerifier(rng: keys.newRng(), taskpool: taskpool)

  let steps = loadOps(path, fork)
  var time = stores.fkChoice.checkpoints.time

  let state = newClone(stores.dag.headState)
  var stateCache = StateCache()

  for step in steps:
    case step.kind
    of opOnTick:
      time = BeaconTime(ns_since_genesis: step.tick.seconds.nanoseconds)
      let status = stores.fkChoice[].update_time(stores.dag, time)
      doAssert status.isOk == step.valid
    of opOnAttestation:
      let status = stores.fkChoice[].on_attestation(
        stores.dag, step.att.data.slot, step.att.data.beacon_block_root,
        toSeq(stores.dag.get_attesting_indices(step.att.asTrusted)), time)
      doAssert status.isOk == step.valid
    of opOnBlock:
      withBlck(step.blck):
        let status = stepOnBlock(
          stores.dag, stores.fkChoice,
          verifier, state[], stateCache,
          blck, time)
        doAssert status.isOk == step.valid
    of opOnAttesterSlashing:
      let indices =
        check_attester_slashing(state[], step.attesterSlashing, flags = {})
      if indices.isOk:
        for idx in indices.get:
          stores.fkChoice[].process_equivocation(idx)
      doAssert indices.isOk == step.valid
    of opChecks:
      stepChecks(step.checks, stores.dag, stores.fkChoice, time)
    else:
      doAssert false, "Unsupported"

proc runTest(path: string, fork: BeaconStateFork) =
  const SKIP = [
    # protoArray can handle blocks in the future gracefully
    # spec: https://github.com/ethereum/consensus-specs/blame/v1.1.3/specs/phase0/fork-choice.md#L349
    # test: tests/fork_choice/scenarios/no_votes.nim
    #       "Ensure the head is still 4 whilst the justified epoch is 0."
    "on_block_future_block",

    # TODO on_merge_block
    "too_early_for_merge",
    "too_late_for_merge",
    "block_lookup_failed",
    "all_valid",
  ]

  test "ForkChoice - " & path.relativePath(SszTestsDir):
    when defined(windows):
      # Some test files have very long paths
      skip()
    else:
      if os.splitPath(path).tail in SKIP:
        skip()
      else:
        doRunTest(path, fork)

suite "EF - ForkChoice" & preset():
  const presetPath = SszTestsDir/const_preset
  for kind, path in walkDir(presetPath, relative = true, checkDir = true):
    let testsPath = presetPath/path/"fork_choice"
    if kind != pcDir or not dirExists(testsPath):
      continue
    let fork = forkForPathComponent(path).valueOr:
      raiseAssert "Unknown test fork: " & testsPath
    for kind, path in walkDir(testsPath, relative = true, checkDir = true):
      let basePath = testsPath/path/"pyspec_tests"
      if kind != pcDir:
        continue
      for kind, path in walkDir(basePath, relative = true, checkDir = true):
        runTest(basePath/path, fork)

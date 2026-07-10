import ../unittest3
import ../tests/chronos_only_helper

suite "Async Chronos Helper Context":
  test "callback failure after helper await fails this test":
    await callAfterNormalChronosAwait(proc() {.gcsafe, raises: [].} =
      checkpoint("helper callback after normal chronos await")
      check false
    )

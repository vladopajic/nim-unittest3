import ../unittest3

suite "Async Expected Failure":
  test "check false fails this child test":
    await sleepAsync(10.milliseconds)
    check false

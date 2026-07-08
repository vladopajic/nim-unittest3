import ../unittest3

suite "Async Expected Timeout":
  test "sleep exceeds configured timeout":
    await sleepAsync(1500.milliseconds)
    check true

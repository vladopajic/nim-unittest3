import ../unittest3


suite "Async Tests":
  test "async work slow":
    await sleepAsync(150.milliseconds)
    echo "1111111111111"
    check(1 == 3)

  test "async work fast":
    await sleepAsync(50.milliseconds)
    echo "22222222222"
    check(1 == 1)
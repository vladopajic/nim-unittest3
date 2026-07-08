import ../unittest3

var
  active = 0
  maxActive = 0

template worker(name: string) =
  test name:
    inc active
    maxActive = max(maxActive, active)
    await sleepAsync(200.milliseconds)
    dec active

suite "Async Jobs Control":
  worker "worker 1"
  worker "worker 2"
  worker "worker 3"

  test "check concurrency":
    await sleepAsync(100.milliseconds)
    when defined(expectParallel):
      check maxActive > 1
    else:
      check maxActive == 1

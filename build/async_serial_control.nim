import ../unittest3

var
  active = 0
  maxActive = 0
  violations = 0

proc enter() =
  inc active
  maxActive = max(maxActive, active)

proc leave() =
  dec active

template worker(name: string) =
  test name:
    enter()
    await sleepAsync(200.milliseconds)
    leave()

template isolatedBody() =
  if active != 0:
    inc violations
  enter()
  await sleepAsync(50.milliseconds)
  if active != 1:
    inc violations
  leave()

suite "Serial Test Control":
  worker "parallel before 1"
  worker "parallel before 2"

  serialTest "isolated serial test":
    isolatedBody()

  worker "parallel after"

serialSuite "Serial Suite Control":
  test "serial suite test 1":
    isolatedBody()

  test "serial suite test 2":
    isolatedBody()

suite "Serial Control Assertions":
  serialTest "serial controls worked":
    check maxActive > 1
    check violations == 0

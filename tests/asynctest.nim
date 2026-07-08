import ../unittest3
import chronicles
import std/[os, osproc, strutils]


suite "Async Tests":
  test "async work slow":
    await sleepAsync(150.milliseconds)
    echo "111 echo"
    stdout.write("111 slow stdout.write\n")
    info "111 slow chronicles log"
    check 1 == 1

  test "async work fast":
    await sleepAsync(50.milliseconds)
    echo "222"
    stdout.write("222 fast stdout.write\n")
    info "222 fast chronicles log"
    check 2 == 2

  test "interleaved async steps keep local state":
    var value = 10
    await sleepAsync(25.milliseconds)
    inc value
    await sleepAsync(25.milliseconds)
    check value == 11

  test "async output after multiple awaits":
    await sleepAsync(10.milliseconds)
    echo "multi await echo one"
    await sleepAsync(10.milliseconds)
    stdout.write("multi await stdout two\n")
    info "multi await chronicles three"
    check true

  test "failing async child test is reported as failure":
    let childPath = "build" / "async_expected_failure.nim"
    createDir childPath.splitFile.dir
    writeFile(childPath, """
import ../unittest3

suite "Async Expected Failure":
  test "check false fails this child test":
    await sleepAsync(10.milliseconds)
    check false
""")

    let (output, exitCode) = execCmdEx(
      "nim c --threads:on -r " & quoteShell(childPath) &
      " --output-level=COMPACT"
    )

    check exitCode == 0
    check output.contains("[FAILED ]")
    check output.contains("check false")

  test "slow async child test fails on timeout":
    let childPath = "build" / "async_expected_timeout.nim"
    createDir childPath.splitFile.dir
    writeFile(childPath, """
import ../unittest3

suite "Async Expected Timeout":
  test "sleep exceeds configured timeout":
    await sleepAsync(1500.milliseconds)
    check true
""")

    let (output, exitCode) = execCmdEx(
      "nim c --threads:on -d:unittest3TestTimeoutSeconds=1 -r " &
      quoteShell(childPath) & " --output-level=COMPACT"
    )

    check exitCode == 0
    check output.contains("[FAILED ]")
    check output.contains("[TIMEOUT]")

  test "runtime jobs option controls concurrency":
    let childPath = "build" / "async_jobs_control.nim"
    createDir childPath.splitFile.dir
    writeFile(childPath, """
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
""")

    let (_, sequentialExitCode) = execCmdEx(
      "nim c --threads:on -r " & quoteShell(childPath) &
      " --output-level=NONE --jobs=1"
    )
    putEnv("UNITTEST3_JOBS", "1")
    let (_, envSequentialExitCode) = execCmdEx(
      "nim c --threads:on -r " & quoteShell(childPath) &
      " --output-level=NONE"
    )
    delEnv("UNITTEST3_JOBS")
    let (_, parallelExitCode) = execCmdEx(
      "nim c --threads:on -d:expectParallel -r " & quoteShell(childPath) &
      " --output-level=NONE --jobs=4"
    )

    check sequentialExitCode == 0
    check envSequentialExitCode == 0
    check parallelExitCode == 0

  test "serial controls prevent overlap":
    let childPath = "build" / "async_serial_control.nim"
    createDir childPath.splitFile.dir
    writeFile(childPath, """
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
""")

    let (_, exitCode) = execCmdEx(
      "nim c --threads:on -r " & quoteShell(childPath) &
      " --output-level=NONE --jobs=4"
    )

    check exitCode == 0

suite "Async Compatibility Helpers":
  asyncSetup:
    await sleepAsync(1.milliseconds)
    var prepared {.used.} = 41

  asyncTeardown:
    await sleepAsync(1.milliseconds)
    check prepared == 42

  asyncTest "async aliases work":
    await sleepAsync(1.milliseconds)
    inc prepared
    check prepared == 42

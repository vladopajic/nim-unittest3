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

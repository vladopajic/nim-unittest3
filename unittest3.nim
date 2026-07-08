# unittest3
#
#        (c) Copyright 2026 @vladopajic
#
# and authors of unittest2
#        (c) Copyright 2015 Nim Contributors
#        (c) Copyright 2019-2021 Ștefan Talpalaru
#        (c) Copyright 2021-Onwards Status Research and Development
#

{.push raises: [].}

import std/[macros, sequtils, sets, strutils, streams, tables]
import chronos except await
export chronos except await
import chronicles
export chronicles

when defined(nimHasWarnBareExcept):
  # In unit tests, we want to at least attempt to catch Exception no matter its
  # UB
  {.warning[BareExcept]: off.}

{.warning[LockLevel]: off.}

when declared(stdout):
  import std/os

when declared(stdout) and defined(posix):
  import std/posix

const useTerminal = declared(stdout) and not defined(js)

type
  OutputLevel* = enum ## The output verbosity of the tests.
    VERBOSE,          ## Print as much as possible.
    COMPACT           ## Print failures and compact success information
    FAILURES,         ## Print only failures
    NONE              ## Print nothing.

const
  outputLevelDefault = COMPACT
  slowThreshold = 5.seconds
  defaultJobs = 8

  # `unittest` compatibility
  nimUnittestOutputLevel {.strdefine.} = $outputLevelDefault
  nimUnittestColor {.strdefine.} = "auto" ## auto|on|off
  nimUnittestAbortOnError {.booldefine.} = false

  # `unittest3` compile-time configuration options
  unittest3DisableParamFiltering {.booldefine.} = false
    ## Disables automatic command line argument parsing - parsing is available
    ## via the `parseParameters` function instead
  unittest3Compat {.booldefine.} = false
    ## Compatibility mode for `unittest` for easier porting and improved
    ## backwards compatibility - no stability guarantees
  unittest3NoCollect {.booldefine.} = false
    ## Disable test collection mode where tests are enumerated before they are
    ## run - in particular, this affects the order in which tests and suites
    ## have their bodies evaluated and disables several features that require
    ## knowing how many tests will be executed - experimental feature
  unittest3PreviewIsolate {.booldefine.} = false
    ## Preview isolation mode where each test is run in a separate process - may
    ## be removed in the future
  unittest3ListTests* {.booldefine.} = false
    ## List tests at runtime without actually running them (useful for test runners)

  unittest3TestTimeoutSeconds* {.intdefine.} = 60
    ## Maximum duration for a single test.
    ## Set to 0 to disable per-test timeout enforcement.

static:
  doAssert unittest3TestTimeoutSeconds >= 0,
    "unittest3TestTimeoutSeconds must be >= 0"

when useTerminal:
  import std/terminal


const
  collect = (not unittest3NoCollect and not unittest3Compat) or
      unittest3PreviewIsolate or unittest3ListTests
  autoParseArgs = not unittest3DisableParamFiltering
  isolate = unittest3PreviewIsolate

when isolate:
  let
    isolated = getEnv("unittest3_ISOLATED") == "1"
      ## Test is running in the isolated environment

from std/exitprocs import nil
template addExitProc(p: proc) =
  try:
    exitprocs.addExitProc(p)
  except Exception as e:
    echo "Can't add exit proc", e.msg
    quit(1)

type
  Test = object
    suiteName: string
    testName: string
    asyncImpl: proc(suite, name: string): Future[TestRunResult]
    lineInfo: int
    filename: string
    serial: bool

  TestStatus* = enum ## The status of a test when it is done.
    OK,
    FAILED,
    SKIPPED

  TestRunResult = object
    status: TestStatus
    output: string

  TestResult* = object
    suiteName*: string
      ## Name of the test suite that contains this test case.
    testName*: string
      ## Name of the test case
    status*: TestStatus
    duration*: Duration # How long the test took, in seconds
    output*: string
    errors*: string

  OutputFormatter* = ref object of RootObj

  ConsoleOutputFormatter* = ref object of OutputFormatter
    colorOutput: bool
      ## Have test results printed in color.
      ## Default is `auto` depending on `isatty(stdout)`, or override it with
      ## `-d:nimUnittestColor:auto|on|off`.
      ##
      ## Deprecated: Setting the environment variable `NIMTEST_COLOR` to `always`
      ## or `never` changes the default for the non-js target to true or false respectively.
      ## Deprecated: the environment variable `NIMTEST_NO_COLOR`, when set, changes the
      ## default to true, if `NIMTEST_COLOR` is undefined.
    outputLevel: OutputLevel
      ## Set the verbosity of test results.
      ## Default is `VERBOSE`, or override with:
      ## `-d:nimUnittestOutputLevel:VERBOSE|FAILURES|NONE`.
      ##
      ## Deprecated: the `NIMTEST_OUTPUT_LVL` environment variable is set for the non-js target.

    when collect:
      tests: Table[string, int]

    curSuiteName: string
    curSuite: int
    curTestName: string
    curTest: int
    compactLineOpen: bool

    statuses: array[TestStatus, int]

    totalDuration: Duration

    results: seq[TestResult]

    failures: seq[TestResult]

    errors: string

  JUnitTest = object
    name: string
    result: TestResult
    error: (seq[string], string)
    failures: seq[seq[string]]

  JUnitSuite = object
    name: string
    tests: seq[JUnitTest]

  JUnitOutputFormatter* = ref object of OutputFormatter
    stream: Stream
    defaultSuite: JUnitSuite
    suites: seq[JUnitSuite]
    currentSuite: int

  AsyncTestContext = ref object
    ## Per-test state for async execution. Avoids shared global `testStatus` /
    ## `checkpoints` being corrupted when tests interleave at `await` points.
    suiteName: string
    testName: string
    status: TestStatus
    checkpoints: seq[string]
    outputPath: string
    outputFile: File
    outputCaptureEnabled: bool

# TODO these globals are threadvar so as to avoid gc-safety-issues - this should
#      probably be resolved in a better way down the line specially since we
#      don't support threads _really_

var
  abortOnError* {.threadvar.}: bool
    ## Set to true in order to quit
    ## immediately on fail. Default is false,
    ## or override with `-d:nimUnittestAbortOnError:on|off`.

  checkpoints {.threadvar.}: seq[string]
  formatters {.threadvar.}: seq[OutputFormatter]
  testsFilters {.threadvar.}: HashSet[string]
  runtimeJobs {.threadvar.}: int

  currentSuite {.threadvar.}: string
  currentSuiteSerial {.threadvar.}: bool
  currentTestSerial {.threadvar.}: bool
  testStatus {.threadvar.}: TestStatus
  currentAsyncCtx {.threadvar.}: AsyncTestContext
    ## Points to the currently-executing async test's context. Nil outside async tests.
    ## Because chronos is single-threaded cooperative, only one test runs between
    ## await points, so this pointer is always valid for the active test.
  stdoutCaptureCounter {.threadvar.}: int
  lastExecutedSuite {.threadvar.}: string
  lastExecutedTest {.threadvar.}: string

when declared(stdout) and defined(posix):
  var
    savedStdoutFd {.threadvar.}: cint
    savedStderrFd {.threadvar.}: cint

  proc ensureSavedOutputFds() =
    if savedStdoutFd <= 0:
      try:
        savedStdoutFd = dup(cint(stdout.getFileHandle()))
      except CatchableError:
        savedStdoutFd = 0
    if savedStderrFd <= 0:
      try:
        savedStderrFd = dup(cint(stderr.getFileHandle()))
      except CatchableError:
        savedStderrFd = 0

  proc redirectFileTo(f: File, fd: cint) =
    try:
      f.flushFile()
    except CatchableError:
      discard
    if fd >= 0:
      discard dup2(fd, cint(f.getFileHandle()))

  proc restoreStdoutCapture() =
    ensureSavedOutputFds()
    redirectFileTo(stdout, savedStdoutFd)
    redirectFileTo(stderr, savedStderrFd)

  proc activateStdoutCapture(ctx: AsyncTestContext) =
    if ctx != nil and ctx.outputCaptureEnabled:
      let fd = cint(ctx.outputFile.getFileHandle())
      redirectFileTo(stdout, fd)
      redirectFileTo(stderr, fd)

  proc appendTestOutput(ctx: AsyncTestContext, output: string) =
    if ctx != nil and ctx.outputCaptureEnabled:
      try:
        ctx.outputFile.write(output)
        if output.len == 0 or output[^1] != '\n':
          ctx.outputFile.write("\n")
        ctx.outputFile.flushFile()
      except CatchableError:
        discard
    else:
      try:
        stdout.write(output)
        if output.len == 0 or output[^1] != '\n':
          stdout.write("\n")
        stdout.flushFile()
      except CatchableError:
        discard

  proc suspendTestOutputCapture() =
    restoreStdoutCapture()

  proc resumeTestOutputCapture() =
    activateStdoutCapture(currentAsyncCtx)

  proc startTestOutputCapture(ctx: AsyncTestContext) =
    ensureSavedOutputFds()
    if savedStdoutFd <= 0 or savedStderrFd <= 0:
      return

    try:
      inc stdoutCaptureCounter
      ctx.outputPath = getTempDir() / (
        "unittest3-stdout-" & $getCurrentProcessId() & "-" &
        $stdoutCaptureCounter & ".out")
      if open(ctx.outputFile, ctx.outputPath, fmWrite):
        ctx.outputCaptureEnabled = true
        activateStdoutCapture(ctx)
    except CatchableError:
      ctx.outputCaptureEnabled = false

  proc finishTestOutputCapture(ctx: AsyncTestContext): string =
    if ctx == nil or not ctx.outputCaptureEnabled:
      return ""

    try:
      ctx.outputFile.flushFile()
    except CatchableError:
      discard

    restoreStdoutCapture()

    try:
      ctx.outputFile.close()
    except CatchableError:
      discard

    try:
      result = readFile(ctx.outputPath)
    except CatchableError:
      result = ""

    try:
      removeFile(ctx.outputPath)
    except CatchableError:
      discard

    ctx.outputCaptureEnabled = false
else:
  proc appendTestOutput(ctx: AsyncTestContext, output: string) =
    discard
  proc suspendTestOutputCapture() = discard
  proc resumeTestOutputCapture() = discard
  proc startTestOutputCapture(ctx: AsyncTestContext) = discard
  proc finishTestOutputCapture(ctx: AsyncTestContext): string = ""

proc chroniclesTestOutputWriter(logLevel: LogLevel, logRecord: LogOutputStr) {.
    gcsafe, used.} =
  discard logLevel
  {.cast(gcsafe).}:
    appendTestOutput(currentAsyncCtx, string(logRecord))

template installChroniclesTestOutput() {.dirty.} =
  bind chroniclesTestOutputWriter
  mixin defaultChroniclesStream
  when declared(defaultChroniclesStream):
    when compiles(defaultChroniclesStream.outputs[
        0].writer = chroniclesTestOutputWriter):
      defaultChroniclesStream.outputs[0].writer = chroniclesTestOutputWriter
    when compiles(defaultChroniclesStream.outputs[
        1].writer = chroniclesTestOutputWriter):
      defaultChroniclesStream.outputs[1].writer = chroniclesTestOutputWriter
    when compiles(defaultChroniclesStream.outputs[
        2].writer = chroniclesTestOutputWriter):
      defaultChroniclesStream.outputs[2].writer = chroniclesTestOutputWriter
    when compiles(defaultChroniclesStream.outputs[
        3].writer = chroniclesTestOutputWriter):
      defaultChroniclesStream.outputs[3].writer = chroniclesTestOutputWriter

proc noteTestExecution(suiteName, testName: string) {.gcsafe.}

template await*[T](f: Future[T]): T =
  let unittest3AwaitCtx = currentAsyncCtx
  suspendTestOutputCapture()
  when T is void:
    chronos.await(f)
    {.cast(gcsafe).}:
      currentAsyncCtx = unittest3AwaitCtx
    if unittest3AwaitCtx != nil:
      noteTestExecution(unittest3AwaitCtx.suiteName, unittest3AwaitCtx.testName)
    resumeTestOutputCapture()
  else:
    let unittest3AwaitResult = chronos.await(f)
    {.cast(gcsafe).}:
      currentAsyncCtx = unittest3AwaitCtx
    if unittest3AwaitCtx != nil:
      noteTestExecution(unittest3AwaitCtx.suiteName, unittest3AwaitCtx.testName)
    resumeTestOutputCapture()
    unittest3AwaitResult

template await*[T, E](f: InternalRaisesFuture[T, E]): T =
  let unittest3AwaitCtx = currentAsyncCtx
  suspendTestOutputCapture()
  when T is void:
    chronos.await(f)
    {.cast(gcsafe).}:
      currentAsyncCtx = unittest3AwaitCtx
    if unittest3AwaitCtx != nil:
      noteTestExecution(unittest3AwaitCtx.suiteName, unittest3AwaitCtx.testName)
    resumeTestOutputCapture()
  else:
    let unittest3AwaitResult = chronos.await(f)
    {.cast(gcsafe).}:
      currentAsyncCtx = unittest3AwaitCtx
    if unittest3AwaitCtx != nil:
      noteTestExecution(unittest3AwaitCtx.suiteName, unittest3AwaitCtx.testName)
    resumeTestOutputCapture()
    unittest3AwaitResult

when collect:
  var
    tests {.threadvar.}: OrderedTable[string, seq[Test]]

abortOnError = nimUnittestAbortOnError

when declared(stdout):
  if existsEnv("unittest3_ABORT_ON_ERROR") or existsEnv("NIMTEST_ABORT_ON_ERROR"):
    abortOnError = true

when collect:
  method suiteRunStarted*(
      formatter: OutputFormatter, tests: OrderedTable[string, seq[
          Test]]) {.base, gcsafe.} =
    # Run when a round of running discovered suites starts - these may result
    # in subsequent tests being added meaning subsequent suite runs
    discard
method suiteStarted*(formatter: OutputFormatter, suiteName: string) {.base, gcsafe.} =
  discard
method testStarted*(formatter: OutputFormatter, testName: string) {.base, gcsafe.} =
  discard
method testExecutionSwitched*(
    formatter: OutputFormatter, suiteName, testName: string) {.base, gcsafe.} =
  discard
method failureOccurred*(formatter: OutputFormatter, checkpoints: seq[string],
    stackTrace: string) {.base, gcsafe.} =
  ## ``stackTrace`` is provided only if the failure occurred due to an exception.
  ## ``checkpoints`` is never ``nil``.
  discard
method testEnded*(formatter: OutputFormatter, testResult: TestResult) {.base, gcsafe.} =
  discard
method suiteEnded*(formatter: OutputFormatter) {.base, gcsafe.} =
  discard
when collect:
  method suiteRunEnded*(
      formatter: OutputFormatter) {.base, gcsafe.} =
    discard

method testRunEnded*(formatter: OutputFormatter) {.base, gcsafe.} =
  # Runs when the test executable is about to end, which is implemented using
  # addExitProc, a best-effort kind of place to do cleanups
  discard

when collect:
  proc suiteRunStarted(tests: OrderedTable[string, seq[Test]]) =
    for formatter in formatters:
      formatter.suiteRunStarted(tests)

proc suiteStarted(name: string) =
  for formatter in formatters:
    formatter.suiteStarted(name)

proc testStarted(name: string) =
  for formatter in formatters:
    formatter.testStarted(name)

proc testExecutionSwitched(suiteName, testName: string) {.gcsafe.} =
  for formatter in formatters:
    formatter.testExecutionSwitched(suiteName, testName)

proc noteTestExecution(suiteName, testName: string) {.gcsafe.} =
  if lastExecutedSuite.len > 0 and
      (lastExecutedSuite != suiteName or lastExecutedTest != testName):
    testExecutionSwitched(suiteName, testName)

  lastExecutedSuite = suiteName
  lastExecutedTest = testName

proc testEnded(testResult: TestResult) =
  for formatter in formatters:
    formatter.testEnded(testResult)

proc suiteEnded() =
  for formatter in formatters:
    formatter.suiteEnded()

when collect:
  proc suiteRunEnded() =
    for formatter in formatters:
      formatter.suiteRunEnded()

proc testRunEnded() =
  when not collect:
    if currentSuite.len > 0:
      suiteEnded()
      currentSuite.reset()

  for formatter in formatters:
    testRunEnded(formatter)

proc addOutputFormatter*(formatter: OutputFormatter) =
  formatters.add(formatter)

proc resetOutputFormatters*() =
  formatters.reset()

proc newConsoleOutputFormatter*(outputLevel: OutputLevel = outputLevelDefault,
                                colorOutput = true): ConsoleOutputFormatter =
  ConsoleOutputFormatter(
    outputLevel: outputLevel,
    colorOutput: colorOutput,
  )

proc defaultColorOutput(): bool =
  let color = nimUnittestColor
  case color
  of "auto":
    when declared(stdout): result = isatty(stdout)
    else: result = false
  of "on": result = true
  of "off": result = false
  else: raiseAssert "Unrecognised nimUnittestColor setting: " & color

  when declared(stdout):
    # TODO unittest3-equivalent color parsing
    if existsEnv("NIMTEST_COLOR"):
      let colorEnv = getEnv("NIMTEST_COLOR")
      if colorEnv == "never":
        result = false
      elif colorEnv == "always":
        result = true
    elif existsEnv("NIMTEST_NO_COLOR"):
      result = false

proc defaultOutputLevel(): OutputLevel =
  when declared(stdout):
    const levelEnv = "unittest3_OUTPUT_LVL"
    const nimtestEnv = "NIMTEST_OUTPUT_LVL"
    if existsEnv(levelEnv):
      try:
        parseEnum[OutputLevel](getEnv(levelEnv))
      except ValueError:
        echo "Cannot parse unittest3_OUTPUT_LVL: ", getEnv(levelEnv)
        quit 1
    elif existsEnv(nimtestEnv):
      # std-compatible parsing and translation
      case toUpper(getEnv(nimtestEnv))
      of "PRINT_ALL": OutputLevel.VERBOSE
      of "PRINT_FAILURES": OutputLevel.FAILURES
      of "PRINT_NONE": OutputLevel.NONE
      else:
        echo "Cannot parse NIMTEST_OUTPUT_LVL: ", getEnv(nimtestEnv)
        quit 1
    else:
      const defaultLevel = static: nimUnittestOutputLevel.parseEnum[:OutputLevel]
      defaultLevel

proc defaultConsoleFormatter*(): ConsoleOutputFormatter =
  newConsoleOutputFormatter(defaultOutputLevel(), defaultColorOutput())

const
  maxStatusLen = 7
  maxDurationLen = 6

func formatStatus(status: string): string =
  "[" & alignLeft(status, maxStatusLen) & "]"

func formatStatus(status: TestStatus): string =
  formatStatus($status)

proc formatDuration(dur: Duration, aligned = true): string =
  let
    seconds = dur.nanoseconds.float / 1_000_000_000.0
    precision = max(3 - ($seconds.int).len, 1)
    str = formatFloat(seconds, ffDecimal, precision)

  if aligned:
    "(" & align(str, maxDurationLen) & "s)"
  else:
    "(" & str & "s)"

when collect:
  proc formatFraction(cur, total: int): string =
    let
      cur = $cur
      total = $total
    "[" & align(cur, max(0, maxStatusLen - total.len - 1)) & "/" & total & "]"

template write(
    formatter: ConsoleOutputFormatter, styled: untyped, unstyled: untyped) =
  template ignoreExceptions(body: untyped) =
    # We ignore exceptions throughout assuming there's no way to
    try: body except CatchableError: discard

  when useTerminal:
    if formatter.colorOutput:
      ignoreExceptions: styled
    else: ignoreExceptions: unstyled
  else: ignoreExceptions: unstyled

when collect:
  method suiteRunStarted*(
      formatter: ConsoleOutputFormatter, tests: OrderedTable[string, seq[Test]]) =
    for k, v in tests:
      formatter.tests[k] = v.len

when collect:
  method suiteRunEnded*(formatter: ConsoleOutputFormatter) =
    formatter.tests.reset()

method suiteStarted*(formatter: ConsoleOutputFormatter, suiteName: string) =
  formatter.curSuiteName = suiteName
  formatter.curSuite += 1

  formatter.curTest.reset()

  if formatter.outputLevel in {OutputLevel.FAILURES, OutputLevel.NONE}:
    return

  let
    counter =
      when collect: formatFraction(formatter.curSuite, formatter.tests.len) & " "
      else:
        if formatter.outputLevel == VERBOSE: formatStatus("Suite") & " " else: ""
    maxNameLen = when collect: max(toSeq(formatter.tests.keys()).mapIt(
        it.len)) else: 0
    eol = if formatter.outputLevel == VERBOSE: "\n" else: " "
  if formatter.outputLevel == COMPACT and formatter.compactLineOpen:
    echo ""
    formatter.compactLineOpen = false

  formatter.write do:
    stdout.styledWrite(styleBright, fgBlue, counter, alignLeft(suiteName,
        maxNameLen), eol)
  do:
    stdout.write(counter, alignLeft(suiteName, maxNameLen), eol)
  stdout.flushFile()
  if formatter.outputLevel == COMPACT:
    formatter.compactLineOpen = true

proc writeTestName(formatter: ConsoleOutputFormatter, testName: string) =
  formatter.write do:
    stdout.styledWrite fgBlue, testName
  do:
    stdout.write(testName)

method testStarted*(formatter: ConsoleOutputFormatter, testName: string) =
  formatter.curTestName = testName
  formatter.curTest += 1

  if formatter.outputLevel != VERBOSE:
    return

  # In verbose mode, print a line when the test starts so that output can be
  # correlated with the test that's currently running rather than misleadingly
  # being printed just below the test that just finished running.
  let
    counter =
      when collect:
        try: formatFraction(formatter.curTest, formatter.tests[
            formatter.curSuiteName]) & " "
        except CatchableError: ""
      else:
        formatStatus("Test")

  formatter.write do:
    stdout.styledWrite "  ", fgBlue, alignLeft(counter, maxStatusLen +
        maxDurationLen + 7)
  do:
    stdout.write "  ", alignLeft(counter, maxStatusLen + maxDurationLen + 7)

  writeTestName(formatter, testName)
  echo ""

method testExecutionSwitched*(
    formatter: ConsoleOutputFormatter, suiteName, testName: string) =
  discard suiteName
  discard testName

  if formatter.outputLevel != COMPACT:
    return

  formatter.write do:
    stdout.styledWrite styleBright, fgGreen, "."
  do:
    stdout.write "."
  stdout.flushFile()
  formatter.compactLineOpen = true

method failureOccurred*(formatter: ConsoleOutputFormatter,
                        checkpoints: seq[string], stackTrace: string) =
  if stackTrace.len > 0:
    formatter.errors.add(stackTrace)
    formatter.errors.add("\n")
  for msg in items(checkpoints):
    formatter.errors.add("    ")
    formatter.errors.add(msg)
    formatter.errors.add("\n")

proc color(status: TestStatus): ForegroundColor =
  case status
  of TestStatus.OK: fgGreen
  of TestStatus.FAILED: fgRed
  of TestStatus.SKIPPED: fgYellow
proc marker(status: TestStatus): string =
  case status
  of TestStatus.OK: "."
  of TestStatus.FAILED: "F"
  of TestStatus.SKIPPED: "s"

proc getAppFilename2(): string =
  # TODO https://github.com/nim-lang/Nim/pull/22544
  try:
    getAppFilename()
  except OSError:
    ""

proc printFailureInfo(formatter: ConsoleOutputFormatter,
    testResult: TestResult) =
  # Show how to re-run this test case
  echo repeat('=', testResult.testName.len)
  echo "  ", getAppFilename2(), " ", quoteShell(testResult.suiteName & "::" &
      testResult.testName)
  echo repeat('-', testResult.testName.len)

  # Show the output
  if testResult.output.len > 0:
    echo testResult.output
  if testResult.errors.len > 0:
    echo testResult.errors

proc printCapturedOutput(formatter: ConsoleOutputFormatter, output: string) =
  if output.len == 0:
    return

  if formatter.outputLevel == COMPACT:
    echo ""
    formatter.compactLineOpen = false

  try:
    stdout.write(output)
    if output[^1] != '\n':
      echo ""
    formatter.compactLineOpen = false
  except CatchableError:
    discard

proc printTestResultStatus(formatter: ConsoleOutputFormatter,
    testResult: TestResult) =
  let
    status = formatStatus(testResult.status)
    duration = formatDuration(testResult.duration)

  formatter.write do:
    stdout.styledWrite(
      "  ", styleBright, testResult.status.color, status, " ")
    if testResult.duration > slowThreshold:
      stdout.styledWrite styleBright, duration
    else:
      stdout.write(duration)
    stdout.write " ", testResult.testName
  do:
    stdout.styledWrite "  ", status, " ", duration, " ", testResult.testName
  echo ""

method testEnded*(formatter: ConsoleOutputFormatter, testResult: TestResult) =
  formatter.statuses[testResult.status] += 1
  formatter.totalDuration += testResult.duration

  if formatter.outputLevel == NONE:
    return

  var testResult = testResult
  testResult.errors = move(formatter.errors)

  if formatter.outputLevel == COMPACT and testResult.output.len > 0:
    formatter.printCapturedOutput(testResult.output)
    testResult.output.reset()

  formatter.results.add(testResult)

  if formatter.outputLevel == VERBOSE and testResult.status ==
      TestStatus.FAILED:
    # We'll print it again when all tests have completed
    formatter.failures.add testResult

  if formatter.outputLevel in {VERBOSE, FAILURES}:
    if testResult.status == TestStatus.FAILED:
      printFailureInfo(formatter, testResult)
    elif formatter.outputLevel == VERBOSE:
      formatter.printCapturedOutput(testResult.output)
    if formatter.outputLevel == VERBOSE or testResult.status ==
        TestStatus.FAILED:
      printTestResultStatus(formatter, testResult)
  else:
    # In compact mode, we use a small marker to mark progress within the suite -
    # we have to be careful about line breaks and flushing so that the marker
    # really ends up on the screen where it's supposed to
    # TODO if the test writes to stdout, the display with be disrupted
    #      capturing / redirecting stdout with `dup2` or process isolation could
    #      fix this

    let
      marker = testResult.status.marker()
      color = testResult.status.color()
    formatter.write do:
      stdout.styledWrite styleBright, color, marker
    do:
      stdout.write marker
    stdout.flushFile()
    formatter.compactLineOpen = true

method suiteEnded*(formatter: ConsoleOutputFormatter) =
  if formatter.outputLevel == OutputLevel.NONE:
    return

  let
    totalDur = formatter.results.foldl(a + b.duration, 0.seconds)
    totalDurStr = formatDuration(totalDur, false)

  if formatter.outputLevel == OutputLevel.COMPACT:
    if formatter.results.len > 0:
      # Complete the line with timing information
      formatter.write do:
        if totalDur > slowThreshold:
          stdout.styledWrite(" ", styleBright, totalDurStr)
        else:
          stdout.write(" ", totalDurStr)
        echo ""
      do:
        echo(" ", totalDurStr)
      formatter.compactLineOpen = false
    else:
      formatter.write do:
        # If no tests were run, remove the suite name
        stdout.eraseLine()
      do:
        stdout.writeLine("")
      formatter.compactLineOpen = false

  var failed = false
  if formatter.outputLevel notin {VERBOSE, FAILURES}:
    for testResult in formatter.results:
      if testResult.status == TestStatus.FAILED:
        failed = true
        formatter.printFailureInfo(testResult)
        formatter.printTestResultStatus(testResult)
        echo ""

  formatter.results.reset()

  if failed or formatter.outputLevel == VERBOSE:
    formatter.write do:
      if totalDur > slowThreshold:
        stdout.styledWrite styleBright, align(totalDurStr, maxStatusLen)
      else:
        stdout.write(align(totalDurStr, maxStatusLen))
    do:
      stdout.write(align(totalDurStr, maxStatusLen))

    echo("   ", formatter.curSuiteName)
    echo("")

method testRunEnded*(formatter: ConsoleOutputFormatter) =
  if formatter.outputLevel notin {VERBOSE, COMPACT} or
      (formatter.outputLevel == FAILURES and
        formatter.statuses[TestStatus.FAILED] > 0):
    return

  let totalDurStr = formatDuration(formatter.totalDuration, false)

  try:
    let total = foldl(formatter.statuses, a + b, 0)
    stdout.write("[Summary] ", $total, " tests run ", totalDurStr, ": ")

    var first = true
    for s, c in formatter.statuses:
      if first:
        first = false
      else:
        stdout.write(", ")
      if c > 0:
        formatter.write do: stdout.styledWrite(s.color, $c, " ", $s)
        do: stdout.write($c, " ", $s)
      else:
        stdout.write($c, " ", $s)
    echo ""
  except CatchableError: discard

  # In verbose mode, it's likely failures got spammed away - print the specifics
  # so that they can more easily be looked up:
  for testResult in formatter.failures:
    formatter.printTestResultStatus(testResult)

proc xmlEscape(s: string): string =
  result = newStringOfCap(s.len)
  for c in items(s):
    case c:
    of '<': result.add("&lt;")
    of '>': result.add("&gt;")
    of '&': result.add("&amp;")
    of '"': result.add("&quot;")
    of '\'': result.add("&apos;")
    else:
      if ord(c) < 32:
        result.add("&#" & $ord(c) & ';')
      else:
        result.add(c)

proc newJUnitOutputFormatter*(stream: Stream): JUnitOutputFormatter =
  ## Creates a formatter that writes report to the specified stream in
  ## JUnit format.
  ## The ``stream`` is NOT closed automatically when the test are finished,
  ## because the formatter has no way to know when all tests are finished.
  ## You should invoke formatter.close() to finalize the report.
  result = JUnitOutputFormatter(
    stream: stream,
    defaultSuite: JUnitSuite(name: "default"),
    currentSuite: -1,
  )
  try:
    stream.writeLine("<?xml version=\"1.0\" encoding=\"UTF-8\"?>")
  except CatchableError as exc:
    echo "Cannot write JUnit: ", exc.msg
    quit 1

template suite(formatter: JUnitOutputFormatter): untyped =
  if formatter.currentSuite == -1:
    addr formatter.defaultSuite
  else:
    addr formatter.suites[formatter.currentSuite]

method suiteStarted*(formatter: JUnitOutputFormatter, suiteName: string) =
  formatter.currentSuite = formatter.suites.len()
  formatter.suites.add(JUnitSuite(name: suiteName))

method testStarted*(formatter: JUnitOutputFormatter, testName: string) =
  formatter.suite().tests.add(JUnitTest(name: testName))

method failureOccurred*(formatter: JUnitOutputFormatter,
                        checkpoints: seq[string], stackTrace: string) =
  ## ``stackTrace`` is provided only if the failure occurred due to an exception.
  ## ``checkpoints`` is never ``nil``.
  if stackTrace.len > 0:
    formatter.suite().tests[^1].error = (checkpoints, stackTrace)
  else:
    formatter.suite().tests[^1].failures.add(checkpoints)

method testEnded*(formatter: JUnitOutputFormatter, testResult: TestResult) =
  formatter.suite().tests[^1].result = testResult

method suiteEnded*(formatter: JUnitOutputFormatter) =
  formatter.currentSuite = -1

func toFloatSeconds(d: Duration): float64 =
  d.nanoseconds.float / 1_000_000_000.0

proc writeTest(s: Stream, test: JUnitTest) {.raises: [CatchableError].} =
  let
    time = test.result.duration.toFloatSeconds()
    timeStr = time.formatFloat(ffDecimal, precision = 6)

  s.writeLine("\t\t<testcase name=\"$#\" time=\"$#\">" % [
      xmlEscape(test.name), timeStr])
  case test.result.status
  of TestStatus.OK:
    discard
  of TestStatus.SKIPPED:
    s.writeLine("\t\t\t<skipped />")
  of TestStatus.FAILED:
    if test.error[0].len > 0:
      s.writeLine("\t\t\t<error message=\"$#\">$#</error>" % [
          xmlEscape(join(test.error[0], "\n")), xmlEscape(test.error[1])])

    for failure in test.failures:
      s.writeLine("\t\t\t<failure message=\"$#\">$#</failure>" %
          [xmlEscape(failure[^1]), xmlEscape(join(failure[0..^2], "\n"))])

  s.writeLine("\t\t</testcase>")

proc countTests(counts: var (int, int, int, int, float), suite: JUnitSuite) =
  counts[0] += suite.tests.len()
  for test in suite.tests:
    counts[4] += test.result.duration.toFloatSeconds()
    case test.result.status
    of TestStatus.OK:
      discard
    of TestStatus.SKIPPED:
      counts[3] += 1
    of TestStatus.FAILED:
      if test.error[0].len > 0:
        counts[2] += 1
      else:
        counts[1] += 1

proc writeSuite(s: Stream, suite: JUnitSuite) {.raises: [CatchableError].} =
  var counts: (int, int, int, int, float)
  countTests(counts, suite)

  let timeStr = counts[4].formatFloat(ffDecimal, precision = 6)

  s.writeLine("\t" & """<testsuite name="$1" tests="$2" failures="$3" errors="$4" skipped="$5" time="$6">""" % [
    xmlEscape(suite.name), $counts[0], $counts[1], $counts[2], $counts[3], timeStr])

  for test in suite.tests.items():
    s.writeTest(test)

  s.writeLine("\t</testsuite>")

method testRunEnded*(formatter: JUnitOutputFormatter) =
  ## Completes the report and closes the underlying stream.
  let s = formatter.stream

  when defined(nimHasWarnBareExcept):
    {.warning[BareExcept]: off.}
  try:
    s.writeLine("<testsuites>")

    for suite in formatter.suites.mitems():
      s.writeSuite(suite)

    if formatter.defaultSuite.tests.len() > 0:
      s.writeSuite(formatter.defaultSuite)

    s.writeLine("</testsuites>")
    s.close()
  except Exception as exc: # Work around Exception raised in stream
    echo "Cannot write JUnit: ", exc.msg
    quit 1

  when defined(nimHasWarnBareExcept):
    {.warning[BareExcept]: on.}

proc glob(matcher, filter: string): bool =
  ## Globbing using a single `*`. Empty `filter` matches everything.
  if filter.len == 0:
    return true

  if not filter.contains('*'):
    return matcher == filter

  let beforeAndAfter = filter.split('*', maxsplit = 1)
  if beforeAndAfter.len == 1:
    # "foo*"
    return matcher.startsWith(beforeAndAfter[0])

  if matcher.len < filter.len - 1:
    return false # "12345" should not match "123*345"

  return matcher.startsWith(beforeAndAfter[0]) and matcher.endsWith(
      beforeAndAfter[1])

proc matchFilter(suiteName, testName, filter: string): bool =
  if filter == "":
    return true
  if testName == filter:
    # corner case for tests containing "::" in their name
    return true
  let suiteAndTestFilters = filter.split("::", maxsplit = 1)

  if suiteAndTestFilters.len == 1:
    # no suite specified
    let testFilter = suiteAndTestFilters[0]
    return glob(testName, testFilter)

  return glob(suiteName, suiteAndTestFilters[0]) and
         glob(testName, suiteAndTestFilters[1])

when defined(testing): export matchFilter

proc shouldRun(currentSuiteName, testName: string): bool =
  ## Check if a test should be run by matching suiteName and testName against
  ## test filters.
  if testsFilters.len == 0:
    return true

  for f in testsFilters:
    if matchFilter(currentSuiteName, testName, f):
      return true

  return false

proc parseJobs(value, source: string): int =
  try:
    result = parseInt(value)
  except ValueError:
    echo "Cannot parse ", source, ": ", value
    quit 1
  if result <= 0:
    echo source, " must be greater than 0"
    quit 1

proc initRuntimeJobs() =
  runtimeJobs = defaultJobs
  when declared(stdout):
    const jobsEnv = "UNITTEST3_JOBS"
    if existsEnv(jobsEnv):
      runtimeJobs = parseJobs(getEnv(jobsEnv), jobsEnv)

proc getRuntimeJobs(): int =
  if runtimeJobs <= 0:
    defaultJobs
  else:
    runtimeJobs

proc parseParameters*(args: openArray[string]) =
  var
    hasConsole = false
    hasXml: string
    hasVerbose = false
    hasLevel = defaultOutputLevel()

  # Read tests to run from the command line.
  for str in args:
    if str.startsWith("--help"):
      echo "Usage: [--xml=file.xml] [--console] [--output-level=[VERBOSE,COMPACT,FAILURES,NONE]] [--jobs=N] [test-name-glob]"
      quit 0
    elif str.startsWith("--xml:") or str.startsWith("--xml="):
      hasXml = str[("--xml".len + 1)..^1] # skip separator char as well
    elif str.startsWith("--console"):
      hasConsole = true
    elif str.startsWith("--jobs:") or str.startsWith("--jobs="):
      runtimeJobs = parseJobs(str[("--jobs".len + 1)..^1], "--jobs")
    elif str.startsWith("--output-level:") or str.startsWith("--output-level="):
      hasLevel = try: parseEnum[OutputLevel](str[("--output-level".len + 1)..^1])
        except ValueError:
          echo "Unknown output level ", str[("--output-level".len + 1)..^1]
          quit 1
    elif str.startsWith("--verbose") or str == "-v":
      hasVerbose = true
    else:
      testsFilters.incl(str)
  if hasXml.len > 0:
    try:
      formatters.add(newJUnitOutputFormatter(newFileStream(hasXml, fmWrite)))
    except CatchableError as exc:
      echo "Cannot open ", hasXml, " for writing: ", exc.msg
      quit 1

  if hasConsole or hasXml.len == 0:
    let level =
      if hasVerbose: OutputLevel.VERBOSE
      else: hasLevel
    formatters.add(newConsoleOutputFormatter(level, defaultColorOutput()))

proc ensureInitialized() =
  initRuntimeJobs()

  if autoParseArgs and declared(paramCount):
    parseParameters(commandLineParams())

  if formatters.len == 0:
    formatters = @[OutputFormatter(defaultConsoleFormatter())]

ensureInitialized() # Run once!

template suite*(nameParam: string, body: untyped) {.dirty.} =
  ## Declare a test suite identified by `name` with optional ``setup``
  ## and/or ``teardown`` section.
  ##
  ## A test suite is a series of one or more related tests sharing a
  ## common fixture (``setup``, ``teardown``). The fixture is executed
  ## for EACH test.
  ##
  ## .. code-block:: nim
  ##  suite "test suite for addition":
  ##    setup:
  ##      let result = 4
  ##
  ##    test "2 + 2 = 4":
  ##      check(2+2 == result)
  ##
  ##    test "(2 + -2) != 4":
  ##      check(2 + -2 != result)
  ##
  ##    # No teardown needed
  ##
  ## The suite will run the individual test cases in the order in which
  ## they were listed. With default global settings the above code prints:
  ##
  ## .. code-block::
  ##
  ##  [Suite] test suite for addition
  ##    [OK] 2 + 2 = 4
  ##    [OK] (2 + -2) != 4
  bind collect, currentSuite, suiteStarted, suiteEnded

  block:
    template setup(setupBody: untyped) {.dirty, used.} =
      var testSetupIMPLFlag {.used.} = true
      template testSetupIMPL: untyped {.dirty.} = setupBody

    template teardown(teardownBody: untyped) {.dirty, used.} =
      var testTeardownIMPLFlag {.used.} = true
      template testTeardownIMPL: untyped {.dirty.} = teardownBody

    template suiteTeardown(suiteTeardownBody: untyped) {.dirty, used.} =
      var testSuiteTeardownIMPLFlag {.used.} = true
      template testSuiteTeardownIMPL: untyped {.dirty.} = suiteTeardownBody

    let suiteName {.inject.} = nameParam
    when not collect:
      # TODO deal with suite nesting
      if currentSuite.len > 0:
        suiteEnded()
        currentSuite.reset()
      currentSuite = suiteName

      suiteStarted(suiteName)

    # TODO what about exceptions in the suite itself?
    body

    when declared(testSuiteTeardownIMPLFlag):
      testSuiteTeardownIMPL()

    when not collect:
      suiteEnded()
      currentSuite.reset()

template checkpoint*(msg: string) =
  ## Set a checkpoint identified by `msg`. Upon test failure all
  ## checkpoints encountered so far are printed out. Example:
  ##
  ## .. code-block:: nim
  ##
  ##  checkpoint("Checkpoint A")
  ##  check((42, "the Answer to life and everything") == (1, "a"))
  ##  checkpoint("Checkpoint B")
  ##
  ## outputs "Checkpoint A" once it fails.
  bind checkpoints

  if currentAsyncCtx != nil:
    currentAsyncCtx.checkpoints.add(msg)
  else:
    checkpoints.add(msg)
  # TODO: add support for something like SCOPED_TRACE from Google Test

template fail* =
  ## Print out the checkpoints encountered so far and quit if ``abortOnError``
  ## is true. Otherwise, erase the checkpoints and indicate the test has
  ## failed (change exit code and test status). This template is useful
  ## for debugging, but is otherwise mostly used internally. Example:
  ##
  ## .. code-block:: nim
  ##
  ##  checkpoint("Checkpoint A")
  ##  complicatedProcInThread()
  ##  fail()
  ##
  ## outputs "Checkpoint A" before quitting.
  if currentAsyncCtx != nil:
    currentAsyncCtx.status = TestStatus.FAILED
  else:
    testStatus = TestStatus.FAILED

  exitProcs.setProgramResult(1)

  for formatter in formatters:
    let formatter = formatter # avoid lent iterator
    let cp = if currentAsyncCtx != nil: currentAsyncCtx.checkpoints
             else: checkpoints
    when declared(stackTrace):
      when stackTrace is string:
        formatter.failureOccurred(cp, stackTrace)
      else:
        formatter.failureOccurred(cp, "")
    else:
      formatter.failureOccurred(cp, "")

  if abortOnError: quit(1)

  if currentAsyncCtx != nil:
    currentAsyncCtx.checkpoints.reset()
  else:
    checkpoints.reset()

template skip* =
  ## Mark the test as skipped. Should be used directly
  ## in case when it is not possible to perform test
  ## for reasons depending on outer environment,
  ## or certain application logic conditions or configurations.
  ## The test code is still executed.
  ##
  ## .. code-block:: nim
  ##
  ##  if not isGLContextCreated():
  ##    skip()
  bind checkpoints

  if currentAsyncCtx != nil:
    currentAsyncCtx.status = TestStatus.SKIPPED
    currentAsyncCtx.checkpoints = @[]
  else:
    testStatus = TestStatus.SKIPPED
    checkpoints = @[]

template runtimeTest*(nameParam: string, body: untyped) =
  ## Similar to `test`, but always runs at runtime.
  bind collect, shouldRun, checkpoints

  proc runTestAsync(asyncSuiteName, asyncTestName: string): Future[
      TestRunResult] {.
      async, gcsafe, gensym.} =
    let ctx = AsyncTestContext(
      suiteName: asyncSuiteName,
      testName: asyncTestName,
      status: TestStatus.OK,
      checkpoints: @[])
    {.cast(gcsafe).}:
      currentAsyncCtx = ctx
      startTestOutputCapture(ctx)
      installChroniclesTestOutput()

      let suiteName {.inject, used.} = asyncSuiteName
      let testName {.inject, used.} = asyncTestName
      template testStatusIMPL: var TestStatus {.inject, used.} = ctx.status

      template fail(prefix: string, eClass: string, e: auto): untyped =
        let eName = "[" & $e.name & "]"
        checkpoint(prefix & "Unhandled " & eClass & ": " & e.msg & " " & eName)
        var stackTrace {.inject.} = e.getStackTrace()
        fail()

      # Use the same failingOnExceptions pattern as the sync version so that
      # {.inject.} variables from setup are visible in body and teardown.
      template failAsyncOnExceptions(prefix: string, code: untyped): untyped =
        when NimMajor >= 2: {.push warning[UnnamedBreak]: off.}
        try:
          block:
            code
        except CatchableError as e: prefix.fail("error", e)
        except Defect as e: prefix.fail("defect", e)
        except Exception as e: prefix.fail(
            "exception that may cause undefined behavior", e)
        when NimMajor >= 2: {.pop.}

      failAsyncOnExceptions("[setup] "):
        when declared(testSetupIMPLFlag): testSetupIMPL()
        failAsyncOnExceptions(""):
          when not unittest3ListTests:
            body # await is valid here; setup-injected vars are in scope
        failAsyncOnExceptions("[teardown] "):
          when declared(testTeardownIMPLFlag): testTeardownIMPL()

      let output = finishTestOutputCapture(ctx)
      currentAsyncCtx = nil
    TestRunResult(status: ctx.status, output: output)

  let
    localSuiteName =
      when declared(suiteName):
        suiteName
      else:
        if currentSuite.len > 0:
          currentSuite
        else:
          instantiationInfo().filename
    localTestName = nameParam
  if shouldRun(localSuiteName, localTestName):
    let
      instance =
        Test(
          testName: localTestName,
          suiteName: localSuiteName,
          asyncImpl: runTestAsync,
          lineInfo: instantiationInfo().line,
          filename: instantiationInfo().filename,
          serial: currentSuiteSerial or currentTestSerial
        )
    when collect:
      tests.mgetOrPut(localSuiteName, default(seq[Test])).add(instance)
    else:
      runDirect(instance)

template test*(nameParam: string, body: untyped) =
  ## Define a single test case identified by `name`.
  ##
  ## .. code-block:: nim
  ##
  ##  test "roses are red":
  ##    let roses = "red"
  ##    check(roses == "red")
  ##
  ## The above code outputs:
  ##
  ## .. code-block::
  ##
  ##  [OK] roses are red
  runtimeTest nameParam:
    when not unittest3ListTests:
      body

template serialTest*(nameParam: string, body: untyped) =
  ## Define a test case that must not overlap with any other collected test.
  bind currentTestSerial

  block:
    let unittest3SavedTestSerial = currentTestSerial
    currentTestSerial = true
    test nameParam:
      body
    currentTestSerial = unittest3SavedTestSerial

template serialSuite*(nameParam: string, body: untyped) =
  ## Define a suite whose tests must not overlap with any other collected test.
  bind currentSuiteSerial

  block:
    let unittest3SavedSuiteSerial = currentSuiteSerial
    currentSuiteSerial = true
    suite nameParam:
      body
    currentSuiteSerial = unittest3SavedSuiteSerial

template asyncTest*(nameParam: string, body: untyped) =
  ## Compatibility alias for async tests. `test` bodies already run in an
  ## async context, so `await` can be used directly.
  test nameParam:
    body

template asyncSetup*(body: untyped) =
  ## Compatibility alias for async setup blocks.
  setup:
    body

template asyncTeardown*(body: untyped) =
  ## Compatibility alias for async teardown blocks.
  teardown:
    body

{.pop.} # raises: []

iterator unittest3EvalOnceIter[T](x: T): auto =
  yield x
iterator unittest3EvalOnceIter[T](x: var T): var T =
  yield x

template unittest3EvalOnce(name: untyped, param: typed, blk: untyped) =
  for name in unittest3EvalOnceIter(param):
    blk

macro check*(conditions: untyped): untyped =
  ## Verify if a statement or a list of statements is true.
  ## A helpful error message and set checkpoints are printed out on
  ## failure (if ``outputLevel`` is not ``NONE``).
  runnableExamples:
    import std/strutils

    check("AKB48".toLowerAscii() == "akb48")

    let teams = {'A', 'K', 'B', '4', '8'}

    check:
      "AKB48".toLowerAscii() == "akb48"
      'C' notin teams

  {.warning[Deprecated]: off.}
  let checked = callsite()[1]
  {.warning[Deprecated]: on.}

  template print(name: untyped, value: typed) =
    when compiles($value):
      when typeof($value) is string:
        checkpoint(name & " was " & $value)

  proc inspectArgs(exp: NimNode): tuple[frame, inner, check,
      printOuts: NimNode] =
    result.check = copyNimTree(exp)
    result.inner = newNimNode(nnkStmtList)
    result.printOuts = newNimNode(nnkStmtList)

    var counter = 0
    let evalOnce = bindSym("unittest3EvalOnce")
    result.frame = result.inner
    if exp[0].kind in {nnkIdent, nnkOpenSymChoice, nnkClosedSymChoice,
        nnkSym} and $exp[0] in ["not", "in", "notin", "==", "<=",
                    ">=", "<", ">", "!=", "is", "isnot"]:

      for i in 1 ..< exp.len:
        if exp[i].kind notin nnkLiterals:
          inc counter
          let argStr = exp[i].toStrLit
          let paramAst = exp[i]
          if exp[i].kind == nnkIdent:
            result.printOuts.add getAst(print(argStr, paramAst))
          if exp[i].kind in nnkCallKinds + {nnkDotExpr, nnkBracketExpr, nnkPar} and
                  (exp[i].typeKind notin {ntyTypeDesc} or $exp[0] notin ["is", "isnot"]):
            let callVar = newIdentNode(":c" & $counter)
            result.frame = nnkCall.newTree(evalOnce, callVar, paramAst, result.frame)
            result.check[i] = callVar
            result.printOuts.add getAst(print(argStr, callVar))
          if exp[i].kind == nnkExprEqExpr:
            # ExprEqExpr
            #   Ident "v"
            #   IntLit 2
            result.check[i] = exp[i][1]
          if exp[i].typeKind notin {ntyTypeDesc}:
            let arg = newIdentNode(":p" & $counter)
            result.frame = nnkCall.newTree(evalOnce, arg, paramAst, result.frame)
            result.printOuts.add getAst(print(argStr, arg))
            if exp[i].kind != nnkExprEqExpr:
              result.check[i] = arg
            else:
              result.check[i][1] = arg

  proc buildCheck(lineinfo, callLit, check, printOuts: NimNode): NimNode =
    let
      checkpointSym = bindSym("checkpoint")
      failSym = bindSym("fail")
    nnkBlockStmt.newTree(
      newEmptyNode(),
      nnkStmtList.newTree(
        nnkIfStmt.newTree(
          nnkElifBranch.newTree(
            nnkCall.newTree(ident("not"), check),
            nnkStmtList.newTree(
              nnkCall.newTree(
                checkpointSym,
                nnkInfix.newTree(
                  ident("&"),
                  nnkInfix.newTree(
                    ident("&"),
                    lineinfo,
                    newLit(": Check failed: ")
      ),
      callLit
    )
      ),
      printOuts,
      nnkCall.newTree(failSym)
    )
      )
    )
      )
    )

  let
    checkSym = bindSym("check")

  case checked.kind
  of nnkCallKinds:
    let
      (frame, inner, check, printOuts) = inspectArgs(checked)
      lineinfo = newStrLitNode(checked.lineInfo)
      callLit = checked.toStrLit

    inner.add buildCheck(lineinfo, callLit, check, printOuts)
    result = frame
  of nnkStmtList:
    result = newNimNode(nnkStmtList)
    for node in checked:
      if node.kind != nnkCommentStmt:
        result.add(newCall(checkSym, node))

  else:
    let
      lineinfo = newStrLitNode(checked.lineInfo)
      callLit = checked.toStrLit

    result = buildCheck(
      lineinfo, callLit, checked, newEmptyNode())

template require*(conditions: untyped) =
  ## Same as `check` except any failed test causes the program to quit
  ## immediately. Any teardown statements are not executed and the failed
  ## test output is not generated.
  let savedAbortOnError = abortOnError
  block:
    abortOnError = true
    check conditions
  abortOnError = savedAbortOnError

macro expect*(exceptions: varargs[typed], body: untyped): untyped =
  ## Test if `body` raises an exception found in the passed `exceptions`.
  ## The test passes if the raised exception is part of the acceptable
  ## exceptions. Otherwise, it fails.
  runnableExamples:
    import std/[math, random, strutils]
    proc defectiveRobot() =
      randomize()
      case rand(1..4)
      of 1: raise newException(OSError, "CANNOT COMPUTE!")
      of 2: discard parseInt("Hello World!")
      of 3: raise newException(IOError, "I can't do that Dave.")
      else: assert 2 + 2 == 5

    expect IOError, OSError, ValueError, AssertionDefect:
      defectiveRobot()

  template expectBody(errorTypes, lineInfoLit, body): NimNode {.dirty.} =
    try:
      try:
        body
        checkpoint(lineInfoLit & ": Expect Failed, no exception was thrown.")
        fail()
      except errorTypes:
        discard
    except CatchableError as e:
      checkpoint(lineInfoLit & ": Expect Failed, unexpected " & $e.name &
      " (" & e.msg & ") was thrown.\n" & e.getStackTrace())
      fail()
    except Defect as e:
      checkpoint(lineInfoLit & ": Expect Failed, unexpected " & $e.name &
      " (" & e.msg & ") was thrown.\n" & e.getStackTrace())
      fail()

  var errorTypes = newNimNode(nnkBracket)
  for exp in exceptions:
    errorTypes.add(exp)

  result = getAst(expectBody(errorTypes, errorTypes.lineInfo, body))

proc disableParamFiltering* {.deprecated:
    "Compile with -d:unittest3DisableParamFiltering instead".} =
  discard

when unittest3PreviewIsolate:
  import std/[osproc, strtabs]
  proc runIsolated(test: Test) =
    # Run test in an isolated process - this has the advantage that we can
    # trivially capture stdout but has a number of problems:
    # * suite and other global stuff gets executed for each test
    #   * on unix, `fork` could work around this but not on windows
    # * there's no good way to separate errors from stdout
    # * there's process overhead
    #
    # There are advantages too:
    # * reduced cross-test pollution
    # * simple to parallelise
    # * we can abort long-running tests after a timeout

    let startTime = Moment.now()
    testStarted(test.testName)

    let runner = startProcess(
      getAppFilename2(),
      args = [test.suiteName & "::" & test.testName],
      env = newStringTable(
        "unittest3_ISOLATED", "1",
        StringTableMode.modeCaseSensitive),
      options = {poStdErrToStdOut})

    close(runner.inputStream) # EOF so the test doesn't think it'll get input

    var output: string

    while true:
      let pos = output.len
      output.setLen(pos + 4096)

      let bytes = runner.outputStream.readData(addr output[pos], 4096)
      if bytes >= 0:
        output.setLen(pos + bytes)

      if bytes <= 0:
        break

    let status = runner.waitForExit()

    runner.close()

    testEnded(TestResult(
      suiteName: test.suiteName,
      testName: test.testName,
      status: if status == 0: TestStatus.OK else: TestStatus.FAILED,
      duration: Moment.now() - startTime,
      output: output
    ))

  type
    IsolatedFormatter* = ref object of OutputFormatter
      ## Formatter suitable for using the process-isolated environment
      ##
      ## This is a work in progress with several open issues
      ## * we could use stderr for "unittest" traffic but it would be
      ##   compromised by application output (typically ok in nim) and makes
      ##   reading messy
      ## * we could print all errors after test providing some sort of
      ##   separator - has escape issues
      ## * we could redirect stdout/stderr to a file and use stdout for errors
      ## * as an addon to the above, we could read back the file then print
      ##   a structured test format to stdout which the parent process can
      ##   capture easily

  if isolated:
    formatters.add(IsolatedFormatter())

  method failureOccurred*(formatter: IsolatedFormatter,
                          checkpoints: seq[string], stackTrace: string) =
    if stackTrace.len > 0:
      echo(stackTrace)
      echo("\n")
    for msg in items(checkpoints):
      echo("    ")
      echo(msg)
      echo("\n")

when collect:
  proc runAsync(test: Test) {.async.} =
    let startTime = Moment.now()
    noteTestExecution(test.suiteName, test.testName)
    testStarted(test.testName)
    var testRunResult = TestRunResult(status: TestStatus.FAILED)
    try:
      {.cast(gcsafe).}:
        let testFuture = test.asyncImpl(test.suiteName, test.testName)
        when unittest3TestTimeoutSeconds == 0:
          testRunResult = await testFuture
        else:
          let testTimeout = unittest3TestTimeoutSeconds.seconds
          let timeoutFuture = chronos.sleepAsync(testTimeout)
          discard await chronos.race(@[FutureBase(testFuture), FutureBase(
              timeoutFuture)])

          if timeoutFuture.finished() and not testFuture.finished():
            testFuture.cancelSoon()
            discard await testFuture.withTimeout(1.seconds)
            testRunResult = TestRunResult(
              status: TestStatus.FAILED,
              output:
              "[TIMEOUT] Test exceeded timeout of " &
              $unittest3TestTimeoutSeconds & " seconds.\n"
            )
          else:
            if not timeoutFuture.finished():
              await timeoutFuture.cancelAndWait()
            if testFuture.finished() and not testFuture.cancelled():
              testRunResult = testFuture.read()
            else:
              testRunResult = TestRunResult(
                status: TestStatus.FAILED,
                output: "Test future was cancelled.\n"
              )
    except Exception as e:
      discard e # asyncImpl catches all exceptions internally; status already set

    testEnded(TestResult(
      suiteName: test.suiteName,
      testName: test.testName,
      status: testRunResult.status,
      duration: Moment.now() - startTime,
      output: testRunResult.output
    ))

  proc runScheduledTestsAsync(
      tmp: OrderedTable[string, seq[Test]]
  ) {.async.} =
    type InflightEntry = tuple[fut: FutureBase, suiteName: string, serial: bool]
    var
      allTests: seq[tuple[suiteName: string, test: Test]]
      suiteTotals: Table[string, int]
      suiteDone: Table[string, int]
      suiteBegun: HashSet[string]
      inflight: seq[InflightEntry]
      raceFutures: seq[FutureBase]
      serialActive = false
      idx = 0

    for sn, suite in tmp:
      if suite.len == 0: continue
      suiteTotals[sn] = suite.len
      for t in suite:
        allTests.add((sn, t))

    let jobLimit = getRuntimeJobs()
    raceFutures = newSeqOfCap[FutureBase](jobLimit)

    while idx < allTests.len or inflight.len > 0:
      # Reap completed futures; signal suiteEnded when last test of suite finishes
      var writeIdx = 0
      serialActive = false
      for readIdx in 0 ..< inflight.len:
        let entry = inflight[readIdx]
        if entry.fut.finished:
          let done = suiteDone.getOrDefault(entry.suiteName, 0) + 1
          suiteDone[entry.suiteName] = done
          if done == suiteTotals.getOrDefault(entry.suiteName, 0):
            suiteEnded()
        else:
          if writeIdx != readIdx:
            inflight[writeIdx] = entry
          inc writeIdx
          serialActive = serialActive or entry.serial
      inflight.setLen(writeIdx)

      # Launch new tests up to the configured job limit.
      var blockedBySerial = false
      while idx < allTests.len and inflight.len < jobLimit:
        if serialActive:
          blockedBySerial = true
          break

        let (sn, t) = allTests[idx]
        if t.serial and inflight.len > 0:
          blockedBySerial = true
          break

        if sn notin suiteBegun:
          suiteStarted(sn)
          suiteBegun.incl(sn)
        inflight.add((FutureBase(runAsync(t)), sn, t.serial))
        inc idx
        if t.serial:
          serialActive = true
          break

      if inflight.len == 0:
        break

      if blockedBySerial or inflight.len >= jobLimit or idx >= allTests.len:
        # At capacity or all tests launched: wait for one to finish
        try:
          raceFutures.setLen(0)
          for entry in inflight:
            raceFutures.add(entry.fut)
          discard await chronos.race(raceFutures)
        except ValueError:
          discard # inflight is non-empty so this should not fire
        except CancelledError:
          break

  proc runScheduledTests() {.noconv.} =
    # Tests can be added inside tests - this is weird and only partially
    # supported
    while tests.len > 0:
      var tmp = move(tests)
      when unittest3ListTests:
        for suiteName, suite in tmp:
          if suite.len == 0: continue
          echo "Suite: ", suiteName
          for test in suite:
            echo "\tTest: ", test.testName
            echo "\tFile: ", test.filename, ":", test.lineInfo
      else:
        suiteRunStarted(tmp)
        when isolate:
          for suiteName, suite in tmp:
            if suite.len == 0: continue
            suiteStarted(suiteName)
            for test in suite:
              if not isolated:
                runIsolated(test)
              else:
                runDirect(test)
            suiteEnded()
        else:
          waitFor(runScheduledTestsAsync(tmp))
        suiteRunEnded()
    when not unittest3ListTests:
      testRunEnded()

  addExitProc(runScheduledTests)

else:
  addExitProc(proc() {.noconv.} = testRunEnded())

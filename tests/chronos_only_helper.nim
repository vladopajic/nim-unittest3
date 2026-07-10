import chronos

type HelperCallback* = proc() {.gcsafe, raises: [].}

proc callAfterNormalChronosAwait*(cb: HelperCallback): Future[void] {.async.} =
  await sleepAsync(10.milliseconds)
  cb()

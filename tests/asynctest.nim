import ../unittest3
import chronicles


suite "Async Tests":
  test "async work slow":
    await sleepAsync(150.milliseconds)
    echo "111 echo"
    stdout.write("111 slow stdout.write\n")
    info "111 slow chronicles log"
    check(1 == 3)

  test "async work fast":
    await sleepAsync(50.milliseconds)
    echo "222"
    stdout.write("222 fast stdout.write\n")
    info "222 fast chronicles log"
    check(1 == 1)

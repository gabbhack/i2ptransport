import chronos

import libp2p
import libp2p/protocols/ping

import i2ptransport

proc main() {.async, gcsafe.} =
  let
    rng = newRng()
    pingProtocol = Ping.new(rng=rng)

  let
    switch1 = I2PSwitch.new(
      initTAddress("127.0.0.1:7656"),
      I2PSettings.init("first"),
      rng
    )
    switch2 = I2PSwitch.new(
      initTAddress("127.0.0.1:7656"),
      I2PSettings.init("second"),
      rng
    )

  switch1.mount(pingProtocol)

  echo "Switch 1 start"
  await switch1.start()
  echo "Switch 2 start"
  await switch2.start()

  echo "Dialing"
  let conn = await switch2.dial(switch1.peerInfo.peerId, switch1.peerInfo.addrs, PingCodec)

  # ping the other node and echo the ping duration
  echo "ping: ", await pingProtocol.ping(conn)

  # We must close the connection ourselves when we're done with it
  await conn.close()

  await allFutures(switch1.stop(), switch2.stop()) # close connections and shutdown all transports


when isMainModule:
  waitFor(main())

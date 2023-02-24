import chronos

import libp2p
import libp2p/protocols/ping

import i2ptransport


proc main() {.async, gcsafe.} =
  let
    rng = newRng()
    pingProtocol = Ping.new(rng=rng)
    samAddress = initTAddress("127.0.0.1:7656")

  let
    keyPair1 = await generateDestination(samAddress)
    switch1 = I2PSwitch.new(
      samAddress,
      I2PSessionSettings.init("first"),
      keyPair1,
      rng
    )

    keyPair2 = await generateDestination(samAddress)
    switch2 = I2PSwitch.new(
      samAddress,
      I2PSessionSettings.init("second"),
      keyPair2,
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
  echo "Done"

when isMainModule:
  waitFor(main())
